import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../errors/plugin_exception.dart';

abstract interface class PluginAssetProvider {
  Future<PluginAssetBundle> load({
    required String pluginId,
    required Directory pluginDirectory,
  });
}

/// Immutable, generation-owned snapshot of a plugin's assets directory.
final class PluginAssetBundle {
  PluginAssetBundle({
    required this.pluginId,
    required Map<String, Uint8List> assets,
  }) : _assets = Map.unmodifiable({
         for (final entry in assets.entries)
           entry.key: Uint8List.fromList(entry.value),
       });

  final String pluginId;
  final Map<String, Uint8List> _assets;

  List<String> list([String prefix = '']) {
    final trailingSlash = prefix.endsWith('/');
    final candidate = trailingSlash ? prefix.substring(0, prefix.length - 1) : prefix;
    final normalized = candidate.isEmpty
        ? ''
        : '${_validateAssetPath(candidate)}${trailingSlash ? '/' : ''}';
    return List.unmodifiable(
      _assets.keys.where((path) => path.startsWith(normalized)).toList()
        ..sort(),
    );
  }

  bool contains(String path) => _assets.containsKey(_validateAssetPath(path));

  Uint8List readBytes(String path) {
    final normalized = _validateAssetPath(path);
    final value = _assets[normalized];
    if (value == null) {
      throw PluginAssetException(
        'Plugin asset "$normalized" does not exist.',
        pluginId: pluginId,
        filename: 'assets/$normalized',
      );
    }
    return Uint8List.fromList(value);
  }

  String readText(String path) {
    final normalized = _validateAssetPath(path);
    try {
      return utf8.decode(readBytes(normalized), allowMalformed: false);
    } on FormatException catch (error, stackTrace) {
      throw PluginAssetException(
        'Plugin asset "$normalized" is not valid UTF-8.',
        pluginId: pluginId,
        filename: 'assets/$normalized',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }
}

/// Loads only regular files below `assets/`, rejects links, and applies a
/// bounded in-memory budget before any Lua code executes.
final class DirectoryPluginAssetProvider implements PluginAssetProvider {
  const DirectoryPluginAssetProvider({
    this.maxFiles = 1024,
    this.maxFileBytes = 8 * 1024 * 1024,
    this.maxTotalBytes = 32 * 1024 * 1024,
  });

  final int maxFiles;
  final int maxFileBytes;
  final int maxTotalBytes;

  @override
  Future<PluginAssetBundle> load({
    required String pluginId,
    required Directory pluginDirectory,
  }) async {
    final root = Directory.fromUri(pluginDirectory.uri.resolve('assets/'));
    if (!await root.exists()) {
      return PluginAssetBundle(pluginId: pluginId, assets: const {});
    }
    final assets = <String, Uint8List>{};
    var total = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.directory) continue;
      if (type != FileSystemEntityType.file) {
        throw PluginAssetException(
          'Plugin assets may contain only regular files.',
          pluginId: pluginId,
          filename: entity.path,
        );
      }
      final file = entity as File;
      final length = await file.length();
      total += length;
      if (assets.length >= maxFiles ||
          length > maxFileBytes ||
          total > maxTotalBytes) {
        throw PluginAssetException(
          'Plugin assets exceed host resource limits.',
          pluginId: pluginId,
          filename: entity.path,
        );
      }
      final relative = _relativeAssetPath(root, file.path);
      assets[relative] = await file.readAsBytes();
    }
    return PluginAssetBundle(pluginId: pluginId, assets: assets);
  }
}

String _validateAssetPath(String path) {
  if (path.isEmpty ||
      path.length > 512 ||
      path.startsWith('/') ||
      path.startsWith('\\') ||
      path.contains('\\') ||
      path.contains(RegExp(r'[\x00-\x1f]')) ||
      path
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw ArgumentError.value(path, 'path', 'Invalid plugin asset path');
  }
  return path;
}

String _relativeAssetPath(Directory root, String path) {
  final prefix = root.absolute.path.endsWith(Platform.pathSeparator)
      ? root.absolute.path
      : '${root.absolute.path}${Platform.pathSeparator}';
  final absolute = File(path).absolute.path;
  final normalizedPrefix = Platform.isWindows ? prefix.toLowerCase() : prefix;
  final normalized = Platform.isWindows ? absolute.toLowerCase() : absolute;
  if (!normalized.startsWith(normalizedPrefix)) {
    throw StateError('Asset path escapes its plugin root.');
  }
  return _validateAssetPath(
    absolute.substring(prefix.length).replaceAll('\\', '/'),
  );
}
