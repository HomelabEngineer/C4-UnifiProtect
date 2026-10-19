"""End-to-end tests for the UniFi Protect Control4 driver set (run: python3 tests/test_drivers.py)."""
import json
import os
import re
import sys
import traceback

sys.path.insert(0, os.path.dirname(__file__))
from harness import Sim, FakeProtect, ws_frame, jpeg, START_EPOCH, S, B  # noqa: E402

MASTER, CAM, CAM2, ENTRY, MOTION, ENV, SMOKE, SIREN = 10, 20, 21, 30, 40, 50, 60, 70
LIGHT_A, LIGHT_B = 900, 901
EVENTS_WS = "/subscribe/events"
DEVICES_WS = "/subscribe/devices"


def make(private=True, children=True, bind=False):
    sim = Sim()
    props = {"Console Address": "10.0.0.1", "Console Port": "443", "API Key": FakeProtect.API_KEY,
             "Media Server Port": "8641", "Media Server Address": "Auto", "Stream Transport": "RTSP",
             "Snapshot Quality": "Standard", "Live MJPEG FPS": "2", "Playback FPS": "2", "Debug Logging": "On"}
    if private:
        props.update({"Local Username": "c4", "Local Password": "pw"})
    sim.add(MASTER, "unifi_protect", props)
    if children:
        sim.add(CAM, "unifi_protect_camera", {"Doorbell Mode": "Auto", "Ring Cooldown (seconds)": "10",
                                              "Ringing Hold (seconds)": "15", "Contact Pulse (seconds)": "2",
                                              "MJPEG Fallback": "Yes", "Preferred Stream": "Auto",
                                              "Stream Codec": "H.264", "History Hours": "24", "History Events": "20",
                                              "History Filter": "All Events", "Playback Pre-Roll (seconds)": "5",
                                              "Playback Timeout (minutes)": "15", "Playback FPS": "2",
                                              "Doorbell Custom Messages": "Be right there;Please wait",
                                              "Doorbell Message Minutes": "10", "Debug Logging": "On"})
        sim.add(ENTRY, "unifi_protect_entry", {"Light Automation": "Enabled", "Linked Lights": f"{LIGHT_A},{LIGHT_B}",
                                               "Light Level (%)": "100", "Turn Lights Off": "Yes",
                                               "Lights Off Delay (seconds)": "30", "Left Open Alert (minutes)": "5",
                                               "Only Turn Off Lights It Turned On": "Yes", "Debug Logging": "On"})
        sim.add(MOTION, "unifi_protect_motion", {"Light Automation": "Enabled", "Linked Lights": f"{LIGHT_A}",
                                                 "Light Level (%)": "60", "Turn Lights Off": "Yes",
                                                 "Lights Off Delay (seconds)": "120", "Contact Closes On Detection": "Yes",
                                                 "Only Turn Off Lights It Turned On": "No"})
        sim.add(ENV, "unifi_protect_environmental", {"Leak Contact Closes When Wet": "Yes",
                                                     "Extras Temperature Unit": "Fahrenheit"})
        sim.add(SMOKE, "unifi_protect_smoke_co", {"Contact Closes On Alarm": "Yes"})
        sim.add(SIREN, "unifi_protect_siren", {"Default Duration (seconds)": "10", "Trigger Input": "Sound On Close",
                                                "Stop When Trigger Releases": "No"})
        if bind:
            for c in (CAM, ENTRY, MOTION, ENV, SMOKE, SIREN):
                sim.bindings[(c, 1)] = MASTER
    sim.start()
    sim.advance(5000)
    return sim


def select(sim, child, label_prefix):
    d = sim.drivers[child]
    lst = d.prop_lists.get("Protect Device")
    assert lst, f"no device list for {child}: {d.properties.get('Connection Status')}"
    labels = lst[0].split(",")
    match = [l for l in labels if l.startswith(label_prefix)]
    assert match, f"{label_prefix} not in {labels}"
    d.set_property("Protect Device", match[0])
    sim.pump()
    return d


