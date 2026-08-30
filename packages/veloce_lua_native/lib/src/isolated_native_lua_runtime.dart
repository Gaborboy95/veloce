import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:veloce_lua_core/veloce_lua_core.dart';

import 'native_bindings.dart';
import 'native_lua_runtime.dart';

/// Creates one Dart isolate and one native Lua state per plugin generation.
///
/// Lua execution and isolate-local native callbacks never run on Flutter's UI
/// isolate. Host API calls cross back as structured messages and are checked by
/// the original [PluginApiRegistry].
final class IsolatedNativeLuaRuntimeFactory
    implements PluginScriptRuntimeFactory {
  IsolatedNativeLuaRuntimeFactory({
    this.libraryPath,
    this.sandboxPolicy = const LuaSandboxPolicy(),
  }) : _hostBindings = NativeLuaBindings.open(libraryPath: libraryPath);

  final String? libraryPath;
  final LuaSandboxPolicy sandboxPolicy;
  final NativeLuaBindings _hostBindings;

  String get luaVersion =>
      _hostBindings.version().cast<Utf8>().toDartString();

  @override
  Future<PluginScriptRuntime> create({
    required PluginManifest manifest,
    required String pluginDirectory,
    required String generation,
    required PluginApiRegistry apiRegistry,
  }) => _IsolatedNativeLuaRuntime.start(
        manifest: manifest,
        pluginDirectory: pluginDirectory,
        generation: generation,
        apiRegistry: apiRegistry,
        bindings: _hostBindings,
        libraryPath: libraryPath,
        sandboxPolicy: sandboxPolicy,
      );
}

final class _IsolatedNativeLuaRuntime implements PluginScriptRuntime {
  _IsolatedNativeLuaRuntime._({
    required this.manifest,
    required this.generation,
    required PluginApiRegistry apiRegistry,
    required NativeLuaBindings bindings,
  })  : _apiRegistry = apiRegistry,
        _bindings = bindings;

  static Future<_IsolatedNativeLuaRuntime> start({
    required PluginManifest manifest,
    required String pluginDirectory,
    required String generation,
    required PluginApiRegistry apiRegistry,
    required NativeLuaBindings bindings,
    required String? libraryPath,
    required LuaSandboxPolicy sandboxPolicy,
  }) async {
    final runtime = _IsolatedNativeLuaRuntime._(
      manifest: manifest,
      generation: generation,
      apiRegistry: apiRegistry,
      bindings: bindings,
    );
    await runtime._spawn(
      pluginDirectory: pluginDirectory,
      libraryPath: libraryPath,
      sandboxPolicy: sandboxPolicy,
    );
    return runtime;
  }

  @override
  final PluginManifest manifest;
  @override
  final String generation;
  final PluginApiRegistry _apiRegistry;
  final NativeLuaBindings _bindings;
  final ReceivePort _messages = ReceivePort();
  final ReceivePort _errors = ReceivePort();
  final ReceivePort _exits = ReceivePort();
  final Map<int, Completer<Object?>> _pending = {};
  final Completer<SendPort> _ready = Completer<SendPort>();
  late final StreamSubscription<Object?> _messageSubscription;
  late final StreamSubscription<Object?> _errorSubscription;
  late final StreamSubscription<Object?> _exitSubscription;
  Isolate? _isolate;
  SendPort? _commands;
  var _nextRequestId = 1;
  var _disposeRequested = false;
  var _disposed = false;

  @override
  bool get isDisposed => _disposeRequested || _disposed;

