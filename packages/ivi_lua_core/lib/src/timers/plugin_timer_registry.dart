import 'dart:async';

import '../callbacks/plugin_callback_registry.dart';
import '../errors/plugin_exception.dart';
import '../runtime/plugin_state.dart';
import '../values/structured_value.dart';

typedef PluginTimerCallbackInvoker = FutureOr<Object?> Function(
  PluginCallbackRef callback,
  List<StructuredValue> arguments,
);

typedef PluginTimerErrorHandler = void Function(
  Object error,
  StackTrace stackTrace,
  String pluginId,
);

final class PluginTimerHandle {
  const PluginTimerHandle({
    required this.pluginId,
    required this.generation,
    required this.timerId,
  });

  final String pluginId;
  final String generation;
  final int timerId;
}

/// Owns bounded timeout/interval resources for a runtime generation.
final class PluginTimerRegistry {
  PluginTimerRegistry({
    required this.pluginId,
    required this.generation,
    required PluginTimerCallbackInvoker invokeCallback,
    this.maxTimers = 128,
    this.minimumInterval = const Duration(milliseconds: 10),
    this.maximumDelay = const Duration(days: 1),
    this.onError,
    StructuredValueCodec codec = const StructuredValueCodec(),
  })  : assert(maxTimers > 0),
        _invokeCallback = invokeCallback,
        _codec = codec;

  final String pluginId;
  final String generation;
  final int maxTimers;
  final Duration minimumInterval;
  final Duration maximumDelay;
  final PluginTimerCallbackInvoker _invokeCallback;
  final PluginTimerErrorHandler? onError;
  final StructuredValueCodec _codec;
  final Map<int, _OwnedTimer> _timers = {};
  final Set<Future<void>> _inFlight = {};
  var _nextId = 1;
  var _active = true;

  int get activeTimerCount => _timers.length;
  bool get isActive => _active;

  PluginTimerHandle setTimeout(
    Duration delay,
    PluginCallbackRef callback, {
    List<StructuredValue> arguments = const [],
  }) =>
      _create(
        delay: delay,
        callback: callback,
        arguments: arguments,
        repeating: false,
      );

  PluginTimerHandle setInterval(
    Duration interval,
    PluginCallbackRef callback, {
    List<StructuredValue> arguments = const [],
  }) =>
      _create(
        delay: interval,
        callback: callback,
        arguments: arguments,
        repeating: true,
      );

  bool cancel(PluginTimerHandle handle) {
    if (handle.pluginId != pluginId || handle.generation != generation) {
      return false;
    }
    final owned = _timers.remove(handle.timerId);
    owned?.timer.cancel();
    return owned != null;
  }

  Future<void> dispose() async {
    if (_active) {
      _active = false;
      for (final timer in _timers.values) {
        timer.timer.cancel();
      }
      _timers.clear();
    }
    await Future.wait(List.of(_inFlight));
  }

  PluginTimerHandle _create({
    required Duration delay,
    required PluginCallbackRef callback,
    required List<StructuredValue> arguments,
    required bool repeating,
  }) {
    if (!_active) {
      throw PluginApiException(
        'Timer registry is disposed.',
        pluginId: pluginId,
        phase: PluginLifecyclePhase.timer,
      );
    }
    if (callback.pluginId != pluginId || callback.generation != generation) {
      throw StalePluginCallbackException(
        'Timer callback belongs to a stale runtime generation.',
        pluginId: pluginId,
      );
    }
    if (delay.isNegative || delay > maximumDelay) {
      throw PluginApiException(
        'Timer delay must be between zero and $maximumDelay.',
        pluginId: pluginId,
        phase: PluginLifecyclePhase.timer,
      );
    }
    if (repeating && delay < minimumInterval) {
      throw PluginApiException(
        'Timer interval must be at least $minimumInterval.',
        pluginId: pluginId,
        phase: PluginLifecyclePhase.timer,
      );
    }
    if (_timers.length >= maxTimers) {
      throw PluginApiException(
        'Plugin timer limit of $maxTimers reached.',
        pluginId: pluginId,
        phase: PluginLifecyclePhase.timer,
      );
    }
    final normalizedArguments = List<StructuredValue>.unmodifiable(
      arguments.map((value) => _codec.normalize(value, pluginId: pluginId)),
    );
    final id = _nextId++;
    late final Timer timer;
    timer = repeating
        ? Timer.periodic(delay, (_) => _fire(id))
        : Timer(delay, () => _fire(id));
    _timers[id] = _OwnedTimer(
      timer: timer,
      callback: callback,
      arguments: normalizedArguments,
      repeating: repeating,
    );
    return PluginTimerHandle(
      pluginId: pluginId,
      generation: generation,
      timerId: id,
    );
  }

  void _fire(int id) {
    final owned = _timers[id];
    if (!_active || owned == null || owned.running) return;
    if (!owned.repeating) {
      _timers.remove(id);
      owned.timer.cancel();
    }
    owned.running = true;
    late final Future<void> invocation;
    invocation = Future<void>.sync(() async {
      try {
        await _invokeCallback(owned.callback, owned.arguments);
      } catch (error, stackTrace) {
        try {
          onError?.call(error, stackTrace, pluginId);
        } catch (_) {
          // Error reporters must not escape a timer zone.
        }
      }
    }).whenComplete(() {
      owned.running = false;
      _inFlight.remove(invocation);
    });
    _inFlight.add(invocation);
  }
}

final class _OwnedTimer {
  _OwnedTimer({
    required this.timer,
    required this.callback,
    required this.arguments,
    required this.repeating,
  });

  final Timer timer;
  final PluginCallbackRef callback;
  final List<StructuredValue> arguments;
  final bool repeating;
  bool running = false;
}
