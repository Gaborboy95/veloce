import 'dart:async';

import '../callbacks/plugin_callback_registry.dart';
import '../can/can_models.dart';
import '../can/can_provider.dart';
import '../events/plugin_event_bus.dart';
import '../logging/plugin_log.dart';
import '../manifest/plugin_manifest.dart';
import '../runtime/plugin_script_runtime.dart';
import '../storage/plugin_storage.dart';
import '../timers/plugin_timer_registry.dart';
import '../ui/plugin_ui_registry.dart';
import '../values/structured_value.dart';
import '../vehicle/vehicle_data_bus.dart';

/// Resources owned by one candidate/running script generation.
///
/// This type is public only so the built-in API controller can live in a
/// separate library. It is not exported from the package barrel.
final class PluginGenerationScope {
  PluginGenerationScope({
    required this.manifest,
    required this.generation,
    required this.eventBus,
    required this.vehicleDataBus,
    required this.canProvider,
    required this.uiRegistry,
    required this.storage,
    required Map<String, StructuredValue> storageSnapshot,
    required this.logger,
    this.canAuthorizationPolicy,
  }) : _storageValues = Map.of(storageSnapshot);

  final PluginManifest manifest;
  final String generation;
  final PluginEventBus eventBus;
  final VehicleDataBus vehicleDataBus;
  final CanProvider canProvider;
  final CanAuthorizationPolicy? canAuthorizationPolicy;
  final PluginUiRegistry uiRegistry;
  final PluginStorage storage;
  final PluginLogger logger;

  final List<PluginEventSubscription> _eventSubscriptions = [];
  final List<VehicleDataSubscription> _vehicleSubscriptions = [];
  final List<CanSubscription> _canSubscriptions = [];
  final List<Future<void>> _pendingResources = [];
  final List<void Function()> _deferredPublications = [];
  final Map<String, PluginTab> _tabs = {};
  final Map<int, PluginCallbackRef> _callbacks = {};
  final Map<String, StructuredValue> _storageValues;
  final Map<int, _TimerSpec> _timerSpecs = {};
  final Map<int, PluginTimerHandle> _timerHandles = {};

  PluginScriptRuntime? _runtime;
  PluginTimerRegistry? _timers;
  Future<void> _storageTail = Future<void>.value();
  var _nextCallbackToken = 1;
  var _nextTimerToken = 1;
  var _active = false;
  var _tearingDown = false;
  var _disposed = false;
  var _storageDirty = false;

  String get pluginId => manifest.id;
  bool get isActive => _active && !_tearingDown && !_disposed;
  bool get isStaging => !_active && !_tearingDown && !_disposed;
  bool get isTearingDown => _tearingDown;
  Iterable<PluginTab> get tabs => _tabs.values;

  void attachRuntime(PluginScriptRuntime runtime) {
    if (_runtime != null) throw StateError('Runtime is already attached.');
    if (runtime.manifest.id != pluginId || runtime.generation != generation) {
      throw ArgumentError('Runtime does not belong to this generation.');
    }
    _runtime = runtime;
  }

  Future<void> prepare() async {
    while (_pendingResources.isNotEmpty) {
      final batch = List<Future<void>>.of(_pendingResources);
      _pendingResources.clear();
      await Future.wait(batch);
    }
  }

  void activate() {
    _ensureUsable();
    if (_active) return;
    _active = true;
    uiRegistry.replacePluginTabs(pluginId, _tabs.values);
    _timers = _createTimerRegistry();
    for (final entry in _timerSpecs.entries) {
      _timerHandles[entry.key] = _startTimer(entry.value);
    }
    final publications = List<void Function()>.of(_deferredPublications);
    _deferredPublications.clear();
    for (final publish in publications) {
      scheduleMicrotask(() {
        if (isActive) publish();
      });
    }
    _scheduleStorageFlush();
  }

  /// Stops all routing synchronously before an old generation is drained.
  void stopRouting() {
    _active = false;
    unawaited(_timers?.dispose());
    _timers = null;
    _timerHandles.clear();
  }

  void beginTeardown() {
    stopRouting();
    _tearingDown = true;
  }

  int retainCallback(PluginScriptCallback callback) {
    _ensureMutable();
    if (callback.pluginId != pluginId || callback.generation != generation) {
      throw ArgumentError('Callback belongs to another plugin generation.');
    }
    final reference = PluginCallbackRef(
      pluginId: callback.pluginId,
      generation: callback.generation,
      callbackId: callback.callbackId,
    );
    for (final entry in _callbacks.entries) {
      if (entry.value == reference) return entry.key;
    }
    final token = _nextCallbackToken++;
    _callbacks[token] = reference;
    return token;
  }

