import 'dart:async';
import 'dart:io';

import 'package:ivi_lua_core/ivi_lua_core.dart';
import 'package:test/test.dart';

void main() {
  test('maps nested changes to the direct plugin directory', () {
    final root = Directory.fromUri(Directory.current.uri.resolve('plugins/'));
    final watcher = PluginWatcher(pluginRoot: root);
    final changed = File.fromUri(
      root.uri.resolve('demo/assets/icons/example.txt'),
    );

    expect(
      watcher.pluginDirectoryFor(changed.path),
      Directory.fromUri(root.uri.resolve('demo')).absolute.path,
    );
    expect(
      watcher.pluginDirectoryFor(
        File.fromUri(Directory.current.uri.resolve('outside.txt')).path,
      ),
      isNull,
    );
  });

  test('filesystem save bursts emit one debounced plugin change', () async {
    final root = await Directory.systemTemp.createTemp('ivi-watcher-test-');
    final plugin = await Directory.fromUri(root.uri.resolve('demo/')).create();
    final watcher = PluginWatcher(
      pluginRoot: root,
      debounce: const Duration(milliseconds: 80),
    );
    addTearDown(() async {
      await watcher.close();
      await root.delete(recursive: true);
    });

    var notifications = 0;
    final firstChange = Completer<String>();
    final subscription = watcher.changes.listen((directory) {
      notifications++;
      if (!firstChange.isCompleted) firstChange.complete(directory);
    });
    addTearDown(subscription.cancel);
    await watcher.start();

    final source = File.fromUri(plugin.uri.resolve('main.lua'));
    await source.writeAsString('return 1\n');
    await source.writeAsString('return 2\n');
    await source.writeAsString('return 3\n');

    expect(
      await firstChange.future.timeout(const Duration(seconds: 5)),
      Directory(
        '${root.path}${Platform.pathSeparator}demo',
      ).absolute.path,
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(notifications, 1);
  });
}
