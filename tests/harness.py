"""Off-controller harness for the UniFi Protect Control4 drivers.

Runs every driver in its own Lua 5.1 state (lupa) against a stubbed Control4
API with:
  * a virtual clock (C4:SetTimer + os.time)
  * a message queue for C4:SendToDevice (master <-> children)
  * a fake UniFi Protect console (Integration API, private API, websockets)
  * fake TCP server clients for the master's media server
"""
import base64
import hashlib
import json
import os
from collections import deque

from lupa import lua51

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
COMMON = os.path.join(ROOT, "common")

START_EPOCH = 1_790_000_000  # seconds


def B(x):
    """Python -> Lua string (bytes)."""
    if isinstance(x, bytes):
        return x
    return str(x).encode("utf-8")


def S(x):
    """Lua string (bytes) -> Python str."""
    if isinstance(x, bytes):
        return x.decode("utf-8", "surrogateescape")
    return x


def lua_to_py(v):
    if v is None or isinstance(v, (bool, int, float)):
        return v
    if isinstance(v, bytes):
        return S(v)
    if lua51.lua_type(v) == "table":
        keys = list(v.keys())
        if keys and all(isinstance(k, int) for k in keys):
            return [lua_to_py(v[i]) for i in sorted(keys)]
        return {S(k): lua_to_py(v[k]) for k in keys}
    return v


