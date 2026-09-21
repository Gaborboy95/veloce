import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';

void main() {
  for (final mutation in ['payload', 'manifest', 'signature', 'added']) {
    test('staged $mutation tampering is rejected', () async {
      final fixture = await _InstallFixture.create();
      final installer = fixture.installer(
        hooks: PluginInstallHooks(
          afterSnapshot: (staging) async {
            switch (mutation) {
              case 'payload':
                await File('${staging.path}/main.lua').writeAsString('changed');
              case 'manifest':
                final file = File('${staging.path}/manifest.json');
                final manifest =
                    jsonDecode(await file.readAsString())
                        as Map<String, dynamic>;
                manifest['version'] = '2.0.0';
                await file.writeAsString(jsonEncode(manifest));
              case 'signature':
                await File(
                  '${staging.path}/signature.json',
                ).writeAsString('{}');
              case 'added':
                await File('${staging.path}/extra.lua').writeAsString('added');
            }
          },
        ),
      );
      await expectLater(
        installer.install(fixture.package),
        throwsA(isA<PluginInstallationException>()),
      );
      expect(
        await Directory('${fixture.root.path}/dev.example.signed').exists(),
        isFalse,
      );
      expect(
        await Directory('${fixture.root.path}/.veloce/staging').list().toList(),
        isEmpty,
      );
    });
  }

  test('signing-key scope uses the staged manifest', () async {
    final fixture = await _InstallFixture.create();
    final installer = fixture.installer(
      hooks: PluginInstallHooks(
        afterSnapshot: (staging) async {
          final file = File('${staging.path}/manifest.json');
          final manifest =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          manifest['id'] = 'dev.example.other';
          await file.writeAsString(jsonEncode(manifest));
          await _sign(
            staging,
            fixture.installer(),
            fixture.algorithm,
            fixture.key,
          );
        },
      ),
    );
    await expectLater(
      installer.install(fixture.package),
      throwsA(isA<PluginInstallationException>()),
    );
    expect(
      await Directory('${fixture.root.path}/dev.example.other').exists(),
      isFalse,
    );
  });

  test('copy enforces growth bounds after inspection', () async {
    final fixture = await _InstallFixture.create();
    final installer = fixture.installer(
      maxTotalBytes: 2048,
      hooks: PluginInstallHooks(
        beforeCopyFile: (relative) async {
          if (relative == 'main.lua') {
            await File(
              '${fixture.package.path}/main.lua',
            ).writeAsBytes(List.filled(4096, 42));
          }
        },
      ),
    );
    await expectLater(
      installer.install(fixture.package),
      throwsA(isA<PluginInstallationException>()),
    );
    expect(
      await Directory('${fixture.root.path}/.veloce/staging').list().toList(),
      isEmpty,
    );
  });

  test(
    'link substitution before copy and symlink destinations are rejected',
    () async {
      final fixture = await _InstallFixture.create();
      final outside = File('${fixture.sources.path}/outside.lua');
      await outside.writeAsString('private fixture');
      final installer = fixture.installer(
        hooks: PluginInstallHooks(
          beforeCopyFile: (relative) async {
            if (relative != 'main.lua') return;
            final file = File('${fixture.package.path}/main.lua');
            await file.delete();
            await Link(file.path).create(outside.path);
          },
        ),
      );
      await expectLater(
        installer.install(fixture.package),
        throwsA(isA<PluginInstallationException>()),
      );
      await Link('${fixture.package.path}/main.lua').delete();
      await File(
        '${fixture.package.path}/main.lua',
      ).writeAsString('return "safe"');
      await _sign(
        fixture.package,
        fixture.installer(),
        fixture.algorithm,
        fixture.key,
      );
      await Link(
        '${fixture.root.path}/dev.example.signed',
      ).create(fixture.sources.path);
      await expectLater(
        fixture.installer().install(fixture.package),
        throwsA(isA<PluginInstallationException>()),
      );
      expect(await outside.readAsString(), 'private fixture');
    },
  );

  test('signature metadata counts towards copy bounds', () async {
    final fixture = await _InstallFixture.create();
    await File(
      '${fixture.package.path}/signature.json',
    ).writeAsString(' ' * (16 * 1024 + 1));
    await expectLater(
      fixture.installer().install(fixture.package),
      throwsA(isA<PluginInstallationException>()),
    );
  });

  test(
    'source mutation after verification cannot alter the installed bytes or manifest',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'veloce-snapshot-root-',
      );
      final sources = await Directory.systemTemp.createTemp(
        'veloce-snapshot-source-',
      );
      addTearDown(() async {
        await root.delete(recursive: true);
        await sources.delete(recursive: true);
      });
      final algorithm = Ed25519();
      final key = await algorithm.newKeyPair();
      final public = await key.extractPublicKey();
      final package = await _package(
        sources,
        version: '1.0.0',
        body: 'verified',
      );
      final verifier = _AfterVerification(
        Ed25519PluginSignatureVerifier([
          TrustedPluginKey(
            keyId: 'test-vendor',
            publicKey: public.bytes,
            allowedPluginIds: ['dev.example.signed'],
          ),
        ]),
        () async {
          await File(
            '${package.path}/main.lua',
          ).writeAsString('unverified payload');
          final file = File('${package.path}/manifest.json');
          final manifest =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          manifest['version'] = '9.0.0';
          await file.writeAsString(jsonEncode(manifest));
          await File(
            '${package.path}/unexpected.lua',
          ).writeAsString('unverified addition');
          await File('${package.path}/signature.json').writeAsString('{}');
        },
      );
      final installer = PluginInstaller(
        pluginRoot: root,
        signatureVerifier: verifier,
      );
      await _sign(package, installer, algorithm, key);
      final result = await installer.install(package);
      expect(result.source.manifest.version.toString(), '1.0.0');
      expect(result.provenance.version.toString(), '1.0.0');
      final target = Directory(result.source.directoryPath);
      expect(
        await File('${target.path}/main.lua').readAsString(),
        'return "verified"',
      );
      expect(await File('${target.path}/unexpected.lua').exists(), isFalse);
      expect(await installer.computeDigest(target), verifier.verifiedDigest);
    },
  );

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

