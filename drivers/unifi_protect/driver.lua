--[[
================================================================================
 UniFi Protect - Master Driver (Control4 DriverWorks)
================================================================================
 Connects to a UniFi OS console / NVR running UniFi Protect and serves the
 child drivers (cameras, doorbells, SuperLink sensors, sirens).

   * Official Protect Integration API (API key, X-API-KEY header)
       - REST:  /proxy/protect/integration/v1/{cameras,sensors,sirens,...}
       - WS:    /proxy/protect/integration/v1/subscribe/events   (rings, motion,
                 smart detections, sensor open/close/leak/alarm...)
                /proxy/protect/integration/v1/subscribe/devices  (state deltas)
       - RTSPS stream creation, snapshots, doorbell LCD, PTZ, sirens
   * Private Protect API (optional local username/password) - only source of
     event history and recorded footage:
       - /proxy/protect/api/events                       (history list)
       - /proxy/protect/api/events/{id}/thumbnail         (event image)
       - /proxy/protect/api/cameras/{id}/recording-snapshot?ts=  (recorded frame)
   * Media server on the controller (C4:CreateTCPServer) so Navigators can
     load snapshots / MJPEG without Protect credentials:
       /up/<token>/snap/<cam>.jpg         live snapshot
       /up/<token>/live/<cam>.mjpg        live MJPEG (fallback stream)
       /up/<token>/play/<cam>/<ms>.mjpg   recorded playback as MJPEG
       /up/<token>/frame/<cam>/<ms>.jpg   single recorded frame
       /up/<token>/thumb/<event>.jpg      event thumbnail

 Open Source - MIT License. Not affiliated with Ubiquiti Inc. or Snap One LLC.
================================================================================
]]

local U = require("up_common")
U.label = "UniFi Protect"

local WS_EVENTS_BINDING = 6100
local WS_DEVICES_BINDING = 6101
local MAX_MEDIA_CLIENTS = 24
local RESYNC_INTERVAL_MS = 10 * 60 * 1000

local CHILD_C4Z = {
  "unifi_protect_camera.c4z",
  "unifi_protect_entry.c4z",
  "unifi_protect_motion.c4z",
  "unifi_protect_environmental.c4z",
  "unifi_protect_smoke_co.c4z",
  "unifi_protect_siren.c4z",
}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
State = State or {}
State.online = false
State.status = "Not configured"
State.version = nil
State.nvr = nil
State.cameras = {}
State.sensors = {}
State.sirens = {}
State.streams = {}
State.streamWaiters = {}
State.children = {}        -- [childDeviceId] = { kind = "camera", device = "<protect id>" }
State.eventDevice = {}     -- [eventId] = protect device id
State.eventOrder = {}
State.connectSeq = 0

local KIND_TABLE = {
  camera = function() return State.cameras end,
  sensor = function() return State.sensors end,
  siren = function() return State.sirens end,
}

local MODEL_KIND = { camera = "camera", sensor = "sensor", siren = "siren" }

-- ---------------------------------------------------------------------------
-- Configuration helpers
-- ---------------------------------------------------------------------------
local function cfg()
  return {
    host = U.trim(U.prop("Console Address", "")),
    port = tonumber(U.prop("Console Port", "443")) or 443,
    apiKey = U.trim(U.prop("API Key", "")),
    user = U.trim(U.prop("Local Username", "")),
    pass = U.prop("Local Password", "") or "",
  }
end

local function hostForUrl(h)
  if h:find(":", 1, true) and not h:find("^%[") then return "[" .. h .. "]" end
  return h
end

local function baseUrl()
  local c = cfg()
  if c.port == 443 then return "https://" .. hostForUrl(c.host) end
  return "https://" .. hostForUrl(c.host) .. ":" .. c.port
end

local function setStatus(text)
  State.status = text
  U.setProp("Connection Status", text)
  U.log("Status: " .. text)
end

local function findDevice(id)
  if not id then return nil end
  if State.cameras[id] then return State.cameras[id], "camera" end
  if State.sensors[id] then return State.sensors[id], "sensor" end
  if State.sirens[id] then return State.sirens[id], "siren" end
  return nil
end

