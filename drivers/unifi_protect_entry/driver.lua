--[[
================================================================================
 UniFi Protect SuperLink Entry Sensor - child driver
================================================================================
 USL-Entry / USL-Entry-R (and any Protect sensor reporting open/closed).
   * "Door / Window Contact" CONTACT_SENSOR output -> bind to a stock Door,
     Window, Garage or Gate contact driver for Navigator icons/programming.
   * Built-in light automation: lights on when opened, off after closing.
   * Events: Opened, Closed, Left Open, Tamper, Battery Low, Online/Offline.

 Open Source - MIT License. Not affiliated with Ubiquiti Inc. or Snap One LLC.
================================================================================
]]

local U = require("up_common")
local Child = U.Child
local Base = U.SensorBase
U.label = "UniFi Entry Sensor"

local CONTACT = 100
local TAMPER = 101

Entry = Entry or {}
Entry.open = nil
Entry.lights = U.LightLink.new()

local function setOpen(open, when)
  if open == nil or Entry.open == open then return end
  local first = Entry.open == nil
  Entry.open = open
  U.setVar("IS_OPEN", open)
  U.setProp("State", open and "Open" or "Closed")
  U.setVar("LAST_CHANGED", U.fmtTime(when or U.nowMs()))
  U.setProp("Last Changed", U.fmtTime(when or U.nowMs()))
  U.contact(CONTACT, not open)
  if first then return end
  if open then
    U.fire("Opened")
    Entry.lights:trigger()
    local mins = tonumber(U.prop("Left Open Alert (minutes)", "0")) or 0
    if mins > 0 then
      U.after("left_open", mins * 60000, function()
        if Entry.open then U.fire("Left Open") end
      end)
    end
  else
    U.stop("left_open")
    U.fire("Closed")
    Entry.lights:release()
  end
end

local function onState(dev, partial)
  Base.update(dev)
  local opened = dev.isOpened
  if opened ~= nil and opened ~= U.NULL then
    setOpen(opened and true or false, U.v(dev.openStatusChangedAt))
  end
end

local function onEvent(ev, action)
  Base.onEvent(ev, action)
  if action ~= "add" then return end
  local t = U.v(ev.type)
  if t == "sensorOpened" then
    setOpen(true, U.v(ev.start))
  elseif t == "sensorClosed" then
    setOpen(false, U.v(ev.start))
  elseif t == "sensorAlarm" then
    U.fire("Alarm Triggered")
  end
end

local function onSelected()
  Entry.open = nil
  Base.reset()
end

local COMMANDS = {
  ["Enable Light Automation"] = function() Entry.lights:setEnabled(true) U.setVar("LIGHT_AUTOMATION", true) end,
  ["Disable Light Automation"] = function() Entry.lights:setEnabled(false) U.setVar("LIGHT_AUTOMATION", false) end,
  Reconnect = function() Child.connect() end,
  TestLights = function() Entry.lights:trigger() Entry.lights:release() end,
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
  if bIsBound and (idBinding == CONTACT or idBinding == TAMPER) then
    U.after("contact_refresh_" .. idBinding, 500, function() U.contactRefresh(idBinding) end)
  end
end

function OnDriverInit()
  U.debugEnabled = U.prop("Debug Logging", "Off") == "On"
  Base.init(TAMPER)
  U.addVar("IS_OPEN", "0", "BOOL")
  U.addVar("LAST_CHANGED", "", "STRING")
  U.addVar("LIGHT_AUTOMATION", U.persistGet("lights_enabled", true) ~= false and "1" or "0", "BOOL")
end

function OnDriverLateInit()
  U.setProp("Driver Version", U.VERSION)
  Child.init({
    kind = "sensor",
    filter = function(dev)
      local f = U.v(dev.featureFlags)
      if type(f) == "table" and U.v(f.open) ~= nil then return true end
      local m = U.v(dev.mountType)
      return m == "door" or m == "window" or m == "garage"
    end,
    onState = onState,
    onEvent = onEvent,
    onSelected = onSelected,
  })
end