class _AfterVerification implements PluginSignatureVerifier {
  _AfterVerification(this.delegate, this.after);
  final PluginSignatureVerifier delegate;
  final Future<void> Function() after;
  late Uint8List verifiedDigest;
  @override
  Future<void> verify({
    required PluginManifest manifest,
    required Uint8List digest,
    required PluginSignatureEnvelope envelope,
  }) async {
    await delegate.verify(
      manifest: manifest,
      digest: digest,
      envelope: envelope,
    );
    verifiedDigest = digest;
    await after();
  }
}

class _InstallFixture {
  _InstallFixture(
    this.root,
    this.sources,
    this.package,
    this.algorithm,
    this.key,
    this.verifier,
  );
  final Directory root, sources, package;
  final Ed25519 algorithm;
  final KeyPair key;
  final PluginSignatureVerifier verifier;
  static Future<_InstallFixture> create() async {
    final root = await Directory.systemTemp.createTemp('veloce-staging-root-');
    final sources = await Directory.systemTemp.createTemp(
      'veloce-staging-source-',
    );
    addTearDown(() async {
      await root.delete(recursive: true);
      await sources.delete(recursive: true);
    });
    final algorithm = Ed25519();
    final key = await algorithm.newKeyPair();
    final public = await key.extractPublicKey();
    final package = await _package(sources, version: '1.0.0', body: 'safe');
    final fixture = _InstallFixture(
      root,
      sources,
      package,
      algorithm,
      key,
      Ed25519PluginSignatureVerifier([
        TrustedPluginKey(
          keyId: 'test-vendor',
          publicKey: public.bytes,
          allowedPluginIds: ['dev.example.signed'],
        ),
      ]),
    );
    await _sign(package, fixture.installer(), algorithm, key);
    return fixture;
  }

  PluginInstaller installer({
    PluginInstallHooks hooks = const PluginInstallHooks(),
    int maxTotalBytes = 128 * 1024 * 1024,
  }) => PluginInstaller(
    pluginRoot: root,
    signatureVerifier: verifier,
    hooks: hooks,
    maxTotalBytes: maxTotalBytes,
  );
}
