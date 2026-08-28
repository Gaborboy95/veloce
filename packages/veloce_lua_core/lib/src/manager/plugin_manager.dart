import 'dart:async';
import 'dart:io';

import '../api/built_in_plugin_apis.dart';
import '../api/plugin_api_registry.dart';
import '../callbacks/plugin_callback_registry.dart';
import '../can/can_provider.dart';
import '../errors/plugin_exception.dart';
import '../events/plugin_event_bus.dart';
import '../loader/plugin_loader.dart';
import '../logging/plugin_log.dart';
import '../manager/plugin_generation_scope.dart';
import '../permissions/capability_manager.dart';
import '../registry/plugin_registry.dart';
import '../runtime/plugin_script_runtime.dart';
import '../runtime/plugin_state.dart';
import '../storage/plugin_storage.dart';
import '../ui/plugin_ui_registry.dart';
import '../values/structured_value.dart';
import '../vehicle/vehicle_data_bus.dart';
import '../watcher/plugin_watcher.dart';

/// Coordinates discovery, isolated runtime generations, ownership cleanup, and
/// replacement-first hot reload.
final class PluginManager {
  factory PluginManager({
    required Directory pluginRoot,
    required PluginScriptRuntimeFactory runtimeFactory,
    PluginLoader? loader,
    PluginRegistry? pluginRegistry,
    CapabilityManager? capabilityManager,
    PluginApiRegistry? apiRegistry,
    PluginEventBus? eventBus,
    VehicleDataBus? vehicleDataBus,
    CanProvider? canProvider,
    CanAuthorizationPolicy? canAuthorizationPolicy,
    PluginUiRegistry? uiRegistry,
    PluginStorageProvider? storageProvider,
    PluginLogManager? logManager,
    PluginWatcher? watcher,
  }) {
    final capabilities = apiRegistry?.capabilityManager ??
        capabilityManager ??
        CapabilityManager();
    if (apiRegistry != null &&
        capabilityManager != null &&
        !identical(apiRegistry.capabilityManager, capabilityManager)) {
      throw ArgumentError(
        'apiRegistry and capabilityManager must use the same manager.',
      );
    }
    final events = eventBus ?? PluginEventBus();
    final vehicle = vehicleDataBus ?? VehicleDataBus();
    final can = canProvider ?? InMemoryCanProvider();
    final ui = uiRegistry ?? PluginUiRegistry();
    final logs = logManager ?? PluginLogManager();
    late final PluginManager manager;
    final usesGenerationAwarePermissions = apiRegistry == null;
    final resolvedApiRegistry = apiRegistry ??
        PluginApiRegistry(
          capabilityManager: capabilities,
          permissionChecker: (call, capability) {
            final scope = manager._resolveScope(call);
            capabilities.requireFor(
              call.pluginId,
              scope.manifest.permissions,
              capability,
            );
          },
        );
    manager = PluginManager._(
      pluginRoot: pluginRoot,
      runtimeFactory: runtimeFactory,
      loader: loader ?? PluginLoader(),
      pluginRegistry: pluginRegistry ?? PluginRegistry(),
      capabilityManager: capabilities,
      apiRegistry: resolvedApiRegistry,
      eventBus: events,
      vehicleDataBus: vehicle,
      canProvider: can,
      canAuthorizationPolicy: canAuthorizationPolicy,
      uiRegistry: ui,
      storageProvider: storageProvider ?? MemoryPluginStorageProvider(),
      logManager: logs,
      watcher: watcher ?? PluginWatcher(pluginRoot: pluginRoot),
      ownsRegistry: pluginRegistry == null,
      ownsEventBus: eventBus == null,
      ownsVehicleDataBus: vehicleDataBus == null,
      ownsCanProvider: canProvider == null,
      ownsUiRegistry: uiRegistry == null,
      ownsLogManager: logManager == null,
      usesGenerationAwarePermissions: usesGenerationAwarePermissions,
    );
    return manager;
  }