def setup_all():
    sim = make()
    select(sim, CAM, "Front Door")
    select(sim, ENTRY, "Back Door")
    select(sim, MOTION, "Hall Motion")
    select(sim, ENV, "Basement Env")
    select(sim, SMOKE, "Kitchen Smoke")
    select(sim, SIREN, "Garage Siren")
    sim.advance(3000)
    return sim


# ---------------------------------------------------------------------------
def test_json_roundtrip():
    sim = Sim()
    d = sim.add(1, "unifi_protect", {})
    res = d.L.execute(B(r'''
      local U = require("up_common")
      local s = '{"a":[1,2,{"b":null}],"c":"x\\u00e9\\n","d":1.5,"e":true,"f":-3e2,"g":{}}'
      local v = assert(U.jsonDecode(s))
      assert(v.a[3].b == U.NULL)
      assert(v.c == "x\195\169\n")
      assert(v.f == -300)
      local out = U.jsonEncode(v)
      local v2 = assert(U.jsonDecode(out))
      assert(v2.a[2] == 2 and v2.d == 1.5 and v2.e == true)
      local m = { x = { y = 1, z = 2 }, list = U.array({1,2}) }
      U.merge(m, { x = { y = U.NULL }, list = U.array({3}) })
      assert(m.x.y == U.NULL and m.x.z == 2 and #m.list == 1 and m.list[1] == 3)
      assert(U.jsonEncode(U.array({})) == "[]")
      assert(U.jsonEncode({}) == "{}")
      return out
    '''))
    assert b'"a":[1,2,{"b":null}]' in res


def test_master_connects_and_websockets():
    sim = make(children=False)
    m = sim.drivers[MASTER]
    assert m.properties["Connection Status"].startswith("Connected"), m.properties["Connection Status"]
    assert m.properties["Cameras"] == "2" and m.properties["Sensors"] == "4" and m.properties["Sirens"] == "1"
    assert m.properties["Realtime Events"] == "Connected"
    assert m.properties["Recordings Access"].startswith("OK")
    assert "Console Online" in m.events
    assert m.variables["CONNECTED"] == "1"
    assert m.properties["Media Server"].startswith("Listening")
    # keepalive pings are masked client frames
    sim.advance(61000)
    assert any(op == 9 for _, _, op, _ in sim.ws_frames)


def test_bad_api_key():
    sim = Sim()
    sim.add(MASTER, "unifi_protect", {"Console Address": "10.0.0.1", "API Key": "wrong"})
    sim.start()
    m = sim.drivers[MASTER]
    assert "API key rejected" in m.properties["Connection Status"]


def test_children_auto_discover_and_select():
    sim = setup_all()
    cam = sim.drivers[CAM]
    assert "Front Door" in cam.prop_lists["Protect Device"][0]
    assert cam.properties["Connection Status"].startswith("Connected - Front Door"), cam.properties["Connection Status"]
    assert cam.properties["Device Type"] == "Doorbell"
    # entry filter hides cameras and non-entry sensors
    entry = sim.drivers[ENTRY]
    labels = entry.prop_lists["Protect Device"][0].split(",")
    assert any(l.startswith("Back Door") for l in labels) and not any(l.startswith("Hall Motion") for l in labels)
    assert sim.drivers[MASTER].properties["Children Connected"] == "6"


def test_children_via_binding():
    sim = make(bind=True)
    select(sim, CAM, "Driveway")
    assert sim.drivers[CAM].properties["Connection Status"].startswith("Connected - Driveway")


