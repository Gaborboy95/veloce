import 'dart:io';

import 'package:test/test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';

void main() {
  test(
    'asset bundle is immutable, bounded, and prevents path traversal',
    () async {
      final root = await Directory.systemTemp.createTemp('veloce-assets-');
      addTearDown(() => root.delete(recursive: true));
      final assets = Directory.fromUri(root.uri.resolve('assets/nested/'));
      await assets.create(recursive: true);
      await File.fromUri(
        assets.uri.resolve('message.txt'),
      ).writeAsString('hello');

      final bundle = await const DirectoryPluginAssetProvider().load(
        pluginId: 'dev.example.assets',
        pluginDirectory: root,
      );
      expect(bundle.list(), ['nested/message.txt']);
      expect(bundle.readText('nested/message.txt'), 'hello');
    bundle.readBytes('nested/message.txt').fillRange(0, 1, 0);
      expect(bundle.readText('nested/message.txt'), 'hello');
      expect(() => bundle.readText('../outside'), throwsArgumentError);
    },
  );

  test('generic declarative UI extension points are owner-cleaned', () async {
    final registry = PluginUiRegistry();
    addTearDown(registry.close);
    final contribution = PluginUiContribution(
      extensionPoint: PluginUiExtensionPoints.quickControls,
      pluginId: 'dev.example.controls',
      id: 'heated_seat',
      title: 'Heated seat',
      content: const PluginTextNode('Off'),
    );

    registry.registerContribution(contribution);
    expect(
      registry.currentContributions(PluginUiExtensionPoints.quickControls),
      [contribution],
    );
    registry.unregisterPlugin('dev.example.controls');
    expect(
      registry.currentContributions(PluginUiExtensionPoints.quickControls),
      isEmpty,
    );
  });
}
