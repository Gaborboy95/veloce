import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:ivi_lua_core/ivi_lua_core.dart';

import 'lua_bootstrap.dart';
import 'native_bindings.dart';

/// Resource limits applied independently to every Lua state and invocation.
final class LuaSandboxPolicy {
  const LuaSandboxPolicy({
    this.memoryLimitBytes = 16 * 1024 * 1024,
    this.instructionLimit = 500000,
    this.executionTimeout = const Duration(milliseconds: 50),
    this.maxCallbacks = 2048,
    this.maxBridgeBytes = 4 * 1024 * 1024,
    this.maxValueDepth = 32,
  });

  final int memoryLimitBytes;
  final int instructionLimit;
  final Duration executionTimeout;
  final int maxCallbacks;
  final int maxBridgeBytes;
  final int maxValueDepth;
}

/// Resolves the application-owned Lua shim without exposing it to plugins.
abstract interface class NativeLuaLibraryResolver {
  DynamicLibrary open();
}

final class DefaultNativeLuaLibraryResolver
    implements NativeLuaLibraryResolver {
  const DefaultNativeLuaLibraryResolver({this.libraryPath});

  final String? libraryPath;

  @override
  DynamicLibrary open() {
    if (libraryPath case final path?) return DynamicLibrary.open(path);
    if (Platform.isWindows) return DynamicLibrary.open('ivi_lua_native.dll');
    if (Platform.isLinux || Platform.isAndroid) {
      return DynamicLibrary.open('libivi_lua_native.so');
    }
    throw UnsupportedError(
      'ivi_lua_native currently supports Windows, Linux, and Android.',
    );
  }
}

/// Factory for independent, pointer-free Lua 5.4 runtime sessions.
final class NativeLuaRuntimeFactory implements PluginScriptRuntimeFactory {
  NativeLuaRuntimeFactory({
    NativeLuaLibraryResolver resolver = const DefaultNativeLuaLibraryResolver(),
    this.sandboxPolicy = const LuaSandboxPolicy(),
  }) : _bindings = NativeLuaBindings(resolver.open());

  final NativeLuaBindings _bindings;
  final LuaSandboxPolicy sandboxPolicy;

  String get luaVersion => _bindings.version().cast<Utf8>().toDartString();

  @override
  Future<PluginScriptRuntime> create({
    required PluginManifest manifest,
    required String pluginDirectory,
    required String generation,
    required PluginApiRegistry apiRegistry,
  }) async {
    late final NativeLuaRuntime runtime;
    final callable = NativeCallable<NativeHostCallback>.isolateLocal(
      (Pointer<Void> userData, IviLuaStatePointer state) =>
          runtime._dispatchHostCall(state),
      exceptionalReturn: 0,
    );
    runtime = NativeLuaRuntime._(
      bindings: _bindings,
      callable: callable,
      manifest: manifest,
      pluginDirectory: pluginDirectory,
      generation: generation,
      apiRegistry: apiRegistry,
      sandboxPolicy: sandboxPolicy,
    );
    try {
      await runtime._initialize();
      return runtime;
    } on Object {
      await runtime.dispose();
      rethrow;
    }
  }
}

final class NativeLuaRuntime implements PluginScriptRuntime {
  NativeLuaRuntime._({
    required NativeLuaBindings bindings,
    required NativeCallable<NativeHostCallback> callable,
    required this.manifest,
    required this.pluginDirectory,
    required this.generation,
    required PluginApiRegistry apiRegistry,
    required LuaSandboxPolicy sandboxPolicy,
  }) : _bindings = bindings,
       _callable = callable,
       _apiRegistry = apiRegistry,
       _policy = sandboxPolicy,
       _callbackRegistry = PluginCallbackRegistry(
         pluginId: manifest.id,
         generation: generation,
       );

  final NativeLuaBindings _bindings;
  final NativeCallable<NativeHostCallback> _callable;
  final PluginApiRegistry _apiRegistry;
  final LuaSandboxPolicy _policy;
  final PluginCallbackRegistry _callbackRegistry;

  @override
  final PluginManifest manifest;
  final String pluginDirectory;
  @override
  final String generation;

  late IviLuaStatePointer _state;
  Future<void> _operationTail = Future<void>.value();
  var _initialized = false;
  var _disposeRequested = false;
  var _disposed = false;
  var _nativeCallbackCount = 0;
  Future<void>? _disposeFuture;

  @override
  bool get isDisposed => _disposeRequested || _disposed;
  int get memoryUsedBytes => _disposed ? 0 : _bindings.memoryUsed(_state);

