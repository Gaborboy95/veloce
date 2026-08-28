import '../errors/plugin_exception.dart';
import '../manifest/plugin_manifest.dart';
import 'capability.dart';

typedef PluginCapabilityAuthorizer = bool Function(
  String pluginId,
  Capability capability,
);

/// Enforces requested and host-granted permissions at every Dart API boundary.
final class CapabilityManager {
  CapabilityManager({
    CapabilityCatalog? catalog,
    Iterable<Capability>? enabledCapabilities,
    PluginCapabilityAuthorizer? authorizer,
  })  : catalog = catalog ?? CapabilityCatalog.builtIn(),
        _enabled = Set.of(
          enabledCapabilities ?? BuiltInCapabilities.safeDefaults,
        ),
        _authorizer = authorizer ?? _allow;

  final CapabilityCatalog catalog;
  final Set<Capability> _enabled;
  final PluginCapabilityAuthorizer _authorizer;
  final Map<String, Set<Capability>> _requested = {};

  static bool _allow(String _, Capability __) => true;

  Set<Capability> get enabledCapabilities => Set.unmodifiable(_enabled);

  void setHostCapabilityEnabled(Capability capability,
      {required bool enabled}) {
    if (catalog.tryResolve(capability.name) == null) {
      throw ArgumentError.value(capability, 'capability', 'Unknown capability');
    }
    enabled ? _enabled.add(capability) : _enabled.remove(capability);
  }

  void registerPlugin(PluginManifest manifest, {bool replace = false}) {
    if (_requested.containsKey(manifest.id) && !replace) {
      throw PluginApiException(
        'Capabilities are already registered for this plugin.',
        pluginId: manifest.id,
      );
    }
    for (final capability in manifest.permissions) {
      catalog.resolve(capability.name, pluginId: manifest.id);
    }
    _requested[manifest.id] = Set.unmodifiable(manifest.permissions);
  }

  void unregisterPlugin(String pluginId) => _requested.remove(pluginId);

  bool isRequested(String pluginId, Capability capability) =>
      _requested[pluginId]?.contains(capability) ?? false;

  bool isGranted(String pluginId, Capability capability) =>
      isRequested(pluginId, capability) &&
      _enabled.contains(capability) &&
      _authorizer(pluginId, capability);

  bool isGrantedFor(
    String pluginId,
    Iterable<Capability> requestedCapabilities,
    Capability capability,
  ) =>
      requestedCapabilities.contains(capability) &&
      _enabled.contains(capability) &&
      _authorizer(pluginId, capability);

  Set<Capability> requestedFor(String pluginId) =>
      Set.unmodifiable(_requested[pluginId] ?? const <Capability>{});

  Set<Capability> grantedFor(String pluginId) => Set.unmodifiable(
        requestedFor(pluginId).where(
          (capability) => isGranted(pluginId, capability),
        ),
      );

  void require(String pluginId, Capability capability) {
    if (!isRequested(pluginId, capability)) {
      throw PluginPermissionException(
        'Plugin did not request capability "${capability.name}".',
        pluginId: pluginId,
        capability: capability.name,
      );
    }
    if (!_enabled.contains(capability)) {
      throw PluginPermissionException(
        'Capability "${capability.name}" is disabled by the host.',
        pluginId: pluginId,
        capability: capability.name,
      );
    }
    if (!_authorizer(pluginId, capability)) {
      throw PluginPermissionException(
        'Capability "${capability.name}" was denied by host policy.',
        pluginId: pluginId,
        capability: capability.name,
      );
    }
  }

  /// Checks an immutable candidate manifest without mutating active grants.
  /// This is used while a transactional replacement is being initialized.
  void requireFor(
    String pluginId,
    Iterable<Capability> requestedCapabilities,
    Capability capability,
  ) {
    if (!requestedCapabilities.contains(capability)) {
      throw PluginPermissionException(
        'Plugin did not request capability "${capability.name}".',
        pluginId: pluginId,
        capability: capability.name,
      );
    }
    if (!_enabled.contains(capability)) {
      throw PluginPermissionException(
        'Capability "${capability.name}" is disabled by the host.',
        pluginId: pluginId,
        capability: capability.name,
      );
    }
    if (!_authorizer(pluginId, capability)) {
      throw PluginPermissionException(
        'Capability "${capability.name}" was denied by host policy.',
        pluginId: pluginId,
        capability: capability.name,
      );
    }
  }
}
