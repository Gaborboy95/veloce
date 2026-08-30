import 'dart:async';
import 'dart:collection';

import '../values/structured_value.dart';

typedef PluginEventHandler = FutureOr<void> Function(PluginEvent event);
typedef PluginAsyncErrorHandler =
    void Function(Object error, StackTrace stackTrace, String ownerId);

enum QueueOverflowPolicy { dropOldest, dropNewest }

final class PluginEvent {
  const PluginEvent({
    required this.topic,
    required this.data,
    required this.timestamp,
    this.sourcePluginId,
  });

  final String topic;
  final StructuredValue data;
  final DateTime timestamp;
  final String? sourcePluginId;
}

final class PluginPublishResult {
  const PluginPublishResult({
    required this.matchedSubscriptions,
    required this.enqueuedDeliveries,
    required this.droppedDeliveries,
  });

  final int matchedSubscriptions;
  final int enqueuedDeliveries;
  final int droppedDeliveries;
}

final class PluginEventSubscription {
  PluginEventSubscription._({
    required this.id,
    required this.ownerId,
    required this.topic,
    required Future<void> Function() cancel,
  }) : _cancel = cancel;

  final int id;
  final String ownerId;
  final String topic;
  final Future<void> Function() _cancel;

  Future<void> cancel() => _cancel();
}

/// An owner-aware event bus with bounded, sequential subscriber queues.
///
/// A slow plugin cannot create an unbounded queue. Delivery errors are isolated
/// and reported to [onHandlerError] instead of escaping through publishers.
final class PluginEventBus {
  PluginEventBus({
    this.maxPendingPerSubscription = 64,
    this.overflowPolicy = QueueOverflowPolicy.dropOldest,
    StructuredValueCodec codec = const StructuredValueCodec(),
    this.onHandlerError,
  }) : assert(maxPendingPerSubscription > 0),
       _codec = codec;

  static final RegExp _topicPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9_-]*(?:\.[A-Za-z0-9][A-Za-z0-9_-]*)*$',
  );

  final int maxPendingPerSubscription;
  final QueueOverflowPolicy overflowPolicy;
  final StructuredValueCodec _codec;
  final PluginAsyncErrorHandler? onHandlerError;
  final Map<int, _EventSubscriptionState> _subscriptions = {};
  var _nextSubscriptionId = 1;
  var _closed = false;

  PluginEventSubscription subscribe({
    required String ownerId,
    required String topic,
    required PluginEventHandler handler,
  }) {
    _ensureOpen();
    _validateOwner(ownerId);
    _validateTopic(topic);
    final id = _nextSubscriptionId++;
    final state = _EventSubscriptionState(
      id: id,
      ownerId: ownerId,
      topic: topic,
      handler: handler,
      maxPending: maxPendingPerSubscription,
      overflowPolicy: overflowPolicy,
      reportError: onHandlerError,
    );
    _subscriptions[id] = state;
    return PluginEventSubscription._(
      id: id,
      ownerId: ownerId,
      topic: topic,
      cancel: () => _cancel(id),
    );
  }

  PluginPublishResult publish(
    String topic,
    StructuredValue data, {
    String? sourcePluginId,
  }) {
    _ensureOpen();
    _validateTopic(topic);
    if (sourcePluginId != null) _validateOwner(sourcePluginId);
    final event = PluginEvent(
      topic: topic,
      data: _codec.normalize(data, pluginId: sourcePluginId),
      timestamp: DateTime.now().toUtc(),
      sourcePluginId: sourcePluginId,
    );
    var matched = 0;
    var enqueued = 0;
    var dropped = 0;
    for (final state in List.of(_subscriptions.values)) {
      if (!state.active || state.topic != topic) continue;
      matched++;
      final outcome = state.enqueue(event);
      if (outcome.enqueued) enqueued++;
      if (outcome.dropped) dropped++;
    }
    return PluginPublishResult(
      matchedSubscriptions: matched,
      enqueuedDeliveries: enqueued,
      droppedDeliveries: dropped,
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

  /// Waits until all events accepted before this call have finished handling.
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
  }

  Future<void> _cancel(int id) async {
    final state = _subscriptions.remove(id);
    await state?.cancel();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('PluginEventBus is closed.');
  }

  static void _validateTopic(String topic) {
    if (topic.length > 256 || !_topicPattern.hasMatch(topic)) {
      throw ArgumentError.value(topic, 'topic', 'Invalid event topic');
    }
  }

  /// Validates a topic without publishing or registering a subscription.
  static void validateTopic(String topic) => _validateTopic(topic);

  static void _validateOwner(String ownerId) {
    if (ownerId.trim().isEmpty) {
      throw ArgumentError.value(ownerId, 'ownerId', 'Must not be empty');
    }
  }
}

final class _EnqueueOutcome {
  const _EnqueueOutcome({required this.enqueued, required this.dropped});

  final bool enqueued;
  final bool dropped;
}

final class _EventSubscriptionState {
  _EventSubscriptionState({
    required this.id,
    required this.ownerId,
    required this.topic,
    required this.handler,
    required this.maxPending,
    required this.overflowPolicy,
    required this.reportError,
  });

  final int id;
  final String ownerId;
  final String topic;
  final PluginEventHandler handler;
  final int maxPending;
  final QueueOverflowPolicy overflowPolicy;
  final PluginAsyncErrorHandler? reportError;
  final Queue<PluginEvent> _pending = Queue();
  Future<void>? _drainFuture;
  bool active = true;

  bool get isIdle => _pending.isEmpty && _drainFuture == null;
  Future<void> get whenIdle => _drainFuture ?? Future<void>.value();

  _EnqueueOutcome enqueue(PluginEvent event) {
    if (!active) {
      return const _EnqueueOutcome(enqueued: false, dropped: true);
    }
    var dropped = false;
    if (_pending.length >= maxPending) {
      dropped = true;
      if (overflowPolicy == QueueOverflowPolicy.dropNewest) {
        return const _EnqueueOutcome(enqueued: false, dropped: true);
      }
      _pending.removeFirst();
    }
    _pending.addLast(event);
    _startDrain();
    return _EnqueueOutcome(enqueued: true, dropped: dropped);
  }

  void _startDrain() {
    if (_drainFuture != null) return;
    final completer = Completer<void>();
    final future = completer.future;
    _drainFuture = future;
    _drain().then(completer.complete, onError: completer.completeError);
    unawaited(
      future.whenComplete(() {
        _drainFuture = null;
        if (active && _pending.isNotEmpty) _startDrain();
      }),
    );
  }

  Future<void> _drain() async {
    while (active && _pending.isNotEmpty) {
      final event = _pending.removeFirst();
      try {
        await handler(event);
      } catch (error, stackTrace) {
        try {
          reportError?.call(error, stackTrace, ownerId);
        } catch (_) {
          // Error reporters must not break queue isolation.
        }
      }
    }
  }

  Future<void> cancel() async {
    active = false;
    _pending.clear();
    await whenIdle;
  }
}