  PluginManager._({
    required Directory pluginRoot,
    required this.runtimeFactory,
    required this.loader,
    required this.pluginRegistry,
    required this.capabilityManager,
    required this.apiRegistry,
    required this.eventBus,
    required this.vehicleDataBus,
    required this.canProvider,
    required this.canAuthorizationPolicy,
    required this.uiRegistry,
    required this.storageProvider,
    required this.logManager,
    required this.watcher,
    required bool ownsRegistry,
    required bool ownsEventBus,
    required bool ownsVehicleDataBus,
    required bool ownsCanProvider,
    required bool ownsUiRegistry,
    required bool ownsLogManager,
    required bool usesGenerationAwarePermissions,
  })  : pluginRoot = pluginRoot.absolute,
        _ownsRegistry = ownsRegistry,
        _ownsEventBus = ownsEventBus,
        _ownsVehicleDataBus = ownsVehicleDataBus,
        _ownsCanProvider = ownsCanProvider,
        _ownsUiRegistry = ownsUiRegistry,
        _ownsLogManager = ownsLogManager,
        _usesGenerationAwarePermissions = usesGenerationAwarePermissions {
    BuiltInPluginApis(
      registry: apiRegistry,
      resolveScope: _resolveScope,
    ).register();
  }

  final Directory pluginRoot;
  final PluginScriptRuntimeFactory runtimeFactory;
  final PluginLoader loader;
  final PluginRegistry pluginRegistry;
  final CapabilityManager capabilityManager;
  final PluginApiRegistry apiRegistry;
  final PluginEventBus eventBus;
  final VehicleDataBus vehicleDataBus;
  final CanProvider canProvider;
  final CanAuthorizationPolicy? canAuthorizationPolicy;
  final PluginUiRegistry uiRegistry;
  final PluginStorageProvider storageProvider;
  final PluginLogManager logManager;
  final PluginWatcher watcher;

  final bool _ownsRegistry;
  final bool _ownsEventBus;
  final bool _ownsVehicleDataBus;
  final bool _ownsCanProvider;
  final bool _ownsUiRegistry;
  final bool _ownsLogManager;
  final bool _usesGenerationAwarePermissions;
  final Map<String, _LoadedPlugin> _loaded = {};
  final Map<String, PluginGenerationScope> _scopes = {};
  final Map<String, PluginSource> _sources = {};
  final Map<String, String> _pluginByDirectory = {};
  final Map<String, Future<void>> _operationTails = {};
  final StreamController<List<PluginDiscoveryFailure>> _discoveryChanges =
      StreamController.broadcast(sync: true);
  StreamSubscription<String>? _watchSubscription;
  List<PluginDiscoveryFailure> _discoveryFailures = const [];
  var _nextGeneration = 1;
  var _closed = false;

  Stream<List<PluginRecord>> get plugins => pluginRegistry.records;
  List<PluginRecord> get currentPlugins => pluginRegistry.current;
  List<PluginDiscoveryFailure> get discoveryFailures => _discoveryFailures;
  Stream<List<PluginDiscoveryFailure>> get discoveryErrors async* {
    yield _discoveryFailures;
    yield* _discoveryChanges.stream;
  }

  bool isLoaded(String pluginId) => _loaded.containsKey(pluginId);

  Future<PluginDiscoveryResult> discover({bool load = true}) async {
    _ensureOpen();
    final result = await loader.discover(pluginRoot);
    _discoveryFailures = result.failures;
    _discoveryChanges.add(_discoveryFailures);
    for (final source in result.plugins) {
      _rememberSource(source);
      if (!_loaded.containsKey(source.manifest.id)) {
        pluginRegistry.put(
          PluginRecord(
            directoryPath: source.directoryPath,
            manifest: source.manifest,
            state: PluginState.discovered,
            enabled: true,
          ),
        );
      }
    }
    if (load) {
      for (final source in result.plugins) {
        if (_loaded.containsKey(source.manifest.id)) continue;
        try {
          await loadPlugin(source);
        } on PluginException {
          // Each failure is already represented by PluginRegistry.
        }
      }
    }
    return result;
  }

  Future<void> loadPlugin(PluginSource source) {
    _ensureOpen();
    _rememberSource(source);
    return _serialize(source.manifest.id, () => _loadPlugin(source));
  }

  Future<void> loadPluginDirectory(Directory directory) async {
    final source = await loader.loadDirectory(directory);
    await loadPlugin(source);
  }

  Future<void> unloadPlugin(String pluginId) =>
      _serialize(pluginId, () => _unloadPlugin(pluginId));