  Future<void> _initialize() async {
    _state = _bindings.create(
      _callable.nativeFunction,
      nullptr,
      _policy.memoryLimitBytes,
    );
    if (_state == nullptr) {
      throw PluginLoadException(
        'Could not allocate an independent Lua state.',
        pluginId: manifest.id,
      );
    }
    _initialized = true;
    _evaluate(
      luaApiBootstrap,
      '@ivi_api_v${manifest.apiVersion}.lua',
      PluginLifecyclePhase.loading,
    );
    const builtInNamespaces = {
      'app',
      'log',
      'events',
      'vehicle',
      'can',
      'ui',
      'storage',
      'timer',
    };
    for (final namespace in _apiRegistry.namespaces) {
      if (builtInNamespaces.contains(namespace.name)) continue;
      final methods = namespace.methods.keys.map(jsonEncode).join(',');
      _evaluate(
        '_ivi_register_namespace(${jsonEncode(namespace.name)}, {$methods})',
        '@ivi_namespace_${namespace.name}.lua',
        PluginLifecyclePhase.loading,
      );
    }
    _evaluate(
      '_ivi_register_namespace = nil',
      '@ivi_namespace_finalize.lua',
      PluginLifecyclePhase.loading,
    );
  }

  @override
  Future<void> loadEntrypoint() => _serialize(() async {
    final root = Directory(pluginDirectory);
    final entrypoint = File.fromUri(root.uri.resolve(manifest.entrypoint));
    await _verifyEntrypoint(root, entrypoint);
    late final String source;
    try {
      source = await entrypoint.readAsString();
    } on Object catch (error, stackTrace) {
      throw PluginLoadException(
        'Could not read Lua entrypoint.',
        pluginId: manifest.id,
        filename: entrypoint.path,
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
    _ensureActive();
    _evaluate(
      source,
      '@${entrypoint.absolute.path}',
      PluginLifecyclePhase.loading,
    );
  });

  @override
  Future<bool> hasFunction(String name) => _serialize(() {
    _ensureFunctionName(name);
    return using((arena) {
      final nativeName = name.toNativeUtf8(allocator: arena).cast<Char>();
      return _bindings.hasGlobalFunction(_state, nativeName) != 0;
    });
  });

  @override
  Future<StructuredValue> invokeFunction(
    String name, {
    List<StructuredValue> arguments = const [],
  }) => _serialize(() {
    _ensureFunctionName(name);
    return _invokePrepared(
      prepare: (arena) {
        final nativeName = name.toNativeUtf8(allocator: arena).cast<Char>();
        return _bindings.prepareGlobal(_state, nativeName) != 0;
      },
      missingMessage: 'Lua function "$name" is not defined.',
      arguments: arguments,
      phase: _phaseForFunction(name),
    );
  });

  @override
  Future<StructuredValue> invokeCallback(
    PluginScriptCallback callback, {
    List<StructuredValue> arguments = const [],
  }) => _serialize(
    () => _callbackRegistry.invoke(
      PluginCallbackRef(
        pluginId: callback.pluginId,
        generation: callback.generation,
        callbackId: callback.callbackId,
      ),
      arguments: arguments,
    ),
  );

  @override
  Future<void> dispose() {
    if (_disposeFuture case final pending?) return pending;
    if (_disposed) return Future<void>.value();
    _disposeRequested = true;
    final completer = Completer<void>();
    _disposeFuture = completer.future;
    _operationTail = _operationTail.then((_) async {
      if (_disposed) {
        completer.complete();
        return;
      }
      try {
        await _callbackRegistry.dispose();
        if (_initialized && _state != nullptr) {
          _bindings.destroy(_state);
        }
        _disposed = true;
        completer.complete();
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        _callable.close();
      }
    });
    return _disposeFuture!;
  }

  Future<T> _serialize<T>(FutureOr<T> Function() operation) {
    if (_disposeRequested) {
      return Future<T>.error(
        StalePluginCallbackException(
          'Lua runtime generation $generation is disposed.',
          pluginId: manifest.id,
        ),
      );
    }
    final completer = Completer<T>();
    _operationTail = _operationTail
        .then((_) async {
          if (_disposeRequested) {
            throw StalePluginCallbackException(
              'Lua runtime generation $generation is disposed.',
              pluginId: manifest.id,
            );
          }
          return operation();
        })
        .then(completer.complete, onError: completer.completeError);
    return completer.future;
  }

  void _evaluate(String source, String chunkName, PluginLifecyclePhase phase) {
    _ensureActive();
    final base = _bindings.getTop(_state);
    try {
      using((arena) {
        final code = source.toNativeUtf8(allocator: arena).cast<Char>();
        final name = chunkName.toNativeUtf8(allocator: arena).cast<Char>();
        final status = _bindings.eval(
          _state,
          code,
          name,
          _policy.instructionLimit,
          _policy.executionTimeout.inMilliseconds,
        );
        if (status != 0) throw _luaError(phase, fallbackFilename: chunkName);
      });
    } finally {
      _bindings.setTop(_state, base);
    }
  }

  StructuredValue _invokePrepared({
    required bool Function(Allocator allocator) prepare,
    required String missingMessage,
    required List<StructuredValue> arguments,
    required PluginLifecyclePhase phase,
  }) {
    _ensureActive();
    _checkBridgeBudget(arguments);
    final base = _bindings.getTop(_state);
    try {
      final found = using<bool>(prepare);
      if (!found) {
        throw PluginLuaException(
          missingMessage,
          pluginId: manifest.id,
          phase: phase,
        );
      }
      for (final argument in arguments) {
        _pushData(argument);
      }
      final status = _bindings.pcall(
        _state,
        arguments.length,
        1,
        _policy.instructionLimit,
        _policy.executionTimeout.inMilliseconds,
      );
      if (status != 0) throw _luaError(phase);
      final result = _readData(-1, depth: 0);
      _checkBridgeBudget(result);
      return result;
    } finally {
      _bindings.setTop(_state, base);
    }
  }

  Future<StructuredValue> _invokeNativeReference(
    int reference,
    List<StructuredValue> arguments,
  ) async => _invokePrepared(
    prepare: (_) => _bindings.prepareRef(_state, reference) != 0,
    missingMessage: 'Lua callback reference is no longer valid.',
    arguments: arguments,
    phase: PluginLifecyclePhase.callback,
  );

  int _dispatchHostCall(IviLuaStatePointer state) {
    if (_disposed || !_initialized || state != _state) return 0;
    final originalTop = _bindings.getTop(state);
    try {
      if (originalTop < 2 ||
          _bindings.typeAt(state, 1) != 4 ||
          _bindings.typeAt(state, 2) != 4) {
        throw PluginApiException(
          'Host calls require a namespace and method string.',
          pluginId: manifest.id,
        );
      }
      final namespace = _readString(1);
      final method = _readString(2);
      final arguments = <PluginApiArgument>[
        for (var index = 3; index <= originalTop; index++)
          _readApiArgument(index),
      ];
      final result = _apiRegistry.invoke(
        PluginApiCall(
          pluginId: manifest.id,
          generation: generation,
          namespace: namespace,
          method: method,
          arguments: arguments,
        ),
      );
      _checkBridgeBudget(result);
      _bindings.pushBoolean(state, 1);
      if (result == null) return 1;
      _pushData(result);
      return 2;
    } on Object catch (error) {
      _bindings.setTop(state, originalTop);
      _bindings.pushBoolean(state, 0);
      _pushString(error.toString());
      return 2;
    }
  }

  PluginApiArgument _readApiArgument(int index) {
    if (_bindings.typeAt(_state, index) == 6) {
      if (_nativeCallbackCount >= _policy.maxCallbacks) {
        throw PluginApiException(
          'Plugin exceeds ${_policy.maxCallbacks} retained callbacks.',
          pluginId: manifest.id,
        );
      }
      final nativeReference = _bindings.refAt(_state, index);
      if (nativeReference < 0) {
        throw PluginApiException(
          'Could not retain Lua callback.',
          pluginId: manifest.id,
        );
      }
      _nativeCallbackCount++;
      final reference = _callbackRegistry.register(
        (arguments) => _invokeNativeReference(nativeReference, arguments),
      );
      return PluginApiCallbackArgument(reference);
    }
    return PluginApiDataArgument(_readData(index, depth: 0));
  }

  StructuredValue _readData(int index, {required int depth}) {
    if (depth > _policy.maxValueDepth) {
      throw PluginApiException(
        'Lua value exceeds bridge depth ${_policy.maxValueDepth}.',
        pluginId: manifest.id,
      );
    }
    switch (_bindings.typeAt(_state, index)) {
      case 0:
        return null;
      case 1:
        return _bindings.toBoolean(_state, index) != 0;
      case 3:
        return using((arena) {
          final success = arena<Int32>();
          if (_bindings.isInteger(_state, index) != 0) {
            final value = _bindings.toInteger(_state, index, success);
            if (success.value == 0) throw _unsupportedValue(index);
            return value;
          }
          final value = _bindings.toNumber(_state, index, success);
          if (success.value == 0 || !value.isFinite) {
            throw _unsupportedValue(index);
          }
          return value;
        });
      case 4:
        return _readString(index);
      case 5:
        return _readTable(index, depth: depth + 1);
      case 6:
        throw PluginApiException(
          'Lua functions are only allowed as direct callback arguments.',
          pluginId: manifest.id,
        );
      default:
        throw _unsupportedValue(index);
    }
  }

  StructuredValue _readTable(int index, {required int depth}) {
    if (_bindings.checkStack(_state, 4) == 0) {
      throw PluginApiException(
        'Lua stack budget is exhausted while decoding a table.',
        pluginId: manifest.id,
      );
    }
    final absoluteIndex = index > 0
        ? index
        : _bindings.getTop(_state) + index + 1;
    final stringEntries = <String, Object?>{};
    final integerEntries = <int, Object?>{};
    _bindings.pushNil(_state);
    while (_bindings.next(_state, absoluteIndex) != 0) {
      final keyType = _bindings.typeAt(_state, -2);
      final value = _readData(-1, depth: depth);
      if (keyType == 4) {
        stringEntries[_readString(-2)] = value;
      } else if (keyType == 3 && _bindings.isInteger(_state, -2) != 0) {
        final key = using((arena) {
          final success = arena<Int32>();
          final result = _bindings.toInteger(_state, -2, success);
          if (success.value == 0) throw _unsupportedValue(-2);
          return result;
        });
        integerEntries[key] = value;
      } else {
        throw PluginApiException(
          'Lua table keys must be strings or contiguous array indexes.',
          pluginId: manifest.id,
        );
      }
      _bindings.setTop(_state, _bindings.getTop(_state) - 1);
    }

    if (stringEntries.isNotEmpty && integerEntries.isNotEmpty) {
      throw PluginApiException(
        'Mixed map/array Lua tables cannot cross the host boundary.',
        pluginId: manifest.id,
      );
    }
    if (integerEntries.isNotEmpty) {
      final length = integerEntries.length;
      if (integerEntries.keys.any((key) => key < 1 || key > length)) {
        throw PluginApiException(
          'Lua arrays must use contiguous indexes starting at 1.',
          pluginId: manifest.id,
        );
      }
      return List<Object?>.unmodifiable([
        for (var index = 1; index <= length; index++) integerEntries[index],
      ]);
    }
    return Map<String, Object?>.unmodifiable(stringEntries);
  }

  String _readString(int index) => using((arena) {
    final length = arena<Uint64>();
    final pointer = _bindings.toStringValue(_state, index, length);
    if (pointer == nullptr) throw _unsupportedValue(index);
    return pointer.cast<Utf8>().toDartString(length: length.value);
  });

  void _pushData(StructuredValue value) {
    if (_bindings.checkStack(_state, 4) == 0) {
      throw PluginApiException(
        'Lua stack budget is exhausted while encoding a value.',
        pluginId: manifest.id,
      );
    }
    switch (value) {
      case null:
        _bindings.pushNil(_state);
      case bool():
        _bindings.pushBoolean(_state, value ? 1 : 0);
      case int():
        _bindings.pushInteger(_state, value);
      case double():
        if (!value.isFinite) throw _unsupportedDartValue(value);
        _bindings.pushNumber(_state, value);
      case String():
        _pushString(value);
      case List<Object?>():
        _bindings.createTable(_state, value.length, 0);
        final table = _bindings.getTop(_state);
        for (var index = 0; index < value.length; index++) {
          _pushData(value[index]);
          _bindings.rawSetIndex(_state, table, index + 1);
        }
      case Map<Object?, Object?>():
        if (value.keys.any((key) => key is! String)) {
          throw _unsupportedDartValue(value);
        }
        _bindings.createTable(_state, 0, value.length);
        final table = _bindings.getTop(_state);
        for (final entry in value.entries) {
          _pushData(entry.value);
          using((arena) {
            final key = (entry.key! as String)
                .toNativeUtf8(allocator: arena)
                .cast<Char>();
            _bindings.setField(_state, table, key);
          });
        }
      default:
        throw _unsupportedDartValue(value);
    }
  }

  void _pushString(String value) => using((arena) {
    final encoded = value.toNativeUtf8(allocator: arena);
    _bindings.pushString(_state, encoded.cast<Char>(), encoded.length);
  });

  void _checkBridgeBudget(Object? value) {
    var bytes = 0;
    var items = 0;
    void visit(Object? current, int depth) {
      if (depth > _policy.maxValueDepth) {
        throw PluginApiException(
          'Value exceeds bridge depth ${_policy.maxValueDepth}.',
          pluginId: manifest.id,
        );
      }
      items++;
      bytes += switch (current) {
        null => 1,
        bool() => 1,
        int() || double() => 8,
        String() => current.length * 3,
        List<Object?>() => 16,
        Map<Object?, Object?>() => 32,
        _ => _policy.maxBridgeBytes + 1,
      };
      if (bytes > _policy.maxBridgeBytes || items > 10000) {
        throw PluginApiException(
          'Value exceeds the bounded Dart/Lua bridge budget.',
          pluginId: manifest.id,
        );
      }
      if (current is List<Object?>) {
        for (final item in current) {
          visit(item, depth + 1);
        }
      } else if (current is Map<Object?, Object?>) {
        for (final entry in current.entries) {
          if (entry.key is! String) {
            throw _unsupportedDartValue(current);
          }
          bytes += (entry.key! as String).length * 3;
          visit(entry.value, depth + 1);
        }
      }
    }

    visit(value, 0);
  }

  PluginLuaException _luaError(
    PluginLifecyclePhase phase, {
    String? fallbackFilename,
  }) {
    final pointer = _bindings.lastError(_state);
    final trace = pointer == nullptr
        ? 'Unknown Lua error.'
        : pointer.cast<Utf8>().toDartString();
    final location = RegExp(r'([^\r\n]+?):(\d+):').firstMatch(trace);
    var filename = location?.group(1) ?? fallbackFilename;
    if (filename?.startsWith('@') ?? false) filename = filename!.substring(1);
    final line = int.tryParse(location?.group(2) ?? '');
    return PluginLuaException(
      trace.split(RegExp(r'[\r\n]')).first,
      pluginId: manifest.id,
      phase: phase,
      filename: filename,
      line: line,
      luaStackTrace: trace,
    );
  }

  PluginApiException _unsupportedValue(int index) => PluginApiException(
    'Unsupported Lua value type ${_bindings.typeAt(_state, index)}.',
    pluginId: manifest.id,
  );

  PluginApiException _unsupportedDartValue(Object? value) => PluginApiException(
    'Unsupported Dart bridge value ${value.runtimeType}.',
    pluginId: manifest.id,
  );

  void _ensureActive() {
    if (!_initialized || _disposeRequested || _disposed) {
      throw StalePluginCallbackException(
        'Lua runtime generation $generation is no longer active.',
        pluginId: manifest.id,
      );
    }
  }

  static void _ensureFunctionName(String name) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
      throw ArgumentError.value(
        name,
        'name',
        'Invalid Lua global function name',
      );
    }
  }

