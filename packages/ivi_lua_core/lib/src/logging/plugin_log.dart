import 'dart:async';
import 'dart:collection';

import '../values/structured_value.dart';

enum PluginLogLevel { debug, info, warning, error }

final class PluginLogEvent {
  const PluginLogEvent({
    required this.pluginId,
    required this.level,
    required this.message,
    required this.timestamp,
    this.metadata,
  });

  final String pluginId;
  final PluginLogLevel level;
  final String message;
  final DateTime timestamp;
  final StructuredValue metadata;
}

/// Bounded log history and live stream for a developer console.
final class PluginLogManager {
  PluginLogManager({
    this.maxHistory = 1000,
    StructuredValueCodec codec = const StructuredValueCodec(),
  })  : assert(maxHistory > 0),
        _codec = codec;

  final int maxHistory;
  final StructuredValueCodec _codec;
  final Queue<PluginLogEvent> _history = Queue();
  final StreamController<PluginLogEvent> _events =
      StreamController<PluginLogEvent>.broadcast(sync: true);
  var _closed = false;

  Stream<PluginLogEvent> get events => _events.stream;
  List<PluginLogEvent> get recent => List.unmodifiable(_history);

  PluginLogger logger(String pluginId) {
    if (pluginId.trim().isEmpty) {
      throw ArgumentError.value(pluginId, 'pluginId', 'Must not be empty');
    }
    return PluginLogger._(pluginId: pluginId, manager: this);
  }

  void clear() => _history.clear();

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _events.close();
  }

  void _write({
    required String pluginId,
    required PluginLogLevel level,
    required String message,
    StructuredValue metadata,
  }) {
    if (_closed) return;
    final event = PluginLogEvent(
      pluginId: pluginId,
      level: level,
      message: message.length <= 16384
          ? message
          : '${message.substring(0, 16381)}...',
      timestamp: DateTime.now().toUtc(),
      metadata: metadata == null
          ? null
          : _codec.normalize(metadata, pluginId: pluginId),
    );
    while (_history.length >= maxHistory) {
      _history.removeFirst();
    }
    _history.addLast(event);
    _events.add(event);
  }
}

/// Logger permanently scoped to a plugin, so Lua cannot spoof another owner.
final class PluginLogger {
  const PluginLogger._(
      {required this.pluginId, required PluginLogManager manager})
      : _manager = manager;

  final String pluginId;
  final PluginLogManager _manager;

  void debug(Object? message, {StructuredValue metadata}) =>
      log(PluginLogLevel.debug, message, metadata: metadata);

  void info(Object? message, {StructuredValue metadata}) =>
      log(PluginLogLevel.info, message, metadata: metadata);

  void warning(Object? message, {StructuredValue metadata}) =>
      log(PluginLogLevel.warning, message, metadata: metadata);

  void error(Object? message, {StructuredValue metadata}) =>
      log(PluginLogLevel.error, message, metadata: metadata);

  void log(
    PluginLogLevel level,
    Object? message, {
    StructuredValue metadata,
  }) {
    _manager._write(
      pluginId: pluginId,
      level: level,
      message: message?.toString() ?? 'nil',
      metadata: metadata,
    );
  }
}
