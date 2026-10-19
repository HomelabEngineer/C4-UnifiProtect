"""Composer "Documentation" tab content for every driver (rendered by build.py)."""

STYLE = """
<style>
 body{font-family:Segoe UI,Helvetica,Arial,sans-serif;font-size:13px;line-height:1.45;color:#1d2733;margin:16px;max-width:900px}
 h1{font-size:20px;margin:0 0 4px} h2{font-size:15px;margin:20px 0 6px;border-bottom:1px solid #d5dde6;padding-bottom:3px}
 h3{font-size:13px;margin:14px 0 4px} code{background:#eef2f6;padding:1px 4px;border-radius:3px}
 table{border-collapse:collapse;margin:6px 0} td,th{border:1px solid #d5dde6;padding:4px 8px;text-align:left;vertical-align:top}
 th{background:#f2f5f8} .note{background:#fff7e0;border:1px solid #f0d58a;padding:8px 10px;border-radius:4px}
 .sub{color:#5b6b7c}
</style>
"""

HEADER = """<!DOCTYPE html><html><head><meta charset="utf-8"><title>{title}</title>{style}</head><body>
<h1>{title}</h1>
<div class="sub">UniFi Protect for Control4 &middot; version {version} &middot; Open Source (MIT). Not affiliated with Ubiquiti Inc. or Snap One LLC.</div>
"""

FOOTER = "</body></html>"

FAMILY = """
<h2>The driver set</h2>
<table>
<tr><th>Driver</th><th>Purpose</th></tr>
<tr><td><b>UniFi Protect</b> (unifi_protect.c4z)</td><td>Master. Connects to the console, keeps the realtime event streams open and serves all children. Add one per Protect console.</td></tr>
<tr><td><b>UniFi Protect Camera</b></td><td>One per camera or doorbell. Live video, snapshots, event history and recorded playback, doorbell ring events.</td></tr>
<tr><td><b>UniFi Protect Entry Sensor</b></td><td>SuperLink Entry / Recessed Entry. Door contact output, light automation.</td></tr>
<tr><td><b>UniFi Protect Motion Sensor</b></td><td>SuperLink Motion, Glass Break and All-In-One. Motion / glass break outputs, light automation.</td></tr>
<tr><td><b>UniFi Protect Environmental Sensor</b></td><td>SuperLink Environmental. Temperature and humidity (Comfort tile + value outputs), water leak.</td></tr>
<tr><td><b>UniFi Protect Smoke CO Alarm</b></td><td>SuperLink Smoke and CO Alarm. Smoke / CO outputs and events.</td></tr>
<tr><td><b>UniFi Protect Siren</b></td><td>SuperLink Siren / Siren PoE. Sound, stop and test from programming.</td></tr>
</table>
<p>Child drivers find the master automatically when there is exactly one master in the project.
With several consoles, bind each child's <code>UniFi Protect</code> connection to the right master.
Then pick the device in the child's <code>Protect Device</code> property.</p>
"""

MASTER = """
<h2>Setup</h2>
<ol>
<li><b>API key</b> &ndash; In UniFi OS open <i>Settings &rsaquo; Control Plane &rsaquo; Integrations</i> and create an API key.
Paste it into <code>API Key</code>. Requires UniFi Protect 6.0 or newer.</li>
<li>Set <code>Console Address</code> to the console / NVR IP (port 443 unless changed).
<code>Connection Status</code> shows <i>Connected - Protect x.y.z</i> and <code>Realtime Events</code> shows <i>Connected</i>.</li>
<li><b>History and playback (optional)</b> &ndash; Create a <i>local</i> UniFi OS user with view access to Protect
(not a UI.com cloud account with MFA) and enter it in <code>Local Username</code> / <code>Local Password</code>.
Protect only offers event history and recorded footage through this login; API keys cannot read them.
<code>Recordings Access</code> confirms it works.</li>
<li>Add the child drivers you need (see below).</li>
</ol>

<h2>Video and the media server</h2>
<p>Live video goes straight from the console to Navigators over RTSP (port 7447, or RTSPS 7441).
The master turns on the RTSPS streams for each camera through the Integration API automatically.</p>
<p>Snapshots, the MJPEG fallback stream and recorded playback come from a small media server inside the master
driver (default port <code>8641</code> on the controller). Navigators never need Protect credentials. URLs carry a random
access token. If the controller has more than one address, set <code>Media Server Address</code> to the one Navigators can reach.</p>
<div class="note">Remote (off-site) Navigators can only show video if they can reach the console and controller addresses,
for example over a VPN.</div>

<h2>Properties</h2>
<table>
<tr><th>Property</th><th>Notes</th></tr>
<tr><td>Stream Transport</td><td>RTSP works on every Navigator. RTSPS is encrypted but not supported by every client.</td></tr>
<tr><td>Snapshot Quality</td><td>High asks Protect for full-resolution snapshots (slower).</td></tr>
<tr><td>Live MJPEG FPS / Playback FPS</td><td>Frame rate of the MJPEG fallback and of recorded playback (1-5).</td></tr>
<tr><td>Media Server Port</td><td>TCP port on the controller (default 8641).</td></tr>
</table>

<h2>Programming</h2>
<p>Events: <i>Console Online</i>, <i>Console Offline</i>, <i>Any Doorbell Ring</i> (variable <code>LAST_RING_CAMERA</code> holds the doorbell name).</p>
<p>Actions: Reconnect, Refresh Devices, Recreate Camera Streams, Find Child Drivers, Print Devices to Lua Output.</p>
"""

