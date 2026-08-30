import '../can/can_models.dart';
import '../errors/plugin_exception.dart';
import '../manager/plugin_generation_scope.dart';
import '../permissions/capability.dart';
import '../ui/plugin_ui_codec.dart';
import '../ui/plugin_ui_registry.dart';
import 'plugin_api_registry.dart';

typedef PluginGenerationScopeResolver =
    PluginGenerationScope Function(PluginApiCall call);

/// Registers API v1's namespaced, capability-bound host operations.
///
/// This controller is internal to [PluginManager] and deliberately contains no
/// Lua or FFI types.
final class BuiltInPluginApis {
  BuiltInPluginApis({
    required this.registry,
    required PluginGenerationScopeResolver resolveScope,
    PluginUiNodeCodec uiCodec = const PluginUiNodeCodec(),
  }) : _resolveScope = resolveScope,
       _uiCodec = uiCodec;

  final PluginApiRegistry registry;
  final PluginGenerationScopeResolver _resolveScope;
  final PluginUiNodeCodec _uiCodec;

  void register() {
    registry
      ..registerNamespace(_app())
      ..registerNamespace(_log())
      ..registerNamespace(_events())
      ..registerNamespace(_vehicle())
      ..registerNamespace(_can())
      ..registerNamespace(_ui())
      ..registerNamespace(_storage())
      ..registerNamespace(_assets())
      ..registerNamespace(_timer());
  }

  PluginApiNamespace _app() => PluginApiNamespace(
    name: 'app',
    methods: {
      'info': PluginApiMethod(
        capability: BuiltInCapabilities.appInfo,
        handler: (call) {
          call.requireArgumentCount(0);
          final scope = _resolveScope(call);
          return {
            'plugin_id': scope.pluginId,
            'plugin_version': scope.manifest.version.toString(),
            'api_version': scope.manifest.apiVersion,
            'generation': scope.generation,
          };
        },
      ),
    },
  );

  PluginApiNamespace _log() => PluginApiNamespace(
    name: 'log',
    methods: {
      for (final level in const ['debug', 'info', 'warn', 'error'])
        level: PluginApiMethod(
          capability: BuiltInCapabilities.logging,
          handler: (call) {
            call.requireArgumentCount(1);
            final message = call.dataAs<String>(0);
            final logger = _resolveScope(call).logger;
            switch (level) {
              case 'debug':
                logger.debug(message);
              case 'info':
                logger.info(message);
              case 'warn':
                logger.warning(message);
              case 'error':
                logger.error(message);
            }
            return null;
          },
        ),
    },
  );

  PluginApiNamespace _events() => PluginApiNamespace(
    name: 'events',
    methods: {
      'subscribe': PluginApiMethod(
        capability: BuiltInCapabilities.events,
        handler: (call) {
          call.requireArgumentCount(2);
          return _resolveScope(
            call,
          ).subscribeEvent(call.dataAs<String>(0), call.callback(1));
        },
      ),
      'publish': PluginApiMethod(
        capability: BuiltInCapabilities.events,
        handler: (call) {
          call.requireArgumentCount(2);
          return _resolveScope(
            call,
          ).publishEvent(call.dataAs<String>(0), call.data(1));
        },
      ),
    },
  );

  PluginApiNamespace _vehicle() => PluginApiNamespace(
    name: 'vehicle',
    methods: {
      'subscribe': PluginApiMethod(
        capability: BuiltInCapabilities.vehicleRead,
        handler: (call) {
          call.requireArgumentCount(2);
          return _resolveScope(
            call,
          ).subscribeVehicle(call.dataAs<String>(0), call.callback(1));
        },
      ),
      'publish': PluginApiMethod(
        capability: BuiltInCapabilities.vehicleWrite,
        handler: (call) {
          call.requireArgumentCount(2);
          return _resolveScope(
            call,
          ).publishVehicle(call.dataAs<String>(0), call.data(1));
        },
      ),
    },
  );