  Future<void> reloadPlugin(String pluginId) {
    _ensureOpen();
    return _serialize(pluginId, () async {
      final source = _sources[pluginId];
      if (source == null) {
        throw PluginReloadException(
          'No discovered source directory is known for this plugin.',
          pluginId: pluginId,
        );
      }
      final refreshed =
          await loader.loadDirectory(Directory(source.directoryPath));
      if (refreshed.manifest.id != pluginId) {
        throw PluginReloadException(
          'A plugin ID cannot change during reload.',
          pluginId: pluginId,
        );
      }
      _rememberSource(refreshed);
      await _reloadPlugin(refreshed);
    });
  }

  Future<void> setEnabled(String pluginId, bool enabled) =>
      _serialize(pluginId, () async {
        final record = pluginRegistry[pluginId];
        if (record == null) throw StateError('Unknown plugin $pluginId.');
        if (record.enabled == enabled) return;
        pluginRegistry.update(
          pluginId,
          (value) => value.copyWith(enabled: enabled),
        );
        if (!enabled) {
          await _unloadPlugin(pluginId, finalState: PluginState.disabled);
        } else {
          final source = _sources[pluginId];
          if (source == null) {
            throw PluginLoadException(
              'No source directory is known for this plugin.',
              pluginId: pluginId,
            );
          }
          await _loadPlugin(source);
        }
      });

  Future<void> startWatching() async {
    _ensureOpen();
    if (_watchSubscription != null) return;
    await watcher.start();
    _watchSubscription = watcher.changes.listen(
      (directory) => unawaited(_handleDirectoryChange(directory)),
      onError: (Object error, StackTrace stackTrace) {
        _discoveryFailures = [
          ..._discoveryFailures,
          PluginDiscoveryFailure(
            directoryPath: pluginRoot.path,
            error: PluginManifestException(
              'Plugin watcher failed.',
              cause: error,
              causeStackTrace: stackTrace,
            ),
          ),
        ];
        _discoveryChanges.add(_discoveryFailures);
      },
    );
  }

  /// Entry point used by Flutter controls. Generation validation fails closed.
  Future<void> invokeCallback(
    PluginCallbackRef callback,
    List<StructuredValue> arguments,
  ) async {
    final scope = _scopes[_scopeKey(callback.pluginId, callback.generation)];
    if (scope == null || !scope.isActive) {
      throw StalePluginCallbackException(
        'Callback $callback belongs to an inactive plugin generation.',
        pluginId: callback.pluginId,
      );
    }
    await scope.invokeCallback(callback, arguments);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _watchSubscription?.cancel();
    _watchSubscription = null;
    for (final pluginId in _loaded.keys.toList(growable: false)) {
      try {
        await _unloadPlugin(pluginId);
      } on Object {
        // Continue draining other plugin generations.
      }
    }
    await watcher.close();
    await _discoveryChanges.close();
    if (_ownsRegistry) await pluginRegistry.close();
    if (_ownsUiRegistry) await uiRegistry.close();
    if (_ownsEventBus) await eventBus.close();
    if (_ownsVehicleDataBus) await vehicleDataBus.close();
    if (_ownsCanProvider) await canProvider.close();
    if (_ownsLogManager) await logManager.close();
  }

  Future<void> _loadPlugin(PluginSource source) async {
    final pluginId = source.manifest.id;
    if (_loaded.containsKey(pluginId)) {
      await _reloadPlugin(source);
      return;
    }
    pluginRegistry.put(
      PluginRecord(
        directoryPath: source.directoryPath,
        manifest: source.manifest,
        state: PluginState.loading,
        enabled: true,
      ),
    );
    if (!_usesGenerationAwarePermissions) {
      capabilityManager.registerPlugin(source.manifest, replace: true);
    }
    _Candidate? candidate;
    try {
      candidate = await _buildCandidate(source, previousState: null);
      candidate.scope.activate();
      capabilityManager.registerPlugin(source.manifest, replace: true);
      _loaded[pluginId] = _LoadedPlugin(
        source: source,
        runtime: candidate.runtime,
        scope: candidate.scope,
      );
      pluginRegistry.put(
        PluginRecord(
          directoryPath: source.directoryPath,
          manifest: source.manifest,
          state: PluginState.running,
          enabled: true,
          generation: candidate.runtime.generation,
        ),
      );
    } on Object catch (error, stackTrace) {
      if (candidate != null) await _discardCandidate(candidate);
      capabilityManager.unregisterPlugin(pluginId);
      final failure = _asLoadException(pluginId, error, stackTrace);
      logManager.logger(pluginId).error(_diagnostic(failure));
      pluginRegistry.put(
        PluginRecord(
          directoryPath: source.directoryPath,
          manifest: source.manifest,
          state: PluginState.failed,
          enabled: true,
          latestError: failure,
        ),
      );
      throw failure;
    }
  }