  Future<void> _spawn({
    required String pluginDirectory,
    required String? libraryPath,
    required LuaSandboxPolicy sandboxPolicy,
  }) async {
    _messageSubscription = _messages.listen(_handleMessage);
    _errorSubscription = _errors.listen(_handleIsolateError);
    _exitSubscription = _exits.listen((_) => _handleUnexpectedExit());
    final descriptors = [
      for (final namespace in _apiRegistry.namespaces)
        {
          'name': namespace.name,
          'methods': [
            for (final entry in namespace.methods.entries)
              {
                'name': entry.key,
                'capability': entry.value.capability.name,
              },
          ],
        },
    ];
    try {
      _isolate = await Isolate.spawn<Map<String, Object?>>(
        _pluginIsolateMain,
        {
          'hostPort': _messages.sendPort,
          'manifest': manifest.toJson(),
          'pluginDirectory': pluginDirectory,
          'generation': generation,
          'libraryPath': libraryPath,
          'policy': _encodePolicy(sandboxPolicy),
          'api': descriptors,
        },
        debugName: 'veloce:${manifest.id}:$generation',
        onError: _errors.sendPort,
        onExit: _exits.sendPort,
        errorsAreFatal: true,
      );
      _commands = await _ready.future;
    } on Object {
      await _shutdownPorts(kill: true);
      rethrow;
    }
  }

  @override
  Future<void> loadEntrypoint() async {
    await _command<void>('load');
  }

  @override
  Future<bool> hasFunction(String name) async =>
      (await _command<bool>('has', payload: {'name': name}))!;

  @override
  Future<StructuredValue> invokeFunction(
    String name, {
    List<StructuredValue> arguments = const [],
  }) => _command<StructuredValue>(
        'invoke',
        payload: {'name': name, 'arguments': arguments},
      );

