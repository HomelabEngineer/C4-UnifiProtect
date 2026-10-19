--[[
================================================================================
 UniFi Protect Camera / Doorbell - child driver (Control4 camera proxy)
================================================================================
 * Live video: RTSP(S) URLs created through the Protect Integration API and
   handed to Navigators with the dynamic-stream API (GET_STREAM_URLS).
 * Snapshots / MJPEG fallback: served by the master driver's media server.
 * Recordings: Extras tab lists recent Protect events; picking one (or a
   "jump back" time) switches the camera view to recorded playback (MJPEG
   frames pulled from the NVR timeline) until "Back to Live".
 * Doorbells: ring -> "Doorbell Pressed" event (use it for Announcements),
   RINGING variable, contact output for a stock Doorbell driver, LCD message.

 Open Source - MIT License. Not affiliated with Ubiquiti Inc. or Snap One LLC.
================================================================================
]]

local U = require("up_common")
local Child = U.Child
U.label = "UniFi Camera"

local PROXY = 5001
local DOORBELL_CONTACT = 100
local MOTION_CONTACT = 101
local SMART_CONTACT = 102

Cam = Cam or {}
Cam.streams = nil
Cam.playback = nil
Cam.history = {}
Cam.historyReq = nil
Cam.historyError = nil
Cam.lastRingAt = 0
Cam.motion = false
Cam.online = nil
Cam.active = {}        -- active event id -> type
Cam.lastRingText = "--"
Cam.lastMotionText = "--"
Cam.lastDetectText = "--"
Cam.extrasSetup = nil
Cam.extrasState = nil
Cam.lcdReq = nil

local SMART_EVENTS = {
  person = "Person Detected",
  vehicle = "Vehicle Detected",
  animal = "Animal Detected",
  package = "Package Detected",
  licensePlate = "License Plate Detected",
  face = "Face Detected",
}

local SMART_LABELS = {
  person = "Person", vehicle = "Vehicle", animal = "Animal", package = "Package",
  licensePlate = "License Plate", face = "Face",
  alrmSmoke = "Smoke Alarm Sound", alrmCmonx = "CO Alarm Sound", alrmSiren = "Siren",
  alrmBabyCry = "Baby Crying", alrmSpeak = "Speech", alrmBark = "Barking",
  alrmBurglar = "Burglar Alarm", alrmCarHorn = "Car Horn", alrmGlassBreak = "Glass Break",
}