CAMERA = """
<h2>Setup</h2>
<ol>
<li>Add the driver to the room where the camera should appear (Navigator <i>Cameras</i>).</li>
<li>Pick the camera or doorbell in <code>Protect Device</code>. <code>Connection Status</code> turns to <i>Connected</i>.</li>
<li>Optional: bind the <code>Doorbell Button</code>, <code>Motion</code> or <code>Smart Detection</code> contact outputs to stock
contact drivers (for example the Control4 <i>Doorbell</i> contact driver) if you want their icons and history.</li>
</ol>

<h2>Live video</h2>
<p>Navigators receive High, Medium and Low RTSP streams and pick the right one by tile size
(<code>Preferred Stream</code> = Auto). A controller-served MJPEG stream is offered as a fallback.
Set <code>Stream Codec</code> to H.265 only when the camera uses Enhanced Encoding in Protect.</p>

<h2>Event history and recorded playback</h2>
<p>Requires <code>Local Username</code>/<code>Local Password</code> on the master. Open the camera in Navigator, then the <b>Extras</b> tab:</p>
<ul>
<li><b>Play Recent Event</b> &ndash; the latest rings, motion and smart detections (window and count set by <code>History Hours</code>,
<code>History Events</code>, <code>History Filter</code>). Picking one switches the camera view to the recording, starting
<code>Playback Pre-Roll</code> seconds before the event.</li>
<li><b>Play From</b> &ndash; jump back 30 seconds to 24 hours.</li>
<li><b>Playback Speed</b> &ndash; 1x, 2x, 4x or 8x.</li>
<li><b>Back to Live</b> &ndash; return to the live stream. Playback also returns to live after <code>Playback Timeout</code>.</li>
</ul>
<p>Playback is delivered as MJPEG built from frames on the Protect timeline, so it runs at a low frame rate (Playback FPS) without audio.
It is meant for checking what happened, not as a replacement for the Protect app's full player.
Re-open the camera view if a Navigator keeps showing the previous stream.</p>

<h2>Doorbells and announcements</h2>
<p>Doorbells are detected automatically (or set <code>Doorbell Mode</code>). On every ring the driver:</p>
<ul>
<li>fires the <b>Doorbell Pressed</b> event (repeat presses inside <code>Ring Cooldown</code> are ignored so announcements do not stack up),</li>
<li>sets <code>RINGING</code> true for <code>Ringing Hold</code> seconds and updates <code>LAST_RING</code>, <code>RING_COUNT</code> and <code>LAST_EVENT_THUMBNAIL_URL</code>,</li>
<li>pulses the <code>Doorbell Button</code> contact output.</li>
</ul>
<p><b>Announcement example</b>: Programming &rsaquo; select this camera &rsaquo; <i>When Doorbell Pressed</i> &rsaquo; drag your
<i>Announcement</i> (Agents &rsaquo; Announcements, e.g. "Someone is at the front door") into the script. Add a camera pop-up or
push notification in the same script if you like.</p>
<p>Doorbell display messages: Extras &rsaquo; Doorbell Display Message (presets plus <code>Doorbell Custom Messages</code>),
or the programming commands <i>Set Doorbell Message</i>, <i>Doorbell Message Preset</i>, <i>Clear Doorbell Message</i>.</p>

<h2>Programming</h2>
<table>
<tr><th>Events</th><td>Doorbell Pressed, Motion Started, Motion Ended, Person / Vehicle / Animal / Package / License Plate / Face Detected,
Line Crossed, Audio Detected, Smart Detection, Camera Online, Camera Offline, Playback Started, Playback Stopped</td></tr>
<tr><th>Commands</th><td>Go Live, Play Last Event, Play Last Ring, Play Minutes Ago, Refresh Event History, Set Doorbell Message,
Doorbell Message Preset, Clear Doorbell Message, PTZ Go To Preset, Set Microphone Volume, Set Status Light</td></tr>
<tr><th>Variables</th><td>ONLINE, RINGING, MOTION, PLAYBACK_ACTIVE, LAST_RING, RING_COUNT, LAST_MOTION, LAST_DETECTION,
LAST_DETECTION_TIME, LAST_EVENT_THUMBNAIL_URL, SNAPSHOT_URL, LIVE_MJPEG_URL</td></tr>
</table>
"""

