import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ivi_lua_core/ivi_lua_core.dart';
import 'package:test/test.dart';

void main() {
  group('PluginManager', () {
    test('loads, runs lifecycle, and cleans owned resources on unload',
        () async {
      final root = await Directory.systemTemp.createTemp('ivi-manager-test-');
      final factory = _FakeRuntimeFactory();
      final behavior = _Behavior(
        onLoad: (runtime, _) {
          final callback = PluginCallbackRef(
            pluginId: runtime.manifest.id,
            generation: runtime.generation,
            callbackId: 1,
          );
          runtime.callApi(
            'events',
            'subscribe',
            [
              const PluginApiDataArgument('demo.event'),
              PluginApiCallbackArgument(callback),
            ],
          );
          final token = runtime.callApi(
            'ui',
            'retain_callback',
            [PluginApiCallbackArgument(callback)],
          )! as int;
          runtime.callApi(
            'ui',
            'register_tab',
            [
              PluginApiDataArgument({
                'id': 'demo',
                'title': 'Demo',
                'content': {
                  'type': 'button',
                  'text': 'Run',
                  'callback': token,
                },
              }),
            ],
          );
        },
      );
      factory.behaviors.add(behavior);
      final manager = PluginManager(
        pluginRoot: root,
        runtimeFactory: factory,
      );
      addTearDown(() async {
        await manager.close();
        await root.delete(recursive: true);
      });
      final source = _source(root, permissions: const ['events', 'ui.tabs']);

      await manager.loadPlugin(source);
      expect(manager.pluginRegistry[source.manifest.id]!.state,
          PluginState.running);
      expect(manager.uiRegistry.currentTabs.single.id, 'demo');
      expect(manager.eventBus.subscriptionCountFor(source.manifest.id), 1);

      manager.eventBus.publish('demo.event', const {'value': 1});
      await manager.eventBus.flush();
      expect(behavior.callbackInvocations, 1);

      await manager.unloadPlugin(source.manifest.id);
      expect(manager.uiRegistry.currentTabs, isEmpty);
      expect(manager.eventBus.subscriptionCountFor(source.manifest.id), 0);
      expect(behavior.onUnloadCalls, 1);
      expect(factory.created.single.isDisposed, isTrue);
      expect(
        manager.pluginRegistry[source.manifest.id]!.generation,
        isNull,
      );
    });

    test('failed transactional reload retains the running generation',
        () async {
      final root = await Directory.systemTemp.createTemp('ivi-reload-test-');
      final factory = _FakeRuntimeFactory();
      final first = _Behavior(
        onLoad: (runtime, _) => _registerTextTab(runtime, 'Working'),
      );
      final broken = _Behavior(
        onLoad: (_, __) => throw StateError('candidate exploded'),
      );
      factory.behaviors.addAll([first, broken]);
      final manager = PluginManager(
        pluginRoot: root,
        runtimeFactory: factory,
      );
      addTearDown(() async {
        await manager.close();
        await root.delete(recursive: true);
      });
      final source = _source(root, permissions: const ['ui.tabs']);
      await manager.loadPlugin(source);
      final oldGeneration =
          manager.pluginRegistry[source.manifest.id]!.generation;

      await expectLater(
        manager.loadPlugin(source),
        throwsA(isA<PluginReloadException>()),
      );

      final record = manager.pluginRegistry[source.manifest.id]!;
      expect(record.state, PluginState.running);
      expect(record.generation, oldGeneration);
      expect(record.latestError, isA<PluginReloadException>());
      expect(manager.uiRegistry.currentTabs.single.title, 'Working');
      expect(factory.created.first.isDisposed, isFalse);
      expect(factory.created.last.isDisposed, isTrue);
    });

    test('successful reload migrates structured state and drains old runtime',
        () async {
      final root = await Directory.systemTemp.createTemp('ivi-state-test-');
      final factory = _FakeRuntimeFactory();
      final first = _Behavior(savedState: const {'counter': 7});
      final second = _Behavior();
      factory.behaviors.addAll([first, second]);
      final manager = PluginManager(
        pluginRoot: root,
        runtimeFactory: factory,
      );
      addTearDown(() async {
        await manager.close();
        await root.delete(recursive: true);
      });
      final source = _source(root);

      await manager.loadPlugin(source);
      await manager.loadPlugin(source);

      expect(second.loadedState, const {'counter': 7});
      expect(first.onUnloadCalls, 1);
      expect(factory.created.first.isDisposed, isTrue);
      expect(factory.created.last.isDisposed, isFalse);
      expect(manager.pluginRegistry[source.manifest.id]!.state,
          PluginState.running);
    });

    test('CAN API accepts wildcard and multiple-ID subscription filters',
        () async {
      final root = await Directory.systemTemp.createTemp('ivi-can-api-test-');
      final factory = _FakeRuntimeFactory();
      final behavior = _Behavior(
        onLoad: (runtime, _) {
          PluginCallbackRef callback(int callbackId) => PluginCallbackRef(
                pluginId: runtime.manifest.id,
                generation: runtime.generation,
                callbackId: callbackId,
              );

          runtime.callApi(
            'can',
            'subscribe',
            [
              const PluginApiDataArgument({
                'bus': 'comfort',
                'extended': false,
              }),
              PluginApiCallbackArgument(callback(1)),
            ],
          );
          runtime.callApi(
            'can',
            'subscribe',
            [
              const PluginApiDataArgument({
                'bus': 'powertrain',
                'ids': [0x100, 0x200],
              }),
              PluginApiCallbackArgument(callback(2)),
            ],
          );
        },
      );
      factory.behaviors.add(behavior);
      final canProvider = InMemoryCanProvider();
      final manager = PluginManager(
        pluginRoot: root,
        runtimeFactory: factory,
        canProvider: canProvider,
      );
      addTearDown(() async {
        await manager.close();
        await canProvider.close();
        await root.delete(recursive: true);
      });

      await manager.loadPlugin(
        _source(root, permissions: const ['can.read']),
      );
      expect(
        canProvider
            .inject(CanFrame(bus: 'comfort', id: 0x555, data: const []))
            .matchedSubscriptions,
        1,
      );
      expect(
        canProvider
            .inject(CanFrame(bus: 'powertrain', id: 0x200, data: const []))
            .matchedSubscriptions,
        1,
      );
      expect(
        canProvider
            .inject(CanFrame(bus: 'powertrain', id: 0x201, data: const []))
            .matchedSubscriptions,
        0,
      );
      await canProvider.flush();

      expect(behavior.callbackInvocations, 2);
    });

    test('candidate API resources are rolled back when on_load fails',
        () async {
      final root = await Directory.systemTemp.createTemp('ivi-rollback-test-');
      final factory = _FakeRuntimeFactory();
      factory.behaviors.add(
        _Behavior(
          onLoad: (runtime, _) {
            runtime.callApi(
              'events',
              'subscribe',
              [
                const PluginApiDataArgument('candidate.event'),
                PluginApiCallbackArgument(
                  PluginCallbackRef(
                    pluginId: runtime.manifest.id,
                    generation: runtime.generation,
                    callbackId: 1,
                  ),
                ),
              ],
            );
            throw StateError('reject candidate');
          },
        ),
      );
      final manager = PluginManager(
        pluginRoot: root,
        runtimeFactory: factory,
      );
      addTearDown(() async {
        await manager.close();
        await root.delete(recursive: true);
      });
      final source = _source(root, permissions: const ['events']);

      await expectLater(
        manager.loadPlugin(source),
        throwsA(isA<PluginLoadException>()),
      );
      expect(manager.eventBus.subscriptionCountFor(source.manifest.id), 0);
      expect(manager.pluginRegistry[source.manifest.id]!.state,
          PluginState.failed);
      expect(factory.created.single.isDisposed, isTrue);
    });

    test('permissions are enforced inside on_load without crashing manager',
        () async {
      final root =
          await Directory.systemTemp.createTemp('ivi-permission-test-');
      final factory = _FakeRuntimeFactory();
      factory.behaviors.add(
        _Behavior(
          onLoad: (runtime, _) => runtime.callApi(
            'events',
            'publish',
            const [
              PluginApiDataArgument('not.allowed'),
              PluginApiDataArgument(null),
            ],
          ),
        ),
      );
      final manager = PluginManager(
        pluginRoot: root,
        runtimeFactory: factory,
      );
      addTearDown(() async {
        await manager.close();
        await root.delete(recursive: true);
      });
      final source = _source(root);

      await expectLater(
        manager.loadPlugin(source),
        throwsA(isA<PluginPermissionException>()),
      );
      expect(manager.pluginRegistry[source.manifest.id]!.state,
          PluginState.failed);
    });

    test('candidate permissions are generation-aware until reload commits',
        () async {
      final root = await Directory.systemTemp.createTemp('ivi-grants-test-');
      final factory = _FakeRuntimeFactory();
      final capabilities = CapabilityManager();
      factory.behaviors.add(_Behavior());
      final manager = PluginManager(
        pluginRoot: root,
        runtimeFactory: factory,
        capabilityManager: capabilities,
      );
      addTearDown(() async {
        await manager.close();
        await root.delete(recursive: true);
      });
      final original = _source(root, permissions: const ['logging']);
      await manager.loadPlugin(original);

      var activeGrantStayedUnchanged = false;
      factory.behaviors.add(
        _Behavior(
          onLoad: (runtime, _) {
            activeGrantStayedUnchanged = capabilities.isRequested(
                  runtime.manifest.id,
                  BuiltInCapabilities.logging,
                ) &&
                !capabilities.isRequested(
                  runtime.manifest.id,
                  BuiltInCapabilities.events,
                );
            runtime.callApi(
              'events',
              'publish',
              [
                const PluginApiDataArgument('demo.changed'),
                const PluginApiDataArgument({'value': 1}),
              ],
            );
          },
        ),
      );

      await manager.loadPlugin(
        _source(root, permissions: const ['events']),
      );

      expect(activeGrantStayedUnchanged, isTrue);
      expect(
        capabilities.isRequested(
          original.manifest.id,
          BuiltInCapabilities.events,
        ),
        isTrue,
      );
      expect(
        capabilities.isRequested(
          original.manifest.id,
          BuiltInCapabilities.logging,
        ),
        isFalse,
      );
    });

    test('plugin storage distinguishes a stored null from a missing key',
        () async {
      final root =
          await Directory.systemTemp.createTemp('ivi-null-store-test-');
      var removed = false;
      var absentAfterRemoval = false;
      final factory = _FakeRuntimeFactory()
        ..behaviors.add(
          _Behavior(
            onLoad: (runtime, _) {
              runtime.callApi(
                'storage',
                'set',
                const [
                  PluginApiDataArgument('nullable'),
                  PluginApiDataArgument(null),
                ],
              );
              removed = runtime.callApi(
                'storage',
                'remove',
                const [PluginApiDataArgument('nullable')],
              )! as bool;
              absentAfterRemoval = !(runtime.callApi(
                'storage',
                'contains',
                const [PluginApiDataArgument('nullable')],
              )! as bool);
            },
          ),
        );
      final manager = PluginManager(
        pluginRoot: root,
        runtimeFactory: factory,
      );
      addTearDown(() async {
        await manager.close();
        await root.delete(recursive: true);
      });

      await manager.loadPlugin(
        _source(root, permissions: const ['storage']),
      );

      expect(removed, isTrue);
      expect(absentAfterRemoval, isTrue);
    });

    test('filesystem watcher hot-reloads a changed plugin once', () async {
      final root =
          await Directory.systemTemp.createTemp('ivi-hot-reload-test-');
      final pluginDirectory =
          await Directory.fromUri(root.uri.resolve('demo/')).create();
      await File.fromUri(pluginDirectory.uri.resolve('manifest.json'))
          .writeAsString(
        jsonEncode({
          'id': 'dev.example.manager_test',
          'name': 'Manager test',
          'version': '1.0.0',
          'apiVersion': '1',
          'entrypoint': 'main.lua',
          'permissions': <String>[],
        }),
      );
      final entrypoint = File.fromUri(pluginDirectory.uri.resolve('main.lua'));
      await entrypoint.writeAsString('-- generation one\n');
      final factory = _FakeRuntimeFactory()
        ..behaviors.addAll([_Behavior(), _Behavior()]);
      final manager = PluginManager(
        pluginRoot: root,
        runtimeFactory: factory,
        watcher: PluginWatcher(
          pluginRoot: root,
          debounce: const Duration(milliseconds: 80),
        ),
      );
      addTearDown(() async {
        await manager.close();
        await root.delete(recursive: true);
      });

      await manager.discover();
      final oldGeneration = manager.currentPlugins.single.generation;
      await manager.startWatching();
      final reloaded = manager.plugins.firstWhere(
        (records) => records.single.generation != oldGeneration,
      );

      await entrypoint.writeAsString('-- generation two, partial save\n');
      await entrypoint.writeAsString('-- generation two\n');
      final records = await reloaded.timeout(const Duration(seconds: 5));
      await factory.created.first.whenDisposed.timeout(
        const Duration(seconds: 5),
      );

      expect(records.single.state, PluginState.running);
      expect(factory.created, hasLength(2));
      expect(factory.created.first.isDisposed, isTrue);
    });
  });
}

