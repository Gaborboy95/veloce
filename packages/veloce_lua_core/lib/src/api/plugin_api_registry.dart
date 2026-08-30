import '../callbacks/plugin_callback_registry.dart';
import '../errors/plugin_exception.dart';
import '../permissions/capability.dart';
import '../permissions/capability_manager.dart';
import '../values/structured_value.dart';

/// One argument supplied by a script to a synchronous host API operation.
sealed class PluginApiArgument {
  const PluginApiArgument();
}

final class PluginApiDataArgument extends PluginApiArgument {
  const PluginApiDataArgument(this.value);

  final StructuredValue value;
}

final class PluginApiCallbackArgument extends PluginApiArgument {
  const PluginApiCallbackArgument(this.callback);

  final PluginScriptCallback callback;
}

/// Context for a call from one script runtime generation into Dart.
final class PluginApiCall {
  PluginApiCall({
    required this.pluginId,
    required this.generation,
    required this.namespace,
    required this.method,
    required Iterable<PluginApiArgument> arguments,
  }) : arguments = List.unmodifiable(arguments);

  final String pluginId;
  final String generation;
  final String namespace;
  final String method;
  final List<PluginApiArgument> arguments;

  void requireArgumentCount(int count) {
    if (arguments.length != count) {
      throw PluginApiException(
        '$namespace.$method expects $count arguments; got ${arguments.length}.',
        pluginId: pluginId,
      );
    }
  }

  StructuredValue data(int index) {
    final argument = _argument(index);
    if (argument is! PluginApiDataArgument) {
      throw PluginApiException(
        '$namespace.$method argument ${index + 1} must be data.',
        pluginId: pluginId,
      );
    }
    return argument.value;
  }

  T dataAs<T>(int index) {
    final value = data(index);
    if (value is! T) {
      throw PluginApiException(
        '$namespace.$method argument ${index + 1} must be $T.',
        pluginId: pluginId,
      );
    }
    return value;
  }

  PluginScriptCallback callback(int index) {
    final argument = _argument(index);
    if (argument is! PluginApiCallbackArgument) {
      throw PluginApiException(
        '$namespace.$method argument ${index + 1} must be a callback.',
        pluginId: pluginId,
      );
    }
    if (argument.callback.pluginId != pluginId ||
        argument.callback.generation != generation) {
      throw StalePluginCallbackException(
        'API callback argument belongs to another runtime generation.',
        pluginId: pluginId,
      );
    }
    return argument.callback;
  }

  PluginApiArgument _argument(int index) {
    if (index < 0 || index >= arguments.length) {
      throw PluginApiException(
        '$namespace.$method is missing argument ${index + 1}.',
        pluginId: pluginId,
      );
    }
    return arguments[index];
  }
}

/// Host handlers are synchronous because Lua C functions must return before
/// control leaves the native call. Asynchronous work must return an ID and
/// deliver completion through a callback/event.
typedef PluginApiHandler = StructuredValue Function(PluginApiCall call);

typedef PluginApiPermissionChecker =
    void Function(PluginApiCall call, Capability capability);

final class PluginApiMethod {
  const PluginApiMethod({required this.capability, required this.handler});

  final Capability capability;
  final PluginApiHandler handler;
}

final class PluginApiNamespace {
  PluginApiNamespace({
    required this.name,
    required Map<String, PluginApiMethod> methods,
  }) : methods = Map.unmodifiable(methods) {
    _validateName(name, 'namespace');
    if (this.methods.isEmpty) {
      throw ArgumentError.value(methods, 'methods', 'Must not be empty');
    }
    for (final method in this.methods.keys) {
      _validateName(method, 'method');
    }
  }

  final String name;
  final Map<String, PluginApiMethod> methods;
}

/// Extensible, permission-checked dispatcher for namespaced Lua host APIs.
final class PluginApiRegistry {
  PluginApiRegistry({
    required this.capabilityManager,
    PluginApiPermissionChecker? permissionChecker,
    StructuredValueCodec codec = const StructuredValueCodec(),
  }) : _permissionChecker = permissionChecker,
       _codec = codec;

  final CapabilityManager capabilityManager;
  final PluginApiPermissionChecker? _permissionChecker;
  final StructuredValueCodec _codec;
  final Map<String, PluginApiNamespace> _namespaces = {};

  Iterable<String> get namespaceNames => _namespaces.keys;
  Iterable<PluginApiNamespace> get namespaces =>
      List<PluginApiNamespace>.unmodifiable(_namespaces.values);

  void registerNamespace(PluginApiNamespace namespace, {bool replace = false}) {
    if (_namespaces.containsKey(namespace.name) && !replace) {
      throw StateError('API namespace "${namespace.name}" is registered.');
    }
    for (final method in namespace.methods.values) {
      if (capabilityManager.catalog.tryResolve(method.capability.name) ==
          null) {
        throw ArgumentError.value(
          method.capability,
          'namespace',
          'API method uses an unknown capability',
        );
      }
    }
    _namespaces[namespace.name] = namespace;
  }

  bool unregisterNamespace(String name) => _namespaces.remove(name) != null;

  StructuredValue invoke(PluginApiCall call) {
    final namespace = _namespaces[call.namespace];
    final method = namespace?.methods[call.method];
    if (method == null) {
      throw PluginApiException(
        'Unknown host API operation ${call.namespace}.${call.method}.',
        pluginId: call.pluginId,
      );
    }
    final checker = _permissionChecker;
    if (checker == null) {
      capabilityManager.require(call.pluginId, method.capability);
    } else {
      checker(call, method.capability);
    }

    final normalizedArguments = <PluginApiArgument>[];
    for (final argument in call.arguments) {
      switch (argument) {
        case PluginApiDataArgument():
          normalizedArguments.add(
            PluginApiDataArgument(
              _codec.normalize(argument.value, pluginId: call.pluginId),
            ),
          );
        case PluginApiCallbackArgument():
          if (argument.callback.pluginId != call.pluginId ||
              argument.callback.generation != call.generation) {
            throw StalePluginCallbackException(
              'API callback argument belongs to another runtime generation.',
              pluginId: call.pluginId,
            );
          }
          normalizedArguments.add(argument);
      }
    }

    final normalizedCall = PluginApiCall(
      pluginId: call.pluginId,
      generation: call.generation,
      namespace: call.namespace,
      method: call.method,
      arguments: normalizedArguments,
    );
    try {
      return _codec.normalize(
        method.handler(normalizedCall),
        pluginId: call.pluginId,
      );
    } catch (error, stackTrace) {
      if (error is PluginException) rethrow;
      throw PluginApiException(
        'Host API operation ${call.namespace}.${call.method} failed.',
        pluginId: call.pluginId,
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }
}

void _validateName(String value, String field) {
  if (value.isEmpty ||
      value.length > 64 ||
      !RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(value)) {
    throw ArgumentError.value(value, field, 'Invalid API name');
  }
}