LIGHTS = """
<h2>Light automation</h2>
<p>Pick lights in <code>Linked Lights</code>. When the sensor {verb} they turn on at <code>Light Level</code>; when it {idle},
they turn off after <code>Lights Off Delay</code> (set <code>Turn Lights Off</code> = No to leave them on).
With <code>Only Turn Off Lights It Turned On</code> = Yes, lights that were already on are left alone.
A new trigger during the delay cancels the pending off.</p>
<p>Programming commands <i>Enable Light Automation</i> / <i>Disable Light Automation</i> (variable <code>LIGHT_AUTOMATION</code>) let you
limit it, for example to night time with a scheduled event. For anything more conditional, leave <code>Linked Lights</code> empty
and use the driver's events in programming instead.</p>
"""

ENTRY = """
<h2>Setup</h2>
<ol>
<li>Pick the sensor in <code>Protect Device</code>.</li>
<li>Bind <code>Door / Window Contact</code> to a stock contact driver (Door Contact Sensor, Window Contact Sensor,
Garage Door Sensor or Gate) to get Navigator icons, history and the usual programming.</li>
</ol>
""" + LIGHTS.format(verb="opens", idle="closes") + """
<h2>Programming</h2>
<table>
<tr><th>Events</th><td>Opened, Closed, Left Open (after <code>Left Open Alert</code> minutes), Alarm Triggered, Battery Low, Tamper Detected,
Tamper Cleared, Sensor Online, Sensor Offline</td></tr>
<tr><th>Variables</th><td>IS_OPEN, LAST_CHANGED, LIGHT_AUTOMATION, ONLINE, BATTERY_PERCENT, BATTERY_LOW, TAMPERED</td></tr>
<tr><th>Connections</th><td>Door / Window Contact (CONTACT_SENSOR, closed = door closed), Tamper (closed = tampered)</td></tr>
</table>
"""

MOTION = """
<h2>Setup</h2>
<ol>
<li>Pick the sensor in <code>Protect Device</code> (Motion, Glass Break or All-In-One).</li>
<li>Optional: bind <code>Motion</code> / <code>Glass Break</code> to the stock Motion Sensor / Glass Break Detector contact drivers.
<code>Contact Closes On Detection</code> sets the polarity.</li>
</ol>
""" + LIGHTS.format(verb="detects motion", idle="clears") + """
<h2>Programming</h2>
<table>
<tr><th>Events</th><td>Motion Detected, Motion Cleared, Glass Break Detected, Alarm Triggered, Battery Low, Tamper Detected,
Tamper Cleared, Sensor Online, Sensor Offline</td></tr>
<tr><th>Variables</th><td>MOTION, LAST_MOTION, LAST_GLASS_BREAK, TEMPERATURE_C/F, HUMIDITY, LIGHT_LUX (All-In-One), LIGHT_AUTOMATION,
ONLINE, BATTERY_PERCENT, BATTERY_LOW, TAMPERED</td></tr>
</table>
"""

ENVIRONMENTAL = """
<h2>Setup</h2>
<ol>
<li>Add the driver to a room and pick the sensor in <code>Protect Device</code>. It appears under <i>Comfort</i> as a
read-only temperature / humidity tile; the <b>Extras</b> tab lists temperature, humidity, light, leak and battery.</li>
<li>Bind <code>Temperature</code> (TEMPERATURE_VALUE) and/or <code>Humidity</code> (HUMIDITY_VALUE) to a thermostat's remote sensor
input or any driver that accepts value connections.</li>
<li>Optional: bind <code>Water Leak</code> to the stock Water Sensor contact driver (<code>Leak Contact Closes When Wet</code> sets polarity).
Internal pads and the external probe both count as a leak.</li>
</ol>
<p>Fahrenheit/Celsius in Navigator follows the project's temperature setting; the driver always reports Celsius to the proxy.
High / Low events follow the thresholds configured for the sensor in Protect.</p>
<h2>Programming</h2>
<table>
<tr><th>Events</th><td>Leak Detected, Leak Cleared, Temperature High / Low / Normal, Humidity High / Low / Normal, Temperature Changed,
Humidity Changed, Battery Low, Tamper Detected, Tamper Cleared, Sensor Online, Sensor Offline</td></tr>
<tr><th>Variables</th><td>TEMPERATURE_C, TEMPERATURE_F, TEMPERATURE_STATUS, HUMIDITY, HUMIDITY_STATUS, LIGHT_LUX, LEAK_DETECTED,
EXTERNAL_LEAK_DETECTED, ONLINE, BATTERY_PERCENT, BATTERY_LOW, TAMPERED</td></tr>
</table>
"""

