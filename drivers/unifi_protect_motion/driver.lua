--[[
================================================================================
 UniFi Protect SuperLink Motion / Glass Break Sensor - child driver
================================================================================
 USL-Motion, USL-GlassBreak and UP-Sense (All-In-One).
   * "Motion" and "Glass Break" CONTACT_SENSOR outputs for stock contact
     drivers (Motion Sensor / Glass Break Detector).
   * Built-in light automation: lights on with motion, off after it clears.
   * Events: Motion Detected, Motion Cleared, Glass Break Detected, Tamper,
     Battery Low, Online/Offline. UP-Sense readings are exposed as variables.

 Open Source - MIT License. Not affiliated with Ubiquiti Inc. or Snap One LLC.
================================================================================
]]

local U = require("up_common")
local Child = U.Child
local Base = U.SensorBase
U.label = "UniFi Motion Sensor"

local MOTION = 100
local GLASS = 101
local TAMPER = 102

Motion = Motion or {}
Motion.active = nil
Motion.lights = U.LightLink.new()

local function activeClosed()
  return U.prop("Contact Closes On Detection", "Yes") == "Yes"
end

local function setMotion(on, when)
  if on == nil then return end
  if on then
    -- Failsafe in case the "cleared" update is lost.
    U.after("motion_failsafe", 10 * 60000, function() setMotion(false) end)
  else
    U.stop("motion_failsafe")
  end
  if Motion.active == on then
    if on then Motion.lights:trigger() end
    return
  end
  local first = Motion.active == nil
  Motion.active = on
  U.setVar("MOTION", on)
  U.setProp("State", on and "Motion" or "Clear")
  U.contact(MOTION, (on and activeClosed()) or ((not on) and not activeClosed()))
  if on then
    U.setVar("LAST_MOTION", U.fmtTime(when or U.nowMs()))
    U.setProp("Last Motion", U.fmtTime(when or U.nowMs()))
  end
  if first then return end
  if on then
    U.fire("Motion Detected")
    Motion.lights:trigger()
  else
    U.fire("Motion Cleared")
    Motion.lights:release()
  end
end

local function glassBreak(when)
  U.setVar("LAST_GLASS_BREAK", U.fmtTime(when or U.nowMs()))
  U.setProp("Last Glass Break", U.fmtTime(when or U.nowMs()))
  U.fire("Glass Break Detected")
  U.contact(GLASS, activeClosed())
  U.after("glass_pulse", (tonumber(U.prop("Glass Break Hold (seconds)", "10")) or 10) * 1000, function()
    U.contact(GLASS, not activeClosed())
  end)
end

local function updateReadings(dev)
  local t = U.get(dev, "stats", "temperature", "value")
  local h = U.get(dev, "stats", "humidity", "value")
  local l = U.get(dev, "stats", "light", "value")
  if t then
    U.setVar("TEMPERATURE_C", tostring(U.round(t, 1)))
    U.setVar("TEMPERATURE_F", tostring(U.round(U.cToF(t), 1)))
  end
  if h then U.setVar("HUMIDITY", tostring(U.round(h, 0))) end
  if l then U.setVar("LIGHT_LUX", tostring(U.round(l, 0))) end
end

local function onState(dev, partial)
  Base.update(dev)
  updateReadings(dev)
  local m = dev.isMotionDetected
  if m ~= nil and m ~= U.NULL then setMotion(m and true or false, U.v(dev.motionDetectedAt)) end
end

local function onEvent(ev, action)
  Base.onEvent(ev, action)
  local t = U.v(ev.type)
  if action == "add" then
    if t == "sensorMotion" then
      setMotion(true, U.v(ev.start))
    elseif t == "sensorAlarm" then
      local alarmType = U.get(ev, "metadata", "alarmType", "text") or U.get(ev, "metadata", "alarmType")
      if alarmType == "glassBreak" then glassBreak(U.v(ev.start)) else U.fire("Alarm Triggered") end
    end
  end
end

local function onSelected()
  Motion.active = nil
  Base.reset()
end

local COMMANDS = {
  ["Enable Light Automation"] = function() Motion.lights:setEnabled(true) U.setVar("LIGHT_AUTOMATION", true) end,
  ["Disable Light Automation"] = function() Motion.lights:setEnabled(false) U.setVar("LIGHT_AUTOMATION", false) end,
  Reconnect = function() Child.connect() end,
  TestLights = function() Motion.lights:trigger() Motion.lights:release() end,
}

function ExecuteCommand(strCommand, tParams)
  local cmd, params = U.normalizeCommand(strCommand, tParams)
  if Child.handleCommand(cmd, params) then return end
  local f = COMMANDS[cmd]
  if f then f(params) end
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  Child.handleCommand(strCommand, tParams or {})
end

function OnPropertyChanged(strProperty)
  if Child.onPropertyChanged(strProperty) then return end
  if strProperty == "Debug Logging" then U.debugEnabled = Properties[strProperty] == "On" end
end

function OnBindingChanged(idBinding, strClass, bIsBound)
  if Child.onBindingChanged(idBinding, strClass, bIsBound) then return end
  if bIsBound and (idBinding == MOTION or idBinding == GLASS or idBinding == TAMPER) then
    U.after("contact_refresh_" .. idBinding, 500, function() U.contactRefresh(idBinding) end)
  end
end

function OnDriverInit()
  U.debugEnabled = U.prop("Debug Logging", "Off") == "On"
  Base.init(TAMPER)
  U.addVar("MOTION", "0", "BOOL")
  U.addVar("LAST_MOTION", "", "STRING")
  U.addVar("LAST_GLASS_BREAK", "", "STRING")
  U.addVar("TEMPERATURE_C", "", "STRING")
  U.addVar("TEMPERATURE_F", "", "STRING")
  U.addVar("HUMIDITY", "", "STRING")
  U.addVar("LIGHT_LUX", "", "STRING")
  U.addVar("LIGHT_AUTOMATION", U.persistGet("lights_enabled", true) ~= false and "1" or "0", "BOOL")
end

function OnDriverLateInit()
  U.setProp("Driver Version", U.VERSION)
  U.contact(GLASS, not activeClosed(), true)
  Child.init({
    kind = "sensor",
    filter = function(dev)
      local f = U.v(dev.featureFlags)
      if type(f) == "table" and U.v(f.motion) ~= nil then return true end
      local t = tostring(U.v(dev.type) or ""):lower()
      return t:find("motion", 1, true) or t:find("glass", 1, true) or t:find("sense", 1, true)
    end,
    onState = onState,
    onEvent = onEvent,
    onSelected = onSelected,
  })
end
