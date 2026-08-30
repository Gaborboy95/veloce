import '../errors/plugin_exception.dart';

/// A stable, versioned name for an operation exposed by the host.
final class Capability implements Comparable<Capability> {
  const Capability(this.name);

  final String name;

  @override
  int compareTo(Capability other) => name.compareTo(other.name);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Capability && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => name;
}

abstract final class BuiltInCapabilities {
  static const appInfo = Capability('app.info');
  static const logging = Capability('logging');
  static const events = Capability('events');
  static const vehicleRead = Capability('vehicle.read');
  static const vehicleWrite = Capability('vehicle.write');
  static const canRead = Capability('can.read');
  static const canWrite = Capability('can.write');
  static const uiTabs = Capability('ui.tabs');
  static const uiRender = Capability('ui.render');
  static const uiSettings = Capability('ui.settings');
  static const uiQuickControls = Capability('ui.quick_controls');
  static const uiStatus = Capability('ui.status');
  static const uiNotifications = Capability('ui.notifications');
  static const storage = Capability('storage');
  static const assetsRead = Capability('assets.read');
  static const timers = Capability('timer');

  static final Set<Capability> all = Set.unmodifiable({
    appInfo,
    logging,
    events,
    vehicleRead,
    vehicleWrite,
    canRead,
    canWrite,
    uiTabs,
    uiRender,
    uiSettings,
    uiQuickControls,
    uiStatus,
    uiNotifications,
    storage,
    assetsRead,
    timers,
  });

  /// Host capabilities enabled without additional configuration.
  ///
  /// CAN transmission is intentionally excluded. A host must explicitly opt in.
  static final Set<Capability> safeDefaults = Set.unmodifiable({
    appInfo,
    logging,
    events,
    vehicleRead,
    vehicleWrite,
    canRead,
    uiTabs,
    uiRender,
    uiSettings,
    uiQuickControls,
    uiStatus,
    uiNotifications,
    storage,
    assetsRead,
    timers,
  });
}

/// Resolves capability strings and rejects unknown permissions.
final class CapabilityCatalog {
  CapabilityCatalog(Iterable<Capability> capabilities)
    : _byName = Map.unmodifiable({
        for (final capability in capabilities) capability.name: capability,
      });

  factory CapabilityCatalog.builtIn() =>
      CapabilityCatalog(BuiltInCapabilities.all);

  final Map<String, Capability> _byName;

  Iterable<Capability> get capabilities => _byName.values;

  Capability? tryResolve(String name) => _byName[name];

  Capability resolve(String name, {String? pluginId}) {
    final capability = tryResolve(name);
    if (capability == null) {
      throw PluginManifestException(
        'Unknown permission "$name".',
        pluginId: pluginId,
      );
    }
    return capability;
  }
}
