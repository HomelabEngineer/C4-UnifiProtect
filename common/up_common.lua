--[[
================================================================================
 up_common.lua - shared library for the UniFi Protect Control4 driver set
================================================================================
 Copied into every .c4z by build.py. Contains:
   * bit shim, logging, timers, string/XML/URL helpers
   * a small JSON encoder/decoder that keeps JSON null (Protect partial
     updates use null to clear fields, e.g. "leakDetectedAt": null)
   * HTTP helper on top of C4:url() (self-signed certs allowed - UniFi OS
     consoles ship with self-signed certificates)
   * the master <-> child message protocol and a reusable child framework
     (master discovery, device picker property, subscription, re-sync)

 Open Source - MIT License. Not affiliated with Ubiquiti Inc. or Snap One LLC.
================================================================================
]]

local U = {}

U.VERSION = "1.0.1"
U.MASTER_C4Z = "unifi_protect.c4z"
U.MASTER_BINDING = 1          -- master provider / child consumer control binding
U.CHILD_BINDING = 1

-- ---------------------------------------------------------------------------
-- bit library (Control4 provides "bit"; fall back to bit32 or pure Lua)
-- ---------------------------------------------------------------------------
local bitlib = rawget(_G, "bit") or rawget(_G, "bit32")
if not bitlib then
  bitlib = {}
  local function tobits(op, a, b)
    local r, m = 0, 1
    a, b = a % 4294967296, b % 4294967296
    for _ = 1, 32 do
      local x, y = a % 2, b % 2
      local v
      if op == "and" then v = (x == 1 and y == 1) and 1 or 0
      elseif op == "or" then v = (x == 1 or y == 1) and 1 or 0
      else v = (x ~= y) and 1 or 0 end
      r = r + v * m
      m = m * 2
      a, b = math.floor(a / 2), math.floor(b / 2)
    end
    return r
  end
  function bitlib.band(a, b) return tobits("and", a, b) end
  function bitlib.bor(a, b) return tobits("or", a, b) end
  function bitlib.bxor(a, b) return tobits("xor", a, b) end
end
U.bit = bitlib

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------
U.label = "UniFi Protect"
U.debugEnabled = false