SMOKE = """
<div class="note"><b>Life safety:</b> this driver is a convenience integration. It is not a listed fire / CO signalling path and
does not replace monitored alarm equipment.</div>
<h2>Setup</h2>
<ol>
<li>Pick the alarm in <code>Protect Device</code>.</li>
<li>Optional: bind <code>Smoke</code> and <code>Carbon Monoxide</code> to the stock Smoke Detector / Carbon Monoxide Detector contact drivers
(<code>Contact Closes On Alarm</code> sets polarity).</li>
</ol>
<h2>Programming</h2>
<table>
<tr><th>Events</th><td>Smoke Alarm, CO Alarm, Any Alarm, Alarm Cleared, Alarm Test, Fault, Needs Cleaning, End of Life, Battery Low,
Tamper Detected, Tamper Cleared, Sensor Online, Sensor Offline</td></tr>
<tr><th>Variables</th><td>SMOKE_ALARM, CO_ALARM, ALARM_ACTIVE, LAST_ALARM, LAST_STATUS_EVENT, ONLINE, BATTERY_PERCENT, BATTERY_LOW, TAMPERED</td></tr>
<tr><th>Commands</th><td>Reset Alarm State (clears the Control4 side only)</td></tr>
</table>
<p>Typical programming: <i>When Any Alarm</i> &rsaquo; turn on lights along the escape route, unlock doors, stop audio, send a notification.</p>
"""

SIREN = """
<h2>Setup</h2>
<p>Pick the siren in <code>Protect Device</code>.</p>
<h2>Programming</h2>
<table>
<tr><th>Commands</th><td>Sound Siren (5, 10, 20 or 30 s), Stop Siren, Test Sound, Set Volume</td></tr>
<tr><th>Events</th><td>Siren Started, Siren Stopped, Siren Online, Siren Offline</td></tr>
<tr><th>Variables</th><td>SIREN_ACTIVE, ONLINE</td></tr>
<tr><th>Connections</th><td>Trigger (CONTACT_SENSOR input): bind a contact output - for example an Entry Sensor's contact - and the
siren sounds for <code>Default Duration</code> when it closes (see <code>Trigger Input</code>).</td></tr>
</table>
"""

TROUBLE = """
<h2>Troubleshooting</h2>
<ul>
<li>Child says <i>Waiting for UniFi Protect master driver</i>: add the master, or bind the child's <code>UniFi Protect</code> connection when
there is more than one master.</li>
<li>No video but snapshots work: make sure Navigators can reach the console on TCP 7447 (RTSP) and try <code>Preferred Stream</code> = Low.</li>
<li>Run the master's <i>Print Devices to Lua Output</i> action and set <code>Debug Logging</code> = On to see the traffic in the Lua tab.</li>
</ul>
"""

PAGES = {
    "unifi_protect": ("UniFi Protect (Master)", FAMILY + MASTER + TROUBLE),
    "unifi_protect_camera": ("UniFi Protect Camera / Doorbell", CAMERA + FAMILY + TROUBLE),
    "unifi_protect_entry": ("UniFi Protect Entry Sensor", ENTRY + FAMILY + TROUBLE),
    "unifi_protect_motion": ("UniFi Protect Motion Sensor", MOTION + FAMILY + TROUBLE),
    "unifi_protect_environmental": ("UniFi Protect Environmental Sensor", ENVIRONMENTAL + FAMILY + TROUBLE),
    "unifi_protect_smoke_co": ("UniFi Protect Smoke and CO Alarm", SMOKE + FAMILY + TROUBLE),
    "unifi_protect_siren": ("UniFi Protect Siren", SIREN + FAMILY + TROUBLE),
}


def render(folder, version):
    title, body = PAGES[folder]
    return HEADER.format(title=title, style=STYLE, version=version) + body + FOOTER
