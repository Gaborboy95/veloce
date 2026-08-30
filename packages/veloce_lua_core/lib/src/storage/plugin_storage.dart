import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../errors/plugin_exception.dart';
import '../values/structured_value.dart';

/// A storage view permanently scoped to one plugin ID.
abstract interface class PluginStorage {
  String get pluginId;

  Future<StructuredValue> get(String key);
  Future<bool> containsKey(String key);
  Future<void> set(String key, StructuredValue value);
  Future<void> remove(String key);
  Future<void> clear();
  Future<Map<String, StructuredValue>> snapshot();
}

abstract interface class PluginStorageProvider {
  Future<PluginStorage> open(String pluginId);
  Future<void> deletePlugin(String pluginId);
}

abstract interface class ClosablePluginStorageProvider
    implements PluginStorageProvider {
  Future<void> close();
}

/// In-memory implementation useful for unit tests and ephemeral hosts.
final class MemoryPluginStorageProvider implements PluginStorageProvider {
  MemoryPluginStorageProvider({
    StructuredValueCodec codec = const StructuredValueCodec(),
  }) : _codec = codec;

  final StructuredValueCodec _codec;
  final Map<String, _MemoryPluginStorage> _stores = {};

  @override
  Future<PluginStorage> open(String pluginId) async {
    _validatePluginId(pluginId);
    return _stores.putIfAbsent(
      pluginId,
      () => _MemoryPluginStorage(pluginId: pluginId, codec: _codec),
    );
  }

  @override
  Future<void> deletePlugin(String pluginId) async {
    _stores.remove(pluginId);
  }
}

final class _MemoryPluginStorage implements PluginStorage {
  _MemoryPluginStorage({required this.pluginId, required this.codec});

  @override
  final String pluginId;
  final StructuredValueCodec codec;
  final Map<String, StructuredValue> _values = {};

  @override
  Future<void> clear() async => _values.clear();

  @override
  Future<bool> containsKey(String key) async {
    _validateStorageKey(key);
    return _values.containsKey(key);
  }

  @override
  Future<StructuredValue> get(String key) async {
    _validateStorageKey(key);
    return _values[key];
  }

  @override
  Future<void> remove(String key) async {
    _validateStorageKey(key);
    _values.remove(key);
  }

  @override
  Future<void> set(String key, StructuredValue value) async {
    _validateStorageKey(key);
    _values[key] = codec.normalize(value, pluginId: pluginId);
  }

  @override
  Future<Map<String, StructuredValue>> snapshot() async =>
      Map.unmodifiable(_values);
}

/// JSON-backed, plugin-scoped persistent storage.
///
/// Storage filenames are base64url-encoded plugin IDs, preventing path escape.
/// Writes use a same-directory temporary file and replace sequence.
final class JsonPluginStorageProvider implements PluginStorageProvider {
  JsonPluginStorageProvider({
    required this.rootDirectory,
    StructuredValueCodec codec = const StructuredValueCodec(),
  }) : _codec = codec;

  final Directory rootDirectory;
  final StructuredValueCodec _codec;
  final Map<String, _JsonPluginStorage> _stores = {};

  @override
  Future<PluginStorage> open(String pluginId) async {
    _validatePluginId(pluginId);
    return _stores.putIfAbsent(
      pluginId,
      () => _JsonPluginStorage(
        pluginId: pluginId,
        file: File(_pathFor(pluginId)),
        codec: _codec,
      ),
    );
  }

  @override
  Future<void> deletePlugin(String pluginId) async {
    _validatePluginId(pluginId);
    _stores.remove(pluginId);
    final file = File(_pathFor(pluginId));
    if (await file.exists()) await file.delete();
  }

  String _pathFor(String pluginId) {
    final encoded = base64Url.encode(utf8.encode(pluginId)).replaceAll('=', '');
    return '${rootDirectory.path}${Platform.pathSeparator}$encoded.json';
  }
}

final class _JsonPluginStorage implements PluginStorage {
  _JsonPluginStorage({
    required this.pluginId,
    required this.file,
    required this.codec,
  });

  @override
  final String pluginId;
  final File file;
  final StructuredValueCodec codec;
  final Map<String, StructuredValue> _values = {};
  Future<void> _operationTail = Future<void>.value();
  bool _loaded = false;