STUB = r"""
local py = ...
CLOCK_MS = 0
local START = __START__
local timers = {}
local timerSeq = 0

os.time = function(t)
  if t then return START end
  return START + math.floor(CLOCK_MS / 1000)
end

local Timer = {}
Timer.__index = Timer
function Timer:Cancel() self.cancelled = true return nil end

function C4TEST_due()
  local best
  for _, t in ipairs(timers) do
    if not t.cancelled and (best == nil or t.due < best.due or (t.due == best.due and t.seq < best.seq)) then best = t end
  end
  return best and best.due or nil
end

function C4TEST_fire_until(target)
  local best
  for _, t in ipairs(timers) do
    if not t.cancelled and t.due <= target and (best == nil or t.due < best.due or (t.due == best.due and t.seq < best.seq)) then
      best = t
    end
  end
  if not best then
    CLOCK_MS = math.max(CLOCK_MS, target)
    local live = {}
    for _, t in ipairs(timers) do if not t.cancelled then live[#live + 1] = t end end
    timers = live
    return false
  end
  CLOCK_MS = math.max(CLOCK_MS, best.due)
  if best.rep then best.due = best.due + best.ms else best.cancelled = true end
  local ok, err = pcall(best.fn, best, 0)
  if not ok then py.error("timer error: " .. tostring(err)) end
  return true
end

C4 = {}
Properties = Properties or {}
PersistData = PersistData or {}

function C4:SetTimer(ms, fn, rep)
  timerSeq = timerSeq + 1
  local t = setmetatable({ due = CLOCK_MS + ms, ms = ms, fn = fn, rep = rep and true or false, seq = timerSeq }, Timer)
  timers[#timers + 1] = t
  return t
end
function C4:GetTime() return START * 1000 + CLOCK_MS end
function C4:UpdateProperty(name, value) Properties[name] = tostring(value) py.property(name, tostring(value)) end
function C4:UpdatePropertyList(name, list, sel) py.property_list(name, list, sel) end
function C4:SendToProxy(binding, cmd, params, kind) py.to_proxy(binding, cmd, params or {}, kind) end
function C4:SendToDevice(id, cmd, params) py.to_device(id, cmd, params or {}) end
function C4:GetDeviceID() return py.device_id() end
function C4:GetBoundProviderDevice(dev, binding) return py.bound_provider(dev, binding) end
function C4:GetBoundConsumerDevices(dev, binding) return py.bound_consumers(dev, binding) end
function C4:GetDevices(filter) return py.get_devices(filter and filter.C4iNames or "") end
function C4:GetDevicesByC4iName(name) return py.get_devices(name) end
function C4:GetDeviceVariables(id) return py.device_variables(id) end
function C4:FireEvent(name) py.event(name) end
function C4:AddVariable(name, value, vtype) py.variable(name, tostring(value)) return true end
function C4:SetVariable(name, value) py.variable(name, tostring(value)) end
function C4:Base64Encode(s) return py.b64(s) end
function C4:Hash(alg, s, opts) return py.hash(alg, s) end
function C4:GetMyNetworkAddress() return "192.168.1.50" end
function C4:GetControllerNetworkAddress() return "192.168.1.50" end
function C4:ErrorLog(msg) py.errorlog(msg) end

-- C4:url()
function C4:url()
  local t = { opts = {} }
  function t:SetOptions(o) self.opts = o return self end
  function t:SetOption(k, v) self.opts[k] = v return self end
  function t:OnDone(f) self.done = f return self end
  function t:Get(url, h) py.http(self, "GET", url, h or {}, nil) return self end
  function t:Post(url, d, h) py.http(self, "POST", url, h or {}, d) return self end
  function t:Put(url, d, h) py.http(self, "PUT", url, h or {}, d) return self end
  function t:Delete(url, d, h) py.http(self, "DELETE", url, h or {}, d) return self end
  function t:Custom(url, m, d, h) py.http(self, m, url, h or {}, d) return self end
  return t
end
function C4TEST_http_done(t, code, body, headers)
  t.done(t, { { code = code, body = body, headers = headers } }, 0, nil)
end
function C4TEST_http_fail(t, msg)
  t.done(t, {}, 7, msg)
end

-- network bindings (websocket)
function C4:CreateNetworkConnection(b, host, kind) py.net_create(b, host, kind) end
function C4:NetPortOptions(b, port, kind, opts) py.net_options(b, port, kind, opts) end
function C4:NetConnect(b, port) py.net_connect(b, port) end
function C4:NetDisconnect(b, port) py.net_disconnect(b, port) end
function C4:SendToNetwork(b, port, data) py.net_send(b, port, data) end

-- TCP server
function C4:CreateTCPServer()
  local srv = { cb = {} }
  function srv:OnResolve(f) self.cb.resolve = f return self end
  function srv:OnListen(f) self.cb.listen = f return self end
  function srv:OnError(f) self.cb.err = f return self end
  function srv:OnAccept(f) self.cb.accept = f return self end
  function srv:Listen(host, port) py.tcp_listen(self, port) return self end
  function srv:Close() py.tcp_close(self) return self end
  function srv:GetLocalAddress() return { ip = "192.168.1.50", port = 0 } end
  return srv
end
function C4TEST_listen_ok(srv, port) if srv.cb.listen then srv.cb.listen(srv, { ip = "0.0.0.0", port = port }) end end
local clientSeq = 0
function C4TEST_accept(srv)
  clientSeq = clientSeq + 1
  local cli = { cb = {}, closed = false, hid = clientSeq }
  function cli:OnRead(f) self.cb.read = f return self end
  function cli:OnWrite(f) self.cb.write = f return self end
  function cli:OnDisconnect(f) self.cb.disc = f return self end
  function cli:OnError(f) self.cb.err = f return self end
  function cli:ReadUntil(d) return self end
  function cli:Write(data) py.client_write(self.hid, data) return self end
  function cli:Close(g) if not self.closed then self.closed = true py.client_close(self.hid) end return self end
  function cli:GetRemoteAddress() return { ip = "192.168.1.99", port = 50000 } end
  srv.cb.accept(srv, cli)
  return cli
end
function C4TEST_client_read(cli, data) if cli.cb.read then cli.cb.read(cli, data) end end
function C4TEST_client_written(cli) if cli.cb.write then cli.cb.write(cli) end end
function C4TEST_client_disconnect(cli) if cli.cb.disc then cli.cb.disc(cli, 0, "") end end

function C4TEST_call(name, ...)
  local f = _G[name]
  if not f then return nil end
  return f(...)
end
"""


def ws_frame(opcode, payload=b"", fin=True):
    payload = B(payload)
    b1 = (0x80 if fin else 0) | opcode
    n = len(payload)
    if n < 126:
        hdr = bytes([b1, n])
    elif n < 65536:
        hdr = bytes([b1, 126, n >> 8, n & 255])
    else:
        hdr = bytes([b1, 127]) + n.to_bytes(8, "big")
    return hdr + payload


