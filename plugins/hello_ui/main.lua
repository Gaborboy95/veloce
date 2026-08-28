local ivi = require("ivi")
local log = ivi.log
local timer = ivi.timer
local ui = ivi.ui

local tab_id = "hello"
local counter = 0
local elapsed_seconds = 0

local function increment()
  counter = counter + 1
  ui.refresh_tab(tab_id)
end

local function render()
  return ui.column({
    ui.text("Hello from Lua"),
    ui.text("Counter: " .. tostring(counter)),
    ui.button({
      text = "Increment",
      on_click = increment,
    }),
    ui.text("Running for " .. tostring(elapsed_seconds) .. " seconds"),
  })
end

function on_load(state)
  if type(state) == "table" then
    if type(state.counter) == "number" then
      counter = math.tointeger(state.counter) or counter
    end
    if type(state.elapsed_seconds) == "number" then
      elapsed_seconds = math.tointeger(state.elapsed_seconds) or elapsed_seconds
    end
  end

  ui.register_tab({
    id = tab_id,
    title = "Hello Lua",
    render = render,
  })

  timer.set_interval(1000, function()
    elapsed_seconds = elapsed_seconds + 1
    ui.refresh_tab(tab_id)
  end)

  log.info("Hello UI plugin loaded")
end

function on_save_state()
  return {
    counter = counter,
    elapsed_seconds = elapsed_seconds,
  }
end

function on_unload()
  -- Tabs, callbacks, and timers are plugin-owned and cleaned up by the host.
  log.info("Hello UI plugin unloaded")
end