  PluginApiNamespace _can() => PluginApiNamespace(
    name: 'can',
    methods: {
      'subscribe': PluginApiMethod(
        capability: BuiltInCapabilities.canRead,
        handler: (call) {
          call.requireArgumentCount(2);
          final value = _stringMap(call.data(0), call);
          final filter = _canFilter(value, call);
          return _resolveScope(call).subscribeCan(filter, call.callback(1));
        },
      ),
      'send': PluginApiMethod(
        capability: BuiltInCapabilities.canWrite,
        handler: (call) {
          call.requireArgumentCount(1);
          final value = _stringMap(call.data(0), call);
          final type = _optionalField<String>(value, 'type', call) ?? 'data';
          if (type != 'data' && type != 'remote') {
            throw PluginApiException(
              'can.send type must be "data" or "remote".',
              pluginId: call.pluginId,
            );
          }
          final rawData = type == 'data'
              ? _field<List<Object?>>(value, 'data', call)
              : const <Object?>[];
          final data = <int>[
            for (final byte in rawData)
              if (byte is int)
                byte
              else
                throw PluginApiException(
                  'can.send data must contain integers.',
                  pluginId: call.pluginId,
                ),
          ];
          final frame = type == 'remote'
              ? CanFrame.remote(
                  bus: _field<String>(value, 'bus', call),
                  id: _field<int>(value, 'id', call),
                  remoteLength: _optionalField<int>(value, 'length', call) ?? 0,
                  extended:
                      _optionalField<bool>(value, 'extended', call) ?? false,
                )
              : CanFrame(
                  bus: _field<String>(value, 'bus', call),
                  id: _field<int>(value, 'id', call),
                  data: data,
                  extended:
                      _optionalField<bool>(value, 'extended', call) ?? false,
                );
          return _resolveScope(call).sendCan(frame);
        },
      ),
    },
  );

  PluginApiNamespace _ui() => PluginApiNamespace(
    name: 'ui',
    methods: {
      'retain_callback': PluginApiMethod(
        capability: BuiltInCapabilities.uiRender,
        handler: (call) {
          call.requireArgumentCount(1);
          return _resolveScope(call).retainCallback(call.callback(0));
        },
      ),
      'register_tab': PluginApiMethod(
        capability: BuiltInCapabilities.uiTabs,
        handler: (call) {
          call.requireArgumentCount(1);
          final scope = _resolveScope(call);
          final value = _stringMap(call.data(0), call);
          final id = _field<String>(value, 'id', call);
          final title = _field<String>(value, 'title', call);
          final tab = PluginTab(
            pluginId: call.pluginId,
            id: id,
            title: title,
            iconName: _optionalField<String>(value, 'icon_name', call),
            content: _uiCodec.decode(
              value['content'],
              pluginId: call.pluginId,
              resolveCallback: scope.resolveCallback,
            ),
          );
          scope.registerTab(tab);
          return true;
        },
      ),
      'update_tab': PluginApiMethod(
        capability: BuiltInCapabilities.uiTabs,
        handler: (call) {
          call.requireArgumentCount(1);
          final scope = _resolveScope(call);
          final value = _stringMap(call.data(0), call);
          final id = _field<String>(value, 'id', call);
          final current = scope.tab(id);
          if (current == null) {
            throw PluginApiException(
              'Cannot update unknown tab "$id".',
              pluginId: call.pluginId,
            );
          }
          scope.registerTab(
            PluginTab(
              pluginId: call.pluginId,
              id: id,
              title: current.title,
              iconName: current.iconName,
              content: _uiCodec.decode(
                value['content'],
                pluginId: call.pluginId,
                resolveCallback: scope.resolveCallback,
              ),
            ),
          );
          return true;
        },
      ),
      'unregister_tab': PluginApiMethod(
        capability: BuiltInCapabilities.uiTabs,
        handler: (call) {
          call.requireArgumentCount(1);
          _resolveScope(call).unregisterTab(call.dataAs<String>(0));
          return true;
        },
      ),
      'register_extension': PluginApiMethod(
        capability: BuiltInCapabilities.uiRender,
        handler: (call) {
          call.requireArgumentCount(1);
          final scope = _resolveScope(call);
          final value = _stringMap(call.data(0), call);
          final point = _field<String>(value, 'point', call);
          _requireUiExtensionCapability(call, scope, point);
          scope.registerUiContribution(
            PluginUiContribution(
              extensionPoint: point,
              pluginId: call.pluginId,
              id: _field<String>(value, 'id', call),
              title: _optionalField<String>(value, 'title', call),
              iconName: _optionalField<String>(value, 'icon_name', call),
              content: _uiCodec.decode(
                value['content'],
                pluginId: call.pluginId,
                resolveCallback: scope.resolveCallback,
              ),
            ),
          );
          return true;
        },
      ),
      'unregister_extension': PluginApiMethod(
        capability: BuiltInCapabilities.uiRender,
        handler: (call) {
          call.requireArgumentCount(2);
          final scope = _resolveScope(call);
          final point = call.dataAs<String>(0);
          _requireUiExtensionCapability(call, scope, point);
          scope.unregisterUiContribution(point, call.dataAs<String>(1));
          return true;
        },
      ),
    },
  );