local function joinArgs(...)
  local n = select("#", ...)
  local parts = {}
  for i = 1, n do parts[#parts + 1] = tostring((select(i, ...))) end
  return table.concat(parts, " ")
end

function U.log(...)
  print(os.date("%H:%M:%S") .. " [" .. U.label .. "] " .. joinArgs(...))
end

function U.dbg(...)
  if U.debugEnabled then U.log(...) end
end

function U.err(...)
  local msg = joinArgs(...)
  U.log("ERROR: " .. msg)
  if C4 and C4.ErrorLog then pcall(C4.ErrorLog, C4, "[" .. U.label .. "] " .. msg) end
end

-- ---------------------------------------------------------------------------
-- Time / timers
-- ---------------------------------------------------------------------------
function U.nowMs()
  return os.time() * 1000
end

function U.setTimer(ms, fn, rep)
  if not (C4 and C4.SetTimer) then return nil end
  if ms < 1 then ms = 1 end
  return C4:SetTimer(ms, function(t, skips)
    local ok, e = pcall(fn, t, skips)
    if not ok then U.err("timer callback: " .. tostring(e)) end
  end, rep and true or false)
end

function U.cancel(t)
  if t then pcall(function() t:Cancel() end) end
  return nil
end

-- Named timers so a driver can re-arm without leaking the previous one.
local named = {}
function U.after(name, ms, fn)
  named[name] = U.cancel(named[name])
  named[name] = U.setTimer(ms, function()
    named[name] = nil
    fn()
  end, false)
end
function U.every(name, ms, fn)
  named[name] = U.cancel(named[name])
  named[name] = U.setTimer(ms, fn, true)
end
function U.stop(name)
  named[name] = U.cancel(named[name])
end
function U.isRunning(name)
  return named[name] ~= nil
end

-- ---------------------------------------------------------------------------
-- String helpers
-- ---------------------------------------------------------------------------
function U.trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function U.split(s, sep)
  local out = {}
  s = tostring(s or "")
  if s == "" then return out end
  local pattern = "([^" .. sep .. "]*)"
  for piece in (s .. sep):gmatch(pattern .. sep) do out[#out + 1] = piece end
  return out
end

function U.xmlEscape(s)
  s = tostring(s == nil and "" or s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;"))
end

function U.urlEncode(s)
  return (tostring(s or ""):gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

function U.urlDecode(s)
  s = tostring(s or ""):gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function U.parseQuery(q)
  local t = {}
  for pair in tostring(q or ""):gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=(.*)$")
    if k then t[U.urlDecode(k)] = U.urlDecode(v) else t[U.urlDecode(pair)] = "" end
  end
  return t
end

-- Names go into comma separated LIST properties, so they may not contain commas.
function U.listSafe(s)
  return (tostring(s or ""):gsub(",", " "):gsub("%s+", " "))
end

function U.yes(v)
  v = tostring(v or ""):lower()
  return v == "yes" or v == "on" or v == "true" or v == "1" or v == "enabled"
end

function U.fmtTime(ms, fmt)
  if not ms then return "" end
  local n = tonumber(ms)
  if not n then return "" end
  return os.date(fmt or "%a %b %d %I:%M:%S %p", math.floor(n / 1000))
end

function U.round(n, places)
  n = tonumber(n)
  if not n then return nil end
  local m = 10 ^ (places or 0)
  return math.floor(n * m + 0.5) / m
end

function U.cToF(c)
  c = tonumber(c)
  if not c then return nil end
  return c * 9 / 5 + 32
end

function U.randomToken(len)
  local chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  local out = {}
  for _ = 1, len or 16 do
    local i = math.random(1, #chars)
    out[#out + 1] = chars:sub(i, i)
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- JSON (null preserved as U.NULL)
-- ---------------------------------------------------------------------------
U.NULL = setmetatable({}, { __tostring = function() return "null" end })
local ARRAY_MT = { __jsontype = "array" }

function U.array(t) return setmetatable(t or {}, ARRAY_MT) end

-- Returns nil for JSON null so callers can use "x or default".
function U.v(x)
  if x == U.NULL then return nil end
  return x
end

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encodeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function isArray(t)
  local mt = getmetatable(t)
  if mt == ARRAY_MT then return true end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then return false end
    n = n + 1
  end
  if n == 0 then return false end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

local function encodeValue(v, depth)
  depth = depth or 0
  if depth > 64 then error("json: nesting too deep") end
  local tv = type(v)
  if v == nil or v == U.NULL then return "null" end
  if tv == "boolean" then return v and "true" or "false" end
  if tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if math.floor(v) == v and math.abs(v) < 1e15 then return string.format("%d", v) end
    return string.format("%.14g", v)
  end
  if tv == "string" then return encodeString(v) end
  if tv == "table" then
    local out = {}
    if isArray(v) then
      for i = 1, #v do out[#out + 1] = encodeValue(v[i], depth + 1) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local val = v[k]
      if val == nil then val = v[tonumber(k)] end
      out[#out + 1] = encodeString(k) .. ":" .. encodeValue(val, depth + 1)
    end
    return "{" .. table.concat(out, ",") .. "}"
  end
  return "null"
end

function U.jsonEncode(v)
  return encodeValue(v, 0)
end

local function codepointToUtf8(n)
  if n < 0x80 then return string.char(n) end
  if n < 0x800 then
    return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40)
  end
  if n < 0x10000 then
    return string.char(0xE0 + math.floor(n / 0x1000), 0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
  end
  return string.char(0xF0 + math.floor(n / 0x40000), 0x80 + math.floor(n / 0x1000) % 0x40,
    0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
end

function U.jsonDecode(str)
  if type(str) ~= "string" then return nil, "not a string" end
  local pos = 1
  local len = #str

  local function fail(msg) error("json: " .. msg .. " at " .. pos, 0) end
  local function skip()
    pos = str:find("[^ \t\r\n]", pos) or len + 1
  end

  local parseValue

  local function parseString()
    pos = pos + 1
    local buf = {}
    while true do
      local s, e = str:find('["\\]', pos)
      if not s then fail("unterminated string") end
      buf[#buf + 1] = str:sub(pos, s - 1)
      local c = str:sub(s, s)
      if c == '"' then pos = s + 1 break end
      local esc = str:sub(s + 1, s + 1)
      if esc == "u" then
        local hex = str:sub(s + 2, s + 5)
        local n = tonumber(hex, 16)
        if not n then fail("bad unicode escape") end
        pos = s + 6
        if n >= 0xD800 and n <= 0xDBFF and str:sub(pos, pos + 1) == "\\u" then
          local lo = tonumber(str:sub(pos + 2, pos + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            n = 0x10000 + (n - 0xD800) * 0x400 + (lo - 0xDC00)
            pos = pos + 6
          end
        end
        buf[#buf + 1] = codepointToUtf8(n)
      else
        local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        local ch = map[esc]
        if not ch then fail("bad escape") end
        buf[#buf + 1] = ch
        pos = s + 2
      end
    end
    return table.concat(buf)
  end

  local function parseNumber()
    local s, e = str:find("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not s then fail("bad number") end
    local n = tonumber(str:sub(s, e))
    if not n then fail("bad number") end
    pos = e + 1
    return n
  end

  local function parseArray()
    pos = pos + 1
    local arr = U.array({})
    skip()
    if str:sub(pos, pos) == "]" then pos = pos + 1 return arr end
    while true do
      arr[#arr + 1] = parseValue()
      skip()
      local c = str:sub(pos, pos)
      if c == "]" then pos = pos + 1 return arr end
      if c ~= "," then fail("expected , or ]") end
      pos = pos + 1
    end
  end

  local function parseObject()
    pos = pos + 1
    local obj = {}
    skip()
    if str:sub(pos, pos) == "}" then pos = pos + 1 return obj end
    while true do
      skip()
      if str:sub(pos, pos) ~= '"' then fail("expected key") end
      local k = parseString()
      skip()
      if str:sub(pos, pos) ~= ":" then fail("expected :") end
      pos = pos + 1
      obj[k] = parseValue()
      skip()
      local c = str:sub(pos, pos)
      if c == "}" then pos = pos + 1 return obj end
      if c ~= "," then fail("expected , or }") end
      pos = pos + 1
    end
  end

  parseValue = function()
    skip()
    local c = str:sub(pos, pos)
    if c == "{" then return parseObject() end
    if c == "[" then return parseArray() end
    if c == '"' then return parseString() end
    if c == "-" or c:match("%d") then return parseNumber() end
    if str:sub(pos, pos + 3) == "true" then pos = pos + 4 return true end
    if str:sub(pos, pos + 4) == "false" then pos = pos + 5 return false end
    if str:sub(pos, pos + 3) == "null" then pos = pos + 4 return U.NULL end
    fail("unexpected character '" .. c .. "'")
  end

  local ok, res = pcall(function()
    local v = parseValue()
    skip()
    return v
  end)
  if not ok then return nil, res end
  return res
end

-- Deep merge src into dst (partial websocket updates). Arrays are replaced.
function U.merge(dst, src)
  if type(dst) ~= "table" or type(src) ~= "table" then return src end
  for k, v in pairs(src) do
    if type(v) == "table" and v ~= U.NULL and getmetatable(v) ~= ARRAY_MT
        and type(dst[k]) == "table" and dst[k] ~= U.NULL and getmetatable(dst[k]) ~= ARRAY_MT then
      U.merge(dst[k], v)
    else
      dst[k] = v
    end
  end
  return dst
end

function U.copy(t)
  if type(t) ~= "table" or t == U.NULL then return t end
  local out = setmetatable({}, getmetatable(t))
  for k, v in pairs(t) do out[k] = U.copy(v) end
  return out
end

-- path lookup: U.get(dev, "stats", "temperature", "value")
function U.get(t, ...)
  local cur = t
  for i = 1, select("#", ...) do
    if type(cur) ~= "table" or cur == U.NULL then return nil end
    cur = cur[(select(i, ...))]
  end
  return U.v(cur)
end

-- ---------------------------------------------------------------------------
-- HTTP via C4:url()
-- ---------------------------------------------------------------------------
-- opts = { method, url, headers, body, timeout, cb = function(code, body, headers, err) }
function U.http(opts)
  local method = string.upper(opts.method or "GET")
  local headers = opts.headers or {}
  local cb = opts.cb or function() end
  local ok, e = pcall(function()
    local t = C4:url()
    t:SetOptions({
      fail_on_error = false,
      timeout = opts.timeout or 20,
      connect_timeout = opts.connectTimeout or 6,
      ssl_verify_host = false,
      ssl_verify_peer = false,
      cookies_enable = false,
    })
    t:OnDone(function(transfer, responses, errCode, errMsg)
      local code, body, hdrs = 0, "", {}
      if errCode == 0 and type(responses) == "table" and #responses > 0 then
        local r = responses[#responses]
        code = tonumber(r.code) or 0
        body = r.body or ""
        hdrs = r.headers or {}
      end
      local errStr = nil
      if errCode ~= 0 then errStr = errMsg or ("transfer error " .. tostring(errCode)) end
      local ok2, e2 = pcall(cb, code, body, hdrs, errStr)
      if not ok2 then U.err("http callback (" .. method .. " " .. tostring(opts.url) .. "): " .. tostring(e2)) end
    end)
    if method == "GET" then
      t:Get(opts.url, headers)
    elseif method == "POST" then
      t:Post(opts.url, opts.body or "", headers)
    elseif method == "PUT" then
      t:Put(opts.url, opts.body or "", headers)
    elseif method == "DELETE" then
      t:Delete(opts.url, opts.body or "", headers)
    else
      t:Custom(opts.url, method, opts.body or "", headers)
    end
  end)
  if not ok then
    U.err("http start failed: " .. tostring(e))
    pcall(cb, 0, "", {}, tostring(e))
  end
end

-- Case-insensitive header lookup (C4 header tables vary in case).
function U.header(headers, name)
  if type(headers) ~= "table" then return nil end
  local lname = name:lower()
  for k, v in pairs(headers) do
    if tostring(k):lower() == lname then
      if type(v) == "table" then return table.concat(v, "; ") end
      return v
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Properties / persistence
-- ---------------------------------------------------------------------------
function U.prop(name, default)
  local v = Properties and Properties[name]
  if v == nil or v == "" then return default end
  return v
end

function U.setProp(name, value)
  value = tostring(value == nil and "" or value)
  if Properties and Properties[name] == value then return end
  pcall(C4.UpdateProperty, C4, name, value)
end

function U.persistGet(key, default)
  PersistData = PersistData or {}
  local v = PersistData[key]
  if v == nil then return default end
  return v
end

function U.persistSet(key, value)
  PersistData = PersistData or {}
  PersistData[key] = value
end

-- Variables: add once, set when changed.
local varCache = {}
function U.addVar(name, default, vtype)
  if varCache[name] ~= nil then return end
  local ok = pcall(C4.AddVariable, C4, name, tostring(default), vtype or "STRING", true, false)
  varCache[name] = tostring(default)
  return ok
end
function U.setVar(name, value)
  if type(value) == "boolean" then value = value and "1" or "0" end
  value = tostring(value == nil and "" or value)
  if varCache[name] == value then return end
  varCache[name] = value
  pcall(C4.SetVariable, C4, name, value)
end

function U.fire(eventName)
  U.dbg("Event: " .. eventName)
  pcall(C4.FireEvent, C4, eventName)
end

-- ---------------------------------------------------------------------------
-- Contact output helper (CONTACT_SENSOR provider bindings)
-- ---------------------------------------------------------------------------
local contactState = {}
-- active=true means "contact closed" unless invert is set by the caller.
function U.contact(binding, closed, force)
  local key = tostring(binding)
  if not force and contactState[key] == closed then return end
  contactState[key] = closed
  pcall(C4.SendToProxy, C4, binding, closed and "CLOSED" or "OPENED", {})
end
function U.contactRefresh(binding)
  local v = contactState[tostring(binding)]
  if v == nil then return end
  pcall(C4.SendToProxy, C4, binding, v and "STATE_CLOSED" or "STATE_OPENED", {})
end

-- ---------------------------------------------------------------------------
-- Linked lights (DEVICE_SELECTOR property value = comma separated proxy ids)
-- ---------------------------------------------------------------------------
function U.deviceList(propValue)
  local ids = {}
  for _, s in ipairs(U.split(propValue or "", ",")) do
    local n = tonumber(U.trim(s))
    if n then ids[#ids + 1] = n end
  end
  return ids
end

function U.lightsOn(ids, level)
  level = tonumber(level) or 100
  for _, id in ipairs(ids) do
    if level >= 100 then
      pcall(C4.SendToDevice, C4, id, "ON", {})
    else
      pcall(C4.SendToDevice, C4, id, "SET_LEVEL", { LEVEL = tostring(level) })
    end
  end
end

function U.lightsOff(ids)
  for _, id in ipairs(ids) do pcall(C4.SendToDevice, C4, id, "OFF", {}) end
end

-- ---------------------------------------------------------------------------
-- Light automation (entry / motion sensors)
--   Properties used: "Linked Lights" (DEVICE_SELECTOR), "Light Level (%)",
--   "Turn Lights Off" (Yes/No), "Lights Off Delay (seconds)", "Light Automation"
-- ---------------------------------------------------------------------------
local LightLink = {}
LightLink.__index = LightLink
U.LightLink = LightLink

function LightLink.new()
  return setmetatable({ active = false }, LightLink)
end

function LightLink:enabled()
  return U.prop("Light Automation", "Enabled") == "Enabled" and U.persistGet("lights_enabled", true) ~= false
end

function LightLink:ids()
  return U.deviceList(U.prop("Linked Lights", ""))
end

-- true/false when the light proxy reports its level/state, nil if unknown.
function U.lightIsOn(id)
  local ok, vars = pcall(C4.GetDeviceVariables, C4, id)
  if ok and type(vars) == "table" then
    for _, v in pairs(vars) do
      if type(v) == "table" then
        local name = v.name or v.NAME
        if name == "LIGHT_LEVEL" or name == "LIGHT_STATE" then
          local val = tonumber(v.value or v.VALUE)
          if val then return val > 0 end
        end
      end
    end
  end
  return nil
end

-- Sensor became active (door opened / motion): turn lights on now.
function LightLink:trigger()
  U.stop("lights_off")
  if not self:enabled() then return end
  local ids = self:ids()
  if #ids == 0 then return end
  if not self.active then
    -- Remember which lights were off, so we only turn those back off later.
    self.owned = {}
    for _, id in ipairs(ids) do
      if U.lightIsOn(id) ~= true then self.owned[#self.owned + 1] = id end
    end
  end
  U.lightsOn(ids, tonumber(U.prop("Light Level (%)", "100")) or 100)
  self.active = true
  U.dbg("Lights on: " .. table.concat(ids, ","))
end

-- Sensor became idle (door closed / motion cleared): schedule lights off.
function LightLink:release()
  if not self.active then return end
  if U.prop("Turn Lights Off", "Yes") ~= "Yes" then self.active = false return end
  local delay = tonumber(U.prop("Lights Off Delay (seconds)", "30")) or 30
  U.after("lights_off", math.max(0, delay) * 1000 + 1, function()
    self.active = false
    local ids = self:ids()
    if U.prop("Only Turn Off Lights It Turned On", "Yes") == "Yes" and self.owned then ids = self.owned end
    self.owned = nil
    U.lightsOff(ids)
    U.dbg("Lights off: " .. table.concat(ids, ","))
  end)
end

function LightLink:setEnabled(on)
  U.persistSet("lights_enabled", on and true or false)
  if not on then U.stop("lights_off") end
end

-- ---------------------------------------------------------------------------
-- Shared SuperLink sensor status (online, battery, tamper, name)
-- ---------------------------------------------------------------------------
local SensorBase = { online = nil, batteryLow = nil, tampered = nil, tamperBinding = nil }
U.SensorBase = SensorBase

function SensorBase.init(tamperBinding)
  SensorBase.tamperBinding = tamperBinding
  U.addVar("ONLINE", "0", "BOOL")
  U.addVar("BATTERY_PERCENT", "", "STRING")
  U.addVar("BATTERY_LOW", "0", "BOOL")
  U.addVar("TAMPERED", "0", "BOOL")
end

function SensorBase.reset()
  SensorBase.online, SensorBase.batteryLow, SensorBase.tampered = nil, nil, nil
end

function SensorBase.setTamper(on)
  if SensorBase.tampered == on then return end
  local first = SensorBase.tampered == nil
  SensorBase.tampered = on
  U.setVar("TAMPERED", on)
  U.setProp("Tamper", on and "TAMPERED" or "OK")
  if SensorBase.tamperBinding then U.contact(SensorBase.tamperBinding, on) end
  if not first or on then U.fire(on and "Tamper Detected" or "Tamper Cleared") end
end

function SensorBase.update(dev)
  if type(dev) ~= "table" then return end
  U.setProp("Device Name", U.v(dev.name) or "")
  local mount = U.v(dev.mountType)
  if mount then U.setProp("Mount Type", mount) end
  local st = U.v(dev.state)
  if st then
    local online = st == "CONNECTED"
    if SensorBase.online ~= online then
      local first = SensorBase.online == nil
      SensorBase.online = online
      U.setVar("ONLINE", online)
      U.setProp("Sensor State", st)
      if not first then U.fire(online and "Sensor Online" or "Sensor Offline") end
    end
  end
  local bat = U.v(dev.batteryStatus)
  if type(bat) == "table" then
    local pct = U.v(bat.percentage)
    local low = U.v(bat.isLow) and true or false
    if pct then U.setVar("BATTERY_PERCENT", tostring(math.floor(tonumber(pct) or 0))) end
    U.setProp("Battery", (pct and (tostring(math.floor(tonumber(pct) or 0)) .. "%") or "--") .. (low and " (LOW)" or ""))
    if SensorBase.batteryLow ~= low then
      local first = SensorBase.batteryLow == nil
      SensorBase.batteryLow = low
      U.setVar("BATTERY_LOW", low)
      if low and (not first or low) then U.fire("Battery Low") end
    end
  end
  if dev.tamperingDetectedAt ~= nil then
    SensorBase.setTamper(U.v(dev.tamperingDetectedAt) ~= nil)
  end
end

-- Sensor events common to every SuperLink device.
function SensorBase.onEvent(ev, action)
  local t = U.v(ev.type)
  if action ~= "add" then return end
  if t == "sensorTamper" then
    SensorBase.setTamper(true)
  elseif t == "sensorBatteryLow" or t == "sensorSmokeBatteryLow" then
    if not SensorBase.batteryLow then
      SensorBase.batteryLow = true
      U.setVar("BATTERY_LOW", true)
      U.fire("Battery Low")
    end
  end
end

-- ---------------------------------------------------------------------------
-- Master <-> child protocol (C4:SendToDevice -> ExecuteCommand)
-- ---------------------------------------------------------------------------
U.MSG = {
  -- child -> master
  HELLO = "UP_HELLO",             -- CHILD, KIND
  SUBSCRIBE = "UP_SUBSCRIBE",     -- CHILD, KIND, DEVICE
  UNSUBSCRIBE = "UP_UNSUBSCRIBE", -- CHILD
  CALL = "UP_CALL",               -- CHILD, REQ, OP, ARGS(json)
  -- master -> child
  PING = "UP_PING",               -- MASTER (ask the child to say hello)
  CONFIG = "UP_CONFIG",           -- JSON {online, mediaBase, privateApi, host}
  DEVICES = "UP_DEVICES",         -- JSON [ {id,name,type,modelKey,...} ]
  STATE = "UP_STATE",             -- JSON full device, PARTIAL="1" for merges
  EVENT = "UP_EVENT",             -- JSON event, ACTION=add|update
  STREAMS = "UP_STREAMS",         -- JSON {high=url,...}
  RESULT = "UP_RESULT",           -- REQ, OK, JSON / ERROR
}

function U.send(deviceId, cmd, params)
  if not deviceId then return false end
  local p = {}
  for k, v in pairs(params or {}) do p[k] = tostring(v) end
  local ok, e = pcall(C4.SendToDevice, C4, tonumber(deviceId), cmd, p)
  if not ok then U.err("SendToDevice " .. tostring(deviceId) .. " " .. cmd .. ": " .. tostring(e)) end
  return ok
end

-- Device ids of every instance of a driver file (.c4z) in the project.
function U.findDevicesByDriver(fileName)
  local ids, seen = {}, {}
  local function add(id)
    id = tonumber(id)
    if id and id > 0 and not seen[id] then seen[id] = true ids[#ids + 1] = id end
  end
  pcall(function()
    local res = C4:GetDevices({ C4iNames = fileName })
    if type(res) == "table" then for k in pairs(res) do add(k) end end
  end)
  if #ids == 0 then
    pcall(function()
      local res = C4:GetDevicesByC4iName(fileName)
      if type(res) == "table" then
        for k, v in pairs(res) do
          if type(v) == "number" or tonumber(v) then add(v) else add(k) end
        end
      end
    end)
  end
  table.sort(ids)
  return ids
end

function U.myId()
  local ok, id = pcall(C4.GetDeviceID, C4)
  if ok then return tonumber(id) end
  return nil
end

-- ---------------------------------------------------------------------------
-- Child framework
-- ---------------------------------------------------------------------------
--[[
  cfg = {
    kind      = "camera" | "sensor" | "siren",
    filter    = function(dev) return true end,   -- which devices to offer
    onState   = function(dev, partialTable) end, -- full state (dev) after merge
    onEvent   = function(ev, action) end,
    onOnline  = function(online) end,            -- master <-> console link
    onConfig  = function(cfg) end,
    onStreams = function(streams) end,           -- camera only
    onResult  = function(req, ok, data, err) end,
    onSelected= function(id) end,                -- device selection changed
  }
]]
local Child = {}
U.Child = Child

Child.cfg = nil
Child.master = nil
Child.deviceId = nil          -- Protect id
Child.device = nil            -- merged device table
Child.devices = {}            -- list from master
Child.byLabel = {}
Child.masterConfig = {}
Child.reqSeq = 0
Child.lastSubscribeOk = false

Child.PROP_DEVICE = "Protect Device"
Child.PROP_STATUS = "Connection Status"

function Child.findMaster()
  local me = U.myId()
  local master
  pcall(function()
    master = C4:GetBoundProviderDevice(me, U.CHILD_BINDING)
  end)
  master = tonumber(master)
  if master and master > 0 then return master, "binding" end
  local found = U.findDevicesByDriver(U.MASTER_C4Z)
  if #found == 1 then return found[1], "auto" end
  if #found > 1 then return nil, "multiple" end
  return nil, "none"
end

function Child.status(text)
  U.setProp(Child.PROP_STATUS, text)
end

function Child.labelFor(dev)
  local name = U.listSafe(U.v(dev.name) or "Unnamed")
  local model = U.v(dev.type) or U.v(dev.marketName) or U.v(dev.modelKey) or ""
  if model ~= "" then return name .. " (" .. U.listSafe(model) .. ")" end
  return name
end

function Child.init(cfg)
  Child.cfg = cfg
  Child.deviceId = U.persistGet("protect_device_id")
  local label = U.persistGet("protect_device_label")
  if label and label ~= "" then
    pcall(C4.UpdatePropertyList, C4, Child.PROP_DEVICE, label, label)
    U.setProp(Child.PROP_DEVICE, label)
  end
  Child.connect()
  -- Periodic safety net: re-hello if the master forgot us (master restart).
  U.every("child_keepalive", 5 * 60 * 1000, function()
    if not Child.master or not Child.lastSubscribeOk then Child.connect() end
  end)
end

function Child.connect()
  local master, how = Child.findMaster()
  if not master then
    Child.master = nil
    if how == "multiple" then
      Child.status("Bind this driver to a UniFi Protect master (more than one found)")
    else
      Child.status("Waiting for UniFi Protect master driver")
    end
    return
  end
  Child.master = master
  U.dbg("Master device " .. tostring(master) .. " via " .. how)
  Child.status("Contacting master...")
  U.send(master, U.MSG.HELLO, { CHILD = U.myId(), KIND = Child.cfg.kind })
  if Child.deviceId and Child.deviceId ~= "" then
    Child.subscribe()
  end
end

function Child.subscribe()
  if not Child.master or not Child.deviceId or Child.deviceId == "" then return end
  U.send(Child.master, U.MSG.SUBSCRIBE, { CHILD = U.myId(), KIND = Child.cfg.kind, DEVICE = Child.deviceId })
end

function Child.call(op, args)
  if not Child.master then return nil end
  Child.reqSeq = Child.reqSeq + 1
  U.send(Child.master, U.MSG.CALL, {
    CHILD = U.myId(), REQ = Child.reqSeq, OP = op,
    DEVICE = Child.deviceId or "", ARGS = U.jsonEncode(args or {}),
  })
  return Child.reqSeq
end

function Child.selectByLabel(label)
  local dev = Child.byLabel[label]
  if not dev then return end
  local id = U.v(dev.id)
  if id == Child.deviceId then return end
  if Child.master and Child.deviceId then
    U.send(Child.master, U.MSG.UNSUBSCRIBE, { CHILD = U.myId() })
  end
  Child.deviceId = id
  Child.device = nil
  U.persistSet("protect_device_id", id)
  U.persistSet("protect_device_label", label)
  if Child.cfg.onSelected then Child.cfg.onSelected(id) end
  Child.subscribe()
end

function Child.applyDeviceList(list)
  Child.devices = {}
  Child.byLabel = {}
  local labels = {}
  local selectedLabel = nil
  local candidates = {}
  for _, dev in ipairs(list or {}) do
    if not Child.cfg.filter or Child.cfg.filter(dev) then candidates[#candidates + 1] = dev end
  end
  -- Never hide everything: if the filter matched nothing, offer all devices.
  if #candidates == 0 then candidates = list or {} end
  table.sort(candidates, function(a, b) return tostring(U.v(a.name) or "") < tostring(U.v(b.name) or "") end)
  for _, dev in ipairs(candidates) do
    local label = Child.labelFor(dev)
    local base, n = label, 2
    while Child.byLabel[label] do label = base .. " #" .. n; n = n + 1 end
    Child.byLabel[label] = dev
    Child.devices[#Child.devices + 1] = dev
    labels[#labels + 1] = label
    if U.v(dev.id) == Child.deviceId then selectedLabel = label end
  end
  local listStr = table.concat(labels, ",")
  if selectedLabel then
    U.persistSet("protect_device_label", selectedLabel)
  end
  pcall(C4.UpdatePropertyList, C4, Child.PROP_DEVICE, listStr, selectedLabel or "")
  if selectedLabel then U.setProp(Child.PROP_DEVICE, selectedLabel) end
  if not Child.deviceId or Child.deviceId == "" then
    Child.status(#labels > 0 and "Select a device in '" .. Child.PROP_DEVICE .. "'" or "No matching Protect devices found")
  end
end

-- Returns true when the command was a protocol message.
function Child.handleCommand(cmd, params)
  params = params or {}
  if cmd == U.MSG.PING then
    if params.MASTER then Child.master = tonumber(params.MASTER) or Child.master end
    U.send(Child.master, U.MSG.HELLO, { CHILD = U.myId(), KIND = Child.cfg.kind })
    if Child.deviceId then Child.subscribe() end
    return true
  elseif cmd == U.MSG.CONFIG then
    local cfg = U.jsonDecode(params.JSON or "") or {}
    Child.masterConfig = cfg
    if not cfg.online then
      Child.status("Master offline: " .. tostring(U.v(cfg.status) or "not connected to console"))
    end
    if Child.cfg.onConfig then Child.cfg.onConfig(cfg) end
    if Child.cfg.onOnline then Child.cfg.onOnline(cfg.online and true or false) end
    return true
  elseif cmd == U.MSG.DEVICES then
    local list = U.jsonDecode(params.JSON or "") or {}
    Child.applyDeviceList(list)
    return true
  elseif cmd == U.MSG.STATE then
    local data = U.jsonDecode(params.JSON or "")
    if type(data) ~= "table" then return true end
    if U.v(data.id) and Child.deviceId and U.v(data.id) ~= Child.deviceId then return true end
    if params.PARTIAL == "1" and Child.device then
      U.merge(Child.device, data)
    else
      Child.device = data
    end
    Child.lastSubscribeOk = true
    local st = U.v(Child.device.state) or "UNKNOWN"
    local online = Child.masterConfig.online ~= false
    Child.status(online and ("Connected - " .. Child.labelFor(Child.device) .. " - " .. st) or "Master offline")
    if Child.cfg.onState then Child.cfg.onState(Child.device, data) end
    return true
  elseif cmd == U.MSG.EVENT then
    local ev = U.jsonDecode(params.JSON or "")
    if type(ev) == "table" and Child.cfg.onEvent then Child.cfg.onEvent(ev, params.ACTION or "add") end
    return true
  elseif cmd == U.MSG.STREAMS then
    local s = U.jsonDecode(params.JSON or "") or {}
    if Child.cfg.onStreams then Child.cfg.onStreams(s) end
    return true
  elseif cmd == U.MSG.RESULT then
    local data = params.JSON and U.jsonDecode(params.JSON) or nil
    if Child.cfg.onResult then
      Child.cfg.onResult(tonumber(params.REQ), params.OK == "1", data, params.ERROR, params.OP)
    end
    return true
  end
  return false
end

function Child.onPropertyChanged(name)
  if name == Child.PROP_DEVICE then
    Child.selectByLabel(Properties[name])
    return true
  end
  return false
end

function Child.onBindingChanged(idBinding, class, bound)
  if idBinding == U.CHILD_BINDING then
    U.after("child_rebind", 500, Child.connect)
    return true
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Command dispatch helper used by every driver's ExecuteCommand.
-- Programming commands arrive as strCommand == "LUA_ACTION" (actions) or the
-- command name itself; Composer "Actions" arrive with tParams.ACTION.
-- ---------------------------------------------------------------------------
function U.normalizeCommand(strCommand, tParams)
  tParams = tParams or {}
  if strCommand == "LUA_ACTION" and tParams.ACTION then
    return tParams.ACTION, tParams
  end
  return strCommand, tParams
end

return U
