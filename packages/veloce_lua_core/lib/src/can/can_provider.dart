import 'dart:async';
import 'dart:collection';

import '../errors/plugin_exception.dart';
import 'can_models.dart';

typedef CanFrameHandler = FutureOr<void> Function(CanFrame frame);
typedef CanProviderErrorHandler = void Function(
  Object error,
  StackTrace stackTrace,
  String ownerId,
);

abstract interface class CanSubscription {
  String get ownerId;
  CanFilter get filter;
  Future<void> cancel();
}

abstract interface class CanProvider {
  bool get writesEnabled;

  Future<CanSubscription> subscribe({
    required String ownerId,
    required CanFilter filter,
    required CanFrameHandler onFrame,
  });

  Future<void> send({
    required String ownerId,
    required CanFrame frame,
  });

  Future<void> removeOwner(String ownerId);
  Future<void> close();
}

/// Read/write restrictions which can later be populated from scoped manifests.
final class CanAccessGrant {
  CanAccessGrant({
    Iterable<CanFilter> readFilters = const [],
    Iterable<CanFilter> writeFilters = const [],
    this.maxSendRatePerSecond = 0,
  })  : readFilters = List.unmodifiable(readFilters),
        writeFilters = List.unmodifiable(writeFilters) {
    if (maxSendRatePerSecond < 0) {
      throw ArgumentError.value(
        maxSendRatePerSecond,
        'maxSendRatePerSecond',
        'Must not be negative',
      );
    }
  }

  final List<CanFilter> readFilters;
  final List<CanFilter> writeFilters;
  final int maxSendRatePerSecond;
}

abstract interface class CanAuthorizationPolicy {
  void requireSubscription(String ownerId, CanFilter filter);
  void requireSend(String ownerId, CanFrame frame);
  void removeOwner(String ownerId);
}

/// Configurable bus/ID-set/mask grants with a sliding write-rate limit.
final class ConfigurableCanAuthorizationPolicy
    implements CanAuthorizationPolicy {
  final Map<String, CanAccessGrant> _grants = {};
  final Map<String, Queue<int>> _sendTimesMicros = {};

  void setGrant(String ownerId, CanAccessGrant grant) {
    _grants[ownerId] = grant;
    _sendTimesMicros.remove(ownerId);
  }

  @override
  void requireSubscription(String ownerId, CanFilter filter) {
    final grant = _grants[ownerId];
    final allowed =
        grant?.readFilters.any((item) => item.covers(filter)) ?? false;
    if (!allowed) {
      throw PluginPermissionException(
        'CAN subscription $filter is outside the plugin read grant.',
        pluginId: ownerId,
        capability: 'can.read',
      );
    }
  }

  @override
  void requireSend(String ownerId, CanFrame frame) {
    final grant = _grants[ownerId];
    final allowed =
        grant?.writeFilters.any((item) => item.matches(frame)) ?? false;
    if (!allowed) {
      throw PluginPermissionException(
        'CAN frame $frame is outside the plugin write grant.',
        pluginId: ownerId,
        capability: 'can.write',
      );
    }
    final rate = grant!.maxSendRatePerSecond;
    if (rate <= 0) {
      throw PluginPermissionException(
        'CAN writes are disabled by the plugin rate grant.',
        pluginId: ownerId,
        capability: 'can.write',
      );
    }
    final now = DateTime.now().microsecondsSinceEpoch;
    final cutoff = now - const Duration(seconds: 1).inMicroseconds;
    final times = _sendTimesMicros.putIfAbsent(ownerId, Queue.new);
    while (times.isNotEmpty && times.first <= cutoff) {
      times.removeFirst();
    }
    if (times.length >= rate) {
      throw PluginPermissionException(
        'CAN send rate limit of $rate frames/second exceeded.',
        pluginId: ownerId,
        capability: 'can.write',
      );
    }
    times.addLast(now);
  }

  @override
  void removeOwner(String ownerId) {
    _grants.remove(ownerId);
    _sendTimesMicros.remove(ownerId);
  }
}

final class CanWriteDisabledException extends PluginPermissionException {
  const CanWriteDisabledException({required String pluginId})
      : super(
          'CAN transmission is disabled by the host.',
          pluginId: pluginId,
          capability: 'can.write',
        );
}

final class CanInjectionResult {
  const CanInjectionResult({
    required this.filterChecks,
    required this.matchedSubscriptions,
    required this.droppedDeliveries,
  });

  final int filterChecks;
  final int matchedSubscriptions;
  final int droppedDeliveries;
}

/// Test/demo CAN provider which filters before scheduling plugin handlers.
final class InMemoryCanProvider implements CanProvider {
  InMemoryCanProvider({
    this.writesEnabled = false,
    this.authorizationPolicy,
    this.maxPendingPerSubscription = 32,
    this.onHandlerError,
  }) : assert(maxPendingPerSubscription > 0);

