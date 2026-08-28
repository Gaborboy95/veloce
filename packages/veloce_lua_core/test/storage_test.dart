import 'dart:io';

import 'package:veloce_lua_core/veloce_lua_core.dart';
import 'package:test/test.dart';

void main() {
  test('JSON storage persists and isolates plugin namespaces', () async {
    final directory =
        await Directory.systemTemp.createTemp('veloce_storage_test_');
    addTearDown(() => directory.delete(recursive: true));
    final provider = JsonPluginStorageProvider(rootDirectory: directory);
    final first = await provider.open('dev.example.first');
    final second = await provider.open('dev.example.second');
    await first.set('value', {'count': 3});
    await second.set('value', 'other');

    final reopenedProvider =
        JsonPluginStorageProvider(rootDirectory: directory);
    final reopened = await reopenedProvider.open('dev.example.first');
    expect(await reopened.get('value'), {'count': 3});
    expect(await second.get('value'), 'other');
    expect(await first.get('missing'), isNull);
  });

  test('storage values are defensive and scoped API has no foreign ID',
      () async {
    final provider = MemoryPluginStorageProvider();
    final storage = await provider.open('dev.example.first');
    final source = <Object?>[1, 2];
    await storage.set('list', source);
    source.add(3);

    expect(await storage.get('list'), [1, 2]);
    expect(storage.pluginId, 'dev.example.first');
  });
}