void _registerTextTab(_FakeRuntime runtime, String title) {
  runtime.callApi(
    'ui',
    'register_tab',
    [
      PluginApiDataArgument({
        'id': 'demo',
        'title': title,
        'content': {'type': 'text', 'text': title},
      }),
    ],
  );
}

PluginSource _source(
  Directory root, {
  List<String> permissions = const [],
}) {
  final manifest = PluginManifestParser().parseMap({
    'id': 'dev.example.manager_test',
    'name': 'Manager test',
    'version': '1.0.0',
    'apiVersion': '1',
    'entrypoint': 'main.lua',
    'permissions': permissions,
  });
  return PluginSource(
    manifest: manifest,
    directoryPath: root.path,
    entrypointPath: File.fromUri(root.uri.resolve('main.lua')).path,
  );
}

typedef _OnLoad = void Function(_FakeRuntime runtime, StructuredValue state);

final class _Behavior {
  _Behavior({this.onLoad, this.savedState});

  final _OnLoad? onLoad;
  final StructuredValue savedState;
  StructuredValue loadedState;
  var callbackInvocations = 0;
  var onUnloadCalls = 0;
}

final class _FakeRuntimeFactory implements PluginScriptRuntimeFactory {
  final List<_Behavior> behaviors = [];
  final List<_FakeRuntime> created = [];