  Future<void> _reloadPlugin(PluginSource source) async {
    final pluginId = source.manifest.id;
    final current = _loaded[pluginId];
    if (current == null) {
      await _loadPlugin(source);
      return;
    }
    pluginRegistry.update(
      pluginId,
      (record) => record.copyWith(state: PluginState.reloading),
    );

    StructuredValue savedState;
    PluginException? migrationError;
    try {
      savedState = await current.runtime.hasFunction('on_save_state')
          ? await current.runtime.invokeFunction('on_save_state')
          : null;
    } on Object catch (error, stackTrace) {
      savedState = null;
      migrationError = PluginReloadException(
        'State migration was skipped because on_save_state failed.',
        pluginId: pluginId,
        cause: error,
        causeStackTrace: stackTrace,
        luaStackTrace: _luaStackTrace(error),
      );
      current.scope.logger.warning(migrationError);
    }

    final oldManifest = current.source.manifest;
    if (!_usesGenerationAwarePermissions) {
      capabilityManager.registerPlugin(source.manifest, replace: true);
    }
    _Candidate? candidate;
    try {
      candidate = await _buildCandidate(source, previousState: savedState);
      candidate.scope.activate();
    } on Object catch (error, stackTrace) {
      if (candidate != null) await _discardCandidate(candidate);
      if (!_usesGenerationAwarePermissions) {
        capabilityManager.registerPlugin(oldManifest, replace: true);
      }
      final failure = PluginReloadException(
        'Transactional reload failed; the previous generation is still active.',
        pluginId: pluginId,
        filename: error is PluginException ? error.filename : null,
        line: error is PluginException ? error.line : null,
        cause: error,
        causeStackTrace: stackTrace,
        luaStackTrace: _luaStackTrace(error),
      );
      current.scope.logger.error(_diagnostic(failure));
      pluginRegistry.put(
        PluginRecord(
          directoryPath: current.source.directoryPath,
          manifest: current.source.manifest,
          state: PluginState.running,
          enabled: true,
          generation: current.runtime.generation,
          latestError: failure,
        ),
      );
      throw failure;
    }

    // No async gap exists in this commit section. Deferred callbacks cannot
    // observe both generations as active.
    current.scope.stopRouting();
    capabilityManager.registerPlugin(source.manifest, replace: true);
    _loaded[pluginId] = _LoadedPlugin(
      source: source,
      runtime: candidate.runtime,
      scope: candidate.scope,
    );
    pluginRegistry.put(
      PluginRecord(
        directoryPath: source.directoryPath,
        manifest: source.manifest,
        state: PluginState.running,
        enabled: true,
        generation: candidate.runtime.generation,
        latestError: migrationError,
      ),
    );

    try {
      await _drainOldGeneration(current, removeUi: false);
    } on Object catch (error, stackTrace) {
      final cleanupError = PluginReloadException(
        'The replacement is running, but the old generation reported a cleanup error.',
        pluginId: pluginId,
        cause: error,
        causeStackTrace: stackTrace,
        luaStackTrace: _luaStackTrace(error),
      );
      candidate.scope.logger.warning(cleanupError);
      pluginRegistry.update(
        pluginId,
        (record) => record.copyWith(latestError: cleanupError),
      );
    }
  }

