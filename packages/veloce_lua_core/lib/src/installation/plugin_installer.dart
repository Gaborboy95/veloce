import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import '../errors/plugin_exception.dart';
import '../loader/plugin_loader.dart';
import '../manifest/plugin_manifest.dart';

final class PluginSignatureEnvelope {
  const PluginSignatureEnvelope({
    required this.algorithm,
    required this.keyId,
    required this.signature,
    required this.digest,
  });

  final String algorithm;
  final String keyId;
  final Uint8List signature;
  final String digest;

  factory PluginSignatureEnvelope.parse(String source) {
    try {
      final raw = jsonDecode(source);
      if (raw is! Map<String, Object?> ||
          raw['algorithm'] != 'ed25519' ||
          raw['keyId'] is! String ||
          raw['signature'] is! String ||
          raw['digest'] is! String) {
        throw const FormatException('Invalid signature envelope.');
      }
      final signature = base64Decode(raw['signature']! as String);
      final digest = raw['digest']! as String;
      if (signature.length != 64 ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
        throw const FormatException('Invalid signature or digest encoding.');
      }
      return PluginSignatureEnvelope(
        algorithm: 'ed25519',
        keyId: raw['keyId']! as String,
        signature: signature,
        digest: digest,
      );
    } on FormatException {
      rethrow;
    } on Object catch (error) {
      throw FormatException('Invalid signature envelope: $error');
    }
  }
}

final class TrustedPluginKey {
  TrustedPluginKey({
    required this.keyId,
    required List<int> publicKey,
    Iterable<String>? allowedPluginIds,
  }) : publicKey = Uint8List.fromList(publicKey),
       allowedPluginIds = allowedPluginIds == null
           ? null
           : Set.unmodifiable(allowedPluginIds) {
    if (keyId.trim().isEmpty || this.publicKey.length != 32) {
      throw ArgumentError('Ed25519 keys require an ID and 32 public bytes.');
    }
  }

  final String keyId;
  final Uint8List publicKey;
  final Set<String>? allowedPluginIds;

  bool permits(String pluginId) =>
      allowedPluginIds == null || allowedPluginIds!.contains(pluginId);
}

abstract interface class PluginSignatureVerifier {
  Future<void> verify({
    required PluginManifest manifest,
    required Uint8List digest,
    required PluginSignatureEnvelope envelope,
  });
}

final class Ed25519PluginSignatureVerifier implements PluginSignatureVerifier {
  Ed25519PluginSignatureVerifier(Iterable<TrustedPluginKey> keys)
    : _keys = Map.unmodifiable({for (final key in keys) key.keyId: key});

  final Map<String, TrustedPluginKey> _keys;
  final Ed25519 _algorithm = Ed25519();

