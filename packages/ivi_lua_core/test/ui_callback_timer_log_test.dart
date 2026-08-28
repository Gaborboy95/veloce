import 'dart:async';

import 'package:ivi_lua_core/ivi_lua_core.dart';
import 'package:test/test.dart';

void main() {
  test('callback refs become stale after disposal', () async {
    final registry = PluginCallbackRegistry(
      pluginId: 'dev.example.ui',
      generation: 'g1',
    );
    final callback = registry.register((arguments) => arguments.first);
    expect(await registry.invoke(callback, arguments: [42]), 42);
    await registry.dispose();

    await expectLater(
      registry.invoke(callback),
      throwsA(isA<StalePluginCallbackException>()),
    );
  });

  test('UI validates ownership and registry cleans all plugin tabs', () async {
    const callback = PluginCallbackRef(
      pluginId: 'dev.example.ui',
      generation: 'g1',
      callbackId: 1,
    );
    final registry = PluginUiRegistry();
    registry.registerTab(
      PluginTab(
        pluginId: 'dev.example.ui',
        id: 'demo',
        title: 'Demo',
        content: PluginColumnNode([
          const PluginTextNode('Hello'),
          const PluginButtonNode(text: 'Press', onPressed: callback),
        ]),
      ),
    );
    expect(registry.currentTabs, hasLength(1));
    registry.unregisterPlugin('dev.example.ui');
    expect(registry.currentTabs, isEmpty);
    await registry.close();
  });

  test('UI rejects callbacks owned by a different plugin', () {
    const foreign = PluginCallbackRef(
      pluginId: 'dev.example.foreign',
      generation: 'g1',
      callbackId: 1,
    );
    expect(
      () => const PluginUiValidator().validate(
        const PluginButtonNode(text: 'Bad', onPressed: foreign),
        pluginId: 'dev.example.ui',
      ),
      throwsA(isA<PluginApiException>()),
    );
  });

  test('log history is bounded and automatically tagged', () async {
    final logs = PluginLogManager(maxHistory: 2);
    final logger = logs.logger('dev.example.ui');
    logger.debug('one');
    logger.info('two');
    logger.error('three');

    expect(logs.recent.map((event) => event.message), ['two', 'three']);
    expect(logs.recent.every((event) => event.pluginId == 'dev.example.ui'),
        isTrue);
    await logs.close();
  });

  test('disposing timers cancels future callbacks', () async {
    final callbacks = PluginCallbackRegistry(
      pluginId: 'dev.example.ui',
      generation: 'g1',
    );
    var calls = 0;
    final callback = callbacks.register((_) => calls++);
    final timers = PluginTimerRegistry(
      pluginId: 'dev.example.ui',
      generation: 'g1',
      invokeCallback: (reference, arguments) => callbacks.invoke(
        reference,
        arguments: arguments,
      ),
    );
    timers.setInterval(const Duration(milliseconds: 10), callback);
    await Future<void>.delayed(const Duration(milliseconds: 35));
    await timers.dispose();
    final countAtDispose = calls;
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(countAtDispose, greaterThan(0));
    expect(calls, countAtDispose);
    await callbacks.dispose();
  });

  test('timer registry rejects stale-generation callbacks', () async {
    final timers = PluginTimerRegistry(
      pluginId: 'dev.example.ui',
      generation: 'new',
      invokeCallback: (_, __) => null,
    );
    expect(
      () => timers.setTimeout(
        Duration.zero,
        const PluginCallbackRef(
          pluginId: 'dev.example.ui',
          generation: 'old',
          callbackId: 1,
        ),
      ),
      throwsA(isA<StalePluginCallbackException>()),
    );
    await timers.dispose();
  });
}
