import 'dart:async';

import '../errors/plugin_exception.dart';
import '../values/structured_value.dart';

typedef PluginCallbackHandler =
    FutureOr<Object?> Function(List<StructuredValue> arguments);

/// Pointer-free identity implemented by script callbacks.
abstract interface class PluginScriptCallback {
  String get pluginId;
  String get generation;
  int get callbackId;
}

/// A serializable identity for a function owned by one runtime generation.
final class PluginCallbackRef implements PluginScriptCallback {
  const PluginCallbackRef({
    required this.pluginId,
    required this.generation,
    required this.callbackId,
  });

  @override
  final String pluginId;
  @override
  final String generation;
  @override
  final int callbackId;

  @override
  bool operator ==(Object other) =>
      other is PluginCallbackRef &&
      other.pluginId == pluginId &&
      other.generation == generation &&
      other.callbackId == callbackId;

  @override
  int get hashCode => Object.hash(pluginId, generation, callbackId);

  @override
  String toString() => '$pluginId@$generation#$callbackId';
}

/// Owns callbacks for exactly one plugin runtime generation.
///
/// [dispose] stops new invocations and waits for in-flight callbacks. The Lua
/// state can therefore be destroyed after disposal completes.
final class PluginCallbackRegistry {
  PluginCallbackRegistry({
    required this.pluginId,
    required this.generation,
    StructuredValueCodec codec = const StructuredValueCodec(),
  }) : _codec = codec {
    if (pluginId.trim().isEmpty || generation.trim().isEmpty) {
      throw ArgumentError('pluginId and generation must not be empty.');
    }
  }

  final String pluginId;
  final String generation;
  final StructuredValueCodec _codec;
  final Map<int, PluginCallbackHandler> _callbacks = {};
  final Set<Future<void>> _inFlight = {};
  var _nextId = 1;
  var _active = true;

  bool get isActive => _active;
  int get callbackCount => _callbacks.length;

  PluginCallbackRef register(PluginCallbackHandler handler) {
    _ensureActive();
    final id = _nextId++;
    _callbacks[id] = handler;
    return PluginCallbackRef(
      pluginId: pluginId,
      generation: generation,
      callbackId: id,
    );
  }

  bool unregister(PluginCallbackRef reference) {
    if (!_matchesGeneration(reference)) return false;
    return _callbacks.remove(reference.callbackId) != null;
  }

  bool contains(PluginCallbackRef reference) =>
      _active &&
      _matchesGeneration(reference) &&
      _callbacks.containsKey(reference.callbackId);

  Future<Object?> invoke(
    PluginCallbackRef reference, {
    List<StructuredValue> arguments = const [],
    bool requireStructuredResult = true,
  }) async {
    _ensureReference(reference);
    final handler = _callbacks[reference.callbackId]!;
    final normalizedArguments = List<StructuredValue>.unmodifiable(
      arguments.map((value) => _codec.normalize(value, pluginId: pluginId)),
    );
    final completer = Completer<void>();
    final marker = completer.future;
    _inFlight.add(marker);
    try {
      final result = await handler(normalizedArguments);
      return requireStructuredResult
          ? _codec.normalize(result, pluginId: pluginId)
          : result;
    } catch (error, stackTrace) {
      if (error is PluginException) rethrow;
      throw PluginApiException(
        'Plugin callback ${reference.callbackId} failed.',
        pluginId: pluginId,
        cause: error,
        causeStackTrace: stackTrace,
      );
    } finally {
      _inFlight.remove(marker);
      completer.complete();
    }
  }

  /// Invalidates every reference, then waits for callbacks already executing.
  Future<void> dispose() async {
    if (!_active) {
      await Future.wait(List.of(_inFlight));
      return;
    }
    _active = false;
    _callbacks.clear();
    await Future.wait(List.of(_inFlight));
  }

  bool _matchesGeneration(PluginCallbackRef reference) =>
      reference.pluginId == pluginId && reference.generation == generation;

  void _ensureReference(PluginCallbackRef reference) {
    if (!_active ||
        !_matchesGeneration(reference) ||
        !_callbacks.containsKey(reference.callbackId)) {
      throw StalePluginCallbackException(
        'Callback reference $reference is stale.',
        pluginId: pluginId,
      );
    }
  }

  void _ensureActive() {
    if (!_active) {
      throw StalePluginCallbackException(
        'Callback registry has been disposed.',
        pluginId: pluginId,
      );
    }
  }
}
