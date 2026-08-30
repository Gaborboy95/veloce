const luaApiBootstrap = r'''
local raw_host_call = _veloce_host_call
_veloce_host_call = nil

local function host_call(namespace, method, ...)
  local result = table.pack(raw_host_call(namespace, method, ...))
  if result[1] ~= true then
    error(tostring(result[2] or "host API call failed"), 2)
  end
  return table.unpack(result, 2, result.n)
end

app = {
  info = function() return host_call("app", "info") end,
}

local function log_values(level, ...)
  local values = table.pack(...)
  local parts = {}
  for index = 1, values.n do
    parts[index] = tostring(values[index])
  end
  return host_call("log", level, table.concat(parts, "\t"))
end

log = {
  debug = function(...) return log_values("debug", ...) end,
  info = function(...) return log_values("info", ...) end,
  warn = function(...) return log_values("warn", ...) end,
  error = function(...) return log_values("error", ...) end,
}

events = {
  subscribe = function(topic, callback)
    return host_call("events", "subscribe", topic, callback)
  end,
  publish = function(topic, value)
    return host_call("events", "publish", topic, value)
  end,
}

vehicle = {
  subscribe = function(path, callback)
    return host_call("vehicle", "subscribe", path, callback)
  end,
  publish = function(path, value)
    return host_call("vehicle", "publish", path, value)
  end,
}

can = {
  subscribe = function(filter, callback)
    return host_call("can", "subscribe", filter, callback)
  end,
  send = function(frame)
    return host_call("can", "send", frame)
  end,
}

storage = {
  get = function(key) return host_call("storage", "get", key) end,
  set = function(key, value) return host_call("storage", "set", key, value) end,
  remove = function(key) return host_call("storage", "remove", key) end,
  contains = function(key) return host_call("storage", "contains", key) end,
}

assets = {
  exists = function(path) return host_call("assets", "exists", path) end,
  list = function(prefix)
    if prefix == nil then return host_call("assets", "list") end
    return host_call("assets", "list", prefix)
  end,
  read_text = function(path) return host_call("assets", "read_text", path) end,
  read_bytes = function(path) return host_call("assets", "read_bytes", path) end,
}

timer = {
  set_timeout = function(milliseconds, callback)
    return host_call("timer", "set_timeout", milliseconds, callback)
  end,
  set_interval = function(milliseconds, callback)
    return host_call("timer", "set_interval", milliseconds, callback)
  end,
  clear = function(handle) return host_call("timer", "clear", handle) end,
}

local function copy_options(node_type, options)
  local node = options or {}
  node.type = node_type
  return node
end

ui = {}
local retained_ui_callbacks = setmetatable({}, {__mode = "k"})
local function retain_ui_callback(callback)
  local retained = retained_ui_callbacks[callback]
  if retained == nil then
    retained = host_call("ui", "retain_callback", callback)
    retained_ui_callbacks[callback] = retained
  end
  return retained
end
ui.text = function(value, options)
  local node = copy_options("text", options)
  node.text = tostring(value)
  return node
end
ui.icon = function(name, options)
  local node = copy_options("icon", options)
  node.name = name
  return node
end
ui.row = function(children, options)
  local node = copy_options("row", options)
  node.children = children or {}
  return node
end
ui.column = function(children, options)
  local node = copy_options("column", options)
  node.children = children or {}
  return node
end
ui.container = function(options)
  return copy_options("container", options)
end
ui.card = function(options)
  return copy_options("card", options)
end
ui.button = function(options)
  local node = copy_options("button", options)
  if type(node.on_click) ~= "function" then
    error("ui.button requires on_click", 2)
  end
  node.callback = retain_ui_callback(node.on_click)
  node.on_click = nil
  return node
end
ui.switch = function(options)
  local node = copy_options("switch", options)
  if type(node.on_changed) ~= "function" then
    error("ui.switch requires on_changed", 2)
  end
  node.callback = retain_ui_callback(node.on_changed)
  node.on_changed = nil
  return node
end
ui.slider = function(options)
  local node = copy_options("slider", options)
  if type(node.on_changed) ~= "function" then
    error("ui.slider requires on_changed", 2)
  end
  node.callback = retain_ui_callback(node.on_changed)
  node.on_changed = nil
  return node
end
ui.spacer = function(options)
  return copy_options("spacer", options)
end
ui.list = function(children, options)
  local node = copy_options("list", options)
  node.children = children or {}
  return node
end

local renderers = {}

local function render_tab(id)
  local renderer = renderers[id]
  if renderer == nil then
    error("unknown UI tab: " .. tostring(id), 2)
  end
  return renderer()
end

ui.register_tab = function(definition)
  if type(definition) ~= "table" or type(definition.id) ~= "string" or
      type(definition.title) ~= "string" or type(definition.render) ~= "function" then
    error("ui.register_tab requires id, title, and render", 2)
  end
  renderers[definition.id] = definition.render
  return host_call("ui", "register_tab", {
    id = definition.id,
    title = definition.title,
    content = render_tab(definition.id),
  })
end

ui.refresh_tab = function(id)
  return host_call("ui", "update_tab", {
    id = id,
    content = render_tab(id),
  })
end

ui.unregister_tab = function(id)
  renderers[id] = nil
  return host_call("ui", "unregister_tab", id)
end

local extension_renderers = {}

ui.register_extension = function(definition)
  if type(definition) ~= "table" or type(definition.point) ~= "string" or
      type(definition.id) ~= "string" or type(definition.render) ~= "function" then
    error("ui.register_extension requires point, id, and render", 2)
  end
  local key = definition.point .. "\0" .. definition.id
  extension_renderers[key] = definition.render
  return host_call("ui", "register_extension", {
    point = definition.point,
    id = definition.id,
    title = definition.title,
    icon_name = definition.icon_name,
    content = extension_renderers[key](),
  })
end

ui.unregister_extension = function(point, id)
  extension_renderers[point .. "\0" .. id] = nil
  return host_call("ui", "unregister_extension", point, id)
end

local veloce_module = {
  app = app,
  log = log,
  events = events,
  vehicle = vehicle,
  can = can,
  ui = ui,
  storage = storage,
  assets = assets,
  timer = timer,
}

function _veloce_register_namespace(name, methods)
  local namespace = {}
  for _, method in ipairs(methods) do
    namespace[method] = function(...)
      return host_call(name, method, ...)
    end
  end
  _G[name] = namespace
end

function require(name)
  if name == "veloce" then
    return veloce_module
  end
  error("module '" .. tostring(name) .. "' is not available in the sandbox", 2)
end
''';