def test_stream_urls():
    sim = setup_all()
    cam = sim.drivers[CAM]
    xml = S(cam.call("UIRequest", "GET_STREAM_URLS", {"RESOLUTION": "1920x1080", "CODEC": "h264,mjpeg"}))
    assert 'url="rtsp://10.0.0.1:7447/cam1high"' in xml, xml
    assert xml.index("cam1high") < xml.index("cam1medium")
    assert "enableSrtp" not in xml
    assert 'codec="mjpeg"' in xml and "/live/cam1.mjpg" in xml
    tile = S(cam.call("UIRequest", "GET_STREAM_URLS", {"RESOLUTION": "640x360"}))
    assert tile.index("cam1low") < tile.index("cam1high")
    snaps = S(cam.call("UIRequest", "GET_SNAPSHOT_URLS", {}))
    assert re.search(r'http://192\.168\.1\.50:8641/up/\w+/snap/cam1\.jpg', snaps), snaps
    # RTSPS mode
    sim.drivers[MASTER].set_property("Stream Transport", "RTSPS")
    sim.pump()
    xml = S(cam.call("UIRequest", "GET_STREAM_URLS", {}))
    assert "rtsps://10.0.0.1:7441/cam1high" in xml
    assert cam.proxy_cmds(5001, "DYNAMIC_URLS_CHANGED")


def test_doorbell_ring_flow():
    sim = setup_all()
    cam, master = sim.drivers[CAM], sim.drivers[MASTER]
    cam.events.clear()
    sim.ws_send_json(master, EVENTS_WS, {"type": "add", "item": {"id": "evR1", "modelKey": "event", "type": "ring",
                                                                 "start": START_EPOCH * 1000, "end": None, "device": "cam1"}})
    assert cam.events.count("Doorbell Pressed") == 1, cam.events
    assert cam.variables["RINGING"] == "1"
    assert "Any Doorbell Ring" in master.events and master.variables["LAST_RING_CAMERA"] == "Front Door"
    closed = cam.proxy_cmds(100, "CLOSED")
    assert closed, "doorbell contact pulse"
    assert cam.variables["LAST_EVENT_THUMBNAIL_URL"].endswith("/thumb/evR1.jpg")
    # second press inside cooldown -> no new event
    sim.advance(3000)
    sim.ws_send_json(master, EVENTS_WS, {"type": "add", "item": {"id": "evR2", "modelKey": "event", "type": "ring",
                                                                 "start": START_EPOCH * 1000, "device": "cam1"}})
    assert cam.events.count("Doorbell Pressed") == 1
    assert cam.proxy_cmds(100, "OPENED"), "pulse released"
    sim.advance(20000)
    assert cam.variables["RINGING"] == "0"
    sim.ws_send_json(master, EVENTS_WS, {"type": "add", "item": {"id": "evR3", "modelKey": "event", "type": "ring",
                                                                 "start": START_EPOCH * 1000, "device": "cam1"}})
    assert cam.events.count("Doorbell Pressed") == 2
    # event for another camera does not reach this child
    sim.ws_send_json(master, EVENTS_WS, {"type": "add", "item": {"id": "evX", "modelKey": "event", "type": "ring",
                                                                 "start": START_EPOCH * 1000, "device": "cam2"}})
    assert cam.events.count("Doorbell Pressed") == 2


def test_motion_and_smart_detections():
    sim = setup_all()
    cam, master = sim.drivers[CAM], sim.drivers[MASTER]
    cam.events.clear()
    sim.ws_send_json(master, EVENTS_WS, {"type": "add", "item": {"id": "m1", "modelKey": "event", "type": "motion",
                                                                 "start": 1, "device": "cam1"}})
    assert "Motion Started" in cam.events and cam.variables["MOTION"] == "1"
    # update without device/type: routed by event id
    sim.ws_send_json(master, EVENTS_WS, {"type": "update", "item": {"id": "m1", "modelKey": "event", "end": 2}})
    assert "Motion Ended" in cam.events and cam.variables["MOTION"] == "0"
    sim.ws_send_json(master, EVENTS_WS, {"type": "add", "item": {"id": "s1", "modelKey": "event", "type": "smartDetectZone",
                                                                 "smartDetectTypes": ["person", "vehicle"], "start": 3, "device": "cam1"}})
    assert "Person Detected" in cam.events and "Vehicle Detected" in cam.events and "Smart Detection" in cam.events
    assert cam.variables["LAST_DETECTION"] == "Person/Vehicle"
    sim.ws_send_json(master, EVENTS_WS, {"type": "add", "item": {"id": "a1", "modelKey": "event", "type": "smartAudioDetect",
                                                                 "smartDetectTypes": ["alrmSmoke"], "start": 3, "device": "cam1"}})
    assert "Audio Detected" in cam.events


