import 'dart:async';

import '../events/plugin_event_bus.dart';
import '../values/structured_value.dart';

typedef VehicleDataHandler = FutureOr<void> Function(VehicleDataPoint point);

final class VehicleDataPoint {
  const VehicleDataPoint({
    required this.key,
    required this.value,
    required this.timestamp,
    required this.sequence,
    this.sourcePluginId,
  });

  final String key;
  final StructuredValue value;
  final DateTime timestamp;
  final int sequence;
  final String? sourcePluginId;
}

final class VehicleDataSubscription {
  VehicleDataSubscription._({
    required this.id,
    required this.ownerId,
    required this.key,
    required Future<void> Function() cancel,
  }) : _cancel = cancel;

  final int id;
  final String ownerId;
  final String key;
  final Future<void> Function() _cancel;

  Future<void> cancel() => _cancel();
}

final class VehiclePublishResult {
  const VehiclePublishResult({
    required this.subscribers,
    required this.coalescedUpdates,
  });

  final int subscribers;
  final int coalescedUpdates;
}

/// Typed vehicle signals, intentionally independent from their CAN transport.
///
/// Each slow subscriber has a single pending slot. Rapid updates replace that
/// slot, preserving the newest value instead of building an unbounded backlog.
final class VehicleDataBus {
  VehicleDataBus({
    StructuredValueCodec codec = const StructuredValueCodec(),
    this.onHandlerError,
  }) : _codec = codec;

  static final RegExp _keyPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9_-]*(?:\.[A-Za-z0-9][A-Za-z0-9_-]*)+$',
  );

  final StructuredValueCodec _codec;
  final PluginAsyncErrorHandler? onHandlerError;
  final Map<int, _VehicleSubscriptionState> _subscriptions = {};
  final Map<String, VehicleDataPoint> _latest = {};
  var _nextId = 1;
  var _sequence = 0;
  var _closed = false;

  Map<String, VehicleDataPoint> get latest => Map.unmodifiable(_latest);

  VehicleDataPoint? valueFor(String key) => _latest[key];

  VehicleDataSubscription subscribe({
    required String ownerId,
    required String key,
    required VehicleDataHandler handler,
    bool emitCurrent = false,
  }) {
    _ensureOpen();
    _validateOwner(ownerId);
    _validateKey(key);
    final id = _nextId++;
    final state = _VehicleSubscriptionState(
      id: id,
      ownerId: ownerId,
      key: key,
      handler: handler,
      reportError: onHandlerError,
    );
    _subscriptions[id] = state;
    final current = _latest[key];
    if (emitCurrent && current != null) {
      state.enqueue(current);
    }
    return VehicleDataSubscription._(
      id: id,
      ownerId: ownerId,
      key: key,
      cancel: () => _cancel(id),
    );
  }

  VehiclePublishResult publish(
    String key,
    StructuredValue value, {
    String? sourcePluginId,
    DateTime? timestamp,
  }) {
    _ensureOpen();
    _validateKey(key);
    if (sourcePluginId != null) _validateOwner(sourcePluginId);
    final point = VehicleDataPoint(
      key: key,
      value: _codec.normalize(value, pluginId: sourcePluginId),
      timestamp: (timestamp ?? DateTime.now()).toUtc(),
      sequence: ++_sequence,
      sourcePluginId: sourcePluginId,
    );
    _latest[key] = point;
    var subscribers = 0;
    var coalesced = 0;
    for (final state in List.of(_subscriptions.values)) {
      if (!state.active || state.key != key) continue;
      subscribers++;
      if (state.enqueue(point)) coalesced++;
    }
    return VehiclePublishResult(
      subscribers: subscribers,
      coalescedUpdates: coalesced,
    );
  }

  int subscriptionCountFor(String ownerId) => _subscriptions.values
      .where((subscription) => subscription.ownerId == ownerId)
      .length;

  Future<void> removeOwner(String ownerId) async {
    final ids = _subscriptions.values
        .where((subscription) => subscription.ownerId == ownerId)
        .map((subscription) => subscription.id)
        .toList(growable: false);
    await Future.wait(ids.map(_cancel));
  }

  Future<void> flush() async {
    while (true) {
      final states = List.of(_subscriptions.values);
      await Future.wait(states.map((state) => state.whenIdle));
      if (states.every((state) => state.isIdle)) return;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final states = List.of(_subscriptions.values);
    _subscriptions.clear();
    await Future.wait(states.map((state) => state.cancel()));
    _latest.clear();
  }

  Future<void> _cancel(int id) async {
    final state = _subscriptions.remove(id);
    await state?.cancel();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('VehicleDataBus is closed.');
  }

  static void _validateKey(String key) {
    if (key.length > 256 || !_keyPattern.hasMatch(key)) {
      throw ArgumentError.value(key, 'key', 'Invalid vehicle data key');
    }
  }

  /// Validates an abstract vehicle-data key without publishing a value.
  static void validateKey(String key) => _validateKey(key);

  static void _validateOwner(String ownerId) {
    if (ownerId.trim().isEmpty) {
      throw ArgumentError.value(ownerId, 'ownerId', 'Must not be empty');
    }
  }
}

final class _VehicleSubscriptionState {
  _VehicleSubscriptionState({
    required this.id,
    required this.ownerId,
    required this.key,
    required this.handler,
    required this.reportError,
  });

  final int id;
  final String ownerId;
  final String key;
  final VehicleDataHandler handler;
  final PluginAsyncErrorHandler? reportError;
  VehicleDataPoint? _pending;
  Future<void>? _drainFuture;
  bool active = true;

  bool get isIdle => _pending == null && _drainFuture == null;
  Future<void> get whenIdle => _drainFuture ?? Future<void>.value();

  /// Returns true when a previously pending value was coalesced.
  bool enqueue(VehicleDataPoint point) {
    if (!active) return false;
    final coalesced = _pending != null;
    _pending = point;
    _startDrain();
    return coalesced;
  }

  void _startDrain() {
    if (_drainFuture != null) return;
    final completer = Completer<void>();
    final future = completer.future;
    _drainFuture = future;
    _drain().then(completer.complete, onError: completer.completeError);
    unawaited(future.whenComplete(() {
      _drainFuture = null;
      if (active && _pending != null) _startDrain();
    }));
  }

  Future<void> _drain() async {
    while (active && _pending != null) {
      final point = _pending!;
      _pending = null;
      try {
        await handler(point);
      } catch (error, stackTrace) {
        try {
          reportError?.call(error, stackTrace, ownerId);
        } catch (_) {
          // Error reporters must not break signal isolation.
        }
      }
    }
  }

  Future<void> cancel() async {
    active = false;
    _pending = null;
    await whenIdle;
  }
}