  void _requireUiExtensionCapability(
    PluginApiCall call,
    PluginGenerationScope scope,
    String point,
  ) {
    final capability = switch (point) {
      PluginUiExtensionPoints.settingsPages => BuiltInCapabilities.uiSettings,
      PluginUiExtensionPoints.quickControls =>
        BuiltInCapabilities.uiQuickControls,
      PluginUiExtensionPoints.statusWidgets => BuiltInCapabilities.uiStatus,
      PluginUiExtensionPoints.notifications =>
        BuiltInCapabilities.uiNotifications,
      _ => throw PluginApiException(
        'Unknown UI extension point "$point".',
        pluginId: call.pluginId,
      ),
    };
    registry.capabilityManager.requireFor(
      call.pluginId,
      scope.manifest.permissions,
      capability,
    );
  }

  PluginApiNamespace _storage() => PluginApiNamespace(
    name: 'storage',
    methods: {
      'get': PluginApiMethod(
        capability: BuiltInCapabilities.storage,
        handler: (call) {
          call.requireArgumentCount(1);
          final key = _storageKey(call.dataAs<String>(0), call);
          return _resolveScope(call).storageGet(key);
        },
      ),
      'contains': PluginApiMethod(
        capability: BuiltInCapabilities.storage,
        handler: (call) {
          call.requireArgumentCount(1);
          final key = _storageKey(call.dataAs<String>(0), call);
          return _resolveScope(call).storageContains(key);
        },
      ),
      'set': PluginApiMethod(
        capability: BuiltInCapabilities.storage,
        handler: (call) {
          call.requireArgumentCount(2);
          final key = _storageKey(call.dataAs<String>(0), call);
          return _resolveScope(call).storageSet(key, call.data(1));
        },
      ),
      'remove': PluginApiMethod(
        capability: BuiltInCapabilities.storage,
        handler: (call) {
          call.requireArgumentCount(1);
          final key = _storageKey(call.dataAs<String>(0), call);
          return _resolveScope(call).storageRemove(key);
        },
      ),
    },
  );

  PluginApiNamespace _assets() => PluginApiNamespace(
    name: 'assets',
    methods: {
      'exists': PluginApiMethod(
        capability: BuiltInCapabilities.assetsRead,
        handler: (call) {
          call.requireArgumentCount(1);
          return _resolveScope(call).assets.contains(call.dataAs<String>(0));
        },
      ),
      'list': PluginApiMethod(
        capability: BuiltInCapabilities.assetsRead,
        handler: (call) {
          if (call.arguments.length > 1) {
            throw PluginApiException(
              'assets.list expects zero or one argument.',
              pluginId: call.pluginId,
            );
          }
          return _resolveScope(
            call,
          ).assets.list(call.arguments.isEmpty ? '' : call.dataAs<String>(0));
        },
      ),
      'read_text': PluginApiMethod(
        capability: BuiltInCapabilities.assetsRead,
        handler: (call) {
          call.requireArgumentCount(1);
          return _resolveScope(call).assets.readText(call.dataAs<String>(0));
        },
      ),
      'read_bytes': PluginApiMethod(
        capability: BuiltInCapabilities.assetsRead,
        handler: (call) {
          call.requireArgumentCount(1);
          return _resolveScope(
            call,
          ).assets.readBytes(call.dataAs<String>(0)).toList(growable: false);
        },
      ),
    },
  );

