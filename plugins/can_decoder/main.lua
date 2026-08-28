local ivi = require("ivi")
local can = ivi.can
local log = ivi.log
local vehicle = ivi.vehicle

local function decode_engine_rpm(frame)
  local data = frame.data
  if type(data) ~= "table" or type(data[1]) ~= "number" or
      type(data[2]) ~= "number" then
    log.warn("Ignoring malformed 0x280 frame: expected at least two data bytes")
    return
  end

  -- The demo protocol encodes RPM as an unsigned, big-endian 16-bit value.
  local rpm = data[1] * 256 + data[2]
  vehicle.publish("engine.rpm", rpm)
end

function on_load()
  can.subscribe({
    bus = "comfort",
    ids = { 0x280 },
    mask = 0x7FF,
  }, decode_engine_rpm)

  log.info("CAN decoder listening on comfort/0x280")
end

function on_unload()
  -- The CAN subscription is owned by this plugin and removed by the host.
  log.info("CAN decoder plugin unloaded")
end