-- ---------------------------------------------------------------------------
-- Public (Integration) API
-- ---------------------------------------------------------------------------
-- cb(code, json, err, rawBody)
local function publicRequest(method, path, body, cb, opts)
  opts = opts or {}
  local c = cfg()
  local headers = { ["X-API-KEY"] = c.apiKey, ["Accept"] = opts.raw and "image/jpeg" or "application/json" }
  local bodyStr = nil
  if body ~= nil then
    bodyStr = type(body) == "string" and body or U.jsonEncode(body)
    headers["Content-Type"] = "application/json"
  end
  U.http({
    method = method,
    url = baseUrl() .. "/proxy/protect/integration" .. path,
    headers = headers,
    body = bodyStr,
    timeout = opts.timeout or 20,
    cb = function(code, data, hdrs, err)
      if opts.raw then cb(code, nil, err, data) return end
      local json = nil
      if data and data ~= "" then json = U.jsonDecode(data) end
      U.dbg(method .. " " .. path .. " -> " .. tostring(code) .. (err and (" " .. err) or ""))
      cb(code, json, err, data)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Private API (local user) - history and recordings only
-- ---------------------------------------------------------------------------
local Priv = { cookie = nil, csrf = nil, loggingIn = false, waiters = {}, failUntil = 0, lastError = nil }

function Priv.enabled()
  local c = cfg()
  return c.user ~= "" and c.pass ~= ""
end

function Priv.reset()
  Priv.cookie, Priv.csrf, Priv.failUntil, Priv.lastError = nil, nil, 0, nil
end

local function privStatus(text)
  U.setProp("Recordings Access", text)
end

function Priv.login(cb)
  if not Priv.enabled() then
    privStatus("Disabled - enter Local Username/Password for history & playback")
    cb(false, "Recordings need a local Protect user (Local Username / Local Password)")
    return
  end
  if os.time() < Priv.failUntil then
    cb(false, Priv.lastError or "login backing off")
    return
  end
  Priv.waiters[#Priv.waiters + 1] = cb
  if Priv.loggingIn then return end
  Priv.loggingIn = true
  local c = cfg()
  U.http({
    method = "POST",
    url = baseUrl() .. "/api/auth/login",
    headers = { ["Content-Type"] = "application/json", ["Accept"] = "application/json" },
    body = U.jsonEncode({ username = c.user, password = c.pass, rememberMe = true, token = "" }),
    timeout = 20,
    cb = function(code, body, hdrs, err)
      Priv.loggingIn = false
      local ok, msg = false, nil
      if code == 200 then
        local sc = U.header(hdrs, "set-cookie") or ""
        local name, val = sc:match("([%w_]*TOKEN)=([^;,%s]+)")
        Priv.csrf = U.header(hdrs, "x-csrf-token") or U.header(hdrs, "x-updated-csrf-token") or Priv.csrf
        if val then
          Priv.cookie = name .. "=" .. val
          ok = true
        else
          msg = "Login succeeded but no session cookie was returned"
        end
      elseif code == 401 or code == 403 then
        msg = "Local login rejected - use a local console user (not a UI.com SSO account with MFA)"
      elseif code == 429 then
        msg = "Too many login attempts - waiting before retrying"
      else
        msg = err or ("HTTP " .. tostring(code))
      end
      if ok then
        privStatus("OK - history and playback available")
        Priv.lastError = nil
      else
        Priv.failUntil = os.time() + ((code == 429) and 300 or 60)
        Priv.lastError = msg
        privStatus("Error: " .. tostring(msg))
        U.err("Private API login: " .. tostring(msg))
      end
      local waiters = Priv.waiters
      Priv.waiters = {}
      for _, f in ipairs(waiters) do pcall(f, ok, msg) end
    end,
  })
end

-- opts: { query = "a=b&c=d", raw = bool, timeout = n }
-- cb(code, jsonOrNil, err, rawBody)
function Priv.request(method, path, opts, cb)
  opts = opts or {}
  if not Priv.enabled() then
    cb(0, nil, "Recordings need a local Protect user (Local Username / Local Password)")
    return
  end
  local function go(allowRetry)
    local headers = { ["Cookie"] = Priv.cookie, ["Accept"] = opts.raw and "image/jpeg" or "application/json" }
    if Priv.csrf then headers["X-CSRF-Token"] = Priv.csrf end
    local url = baseUrl() .. "/proxy/protect/api" .. path
    if opts.query and opts.query ~= "" then url = url .. "?" .. opts.query end
    U.http({
      method = method,
      url = url,
      headers = headers,
      timeout = opts.timeout or 20,
      cb = function(code, data, hdrs, err)
        local newCsrf = U.header(hdrs, "x-updated-csrf-token")
        if newCsrf then Priv.csrf = newCsrf end
        if code == 401 and allowRetry then
          Priv.cookie = nil
          Priv.login(function(ok, msg)
            if ok then go(false) else cb(code, nil, msg) end
          end)
          return
        end
        if opts.raw then cb(code, nil, err, data) return end
        local json = nil
        if data and data ~= "" then json = U.jsonDecode(data) end
        cb(code, json, err, data)
      end,
    })
  end
  if Priv.cookie then
    go(true)
  else
    Priv.login(function(ok, msg)
      if ok then go(true) else cb(0, nil, msg) end
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Child messaging
-- ---------------------------------------------------------------------------
local Media -- forward

local function configPayload()
  return {
    online = State.online,
    status = State.status,
    version = State.version,
    privateApi = Priv.enabled(),
    privateApiOk = Priv.cookie ~= nil,
    mediaBase = Media and Media.base() or nil,
    host = cfg().host,
    rtspMode = U.prop("Stream Transport", "RTSP"),
  }
end

local function summarize(dev, kind)
  local s = {
    id = U.v(dev.id),
    name = U.v(dev.name) or "Unnamed",
    modelKey = U.v(dev.modelKey) or kind,
    type = U.v(dev.type),
    state = U.v(dev.state),
    kind = kind,
  }
  if kind == "sensor" then
    s.mountType = U.v(dev.mountType)
    s.featureFlags = U.v(dev.featureFlags)
  elseif kind == "camera" then
    s.featureFlags = U.v(dev.featureFlags)
    s.hasPackageCamera = U.v(dev.hasPackageCamera)
    local t = tostring(s.type or "") .. " " .. tostring(s.name or "")
    s.isDoorbell = (t:lower():find("doorbell", 1, true) ~= nil) or type(U.v(dev.lcdMessage)) == "table"
  end
  return s
end

local function deviceListFor(kind)
  local out = U.array({})
  local tbl = KIND_TABLE[kind] and KIND_TABLE[kind]() or {}
  for _, dev in pairs(tbl) do out[#out + 1] = summarize(dev, kind) end
  table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
  return out
end

local function sendConfig(childId)
  U.send(childId, U.MSG.CONFIG, { JSON = U.jsonEncode(configPayload()) })
end

local function sendDevices(childId, kind)
  if not State.online then return end
  U.send(childId, U.MSG.DEVICES, { JSON = U.jsonEncode(deviceListFor(kind)) })
end

local function sendState(childId, id, partial)
  local dev = findDevice(id)
  if not dev then return end
  U.send(childId, U.MSG.STATE, { JSON = U.jsonEncode(partial or dev), PARTIAL = partial and "1" or "0" })
end

local function subscribersOf(id)
  local out = {}
  for childId, info in pairs(State.children) do
    if info.device == id then out[#out + 1] = childId end
  end
  return out
end

local function updateChildCount()
  local n = 0
  for _ in pairs(State.children) do n = n + 1 end
  U.setProp("Children Connected", tostring(n))
end

local function broadcastConfig()
  for childId in pairs(State.children) do sendConfig(childId) end
end

local function broadcastDevices(kindFilter)
  for childId, info in pairs(State.children) do
    if not kindFilter or info.kind == kindFilter then sendDevices(childId, info.kind) end
  end
end

-- Ask every child driver in the project to say hello (master restart).
local function pingChildren()
  local me = U.myId()
  local seen = {}
  local function ping(id)
    id = tonumber(id)
    if id and not seen[id] and id ~= me then
      seen[id] = true
      U.send(id, U.MSG.PING, { MASTER = me })
    end
  end
  pcall(function()
    local bound = C4:GetBoundConsumerDevices(me, U.MASTER_BINDING)
    if type(bound) == "table" then for id in pairs(bound) do ping(id) end end
  end)
  for _, name in ipairs(CHILD_C4Z) do
    for _, id in ipairs(U.findDevicesByDriver(name)) do ping(id) end
  end
end

-- ---------------------------------------------------------------------------
-- RTSP(S) streams
-- ---------------------------------------------------------------------------
local function convertStreams(raw)
  local host = hostForUrl(cfg().host)
  local out = { rtsps = {}, rtsp = {} }
  if type(raw) ~= "table" then return out end
  for quality, url in pairs(raw) do
    url = U.v(url)
    if type(url) == "string" and url:match("^rtsps?://") then
      local path = url:match("^rtsps?://[^/]+(/.*)$") or "/"
      local token = path:gsub("%?enableSrtp$", "")
      out.rtsps[quality] = "rtsps://" .. host .. ":7441" .. token
      out.rtsp[quality] = "rtsp://" .. host .. ":7447" .. token
    end
  end
  return out
end

local function hasStreams(s)
  return s and next(s.rtsp or {}) ~= nil
end

local function ensureStreams(camId, cb, force)
  if not force and hasStreams(State.streams[camId]) then cb(State.streams[camId]) return end
  if State.streamWaiters[camId] then
    table.insert(State.streamWaiters[camId], cb)
    return
  end
  State.streamWaiters[camId] = { cb }
  local function finish(raw)
    local s = convertStreams(raw)
    if hasStreams(s) then State.streams[camId] = s end
    local waiters = State.streamWaiters[camId] or {}
    State.streamWaiters[camId] = nil
    for _, f in ipairs(waiters) do pcall(f, State.streams[camId] or s) end
  end
  local function create(qualities, nextTry)
    publicRequest("POST", "/v1/cameras/" .. camId .. "/rtsps-stream", { qualities = U.array(qualities) }, function(code, json)
      if code >= 200 and code < 300 and type(json) == "table" then
        finish(json)
      elseif nextTry then
        nextTry()
      else
        U.err("Could not create RTSPS streams for camera " .. camId .. " (HTTP " .. tostring(code) .. ")")
        finish(nil)
      end
    end)
  end
  publicRequest("GET", "/v1/cameras/" .. camId .. "/rtsps-stream", nil, function(code, json)
    local s = convertStreams(json)
    if not force and code == 200 and s.rtsp.high then
      finish(json)
      return
    end
    create({ "high", "medium", "low" }, function()
      create({ "high", "medium" }, function() create({ "high" }, nil) end)
    end)
  end)
end

local function sendStreams(childId, camId)
  ensureStreams(camId, function(s)
    U.send(childId, U.MSG.STREAMS, { JSON = U.jsonEncode(s or {}) })
  end)
end

-- ---------------------------------------------------------------------------
-- WebSocket client (raw TLS socket via dynamic network binding)
-- ---------------------------------------------------------------------------
local WS = {}
WS.__index = WS
local WSByBinding = {}

function WS.new(name, binding, path, onMessage, onUp)
  local self = setmetatable({
    name = name, binding = binding, path = path, onMessage = onMessage, onUp = onUp,
    buf = "", upgraded = false, wanted = false, state = "idle", backoff = 5000, lastRx = 0,
  }, WS)
  WSByBinding[binding] = self
  return self
end

local function randomBytes(n)
  local t = {}
  for i = 1, n do t[i] = string.char(math.random(0, 255)) end
  return table.concat(t)
end

function WS:start()
  local c = cfg()
  self.host, self.port = c.host, c.port
  self.wanted = true
  self.state = "connecting"
  self.buf = ""
  self.frag = nil
  self.upgraded = false
  self.key = C4:Base64Encode(randomBytes(16))
  U.stop("ws_ping_" .. self.binding)
  pcall(C4.NetDisconnect, C4, self.binding, self.port)
  C4:CreateNetworkConnection(self.binding, self.host, "SSL")
  C4:NetPortOptions(self.binding, self.port, "SSL", {
    AUTO_CONNECT = false, MONITOR_CONNECTION = false, KEEP_CONNECTION = false, KEEP_ALIVE = true,
    DELIMITER = "", VERIFY_MODE = "none", SUPPRESS_CONNECTION_EVENTS = true,
  })
  C4:NetConnect(self.binding, self.port)
  U.after("ws_connect_" .. self.binding, 15000, function()
    if self.wanted and not self.upgraded then self:fail("connect/handshake timeout") end
  end)
end

function WS:stop()
  self.wanted = false
  self.upgraded = false
  self.state = "idle"
  U.stop("ws_ping_" .. self.binding)
  U.stop("ws_connect_" .. self.binding)
  U.stop("ws_retry_" .. self.binding)
  if self.port then pcall(C4.NetDisconnect, C4, self.binding, self.port) end
end

function WS:fail(reason)
  if self.state == "retrying" or not self.wanted then return end
  local wasUp = self.upgraded
  U.log("WebSocket " .. self.name .. ": " .. tostring(reason))
  self.upgraded = false
  self.state = "retrying"
  U.stop("ws_ping_" .. self.binding)
  U.stop("ws_connect_" .. self.binding)
  pcall(C4.NetDisconnect, C4, self.binding, self.port)
  if wasUp and self.onUp then self.onUp(false) end
  local delay = self.backoff
  self.backoff = math.min(self.backoff * 2, 60000)
  U.after("ws_retry_" .. self.binding, delay, function()
    if self.wanted then self:start() end
  end)
end

function WS:onStatus(status)
  if status == "ONLINE" then
    if self.state ~= "connecting" then return end
    self.state = "handshake"
    local req = table.concat({
      "GET " .. self.path .. " HTTP/1.1",
      "Host: " .. hostForUrl(self.host) .. (self.port ~= 443 and (":" .. self.port) or ""),
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Key: " .. self.key,
      "Sec-WebSocket-Version: 13",
      "X-API-KEY: " .. cfg().apiKey,
      "User-Agent: Control4-UniFiProtect/" .. U.VERSION,
      "", "",
    }, "\r\n")
    C4:SendToNetwork(self.binding, self.port, req)
  else
    if self.upgraded then self:fail("connection closed") end
    -- while connecting, the connect timer handles failures
  end
end

function WS:sendFrame(opcode, payload)
  payload = payload or ""
  local len = #payload
  local hdr
  if len < 126 then
    hdr = string.char(128 + opcode, 128 + len)
  elseif len < 65536 then
    hdr = string.char(128 + opcode, 128 + 126, math.floor(len / 256), len % 256)
  else
    local b = {}
    local n = len
    for i = 8, 1, -1 do b[i] = n % 256; n = math.floor(n / 256) end
    hdr = string.char(128 + opcode, 128 + 127, b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8])
  end
  local m = { math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255) }
  local out = {}
  for i = 1, len do
    out[i] = string.char(U.bit.bxor(payload:byte(i), m[(i - 1) % 4 + 1]))
  end
  C4:SendToNetwork(self.binding, self.port, hdr .. string.char(m[1], m[2], m[3], m[4]) .. table.concat(out))
end

function WS:onData(data)
  self.buf = self.buf .. data
  self.lastRx = os.time()
  if not self.upgraded then
    local hEnd = self.buf:find("\r\n\r\n", 1, true)
    if not hEnd then
      if #self.buf > 16384 then self:fail("bad handshake response") end
      return
    end
    local head = self.buf:sub(1, hEnd - 1)
    self.buf = self.buf:sub(hEnd + 4)
    local code = tonumber(head:match("^HTTP/%d%.%d (%d+)"))
    if code ~= 101 then
      if code == 401 or code == 403 then
        self.backoff = 60000
        setStatus("API key rejected by console (HTTP " .. code .. ")")
      end
      self:fail("handshake failed (HTTP " .. tostring(code) .. ")")
      return
    end
    self.upgraded = true
    self.state = "open"
    self.backoff = 5000
    U.stop("ws_connect_" .. self.binding)
    U.log("WebSocket " .. self.name .. " connected")
    U.every("ws_ping_" .. self.binding, 60000, function()
      if not self.upgraded then return end
      if os.time() - self.lastRx > 200 then
        self:fail("no traffic for 200s")
        return
      end
      self:sendFrame(0x9, "c4")
    end)
    if self.onUp then self.onUp(true) end
  end
  self:parse()
end

function WS:parse()
  local buf = self.buf
  local pos, n = 1, #buf
  while self.upgraded do
    local avail = n - pos + 1
    if avail < 2 then break end
    local b1, b2 = buf:byte(pos, pos + 1)
    local fin = b1 >= 128
    local opcode = b1 % 16
    local masked = b2 >= 128
    local len = b2 % 128
    local hdr = 2
    if len == 126 then
      if avail < 4 then break end
      local x1, x2 = buf:byte(pos + 2, pos + 3)
      len = x1 * 256 + x2
      hdr = 4
    elseif len == 127 then
      if avail < 10 then break end
      len = 0
      for i = pos + 2, pos + 9 do len = len * 256 + buf:byte(i) end
      hdr = 10
    end
    local mask
    if masked then
      if avail < hdr + 4 then break end
      mask = { buf:byte(pos + hdr, pos + hdr + 3) }
      hdr = hdr + 4
    end
    if avail < hdr + len then break end
    local payload = buf:sub(pos + hdr, pos + hdr + len - 1)
    if mask then
      local out = {}
      for i = 1, #payload do out[i] = string.char(U.bit.bxor(payload:byte(i), mask[(i - 1) % 4 + 1])) end
      payload = table.concat(out)
    end
    pos = pos + hdr + len
    self:onFrame(fin, opcode, payload)
  end
  self.buf = buf:sub(pos)
end

function WS:onFrame(fin, opcode, payload)
  if opcode == 0x8 then
    self:fail("closed by console")
  elseif opcode == 0x9 then
    self:sendFrame(0xA, payload)
  elseif opcode == 0xA then
    -- pong; lastRx already updated
  elseif opcode == 0x1 or opcode == 0x2 then
    if fin then
      self:deliver(payload)
    else
      self.frag = { payload }
    end
  elseif opcode == 0x0 and self.frag then
    self.frag[#self.frag + 1] = payload
    if fin then
      local msg = table.concat(self.frag)
      self.frag = nil
      self:deliver(msg)
    end
  end
end

function WS:deliver(msg)
  local ok, e = pcall(self.onMessage, msg)
  if not ok then U.err("WebSocket " .. self.name .. " handler: " .. tostring(e)) end
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
  local ws = WSByBinding[idBinding]
  if ws then ws:onStatus(strStatus) end
end

function ReceivedFromNetwork(idBinding, nPort, strData)
  local ws = WSByBinding[idBinding]
  if ws then ws:onData(strData) end
end

-- ---------------------------------------------------------------------------
-- Realtime message handling
-- ---------------------------------------------------------------------------
local function rememberEvent(eventId, deviceId)
  if not eventId or not deviceId then return end
  if not State.eventDevice[eventId] then
    State.eventOrder[#State.eventOrder + 1] = eventId
    if #State.eventOrder > 500 then
      local old = table.remove(State.eventOrder, 1)
      State.eventDevice[old] = nil
    end
  end
  State.eventDevice[eventId] = deviceId
end

local function onEventsMessage(msg)
  local data = U.jsonDecode(msg)
  if type(data) ~= "table" then return end
  local action = U.v(data.type)
  local item = U.v(data.item)
  if type(item) ~= "table" then return end
  if U.v(item.modelKey) ~= "event" then return end
  local evId = U.v(item.id)
  local devId = U.v(item.device) or State.eventDevice[evId]
  if not devId then
    U.dbg("Event without device: " .. msg)
    return
  end
  rememberEvent(evId, devId)
  item.device = devId
  U.dbg("Event " .. tostring(action) .. " " .. tostring(U.v(item.type)) .. " on " .. tostring(devId))
  local payload = U.jsonEncode(item)
  for _, childId in ipairs(subscribersOf(devId)) do
    U.send(childId, U.MSG.EVENT, { JSON = payload, ACTION = action or "add" })
  end
  local dev = findDevice(devId)
  if action == "add" and U.v(item.type) == "ring" and dev then
    U.setVar("LAST_RING_CAMERA", U.v(dev.name) or devId)
    U.fire("Any Doorbell Ring")
  end
end

local devicesRefreshPending = false
local function scheduleDeviceListRefresh()
  if devicesRefreshPending then return end
  devicesRefreshPending = true
  U.after("device_list_refresh", 2000, function()
    devicesRefreshPending = false
    broadcastDevices()
  end)
end

local function updateCounts()
  local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
  U.setProp("Cameras", tostring(count(State.cameras)))
  U.setProp("Sensors", tostring(count(State.sensors)))
  U.setProp("Sirens", tostring(count(State.sirens)))
end

local function onDevicesMessage(msg)
  local data = U.jsonDecode(msg)
  if type(data) ~= "table" then return end
  local action = U.v(data.type)
  local item = U.v(data.item)
  if type(item) ~= "table" then return end
  local kind = MODEL_KIND[U.v(item.modelKey) or ""]
  local id = U.v(item.id)
  if not kind or not id then return end
  local tbl = KIND_TABLE[kind]()
  if action == "remove" then
    tbl[id] = nil
    scheduleDeviceListRefresh()
    updateCounts()
    return
  end
  local existing = tbl[id]
  if not existing then
    tbl[id] = item
    scheduleDeviceListRefresh()
    updateCounts()
  else
    U.merge(existing, item)
    if item.name ~= nil or item.state ~= nil then scheduleDeviceListRefresh() end
  end
  local payload = U.jsonEncode(item)
  for _, childId in ipairs(subscribersOf(id)) do
    U.send(childId, U.MSG.STATE, { JSON = payload, PARTIAL = existing and "1" or "0" })
  end
end

local wsEvents = WS.new("events", WS_EVENTS_BINDING, "/proxy/protect/integration/v1/subscribe/events", onEventsMessage)
local wsDevices

local function onWsUpChanged()
  local up = wsEvents.upgraded and wsDevices and wsDevices.upgraded
  U.setProp("Realtime Events", up and "Connected" or "Reconnecting...")
end
wsEvents.onUp = function(up) onWsUpChanged() end
wsDevices = WS.new("devices", WS_DEVICES_BINDING, "/proxy/protect/integration/v1/subscribe/devices", onDevicesMessage, function(up)
  onWsUpChanged()
  -- After a devices-socket reconnect, resync REST state (deltas may be lost).
  if up and State.online then U.after("resync_after_ws", 3000, function() Resync() end) end
end)

-- ---------------------------------------------------------------------------
-- Loading / connecting
-- ---------------------------------------------------------------------------
local function loadList(path, cb)
  publicRequest("GET", path, nil, function(code, json, err)
    if code == 200 and type(json) == "table" then
      cb(true, json)
    else
      cb(false, nil, code, err)
    end
  end)
end

-- Reload all device lists; cb(ok, errText)
local function loadDevices(cb)
  local pending = 3
  local failed = nil
  local newCams, newSensors, newSirens = nil, nil, nil
  local function done()
    pending = pending - 1
    if pending > 0 then return end
    if failed then cb(false, failed) return end
    local function index(list, old)
      local t = {}
      for _, d in ipairs(list or {}) do
        local id = U.v(d.id)
        if id then t[id] = d end
      end
      return t
    end
    State.cameras = index(newCams)
    State.sensors = index(newSensors)
    State.sirens = index(newSirens or {})
    updateCounts()
    cb(true)
  end
  loadList("/v1/cameras", function(ok, json, code, err)
    if ok then newCams = json else failed = "cameras: HTTP " .. tostring(code) .. " " .. tostring(err or "") end
    done()
  end)
  loadList("/v1/sensors", function(ok, json, code, err)
    if ok then newSensors = json else newSensors = {} U.dbg("sensors list unavailable: " .. tostring(code)) end
    done()
  end)
  loadList("/v1/sirens", function(ok, json, code)
    -- Older Protect versions have no sirens endpoint.
    newSirens = ok and json or {}
    done()
  end)
end

local function pushAllStates()
  for childId, info in pairs(State.children) do
    if info.device then sendState(childId, info.device) end
  end
end

function Resync()
  if not State.online then return end
  loadDevices(function(ok, err)
    if not ok then
      U.err("Resync failed: " .. tostring(err))
      return
    end
    broadcastDevices()
    pushAllStates()
  end)
end

local function goOffline(reason)
  local was = State.online
  State.online = false
  setStatus(reason)
  U.setVar("CONNECTED", false)
  wsEvents:stop()
  wsDevices:stop()
  U.setProp("Realtime Events", "Stopped")
  U.stop("resync")
  broadcastConfig()
  if was then U.fire("Console Offline") end
end

function Connect()
  State.connectSeq = State.connectSeq + 1
  local seq = State.connectSeq
  U.stop("reconnect")
  local c = cfg()
  if c.host == "" or c.apiKey == "" then
    goOffline("Enter Console Address and API Key")
    return
  end
  setStatus("Connecting to " .. c.host .. "...")
  publicRequest("GET", "/v1/meta/info", nil, function(code, json, err)
    if seq ~= State.connectSeq then return end
    if code == 401 or code == 403 then
      goOffline("API key rejected (HTTP " .. code .. ") - create one under UniFi OS Settings > Control Plane > Integrations")
      U.after("reconnect", 120000, Connect)
      return
    end
    if code ~= 200 then
      local why = err or ("HTTP " .. tostring(code))
      if code == 404 then why = "Integration API not found - update UniFi Protect (6.0+ required)" end
      goOffline("Cannot reach console: " .. why)
      U.after("reconnect", 30000, Connect)
      return
    end
    State.version = type(json) == "table" and U.v(json.applicationVersion) or nil
    U.setProp("Protect Version", State.version or "unknown")
    loadDevices(function(ok, lerr)
      if seq ~= State.connectSeq then return end
      if not ok then
        goOffline("Failed to load devices: " .. tostring(lerr))
        U.after("reconnect", 30000, Connect)
        return
      end
      local wasOnline = State.online
      State.online = true
      setStatus("Connected - Protect " .. tostring(State.version or ""))
      U.setVar("CONNECTED", true)
      if not wasOnline then U.fire("Console Online") end
      wsEvents:start()
      wsDevices:start()
      broadcastConfig()
      broadcastDevices()
      pushAllStates()
      for childId, info in pairs(State.children) do
        if info.kind == "camera" and info.device then sendStreams(childId, info.device) end
      end
      U.every("resync", RESYNC_INTERVAL_MS, Resync)
      if Priv.enabled() then
        Priv.login(function() broadcastConfig() end)
      else
        privStatus("Disabled - enter Local Username/Password for history & playback")
      end
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Child requests
-- ---------------------------------------------------------------------------
local function reply(childId, req, op, ok, data, errText)
  U.send(childId, U.MSG.RESULT, {
    REQ = req or "0", OP = op or "", OK = ok and "1" or "0",
    JSON = data ~= nil and U.jsonEncode(data) or "", ERROR = errText or "",
  })
end

local HISTORY_TYPES = {
  all = { "ring", "motion", "smartDetectZone", "smartDetectLine", "smartAudioDetect" },
  smart = { "ring", "smartDetectZone", "smartDetectLine", "smartAudioDetect" },
  ring = { "ring" },
}

local function trimEvent(ev)
  return {
    id = U.v(ev.id),
    type = U.v(ev.type),
    start = U.v(ev.start),
    ["end"] = U.v(ev["end"]),
    score = U.v(ev.score),
    smartDetectTypes = U.v(ev.smartDetectTypes),
    camera = U.v(ev.camera),
  }
end

local Ops = {}

function Ops.events(childId, req, devId, args)
  local hours = tonumber(args.hours) or 24
  local limit = math.max(1, math.min(tonumber(args.limit) or 20, 50))
  local now = U.nowMs()
  local q = {
    "start=" .. string.format("%d", now - hours * 3600000),
    "end=" .. string.format("%d", now + 10000),
    "limit=" .. tostring(math.min(limit * 4, 100)),
    "orderDirection=DESC",
    "cameras=" .. U.urlEncode(devId),
  }
  for _, t in ipairs(HISTORY_TYPES[args.filter or "all"] or HISTORY_TYPES.all) do q[#q + 1] = "types=" .. t end
  Priv.request("GET", "/events", { query = table.concat(q, "&") }, function(code, json, err)
    if code ~= 200 or type(json) ~= "table" then
      reply(childId, req, "events", false, nil, err or ("HTTP " .. tostring(code)))
      return
    end
    local out = U.array({})
    for _, ev in ipairs(json) do
      local cam = U.v(ev.camera)
      if (cam == nil or cam == devId) and #out < limit then out[#out + 1] = trimEvent(ev) end
    end
    reply(childId, req, "events", true, out)
  end)
end

function Ops.lcd(childId, req, devId, args)
  local body = { lcdMessage = { type = args.type or "CUSTOM_MESSAGE" } }
  if args.text then body.lcdMessage.text = args.text end
  if args.forever then
    body.lcdMessage.resetAt = U.NULL
  elseif tonumber(args.resetAt) then
    body.lcdMessage.resetAt = tonumber(args.resetAt)
  end
  if args.clear then body.lcdMessage = { type = "CUSTOM_MESSAGE", text = " ", resetAt = U.nowMs() - 1000 } end
  publicRequest("PATCH", "/v1/cameras/" .. devId, body, function(code, json, err)
    reply(childId, req, "lcd", code >= 200 and code < 300, nil, err or ("HTTP " .. tostring(code)))
  end)
end

function Ops.ptz(childId, req, devId, args)
  local slot = tonumber(args.slot) or 0
  publicRequest("POST", "/v1/cameras/" .. devId .. "/ptz/goto/" .. slot, {}, function(code, json, err)
    reply(childId, req, "ptz", code >= 200 and code < 300, nil, err or ("HTTP " .. tostring(code)))
  end)
end

function Ops.camera_patch(childId, req, devId, args)
  publicRequest("PATCH", "/v1/cameras/" .. devId, args.body or {}, function(code, json, err)
    reply(childId, req, "camera_patch", code >= 200 and code < 300, nil, err or ("HTTP " .. tostring(code)))
  end)
end

function Ops.streams(childId, req, devId, args)
  ensureStreams(devId, function(s)
    U.send(childId, U.MSG.STREAMS, { JSON = U.jsonEncode(s or {}) })
    reply(childId, req, "streams", hasStreams(s), nil, hasStreams(s) and "" or "no streams")
  end, args.force and true or false)
end

function Ops.siren_play(childId, req, devId, args)
  local d = tonumber(args.duration) or 5
  local allowed = { [5] = true, [10] = true, [20] = true, [30] = true }
  if not allowed[d] then d = 5 end
  publicRequest("POST", "/v1/sirens/" .. devId .. "/play", { duration = d }, function(code, json, err)
    reply(childId, req, "siren_play", code >= 200 and code < 300, nil, err or ("HTTP " .. tostring(code)))
  end)
end

function Ops.siren_stop(childId, req, devId)
  publicRequest("POST", "/v1/sirens/" .. devId .. "/stop", {}, function(code, json, err)
    reply(childId, req, "siren_stop", code >= 200 and code < 300, nil, err or ("HTTP " .. tostring(code)))
  end)
end

function Ops.siren_test(childId, req, devId, args)
  local body = {}
  if tonumber(args.volume) then body.volume = tonumber(args.volume) end
  publicRequest("POST", "/v1/sirens/" .. devId .. "/test-sound", body, function(code, json, err)
    reply(childId, req, "siren_test", code >= 200 and code < 300, nil, err or ("HTTP " .. tostring(code)))
  end)
end

function Ops.siren_volume(childId, req, devId, args)
  publicRequest("PATCH", "/v1/sirens/" .. devId, { volume = tonumber(args.volume) or 100 }, function(code, json, err)
    reply(childId, req, "siren_volume", code >= 200 and code < 300, nil, err or ("HTTP " .. tostring(code)))
  end)
end

local function handleChildMessage(cmd, p)
  local childId = tonumber(p.CHILD)
  if not childId then return end
  if cmd == U.MSG.HELLO then
    local info = State.children[childId] or {}
    info.kind = p.KIND or info.kind or "sensor"
    State.children[childId] = info
    updateChildCount()
    sendConfig(childId)
    sendDevices(childId, info.kind)
    if info.device then sendState(childId, info.device) end
  elseif cmd == U.MSG.SUBSCRIBE then
    local info = State.children[childId] or { kind = p.KIND or "sensor" }
    info.kind = p.KIND or info.kind
    info.device = p.DEVICE
    State.children[childId] = info
    updateChildCount()
    if State.online then
      sendState(childId, info.device)
      if info.kind == "camera" then sendStreams(childId, info.device) end
    else
      sendConfig(childId)
    end
  elseif cmd == U.MSG.UNSUBSCRIBE then
    if State.children[childId] then State.children[childId].device = nil end
  elseif cmd == U.MSG.CALL then
    local op = p.OP or ""
    local devId = p.DEVICE or (State.children[childId] and State.children[childId].device)
    local args = U.jsonDecode(p.ARGS or "{}") or {}
    local f = Ops[op]
    if not f then
      reply(childId, p.REQ, op, false, nil, "unknown operation")
      return
    end
    if not State.online then
      reply(childId, p.REQ, op, false, nil, "master not connected")
      return
    end
    if not devId or devId == "" then
      reply(childId, p.REQ, op, false, nil, "no device selected")
      return
    end
    f(childId, p.REQ, devId, args)
  end
end

-- ---------------------------------------------------------------------------
-- Media server (snapshots / MJPEG / recorded playback)
-- ---------------------------------------------------------------------------
Media = { server = nil, clients = {}, count = 0, snap = {}, token = nil, ip = nil, port = nil, listening = false }

local function tick()
  if C4 and C4.GetTime then
    local ok, t = pcall(C4.GetTime, C4)
    if ok and tonumber(t) then return tonumber(t) end
  end
  return os.time() * 1000
end

function Media.base()
  if not Media.listening then return nil end
  return "http://" .. hostForUrl(Media.ip or "127.0.0.1") .. ":" .. tostring(Media.port) .. "/up/" .. Media.token
end

local function controllerAddress()
  local override = U.trim(U.prop("Media Server Address", ""))
  if override ~= "" and override:lower() ~= "auto" then return override end
  local ip
  pcall(function() ip = C4:GetMyNetworkAddress() end)
  if not ip or ip == "" then pcall(function() ip = C4:GetControllerNetworkAddress() end) end
  return ip or "127.0.0.1"
end

function Media.stop()
  for _, ctx in pairs(Media.clients) do Media.drop(ctx) end
  if Media.server then pcall(function() Media.server:Close() end) end
  Media.server = nil
  Media.listening = false
end

function Media.start()
  Media.stop()
  Media.token = U.persistGet("media_token")
  if not Media.token or #Media.token < 12 then
    Media.token = U.randomToken(20)
    U.persistSet("media_token", Media.token)
  end
  Media.port = tonumber(U.prop("Media Server Port", "8641")) or 8641
  Media.ip = controllerAddress()
  local ok, e = pcall(function()
    Media.server = C4:CreateTCPServer()
      :OnListen(function(srv, endpoint)
        Media.listening = true
        U.setProp("Media Server", "Listening on " .. tostring(Media.ip) .. ":" .. tostring(Media.port))
        U.log("Media server listening on port " .. tostring(Media.port))
        broadcastConfig()
      end)
      :OnError(function(srv, code, msg)
        Media.listening = false
        U.setProp("Media Server", "Error: " .. tostring(msg) .. " (port " .. tostring(Media.port) .. ")")
        U.err("Media server: " .. tostring(msg))
        broadcastConfig()
      end)
      :OnAccept(function(srv, client) Media.accept(client) end)
      :Listen("*", Media.port)
  end)
  if not ok then
    U.setProp("Media Server", "Error: " .. tostring(e))
    U.err("Media server start: " .. tostring(e))
  end
end

function Media.drop(ctx)
  if not ctx or ctx.dropped then return end
  ctx.dropped = true
  ctx.alive = false
  ctx.timer = U.cancel(ctx.timer)
  ctx.watchdog = U.cancel(ctx.watchdog)
  if Media.clients[ctx.client] then
    Media.clients[ctx.client] = nil
    Media.count = Media.count - 1
  end
  pcall(function() ctx.client:Close() end)
end

function Media.write(ctx, data, onWritten)
  if not ctx.alive then return end
  ctx.onWritten = onWritten
  ctx.watchdog = U.cancel(ctx.watchdog)
  ctx.watchdog = U.setTimer(20000, function() Media.drop(ctx) end)
  local ok = pcall(function() ctx.client:Write(data) end)
  if not ok then Media.drop(ctx) end
end

function Media.accept(client)
  if Media.count >= MAX_MEDIA_CLIENTS then
    pcall(function() client:Write("HTTP/1.0 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"):Close(true) end)
    return
  end
  local ctx = { client = client, alive = true }
  Media.clients[client] = ctx
  Media.count = Media.count + 1
  client
    :OnRead(function(cli, data) Media.onRequest(ctx, data) end)
    :OnWrite(function(cli)
      ctx.watchdog = U.cancel(ctx.watchdog)
      if ctx.closeAfterWrite then
        Media.drop(ctx)
      elseif ctx.onWritten then
        local f = ctx.onWritten
        ctx.onWritten = nil
        f()
      end
    end)
    :OnDisconnect(function() Media.drop(ctx) end)
    :OnError(function() Media.drop(ctx) end)
    :ReadUntil("\r\n\r\n")
  ctx.watchdog = U.setTimer(15000, function() if not ctx.routed then Media.drop(ctx) end end)
end

local function httpHead(code, text, ctype, length, extra)
  local h = { "HTTP/1.0 " .. code .. " " .. text, "Server: Control4-UniFiProtect", "Cache-Control: no-cache, no-store",
    "Pragma: no-cache", "Connection: close", "Access-Control-Allow-Origin: *" }
  if ctype then h[#h + 1] = "Content-Type: " .. ctype end
  if length then h[#h + 1] = "Content-Length: " .. length end
  if extra then h[#h + 1] = extra end
  return table.concat(h, "\r\n") .. "\r\n\r\n"
end

function Media.sendBody(ctx, code, text, ctype, body)
  ctx.closeAfterWrite = true
  Media.write(ctx, httpHead(code, text, ctype, #body) .. body)
end

function Media.sendError(ctx, code, text)
  Media.sendBody(ctx, code, text, "text/plain", text .. "\n")
end

local function isJpeg(data)
  return type(data) == "string" and #data > 100 and data:sub(1, 2) == "\255\216"
end

-- Live snapshot with a short shared cache (several Navigators, one fetch).
function Media.liveSnapshot(camId, height, cb)
  local key = camId .. ":" .. tostring(height or "")
  local c = Media.snap[key]
  if not c then c = {} Media.snap[key] = c end
  if c.data and tick() - c.at < 700 then cb(c.data) return end
  if c.waiters then c.waiters[#c.waiters + 1] = cb return end
  c.waiters = { cb }
  local function deliver(data)
    if data then c.data, c.at = data, tick() end
    local w = c.waiters or {}
    c.waiters = nil
    for _, f in ipairs(w) do pcall(f, data or c.data) end
  end
  local hq = U.prop("Snapshot Quality", "Standard") == "High"
  publicRequest("GET", "/v1/cameras/" .. camId .. "/snapshot?highQuality=" .. (hq and "true" or "false"), nil,
    function(code, _, err, body)
      if code == 200 and isJpeg(body) then deliver(body) return end
      if Priv.enabled() then
        local q = "ts=" .. string.format("%d", U.nowMs()) .. "&force=true"
        if height then q = q .. "&h=" .. height end
        Priv.request("GET", "/cameras/" .. camId .. "/snapshot", { query = q, raw = true }, function(c2, _, _, b2)
          deliver(c2 == 200 and isJpeg(b2) and b2 or nil)
        end)
      else
        deliver(nil)
      end
    end, { raw = true, timeout = 10 })
end

function Media.recordedFrame(camId, ts, height, cb)
  local q = "ts=" .. string.format("%d", ts)
  if height then q = q .. "&h=" .. height end
  Priv.request("GET", "/cameras/" .. camId .. "/recording-snapshot", { query = q, raw = true, timeout = 12 },
    function(code, _, err, body)
      if code == 200 and isJpeg(body) then cb(body) else cb(nil, err or ("HTTP " .. tostring(code))) end
    end)
end

function Media.eventThumb(eventId, height, cb)
  local q = height and ("h=" .. height) or ""
  Priv.request("GET", "/events/" .. eventId .. "/thumbnail", { query = q, raw = true }, function(code, _, err, body)
    if code == 200 and isJpeg(body) then cb(body) else cb(nil, err or ("HTTP " .. tostring(code))) end
  end)
end

local function mjpegPart(jpeg)
  return "--upframe\r\nContent-Type: image/jpeg\r\nContent-Length: " .. #jpeg .. "\r\n\r\n" .. jpeg .. "\r\n"
end

-- Generic MJPEG pump: frameFn(cb) delivers a JPEG (or nil to skip).
function Media.pump(ctx, intervalMs, frameFn, maxMs)
  local started = tick()
  Media.write(ctx, httpHead(200, "OK", "multipart/x-mixed-replace; boundary=upframe"), function()
    local function step()
      if not ctx.alive then return end
      if maxMs and tick() - started > maxMs then Media.drop(ctx) return end
      local t0 = tick()
      frameFn(function(jpeg)
        if not ctx.alive then return end
        local function again()
          local wait = intervalMs - (tick() - t0)
          ctx.timer = U.setTimer(math.max(40, wait), step)
        end
        if jpeg then Media.write(ctx, mjpegPart(jpeg), again) else ctx.timer = U.setTimer(math.max(250, intervalMs), step) end
      end)
    end
    step()
  end)
end

function Media.onRequest(ctx, data)
  if ctx.routed then return end
  ctx.routed = true
  ctx.watchdog = U.cancel(ctx.watchdog)
  local method, target = data:match("^(%u+) (%S+) HTTP/%d%.%d")
  if method ~= "GET" and method ~= "HEAD" then Media.sendError(ctx, 405, "Method Not Allowed") return end
  local path, query = target:match("^([^?]*)%??(.*)$")
  local q = U.parseQuery(query)
  local token, rest = path:match("^/up/([^/]+)(/.*)$")
  if not token or token ~= Media.token then Media.sendError(ctx, 404, "Not Found") return end
  if not State.online then Media.sendError(ctx, 503, "UniFi Protect offline") return end
  local height = tonumber(q.h)

  local cam = rest:match("^/snap/([%w%-_]+)%.jpg$")
  if cam then
    Media.liveSnapshot(cam, height, function(jpeg)
      if jpeg then Media.sendBody(ctx, 200, "OK", "image/jpeg", jpeg) else Media.sendError(ctx, 502, "Snapshot unavailable") end
    end)
    return
  end

  cam = rest:match("^/live/([%w%-_]+)%.mjpg$")
  if cam then
    local fps = math.max(0.2, math.min(tonumber(q.fps) or tonumber(U.prop("Live MJPEG FPS", "2")) or 2, 5))
    Media.pump(ctx, math.floor(1000 / fps), function(cb) Media.liveSnapshot(cam, height, cb) end, 60 * 60 * 1000)
    return
  end

  local pcam, pstart = rest:match("^/play/([%w%-_]+)/(%d+)%.mjpg$")
  if pcam then
    if not Priv.enabled() then Media.sendError(ctx, 503, "Playback needs Local Username/Password on the master driver") return end
    local fps = math.max(0.5, math.min(tonumber(q.fps) or tonumber(U.prop("Playback FPS", "2")) or 2, 5))
    local speed = math.max(0.25, math.min(tonumber(q.speed) or 1, 16))
    local ts = tonumber(pstart)
    local interval = math.floor(1000 / fps)
    local misses = 0
    Media.pump(ctx, interval, function(cb)
      if ts > U.nowMs() - 3000 then
        -- caught up with "now": continue as a live stream
        Media.liveSnapshot(pcam, height, cb)
        return
      end
      Media.recordedFrame(pcam, ts, height, function(jpeg)
        if jpeg then
          misses = 0
          ts = ts + interval * speed
        else
          misses = misses + 1
          ts = ts + math.max(2000, interval * speed)   -- skip gaps without recordings
        end
        cb(jpeg)
      end)
    end, 2 * 60 * 60 * 1000)
    return
  end

  local fcam, fts = rest:match("^/frame/([%w%-_]+)/(%d+)%.jpg$")
  if fcam then
    Media.recordedFrame(fcam, tonumber(fts), height, function(jpeg, err)
      if jpeg then Media.sendBody(ctx, 200, "OK", "image/jpeg", jpeg) else Media.sendError(ctx, 502, "Frame unavailable: " .. tostring(err)) end
    end)
    return
  end

  local ev = rest:match("^/thumb/([%w%-_]+)%.jpg$")
  if ev then
    Media.eventThumb(ev, height, function(jpeg, err)
      if jpeg then Media.sendBody(ctx, 200, "OK", "image/jpeg", jpeg) else Media.sendError(ctx, 502, "Thumbnail unavailable: " .. tostring(err)) end
    end)
    return
  end

  if rest == "/status" then
    Media.sendBody(ctx, 200, "OK", "text/plain", "UniFi Protect for Control4 " .. U.VERSION .. "\nstatus: " .. State.status .. "\nclients: " .. Media.count .. "\n")
    return
  end
  Media.sendError(ctx, 404, "Not Found")
end

-- ---------------------------------------------------------------------------
-- Driver lifecycle
-- ---------------------------------------------------------------------------
local reconnectPending = false
local function scheduleConnect()
  if reconnectPending then return end
  reconnectPending = true
  U.after("cfg_reconnect", 1500, function()
    reconnectPending = false
    wsEvents:stop()
    wsDevices:stop()
    State.streams = {}
    Priv.reset()
    Connect()
  end)
end

function OnDriverInit()
  U.debugEnabled = U.prop("Debug Logging", "Off") == "On"
  U.addVar("CONNECTED", "0", "BOOL")
  U.addVar("LAST_RING_CAMERA", "", "STRING")
end

function OnDriverLateInit()
  math.randomseed(os.time() + (U.myId() or 0))
  U.setProp("Driver Version", U.VERSION)
  U.setProp("Children Connected", "0")
  Media.start()
  Connect()
  -- Give children a moment to load, then ask them to register.
  U.after("ping_children", 4000, pingChildren)
end

function OnDriverDestroyed()
  wsEvents:stop()
  wsDevices:stop()
  Media.stop()
end

local PROPERTY_HANDLERS = {
  ["Console Address"] = scheduleConnect,
  ["Console Port"] = scheduleConnect,
  ["API Key"] = scheduleConnect,
  ["Local Username"] = function() Priv.reset() if State.online then Priv.login(function() broadcastConfig() end) end end,
  ["Local Password"] = function() Priv.reset() if State.online then Priv.login(function() broadcastConfig() end) end end,
  ["Media Server Port"] = function() Media.start() end,
  ["Media Server Address"] = function() Media.start() end,
  ["Stream Transport"] = function() broadcastConfig() end,
  ["Debug Logging"] = function(v) U.debugEnabled = (v == "On") end,
}

function OnPropertyChanged(strProperty)
  local f = PROPERTY_HANDLERS[strProperty]
  if f then f(Properties[strProperty]) end
end

local ACTIONS = {
  Reconnect = function() scheduleConnect() end,
  RefreshDevices = function() Resync() end,
  RecreateStreams = function()
    State.streams = {}
    for childId, info in pairs(State.children) do
      if info.kind == "camera" and info.device then
        ensureStreams(info.device, function(s) U.send(childId, U.MSG.STREAMS, { JSON = U.jsonEncode(s or {}) }) end, true)
      end
    end
  end,
  PrintDevices = function()
    U.log("---- UniFi Protect devices ----")
    for id, d in pairs(State.cameras) do U.log("camera  " .. id .. "  " .. tostring(U.v(d.name)) .. "  " .. tostring(U.v(d.type))) end
    for id, d in pairs(State.sensors) do U.log("sensor  " .. id .. "  " .. tostring(U.v(d.name)) .. "  mount=" .. tostring(U.v(d.mountType))) end
    for id, d in pairs(State.sirens) do U.log("siren   " .. id .. "  " .. tostring(U.v(d.name))) end
    for childId, info in pairs(State.children) do U.log("child " .. childId .. " kind=" .. tostring(info.kind) .. " device=" .. tostring(info.device)) end
    U.log("media base: " .. tostring(Media.base()))
  end,
  PingChildren = function() pingChildren() end,
}

function ExecuteCommand(strCommand, tParams)
  local cmd, params = U.normalizeCommand(strCommand, tParams)
  if cmd:sub(1, 3) == "UP_" then
    handleChildMessage(cmd, params)
    return
  end
  local f = ACTIONS[cmd]
  if f then f(params) return end
  U.dbg("Unhandled command " .. tostring(cmd))
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  if tostring(strCommand):sub(1, 3) == "UP_" then handleChildMessage(strCommand, tParams or {}) end
end

function OnBindingChanged(idBinding, strClass, bIsBound)
  if idBinding == U.MASTER_BINDING then U.after("ping_children", 1000, pingChildren) end
end

-- Exposed for the off-controller test harness.
UP_TEST = { State = State, Media = Media, Priv = Priv, wsEvents = wsEvents, wsDevices = wsDevices, U = U }