  PluginApiNamespace _timer() => PluginApiNamespace(
    name: 'timer',
    methods: {
      'set_timeout': PluginApiMethod(
        capability: BuiltInCapabilities.timers,
        handler: (call) => _setTimer(call, repeating: false),
      ),
      'set_interval': PluginApiMethod(
        capability: BuiltInCapabilities.timers,
        handler: (call) => _setTimer(call, repeating: true),
      ),
      'clear': PluginApiMethod(
        capability: BuiltInCapabilities.timers,
        handler: (call) {
          call.requireArgumentCount(1);
          return _resolveScope(call).clearTimer(call.dataAs<int>(0));
        },
      ),
    },
  );

  int _setTimer(PluginApiCall call, {required bool repeating}) {
    call.requireArgumentCount(2);
    final milliseconds = call.dataAs<int>(0);
    return _resolveScope(call).setTimer(
      duration: Duration(milliseconds: milliseconds),
      repeating: repeating,
      callback: call.callback(1),
    );
  }

  static Map<String, Object?> _stringMap(Object? value, PluginApiCall call) {
    if (value is! Map<Object?, Object?> ||
        value.keys.any((key) => key is! String)) {
      throw PluginApiException(
        '${call.namespace}.${call.method} expects a string-keyed table.',
        pluginId: call.pluginId,
      );
    }
    return {
      for (final entry in value.entries) entry.key! as String: entry.value,
    };
  }

  static T _field<T>(
    Map<String, Object?> value,
    String name,
    PluginApiCall call,
  ) {
    final field = value[name];
    if (field is! T) {
      throw PluginApiException(
        '${call.namespace}.${call.method} field "$name" must be $T.',
        pluginId: call.pluginId,
      );
    }
    return field;
  }

  static T? _optionalField<T>(
    Map<String, Object?> value,
    String name,
    PluginApiCall call,
  ) {
    if (!value.containsKey(name)) return null;
    return _field<T>(value, name, call);
  }

  static CanFilter _canFilter(Map<String, Object?> value, PluginApiCall call) {
    final rawIds = value['ids'];
    List<int>? ids;
    if (value.containsKey('ids')) {
      if (rawIds is! List<Object?> || rawIds.any((id) => id is! int)) {
        throw PluginApiException(
          '${call.namespace}.${call.method} field "ids" must be an array of integers.',
          pluginId: call.pluginId,
        );
      }
      ids = [for (final id in rawIds) id! as int];
    }

    try {
      return CanFilter(
        bus: _field<String>(value, 'bus', call),
        id: _optionalField<int>(value, 'id', call),
        ids: ids,
        mask: _optionalField<int>(value, 'mask', call),
        extended: _optionalField<bool>(value, 'extended', call),
        includeRemote:
            _optionalField<bool>(value, 'include_remote', call) ?? false,
        includeErrors:
            _optionalField<bool>(value, 'include_errors', call) ?? false,
      );
    } on ArgumentError catch (error) {
      throw PluginApiException(
        'Invalid CAN filter: ${error.message}',
        pluginId: call.pluginId,
      );
    }
  }

  static String _storageKey(String value, PluginApiCall call) {
    if (value.isEmpty ||
        value.length > 256 ||
        value.contains(RegExp(r'[\x00-\x1f]'))) {
      throw PluginApiException(
        'Invalid plugin storage key.',
        pluginId: call.pluginId,
      );
    }
    return value;
  }
}
