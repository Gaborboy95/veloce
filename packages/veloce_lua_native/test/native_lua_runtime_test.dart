import 'dart:io';

import 'package:veloce_lua_core/veloce_lua_core.dart';
import 'package:veloce_lua_native/veloce_lua_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final libraryPath = _findNativeLibrary();
  final skipReason = libraryPath == null
      ? 'Build the pinned Lua shim first (see packages/veloce_lua_native/README.md).'
      : false;

  group('NativeLuaRuntime', () {
    test('loads Lua 5.4 and keeps plugin states independent', () async {
      final fixtureA = await _fixture(
        'counter = 10\nfunction value() return counter end',
      );
      final fixtureB = await _fixture(
        'counter = 20\nfunction value() return counter end',
      );
      final hostA = _host(fixtureA.manifest, libraryPath!);
      final hostB = _host(fixtureB.manifest, libraryPath);
      final runtimeA = await hostA.createRuntime(fixtureA.directory.path, 'a');
      final runtimeB = await hostB.createRuntime(fixtureB.directory.path, 'b');
      addTearDown(() async {
        await runtimeA.dispose();
        await runtimeB.dispose();
        await fixtureA.close();
        await fixtureB.close();
      });

      await runtimeA.loadEntrypoint();
      await runtimeB.loadEntrypoint();
      expect(await runtimeA.invokeFunction('value'), 10);
      expect(await runtimeB.invokeFunction('value'), 20);
      expect(hostA.factory.luaVersion, 'Lua 5.4.9');
    }, skip: skipReason);

    test(
      'reports syntax filename and line without terminating the host',
      () async {
        final fixture = await _fixture('function broken(\n  return 1\nend');
        final host = _host(fixture.manifest, libraryPath!);
        final runtime = await host.createRuntime(
          fixture.directory.path,
          'syntax',
        );
        addTearDown(() async {
          await runtime.dispose();
          await fixture.close();
        });

        await expectLater(
          runtime.loadEntrypoint(),
          throwsA(
            isA<PluginLuaException>()
                .having(
                  (error) => error.filename,
                  'filename',
                  contains('main.lua'),
                )
                .having((error) => error.line, 'line', isNotNull)
                .having(
                  (error) => error.phase,
                  'phase',
                  PluginLifecyclePhase.loading,
                ),
          ),
        );
      },
      skip: skipReason,
    );

    test('surfaces on_load failures with a Lua traceback', () async {
      final fixture = await _fixture('''
function on_load()
  error("initialization exploded")
end
''');
      final host = _host(fixture.manifest, libraryPath!);
      final runtime = await host.createRuntime(
        fixture.directory.path,
        'load-error',
      );
      addTearDown(() async {
        await runtime.dispose();
        await fixture.close();
      });
      await runtime.loadEntrypoint();

      await expectLater(
        runtime.invokeFunction('on_load'),
        throwsA(
          isA<PluginLuaException>()
              .having(
                (error) => error.phase,
                'phase',
                PluginLifecyclePhase.initialization,
              )
              .having(
                (error) => error.luaStackTrace,
                'traceback',
                contains('stack traceback'),
              ),
        ),
      );
    }, skip: skipReason);

    test('registers custom namespaces and safely round-trips values', () async {
      final fixture = await _fixture('''
function round_trip()
  return test_api.echo({answer = 42, values = {1, 2, 3}})
end
''');
      final host = _host(fixture.manifest, libraryPath!);
      host.registry.registerNamespace(
        PluginApiNamespace(
          name: 'test_api',
          methods: {
            'echo': PluginApiMethod(
              capability: BuiltInCapabilities.logging,
              handler: (call) {
                call.requireArgumentCount(1);
                return call.data(0);
              },
            ),
          },
        ),
      );
      final runtime = await host.createRuntime(
        fixture.directory.path,
        'namespace',
      );
      addTearDown(() async {
        await runtime.dispose();
        await fixture.close();
      });
      await runtime.loadEntrypoint();

      expect(await runtime.invokeFunction('round_trip'), {
        'answer': 42,
        'values': [1, 2, 3],
      });
    }, skip: skipReason);

    test(
      'retains callbacks without exposing native pointers and rejects stale use',
      () async {
        final fixture = await _fixture('''
function on_load()
  callback_api.capture(function(value) return value + 1 end)
end
''');
        final host = _host(fixture.manifest, libraryPath!);
        PluginScriptCallback? captured;
        host.registry.registerNamespace(
          PluginApiNamespace(
            name: 'callback_api',
            methods: {
              'capture': PluginApiMethod(
                capability: BuiltInCapabilities.logging,
                handler: (call) {
                  call.requireArgumentCount(1);
                  captured = call.callback(0);
                  return null;
                },
              ),
            },
          ),
        );
        final runtime = await host.createRuntime(
          fixture.directory.path,
          'callbacks',
        );
        addTearDown(() async {
          if (!runtime.isDisposed) await runtime.dispose();
          await fixture.close();
        });
        await runtime.loadEntrypoint();
        await runtime.invokeFunction('on_load');

        expect(captured, isNotNull);
        expect(
          await runtime.invokeCallback(captured!, arguments: const [41]),
          42,
        );
        await runtime.dispose();
        await expectLater(
          runtime.invokeCallback(captured!, arguments: const [1]),
          throwsA(isA<StalePluginCallbackException>()),
        );
      },
      skip: skipReason,
    );

    test('enforces permissions at the Dart API boundary', () async {
      final fixture = await _fixture(
        'function call_host() return denied_api.read() end',
        permissions: const [],
      );
      final host = _host(fixture.manifest, libraryPath!);
      host.registry.registerNamespace(
        PluginApiNamespace(
          name: 'denied_api',
          methods: {
            'read': PluginApiMethod(
              capability: BuiltInCapabilities.vehicleRead,
              handler: (_) => 123,
            ),
          },
        ),
      );
      final runtime = await host.createRuntime(
        fixture.directory.path,
        'permission',
      );
      addTearDown(() async {
        await runtime.dispose();
        await fixture.close();
      });
      await runtime.loadEntrypoint();

      await expectLater(
        runtime.invokeFunction('call_host'),
        throwsA(
          isA<PluginLuaException>().having(
            (error) => error.message,
            'message',
            contains('did not request capability'),
          ),
        ),
      );
    }, skip: skipReason);

    test(
      'removes dangerous libraries and terminates runaway scripts',
      () async {
        final fixture = await _fixture('''
function sandboxed()
  return io == nil and os == nil and debug == nil and package == nil and
    print == nil and load == nil and loadfile == nil and dofile == nil
end
function runaway()
  while true do end
end
''');
        final host = _host(
          fixture.manifest,
          libraryPath!,
          policy: const LuaSandboxPolicy(
            instructionLimit: 10000,
            executionTimeout: Duration(milliseconds: 100),
          ),
        );
        final runtime = await host.createRuntime(
          fixture.directory.path,
          'budget',
        );
        addTearDown(() async {
          await runtime.dispose();
          await fixture.close();
        });
        await runtime.loadEntrypoint();

        expect(await runtime.invokeFunction('sandboxed'), isTrue);
        await expectLater(
          runtime.invokeFunction('runaway'),
          throwsA(
            isA<PluginLuaException>().having(
              (error) => error.message,
              'message',
              contains('instruction budget exceeded'),
            ),
          ),
        );
      },
      skip: skipReason,
    );
  });
}

