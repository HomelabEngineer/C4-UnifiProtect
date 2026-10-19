--[[
================================================================================
 UniFi Protect SuperLink Environmental Sensor - child driver
================================================================================
 USL-Environmental (also UP-Sense temperature/humidity/light).
   * thermostatV2 proxy in sensor-only mode: temperature + humidity tile in
     Navigator Comfort, readings listed on the Extras tab.
   * "Temperature" (TEMPERATURE_VALUE) and "Humidity" (HUMIDITY_VALUE) output
     connections - bind to a thermostat remote sensor input or anything that
     accepts a value connection.
   * "Water Leak" CONTACT_SENSOR output (internal pads + external probe).
   * Events: leak, temperature/humidity high/low (Protect thresholds),
     reading changes, battery, tamper, online/offline.

 Open Source - MIT License. Not affiliated with Ubiquiti Inc. or Snap One LLC.
================================================================================
]]

local U = require("up_common")
local Child = U.Child
local Base = U.SensorBase
U.label = "UniFi Environmental"

local PROXY = 5001
local TEMPERATURE_OUT = 5010
local HUMIDITY_OUT = 5012
local LEAK = 100
local TAMPER = 101

Env = Env or {}
Env.tempC = nil
Env.hum = nil
Env.lux = nil
Env.leak = nil
Env.extLeak = nil
Env.tempStatus = nil
Env.humStatus = nil
Env.lastExtrasXml = nil

local function leakClosed(wet)
  if U.prop("Leak Contact Closes When Wet", "Yes") == "Yes" then return wet end
  return not wet
end

local function extrasItem(id, label, text)
  text = text or "--"
  return '<object type="list" id="' .. id .. '" label="' .. U.xmlEscape(label) .. '" command="EXTRAS_NOOP" value="'
    .. U.xmlEscape(text) .. '"><list maxselections="1" minselections="1"><item text="' .. U.xmlEscape(text)
    .. '" value="' .. U.xmlEscape(text) .. '"/></list></object>'
end

local function pushExtras()
  local useF = U.prop("Extras Temperature Unit", "Fahrenheit") == "Fahrenheit"
  local temp = "--"
  if Env.tempC then
    temp = useF and (tostring(U.round(U.cToF(Env.tempC), 1)) .. " F") or (tostring(U.round(Env.tempC, 1)) .. " C")
  end
  local parts = {
    extrasItem("temp", "Temperature", temp),
    extrasItem("hum", "Humidity", Env.hum and (tostring(U.round(Env.hum, 0)) .. " %") or "--"),
    extrasItem("lux", "Light", Env.lux and (tostring(U.round(Env.lux, 0)) .. " lux") or "--"),
    extrasItem("leak", "Water Leak", (Env.leak or Env.extLeak) and "LEAK DETECTED" or "Dry"),
    extrasItem("bat", "Battery", U.prop("Battery", "--")),
  }
  local xml = '<extras_setup><extra><section label="Environment">' .. table.concat(parts) .. "</section></extra></extras_setup>"
  if xml ~= Env.lastExtrasXml then
    Env.lastExtrasXml = xml
    pcall(C4.SendToProxy, C4, PROXY, "EXTRAS_SETUP_CHANGED", { XML = xml }, "NOTIFY")
  end
end

local function statusEvents(kind, newStatus, oldStatus)
  if newStatus == oldStatus or oldStatus == nil then return end
  if newStatus == "high" then U.fire(kind .. " High")
  elseif newStatus == "low" then U.fire(kind .. " Low")
  elseif oldStatus == "high" or oldStatus == "low" then U.fire(kind .. " Normal") end
end