  @override
  final bool writesEnabled;
  final CanAuthorizationPolicy? authorizationPolicy;
  final int maxPendingPerSubscription;
  final CanProviderErrorHandler? onHandlerError;
  final Map<int, _InMemoryCanSubscription> _subscriptions = {};
  final StreamController<CanFrame> _sentFrames =
      StreamController<CanFrame>.broadcast(sync: true);
  final List<CanFrame> _sentHistory = [];
  var _nextId = 1;
  var _closed = false;

  Stream<CanFrame> get sentFrames => _sentFrames.stream;
  List<CanFrame> get sentHistory => List.unmodifiable(_sentHistory);

  @override
  Future<CanSubscription> subscribe({
    required String ownerId,
    required CanFilter filter,
    required CanFrameHandler onFrame,
  }) async {
    _ensureOpen();
    _validateOwner(ownerId);
    authorizationPolicy?.requireSubscription(ownerId, filter);
    final id = _nextId++;
    final subscription = _InMemoryCanSubscription(
      id: id,
      ownerId: ownerId,
      filter: filter,
      handler: onFrame,
      maxPending: maxPendingPerSubscription,
      reportError: onHandlerError,
      onCancel: () => _subscriptions.remove(id),
    );
    _subscriptions[id] = subscription;
    return subscription;
  }

  /// Injects a received frame. Non-matching frames never enter plugin queues.
  CanInjectionResult inject(CanFrame frame) {
    _ensureOpen();
    var checks = 0;
    var matches = 0;
    var drops = 0;
    for (final subscription in List.of(_subscriptions.values)) {
      if (!subscription.active) continue;
      checks++;
      if (!subscription.filter.matches(frame)) continue;
      matches++;
      if (!subscription.enqueue(frame)) drops++;
    }
    return CanInjectionResult(
      filterChecks: checks,
      matchedSubscriptions: matches,
      droppedDeliveries: drops,
    );
  }

  @override
  Future<void> send({
    required String ownerId,
    required CanFrame frame,
  }) async {
    _ensureOpen();
    _validateOwner(ownerId);
    if (!writesEnabled) {
      throw CanWriteDisabledException(pluginId: ownerId);
    }
    authorizationPolicy?.requireSend(ownerId, frame);
    final copy = frame.copyWith();
    _sentHistory.add(copy);
    _sentFrames.add(copy);
  }

  Future<void> flush() async {
    while (true) {
      final states = List.of(_subscriptions.values);
      await Future.wait(states.map((state) => state.whenIdle));
      if (states.every((state) => state.isIdle)) return;
    }
  }

  @override
  Future<void> removeOwner(String ownerId) async {
    final states = _subscriptions.values
        .where((subscription) => subscription.ownerId == ownerId)
        .toList(growable: false);
    await Future.wait(states.map((state) => state.cancel()));
    authorizationPolicy?.removeOwner(ownerId);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final states = List.of(_subscriptions.values);
    _subscriptions.clear();
    await Future.wait(states.map((state) => state.cancel()));
    await _sentFrames.close();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('InMemoryCanProvider is closed.');
  }

  static void _validateOwner(String ownerId) {
    if (ownerId.trim().isEmpty) {
      throw ArgumentError.value(ownerId, 'ownerId', 'Must not be empty');
    }
  }
}

final class _InMemoryCanSubscription implements CanSubscription {
  _InMemoryCanSubscription({
    required this.id,
    required this.ownerId,
    required this.filter,
    required this.handler,
    required this.maxPending,
    required this.reportError,
    required this.onCancel,
  });

  final int id;
  @override
  final String ownerId;
  @override
  final CanFilter filter;
  final CanFrameHandler handler;
  final int maxPending;
  final CanProviderErrorHandler? reportError;
  final void Function() onCancel;
  final Queue<CanFrame> _pending = Queue();
  Future<void>? _drainFuture;
  bool active = true;

  bool get isIdle => _pending.isEmpty && _drainFuture == null;
  Future<void> get whenIdle => _drainFuture ?? Future<void>.value();

  bool enqueue(CanFrame frame) {
    if (!active) return false;
    var accepted = true;
    if (_pending.length >= maxPending) {
      _pending.removeFirst();
      accepted = false;
    }
    _pending.addLast(frame.copyWith());
    _startDrain();
    return accepted;
  }

  void _startDrain() {
    if (_drainFuture != null) return;
    final completer = Completer<void>();
    final future = completer.future;
    _drainFuture = future;
    _drain().then(completer.complete, onError: completer.completeError);
    unawaited(future.whenComplete(() {
      _drainFuture = null;
      if (active && _pending.isNotEmpty) _startDrain();
    }));
  }

  Future<void> _drain() async {
    while (active && _pending.isNotEmpty) {
      final frame = _pending.removeFirst();
      try {
        await handler(frame);
      } catch (error, stackTrace) {
        try {
          reportError?.call(error, stackTrace, ownerId);
        } catch (_) {
          // Error reporters must not break provider isolation.
        }
      }
    }
  }

  @override
  Future<void> cancel() async {
    if (!active) return;
    active = false;
    _pending.clear();
    onCancel();
    await whenIdle;
  }
}
