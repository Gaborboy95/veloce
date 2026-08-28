local veloce = require("veloce")
local ui = veloce.ui
local vehicle = veloce.vehicle

local tab_id = "engine_dashboard"
local engine_rpm = 0

local function render()
  return ui.column({
    ui.text("Engine speed"),
    ui.text(tostring(engine_rpm) .. " RPM"),
    ui.text("Data source: VehicleDataBus"),
  })
end

function on_load()
  ui.register_tab({
    id = tab_id,
    title = "Engine",
    render = render,
  })

  vehicle.subscribe("engine.rpm", function(value)
    if type(value) == "number" then
      engine_rpm = math.max(0, math.floor(value))
      ui.refresh_tab(tab_id)
    end
  end)
end

function on_unload()
  -- The vehicle subscription and tab are both removed by ownership cleanup.
end
