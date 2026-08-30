import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';

void main() {
  test(
    'signed installs upgrade atomically and retain a verified rollback',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'veloce-install-root-',
      );
      final packageRoot = await Directory.systemTemp.createTemp(
        'veloce-install-source-',
      );
      addTearDown(() async {
        await root.delete(recursive: true);
        await packageRoot.delete(recursive: true);
      });
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final installer = PluginInstaller(
        pluginRoot: root,
        signatureVerifier: Ed25519PluginSignatureVerifier([
          TrustedPluginKey(
            keyId: 'test-vendor',
            publicKey: publicKey.bytes,
            allowedPluginIds: const ['dev.example.signed'],
          ),
        ]),
      );

      final first = await _package(packageRoot, version: '1.0.0', body: 'v1');
      await _sign(first, installer, algorithm, keyPair);
      final installed = await installer.install(first, source: 'unit-test');
      expect(installed.replacedExisting, isFalse);
      expect(installed.provenance.signingKeyId, 'test-vendor');

      final second = await _package(packageRoot, version: '2.0.0', body: 'v2');
      await _sign(second, installer, algorithm, keyPair);
      final upgraded = await installer.install(second);
      expect(upgraded.replacedExisting, isTrue);
      expect(upgraded.source.manifest.version.toString(), '2.0.0');

      final rolledBack = await installer.rollback('dev.example.signed');
      expect(rolledBack.manifest.version.toString(), '1.0.0');
      expect(
        await File.fromUri(
          Directory(rolledBack.directoryPath).uri.resolve('main.lua'),
        ).readAsString(),
        'return "v1"',
      );
    },
  );

  test(
    'tampering after signing is rejected before the active plugin changes',
    () async {
      final root = await Directory.systemTemp.createTemp('veloce-tamper-root-');
      final packageRoot = await Directory.systemTemp.createTemp(
        'veloce-tamper-source-',
      );
      addTearDown(() async {
        await root.delete(recursive: true);
        await packageRoot.delete(recursive: true);
      });
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final installer = PluginInstaller(
        pluginRoot: root,
        signatureVerifier: Ed25519PluginSignatureVerifier([
          TrustedPluginKey(keyId: 'test-vendor', publicKey: publicKey.bytes),
        ]),
      );
      final package = await _package(
        packageRoot,
        version: '1.0.0',
        body: 'safe',
      );
      await _sign(package, installer, algorithm, keyPair);
      await File.fromUri(package.uri.resolve('main.lua')).writeAsString('evil');

      await expectLater(
        installer.install(package),
        throwsA(isA<PluginInstallationException>()),
      );
      expect(
        Directory.fromUri(root.uri.resolve('dev.example.signed/')).existsSync(),
        isFalse,
      );
    },
  );
}

Future<Directory> _package(
  Directory root, {
  required String version,
  required String body,
}) async {
  final directory = Directory.fromUri(
    root.uri.resolve('package-${version.replaceAll('.', '-')}/'),
  );
  await directory.create(recursive: true);
  await File.fromUri(directory.uri.resolve('manifest.json')).writeAsString(
    jsonEncode({
      'id': 'dev.example.signed',
      'name': 'Signed plugin',
      'version': version,
      'apiVersion': '1',
      'entrypoint': 'main.lua',
      'permissions': <String>[],
    }),
  );
  await File.fromUri(
    directory.uri.resolve('main.lua'),
  ).writeAsString('return "$body"');
  return directory;
}

Future<void> _sign(
  Directory package,
  PluginInstaller installer,
  Ed25519 algorithm,
  KeyPair keyPair,
) async {
  final digest = await installer.computeDigest(package);
  final signature = await algorithm.sign(digest, keyPair: keyPair);
  await File.fromUri(package.uri.resolve('signature.json')).writeAsString(
    jsonEncode({
      'algorithm': 'ed25519',
      'keyId': 'test-vendor',
      'digest': digest
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(),
      'signature': base64Encode(signature.bytes),
    }),
  );
}