def test_history_and_playback():
    sim = setup_all()
    cam = sim.drivers[CAM]
    setup = [p for p in cam.proxy if p[1] == "EXTRAS_SETUP_CHANGED"][-1][2]["XML"]
    assert "Doorbell" in setup and "Person" in setup, setup
    assert 'value="ev3"' in setup and "ev9" not in setup  # cam2 event filtered out
    cam.call("ReceivedFromProxy", 5001, "UP_X_EVENT", {"value": "ev3", "id": "events"})
    sim.pump()
    xml = S(cam.call("UIRequest", "GET_STREAM_URLS", {}))
    start = (START_EPOCH - 600) * 1000 - 5000
    assert f"/play/cam1/{start}.mjpg" in xml and "rtsp://" not in xml, xml
    assert cam.variables["PLAYBACK_ACTIVE"] == "1"
    assert "Playback Started" in cam.events
    ack = [p for p in cam.proxy if p[1] == "EXTRAS_STATE_CHANGED"][-1][2]["XML"]
    assert 'id="events"' in ack
    # jump back + speed
    cam.call("ReceivedFromProxy", 5001, "UP_X_SPEED", {"value": "4"})
    cam.call("ReceivedFromProxy", 5001, "UP_X_JUMP", {"value": "10"})
    sim.pump()
    xml = S(cam.call("UIRequest", "GET_STREAM_URLS", {}))
    assert "speed=4" in xml
    # back to live
    cam.call("ReceivedFromProxy", 5001, "UP_X_LIVE", {})
    xml = S(cam.call("UIRequest", "GET_STREAM_URLS", {}))
    assert "rtsp://10.0.0.1:7447/cam1high" in xml
    assert cam.variables["PLAYBACK_ACTIVE"] == "0"
    # playback auto-timeout
    cam.call("ExecuteCommand", "Play Last Ring", {})
    sim.pump()
    assert cam.variables["PLAYBACK_ACTIVE"] == "1"
    sim.advance(16 * 60 * 1000)
    assert cam.variables["PLAYBACK_ACTIVE"] == "0"


def test_history_without_private_api():
    sim = make(private=False)
    cam = select(sim, CAM, "Front Door")
    sim.advance(3000)
    setup = [p for p in cam.proxy if p[1] == "EXTRAS_SETUP_CHANGED"][-1][2]["XML"]
    assert "Add a local Protect user" in setup
    assert sim.drivers[MASTER].properties["Recordings Access"].startswith("Disabled")