local TYPE_LABELS = {
  ring = "Doorbell", motion = "Motion", smartDetectZone = "Detection",
  smartDetectLine = "Line Crossing", smartAudioDetect = "Audio", smartDetectLoiterZone = "Loitering",
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function camId() return Child.deviceId end

local function mediaBase()
  return Child.masterConfig and U.v(Child.masterConfig.mediaBase) or nil
end

local function isDoorbell()
  local mode = U.prop("Doorbell Mode", "Auto")
  if mode == "Doorbell" then return true end
  if mode == "Camera" then return false end
  if U.persistGet("learned_doorbell") == Child.deviceId and Child.deviceId then return true end
  local d = Child.device
  if not d then return false end
  local t = (tostring(U.v(d.type) or "") .. " " .. tostring(U.v(d.name) or "")):lower()
  return t:find("doorbell", 1, true) ~= nil or type(U.v(d.lcdMessage)) == "table"
end

local function smartList(ev)
  local out = {}
  local s = U.v(ev.smartDetectTypes)
  if type(s) == "table" then
    for _, v in ipairs(s) do out[#out + 1] = tostring(v) end
  end
  return out
end

local function describeEvent(ev)
  local t = U.v(ev.type) or "event"
  local label = TYPE_LABELS[t] or t
  local smart = smartList(ev)
  if #smart > 0 then
    local names = {}
    for _, s in ipairs(smart) do names[#names + 1] = SMART_LABELS[s] or s end
    label = table.concat(names, "/")
    if t == "smartDetectLine" then label = label .. " (line)" end
  end
  return label
end

local function shortTime(ms)
  local secs = math.floor((tonumber(ms) or 0) / 1000)
  if os.date("%Y%m%d", secs) == os.date("%Y%m%d") then
    return os.date("%I:%M:%S %p", secs):gsub("^0", "")
  end
  return (os.date("%a %I:%M %p", secs):gsub(" 0", " "))
end

local function notifyUrlsChanged()
  pcall(C4.SendToProxy, C4, PROXY, "DYNAMIC_URLS_CHANGED", {}, "NOTIFY")
end

local function pulse(binding, seconds)
  U.contact(binding, true)
  U.after("pulse_" .. binding, math.max(1, tonumber(seconds) or 2) * 1000, function() U.contact(binding, false) end)
end

-- ---------------------------------------------------------------------------
-- Stream / snapshot URLs
-- ---------------------------------------------------------------------------
local RES_HINT = { high = "1920x1080", medium = "1280x720", low = "640x360", package = "1600x1200" }

local function liveMjpegUrl(height)
  local base = mediaBase()
  if not base or not camId() then return nil end
  return base .. "/live/" .. camId() .. ".mjpg" .. (height and ("?h=" .. height) or "")
end

local function snapshotUrl(height)
  local base = mediaBase()
  if not base or not camId() then return nil end
  return base .. "/snap/" .. camId() .. ".jpg" .. (height and ("?h=" .. height) or "")
end

local function playbackUrl()
  local base = mediaBase()
  if not base or not camId() or not Cam.playback then return nil end
  return string.format("%s/play/%s/%d.mjpg?speed=%s&fps=%s&h=720", base, camId(), Cam.playback.start,
    tostring(Cam.playback.speed or 1), tostring(tonumber(U.prop("Playback FPS", "2")) or 2))
end

local function orderedQualities(resolution)
  local w = tonumber((tostring(resolution or "")):match("^(%d+)"))
  local pref = U.prop("Preferred Stream", "Auto")
  if pref == "High" then return { "high", "medium", "low" } end
  if pref == "Medium" then return { "medium", "high", "low" } end
  if pref == "Low" then return { "low", "medium", "high" } end
  if w and w <= 700 then return { "low", "medium", "high" } end
  if w and w <= 1300 then return { "medium", "high", "low" } end
  return { "high", "medium", "low" }
end

local function buildStreamsXml(params)
  params = params or {}
  local codecs = tostring(params.CODEC or params.codec or ""):lower()
  local wantsMjpegOnly = codecs ~= "" and not codecs:find("h26", 1, true)
  local out = { "<streams>" }
  local function add(url, codec, res, fps)
    if not url then return end
    local attrs = { 'url="' .. U.xmlEscape(url) .. '"', 'codec="' .. codec .. '"' }
    if res then attrs[#attrs + 1] = 'resolution="' .. res .. '"' end
    if fps then attrs[#attrs + 1] = 'fps="' .. fps .. '"' end
    out[#out + 1] = "<stream " .. table.concat(attrs, " ") .. "/>"
  end
  if Cam.playback then
    add(playbackUrl(), "mjpeg", "1280x720", tostring(U.prop("Playback FPS", "2")))
  else
    if not wantsMjpegOnly and Cam.streams then
      local useRtsps = U.v(Child.masterConfig.rtspMode) == "RTSPS"
      local set = useRtsps and Cam.streams.rtsps or Cam.streams.rtsp
      local codec = U.prop("Stream Codec", "H.264") == "H.265" and "h265" or "h264"
      if type(set) == "table" then
        for _, q in ipairs(orderedQualities(params.RESOLUTION or params.resolution)) do
          add(U.v(set[q]), codec, RES_HINT[q], nil)
        end
      end
    end
    if U.prop("MJPEG Fallback", "Yes") == "Yes" or wantsMjpegOnly or not Cam.streams then
      add(liveMjpegUrl(720), "mjpeg", "1280x720", "2")
    end
  end
  out[#out + 1] = "</streams>"
  return table.concat(out)
end

local function buildSnapshotsXml()
  local out = { "<snapshots>" }
  local base = mediaBase()
  if base and camId() then
    if Cam.playback then
      out[#out + 1] = '<snapshot url="' .. U.xmlEscape(string.format("%s/frame/%s/%d.jpg?h=720", base, camId(), Cam.playback.start)) .. '"/>'
    end
    out[#out + 1] = '<snapshot url="' .. U.xmlEscape(snapshotUrl(1080)) .. '" resolution="1920x1080"/>'
    out[#out + 1] = '<snapshot url="' .. U.xmlEscape(snapshotUrl(360)) .. '" resolution="640x360"/>'
  end
  out[#out + 1] = "</snapshots>"
  return table.concat(out)
end

-- Legacy (non-dynamic) clients: ADDRESS/HTTP port point at the master media server.
local function pushLegacyAddress()
  local base = mediaBase()
  if not base then return end
  local host, port = base:match("^http://([^/:]+):(%d+)/")
  if host then
    pcall(C4.SendToProxy, C4, PROXY, "ADDRESS_CHANGED", { ADDRESS = host }, "NOTIFY")
    pcall(C4.SendToProxy, C4, PROXY, "HTTP_PORT_CHANGED", { PORT = port }, "NOTIFY")
  end
end

local function mediaPath(kind)
  local base = mediaBase()
  if not base or not camId() then return "" end
  local path = base:match("^http://[^/]+/(.*)$") or ""
  if kind == "snap" then return path .. "/snap/" .. camId() .. ".jpg" end
  return path .. "/live/" .. camId() .. ".mjpg"
end

local function updateUrlVars()
  U.setVar("SNAPSHOT_URL", snapshotUrl() or "")
  U.setVar("LIVE_MJPEG_URL", liveMjpegUrl() or "")
  local s = Cam.streams and Cam.streams.rtsp and U.v(Cam.streams.rtsp.high)
  U.setProp("RTSP URL (High)", s or "")
end

-- ---------------------------------------------------------------------------
-- Extras (Navigator "Extras" tab on the camera)
-- ---------------------------------------------------------------------------
local function listObject(id, label, command, items, value)
  local parts = { '<object type="list" id="' .. id .. '" label="' .. U.xmlEscape(label) .. '" command="' .. command .. '"' }
  if value then parts[#parts + 1] = ' value="' .. U.xmlEscape(value) .. '"' end
  parts[#parts + 1] = '><list maxselections="1" minselections="1">'
  for _, it in ipairs(items) do
    parts[#parts + 1] = '<item text="' .. U.xmlEscape(it[1]) .. '" value="' .. U.xmlEscape(it[2]) .. '"/>'
  end
  parts[#parts + 1] = "</list></object>"
  return table.concat(parts)
end

local function buttonObject(id, label, command, text)
  return '<object type="button" id="' .. id .. '" label="' .. U.xmlEscape(label) .. '" command="' .. command
    .. '"><buttontext>' .. U.xmlEscape(text) .. "</buttontext></object>"
end

local function displayObject(id, label, text)
  return listObject(id, label, "UP_X_NOOP", { { text, text } }, text)
end

local JUMPS = {
  { "30 seconds ago", "0.5" }, { "1 minute ago", "1" }, { "2 minutes ago", "2" }, { "5 minutes ago", "5" },
  { "10 minutes ago", "10" }, { "15 minutes ago", "15" }, { "30 minutes ago", "30" },
  { "1 hour ago", "60" }, { "2 hours ago", "120" }, { "4 hours ago", "240" },
  { "8 hours ago", "480" }, { "12 hours ago", "720" }, { "24 hours ago", "1440" },
}

local SPEEDS = { { "1x", "1" }, { "2x", "2" }, { "4x", "4" }, { "8x", "8" } }

local function modeText()
  if Cam.playback then
    return "Playback from " .. shortTime(Cam.playback.start) .. " (" .. tostring(Cam.playback.speed) .. "x)"
  end
  return "Live"
end

local function buildExtras()
  local sec = {}
  -- Recordings
  local items = {}
  if not U.v(Child.masterConfig.privateApi) then
    items[1] = { "Add a local Protect user on the master driver", "none" }
  elseif Cam.historyError and #Cam.history == 0 then
    items[1] = { "History unavailable: " .. tostring(Cam.historyError), "none" }
  elseif #Cam.history == 0 then
    items[1] = { Cam.historyReq and "Loading..." or "No events in the selected window", "none" }
  else
    for _, ev in ipairs(Cam.history) do
      items[#items + 1] = { shortTime(ev.start) .. " - " .. describeEvent(ev), tostring(U.v(ev.id)) }
    end
  end
  local rec = {}
  rec[#rec + 1] = displayObject("mode", "Viewing", modeText())
  rec[#rec + 1] = buttonObject("live", "Live View", "UP_X_LIVE", "Back to Live")
  rec[#rec + 1] = listObject("events", "Play Recent Event", "UP_X_EVENT", items)
  rec[#rec + 1] = listObject("jump", "Play From", "UP_X_JUMP", JUMPS)
  rec[#rec + 1] = listObject("speed", "Playback Speed", "UP_X_SPEED", SPEEDS, tostring(U.persistGet("speed", "1")))
  rec[#rec + 1] = buttonObject("refresh", "Event History", "UP_X_REFRESH", "Refresh")
  sec[#sec + 1] = '<section label="Recordings">' .. table.concat(rec) .. "</section>"

  local st = {}
  if isDoorbell() then st[#st + 1] = displayObject("lastring", "Last Ring", Cam.lastRingText) end
  st[#st + 1] = displayObject("lastmotion", "Last Motion", Cam.lastMotionText)
  st[#st + 1] = displayObject("lastdetect", "Last Detection", Cam.lastDetectText)
  sec[#sec + 1] = '<section label="Activity">' .. table.concat(st) .. "</section>"

  if isDoorbell() then
    local msgs = {
      { "Default (clear message)", "clear" },
      { "Leave Package at Door", "LEAVE_PACKAGE_AT_DOOR" },
      { "Do Not Disturb", "DO_NOT_DISTURB" },
    }
    for _, m in ipairs(U.split(U.prop("Doorbell Custom Messages", ""), ";")) do
      m = U.trim(m)
      if m ~= "" then msgs[#msgs + 1] = { m, "custom:" .. m } end
    end
    sec[#sec + 1] = '<section label="Doorbell">' .. listObject("lcd", "Doorbell Display Message", "UP_X_LCD", msgs) .. "</section>"
  end

  local xml = "<extras_setup><extra>" .. table.concat(sec) .. "</extra></extras_setup>"
  if xml ~= Cam.extrasSetup then
    Cam.extrasSetup = xml
    pcall(C4.SendToProxy, C4, PROXY, "EXTRAS_SETUP_CHANGED", { XML = xml }, "NOTIFY")
  end
end

local function extrasAck(id, value)
  local xml = '<extras_state><extra><object id="' .. U.xmlEscape(id) .. '"'
    .. (value and (' value="' .. U.xmlEscape(value) .. '"') or "") .. "/></extra></extras_state>"
  Cam.extrasState = xml
  pcall(C4.SendToProxy, C4, PROXY, "EXTRAS_STATE_CHANGED", { XML = xml }, "NOTIFY")
end

local extrasPending = false
local function refreshExtrasSoon()
  if extrasPending then return end
  extrasPending = true
  U.after("extras", 300, function()
    extrasPending = false
    buildExtras()
  end)
end

-- ---------------------------------------------------------------------------
-- History / playback
-- ---------------------------------------------------------------------------
local FILTERS = { ["All Events"] = "all", ["Rings and Smart Detections"] = "smart", ["Rings Only"] = "ring" }

local function requestHistory()
  if not camId() or not U.v(Child.masterConfig.privateApi) then refreshExtrasSoon() return end
  Cam.historyReq = Child.call("events", {
    hours = tonumber(U.prop("History Hours", "24")) or 24,
    limit = tonumber(U.prop("History Events", "20")) or 20,
    filter = FILTERS[U.prop("History Filter", "All Events")] or "all",
  })
  refreshExtrasSoon()
end

local function historySoon(delayMs)
  U.after("history", delayMs or 5000, requestHistory)
end

local function setPlayback(startMs, label)
  local speed = tonumber(U.persistGet("speed", "1")) or 1
  local preroll = (tonumber(U.prop("Playback Pre-Roll (seconds)", "5")) or 5) * 1000
  Cam.playback = { start = math.floor(startMs - preroll), speed = speed, label = label }
  U.setVar("PLAYBACK_ACTIVE", true)
  U.setProp("Playback Status", modeText())
  notifyUrlsChanged()
  refreshExtrasSoon()
  U.fire("Playback Started")
  local timeoutMin = tonumber(U.prop("Playback Timeout (minutes)", "15")) or 15
  if timeoutMin > 0 then
    U.after("playback_timeout", timeoutMin * 60000, function() GoLive() end)
  end
end

function GoLive()
  U.stop("playback_timeout")
  if not Cam.playback then return end
  Cam.playback = nil
  U.setVar("PLAYBACK_ACTIVE", false)
  U.setProp("Playback Status", "Live")
  notifyUrlsChanged()
  refreshExtrasSoon()
  U.fire("Playback Stopped")
end

local function playEventById(id)
  for _, ev in ipairs(Cam.history) do
    if tostring(U.v(ev.id)) == tostring(id) then
      setPlayback(tonumber(U.v(ev.start)) or U.nowMs(), describeEvent(ev))
      return true
    end
  end
  return false
end

local function playLatest(filterType)
  for _, ev in ipairs(Cam.history) do
    if not filterType or U.v(ev.type) == filterType then
      setPlayback(tonumber(U.v(ev.start)) or U.nowMs(), describeEvent(ev))
      return true
    end
  end
  U.log("No matching event in history to play")
  return false
end

local function playMinutesAgo(minutes)
  minutes = tonumber(minutes) or 1
  setPlayback(U.nowMs() - minutes * 60000, tostring(minutes) .. " min ago")
end

-- ---------------------------------------------------------------------------
-- Realtime state & events
-- ---------------------------------------------------------------------------
local function setOnline(online)
  if Cam.online == online then return end
  local first = Cam.online == nil
  Cam.online = online
  U.setVar("ONLINE", online)
  if not first then U.fire(online and "Camera Online" or "Camera Offline") end
end

local function motionStart()
  U.after("motion_failsafe", 120000, function() MotionEnd() end)
  if Cam.motion then return end
  Cam.motion = true
  Cam.lastMotionText = shortTime(U.nowMs())
  U.setVar("MOTION", true)
  U.setVar("LAST_MOTION", U.fmtTime(U.nowMs()))
  U.setProp("Last Motion", U.fmtTime(U.nowMs()))
  U.contact(MOTION_CONTACT, true)
  U.fire("Motion Started")
  refreshExtrasSoon()
end

function MotionEnd()
  U.stop("motion_failsafe")
  if not Cam.motion then return end
  Cam.motion = false
  U.setVar("MOTION", false)
  U.contact(MOTION_CONTACT, false)
  U.fire("Motion Ended")
end

local function handleRing(ev)
  local now = U.nowMs()
  local cooldown = (tonumber(U.prop("Ring Cooldown (seconds)", "10")) or 10) * 1000
  if not isDoorbell() and Child.deviceId then
    U.persistSet("learned_doorbell", Child.deviceId)
    U.setProp("Device Type", "Doorbell")
  end
  Cam.lastRingText = shortTime(now)
  U.setVar("LAST_RING", U.fmtTime(now))
  U.setProp("Last Ring", U.fmtTime(now))
  local base = mediaBase()
  if base and U.v(ev.id) then U.setVar("LAST_EVENT_THUMBNAIL_URL", base .. "/thumb/" .. U.v(ev.id) .. ".jpg") end
  refreshExtrasSoon()
  historySoon(8000)
  if now - Cam.lastRingAt < cooldown then
    U.dbg("Ring ignored (cooldown)")
    return
  end
  Cam.lastRingAt = now
  U.setVar("RING_COUNT", tostring((tonumber(U.persistGet("ring_count", 0)) or 0) + 1))
  U.persistSet("ring_count", (tonumber(U.persistGet("ring_count", 0)) or 0) + 1)
  U.setVar("RINGING", true)
  pulse(DOORBELL_CONTACT, tonumber(U.prop("Contact Pulse (seconds)", "2")) or 2)
  U.fire("Doorbell Pressed")
  U.after("ringing", (tonumber(U.prop("Ringing Hold (seconds)", "15")) or 15) * 1000, function()
    U.setVar("RINGING", false)
  end)
end

local function handleDetection(ev)
  local smart = smartList(ev)
  local t = U.v(ev.type)
  local label = describeEvent(ev)
  Cam.lastDetectText = shortTime(U.nowMs()) .. " - " .. label
  U.setVar("LAST_DETECTION", label)
  U.setVar("LAST_DETECTION_TIME", U.fmtTime(U.nowMs()))
  U.setProp("Last Detection", U.fmtTime(U.nowMs()) .. " - " .. label)
  local base = mediaBase()
  if base and U.v(ev.id) then U.setVar("LAST_EVENT_THUMBNAIL_URL", base .. "/thumb/" .. U.v(ev.id) .. ".jpg") end
  pulse(SMART_CONTACT, tonumber(U.prop("Contact Pulse (seconds)", "2")) or 2)
  if t == "smartAudioDetect" then
    U.fire("Audio Detected")
  else
    for _, s in ipairs(smart) do
      if SMART_EVENTS[s] then U.fire(SMART_EVENTS[s]) end
    end
    if t == "smartDetectLine" then U.fire("Line Crossed") end
  end
  U.fire("Smart Detection")
  refreshExtrasSoon()
  historySoon(15000)
end

local function onEvent(ev, action)
  local id = U.v(ev.id)
  local t = U.v(ev.type) or (id and Cam.active[id])
  if action == "add" then
    if id and t then Cam.active[id] = t end
    if t == "ring" then
      handleRing(ev)
    elseif t == "motion" then
      motionStart()
    elseif t == "smartDetectZone" or t == "smartDetectLine" or t == "smartAudioDetect" or t == "smartDetectLoiterZone" then
      handleDetection(ev)
    end
    if U.v(ev["end"]) and t == "motion" then MotionEnd() end
  else
    if U.v(ev["end"]) then
      if id then Cam.active[id] = nil end
      if t == "motion" then MotionEnd() end
      historySoon(6000)
    end
  end
end

local function onState(dev, partial)
  local st = U.v(dev.state)
  if st then setOnline(st == "CONNECTED") end
  U.setProp("Device Type", isDoorbell() and "Doorbell" or ("Camera" .. (U.v(dev.type) and (" - " .. U.v(dev.type)) or "")))
  U.setProp("Device Name", U.v(dev.name) or "")
  if partial == dev or partial.lcdMessage ~= nil or partial.name ~= nil then refreshExtrasSoon() end
end

local function onStreams(s)
  if type(s) == "table" and s.rtsp then
    Cam.streams = s
    updateUrlVars()
    notifyUrlsChanged()
  end
end

local function onConfig(cfg)
  updateUrlVars()
  pushLegacyAddress()
  notifyUrlsChanged()
  if cfg.privateApi and #Cam.history == 0 and camId() then historySoon(1500) end
  refreshExtrasSoon()
end

local function onResult(req, ok, data, err, op)
  if op == "events" and req == Cam.historyReq then
    Cam.historyReq = nil
    if ok and type(data) == "table" then
      Cam.history = data
      Cam.historyError = nil
    else
      Cam.historyError = err
      U.log("Event history failed: " .. tostring(err))
    end
    refreshExtrasSoon()
  elseif op == "lcd" and not ok then
    U.err("Doorbell message failed: " .. tostring(err))
  elseif op == "ptz" and not ok then
    U.err("PTZ failed: " .. tostring(err))
  end
end

local function onSelected(id)
  Cam.streams = nil
  Cam.history = {}
  Cam.playback = nil
  Cam.online = nil
  Cam.active = {}
  updateUrlVars()
  notifyUrlsChanged()
  refreshExtrasSoon()
  historySoon(2000)
end

-- ---------------------------------------------------------------------------
-- Doorbell LCD
-- ---------------------------------------------------------------------------
local function setLcd(value, minutes)
  minutes = tonumber(minutes)
  if value == "clear" then
    Child.call("lcd", { clear = true })
    return
  end
  local args = {}
  if value == "LEAVE_PACKAGE_AT_DOOR" or value == "DO_NOT_DISTURB" then
    args.type = value
  else
    local text = value:gsub("^custom:", "")
    args.type = "CUSTOM_MESSAGE"
    args.text = text:sub(1, 30)
  end
  if minutes and minutes > 0 then
    args.resetAt = U.nowMs() + minutes * 60000
  elseif minutes == 0 then
    args.forever = true
  end
  Child.call("lcd", args)
end

-- ---------------------------------------------------------------------------
-- Proxy / UI requests
-- ---------------------------------------------------------------------------
local function extrasValue(p)
  return p.value or p.VALUE or p.Value or ""
end

local EXTRAS = {
  UP_X_LIVE = function(p) GoLive() extrasAck("live") end,
  UP_X_EVENT = function(p)
    local v = extrasValue(p)
    if v ~= "none" and v ~= "" then playEventById(v) end
    extrasAck("events", v)
  end,
  UP_X_JUMP = function(p)
    local v = extrasValue(p)
    playMinutesAgo(tonumber(v) or 1)
    extrasAck("jump", v)
  end,
  UP_X_SPEED = function(p)
    local v = extrasValue(p)
    U.persistSet("speed", tostring(tonumber(v) or 1))
    if Cam.playback then
      -- restart playback from roughly where it should be now
      Cam.playback.speed = tonumber(v) or 1
      notifyUrlsChanged()
      U.setProp("Playback Status", modeText())
    end
    extrasAck("speed", v)
    refreshExtrasSoon()
  end,
  UP_X_REFRESH = function(p) requestHistory() extrasAck("refresh") end,
  UP_X_LCD = function(p)
    local v = extrasValue(p)
    setLcd(v, tonumber(U.prop("Doorbell Message Minutes", "0")) or 0)
    extrasAck("lcd", v)
  end,
  UP_X_NOOP = function(p) extrasAck(p.id or p.ID or "noop") end,
}

local function handleUiRequest(cmd, params)
  if cmd == "GET_STREAM_URLS" then
    return buildStreamsXml(params)
  elseif cmd == "GET_SNAPSHOT_URLS" then
    return buildSnapshotsXml()
  elseif cmd == "GET_SNAPSHOT_QUERY_STRING" then
    return "<snapshot_query_string>" .. U.xmlEscape(mediaPath("snap")) .. "</snapshot_query_string>"
  elseif cmd == "GET_MJPEG_QUERY" or cmd == "GET_MJPEG_QUERY_STRING" then
    return "<mjpeg_query_string>" .. U.xmlEscape(mediaPath("mjpeg")) .. "</mjpeg_query_string>"
  elseif cmd == "GET_RTSP_H264_QUERY_STRING" or cmd == "GET_RTSP_H264_QUERY" then
    return "<rtsp_h264_query_string></rtsp_h264_query_string>"
  elseif cmd == "GET_EXTRAS_SETUP" then
    if not Cam.extrasSetup then buildExtras() end
    return Cam.extrasSetup
  elseif cmd == "GET_EXTRAS_STATE" then
    return Cam.extrasState or "<extras_state><extra></extra></extras_state>"
  end
  return nil
end

function UIRequest(strCommand, tParams)
  local ok, res = pcall(handleUiRequest, strCommand, tParams or {})
  if not ok then U.err("UIRequest " .. tostring(strCommand) .. ": " .. tostring(res)) return "" end
  return res or ""
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  tParams = tParams or {}
  U.dbg("RFP " .. tostring(idBinding) .. " " .. tostring(strCommand))
  -- Master messages addressed to the proxy id are forwarded here.
  if Child.handleCommand(strCommand, tParams) then return end
  if EXTRAS[strCommand] then
    EXTRAS[strCommand](tParams)
    return
  end
  local r = handleUiRequest(strCommand, tParams)
  if r then return r end
  if strCommand == "HOME" then
    Child.call("ptz", { slot = 0 })
  elseif strCommand == "PRESET" or strCommand == "SELECT_PRESET" then
    local idx = tonumber(tParams.INDEX or tParams.ID or tParams.PRESET or tParams.index or "")
    if idx then Child.call("ptz", { slot = math.max(0, idx - 1) }) end
  end
end

-- ---------------------------------------------------------------------------
-- Programming commands / actions
-- ---------------------------------------------------------------------------
local COMMANDS = {
  ["Go Live"] = function() GoLive() end,
  ["Play Last Event"] = function() playLatest(nil) end,
  ["Play Last Ring"] = function() playLatest("ring") end,
  ["Play Minutes Ago"] = function(p) playMinutesAgo(tonumber(p.Minutes or p.MINUTES) or 5) end,
  ["Refresh Event History"] = function() requestHistory() end,
  ["Set Doorbell Message"] = function(p)
    local text = p.Message or p.MESSAGE or ""
    if text == "" then return end
    setLcd("custom:" .. text, tonumber(p.Minutes or p.MINUTES) or 0)
  end,
  ["Doorbell Message Preset"] = function(p)
    local m = p.Message or p.MESSAGE or "Leave Package at Door"
    local map = { ["Leave Package at Door"] = "LEAVE_PACKAGE_AT_DOOR", ["Do Not Disturb"] = "DO_NOT_DISTURB" }
    setLcd(map[m] or "LEAVE_PACKAGE_AT_DOOR", tonumber(p.Minutes or p.MINUTES) or 0)
  end,
  ["Clear Doorbell Message"] = function() setLcd("clear") end,
  ["PTZ Go To Preset"] = function(p) Child.call("ptz", { slot = tonumber(p.Slot or p.SLOT) or 0 }) end,
  ["Set Microphone Volume"] = function(p)
    Child.call("camera_patch", { body = { micVolume = math.max(0, math.min(100, tonumber(p.Volume or p.VOLUME) or 50)) } })
  end,
  ["Set Status Light"] = function(p)
    Child.call("camera_patch", { body = { ledSettings = { isEnabled = (p.State or p.STATE) == "On" } } })
  end,
  -- Composer actions
  Reconnect = function() Child.connect() end,
  RefreshStreams = function() Child.call("streams", { force = true }) end,
  TestRing = function() handleRing({ type = "ring" }) end,
  PrintUrls = function()
    U.log("Streams: " .. buildStreamsXml({}))
    U.log("Snapshots: " .. buildSnapshotsXml())
  end,
}

function ExecuteCommand(strCommand, tParams)
  local cmd, params = U.normalizeCommand(strCommand, tParams)
  if Child.handleCommand(cmd, params) then return end
  local f = COMMANDS[cmd]
  if f then f(params) return end
  U.dbg("Unhandled command " .. tostring(cmd))
end

function OnPropertyChanged(strProperty)
  local v = Properties[strProperty]
  if Child.onPropertyChanged(strProperty) then return end
  if strProperty == "Debug Logging" then
    U.debugEnabled = (v == "On")
  elseif strProperty == "Doorbell Mode" or strProperty == "Doorbell Custom Messages" then
    refreshExtrasSoon()
  elseif strProperty == "History Hours" or strProperty == "History Events" or strProperty == "History Filter" then
    historySoon(500)
  elseif strProperty == "Preferred Stream" or strProperty == "MJPEG Fallback" or strProperty == "Stream Codec" then
    notifyUrlsChanged()
  end
end

function OnBindingChanged(idBinding, strClass, bIsBound)
  if Child.onBindingChanged(idBinding, strClass, bIsBound) then return end
  if bIsBound then
    if idBinding == DOORBELL_CONTACT or idBinding == MOTION_CONTACT or idBinding == SMART_CONTACT then
      U.contact(idBinding, false, true)
    end
  end
end

function OnDriverInit()
  U.debugEnabled = U.prop("Debug Logging", "Off") == "On"
  U.addVar("ONLINE", "0", "BOOL")
  U.addVar("RINGING", "0", "BOOL")
  U.addVar("MOTION", "0", "BOOL")
  U.addVar("PLAYBACK_ACTIVE", "0", "BOOL")
  U.addVar("LAST_RING", "", "STRING")
  U.addVar("RING_COUNT", tostring(U.persistGet("ring_count", 0)), "STRING")
  U.addVar("LAST_MOTION", "", "STRING")
  U.addVar("LAST_DETECTION", "", "STRING")
  U.addVar("LAST_DETECTION_TIME", "", "STRING")
  U.addVar("LAST_EVENT_THUMBNAIL_URL", "", "STRING")
  U.addVar("SNAPSHOT_URL", "", "STRING")
  U.addVar("LIVE_MJPEG_URL", "", "STRING")
end

function OnDriverLateInit()
  math.randomseed(os.time() + (U.myId() or 0))
  U.setProp("Driver Version", U.VERSION)
  U.setProp("Playback Status", "Live")
  pcall(C4.SendToProxy, C4, PROXY, "DYNAMIC_CAPABILITIES_CHANGED",
    { requires_dynamic_stream_urls = "true", requires_dynamic_snapshot_urls = "true", has_extras = "true" }, "NOTIFY")
  Child.init({
    kind = "camera",
    filter = function(dev) return true end,
    onState = onState,
    onEvent = onEvent,
    onStreams = onStreams,
    onConfig = onConfig,
    onResult = onResult,
    onSelected = onSelected,
  })
  buildExtras()
end

UP_TEST = { Cam = Cam, Child = Child, U = U, buildStreamsXml = buildStreamsXml, buildSnapshotsXml = buildSnapshotsXml }