def parse_client_frames(buf):
    """Parse masked client frames; returns (frames, rest)."""
    frames = []
    pos = 0
    while len(buf) - pos >= 2:
        b1, b2 = buf[pos], buf[pos + 1]
        n = b2 & 0x7F
        hdr = 2
        if n == 126:
            n = int.from_bytes(buf[pos + 2:pos + 4], "big")
            hdr = 4
        elif n == 127:
            n = int.from_bytes(buf[pos + 2:pos + 10], "big")
            hdr = 10
        masked = b2 & 0x80
        mask = buf[pos + hdr:pos + hdr + 4] if masked else b"\0\0\0\0"
        if masked:
            hdr += 4
        if len(buf) - pos < hdr + n:
            break
        data = bytes(c ^ mask[i % 4] for i, c in enumerate(buf[pos + hdr:pos + hdr + n]))
        frames.append((b1 & 0x0F, data, bool(masked)))
        pos += hdr + n
    return frames, buf[pos:]


JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 200 + b"\xff\xd9"


def jpeg(tag):
    return b"\xff\xd8\xff\xe0" + B(tag).ljust(200, b"\x00") + b"\xff\xd9"


class FakeProtect:
    API_KEY = "test-api-key"

    def __init__(self):
        self.calls = []
        self.cameras = [
            {"id": "cam1", "modelKey": "camera", "state": "CONNECTED", "name": "Front Door", "mac": "AA",
             "type": "UVC G4 Doorbell Pro", "lcdMessage": None, "featureFlags": {"hasMic": True},
             "hasPackageCamera": True},
            {"id": "cam2", "modelKey": "camera", "state": "CONNECTED", "name": "Driveway", "mac": "BB",
             "type": "UVC G5 Bullet", "featureFlags": {}, "hasPackageCamera": False},
        ]
        self.sensors = [
            {"id": "sen1", "modelKey": "sensor", "state": "CONNECTED", "name": "Back Door", "mac": "C1",
             "mountType": "door", "batteryStatus": {"percentage": 90, "isLow": False},
             "stats": {"light": {"value": None, "status": "neutral"}, "humidity": {"value": None, "status": "neutral"},
                       "temperature": {"value": None, "status": "neutral"}},
             "isOpened": False, "isMotionDetected": False, "tamperingDetectedAt": None,
             "leakDetectedAt": None, "externalLeakDetectedAt": None, "alarmTriggeredAt": None,
             "featureFlags": {"open": {}, "tamper": {}}},
            {"id": "sen2", "modelKey": "sensor", "state": "CONNECTED", "name": "Hall Motion", "mac": "C2",
             "mountType": "none", "batteryStatus": {"percentage": 80, "isLow": False},
             "stats": {"light": {"value": 20, "status": "neutral"}, "humidity": {"value": 40, "status": "neutral"},
                       "temperature": {"value": 21, "status": "neutral"}},
             "isOpened": None, "isMotionDetected": False, "tamperingDetectedAt": None,
             "leakDetectedAt": None, "externalLeakDetectedAt": None, "alarmTriggeredAt": None,
             "featureFlags": {"motion": {}, "tamper": {}}},
            {"id": "sen3", "modelKey": "sensor", "state": "CONNECTED", "name": "Basement Env", "mac": "C3",
             "mountType": "leak", "batteryStatus": {"percentage": 70, "isLow": False},
             "stats": {"light": {"value": 5, "status": "neutral"}, "humidity": {"value": 55.4, "status": "neutral"},
                       "temperature": {"value": 18.5, "status": "neutral"}},
             "isOpened": None, "isMotionDetected": False, "tamperingDetectedAt": None,
             "leakDetectedAt": None, "externalLeakDetectedAt": None, "alarmTriggeredAt": None,
             "featureFlags": {"temperature": {}, "humidity": {}, "light": {}, "waterLeak": {}}},
            {"id": "sen4", "modelKey": "sensor", "state": "CONNECTED", "name": "Kitchen Smoke", "mac": "C4",
             "mountType": "none", "batteryStatus": {"percentage": 100, "isLow": False},
             "stats": {}, "isOpened": None, "isMotionDetected": False, "tamperingDetectedAt": None,
             "leakDetectedAt": None, "externalLeakDetectedAt": None, "alarmTriggeredAt": None,
             "featureFlags": {"smoke": {}}},
        ]
        self.sirens = [
            {"id": "sir1", "modelKey": "siren", "state": "CONNECTED", "name": "Garage Siren", "mac": "D1",
             "volume": 80, "ledSettings": {"isEnabled": True},
             "sirenStatus": {"isActive": False, "activatedAt": None, "duration": None}, "connectionType": "superlink"},
        ]
        self.streams = {}
        self.events = [
            {"id": "ev3", "type": "ring", "start": (START_EPOCH - 600) * 1000, "end": (START_EPOCH - 590) * 1000,
             "camera": "cam1", "smartDetectTypes": [], "score": 0},
            {"id": "ev2", "type": "smartDetectZone", "start": (START_EPOCH - 1200) * 1000, "end": (START_EPOCH - 1180) * 1000,
             "camera": "cam1", "smartDetectTypes": ["person"], "score": 80},
            {"id": "ev9", "type": "motion", "start": (START_EPOCH - 1300) * 1000, "end": (START_EPOCH - 1290) * 1000,
             "camera": "cam2", "smartDetectTypes": [], "score": 50},
        ]
        self.logged_in = False
        self.cookie = "TOKEN=abc123"
        self.login_count = 0
        self.private_ok = True
        self.meta_code = 200

    def handle(self, method, url, headers, body):
        self.calls.append((method, url, body))
        path = url.split("://", 1)[1]
        path = path[path.index("/"):]
        query = ""
        if "?" in path:
            path, query = path.split("?", 1)
        hdrs = {S(k).lower(): S(v) for k, v in headers.items()}
        if path == "/api/auth/login":
            self.login_count += 1
            data = json.loads(body)
            if data.get("username") == "c4" and data.get("password") == "pw":
                return 200, b"{}", {"Set-Cookie": self.cookie + "; path=/; httponly", "X-CSRF-Token": "csrf1"}
            return 401, b'{"error":"bad"}', {}
        if path.startswith("/proxy/protect/integration"):
            if hdrs.get("x-api-key") != self.API_KEY:
                return 401, b'{"error":"unauthorized"}', {}
            p = path[len("/proxy/protect/integration"):]
            if p == "/v1/meta/info":
                return self.meta_code, b'{"applicationVersion":"7.2.1"}', {}
            if p == "/v1/cameras" and method == "GET":
                return 200, B(json.dumps(self.cameras)), {}
            if p == "/v1/sensors":
                return 200, B(json.dumps(self.sensors)), {}
            if p == "/v1/sirens":
                return 200, B(json.dumps(self.sirens)), {}
            if p.endswith("/rtsps-stream"):
                cam = p.split("/")[3]
                if method == "GET":
                    return 200, B(json.dumps(self.streams.get(cam, {}))), {}
                q = json.loads(body)["qualities"]
                self.streams[cam] = {k: f"rtsps://10.0.0.1:7441/{cam}{k}?enableSrtp" for k in q}
                return 200, B(json.dumps(self.streams[cam])), {}
            if p.endswith("/snapshot"):
                cam = p.split("/")[3]
                return 200, jpeg("live-" + cam), {"Content-Type": "image/jpeg"}
            if method == "PATCH" and p.startswith("/v1/cameras/"):
                return 200, B(json.dumps(self.cameras[0])), {}
            if p.startswith("/v1/sirens/") and method == "POST":
                return 204, b"", {}
            if p.startswith("/v1/cameras/") and "/ptz/goto/" in p:
                return 204, b"", {}
            return 404, b'{"error":"not found"}', {}
        if path.startswith("/proxy/protect/api"):
            if not self.private_ok or hdrs.get("cookie") != self.cookie:
                return 401, b"{}", {}
            p = path[len("/proxy/protect/api"):]
            if p == "/events":
                params = [kv.split("=", 1) for kv in query.split("&") if kv]
                cams = [v for k, v in params if k == "cameras"]
                types = [v for k, v in params if k == "types"]
                evs = [e for e in self.events if (not cams or e["camera"] in cams) and (not types or e["type"] in types)]
                return 200, B(json.dumps(evs)), {}
            if p.endswith("/recording-snapshot"):
                cam = p.split("/")[2]
                ts = dict(kv.split("=", 1) for kv in query.split("&"))["ts"]
                return 200, jpeg(f"rec-{cam}-{ts}"), {}
            if p.endswith("/thumbnail"):
                return 200, jpeg("thumb-" + p.split("/")[2]), {}
            if p.endswith("/snapshot"):
                return 200, jpeg("privsnap"), {}
            return 404, b"{}", {}
        return 404, b"", {}


