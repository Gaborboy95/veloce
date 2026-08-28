import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ivi_lua_core/ivi_lua_core.dart';

import 'package:infotainment_demo/demo_runtime.dart';
import 'package:infotainment_demo/infotainment_app.dart';

void main() {
  testWidgets('renders the built-in infotainment sections without native Lua', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final canProvider = InMemoryCanProvider();
    final manager = PluginManager(
      pluginRoot: Directory.current,
      runtimeFactory: _UnusedRuntimeFactory(),
      canProvider: canProvider,
    );
    final runtime = DemoRuntime(
      manager: manager,
      canProvider: canProvider,
      pluginDirectory: Directory.current,
    );

    await tester.pumpWidget(InfotainmentDemo(runtime: runtime));

    expect(find.text('Home'), findsWidgets);
    expect(find.text('Plugins'), findsOneWidget);
    expect(find.text('Developer Console'), findsOneWidget);
    expect(find.text('Inject 3000 RPM frame'), findsOneWidget);

    await tester.tap(find.text('Inject 3000 RPM frame'));
    await tester.pump();
    expect(find.textContaining('No decoder is subscribed'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

final class _UnusedRuntimeFactory implements PluginScriptRuntimeFactory {
  @override
  Future<PluginScriptRuntime> create({
    required PluginManifest manifest,
    required String pluginDirectory,
    required String generation,
    required PluginApiRegistry apiRegistry,
  }) {
    throw StateError(
      'No plugin runtime should be created by this widget test.',
    );
  }
}