  @override
  Future<void> verify({
    required PluginManifest manifest,
    required Uint8List digest,
    required PluginSignatureEnvelope envelope,
  }) async {
    final key = _keys[envelope.keyId];
    if (key == null || !key.permits(manifest.id)) {
      throw PluginInstallationException(
        'Plugin signer is not trusted for this plugin ID.',
        pluginId: manifest.id,
      );
    }
    if (envelope.digest != _hex(digest)) {
      throw PluginInstallationException(
        'Plugin payload digest does not match signature.json.',
        pluginId: manifest.id,
      );
    }
    final valid = await _algorithm.verify(
      digest,
      signature: Signature(
        envelope.signature,
        publicKey: SimplePublicKey(key.publicKey, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) {
      throw PluginInstallationException(
        'Plugin Ed25519 signature is invalid.',
        pluginId: manifest.id,
      );
    }
  }
}

final class PluginProvenance {
  const PluginProvenance({
    required this.pluginId,
    required this.version,
    required this.digest,
    required this.installedAt,
    this.signingKeyId,
    this.source,
  });

  final String pluginId;
  final SemanticVersion version;
  final String digest;
  final DateTime installedAt;
  final String? signingKeyId;
  final String? source;

  Map<String, Object?> toJson() => {
    'pluginId': pluginId,
    'version': version.toString(),
    'digest': digest,
    'installedAt': installedAt.toUtc().toIso8601String(),
    if (signingKeyId != null) 'signingKeyId': signingKeyId,
    if (source != null) 'source': source,
  };
}

final class PluginInstallResult {
  const PluginInstallResult({
    required this.source,
    required this.provenance,
    required this.replacedExisting,
  });

  final PluginSource source;
  final PluginProvenance provenance;
  final bool replacedExisting;
}

/// Authenticates a directory package, stages it on the destination filesystem,
/// and commits it with an atomic directory rename.
final class PluginInstaller {
  PluginInstaller({
    required this.pluginRoot,
    required this.signatureVerifier,
    PluginLoader? loader,
    this.requireSignature = true,
    this.maxFiles = 4096,
    this.maxTotalBytes = 128 * 1024 * 1024,
  }) : loader = loader ?? PluginLoader();

  static const signatureFileName = 'signature.json';
  static const provenanceFileName = '.veloce-provenance.json';

  final Directory pluginRoot;
  final PluginSignatureVerifier signatureVerifier;
  final PluginLoader loader;
  final bool requireSignature;
  final int maxFiles;
  final int maxTotalBytes;

  /// Computes the canonical digest signed by `signature.json`.
  Future<Uint8List> computeDigest(Directory packageDirectory) async =>
      Uint8List.fromList((await _digestDirectory(packageDirectory)).digest);

  Future<PluginInstallResult> install(
    Directory packageDirectory, {
    String? source,
  }) async {
    Directory? staging;
    Directory? prior;
    PluginManifest? manifest;
    try {
      final candidate = await loader.loadDirectory(packageDirectory);
      manifest = candidate.manifest;
      final payload = await _digestDirectory(packageDirectory);
      final signatureFile = File.fromUri(
        packageDirectory.uri.resolve(signatureFileName),
      );
      PluginSignatureEnvelope? envelope;
      if (await signatureFile.exists()) {
        envelope = PluginSignatureEnvelope.parse(
          await signatureFile.readAsString(),
        );
        await signatureVerifier.verify(
          manifest: manifest,
          digest: payload.digest,
          envelope: envelope,
        );
      } else if (requireSignature) {
        throw PluginInstallationException(
          'Signed installation requires signature.json.',
          pluginId: manifest.id,
          filename: signatureFile.path,
        );
      }

      await pluginRoot.create(recursive: true);
      final control = Directory.fromUri(pluginRoot.uri.resolve('.veloce/'));
      final stagingRoot = Directory.fromUri(control.uri.resolve('staging/'));
      final rollbackRoot = Directory.fromUri(control.uri.resolve('rollback/'));
      await stagingRoot.create(recursive: true);
      await rollbackRoot.create(recursive: true);
      final nonce = '${DateTime.now().microsecondsSinceEpoch}-$pid';
      staging = Directory.fromUri(
        stagingRoot.uri.resolve('${manifest.id}-$nonce/'),
      );
      await _copyPackage(packageDirectory, staging, payload.files);
      final provenance = PluginProvenance(
        pluginId: manifest.id,
        version: manifest.version,
        digest: _hex(payload.digest),
        installedAt: DateTime.now().toUtc(),
        signingKeyId: envelope?.keyId,
        source: source,
      );
      await File.fromUri(
        staging.uri.resolve(provenanceFileName),
      ).writeAsString(jsonEncode(provenance.toJson()), flush: true);

      final target = Directory.fromUri(
        pluginRoot.uri.resolve('${manifest.id}/'),
      );
      final replaced = await target.exists();
      if (replaced) {
        prior = Directory.fromUri(
          rollbackRoot.uri.resolve('${manifest.id}-$nonce/'),
        );
        await target.rename(prior.path);
      }
      try {
        await staging.rename(target.path);
        staging = null;
      } on Object {
        if (prior != null && await prior.exists() && !await target.exists()) {
          await prior.rename(target.path);
        }
        rethrow;
      }
      return PluginInstallResult(
        source: await loader.loadDirectory(target),
        provenance: provenance,
        replacedExisting: replaced,
      );
    } on PluginException {
      rethrow;
    } on Object catch (error, stackTrace) {
      throw PluginInstallationException(
        'Plugin installation failed.',
        pluginId: manifest?.id,
        cause: error,
        causeStackTrace: stackTrace,
      );
    } finally {
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
  }

  Future<PluginSource> rollback(String pluginId) async {
    final rollbackRoot = Directory.fromUri(
      pluginRoot.uri.resolve('.veloce/rollback/'),
    );
    if (!await rollbackRoot.exists()) {
      throw PluginInstallationException(
        'No rollback is available.',
        pluginId: pluginId,
      );
    }
    final candidates = <Directory>[];
    await for (final entity in rollbackRoot.list(followLinks: false)) {
      if (entity is Directory &&
          entity.uri.pathSegments
              .where((item) => item.isNotEmpty)
              .last
              .startsWith('$pluginId-')) {
        candidates.add(entity);
      }
    }
    candidates.sort((left, right) => right.path.compareTo(left.path));
    if (candidates.isEmpty) {
      throw PluginInstallationException(
        'No rollback is available.',
        pluginId: pluginId,
      );
    }
    final replacement = candidates.first;
    final source = await loader.loadDirectory(replacement);
    if (source.manifest.id != pluginId) {
      throw PluginInstallationException(
        'Rollback package has the wrong plugin ID.',
        pluginId: pluginId,
      );
    }
    final payload = await _digestDirectory(replacement);
    final signature = File.fromUri(replacement.uri.resolve(signatureFileName));
    if (await signature.exists()) {
      await signatureVerifier.verify(
        manifest: source.manifest,
        digest: payload.digest,
        envelope: PluginSignatureEnvelope.parse(await signature.readAsString()),
      );
    } else if (requireSignature) {
      throw PluginInstallationException(
        'Rollback package is unsigned.',
        pluginId: pluginId,
      );
    }

    final target = Directory.fromUri(pluginRoot.uri.resolve('$pluginId/'));
    final displaced = Directory.fromUri(
      rollbackRoot.uri.resolve(
        '$pluginId-${DateTime.now().microsecondsSinceEpoch}-$pid/',
      ),
    );
    if (await target.exists()) await target.rename(displaced.path);
    try {
      await replacement.rename(target.path);
    } on Object {
      if (await displaced.exists() && !await target.exists()) {
        await displaced.rename(target.path);
      }
      rethrow;
    }
    return loader.loadDirectory(target);
  }

  Future<_PackageDigest> _digestDirectory(Directory root) async {
    final files = <({File file, String relative, int length})>[];
    var total = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw PluginInstallationException(
          'Plugin packages may not contain symbolic links.',
          filename: entity.path,
        );
      }
      if (type == FileSystemEntityType.directory) continue;
      if (type != FileSystemEntityType.file) {
        throw PluginInstallationException(
          'Plugin package contains an unsupported filesystem entry.',
          filename: entity.path,
        );
      }
      final relative = _relativePath(root, entity.path);
      if (relative == signatureFileName || relative == provenanceFileName) {
        continue;
      }
      final file = entity as File;
      final length = await file.length();
      total += length;
      if (files.length >= maxFiles || total > maxTotalBytes) {
        throw const PluginInstallationException(
          'Plugin package exceeds host file-count or size limits.',
        );
      }
      files.add((file: file, relative: relative, length: length));
    }
    files.sort((left, right) => left.relative.compareTo(right.relative));
    final records = StringBuffer();
    for (final entry in files) {
      final fileDigest = await crypto.sha256.bind(entry.file.openRead()).first;
      records
        ..write(entry.relative)
        ..write('\u0000')
        ..write(entry.length)
        ..write('\u0000')
        ..write(fileDigest)
        ..write('\n');
    }
    final digest = crypto.sha256.convert(utf8.encode(records.toString()));
    return _PackageDigest(
      files: files,
      digest: Uint8List.fromList(digest.bytes),
    );
  }

  static Future<void> _copyPackage(
    Directory root,
    Directory destination,
    List<({File file, String relative, int length})> signedFiles,
  ) async {
    await destination.create(recursive: true);
    final signature = File.fromUri(root.uri.resolve(signatureFileName));
    final files = [
      ...signedFiles.map(
        (entry) => (file: entry.file, relative: entry.relative),
      ),
      if (await signature.exists())
        (file: signature, relative: signatureFileName),
    ];
    for (final entry in files) {
      final target = File.fromUri(destination.uri.resolve(entry.relative));
      await target.parent.create(recursive: true);
      await entry.file.copy(target.path);
    }
  }

  static String _relativePath(Directory root, String path) {
    final prefix = root.absolute.path.endsWith(Platform.pathSeparator)
        ? root.absolute.path
        : '${root.absolute.path}${Platform.pathSeparator}';
    final absolute = File(path).absolute.path;
    final normalizedPrefix = Platform.isWindows ? prefix.toLowerCase() : prefix;
    final normalized = Platform.isWindows ? absolute.toLowerCase() : absolute;
    if (!normalized.startsWith(normalizedPrefix)) {
      throw PluginInstallationException(
        'Plugin package entry escapes its root.',
        filename: path,
      );
    }
    return absolute.substring(prefix.length).replaceAll('\\', '/');
  }
}

final class _PackageDigest {
  const _PackageDigest({required this.files, required this.digest});

  final List<({File file, String relative, int length})> files;
  final Uint8List digest;
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