  @override
  Future<PluginScriptRuntime> create({
    required PluginManifest manifest,
    required String pluginDirectory,
    required String generation,
    required PluginApiRegistry apiRegistry,
  }) async {
    if (behaviors.isEmpty) throw StateError('No fake behavior queued.');
    final runtime = _FakeRuntime(
      manifest: manifest,
      generation: generation,
      registry: apiRegistry,
      behavior: behaviors.removeAt(0),
    );
    created.add(runtime);
    return runtime;
  }
}

final class _FakeRuntime implements PluginScriptRuntime {
  _FakeRuntime({
    required this.manifest,
    required this.generation,
    required this.registry,
    required this.behavior,
  });

  @override
  final PluginManifest manifest;
  @override
  final String generation;
  final PluginApiRegistry registry;
  final _Behavior behavior;
  final Completer<void> _disposedCompleter = Completer<void>();
  var _disposed = false;

  @override
  bool get isDisposed => _disposed;
  Future<void> get whenDisposed => _disposedCompleter.future;

  StructuredValue callApi(
    String namespace,
    String method,
    List<PluginApiArgument> arguments,
  ) =>
      registry.invoke(
        PluginApiCall(
          pluginId: manifest.id,
          generation: generation,
          namespace: namespace,
          method: method,
          arguments: arguments,
        ),
      );

  @override
  Future<void> loadEntrypoint() async {}

  @override
  Future<bool> hasFunction(String name) async => switch (name) {
        'on_load' => true,
        'on_unload' => true,
        'on_save_state' => behavior.savedState != null,
        _ => false,
      };

  @override
  Future<StructuredValue> invokeFunction(
    String name, {
    List<StructuredValue> arguments = const [],
  }) async {
    switch (name) {
      case 'on_load':
        behavior.loadedState = arguments.isEmpty ? null : arguments.first;
        behavior.onLoad?.call(this, behavior.loadedState);
        return null;
      case 'on_unload':
        behavior.onUnloadCalls++;
        return null;
      case 'on_save_state':
        return behavior.savedState;
      default:
        throw StateError('Unknown fake function $name');
    }
  }

  @override
  Future<StructuredValue> invokeCallback(
    PluginScriptCallback callback, {
    List<StructuredValue> arguments = const [],
  }) async {
    if (_disposed || callback.generation != generation) {
      throw StalePluginCallbackException(
        'stale callback',
        pluginId: manifest.id,
      );
    }
    behavior.callbackInvocations++;
    return null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _disposedCompleter.complete();
  }
}