  PluginCallbackRef resolveCallback(int token) {
    final callback = _callbacks[token];
    if (callback == null) {
      throw StateError('Unknown callback token $token.');
    }
    return callback;
  }

  Future<StructuredValue> invokeCallback(
    PluginScriptCallback callback,
    List<StructuredValue> arguments,
  ) async {
    if (!isActive) return null;
    final runtime = _runtime;
    if (runtime == null || runtime.isDisposed) return null;
    try {
      return await runtime.invokeCallback(callback, arguments: arguments);
    } catch (error) {
      logger.error('Callback failed: $error');
      rethrow;
    }
  }

  int subscribeEvent(String topic, PluginScriptCallback callback) {
    _ensureMutable();
    final subscription = eventBus.subscribe(
      ownerId: pluginId,
      topic: topic,
      handler: (event) => Future<void>.microtask(() async {
        if (isActive) await invokeCallback(callback, [event.data]);
      }),
    );
    _eventSubscriptions.add(subscription);
    return subscription.id;
  }

  Map<String, Object?> publishEvent(String topic, StructuredValue value) {
    _ensureMutable();
    PluginEventBus.validateTopic(topic);
    if (!_active) {
      _deferredPublications.add(
        () => eventBus.publish(topic, value, sourcePluginId: pluginId),
      );
      return const {'matched': 0, 'enqueued': 0, 'dropped': 0, 'staged': true};
    }
    final result = eventBus.publish(topic, value, sourcePluginId: pluginId);
    return {
      'matched': result.matchedSubscriptions,
      'enqueued': result.enqueuedDeliveries,
      'dropped': result.droppedDeliveries,
    };
  }

  int subscribeVehicle(String key, PluginScriptCallback callback) {
    _ensureMutable();
    final subscription = vehicleDataBus.subscribe(
      ownerId: pluginId,
      key: key,
      emitCurrent: true,
      handler: (point) => Future<void>.microtask(() async {
        if (isActive) await invokeCallback(callback, [point.value]);
      }),
    );
    _vehicleSubscriptions.add(subscription);
    return subscription.id;
  }

  Map<String, Object?> publishVehicle(String key, StructuredValue value) {
    _ensureMutable();
    VehicleDataBus.validateKey(key);
    if (!_active) {
      _deferredPublications.add(
        () => vehicleDataBus.publish(key, value, sourcePluginId: pluginId),
      );
      return const {'subscribers': 0, 'coalesced': 0, 'staged': true};
    }
    final result = vehicleDataBus.publish(key, value, sourcePluginId: pluginId);
    return {
      'subscribers': result.subscribers,
      'coalesced': result.coalescedUpdates,
    };
  }

  int subscribeCan(CanFilter filter, PluginScriptCallback callback) {
    _ensureMutable();
    canAuthorizationPolicy?.requireSubscription(pluginId, filter);
    final token = _canSubscriptions.length + _pendingResources.length + 1;
    final wasActive = _active;
    final rawPending = canProvider
        .subscribe(
      ownerId: pluginId,
      filter: filter,
      onFrame: (frame) => Future<void>.microtask(() async {
        if (isActive) {
          await invokeCallback(callback, [_canFrameValue(frame)]);
        }
      }),
    )
        .then((subscription) async {
      if (_disposed) {
        await subscription.cancel();
      } else {
        _canSubscriptions.add(subscription);
      }
    });
    late final Future<void> pending;
    pending = wasActive
        ? rawPending.catchError((Object error, StackTrace stackTrace) {
            logger.error('CAN subscription failed: $error');
          })
        : rawPending;
    _pendingResources.add(pending);
    if (wasActive) {
      unawaited(pending.whenComplete(() => _pendingResources.remove(pending)));
    }
    return token;
  }

  bool sendCan(CanFrame frame) {
    _ensureMutable();
    if (!_active) {
      throw StateError(
          'CAN transmission is unavailable during initialization.');
    }
    if (!canProvider.writesEnabled) {
      throw CanWriteDisabledException(pluginId: pluginId);
    }
    canAuthorizationPolicy?.requireSend(pluginId, frame);
    unawaited(
      canProvider.send(ownerId: pluginId, frame: frame).catchError(
        (Object error, StackTrace stackTrace) {
          logger.error('CAN transmission failed: $error');
        },
      ),
    );
    return true;
  }

  void registerTab(PluginTab tab) {
    _ensureMutable();
    _tabs[tab.id] = tab;
    _publishTabsIfActive();
  }

  PluginTab? tab(String id) => _tabs[id];

  void unregisterTab(String id) {
    _ensureMutable();
    _tabs.remove(id);
    _publishTabsIfActive();
  }

  StructuredValue storageGet(String key) => _storageValues[key];

  bool storageContains(String key) => _storageValues.containsKey(key);