local function setTemperature(c, status)
  if c then
    c = tonumber(c)
    local changed = Env.tempC == nil or math.abs(c - Env.tempC) >= 0.05
    Env.tempC = c
    if changed then
      local f = U.cToF(c)
      U.setVar("TEMPERATURE_C", tostring(U.round(c, 1)))
      U.setVar("TEMPERATURE_F", tostring(U.round(f, 1)))
      U.setProp("Temperature", tostring(U.round(f, 1)) .. " F / " .. tostring(U.round(c, 1)) .. " C")
      pcall(C4.SendToProxy, C4, PROXY, "TEMPERATURE_CHANGED", { TEMPERATURE = tostring(U.round(c, 1)), SCALE = "C" }, "NOTIFY")
      pcall(C4.SendToProxy, C4, TEMPERATURE_OUT, "VALUE_CHANGED", {
        CELSIUS = tostring(U.round(c, 1)),
        FAHRENHEIT = tostring(U.round(f, 1)),
      })
      U.fire("Temperature Changed")
    end
  end
  if status then
    local old = Env.tempStatus
    Env.tempStatus = status
    U.setVar("TEMPERATURE_STATUS", status)
    statusEvents("Temperature", status, old)
  end
end

local function setHumidity(h, status)
  if h then
    h = tonumber(h)
    local rounded = math.floor(h + 0.5)
    local changed = Env.hum == nil or math.floor(Env.hum + 0.5) ~= rounded
    Env.hum = h
    if changed then
      U.setVar("HUMIDITY", tostring(rounded))
      U.setProp("Humidity", tostring(rounded) .. " %")
      pcall(C4.SendToProxy, C4, PROXY, "HUMIDITY_CHANGED", { HUMIDITY = tostring(rounded) }, "NOTIFY")
      pcall(C4.SendToProxy, C4, HUMIDITY_OUT, "VALUE_CHANGED", { VALUE = tostring(rounded) })
      U.fire("Humidity Changed")
    end
  end
  if status then
    local old = Env.humStatus
    Env.humStatus = status
    U.setVar("HUMIDITY_STATUS", status)
    statusEvents("Humidity", status, old)
  end
end

local function setLight(l)
  if not l then return end
  Env.lux = tonumber(l)
  U.setVar("LIGHT_LUX", tostring(U.round(Env.lux, 0)))
  U.setProp("Light", tostring(U.round(Env.lux, 0)) .. " lux")
end

local function setLeak(internal, external)
  local before = (Env.leak or Env.extLeak) and true or false
  local first = Env.leak == nil and Env.extLeak == nil
  if internal ~= nil then Env.leak = internal end
  if external ~= nil then Env.extLeak = external end
  local now = (Env.leak or Env.extLeak) and true or false
  U.setVar("LEAK_DETECTED", now)
  U.setVar("EXTERNAL_LEAK_DETECTED", Env.extLeak and true or false)
  U.setProp("Water Leak", now and ("LEAK DETECTED" .. (Env.extLeak and " (external probe)" or "")) or "Dry")
  U.contact(LEAK, leakClosed(now))
  if now ~= before or (first and now) then
    U.fire(now and "Leak Detected" or "Leak Cleared")
  end
end

local function onState(dev, partial)
  Base.update(dev)
  local stats = U.v(dev.stats)
  if type(stats) == "table" then
    local t, h, l = U.v(stats.temperature), U.v(stats.humidity), U.v(stats.light)
    if type(t) == "table" then setTemperature(U.v(t.value), U.v(t.status)) end
    if type(h) == "table" then setHumidity(U.v(h.value), U.v(h.status)) end
    if type(l) == "table" then setLight(U.v(l.value)) end
  end
  local internal, external = nil, nil
  if dev.leakDetectedAt ~= nil then internal = U.v(dev.leakDetectedAt) ~= nil end
  if dev.externalLeakDetectedAt ~= nil then external = U.v(dev.externalLeakDetectedAt) ~= nil end
  if internal ~= nil or external ~= nil then setLeak(internal, external) end
  pushExtras()
end

local function onEvent(ev, action)
  Base.onEvent(ev, action)
  local t = U.v(ev.type)
  if t == "sensorWaterLeak" then
    if action == "add" then setLeak(true, nil) end
  elseif t == "sensorExtremeValues" and action == "add" then
    local metric = U.get(ev, "metadata", "sensorType", "text") or U.get(ev, "metadata", "sensorType")
    local status = U.get(ev, "metadata", "status", "text") or U.get(ev, "metadata", "status")
    local value = U.get(ev, "metadata", "sensorValue", "text") or U.get(ev, "metadata", "sensorValue")
    if metric == "temperature" then setTemperature(tonumber(value), status)
    elseif metric == "humidity" then setHumidity(tonumber(value), status) end
  end
  pushExtras()
