--[[
================================================================================
 UniFi Protect Siren - child driver (USL-Siren / UP-Siren-PoE)
================================================================================
   * Programming commands: Sound Siren (5/10/20/30 s), Stop Siren, Test Sound,
     Set Volume.
   * "Trigger" contact input: bind any contact/relay (e.g. a stock contact
     driver or security panel output) - closing it sounds the siren.
   * Events: Siren Started, Siren Stopped. Variable SIREN_ACTIVE.

 Open Source - MIT License. Not affiliated with Ubiquiti Inc. or Snap One LLC.
================================================================================
]]

local U = require("up_common")
local Child = U.Child
U.label = "UniFi Siren"

local TRIGGER_IN = 200

Siren = Siren or {}
Siren.active = nil
Siren.online = nil

local function setActive(on)
  if Siren.active == on then return end
  local first = Siren.active == nil
  Siren.active = on
  U.setVar("SIREN_ACTIVE", on)
  U.setProp("Siren State", on and "SOUNDING" or "Idle")
  if not first then U.fire(on and "Siren Started" or "Siren Stopped") end
end

local function onState(dev, partial)
  U.setProp("Device Name", U.v(dev.name) or "")
  local st = U.v(dev.state)
  if st then
    local online = st == "CONNECTED"
    U.setProp("Sensor State", st)
    if Siren.online ~= online then
      local first = Siren.online == nil
      Siren.online = online
      U.setVar("ONLINE", online)
      if not first then U.fire(online and "Siren Online" or "Siren Offline") end
    end
  end
  if U.v(dev.volume) then U.setProp("Volume", tostring(U.v(dev.volume))) end
  local s = U.v(dev.sirenStatus)
  if type(s) == "table" and s.isActive ~= nil then
    local on = U.v(s.isActive) and true or false
    setActive(on)
    -- Protect does not always send a stop update after a timed run.
    local dur = tonumber(U.v(s.duration))
    if on and dur then U.after("siren_expire", dur + 2000, function() setActive(false) end) end
  end
end

local function play(seconds)
  seconds = tonumber(seconds) or tonumber(U.prop("Default Duration (seconds)", "10")) or 10
  local allowed = { 5, 10, 20, 30 }
  local best = 5
  for _, a in ipairs(allowed) do if seconds >= a then best = a end end
  Child.call("siren_play", { duration = best })
  setActive(true)
  U.after("siren_expire", best * 1000 + 2000, function() setActive(false) end)
end

local function onResult(req, ok, data, err, op)
  if not ok then U.err(tostring(op) .. " failed: " .. tostring(err)) end
  if op == "siren_play" and not ok then setActive(false) end
end

local COMMANDS = {
  ["Sound Siren"] = function(p) play(p.Duration or p.DURATION) end,
  ["Stop Siren"] = function() Child.call("siren_stop", {}) setActive(false) end,
  ["Test Sound"] = function(p) Child.call("siren_test", { volume = tonumber(p.Volume or p.VOLUME) }) end,
  ["Set Volume"] = function(p) Child.call("siren_volume", { volume = tonumber(p.Volume or p.VOLUME) or 100 }) end,
  Reconnect = function() Child.connect() end,
  TestSiren = function() Child.call("siren_test", {}) end,
}

function ExecuteCommand(strCommand, tParams)
  local cmd, params = U.normalizeCommand(strCommand, tParams)
  if Child.handleCommand(cmd, params) then return end
  local f = COMMANDS[cmd]
  if f then f(params) end
end

-- Contact input: a bound contact closing sounds the siren.
function ReceivedFromProxy(idBinding, strCommand, tParams)
  if Child.handleCommand(strCommand, tParams or {}) then return end
  if idBinding == TRIGGER_IN then
    if strCommand == "CLOSED" then
      if U.prop("Trigger Input", "Sound On Close") == "Sound On Close" then play() end
    elseif strCommand == "OPENED" then
      if U.prop("Trigger Input", "Sound On Close") == "Sound On Open" then play() end
      if U.prop("Stop When Trigger Releases", "No") == "Yes" and Siren.active then COMMANDS["Stop Siren"]() end
    end
  end
end

function OnPropertyChanged(strProperty)
  if Child.onPropertyChanged(strProperty) then return end
  if strProperty == "Debug Logging" then U.debugEnabled = Properties[strProperty] == "On" end
end

function OnBindingChanged(idBinding, strClass, bIsBound)
  Child.onBindingChanged(idBinding, strClass, bIsBound)
end

function OnDriverInit()
  U.debugEnabled = U.prop("Debug Logging", "Off") == "On"
  U.addVar("SIREN_ACTIVE", "0", "BOOL")
  U.addVar("ONLINE", "0", "BOOL")
end

function OnDriverLateInit()
  U.setProp("Driver Version", U.VERSION)
  Child.init({
    kind = "siren",
    onState = onState,
    onResult = onResult,
    onSelected = function() Siren.active = nil Siren.online = nil end,
  })
end