  bool storageSet(String key, StructuredValue value) {
    _ensureMutable();
    _storageValues[key] = value;
    _storageDirty = true;
    _scheduleStorageFlush();
    return true;
  }

  bool storageRemove(String key) {
    _ensureMutable();
    final removed = _storageValues.containsKey(key);
    _storageValues.remove(key);
    if (removed) {
      _storageDirty = true;
      _scheduleStorageFlush();
    }
    return removed;
  }

  int setTimer({
    required Duration duration,
    required bool repeating,
    required PluginScriptCallback callback,
  }) {
    _ensureMutable();
    if (duration.isNegative || duration > const Duration(days: 1)) {
      throw ArgumentError.value(
        duration,
        'duration',
        'Timer duration must be between zero and one day.',
      );
    }
    if (repeating && duration < const Duration(milliseconds: 10)) {
      throw ArgumentError.value(
        duration,
        'duration',
        'Timer intervals must be at least 10 milliseconds.',
      );
    }
    if (_timerSpecs.length >= 128) {
      throw StateError('Plugin timer limit of 128 reached.');
    }
    if (callback.pluginId != pluginId || callback.generation != generation) {
      throw ArgumentError('Timer callback belongs to another generation.');
    }
    final reference = PluginCallbackRef(
      pluginId: callback.pluginId,
      generation: callback.generation,
      callbackId: callback.callbackId,
    );
    final token = _nextTimerToken++;
    final spec = _TimerSpec(
      duration: duration,
      repeating: repeating,
      callback: reference,
    );
    _timerSpecs[token] = spec;
    if (_active) {
      _timers ??= _createTimerRegistry();
      _timerHandles[token] = _startTimer(spec);
    }
    return token;
  }

  bool clearTimer(int token) {
    _ensureMutable();
    final existed = _timerSpecs.remove(token) != null;
    final handle = _timerHandles.remove(token);
    if (handle != null) _timers?.cancel(handle);
    return existed;
  }

  Future<void> dispose({required bool removeUi}) async {
    if (_disposed) return;
    _disposed = true;
    _active = false;
    _tearingDown = true;
    await _timers?.dispose();
    _timers = null;
    await prepare();
    await Future.wait(_eventSubscriptions.map((item) => item.cancel()));
    await Future.wait(_vehicleSubscriptions.map((item) => item.cancel()));
    await Future.wait(_canSubscriptions.map((item) => item.cancel()));
    if (removeUi) uiRegistry.unregisterPlugin(pluginId);
    await flushStorage();
    _eventSubscriptions.clear();
    _vehicleSubscriptions.clear();
    _canSubscriptions.clear();
    _callbacks.clear();
    _tabs.clear();
    _timerSpecs.clear();
    _deferredPublications.clear();
  }

  Future<void> flushStorage() => _storageTail;

  PluginTimerRegistry _createTimerRegistry() => PluginTimerRegistry(
        pluginId: pluginId,
        generation: generation,
        invokeCallback: (callback, arguments) =>
            invokeCallback(callback, arguments),
        onError: (error, _, __) => logger.error('Timer failed: $error'),
      );

  PluginTimerHandle _startTimer(_TimerSpec spec) => spec.repeating
      ? _timers!.setInterval(spec.duration, spec.callback)
      : _timers!.setTimeout(spec.duration, spec.callback);

  void _publishTabsIfActive() {
    if (isActive) uiRegistry.replacePluginTabs(pluginId, _tabs.values);
  }

  void _scheduleStorageFlush() {
    if (!_active || !_storageDirty || _disposed) return;
    _storageDirty = false;
    final snapshot = Map<String, StructuredValue>.of(_storageValues);
    _storageTail = _storageTail.then((_) async {
      final current = await storage.snapshot();
      for (final key
          in current.keys.where((key) => !snapshot.containsKey(key))) {
        await storage.remove(key);
      }
      for (final entry in snapshot.entries) {
        await storage.set(entry.key, entry.value);
      }
    }).catchError((Object error, StackTrace stackTrace) {
      logger.error('Storage persistence failed: $error');
    });
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('Plugin generation is disposed.');
  }

  void _ensureMutable() {
    _ensureUsable();
    if (_tearingDown) {
      throw StateError('Plugin generation is unloading.');
    }
  }

  static Map<String, Object?> _canFrameValue(CanFrame frame) => {
        'bus': frame.bus,
        'id': frame.id,
        'data': frame.data.toList(growable: false),
        'extended': frame.extended,
        if (frame.timestampMicros != null)
          'timestamp_micros': frame.timestampMicros,
      };
}

final class _TimerSpec {
  const _TimerSpec({
    required this.duration,
    required this.repeating,
    required this.callback,
  });

  final Duration duration;
  final bool repeating;
  final PluginCallbackRef callback;
}