class Driver:
    def __init__(self, sim, device_id, folder, props):
        self.sim = sim
        self.id = device_id
        self.folder = folder
        self.properties = dict(props)
        self.proxy = []        # (binding, cmd, params, kind)
        self.events = []
        self.variables = {}
        self.prop_lists = {}
        self.errors = []
        self.logs = []
        L = lua51.LuaRuntime(encoding=None, unpack_returned_tuples=True)
        self.L = L
        drv_dir = os.path.join(ROOT, "drivers", folder)
        L.execute(B("package.path = '%s/?.lua;%s/?.lua;' .. package.path" % (drv_dir, COMMON)))
        g = L.globals()
        g[b"print"] = self._print
        props_tbl = L.table_from({B(k): B(v) for k, v in self.properties.items()})
        g[b"Properties"] = props_tbl
        stub = STUB.replace("__START__", str(START_EPOCH))
        L.execute(B(stub), self._py_bridge())
        src = open(os.path.join(drv_dir, "driver.lua"), "rb").read()
        L.execute(src)
        self.g = g

    # -- bridge ---------------------------------------------------------
    def _py_bridge(self):
        sim, me = self.sim, self

        class Bridge:
            pass

        b = Bridge()

        def error(msg):
            me.errors.append(S(msg))
            raise AssertionError(S(msg))
        b.error = error
        b.property = lambda n, v: me.properties.__setitem__(S(n), S(v))
        b.property_list = lambda n, l, sel=None: me.prop_lists.__setitem__(S(n), (S(l), S(sel) if sel else None))
        b.to_proxy = lambda binding, cmd, params, kind=None: me.proxy.append((binding, S(cmd), lua_to_py(params), S(kind)))
        b.to_device = lambda dev, cmd, params: sim.queue_device(int(dev), S(cmd), lua_to_py(params), me.id)
        b.device_id = lambda: me.id
        b.bound_provider = lambda dev, binding: sim.bindings.get((int(dev), int(binding)))
        b.bound_consumers = lambda dev, binding: me.L.table_from({k: 1 for (k, kb), v in sim.bindings.items() if v == int(dev)})
        b.get_devices = lambda names: me.L.table_from(sim.devices_by_driver(S(names)))
        b.device_variables = lambda dev: me.L.table_from({1001: me.L.table_from({b"name": b"LIGHT_LEVEL", b"value": B(sim.light_levels.get(int(dev), 0))})})
        b.event = lambda name: me.events.append(S(name))
        b.variable = lambda n, v: me.variables.__setitem__(S(n), S(v))
        b.b64 = lambda s: base64.b64encode(s).decode().encode()
        b.hash = lambda alg, s: base64.b64encode(hashlib.sha1(s).digest())
        b.errorlog = lambda m: me.errors.append(S(m))
        b.http = lambda t, method, url, headers, body: sim.queue_http(me, t, S(method), S(url), lua_to_py(headers) or {}, body)
        b.net_create = lambda bnd, host, kind: sim.net_create(me, int(bnd), S(host))
        b.net_options = lambda bnd, port, kind, opts: None
        b.net_connect = lambda bnd, port: sim.net_connect(me, int(bnd), int(port))
        b.net_disconnect = lambda bnd, port: sim.net_disconnect(me, int(bnd))
        b.net_send = lambda bnd, port, data: sim.net_send(me, int(bnd), data)
        b.tcp_listen = lambda srv, port: sim.tcp_listen(me, srv, int(port))
        b.tcp_close = lambda srv: None
        b.client_write = lambda hid, data: sim.client_write(me, hid, data)
        b.client_close = lambda hid: sim.client_close(me, hid)
        # Hand Lua a plain table of functions (attribute lookups on a Python
        # object proved unreliable across long runs in lupa).
        self._bridge_funcs = {k: v for k, v in vars(b).items() if callable(v)}
        return self.L.table_from({B(k): v for k, v in self._bridge_funcs.items()})

    def _print(self, *args):
        line = " ".join(S(a) if isinstance(a, bytes) else str(a) for a in args)
        self.logs.append(line)
        if os.environ.get("C4_VERBOSE"):
            print(f"[{self.folder}] {line}")

    # -- helpers --------------------------------------------------------
    def call(self, name, *args):
        conv = []
        for a in args:
            if isinstance(a, dict):
                a = self.L.table_from({B(k): B(v) for k, v in a.items()})
            elif isinstance(a, str):
                a = B(a)
            conv.append(a)
        return self.g[b"C4TEST_call"](B(name), *conv)

    def set_property(self, name, value):
        self.properties[name] = value
        self.g[b"Properties"][B(name)] = B(value)
        self.call("OnPropertyChanged", name)

    def proxy_cmds(self, binding=None, cmd=None):
        return [p for p in self.proxy if (binding is None or p[0] == binding) and (cmd is None or p[1] == cmd)]


