import 'dart:collection';
import 'dart:convert';

import '../errors/plugin_exception.dart';

/// Recursive values which are safe to copy between Dart and Lua.
typedef StructuredValue = Object?;

/// Validates and defensively freezes the Dart/Lua interchange value subset.
final class StructuredValueCodec {
  const StructuredValueCodec({
    this.maxDepth = 32,
    this.maxCollectionLength = 10000,
    this.maxStringLength = 1048576,
  });

  final int maxDepth;
  final int maxCollectionLength;
  final int maxStringLength;

  StructuredValue normalize(Object? value, {String? pluginId}) {
    final ancestors = HashSet<Object>.identity();
    var itemCount = 0;

    Object? visit(Object? current, int depth, String path) {
      if (depth > maxDepth) {
        throw PluginApiException(
          'Structured value exceeds maximum depth $maxDepth at $path.',
          pluginId: pluginId ?? '<host>',
        );
      }
      if (current == null || current is bool || current is int) return current;
      if (current is double) {
        if (!current.isFinite) {
          throw PluginApiException(
            'Non-finite number at $path.',
            pluginId: pluginId ?? '<host>',
          );
        }
        return current;
      }
      if (current is String) {
        if (current.length > maxStringLength) {
          throw PluginApiException(
            'String exceeds maximum length $maxStringLength at $path.',
            pluginId: pluginId ?? '<host>',
          );
        }
        return current;
      }
      if (current is List<Object?>) {
        if (!ancestors.add(current)) {
          throw PluginApiException(
            'Cyclic list at $path.',
            pluginId: pluginId ?? '<host>',
          );
        }
        itemCount += current.length;
        _checkItemCount(itemCount, path, pluginId);
        final result = List<Object?>.unmodifiable([
          for (var index = 0; index < current.length; index++)
            visit(current[index], depth + 1, '$path[$index]'),
        ]);
        ancestors.remove(current);
        return result;
      }
      if (current is Map<Object?, Object?>) {
        if (!ancestors.add(current)) {
          throw PluginApiException(
            'Cyclic map at $path.',
            pluginId: pluginId ?? '<host>',
          );
        }
        itemCount += current.length;
        _checkItemCount(itemCount, path, pluginId);
        final result = <String, Object?>{};
        for (final entry in current.entries) {
          if (entry.key is! String) {
            throw PluginApiException(
              'Map key at $path must be a string.',
              pluginId: pluginId ?? '<host>',
            );
          }
          final key = entry.key! as String;
          if (key.length > maxStringLength) {
            throw PluginApiException(
              'Map key exceeds maximum length at $path.',
              pluginId: pluginId ?? '<host>',
            );
          }
          result[key] = visit(entry.value, depth + 1, '$path.$key');
        }
        ancestors.remove(current);
        return Map<String, Object?>.unmodifiable(result);
      }
      throw PluginApiException(
        'Unsupported structured value ${current.runtimeType} at $path.',
        pluginId: pluginId ?? '<host>',
      );
    }

    return visit(value, 0, r'$');
  }

  bool isValid(Object? value) {
    try {
      normalize(value);
      return true;
    } on PluginApiException {
      return false;
    }
  }

  String encode(Object? value, {String? pluginId}) =>
      jsonEncode(normalize(value, pluginId: pluginId));

  StructuredValue decode(String source, {String? pluginId}) {
    try {
      return normalize(jsonDecode(source), pluginId: pluginId);
    } on FormatException catch (error, stackTrace) {
      throw PluginApiException(
        'Invalid structured JSON: ${error.message}',
        pluginId: pluginId ?? '<host>',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  void _checkItemCount(int count, String path, String? pluginId) {
    if (count > maxCollectionLength) {
      throw PluginApiException(
        'Structured value exceeds $maxCollectionLength collection items at '
        '$path.',
        pluginId: pluginId ?? '<host>',
      );
    }
  }
}
