import 'dart:async';

import '../errors/plugin_exception.dart';
import '../manifest/plugin_manifest.dart';
import '../runtime/plugin_state.dart';

final class PluginRecord {
  const PluginRecord({
    required this.directoryPath,
    required this.manifest,
    required this.state,
    required this.enabled,
    this.latestError,
    this.generation,
  });

  final String directoryPath;
  final PluginManifest manifest;
  final PluginState state;
  final bool enabled;
  final PluginException? latestError;
  final String? generation;

  PluginRecord copyWith({
    PluginManifest? manifest,
    PluginState? state,
    bool? enabled,
    PluginException? latestError,
    bool clearError = false,
    String? generation,
    bool clearGeneration = false,
  }) =>
      PluginRecord(
        directoryPath: directoryPath,
        manifest: manifest ?? this.manifest,
        state: state ?? this.state,
        enabled: enabled ?? this.enabled,
        latestError: clearError ? null : latestError ?? this.latestError,
        generation: clearGeneration ? null : generation ?? this.generation,
      );
}

final class PluginRegistry {
  final Map<String, PluginRecord> _records = {};
  final StreamController<List<PluginRecord>> _changes =
      StreamController.broadcast(sync: true);

  List<PluginRecord> get current => List.unmodifiable(
        _records.values.toList()
          ..sort(
              (left, right) => left.manifest.id.compareTo(right.manifest.id)),
      );
  Stream<List<PluginRecord>> get records async* {
    yield current;
    yield* _changes.stream;
  }

  PluginRecord? operator [](String pluginId) => _records[pluginId];

  void put(PluginRecord record) {
    _records[record.manifest.id] = record;
    _emit();
  }

  PluginRecord update(
      String pluginId, PluginRecord Function(PluginRecord) edit) {
    final current = _records[pluginId];
    if (current == null) throw StateError('Unknown plugin $pluginId.');
    final updated = edit(current);
    _records[pluginId] = updated;
    _emit();
    return updated;
  }

  bool remove(String pluginId) {
    final removed = _records.remove(pluginId) != null;
    if (removed) _emit();
    return removed;
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(current);
  }

  Future<void> close() => _changes.close();
}