class Sim:
    def __init__(self):
        self.protect = FakeProtect()
        self.drivers = {}
        self.queue = deque()
        self.bindings = {}          # (consumerDevice, binding) -> providerDevice
        self.light_levels = {}
        self.light_cmds = []
        self.nets = {}              # (driverId, binding) -> dict
        self.servers = {}           # driverId -> (srv, port)
        self.clients = {}           # id(cli) -> dict
        self.ws_frames = []         # (driverId, binding, opcode, payload)
        self.auto_pong = True

    # -- drivers ----------------------------------------------------------
    def add(self, device_id, folder, props=None):
        d = Driver(self, device_id, folder, props or {})
        self.drivers[device_id] = d
        return d

    def devices_by_driver(self, names):
        out = {}
        for n in names.split(","):
            n = n.strip()
            for did, d in self.drivers.items():
                if d.folder + ".c4z" == n:
                    out[did] = {b"driverFileName": B(n)}
        return out

    def start(self, ids=None):
        for did in (ids or list(self.drivers)):
            self.drivers[did].call("OnDriverInit")
        for did in (ids or list(self.drivers)):
            self.drivers[did].call("OnDriverLateInit")
        self.pump()

    # -- queue ------------------------------------------------------------
    def queue_device(self, dev, cmd, params, sender):
        self.queue.append(("device", dev, cmd, params, sender))

    def queue_http(self, drv, t, method, url, headers, body):
        self.queue.append(("http", drv, t, method, url, headers, body))

    def pump(self, max_steps=20000):
        steps = 0
        while self.queue and steps < max_steps:
            steps += 1
            item = self.queue.popleft()
            kind = item[0]
            if kind == "device":
                _, dev, cmd, params, sender = item
                if dev in self.drivers:
                    self.drivers[dev].call("ExecuteCommand", cmd, {k: str(v) for k, v in (params or {}).items()})
                elif cmd in ("ON", "OFF", "SET_LEVEL"):
                    self.light_cmds.append((dev, cmd, params))
                    self.light_levels[dev] = 0 if cmd == "OFF" else 100
            elif kind == "http":
                _, drv, t, method, url, headers, body = item
                code, rbody, rheaders = self.protect.handle(method, url, headers, S(body) if body is not None else None)
                drv.g[b"C4TEST_http_done"](t, code, rbody, drv.L.table_from({B(k): B(v) for k, v in rheaders.items()}))
            elif kind == "net":
                _, drv, binding, fn, args = item
                drv.call(fn, *args)
            elif kind == "client_written":
                _, drv, cli = item
                if cli is not None:
                    drv.g[b"C4TEST_client_written"](cli)
        assert steps < max_steps, "message storm"

    def advance(self, ms):
        """Advance the shared virtual clock, firing timers in order across drivers."""
        target = self.now_ms() + ms
        while True:
            self.pump()
            best = None
            for d in self.drivers.values():
                due = d.g[b"C4TEST_due"]()
                if due is not None and due <= target and (best is None or due < best[0]):
                    best = (due, d)
            if not best:
                break
            for d in self.drivers.values():
                d.g[b"CLOCK_MS"] = max(d.g[b"CLOCK_MS"], best[0])
            best[1].g[b"C4TEST_fire_until"](best[0])
        for d in self.drivers.values():
            d.g[b"CLOCK_MS"] = target
        self.pump()

    def now_ms(self):
        return max(d.g[b"CLOCK_MS"] for d in self.drivers.values()) if self.drivers else 0

    # -- network (websocket) -----------------------------------------------
    def net_create(self, drv, binding, host):
        self.nets[(drv.id, binding)] = {"host": host, "connected": False, "buf": b"", "upgraded": False}

    def net_connect(self, drv, binding, port):
        n = self.nets[(drv.id, binding)]
        n["connected"] = True
        n["upgraded"] = False
        n["buf"] = b""
        self.queue.append(("net", drv, binding, "OnConnectionStatusChanged", (binding, port, "ONLINE")))

    def net_disconnect(self, drv, binding):
        n = self.nets.get((drv.id, binding))
        if n and n["connected"]:
            n["connected"] = False
            self.queue.append(("net", drv, binding, "OnConnectionStatusChanged", (binding, 443, "OFFLINE")))

    def net_send(self, drv, binding, data):
        n = self.nets[(drv.id, binding)]
        if not n["upgraded"]:
            text = S(data)
            assert text.startswith("GET /proxy/protect/integration/v1/subscribe/"), text
            assert "Upgrade: websocket" in text
            key = [l.split(": ", 1)[1] for l in text.split("\r\n") if l.startswith("Sec-WebSocket-Key")][0]
            apikey = [l.split(": ", 1)[1] for l in text.split("\r\n") if l.startswith("X-API-KEY")][0]
            n["path"] = text.split(" ")[1]
            if apikey != FakeProtect.API_KEY:
                self.queue.append(("net", drv, binding, "ReceivedFromNetwork", (binding, 443, b"HTTP/1.1 401 Unauthorized\r\n\r\n")))
                return
            accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            n["upgraded"] = True
            resp = ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode()
            self.queue.append(("net", drv, binding, "ReceivedFromNetwork", (binding, 443, resp)))
            return
        n["buf"] += bytes(data)
        frames, n["buf"] = parse_client_frames(n["buf"])
        for op, payload, masked in frames:
            assert masked, "client frames must be masked"
            self.ws_frames.append((drv.id, binding, op, payload))
            if op == 9 and self.auto_pong:
                self.queue.append(("net", drv, binding, "ReceivedFromNetwork", (binding, 443, ws_frame(10, payload))))

    def ws_push(self, drv, path_suffix, raw_bytes):
        for (did, binding), n in self.nets.items():
            if did == drv.id and n.get("upgraded") and n.get("path", "").endswith(path_suffix):
                self.queue.append(("net", drv, binding, "ReceivedFromNetwork", (binding, 443, raw_bytes)))
                self.pump()
                return binding
        raise AssertionError("websocket not connected: " + path_suffix)

    def ws_send_json(self, drv, path_suffix, obj):
        return self.ws_push(drv, path_suffix, ws_frame(1, json.dumps(obj)))

    # -- media server ------------------------------------------------------
    def tcp_listen(self, drv, srv, port):
        self.servers[drv.id] = (srv, port)
        drv.g[b"C4TEST_listen_ok"](srv, port)

    def client_write(self, drv, hid, data):
        c = self.clients.setdefault((drv.id, hid), {"data": b"", "closed": False, "cli": None, "drv": drv})
        c["data"] += bytes(data)
        self.queue.append(("client_written", drv, c["cli"]))

    def client_close(self, drv, hid):
        self.clients[(drv.id, hid)]["closed"] = True

    def http_get(self, drv, path):
        srv, port = self.servers[drv.id]
        cli = drv.g[b"C4TEST_accept"](srv)
        c = self.clients.setdefault((drv.id, cli[b"hid"]), {"data": b"", "closed": False, "cli": cli, "drv": drv})
        drv.g[b"C4TEST_client_read"](cli, B(f"GET {path} HTTP/1.1\r\nHost: x\r\n\r\n"))
        self.pump()
        return c

    def disconnect_client(self, c):
        c["drv"].g[b"C4TEST_client_disconnect"](c["cli"])
        self.pump()