end

local function onSelected()
  Env.tempC, Env.hum, Env.lux, Env.leak, Env.extLeak, Env.tempStatus, Env.humStatus = nil, nil, nil, nil, nil, nil, nil
  Base.reset()
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  U.dbg("RFP " .. tostring(idBinding) .. " " .. tostring(strCommand))
  -- Master messages addressed to the proxy id are forwarded here.
  if Child.handleCommand(strCommand, tParams or {}) then return end
  -- Sensor only: no HVAC equipment to control.
end

function UIRequest(strCommand, tParams)
  if strCommand == "GET_EXTRAS_SETUP" then return Env.lastExtrasXml or "" end
  return ""
end

local COMMANDS = {
  Reconnect = function() Child.connect() end,
  ResendValues = function()
    local c, h = Env.tempC, Env.hum
    Env.tempC, Env.hum = nil, nil
    setTemperature(c)
    setHumidity(h)
  end,
}

function ExecuteCommand(strCommand, tParams)
  local cmd, params = U.normalizeCommand(strCommand, tParams)
  if Child.handleCommand(cmd, params) then return end
  local f = COMMANDS[cmd]
  if f then f(params) end
end

function OnPropertyChanged(strProperty)
  if Child.onPropertyChanged(strProperty) then return end
  local v = Properties[strProperty]
  if strProperty == "Debug Logging" then U.debugEnabled = v == "On"
  elseif strProperty == "Extras Temperature Unit" then pushExtras()
  elseif strProperty == "Leak Contact Closes When Wet" then
    U.contact(LEAK, leakClosed((Env.leak or Env.extLeak) and true or false), true)
  end
end

function OnBindingChanged(idBinding, strClass, bIsBound)
  if Child.onBindingChanged(idBinding, strClass, bIsBound) then return end
  if bIsBound then
    U.after("rebind_" .. idBinding, 500, function()
      if idBinding == TEMPERATURE_OUT or idBinding == HUMIDITY_OUT then COMMANDS.ResendValues()
      elseif idBinding == LEAK or idBinding == TAMPER then U.contactRefresh(idBinding) end
    end)
  end
end

function OnDriverInit()
  U.debugEnabled = U.prop("Debug Logging", "Off") == "On"
  Base.init(TAMPER)
  U.addVar("TEMPERATURE_C", "", "STRING")
  U.addVar("TEMPERATURE_F", "", "STRING")
  U.addVar("TEMPERATURE_STATUS", "", "STRING")
  U.addVar("HUMIDITY", "", "STRING")
  U.addVar("HUMIDITY_STATUS", "", "STRING")
  U.addVar("LIGHT_LUX", "", "STRING")
  U.addVar("LEAK_DETECTED", "0", "BOOL")
  U.addVar("EXTERNAL_LEAK_DETECTED", "0", "BOOL")
end

function OnDriverLateInit()
  U.setProp("Driver Version", U.VERSION)
  pcall(function()
    C4:SendToProxy(PROXY, "ALLOWED_HVAC_MODES_CHANGED", { MODES = "Off" }, "NOTIFY")
    C4:SendToProxy(PROXY, "DYNAMIC_CAPABILITIES_CHANGED", { HAS_HUMIDITY = true, HAS_EXTRAS = true }, "NOTIFY")
    C4:SendToProxy(PROXY, "HVAC_MODE_CHANGED", { MODE = "Off" }, "NOTIFY")
  end)
  pushExtras()
  Child.init({
    kind = "sensor",
    filter = function(dev)
      local f = U.v(dev.featureFlags)
      if type(f) == "table" and (U.v(f.temperature) ~= nil or U.v(f.humidity) ~= nil or U.v(f.waterLeak) ~= nil) then
        return true
      end
      local t = tostring(U.v(dev.type) or ""):lower()
      return t:find("environ", 1, true) or t:find("sense", 1, true) or U.v(dev.mountType) == "leak"
    end,
    onState = onState,
    onEvent = onEvent,
    onSelected = onSelected,
  })
end
