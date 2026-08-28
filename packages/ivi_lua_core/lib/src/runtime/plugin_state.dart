/// The externally visible lifecycle state of a plugin.
enum PluginState {
  discovered,
  loading,
  running,
  reloading,
  failed,
  disabled,
  unloading,
}

/// Identifies where an error happened without coupling errors to a Lua runtime.
enum PluginLifecyclePhase {
  discovery,
  manifestValidation,
  loading,
  initialization,
  running,
  stateSaving,
  reloading,
  unloading,
  callback,
  eventDelivery,
  timer,
  storage,
}