def test_media_server():
    sim = setup_all()
    m = sim.drivers[MASTER]
    token = re.search(r"/up/(\w+)/", sim.drivers[CAM].variables["SNAPSHOT_URL"]).group(1)
    c = sim.http_get(m, f"/up/{token}/snap/cam1.jpg")
    assert c["data"].startswith(b"HTTP/1.0 200 OK") and b"live-cam1" in c["data"] and c["closed"]
    bad = sim.http_get(m, "/up/wrongtoken/snap/cam1.jpg")
    assert bad["data"].startswith(b"HTTP/1.0 404")
    thumb = sim.http_get(m, f"/up/{token}/thumb/ev3.jpg")
    assert b"thumb-ev3" in thumb["data"]
    frame = sim.http_get(m, f"/up/{token}/frame/cam1/1789999000000.jpg")
    assert b"rec-cam1-1789999000000" in frame["data"]
    # live MJPEG: several frames over time, then client disconnect stops the pump
    live = sim.http_get(m, f"/up/{token}/live/cam1.mjpg?fps=2")
    sim.advance(2100)
    assert live["data"].startswith(b"HTTP/1.0 200 OK") and b"multipart/x-mixed-replace" in live["data"]
    assert live["data"].count(b"--upframe") >= 3, live["data"].count(b"--upframe")
    sim.disconnect_client(live)
    n = live["data"].count(b"--upframe")
    sim.advance(3000)
    assert live["data"].count(b"--upframe") == n
    # playback MJPEG: timestamps advance by interval * speed
    t0 = (START_EPOCH - 600) * 1000
    play = sim.http_get(m, f"/up/{token}/play/cam1/{t0}.mjpg?speed=2&fps=2")
    sim.advance(1600)
    stamps = [int(x) for x in re.findall(rb"rec-cam1-(\d+)", play["data"])]
    assert len(stamps) >= 3 and stamps[0] == t0 and stamps[1] - stamps[0] == 1000, stamps
    sim.disconnect_client(play)
    st = sim.http_get(m, f"/up/{token}/status")
    assert b"clients:" in st["data"]


def test_entry_sensor_lights():
    sim = setup_all()
    entry, master = sim.drivers[ENTRY], sim.drivers[MASTER]
    sim.light_levels[LIGHT_B] = 100  # LIGHT_B already on -> must be left on
    entry.events.clear()
    sim.ws_send_json(master, DEVICES_WS, {"type": "update", "item": {"id": "sen1", "modelKey": "sensor",
                                                                     "isOpened": True, "openStatusChangedAt": 5}})
    assert "Opened" in entry.events and entry.variables["IS_OPEN"] == "1"
    assert entry.proxy_cmds(100, "OPENED")
    assert (LIGHT_A, "ON", {}) in sim.light_cmds and (LIGHT_B, "ON", {}) in sim.light_cmds
    sim.ws_send_json(master, DEVICES_WS, {"type": "update", "item": {"id": "sen1", "modelKey": "sensor", "isOpened": False}})
    assert "Closed" in entry.events and entry.proxy_cmds(100, "CLOSED")
    sim.advance(10000)
    assert not any(c[1] == "OFF" for c in sim.light_cmds), "delay not honored"
    sim.advance(25000)
    offs = [c[0] for c in sim.light_cmds if c[1] == "OFF"]
    assert offs == [LIGHT_A], offs
    # left open alert
    sim.ws_send_json(master, EVENTS_WS, {"type": "add", "item": {"id": "o1", "modelKey": "event", "type": "sensorOpened",
                                                                 "start": 1, "device": "sen1"}})
    sim.advance(5 * 60 * 1000 + 1000)
    assert "Left Open" in entry.events
    # automation disabled -> no light commands
    entry.call("ExecuteCommand", "Disable Light Automation", {})
    sim.light_cmds.clear()
    sim.ws_send_json(master, DEVICES_WS, {"type": "update", "item": {"id": "sen1", "modelKey": "sensor", "isOpened": False}})
    sim.ws_send_json(master, DEVICES_WS, {"type": "update", "item": {"id": "sen1", "modelKey": "sensor", "isOpened": True}})
    assert not sim.light_cmds
    # tamper + battery
    sim.ws_send_json(master, DEVICES_WS, {"type": "update", "item": {"id": "sen1", "modelKey": "sensor",
                                                                     "tamperingDetectedAt": 99, "batteryStatus": {"percentage": 9, "isLow": True}}})
    assert "Tamper Detected" in entry.events and "Battery Low" in entry.events
    assert entry.proxy_cmds(101, "CLOSED")
    assert entry.properties["Battery"] == "9% (LOW)"