  @override
  Future<StructuredValue> invokeCallback(
    PluginScriptCallback callback, {
    List<StructuredValue> arguments = const [],
  }) {
    if (callback.pluginId != manifest.id ||
        callback.generation != generation) {
      return Future.error(
        StalePluginCallbackException(
          'Callback belongs to another plugin generation.',
          pluginId: manifest.id,
        ),
      );
    }
    return _command<StructuredValue>(
      'callback',
      payload: {
        'callbackId': callback.callbackId,
        'arguments': arguments,
      },
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    if (_disposeRequested) {
      while (!_disposed) {
        await Future<void>.delayed(Duration.zero);
      }
      return;
    }
    _disposeRequested = true;
    try {
      if (_commands != null) {
        await _command<void>('dispose', allowDisposing: true);
      }
    } finally {
      _disposed = true;
      await _shutdownPorts(kill: true);
    }
  }

  Future<T?> _command<T>(
    String operation, {
    Map<String, Object?> payload = const {},
    bool allowDisposing = false,
  }) {
    if (_disposed || (_disposeRequested && !allowDisposing)) {
      return Future.error(
        StalePluginCallbackException(
          'Lua runtime generation $generation is disposed.',
          pluginId: manifest.id,
        ),
      );
    }
    final port = _commands;
    if (port == null) {
      return Future.error(
        PluginLoadException(
          'Plugin isolate is not ready.',
          pluginId: manifest.id,
        ),
      );
    }
    final id = _nextRequestId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    port.send({'type': 'command', 'id': id, 'operation': operation, ...payload});
    return completer.future.then((value) => value as T?);
  }

  void _handleMessage(Object? raw) {
    if (raw is! Map<Object?, Object?>) return;
    switch (raw['type']) {
      case 'ready':
        final port = raw['port'];
        if (port is SendPort && !_ready.isCompleted) _ready.complete(port);
      case 'result':
        final id = raw['id'];
        if (id is! int) return;
        final completer = _pending.remove(id);
        if (completer == null) return;
        if (raw['ok'] == true) {
          completer.complete(raw['value']);
        } else {
          completer.completeError(_decodeRemoteError(raw['error']));
        }
      case 'api':
        _handleApiCall(raw);
      case 'startupError':
        final error = _decodeRemoteError(raw['error']);
        if (!_ready.isCompleted) _ready.completeError(error);
    }
  }

  void _handleApiCall(Map<Object?, Object?> raw) {
    final address = raw['handle'];
    if (address is! int) return;
    Object? response;
    try {
      final rawArguments = raw['arguments'];
      if (raw['pluginId'] != manifest.id ||
          raw['generation'] != generation ||
          raw['namespace'] is! String ||
          raw['method'] is! String ||
          rawArguments is! List<Object?>) {
        throw PluginApiException(
          'Malformed plugin-isolate API request.',
          pluginId: manifest.id,
        );
      }
      final arguments = <PluginApiArgument>[
        for (final item in rawArguments)
          _decodeApiArgument(item, pluginId: manifest.id, generation: generation),
      ];
      final value = _apiRegistry.invoke(
        PluginApiCall(
          pluginId: manifest.id,
          generation: generation,
          namespace: raw['namespace']! as String,
          method: raw['method']! as String,
          arguments: arguments,
        ),
      );
      response = {'ok': true, 'value': value};
    } on Object catch (error) {
      response = {'ok': false, 'error': error.toString()};
    }
    _completeRpc(address, response);
  }

  void _completeRpc(int address, Object? response) {
    Uint8List encoded;
    try {
      encoded = Uint8List.fromList(utf8.encode(jsonEncode(response)));
    } on Object catch (error) {
      encoded = Uint8List.fromList(
        utf8.encode(jsonEncode({'ok': false, 'error': error.toString()})),
      );
    }
    final native = calloc<Uint8>(encoded.length);
    try {
      native.asTypedList(encoded.length).setAll(0, encoded);
      _bindings.rpcComplete(
        Pointer<VeloceLuaRpc>.fromAddress(address),
        native,
        encoded.length,
      );
    } finally {
      calloc.free(native);
    }
  }

  void _handleIsolateError(Object? raw) {
    final message = raw is List && raw.isNotEmpty ? raw.first.toString() : '$raw';
    final stack = raw is List && raw.length > 1 ? raw[1].toString() : null;
    final error = PluginLoadException(
      'Plugin isolate terminated: $message',
      pluginId: manifest.id,
      causeStackTrace: stack == null ? null : StackTrace.fromString(stack),
    );
    if (!_ready.isCompleted) _ready.completeError(error);
    _failPending(error);
  }

  void _handleUnexpectedExit() {
    if (_disposed || _disposeRequested) return;
    _failPending(
      PluginLoadException(
        'Plugin isolate exited unexpectedly.',
        pluginId: manifest.id,
      ),
    );
  }

  void _failPending(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  Future<void> _shutdownPorts({required bool kill}) async {
    if (kill) _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _messages.close();
    _errors.close();
    _exits.close();
    await _messageSubscription.cancel();
    await _errorSubscription.cancel();
    await _exitSubscription.cancel();
  }
}

void _pluginIsolateMain(Map<String, Object?> initial) async {
  final hostPort = initial['hostPort']! as SendPort;
  final commandPort = ReceivePort();
  PluginScriptRuntime? runtime;
  try {
    final manifestMap = (initial['manifest']! as Map<Object?, Object?>).map(
      (key, value) => MapEntry(key as String, value),
    );
    final descriptors = initial['api']! as List<Object?>;
    final capabilityNames = <String>{
      ...BuiltInCapabilities.all.map((item) => item.name),
      for (final permission in manifestMap['permissions']! as List<Object?>)
        permission! as String,
      for (final namespace in descriptors)
        for (final method
            in (namespace! as Map<Object?, Object?>)['methods']! as List<Object?>)
          (method! as Map<Object?, Object?>)['capability']! as String,
    };
    final catalog = CapabilityCatalog(
      capabilityNames.map(Capability.new),
    );
    final manifest = PluginManifestParser(
      capabilityCatalog: catalog,
      apiVersionPolicy: ExactApiVersionPolicy({manifestMap['apiVersion']! as String}),
    ).parseMap(manifestMap);
    final policy = _decodePolicy(initial['policy']! as Map<Object?, Object?>);
    final bindings = NativeLuaBindings.open(
      libraryPath: initial['libraryPath'] as String?,
    );
    final remote = _BlockingApiClient(bindings: bindings, hostPort: hostPort);
    final permissions = CapabilityManager(
      catalog: catalog,
      enabledCapabilities: capabilityNames.map(Capability.new),
    );
    final apiRegistry = PluginApiRegistry(
      capabilityManager: permissions,
      permissionChecker: (_, _) {},
    );
    for (final rawNamespace in descriptors) {
      final namespace = rawNamespace! as Map<Object?, Object?>;
      final name = namespace['name']! as String;
      final methods = <String, PluginApiMethod>{};
      for (final rawMethod in namespace['methods']! as List<Object?>) {
        final method = rawMethod! as Map<Object?, Object?>;
        final methodName = method['name']! as String;
        methods[methodName] = PluginApiMethod(
          capability: Capability(method['capability']! as String),
          handler: remote.invoke,
        );
      }
      apiRegistry.registerNamespace(
        PluginApiNamespace(name: name, methods: methods),
      );
    }
    runtime = await NativeLuaRuntimeFactory(
      resolver: DefaultNativeLuaLibraryResolver(
        libraryPath: initial['libraryPath'] as String?,
      ),
      sandboxPolicy: policy,
    ).create(
      manifest: manifest,
      pluginDirectory: initial['pluginDirectory']! as String,
      generation: initial['generation']! as String,
      apiRegistry: apiRegistry,
    );
    hostPort.send({'type': 'ready', 'port': commandPort.sendPort});
  } on Object catch (error, stackTrace) {
    hostPort.send({
      'type': 'startupError',
      'error': _encodeRemoteError(error, stackTrace),
    });
    commandPort.close();
    return;
  }

  await for (final raw in commandPort) {
    if (raw is! Map<Object?, Object?> || raw['type'] != 'command') continue;
    final id = raw['id'];
    if (id is! int) continue;
    final operation = raw['operation'];
    var shouldExit = false;
    try {
      Object? value;
      switch (operation) {
        case 'load':
          await runtime.loadEntrypoint();
        case 'has':
          value = await runtime.hasFunction(raw['name']! as String);
        case 'invoke':
          value = await runtime.invokeFunction(
            raw['name']! as String,
            arguments: (raw['arguments']! as List<Object?>).cast(),
          );
        case 'callback':
          value = await runtime.invokeCallback(
            PluginCallbackRef(
              pluginId: runtime.manifest.id,
              generation: runtime.generation,
              callbackId: raw['callbackId']! as int,
            ),
            arguments: (raw['arguments']! as List<Object?>).cast(),
          );
        case 'dispose':
          await runtime.dispose();
        default:
          throw StateError('Unknown isolate operation "$operation".');
      }
      shouldExit = operation == 'dispose';
      hostPort.send({'type': 'result', 'id': id, 'ok': true, 'value': value});
    } on Object catch (error, stackTrace) {
      hostPort.send({
        'type': 'result',
        'id': id,
        'ok': false,
        'error': _encodeRemoteError(error, stackTrace),
      });
    }
    if (shouldExit) {
      commandPort.close();
      return;
    }
  }
}

final class _BlockingApiClient {
  const _BlockingApiClient({required this.bindings, required this.hostPort});

  final NativeLuaBindings bindings;
  final SendPort hostPort;

  StructuredValue invoke(PluginApiCall call) {
    final rpc = bindings.rpcCreate();
    if (rpc == nullptr) {
      throw PluginApiException(
        'Could not allocate the plugin-isolate RPC rendezvous.',
        pluginId: call.pluginId,
      );
    }
    try {
      hostPort.send({
        'type': 'api',
        'handle': rpc.address,
        'pluginId': call.pluginId,
        'generation': call.generation,
        'namespace': call.namespace,
        'method': call.method,
        'arguments': [for (final argument in call.arguments) _encodeApiArgument(argument)],
      });
      bindings.rpcWait(rpc);
      return using((arena) {
        final length = arena<Uint64>();
        final pointer = bindings.rpcResponse(rpc, length);
        if (pointer == nullptr) {
          throw PluginApiException(
            'Plugin-isolate RPC completed without a response.',
            pluginId: call.pluginId,
          );
        }
        final decoded = jsonDecode(
          utf8.decode(pointer.asTypedList(length.value)),
        );
        if (decoded is! Map<String, Object?>) {
          throw PluginApiException(
            'Plugin-isolate RPC returned a malformed response.',
            pluginId: call.pluginId,
          );
        }
        if (decoded['ok'] != true) {
          throw PluginApiException(
            decoded['error']?.toString() ?? 'Host API call failed.',
            pluginId: call.pluginId,
          );
        }
        return decoded['value'];
      });
    } finally {
      bindings.rpcDestroy(rpc);
    }
  }
}

Map<String, Object?> _encodeApiArgument(PluginApiArgument argument) =>
    switch (argument) {
      PluginApiDataArgument() => {'kind': 'data', 'value': argument.value},
      PluginApiCallbackArgument() => {
          'kind': 'callback',
          'callbackId': argument.callback.callbackId,
        },
    };

PluginApiArgument _decodeApiArgument(
  Object? raw, {
  required String pluginId,
  required String generation,
}) {
  if (raw is! Map<Object?, Object?>) {
    throw PluginApiException('Malformed API argument.', pluginId: pluginId);
  }
  return switch (raw['kind']) {
    'data' => PluginApiDataArgument(raw['value']),
    'callback' when raw['callbackId'] is int => PluginApiCallbackArgument(
        PluginCallbackRef(
          pluginId: pluginId,
          generation: generation,
          callbackId: raw['callbackId']! as int,
        ),
      ),
    _ => throw PluginApiException('Malformed API argument.', pluginId: pluginId),
  };
}

Map<String, Object?> _encodePolicy(LuaSandboxPolicy value) => {
      'memoryLimitBytes': value.memoryLimitBytes,
      'instructionLimit': value.instructionLimit,
      'executionTimeoutMicros': value.executionTimeout.inMicroseconds,
      'maxCallbacks': value.maxCallbacks,
      'maxBridgeBytes': value.maxBridgeBytes,
      'maxValueDepth': value.maxValueDepth,
    };

LuaSandboxPolicy _decodePolicy(Map<Object?, Object?> value) => LuaSandboxPolicy(
      memoryLimitBytes: value['memoryLimitBytes']! as int,
      instructionLimit: value['instructionLimit']! as int,
      executionTimeout:
          Duration(microseconds: value['executionTimeoutMicros']! as int),
      maxCallbacks: value['maxCallbacks']! as int,
      maxBridgeBytes: value['maxBridgeBytes']! as int,
      maxValueDepth: value['maxValueDepth']! as int,
    );

Map<String, Object?> _encodeRemoteError(Object error, StackTrace stackTrace) {
  if (error is PluginException) {
    return {
      'kind': error.runtimeType.toString(),
      'message': error.message,
      'pluginId': error.pluginId,
      'phase': error.phase?.name,
      'filename': error.filename,
      'line': error.line,
      'stack': stackTrace.toString(),
      if (error is PluginLuaException) 'luaStack': error.luaStackTrace,
    };
  }
  return {
    'kind': 'PluginLoadException',
    'message': error.toString(),
    'stack': stackTrace.toString(),
  };
}

PluginException _decodeRemoteError(Object? raw) {
  if (raw is! Map<Object?, Object?>) {
    return const PluginLoadException(
      'Plugin isolate returned a malformed error.',
      pluginId: 'unknown',
    );
  }
  final message = raw['message']?.toString() ?? 'Plugin isolate failed.';
  final pluginId = raw['pluginId']?.toString() ?? 'unknown';
  final filename = raw['filename'] as String?;
  final line = raw['line'] as int?;
  final stack = raw['stack'] == null
      ? null
      : StackTrace.fromString(raw['stack']!.toString());
  final phaseName = raw['phase'] as String?;
  final phase = PluginLifecyclePhase.values
      .where((item) => item.name == phaseName)
      .firstOrNull;
  return switch (raw['kind']) {
    'PluginLuaException' => PluginLuaException(
        message,
        pluginId: pluginId,
        phase: phase ?? PluginLifecyclePhase.running,
        filename: filename,
        line: line,
        causeStackTrace: stack,
        luaStackTrace: raw['luaStack'] as String?,
      ),
    'PluginApiException' => PluginApiException(
        message,
        pluginId: pluginId,
        phase: phase ?? PluginLifecyclePhase.running,
        causeStackTrace: stack,
      ),
    'StalePluginCallbackException' =>
      StalePluginCallbackException(message, pluginId: pluginId),
    _ => PluginLoadException(
        message,
        pluginId: pluginId,
        phase: phase ?? PluginLifecyclePhase.loading,
        filename: filename,
        line: line,
        causeStackTrace: stack,
      ),
  };
}
