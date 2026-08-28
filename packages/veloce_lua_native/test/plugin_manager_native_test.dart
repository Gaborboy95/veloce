import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';
import 'package:veloce_lua_native/veloce_lua_native.dart';

void main() {
  final libraryPath = _findNativeLibrary();
  final repositoryRoot = Directory.current.uri.resolve('../../');
  final sourcePlugins = Directory.fromUri(repositoryRoot.resolve('plugins/'));
  final canPolicy = ConfigurableCanAuthorizationPolicy();

  test(
    'three real Lua plugins form the filtered CAN to vehicle to UI pipeline',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'veloce-native-manager-',
      );
      await _copyDirectory(sourcePlugins, temporary);
      canPolicy.setGrant(
        'dev.example.can_decoder',
        CanAccessGrant(
          readFilters: [CanFilter(bus: 'comfort', id: 0x280, mask: 0x7ff)],
        ),
      );
      final canProvider = InMemoryCanProvider();
      final manager = PluginManager(
        pluginRoot: temporary,
        runtimeFactory: NativeLuaRuntimeFactory(
          resolver: DefaultNativeLuaLibraryResolver(libraryPath: libraryPath!),
        ),
        canProvider: canProvider,
        canAuthorizationPolicy: canPolicy,
      );
      addTearDown(() async {
        await manager.close();
        await canProvider.close();
        await temporary.delete(recursive: true);
      });

      final discovery = await manager.discover();
      expect(discovery.failures, isEmpty);
      expect(manager.currentPlugins, hasLength(3));
      expect(
        manager.currentPlugins.map((record) => record.state),
        everyElement(PluginState.running),
      );
      expect(
        manager.uiRegistry.currentTabs.map((tab) => tab.id),
        containsAll(['hello', 'engine_dashboard']),
      );

      final result = canProvider.inject(
        CanFrame(bus: 'comfort', id: 0x280, data: const [0x0b, 0xb8]),
      );
      expect(result.matchedSubscriptions, 1);
      await canProvider.flush();
      await manager.vehicleDataBus.flush();
      expect(manager.vehicleDataBus.valueFor('engine.rpm')!.value, 3000);
      expect(
        _allText(_tab(manager, 'engine_dashboard').content!),
        contains('3000 RPM'),
      );

      final hello = _tab(manager, 'hello');
      final button = _findButton(hello.content!);
      await manager.invokeCallback(button.onPressed, const []);
      expect(_allText(_tab(manager, 'hello').content!), contains('Counter: 1'));

      final stale = button.onPressed;
      await manager.unloadPlugin('dev.example.hello_ui');
      expect(
        manager.uiRegistry.currentTabs.map((tab) => tab.id),
        isNot(contains('hello')),
      );
      await expectLater(
        manager.invokeCallback(stale, const []),
        throwsA(isA<StalePluginCallbackException>()),
      );

      final decoderGeneration =
          manager.pluginRegistry['dev.example.can_decoder']!.generation!;
      expect(
        () => manager.apiRegistry.invoke(
          PluginApiCall(
            pluginId: 'dev.example.can_decoder',
            generation: decoderGeneration,
            namespace: 'can',
            method: 'send',
            arguments: const [
              PluginApiDataArgument({
                'bus': 'comfort',
                'id': 0x500,
                'data': [1, 2, 3],
              }),
            ],
          ),
        ),
        throwsA(isA<PluginPermissionException>()),
      );

      await manager.unloadPlugin('dev.example.can_decoder');
      final afterUnload = canProvider.inject(
        CanFrame(bus: 'comfort', id: 0x280, data: const [0, 1]),
      );
      expect(afterUnload.matchedSubscriptions, 0);

      final dashboardRecord =
          manager.pluginRegistry['dev.example.vehicle_dashboard']!;
      final dashboardGeneration = dashboardRecord.generation;
      final dashboardFile = File.fromUri(
        temporary.uri.resolve('vehicle_dashboard/main.lua'),
      );
      await dashboardFile.writeAsString('function on_load( this is invalid');
      await expectLater(
        manager.reloadPlugin('dev.example.vehicle_dashboard'),
        throwsA(isA<PluginReloadException>()),
      );
      expect(
        manager.pluginRegistry['dev.example.vehicle_dashboard']!.generation,
        dashboardGeneration,
      );
      final reloadError =
          manager.pluginRegistry['dev.example.vehicle_dashboard']!.latestError!
              as PluginReloadException;
      expect(reloadError.phase, PluginLifecyclePhase.reloading);
      expect(reloadError.filename, endsWith('main.lua'));
      expect(reloadError.line, 1);
      expect(reloadError.luaStackTrace, contains('main.lua:1'));
      expect(
        _allText(_tab(manager, 'engine_dashboard').content!),
        contains('3000 RPM'),
      );
    },
    skip: libraryPath == null || !sourcePlugins.existsSync()
        ? 'Build the native shim and run this test from the package checkout.'
        : false,
  );
}

PluginTab _tab(PluginManager manager, String id) =>
    manager.uiRegistry.currentTabs.singleWhere((tab) => tab.id == id);

List<String> _allText(PluginUiNode node) => switch (node) {
  PluginTextNode() => [node.text],
  PluginRowNode() => [for (final child in node.children) ..._allText(child)],
  PluginColumnNode() => [for (final child in node.children) ..._allText(child)],
  PluginContainerNode() => node.child == null ? [] : _allText(node.child!),
  PluginListNode() => [for (final child in node.children) ..._allText(child)],
  PluginCardNode() => _allText(node.child),
  PluginButtonNode() => [node.text],
  PluginSwitchNode() => [if (node.label != null) node.label!],
  PluginSliderNode() => [if (node.label != null) node.label!],
  PluginIconNode() || PluginSpacerNode() => [],
};

PluginButtonNode _findButton(PluginUiNode node) => switch (node) {
  PluginButtonNode() => node,
  PluginRowNode() => _firstButton(node.children),
  PluginColumnNode() => _firstButton(node.children),
  PluginContainerNode() when node.child != null => _findButton(node.child!),
  PluginListNode() => _firstButton(node.children),
  PluginCardNode() => _findButton(node.child),
  _ => throw StateError('No button in UI tree.'),
};

PluginButtonNode _firstButton(List<PluginUiNode> children) {
  for (final child in children) {
    try {
      return _findButton(child);
    } on StateError {
      // Search the next child.
    }
  }
  throw StateError('No button in UI tree.');
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  final prefix = source.path.endsWith(Platform.pathSeparator)
      ? source.path
      : '${source.path}${Platform.pathSeparator}';
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relative = entity.path.substring(prefix.length);
    final target = destination.uri.resolve(relative.replaceAll('\\', '/'));
    if (entity is Directory) {
      await Directory.fromUri(target).create(recursive: true);
    } else if (entity is File) {
      final file = File.fromUri(target);
      await file.parent.create(recursive: true);
      await entity.copy(file.path);
    }
  }
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
  for (final candidate in candidates) {
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}
