--[[
================================================================================
 UniFi Protect SuperLink Smoke & CO Alarm - child driver
================================================================================
   * "Smoke" and "Carbon Monoxide" CONTACT_SENSOR outputs for the stock
     Smoke Detector / Carbon Monoxide Detector contact drivers.
   * Events: Smoke Alarm, CO Alarm, Alarm Cleared, Alarm Test, Fault,
     Needs Cleaning, End of Life, Battery Low, Tamper, Online/Offline.

 Life-safety note: this integration is a convenience layer. It is not a
 listed fire/CO alarm signalling path and must not replace monitoring.

 Open Source - MIT License. Not affiliated with Ubiquiti Inc. or Snap One LLC.
================================================================================
]]

local U = require("up_common")
local Child = U.Child
local Base = U.SensorBase
U.label = "UniFi Smoke/CO Alarm"

local SMOKE = 100
local CO = 101
local TAMPER = 102

Alarm = Alarm or {}
Alarm.smoke = false
Alarm.co = false
Alarm.events = {}   -- active alarm event id -> "smoke" | "co"

local function activeClosed()
  return U.prop("Contact Closes On Alarm", "Yes") == "Yes"
end

local function refreshContacts(force)
  U.contact(SMOKE, Alarm.smoke == activeClosed(), force)
  U.contact(CO, Alarm.co == activeClosed(), force)
end

local function setAlarm(kind, on)
  if Alarm[kind] == on then return end
  Alarm[kind] = on
  U.setVar(kind == "smoke" and "SMOKE_ALARM" or "CO_ALARM", on)
  U.setVar("ALARM_ACTIVE", Alarm.smoke or Alarm.co)
  U.setProp("Alarm State", (Alarm.smoke and "SMOKE " or "") .. (Alarm.co and "CO " or "") .. ((Alarm.smoke or Alarm.co) and "ALARM" or "Normal"))
  refreshContacts()
  if on then
    U.setVar("LAST_ALARM", U.fmtTime(U.nowMs()) .. " " .. (kind == "smoke" and "Smoke" or "CO"))
    U.fire(kind == "smoke" and "Smoke Alarm" or "CO Alarm")
    U.fire("Any Alarm")
    -- Failsafe: clear if Protect never sends the end of the alarm event.
    U.after("alarm_failsafe_" .. kind, 30 * 60000, function() setAlarm(kind, false) end)
  else
    U.stop("alarm_failsafe_" .. kind)
    if not (Alarm.smoke or Alarm.co) then U.fire("Alarm Cleared") end
  end
end

local function alarmKind(ev)
  local a = U.get(ev, "metadata", "alarmType", "text") or U.get(ev, "metadata", "alarmType")
  a = tostring(a or ""):lower()
  if a == "co" or a:find("cmonx", 1, true) or a:find("carbon", 1, true) then return "co" end
  if a == "smoke" then return "smoke" end
  return nil
end

local SIMPLE_EVENTS = {
  sensorSmokeTest = "Alarm Test",
  sensorSmokeFault = "Fault",
  sensorCoFault = "Fault",
  sensorSmokeNeedsCleaning = "Needs Cleaning",
  sensorSmokeEndOfLife = "End of Life",
}

local function onEvent(ev, action)
  Base.onEvent(ev, action)
  local id = U.v(ev.id)
  local t = U.v(ev.type)
  if t == "sensorAlarm" or (t == nil and id and Alarm.events[id]) then
    local kind = alarmKind(ev) or (id and Alarm.events[id])
    if not kind then return end
    if action == "add" and not U.v(ev["end"]) then
      if id then Alarm.events[id] = kind end
      setAlarm(kind, true)
    elseif U.v(ev["end"]) then
      if id then Alarm.events[id] = nil end
      setAlarm(kind, false)
    end
  elseif action == "add" and SIMPLE_EVENTS[t] then
    U.setVar("LAST_STATUS_EVENT", SIMPLE_EVENTS[t] .. " " .. U.fmtTime(U.nowMs()))
    U.fire(SIMPLE_EVENTS[t])
  end
end

local function onState(dev, partial)
  Base.update(dev)
  -- alarmTriggeredAt cleared by Protect -> nothing active anymore.
  if dev.alarmTriggeredAt ~= nil and U.v(dev.alarmTriggeredAt) == nil and partial.alarmTriggeredAt ~= nil then
    Alarm.events = {}
    setAlarm("smoke", false)
    setAlarm("co", false)
  end
end

local COMMANDS = {
  Reconnect = function() Child.connect() end,
  ["Reset Alarm State"] = function()
    Alarm.events = {}
    setAlarm("smoke", false)
    setAlarm("co", false)
  end,
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
  if strProperty == "Debug Logging" then U.debugEnabled = Properties[strProperty] == "On"
  elseif strProperty == "Contact Closes On Alarm" then refreshContacts(true) end
end

function OnBindingChanged(idBinding, strClass, bIsBound)
  if Child.onBindingChanged(idBinding, strClass, bIsBound) then return end
  if bIsBound then U.after("rebind_" .. idBinding, 500, function() U.contactRefresh(idBinding) end) end
end

function OnDriverInit()
  U.debugEnabled = U.prop("Debug Logging", "Off") == "On"
  Base.init(TAMPER)
  U.addVar("SMOKE_ALARM", "0", "BOOL")
  U.addVar("CO_ALARM", "0", "BOOL")
  U.addVar("ALARM_ACTIVE", "0", "BOOL")
  U.addVar("LAST_ALARM", "", "STRING")
  U.addVar("LAST_STATUS_EVENT", "", "STRING")
end

function OnDriverLateInit()
  U.setProp("Driver Version", U.VERSION)
  U.setProp("Alarm State", "Normal")
  refreshContacts(true)
  Child.init({
    kind = "sensor",
    filter = function(dev)
      local f = U.v(dev.featureFlags)
      if type(f) == "table" and U.v(f.smoke) ~= nil then return true end
      local t = tostring(U.v(dev.type) or ""):lower()
      return t:find("smoke", 1, true) or t:find("co ", 1, true) or t:find("alarm", 1, true)
    end,
    onState = onState,
    onEvent = onEvent,
    onSelected = function() Base.reset() end,
  })
end