def test_motion_sensor():
    sim = setup_all()
    mo, master = sim.drivers[MOTION], sim.drivers[MASTER]
    mo.events.clear()
    sim.ws_send_json(master, DEVICES_WS, {"type": "update", "item": {"id": "sen2", "modelKey": "sensor", "isMotionDetected": True}})
    assert "Motion Detected" in mo.events and mo.proxy_cmds(100, "CLOSED")
    assert (LIGHT_A, "SET_LEVEL", {"LEVEL": "60"}) in sim.light_cmds
    sim.ws_send_json(master, DEVICES_WS, {"type": "update", "item": {"id": "sen2", "modelKey": "sensor", "isMotionDetected": False}})
    assert "Motion Cleared" in mo.events
    sim.advance(60000)
    sim.ws_send_json(master, DEVICES_WS, {"type": "update", "item": {"id": "sen2", "modelKey": "sensor", "isMotionDetected": True}})
    sim.advance(130000)
    assert not any(c[1] == "OFF" for c in sim.light_cmds), "motion re-trigger must cancel pending off"
    sim.ws_send_json(master, DEVICES_WS, {"type": "update", "item": {"id": "sen2", "modelKey": "sensor", "isMotionDetected": False}})
    sim.advance(121000)
    assert any(c == (LIGHT_A, "OFF", {}) for c in sim.light_cmds)
    sim.ws_send_json(master, EVENTS_WS, {"type": "add", "item": {"id": "g1", "modelKey": "event", "type": "sensorAlarm",
                                                                 "metadata": {"alarmType": {"text": "glassBreak"}}, "start": 1, "device": "sen2"}})
    assert "Glass Break Detected" in mo.events
    assert mo.variables["TEMPERATURE_F"] == "69.8"


def test_environmental_sensor():
    sim = setup_all()
    env, master = sim.drivers[ENV], sim.drivers[MASTER]
    temps = env.proxy_cmds(5001, "TEMPERATURE_CHANGED")
    assert temps and temps[-1][2] == {"TEMPERATURE": "18.5", "SCALE": "C"}, temps
    out = env.proxy_cmds(5010, "VALUE_CHANGED")[-1][2]
    assert out == {"CELSIUS": "18.5", "FAHRENHEIT": "65.3"}, out
    assert env.proxy_cmds(5012, "VALUE_CHANGED")[-1][2] == {"VALUE": "55"}
    assert env.proxy_cmds(5001, "HUMIDITY_CHANGED")[-1][2] == {"HUMIDITY": "55"}
    env.events.clear()
    sim.ws_send_json(master, DEVICES_WS, {"type": "update", "item": {"id": "sen3", "modelKey": "sensor",
                                                                     "stats": {"temperature": {"value": 31.2, "status": "high"}}}})
    assert "Temperature High" in env.events and "Temperature Changed" in env.events
    assert env.variables["TEMPERATURE_F"] == "88.2"
    sim.ws_send_json(master, DEVICES_WS, {"type": "update", "item": {"id": "sen3", "modelKey": "sensor", "externalLeakDetectedAt": 123}})
    assert "Leak Detected" in env.events and env.proxy_cmds(100, "CLOSED")
    assert env.variables["EXTERNAL_LEAK_DETECTED"] == "1"
    extras = [p for p in env.proxy if p[1] == "EXTRAS_SETUP_CHANGED"][-1][2]["XML"]
    assert "LEAK DETECTED" in extras and "88.2 F" in extras
    sim.ws_send_json(master, DEVICES_WS, {"type": "update", "item": {"id": "sen3", "modelKey": "sensor", "externalLeakDetectedAt": None}})
    assert "Leak Cleared" in env.events and env.proxy_cmds(100, "OPENED")
    # rebinding the temperature output resends the value
    n = len(env.proxy_cmds(5010, "VALUE_CHANGED"))
    env.call("OnBindingChanged", 5010, "TEMPERATURE_VALUE", True)
    sim.advance(1000)
    assert len(env.proxy_cmds(5010, "VALUE_CHANGED")) == n + 1