String? _findNativeLibrary() {
  final override = Platform.environment['VELOCE_LUA_LIBRARY'];
  if (override != null && File(override).existsSync()) return override;
  final root = Directory.current.uri.resolve('../../');
  final candidates = Platform.isWindows
      ? [File.fromUri(root.resolve('build/native/Debug/veloce_lua_native.dll'))]
      : [
          File.fromUri(root.resolve('build/native/libveloce_lua_native.so')),
          File.fromUri(
            root.resolve('build/native/Debug/libveloce_lua_native.so'),
          ),
        ];
  return candidates.where((file) => file.existsSync()).firstOrNull?.path;
}

final class _Host {
  _Host({
    required this.factory,
    required this.manifest,
    required this.capabilities,
    required this.registry,
  });

  final NativeLuaRuntimeFactory factory;
  final PluginManifest manifest;
  final CapabilityManager capabilities;
  final PluginApiRegistry registry;

  Future<PluginScriptRuntime> createRuntime(
    String directory,
    String generation,
  ) => factory.create(
    manifest: manifest,
    pluginDirectory: directory,
    generation: generation,
    apiRegistry: registry,
  );
}

_Host _host(
  PluginManifest manifest,
  String libraryPath, {
  LuaSandboxPolicy policy = const LuaSandboxPolicy(),
}) {
  final capabilities = CapabilityManager();
  capabilities.registerPlugin(manifest);
  final registry = PluginApiRegistry(capabilityManager: capabilities);
  return _Host(
    factory: NativeLuaRuntimeFactory(
      resolver: DefaultNativeLuaLibraryResolver(libraryPath: libraryPath),
      sandboxPolicy: policy,
    ),
    manifest: manifest,
    capabilities: capabilities,
    registry: registry,
  );
}

final class _PluginFixture {
  const _PluginFixture({required this.directory, required this.manifest});

  final Directory directory;
  final PluginManifest manifest;

  Future<void> close() => directory.delete(recursive: true);
}

Future<_PluginFixture> _fixture(
  String source, {
  List<String> permissions = const ['logging'],
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'veloce-lua-native-test-',
  );
  await File.fromUri(directory.uri.resolve('main.lua')).writeAsString(source);
  final manifest = PluginManifestParser().parseMap({
    'id': 'dev.test.plugin',
    'name': 'Native test plugin',
    'version': '1.0.0',
    'apiVersion': '1',
    'entrypoint': 'main.lua',
    'permissions': permissions,
  });
  return _PluginFixture(directory: directory, manifest: manifest);
}