  Future<_Candidate> _buildCandidate(
    PluginSource source, {
    required StructuredValue previousState,
  }) async {
    final pluginId = source.manifest.id;
    final generation =
        '${DateTime.now().microsecondsSinceEpoch}-${_nextGeneration++}';
    final storage = await storageProvider.open(pluginId);
    final scope = PluginGenerationScope(
      manifest: source.manifest,
      generation: generation,
      eventBus: eventBus,
      vehicleDataBus: vehicleDataBus,
      canProvider: canProvider,
      canAuthorizationPolicy: canAuthorizationPolicy,
      uiRegistry: uiRegistry,
      storage: storage,
      storageSnapshot: await storage.snapshot(),
      logger: logManager.logger(pluginId),
    );
    PluginScriptRuntime? runtime;
    try {
      runtime = await runtimeFactory.create(
        manifest: source.manifest,
        pluginDirectory: source.directoryPath,
        generation: generation,
        apiRegistry: apiRegistry,
      );
      scope.attachRuntime(runtime);
      _scopes[_scopeKey(pluginId, generation)] = scope;
      await runtime.loadEntrypoint();
      if (await runtime.hasFunction('on_load')) {
        await runtime.invokeFunction('on_load', arguments: [previousState]);
      }
      await scope.prepare();
      return _Candidate(runtime: runtime, scope: scope);
    } on Object {
      _scopes.remove(_scopeKey(pluginId, generation));
      await scope.dispose(removeUi: false);
      await runtime?.dispose();
      rethrow;
    }
  }

  Future<void> _unloadPlugin(
    String pluginId, {
    PluginState finalState = PluginState.discovered,
  }) async {
    final loaded = _loaded.remove(pluginId);
    if (loaded == null) {
      final record = pluginRegistry[pluginId];
      if (record != null && finalState == PluginState.disabled) {
        pluginRegistry.update(
          pluginId,
          (value) => value.copyWith(state: finalState, enabled: false),
        );
      }
      return;
    }
    pluginRegistry.update(
      pluginId,
      (record) => record.copyWith(state: PluginState.unloading),
    );
    loaded.scope.stopRouting();
    uiRegistry.unregisterPlugin(pluginId);
    PluginException? unloadError;
    try {
      await _drainOldGeneration(loaded, removeUi: false);
    } on Object catch (error, stackTrace) {
      unloadError = error is PluginException
          ? error
          : PluginLoadException(
              'Plugin cleanup failed.',
              pluginId: pluginId,
              phase: PluginLifecyclePhase.unloading,
              cause: error,
              causeStackTrace: stackTrace,
            );
    } finally {
      capabilityManager.unregisterPlugin(pluginId);
      final record = pluginRegistry[pluginId];
      if (record != null) {
        pluginRegistry.update(
          pluginId,
          (value) => value.copyWith(
            state: finalState,
            enabled: finalState != PluginState.disabled && value.enabled,
            latestError: unloadError,
            clearError: unloadError == null,
            clearGeneration: true,
          ),
        );
      }
    }
    if (unloadError != null) throw unloadError;
  }

  Future<void> _drainOldGeneration(
    _LoadedPlugin loaded, {
    required bool removeUi,
  }) async {
    loaded.scope.beginTeardown();
    Object? lifecycleError;
    StackTrace? lifecycleStack;
    try {
      if (await loaded.runtime.hasFunction('on_unload')) {
        await loaded.runtime.invokeFunction('on_unload');
      }
    } on Object catch (error, stackTrace) {
      lifecycleError = error;
      lifecycleStack = stackTrace;
      loaded.scope.logger.error('on_unload failed: $error');
    }
    await loaded.scope.dispose(removeUi: removeUi);
    _scopes.remove(
      _scopeKey(loaded.runtime.manifest.id, loaded.runtime.generation),
    );
    await loaded.runtime.dispose();
    if (lifecycleError != null) {
      if (lifecycleError is PluginException) throw lifecycleError;
      Error.throwWithStackTrace(lifecycleError, lifecycleStack!);
    }
  }

  Future<void> _discardCandidate(_Candidate candidate) async {
    _scopes.remove(
      _scopeKey(candidate.runtime.manifest.id, candidate.runtime.generation),
    );
    await candidate.scope.dispose(removeUi: false);
    await candidate.runtime.dispose();
  }

  PluginGenerationScope _resolveScope(PluginApiCall call) {
    final scope = _scopes[_scopeKey(call.pluginId, call.generation)];
    if (scope == null) {
      throw StalePluginCallbackException(
        'Host API call belongs to an inactive plugin generation.',
        pluginId: call.pluginId,
      );
    }
    return scope;
  }

