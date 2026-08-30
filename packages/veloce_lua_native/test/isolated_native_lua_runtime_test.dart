import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';
import 'package:veloce_lua_native/veloce_lua_native.dart';

void main() {
  final libraryPath = _findNativeLibrary();
  final skipReason = libraryPath == null
      ? 'Build the pinned Lua shim first.'
      : false;

  test('host API calls and callbacks cross the plugin isolate boundary',
      () async {
    final fixture = await _fixture('''
local captured
function run()
  bridge.capture(function(value) return value + 1 end)
  return bridge.echo({answer = 42})
end
''');
    final capabilities = CapabilityManager()..registerPlugin(fixture.manifest);
    final api = PluginApiRegistry(capabilityManager: capabilities);
    PluginScriptCallback? callback;
    api.registerNamespace(
      PluginApiNamespace(
        name: 'bridge',
        methods: {
          'echo': PluginApiMethod(
            capability: BuiltInCapabilities.logging,
            handler: (call) => call.data(0),
          ),
          'capture': PluginApiMethod(
            capability: BuiltInCapabilities.logging,
            handler: (call) {
              callback = call.callback(0);
              return null;
            },
          ),
        },
      ),
    );
    final runtime = await IsolatedNativeLuaRuntimeFactory(
      libraryPath: libraryPath!,
    ).create(
      manifest: fixture.manifest,
      pluginDirectory: fixture.directory.path,
      generation: 'isolated-bridge',
      apiRegistry: api,
    );
    addTearDown(() async {
      await runtime.dispose();
      await fixture.close();
    });

    await runtime.loadEntrypoint();
    expect(await runtime.invokeFunction('run'), {'answer': 42});
    expect(callback, isNotNull);
    expect(await runtime.invokeCallback(callback!, arguments: const [41]), 42);
  }, skip: skipReason);

  test('runaway Lua does not stall the host isolate', () async {
    final fixture = await _fixture('''
function runaway()
  while true do end
end
''');
    final capabilities = CapabilityManager()..registerPlugin(fixture.manifest);
    final api = PluginApiRegistry(capabilityManager: capabilities);
    final runtime = await IsolatedNativeLuaRuntimeFactory(
      libraryPath: libraryPath!,
      sandboxPolicy: const LuaSandboxPolicy(
        instructionLimit: 0,
        executionTimeout: Duration(milliseconds: 250),
      ),
    ).create(
      manifest: fixture.manifest,
      pluginDirectory: fixture.directory.path,
      generation: 'isolated-runaway',
      apiRegistry: api,
    );
    addTearDown(() async {
      await runtime.dispose();
      await fixture.close();
    });
    await runtime.loadEntrypoint();

    var timerFired = false;
    Timer(const Duration(milliseconds: 10), () => timerFired = true);
    final runaway = runtime.invokeFunction('runaway');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(timerFired, isTrue);
    await expectLater(
      runaway,
      throwsA(
        isA<PluginLuaException>().having(
          (error) => error.message,
          'message',
          contains('deadline exceeded'),
        ),
      ),
    );
  }, skip: skipReason);
}

String? _findNativeLibrary() {
  final override = Platform.environment['VELOCE_LUA_LIBRARY'];
  if (override != null && File(override).existsSync()) return override;
  final root = Directory.current.uri.resolve('../../');
  final candidates = Platform.isWindows
      ? [File.fromUri(root.resolve('build/native/Debug/veloce_lua_native.dll'))]
      : [File.fromUri(root.resolve('build/native/libveloce_lua_native.so'))];
  return candidates.where((file) => file.existsSync()).firstOrNull?.path;
}

final class _Fixture {
  const _Fixture(this.directory, this.manifest);

  final Directory directory;
  final PluginManifest manifest;

  Future<void> close() => directory.delete(recursive: true);
}

Future<_Fixture> _fixture(String source) async {
  final directory = await Directory.systemTemp.createTemp('veloce-isolate-');
  await File.fromUri(directory.uri.resolve('main.lua')).writeAsString(source);
  return _Fixture(
    directory,
    PluginManifestParser().parseMap({
      'id': 'dev.test.isolated',
      'name': 'Isolated test plugin',
      'version': '1.0.0',
      'apiVersion': '1',
      'entrypoint': 'main.lua',
      'permissions': ['logging'],
    }),
  );
}