def test_smoke_alarm():
    sim = setup_all()
    sm, master = sim.drivers[SMOKE], sim.drivers[MASTER]
    sm.events.clear()
    sim.ws_send_json(master, EVENTS_WS, {"type": "add", "item": {"id": "al1", "modelKey": "event", "type": "sensorAlarm",
                                                                 "metadata": {"alarmType": {"text": "CO"}}, "start": 1, "end": None, "device": "sen4"}})
    assert "CO Alarm" in sm.events and sm.variables["CO_ALARM"] == "1" and sm.proxy_cmds(101, "CLOSED")
    sim.ws_send_json(master, EVENTS_WS, {"type": "update", "item": {"id": "al1", "modelKey": "event", "end": 5}})
    assert "Alarm Cleared" in sm.events and sm.variables["CO_ALARM"] == "0"
    sim.ws_send_json(master, EVENTS_WS, {"type": "add", "item": {"id": "t1", "modelKey": "event", "type": "sensorSmokeTest",
                                                                 "start": 1, "device": "sen4"}})
    assert "Alarm Test" in sm.events


def test_siren():
    sim = setup_all()
    si = sim.drivers[SIREN]
    si.call("ExecuteCommand", "Sound Siren", {"Duration": "20"})
    sim.pump()
    calls = [c for c in sim.protect.calls if "/v1/sirens/sir1/play" in c[1]]
    assert calls and json.loads(calls[-1][2]) == {"duration": 20}
    assert si.variables["SIREN_ACTIVE"] == "1" and "Siren Started" in si.events
    sim.advance(23000)
    assert si.variables["SIREN_ACTIVE"] == "0"
    si.call("ReceivedFromProxy", 200, "CLOSED", {})
    sim.pump()
    assert json.loads([c for c in sim.protect.calls if "/play" in c[1]][-1][2]) == {"duration": 10}


def test_doorbell_lcd_and_ptz():
    sim = setup_all()
    cam = sim.drivers[CAM]
    cam.call("ExecuteCommand", "Set Doorbell Message", {"Message": "Back in five minutes, thank you!", "Minutes": "0"})
    sim.pump()
    body = json.loads([c for c in sim.protect.calls if c[0] == "PATCH"][-1][2])
    assert body["lcdMessage"]["type"] == "CUSTOM_MESSAGE" and len(body["lcdMessage"]["text"]) <= 30
    assert body["lcdMessage"]["resetAt"] is None
    cam.call("ReceivedFromProxy", 5001, "UP_X_LCD", {"value": "DO_NOT_DISTURB"})
    sim.pump()
    body = json.loads([c for c in sim.protect.calls if c[0] == "PATCH"][-1][2])
    assert body["lcdMessage"]["type"] == "DO_NOT_DISTURB" and body["lcdMessage"]["resetAt"] > START_EPOCH * 1000
    cam.call("ExecuteCommand", "PTZ Go To Preset", {"Slot": "2"})
    sim.pump()
    assert any("/ptz/goto/2" in c[1] for c in sim.protect.calls)


def test_websocket_framing_and_reconnect():
    sim = setup_all()
    master, cam = sim.drivers[MASTER], sim.drivers[CAM]
    cam.events.clear()
    payload = json.dumps({"type": "add", "item": {"id": "big", "modelKey": "event", "type": "smartDetectZone",
                                                  "smartDetectTypes": ["animal"], "start": 1, "device": "cam1",
                                                  "pad": "x" * 70000}}).encode()
    raw = ws_frame(1, payload[:30000], fin=False) + ws_frame(0, payload[30000:], fin=True)
    # deliver in odd-sized TCP chunks, interleaved with a ping
    raw = ws_frame(9, b"hi") + raw
    for i in range(0, len(raw), 4093):
        sim.ws_push(master, EVENTS_WS, raw[i:i + 4093])
    assert "Animal Detected" in cam.events
    assert any(op == 0xA and data == b"hi" for _, _, op, data in sim.ws_frames), "pong"
    # server closes -> reconnect after backoff
    sim.ws_push(master, EVENTS_WS, ws_frame(8, b""))
    assert master.properties["Realtime Events"].startswith("Reconnecting")
    sim.advance(6000)
    assert master.properties["Realtime Events"] == "Connected"
    sim.ws_send_json(master, EVENTS_WS, {"type": "add", "item": {"id": "r9", "modelKey": "event", "type": "ring",
                                                                 "start": 1, "device": "cam1"}})
    assert "Doorbell Pressed" in cam.events