  @override
  Future<void> clear() => _serialized(() async {
    await _ensureLoaded();
    _values.clear();
    await _persist();
  });

  @override
  Future<bool> containsKey(String key) {
    _validateStorageKey(key);
    return _serialized(() async {
      await _ensureLoaded();
      return _values.containsKey(key);
    });
  }

  @override
  Future<StructuredValue> get(String key) {
    _validateStorageKey(key);
    return _serialized(() async {
      await _ensureLoaded();
      return _values[key];
    });
  }

  @override
  Future<void> remove(String key) {
    _validateStorageKey(key);
    return _serialized(() async {
      await _ensureLoaded();
      final existed = _values.containsKey(key);
      _values.remove(key);
      if (existed) await _persist();
    });
  }

  @override
  Future<void> set(String key, StructuredValue value) {
    _validateStorageKey(key);
    final normalized = codec.normalize(value, pluginId: pluginId);
    return _serialized(() async {
      await _ensureLoaded();
      _values[key] = normalized;
      await _persist();
    });
  }

  @override
  Future<Map<String, StructuredValue>> snapshot() => _serialized(() async {
    await _ensureLoaded();
    return Map.unmodifiable(_values);
  });

  Future<T> _serialized<T>(FutureOr<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    if (!await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Storage root is not an object.');
      }
      for (final entry in decoded.entries) {
        _validateStorageKey(entry.key);
        _values[entry.key] = codec.normalize(entry.value, pluginId: pluginId);
      }
    } catch (error, stackTrace) {
      _loaded = false;
      throw PluginStorageException(
        'Could not read plugin storage.',
        pluginId: pluginId,
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  Future<void> _persist() async {
    try {
      await file.parent.create(recursive: true);
      final unique = DateTime.now().microsecondsSinceEpoch;
      final temporary = File('${file.path}.tmp.$unique');
      final backup = File('${file.path}.bak.$unique');
      await temporary.writeAsString(jsonEncode(_values), flush: true);
      final hadOriginal = await file.exists();
      if (hadOriginal) await file.rename(backup.path);
      try {
        await temporary.rename(file.path);
        if (hadOriginal && await backup.exists()) await backup.delete();
      } catch (_) {
        if (await temporary.exists()) await temporary.delete();
        if (hadOriginal && await backup.exists() && !await file.exists()) {
          await backup.rename(file.path);
        }
        rethrow;
      }
    } catch (error, stackTrace) {
      throw PluginStorageException(
        'Could not persist plugin storage.',
        pluginId: pluginId,
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }
}

/// SQLite-backed storage with one composite-key table for every plugin.
///
/// Values remain restricted to the structured Dart/Lua bridge model and are
/// encoded as JSON. All access to the synchronous SQLite connection is
/// serialized; a host with heavy storage traffic can wrap this provider in a
/// dedicated storage isolate without changing [PluginStorage].
final class SqlitePluginStorageProvider
    implements ClosablePluginStorageProvider {
  SqlitePluginStorageProvider({
    required this.databaseFile,
    StructuredValueCodec codec = const StructuredValueCodec(),
  }) : _codec = codec;

  final File databaseFile;
  final StructuredValueCodec _codec;
  final Map<String, _SqlitePluginStorage> _stores = {};
  Future<void> _operationTail = Future<void>.value();
  sqlite.Database? _database;
  var _closed = false;

  @override
  Future<PluginStorage> open(String pluginId) async {
    _validatePluginId(pluginId);
    _ensureNotClosed();
    await _ensureDatabase();
    return _stores.putIfAbsent(
      pluginId,
      () => _SqlitePluginStorage(provider: this, pluginId: pluginId),
    );
  }

  @override
  Future<void> deletePlugin(String pluginId) {
    _validatePluginId(pluginId);
    return _serialized((database) {
      database.execute('DELETE FROM plugin_storage WHERE plugin_id = ?', [
        pluginId,
      ]);
      _stores.remove(pluginId);
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _operationTail;
    _stores.clear();
    _database?.close();
    _database = null;
  }

  Future<T> _serialized<T>(T Function(sqlite.Database database) operation) {
    _ensureNotClosed();
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        final database = await _ensureDatabase();
        completer.complete(operation(database));
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<sqlite.Database> _ensureDatabase() async {
    _ensureNotClosed();
    if (_database case final current?) return current;
    try {
      await databaseFile.parent.create(recursive: true);
      final database = sqlite.sqlite3.open(databaseFile.path);
      database
        ..execute('PRAGMA journal_mode = WAL')
        ..execute('PRAGMA synchronous = NORMAL')
        ..execute('''
CREATE TABLE IF NOT EXISTS plugin_storage (
  plugin_id TEXT NOT NULL,
  storage_key TEXT NOT NULL,
  value_json TEXT NOT NULL,
  PRIMARY KEY (plugin_id, storage_key)
) WITHOUT ROWID
''');
      _database = database;
      return database;
    } on Object catch (error, stackTrace) {
      throw PluginStorageException(
        'Could not open SQLite plugin storage.',
        pluginId: '<host>',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  void _ensureNotClosed() {
    if (_closed) throw StateError('SQLite plugin storage is closed.');
  }
}

final class _SqlitePluginStorage implements PluginStorage {
  const _SqlitePluginStorage({required this.provider, required this.pluginId});

  final SqlitePluginStorageProvider provider;
  @override
  final String pluginId;

  @override
  Future<void> clear() => provider._serialized((database) {
    database.execute('DELETE FROM plugin_storage WHERE plugin_id = ?', [
      pluginId,
    ]);
  });

  @override
  Future<bool> containsKey(String key) {
    _validateStorageKey(key);
    return provider._serialized((database) {
      final rows = database.select(
        'SELECT 1 FROM plugin_storage '
        'WHERE plugin_id = ? AND storage_key = ? LIMIT 1',
        [pluginId, key],
      );
      return rows.isNotEmpty;
    });
  }

  @override
  Future<StructuredValue> get(String key) {
    _validateStorageKey(key);
    return provider._serialized((database) {
      final rows = database.select(
        'SELECT value_json FROM plugin_storage '
        'WHERE plugin_id = ? AND storage_key = ? LIMIT 1',
        [pluginId, key],
      );
      if (rows.isEmpty) return null;
      return provider._codec.normalize(
        jsonDecode(rows.single['value_json']! as String),
        pluginId: pluginId,
      );
    });
  }

  @override
  Future<void> remove(String key) {
    _validateStorageKey(key);
    return provider._serialized((database) {
      database.execute(
        'DELETE FROM plugin_storage '
        'WHERE plugin_id = ? AND storage_key = ?',
        [pluginId, key],
      );
    });
  }

  @override
  Future<void> set(String key, StructuredValue value) {
    _validateStorageKey(key);
    final normalized = provider._codec.normalize(value, pluginId: pluginId);
    final encoded = jsonEncode(normalized);
    return provider._serialized((database) {
      database.execute(
        'INSERT INTO plugin_storage(plugin_id, storage_key, value_json) '
        'VALUES (?, ?, ?) '
        'ON CONFLICT(plugin_id, storage_key) DO UPDATE '
        'SET value_json = excluded.value_json',
        [pluginId, key, encoded],
      );
    });
  }

  @override
  Future<Map<String, StructuredValue>> snapshot() =>
      provider._serialized((database) {
        final rows = database.select(
          'SELECT storage_key, value_json FROM plugin_storage '
          'WHERE plugin_id = ? ORDER BY storage_key',
          [pluginId],
        );
        return Map.unmodifiable({
          for (final row in rows)
            row['storage_key']! as String: provider._codec.normalize(
              jsonDecode(row['value_json']! as String),
              pluginId: pluginId,
            ),
        });
      });
}

void _validatePluginId(String pluginId) {
  if (pluginId.trim().isEmpty || pluginId.length > 256) {
    throw ArgumentError.value(pluginId, 'pluginId', 'Invalid plugin ID');
  }
}

void _validateStorageKey(String key) {
  if (key.isEmpty || key.length > 256 || key.contains(RegExp(r'[\x00-\x1f]'))) {
    throw ArgumentError.value(key, 'key', 'Invalid storage key');
  }
}