  static PluginLifecyclePhase _phaseForFunction(String name) => switch (name) {
    'on_load' => PluginLifecyclePhase.initialization,
    'on_unload' => PluginLifecyclePhase.unloading,
    'on_save_state' => PluginLifecyclePhase.stateSaving,
    'on_suspend' || 'on_resume' => PluginLifecyclePhase.running,
    _ => PluginLifecyclePhase.running,
  };

  Future<void> _verifyEntrypoint(Directory root, File entrypoint) async {
    try {
      final rootPath = await root.resolveSymbolicLinks();
      final targetPath = await entrypoint.resolveSymbolicLinks();
      final prefix = rootPath.endsWith(Platform.pathSeparator)
          ? rootPath
          : '$rootPath${Platform.pathSeparator}';
      final normalizedPrefix = Platform.isWindows
          ? prefix.toLowerCase()
          : prefix;
      final normalizedTarget = Platform.isWindows
          ? targetPath.toLowerCase()
          : targetPath;
      if (!normalizedTarget.startsWith(normalizedPrefix)) {
        throw PluginLoadException(
          'Lua entrypoint resolves outside the plugin directory.',
          pluginId: manifest.id,
          filename: entrypoint.path,
        );
      }
    } on PluginException {
      rethrow;
    } on Object catch (error, stackTrace) {
      throw PluginLoadException(
        'Could not validate Lua entrypoint.',
        pluginId: manifest.id,
        filename: entrypoint.path,
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }
}
