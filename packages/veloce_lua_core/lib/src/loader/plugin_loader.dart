import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../errors/plugin_exception.dart';
import '../manifest/plugin_manifest.dart';

final class PluginSource {
  const PluginSource({
    required this.manifest,
    required this.directoryPath,
    required this.entrypointPath,
  });

  final PluginManifest manifest;
  final String directoryPath;
  final String entrypointPath;
}

final class PluginDiscoveryFailure {
  const PluginDiscoveryFailure({
    required this.directoryPath,
    required this.error,
  });

  final String directoryPath;
  final PluginException error;
}

final class PluginDiscoveryResult {
  PluginDiscoveryResult({
    required Iterable<PluginSource> plugins,
    required Iterable<PluginDiscoveryFailure> failures,
  }) : plugins = List.unmodifiable(plugins),
       failures = List.unmodifiable(failures);

  final List<PluginSource> plugins;
  final List<PluginDiscoveryFailure> failures;
}

/// Reads and validates plugin directories without executing plugin code.
final class PluginLoader {
  PluginLoader({PluginManifestParser? manifestParser})
    : _manifestParser = manifestParser ?? PluginManifestParser();

  final PluginManifestParser _manifestParser;

  Future<PluginSource> loadDirectory(Directory directory) async {
    final manifestFile = File.fromUri(directory.uri.resolve('manifest.json'));
    if (!await manifestFile.exists()) {
      throw PluginManifestException(
        'Plugin directory does not contain manifest.json.',
        filename: manifestFile.path,
      );
    }

    late final PluginManifest manifest;
    try {
      manifest = _manifestParser.parseString(await manifestFile.readAsString());
    } on PluginManifestException {
      rethrow;
    } on Object catch (error, stackTrace) {
      throw PluginManifestException(
        'Could not read manifest.json.',
        filename: manifestFile.path,
        cause: error,
        causeStackTrace: stackTrace,
      );
    }

    final entrypoint = File.fromUri(directory.uri.resolve(manifest.entrypoint));
    if (!await entrypoint.exists()) {
      throw PluginManifestException(
        'Entrypoint "${manifest.entrypoint}" does not exist.',
        pluginId: manifest.id,
        filename: entrypoint.path,
      );
    }
    await _verifyContained(directory, entrypoint, manifest.id);
    return PluginSource(
      manifest: manifest,
      directoryPath: directory.absolute.path,
      entrypointPath: entrypoint.absolute.path,
    );
  }

  Future<PluginDiscoveryResult> discover(Directory root) async {
    if (!await root.exists()) {
      return PluginDiscoveryResult(plugins: const [], failures: const []);
    }
    final plugins = <PluginSource>[];
    final failures = <PluginDiscoveryFailure>[];
    final byId = <String, PluginSource>{};
    final duplicateIds = <String>{};

    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final segments = entity.uri.pathSegments.where((item) => item.isNotEmpty);
      if (segments.isNotEmpty && segments.last.startsWith('.')) continue;
      try {
        final source = await loadDirectory(entity);
        final existing = byId[source.manifest.id];
        if (existing == null) {
          byId[source.manifest.id] = source;
          plugins.add(source);
        } else {
          duplicateIds.add(source.manifest.id);
          plugins.remove(existing);
          failures
            ..add(
              PluginDiscoveryFailure(
                directoryPath: existing.directoryPath,
                error: PluginManifestException(
                  'Duplicate plugin ID "${source.manifest.id}".',
                  pluginId: source.manifest.id,
                ),
              ),
            )
            ..add(
              PluginDiscoveryFailure(
                directoryPath: source.directoryPath,
                error: PluginManifestException(
                  'Duplicate plugin ID "${source.manifest.id}".',
                  pluginId: source.manifest.id,
                ),
              ),
            );
        }
      } on PluginException catch (error) {
        failures.add(
          PluginDiscoveryFailure(directoryPath: entity.path, error: error),
        );
      } on Object catch (error, stackTrace) {
        failures.add(
          PluginDiscoveryFailure(
            directoryPath: entity.path,
            error: PluginManifestException(
              'Unexpected plugin discovery failure.',
              cause: error,
              causeStackTrace: stackTrace,
            ),
          ),
        );
      }
    }
    plugins.removeWhere((plugin) => duplicateIds.contains(plugin.manifest.id));
    plugins.sort(
      (left, right) => left.manifest.id.compareTo(right.manifest.id),
    );
    return PluginDiscoveryResult(plugins: plugins, failures: failures);
  }

  static Future<void> _verifyContained(
    Directory directory,
    File entrypoint,
    String pluginId,
  ) async {
    try {
      final root = _withTrailingSeparator(
        await directory.resolveSymbolicLinks(),
      );
      final target = await entrypoint.resolveSymbolicLinks();
      final normalizedRoot = Platform.isWindows ? root.toLowerCase() : root;
      final normalizedTarget = Platform.isWindows
          ? target.toLowerCase()
          : target;
      if (!normalizedTarget.startsWith(normalizedRoot)) {
        throw PluginManifestException(
          'Entrypoint resolves outside the plugin directory.',
          pluginId: pluginId,
          filename: entrypoint.path,
        );
      }
      // Source is decoded here so malformed UTF-8 is reported before Lua FFI.
      await entrypoint.openRead().transform(utf8.decoder).drain<void>();
    } on PluginManifestException {
      rethrow;
    } on Object catch (error, stackTrace) {
      throw PluginManifestException(
        'Could not validate the plugin entrypoint.',
        pluginId: pluginId,
        filename: entrypoint.path,
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  static String _withTrailingSeparator(String path) =>
      path.endsWith(Platform.pathSeparator)
      ? path
      : '$path${Platform.pathSeparator}';
}
