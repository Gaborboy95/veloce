import 'dart:async';

/// An immutable contribution to a named host extension point.
final class PluginExtension<T extends Object> {
  const PluginExtension({
    required this.extensionPoint,
    required this.pluginId,
    required this.id,
    required this.value,
  });

  final String extensionPoint;
  final String pluginId;
  final String id;
  final T value;
}

final class PluginExtensionChange {
  const PluginExtensionChange({
    required this.extensionPoint,
    required this.pluginId,
  });

  final String extensionPoint;
  final String pluginId;
}

/// Generic owner-aware registry for tabs and future host extension points.
final class PluginExtensionRegistry {
  final Map<String, Map<String, PluginExtension<Object>>> _byPoint = {};
  final StreamController<PluginExtensionChange> _changes =
      StreamController<PluginExtensionChange>.broadcast(sync: true);
  var _closed = false;

  Stream<PluginExtensionChange> get changes => _changes.stream;

  void register<T extends Object>(PluginExtension<T> extension) {
    _ensureOpen();
    _validate(extension.extensionPoint, 'extensionPoint');
    _validate(extension.pluginId, 'pluginId');
    _validate(extension.id, 'id');
    final entries = _byPoint.putIfAbsent(extension.extensionPoint, () => {});
    entries[_key(extension.pluginId, extension.id)] = PluginExtension<Object>(
      extensionPoint: extension.extensionPoint,
      pluginId: extension.pluginId,
      id: extension.id,
      value: extension.value,
    );
    _changes.add(
      PluginExtensionChange(
        extensionPoint: extension.extensionPoint,
        pluginId: extension.pluginId,
      ),
    );
  }

  /// Validates first, then atomically swaps all contributions for one owner.
  void replaceForPlugin<T extends Object>({
    required String extensionPoint,
    required String pluginId,
    required Iterable<PluginExtension<T>> extensions,
  }) {
    _ensureOpen();
    _validate(extensionPoint, 'extensionPoint');
    _validate(pluginId, 'pluginId');
    final replacements = extensions.toList(growable: false);
    final ids = <String>{};
    for (final extension in replacements) {
      if (extension.extensionPoint != extensionPoint ||
          extension.pluginId != pluginId) {
        throw ArgumentError(
          'Every replacement must have the requested point and plugin owner.',
        );
      }
      _validate(extension.id, 'id');
      if (!ids.add(extension.id)) {
        throw ArgumentError.value(extension.id, 'extensions', 'Duplicate ID');
      }
    }
    final entries = _byPoint.putIfAbsent(extensionPoint, () => {});
    entries.removeWhere((_, extension) => extension.pluginId == pluginId);
    for (final extension in replacements) {
      entries[_key(pluginId, extension.id)] = PluginExtension<Object>(
        extensionPoint: extensionPoint,
        pluginId: pluginId,
        id: extension.id,
        value: extension.value,
      );
    }
    _changes.add(
      PluginExtensionChange(extensionPoint: extensionPoint, pluginId: pluginId),
    );
  }

  bool unregister({
    required String extensionPoint,
    required String pluginId,
    required String id,
  }) {
    if (_closed) return false;
    final removed = _byPoint[extensionPoint]?.remove(_key(pluginId, id));
    if (removed == null) return false;
    _changes.add(
      PluginExtensionChange(extensionPoint: extensionPoint, pluginId: pluginId),
    );
    return true;
  }

  void unregisterPlugin(String pluginId) {
    if (_closed) return;
    for (final point in _byPoint.keys.toList(growable: false)) {
      final entries = _byPoint[point]!;
      final before = entries.length;
      entries.removeWhere((_, extension) => extension.pluginId == pluginId);
      if (before != entries.length) {
        _changes.add(
          PluginExtensionChange(extensionPoint: point, pluginId: pluginId),
        );
      }
    }
  }

  List<PluginExtension<T>> extensions<T extends Object>(String point) =>
      List.unmodifiable(
        (_byPoint[point]?.values ?? const <PluginExtension<Object>>[])
            .where((extension) => extension.value is T)
            .map(
              (extension) => PluginExtension<T>(
                extensionPoint: extension.extensionPoint,
                pluginId: extension.pluginId,
                id: extension.id,
                value: extension.value as T,
              ),
            ),
      );

  Stream<List<PluginExtension<T>>> watch<T extends Object>(
    String point,
  ) async* {
    yield extensions<T>(point);
    await for (final change in changes) {
      if (change.extensionPoint == point) yield extensions<T>(point);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _byPoint.clear();
    await _changes.close();
  }

  String _key(String pluginId, String id) => '$pluginId\u0000$id';

  void _ensureOpen() {
    if (_closed) throw StateError('PluginExtensionRegistry is closed.');
  }

  static void _validate(String value, String name) {
    if (value.trim().isEmpty || value.length > 256) {
      throw ArgumentError.value(value, name, 'Must not be empty');
    }
  }
}
