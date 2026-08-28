import 'package:ivi_lua_core/ivi_lua_core.dart';
import 'package:test/test.dart';

void main() {
  final parser = PluginManifestParser();
  const validJson = '''
  {
    "id": "dev.example.demo",
    "name": "Demo Plugin",
    "version": "1.2.3-beta.1+linux",
    "apiVersion": "1",
    "entrypoint": "main.lua",
    "permissions": ["logging", "events", "ui.tabs"]
  }
  ''';

  test('parses a strongly typed valid manifest', () {
    final manifest = parser.parseString(validJson);

    expect(manifest.id, 'dev.example.demo');
    expect(manifest.version, SemanticVersion.parse('1.2.3-beta.1+linux'));
    expect(manifest.permissions, contains(BuiltInCapabilities.uiTabs));
  });

  test('semantic versions use SemVer precedence', () {
    expect(
      SemanticVersion.parse('1.0.0-alpha'),
      lessThan(SemanticVersion.parse('1.0.0')),
    );
    expect(
      SemanticVersion.parse('2.0.0'),
      greaterThan(SemanticVersion.parse('1.99.99')),
    );
  });

  test('rejects malformed and unsafe manifest fields', () {
    expect(
      () => parser.parseString('{'),
      throwsA(isA<PluginManifestException>()),
    );
    final base = parser.parseString(validJson).toJson();
    for (final invalid in [
      {...base, 'id': '../bad'},
      {...base, 'version': 'v1'},
      {...base, 'version': '1.0.0-01'},
      {...base, 'apiVersion': '2'},
      {...base, 'entrypoint': '../main.lua'},
      {...base, 'entrypoint': 'lua//main.lua'},
      {
        ...base,
        'permissions': ['unknown.permission']
      },
    ]) {
      expect(
        () => parser.parseMap(invalid),
        throwsA(isA<PluginManifestException>()),
      );
    }
  });

  test('rejects duplicate IDs', () {
    final manifest = parser.parseString(validJson);
    expect(
      () => PluginManifestCollection([manifest, manifest]),
      throwsA(isA<PluginManifestException>()),
    );
  });
}
