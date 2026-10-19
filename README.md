# UniFi Protect for Control4

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![Control4 OS](https://img.shields.io/badge/Control4%20OS-3.3%2B-orange.svg)
![UniFi Protect](https://img.shields.io/badge/UniFi%20Protect-6.0%2B-1f6fd1.svg)

Open-source Control4 drivers for UniFi Protect: one master driver that talks to the console,
plus child drivers for cameras/doorbells and SuperLink sensors.

| Package | What it is |
|---|---|
| `unifi_protect.c4z` | **Master.** API key + optional local user, realtime event websockets, device registry, media server |
| `unifi_protect_camera.c4z` | **Camera / Doorbell.** Live RTSP, snapshots, event history + recorded playback in the Extras tab, doorbell ring events, LCD messages, PTZ presets |
| `unifi_protect_entry.c4z` | **Entry Sensor.** Door/window contact output, lights on when opened / off after closing, left-open alert |
| `unifi_protect_motion.c4z` | **Motion / Glass Break / All-In-One.** Motion + glass break outputs, motion lighting |
| `unifi_protect_environmental.c4z` | **Environmental.** Comfort tile, `TEMPERATURE_VALUE` / `HUMIDITY_VALUE` outputs, water leak contact |
| `unifi_protect_smoke_co.c4z` | **Smoke & CO Alarm.** Smoke / CO contact outputs and events |
| `unifi_protect_siren.c4z` | **Siren.** Sound / stop / test, contact trigger input |

## How it works

```
                    Integration API (API key)                  Private API (local user, optional)
UniFi OS console ── REST: cameras, sensors, sirens, RTSPS ──┐  ┌─ /events, recording-snapshot, thumbnails
   (Protect)     ── WS:   subscribe/events, subscribe/devices│  │
                                                             ▼  ▼
                                               UniFi Protect master driver
                                     (device registry, routing, media server :8641)
                                    /        |          |           |         \
                              Camera    Entry     Motion   Environmental  Smoke/CO  Siren
                               │ RTSP from console to Navigators
                               │ snapshots / MJPEG / playback from the master's media server
```

* **Realtime:** both Integration API websockets (events + device deltas) stay open with pings and
  automatic reconnect + REST resync, so rings and door openings reach Control4 immediately.
* **Video:** RTSPS streams are created through the API, offered to Navigators as RTSP (7447) or RTSPS (7441)
  via the camera proxy's dynamic stream API (High/Medium/Low picked by tile size), with an MJPEG fallback.
* **History & recordings:** Protect only exposes event history and recorded footage through its private
  API, which needs a local login (API keys are rejected there). The camera's Extras tab lists recent events;
  picking one, or a "jump back" time, switches the camera view to playback. Playback is MJPEG assembled from
  recorded frames on the NVR timeline (1–5 fps, no audio) by the master's media server, then "Back to Live".
* **Doorbells:** ring → `Doorbell Pressed` event (with cooldown so announcements don't stack),
  `RINGING` / `LAST_RING` / `LAST_EVENT_THUMBNAIL_URL` variables, contact pulse output.

## Installation

1. Copy the `.c4z` files from `dist/` into Composer Pro's driver folder and add **UniFi Protect** to the project.
2. UniFi OS → *Settings › Control Plane › Integrations* → create an API key. Enter `Console Address` and `API Key`.
3. Optional (history + playback): create a **local** UniFi OS user with Protect view access and enter
   `Local Username` / `Local Password`.
4. Add child drivers to rooms and choose the device in each child's **Protect Device** property.
   Children find the master automatically when there is one; with several consoles, bind the child's
   `UniFi Protect` connection to its master.

### Doorbell announcement

Programming → the camera driver → **When Doorbell Pressed** → drag in your Announcement. `Ring Cooldown (seconds)`
stops repeated presses from re-announcing.

### Door opens → lights on

On the Entry Sensor set `Linked Lights` (multi-select), `Light Level`, `Lights Off Delay` and whether to turn them off.
Lights that were already on are left alone. Use programming with the `Opened` / `Closed` events for anything conditional.

### Temperature / humidity into Control4

Bind the Environmental driver's `Temperature` (TEMPERATURE_VALUE) and `Humidity` (HUMIDITY_VALUE) outputs to a thermostat's
remote sensor input or any value consumer. The driver also shows a sensor-only Comfort tile and lists readings on its Extras tab.

## Building from source

```
pip install lupa pillow
python3 build.py            # manifests, icons, docs, 23 end-to-end tests, dist/*.c4z
python3 build.py --no-test
```

`tests/harness.py` runs every driver in its own Lua 5.1 state against a stubbed Control4 API, a fake Protect console
(REST + websocket framing, private login, recordings) and fake Navigator HTTP clients for the media server.

## Project layout

```
common/up_common.lua          shared library (JSON w/ null, HTTP, timers, child framework, light automation)
drivers/<driver>/driver.lua   driver logic
drivers/<driver>/driver.xml   manifest (sensor manifests generated by tools/gen_sensor_xml.py)
tools/                        manifest generator, icon generator, documentation pages
tests/                        harness + end-to-end tests
```

## Status and known limitations

* Tested off-controller only (Lua 5.1 harness); needs on-controller verification in Composer.
* Recorded playback is a low-frame-rate MJPEG preview, not full-motion video with audio.
* Remote Navigators need network reach to the console (RTSP) and controller (media server), e.g. via VPN.
* The Smoke/CO driver is a convenience integration, not a listed life-safety signalling path.

## License

MIT — see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md). Not affiliated with Ubiquiti Inc. or Snap One, LLC.