  Future<void> _handleDirectoryChange(String directoryPath) async {
    final normalized = _normalizeDirectory(directoryPath);
    final knownPluginId = _pluginByDirectory[normalized];
    try {
      final source = await loader.loadDirectory(Directory(directoryPath));
      if (knownPluginId != null && source.manifest.id != knownPluginId) {
        throw PluginReloadException(
          'A plugin ID cannot change during hot reload.',
          pluginId: knownPluginId,
        );
      }
      final existingSource = _sources[source.manifest.id];
      if (existingSource != null &&
          _normalizeDirectory(existingSource.directoryPath) != normalized) {
        throw PluginManifestException(
          'Duplicate plugin ID "${source.manifest.id}".',
          pluginId: source.manifest.id,
        );
      }
      _rememberSource(source);
      if (_loaded.containsKey(source.manifest.id)) {
        await reloadPlugin(source.manifest.id);
      } else {
        await loadPlugin(source);
      }
    } on Object catch (error, stackTrace) {
      if (knownPluginId != null && pluginRegistry[knownPluginId] != null) {
        final failure = error is PluginException
            ? error
            : PluginReloadException(
                'Hot reload discovery failed.',
                pluginId: knownPluginId,
                cause: error,
                causeStackTrace: stackTrace,
              );
        _loaded[knownPluginId]?.scope.logger.error(_diagnostic(failure));
        pluginRegistry.update(
          knownPluginId,
          (record) => record.copyWith(
            state: _loaded.containsKey(knownPluginId)
                ? PluginState.running
                : PluginState.failed,
            latestError: failure,
          ),
        );
      } else {
        _discoveryFailures = [
          ..._discoveryFailures,
          PluginDiscoveryFailure(
            directoryPath: directoryPath,
            error: error is PluginException
                ? error
                : PluginManifestException(
                    'Hot reload discovery failed.',
                    cause: error,
                    causeStackTrace: stackTrace,
                  ),
          ),
        ];
        _discoveryChanges.add(_discoveryFailures);
      }
    }
  }

  Future<void> _serialize(String pluginId, Future<void> Function() operation) {
    final previous = _operationTails[pluginId] ?? Future<void>.value();
    final completer = Completer<void>();
    final next = previous.then((_) => operation()).then(
          completer.complete,
          onError: completer.completeError,
        );
    late final Future<void> tail;
    tail = next.whenComplete(() {
      if (identical(_operationTails[pluginId], tail)) {
        _operationTails.remove(pluginId);
      }
    });
    _operationTails[pluginId] = tail;
    return completer.future;
  }

  void _rememberSource(PluginSource source) {
    _sources[source.manifest.id] = source;
    _pluginByDirectory[_normalizeDirectory(source.directoryPath)] =
        source.manifest.id;
  }

  static String _scopeKey(String pluginId, String generation) =>
      '$pluginId\u0000$generation';

  static String _normalizeDirectory(String value) {
    final absolute = Directory(value).absolute.path;
    return Platform.isWindows ? absolute.toLowerCase() : absolute;
  }

  static PluginException _asLoadException(
    String pluginId,
    Object error,
    StackTrace stackTrace,
  ) =>
      error is PluginException
          ? error
          : PluginLoadException(
              'Plugin load failed.',
              pluginId: pluginId,
              cause: error,
              causeStackTrace: stackTrace,
            );

  static String? _luaStackTrace(Object error) => switch (error) {
        PluginLuaException() => error.luaStackTrace,
        PluginReloadException() => error.luaStackTrace,
        PluginException() when error.cause != null =>
          _luaStackTrace(error.cause!),
        _ => null,
      };

  static String _diagnostic(PluginException error) {
    final trace = _luaStackTrace(error);
    return trace == null ? error.toString() : '${error.toString()}\n$trace';
  }

  void _ensureOpen() {
    if (_closed) throw StateError('PluginManager is closed.');
  }
}

final class _Candidate {
  const _Candidate({required this.runtime, required this.scope});

  final PluginScriptRuntime runtime;
  final PluginGenerationScope scope;
}

final class _LoadedPlugin {
  const _LoadedPlugin({
    required this.source,
    required this.runtime,
    required this.scope,
  });

  final PluginSource source;
  final PluginScriptRuntime runtime;
  final PluginGenerationScope scope;
}