def test_websocket_dead_peer_detected():
    sim = setup_all()
    master = sim.drivers[MASTER]
    sim.auto_pong = False          # half-open socket: console stops answering
    sim.advance(5 * 60 * 1000)
    assert any("no traffic" in l for l in master.logs), "liveness check did not trip"
    sim.auto_pong = True
    sim.advance(70 * 1000)
    assert master.properties["Realtime Events"] == "Connected"


def test_media_server_limits_and_errors():
    sim = setup_all()
    m = sim.drivers[MASTER]
    token = re.search(r"/up/(\w+)/", sim.drivers[CAM].variables["SNAPSHOT_URL"]).group(1)
    streams = [sim.http_get(m, f"/up/{token}/live/cam1.mjpg") for _ in range(24)]
    extra = sim.http_get(m, f"/up/{token}/snap/cam1.jpg")
    assert extra["data"].startswith(b"HTTP/1.0 503"), extra["data"][:40]
    for c in streams:
        sim.disconnect_client(c)
    ok = sim.http_get(m, f"/up/{token}/snap/cam1.jpg")
    assert ok["data"].startswith(b"HTTP/1.0 200")
    post = sim.http_get(m, f"/up/{token}/nothing")
    assert post["data"].startswith(b"HTTP/1.0 404")


def test_master_restart_children_rejoin():
    sim = setup_all()
    # replace the master with a fresh instance (driver update / controller reboot)
    del sim.drivers[MASTER]
    sim.add(MASTER, "unifi_protect", {"Console Address": "10.0.0.1", "API Key": FakeProtect.API_KEY,
                                       "Local Username": "c4", "Local Password": "pw"})
    sim.start([MASTER])
    sim.advance(6000)
    assert sim.drivers[MASTER].properties["Children Connected"] == "6"
    cam = sim.drivers[CAM]
    cam.events.clear()
    sim.ws_send_json(sim.drivers[MASTER], EVENTS_WS, {"type": "add", "item": {"id": "z", "modelKey": "event",
                                                                              "type": "ring", "start": 1, "device": "cam1"}})
    assert "Doorbell Pressed" in cam.events


def test_private_session_expiry_relogin():
    sim = setup_all()
    before = sim.protect.login_count
    sim.protect.cookie = "TOKEN=rotated"
    cam = sim.drivers[CAM]
    cam.call("ExecuteCommand", "Refresh Event History", {})
    sim.pump()
    assert sim.protect.login_count == before + 1


def test_device_removed_and_added():
    sim = setup_all()
    master = sim.drivers[MASTER]
    sim.ws_send_json(master, DEVICES_WS, {"type": "add", "item": dict(sim.protect.sensors[0], id="sen9", name="Garage Door")})
    sim.advance(3000)
    assert "Garage Door" in sim.drivers[ENTRY].prop_lists["Protect Device"][0]
    sim.ws_send_json(master, DEVICES_WS, {"type": "remove", "item": {"id": "sen9", "modelKey": "sensor"}})
    sim.advance(3000)
    assert "Garage Door" not in sim.drivers[ENTRY].prop_lists["Protect Device"][0]


TESTS = [v for k, v in sorted(globals().items()) if k.startswith("test_")]

if __name__ == "__main__":
    failed = 0
    for t in TESTS:
        try:
            t()
            print("PASS", t.__name__)
        except Exception:
            failed += 1
            print("FAIL", t.__name__)
            traceback.print_exc()
    print(f"{len(TESTS) - failed}/{len(TESTS)} passed")
    sys.exit(1 if failed else 0)
