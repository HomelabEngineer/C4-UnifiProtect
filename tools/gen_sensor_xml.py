#!/usr/bin/env python3
"""Generate driver.xml for the SuperLink sensor / siren child drivers.

The five sensor drivers share most of their manifest (child binding, device
picker, status, light automation block), so it is generated from one place.
Run by build.py; safe to run on its own.
"""
import os
from xml.sax.saxutils import escape

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DATE = "10/18/2026 12:00 PM"


def prop(name, ptype="STRING", default="", readonly=False, items=None, tooltip=None,
         minimum=None, maximum=None, password=False, multiselect=None):
    out = ["      <property>", f"        <name>{escape(name)}</name>", f"        <type>{ptype}</type>"]
    if readonly:
        out.append("        <readonly>true</readonly>")
    if password:
        out.append("        <password>true</password>")
    if minimum is not None:
        out.append(f"        <minimum>{minimum}</minimum>")
    if maximum is not None:
        out.append(f"        <maximum>{maximum}</maximum>")
    if items:
        out.append("        <items>")
        out.extend(f"          <item>{escape(i)}</item>" for i in items)
        out.append("        </items>")
    if multiselect is not None:
        out.append(f"        <multiselect>{'true' if multiselect else 'false'}</multiselect>")
    if ptype not in ("DYNAMIC_LIST",):
        out.append(f"        <default>{escape(str(default))}</default>")
    if tooltip:
        out.append(f"        <tooltip>{escape(tooltip)}</tooltip>")
    out.append("      </property>")
    return "\n".join(out)


def label(name, text):
    return prop(name, "LABEL", text)


def head_props(device_tooltip):
    return [
        prop("Driver Version", readonly=True),
        prop("Connection Status", readonly=True, default="Waiting for UniFi Protect master driver"),
        prop("Protect Device", "DYNAMIC_LIST", tooltip=device_tooltip),
        prop("Device Name", readonly=True),
    ]


def status_props(extra=()):
    out = [label("Status", "Status"),
           prop("Sensor State", readonly=True),
           prop("Battery", readonly=True, default="--"),
           prop("Tamper", readonly=True, default="--")]
    out.extend(extra)
    return out


def light_props(trigger_word):
    return [
        label("Lights", f"Light Automation ({trigger_word})"),
        prop("Light Automation", "LIST", "Enabled", items=["Enabled", "Disabled"]),
        prop("Linked Lights", "DEVICE_SELECTOR", "", items=["light_v2.c4i", "light.c4i"], multiselect=True,
             tooltip=f"Lights to turn on when the sensor {trigger_word}"),
        prop("Light Level (%)", "RANGED_INTEGER", 100, minimum=1, maximum=100),
        prop("Turn Lights Off", "LIST", "Yes", items=["Yes", "No"]),
        prop("Lights Off Delay (seconds)", "RANGED_INTEGER", 30, minimum=0, maximum=3600),
        prop("Only Turn Off Lights It Turned On", "LIST", "Yes", items=["Yes", "No"],
             tooltip="Leave lights alone that were already on before the sensor triggered"),
    ]


def debug_prop():
    return prop("Debug Logging", "LIST", "Off", items=["Off", "On"])


def conn(cid, name, cls, consumer=False, ctype=1, hidden=False, proxy=None):
    attr = f' proxybindingid="{proxy}"' if proxy else ""
    lines = [
        f"    <connection{attr}>",
        f"      <id>{cid}</id>",
        "      <facing>6</facing>",
        f"      <connectionname>{escape(name)}</connectionname>",
        f"      <type>{ctype}</type>",
        f"      <consumer>{'True' if consumer else 'False'}</consumer>",
        "      <audiosource>False</audiosource>",
        "      <videosource>False</videosource>",
        "      <linelevel>False</linelevel>",
        "      <classes>",
        f"        <class><classname>{cls}</classname></class>",
        "      </classes>",
    ]
    if hidden:
        lines.append("      <hidden>True</hidden>")
    lines.append("    </connection>")
    return "\n".join(lines)


def master_conn():
    return conn(1, "UniFi Protect", "UNIFI_PROTECT", consumer=True)


def contact_out(cid, name):
    return conn(cid, name, "CONTACT_SENSOR", consumer=False)


def events_xml(events):
    return "\n".join(
        f"      <event><id>{i}</id><name>{escape(n)}</name><description>{escape(d)}</description></event>"
        for i, (n, d) in enumerate(events, 1))


def actions_xml(actions):
    return "\n".join(f"      <action><name>{escape(n)}</name><command>{c}</command></action>" for n, c in actions)


def commands_xml(commands):
    out = []
    for c in commands:
        out.append("      <command>")
        out.append(f"        <name>{escape(c['name'])}</name>")
        out.append(f"        <description>{escape(c['desc'])}</description>")
        if c.get("params"):
            out.append("        <params>")
            for p in c["params"]:
                out.append("          <param>")
                out.append(f"            <name>{escape(p['name'])}</name>")
                out.append(f"            <type>{p['type']}</type>")
                if "min" in p:
                    out.append(f"            <minimum>{p['min']}</minimum>")
                    out.append(f"            <maximum>{p['max']}</maximum>")
                if p.get("items"):
                    out.append("            <items>")
                    out.extend(f"              <item>{escape(i)}</item>" for i in p["items"])
                    out.append("            </items>")
                if "default" in p:
                    out.append(f"            <default>{escape(str(p['default']))}</default>")
                out.append("          </param>")
            out.append("        </params>")
        out.append("      </command>")
    return "\n".join(out)


COMMON_EVENTS = [
    ("Battery Low", "Sensor battery is low"),
    ("Tamper Detected", "Sensor tamper switch triggered"),
    ("Tamper Cleared", "Sensor tamper cleared"),
    ("Sensor Online", "Sensor reconnected to Protect"),
    ("Sensor Offline", "Sensor disconnected from Protect"),
]

LIGHT_COMMANDS = [
    {"name": "Enable Light Automation", "desc": "Enable NAME light automation"},
    {"name": "Disable Light Automation", "desc": "Disable NAME light automation"},
]


def render(spec):
    proxies = spec.get("proxies")
    if proxies is None:
        # Combo driver: the driver is its own proxy (proxy name = .c4z file name).
        proxies = f"""
  <combo>true</combo>
  <proxies qty="1">
    <proxy proxybindingid="5001" name="{escape(spec['name'])}" primary="True" image_source="c4z" small_image="icons/device_sm.png" large_image="icons/device_lg.png">{spec['folder']}</proxy>
  </proxies>
"""
    caps = spec.get("capabilities", "")
    cats = "\n".join(f"    <category>{c}</category>" for c in spec["categories"])
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by tools/gen_sensor_xml.py - edit the generator, not this file. -->
<devicedata>
  <copyright>Open Source (MIT License)</copyright>
  <creator>Open Source</creator>
  <manufacturer>Ubiquiti</manufacturer>
  <name>{escape(spec['name'])}</name>
  <model>{escape(spec['model'])}</model>
  <created>{DATE}</created>
  <modified>{DATE}</modified>
  <version>101</version>
  <control>lua_gen</control>
  <controlmethod>ip</controlmethod>
  <driver>DriverWorks</driver>
  <minimum_os_version>3.3.0</minimum_os_version>
  <small image_source="c4z">icons/device_sm.png</small>
  <large image_source="c4z">icons/device_lg.png</large>

  <composer_categories>
{cats}
  </composer_categories>
{proxies}{caps}
  <connections>
{chr(10).join(spec['connections'])}
  </connections>

  <config>
    <documentation file="www/documentation.html"/>
    <script file="driver.lua"/>

    <actions>
{actions_xml(spec['actions'])}
    </actions>

    <events>
{events_xml(spec['events'])}
    </events>

    <commands>
{commands_xml(spec.get('commands', []))}
    </commands>

    <properties>
{chr(10).join(spec['properties'])}
    </properties>
  </config>
</devicedata>
"""


SPECS = {
    "unifi_protect_entry": {
        "name": "UniFi Protect Entry Sensor",
        "model": "SuperLink Entry Sensor (USL-Entry / USL-Entry-R)",
        "categories": ["Sensors"],
        "connections": [
            master_conn(),
            contact_out(100, "Door / Window Contact"),
            contact_out(101, "Tamper"),
        ],
        "actions": [("Reconnect to Master", "Reconnect"), ("Test Linked Lights", "TestLights")],
        "events": [
            ("Opened", "Door / window opened"),
            ("Closed", "Door / window closed"),
            ("Left Open", "Still open after the Left Open Alert time"),
            ("Alarm Triggered", "Sensor triggered a Protect alarm"),
        ] + COMMON_EVENTS,
        "commands": LIGHT_COMMANDS,
        "properties": head_props("SuperLink entry sensor in UniFi Protect") + status_props([
            prop("Mount Type", readonly=True),
            prop("State", readonly=True, default="--"),
            prop("Last Changed", readonly=True),
            prop("Left Open Alert (minutes)", "RANGED_INTEGER", 0, minimum=0, maximum=1440,
                 tooltip="Fire 'Left Open' after this many minutes (0 = off)"),
        ]) + light_props("opens") + [debug_prop()],
    },
    "unifi_protect_motion": {
        "name": "UniFi Protect Motion Sensor",
        "model": "SuperLink Motion / Glass Break / All-In-One",
        "categories": ["Sensors"],
        "connections": [
            master_conn(),
            contact_out(100, "Motion"),
            contact_out(101, "Glass Break"),
            contact_out(102, "Tamper"),
        ],
        "actions": [("Reconnect to Master", "Reconnect"), ("Test Linked Lights", "TestLights")],
        "events": [
            ("Motion Detected", "Motion detected"),
            ("Motion Cleared", "Motion cleared"),
            ("Glass Break Detected", "Glass break detected"),
            ("Alarm Triggered", "Sensor triggered a Protect alarm"),
        ] + COMMON_EVENTS,
        "commands": LIGHT_COMMANDS,
        "properties": head_props("SuperLink motion / glass break sensor in UniFi Protect") + status_props([
            prop("State", readonly=True, default="--"),
            prop("Last Motion", readonly=True),
            prop("Last Glass Break", readonly=True),
            prop("Contact Closes On Detection", "LIST", "Yes", items=["Yes", "No"]),
            prop("Glass Break Hold (seconds)", "RANGED_INTEGER", 10, minimum=1, maximum=600),
        ]) + light_props("detects motion") + [debug_prop()],
    },
    "unifi_protect_environmental": {
        "name": "UniFi Protect Environmental Sensor",
        "model": "SuperLink Environmental Sensor (USL-Environmental)",
        "categories": ["Comfort"],
        "proxies": """
  <proxies qty="1">
    <proxy proxybindingid="5001" primary="True" name="Environment">thermostatV2</proxy>
  </proxies>
""",
        "capabilities": """
  <capabilities>
    <can_heat>False</can_heat>
    <can_cool>False</can_cool>
    <can_auto>False</can_auto>
    <has_humidity>True</has_humidity>
    <has_single_setpoint>False</has_single_setpoint>
    <can_preset>False</can_preset>
    <can_preset_schedule>False</can_preset_schedule>
    <has_temperature>True</has_temperature>
    <current_temperature_min_c>-40</current_temperature_min_c>
    <current_temperature_max_c>85</current_temperature_max_c>
    <current_temperature_min_f>-40</current_temperature_min_f>
    <current_temperature_max_f>185</current_temperature_max_f>
    <current_temperature_resolution_c>0.1</current_temperature_resolution_c>
    <current_temperature_resolution_f>1</current_temperature_resolution_f>
    <setpoint_resolution_c>0.5</setpoint_resolution_c>
    <setpoint_resolution_f>1</setpoint_resolution_f>
    <setpoint_heat_min_c>0</setpoint_heat_min_c>
    <setpoint_heat_max_c>120</setpoint_heat_max_c>
    <setpoint_heat_min_f>32</setpoint_heat_min_f>
    <setpoint_heat_max_f>248</setpoint_heat_max_f>
    <setpoint_cool_min_c>0</setpoint_cool_min_c>
    <setpoint_cool_max_c>120</setpoint_cool_max_c>
    <setpoint_cool_min_f>32</setpoint_cool_min_f>
    <setpoint_cool_max_f>248</setpoint_cool_max_f>
    <setpoint_single_min_c>0</setpoint_single_min_c>
    <setpoint_single_max_c>120</setpoint_single_max_c>
    <setpoint_single_min_f>32</setpoint_single_min_f>
    <setpoint_single_max_f>248</setpoint_single_max_f>
    <setpoint_single_resolution_c>0.5</setpoint_single_resolution_c>
    <setpoint_single_resolution_f>1</setpoint_single_resolution_f>
    <can_inc_dec_setpoints>False</can_inc_dec_setpoints>
    <can_change_scale>False</can_change_scale>
    <has_extras>True</has_extras>
    <has_vacation_mode>False</has_vacation_mode>
    <has_remote_sensor>True</has_remote_sensor>
    <fan_modes/>
    <hvac_modes>Off</hvac_modes>
    <hold_modes/>
  </capabilities>
""",
        "connections": [
            conn(5001, "Thermostat", "THERMOSTAT", consumer=False, ctype=2, hidden=True, proxy=5001),
            conn(5010, "Temperature", "TEMPERATURE_VALUE", consumer=False, ctype=6),
            conn(5012, "Humidity", "HUMIDITY_VALUE", consumer=False, ctype=6),
            master_conn(),
            contact_out(100, "Water Leak"),
            contact_out(101, "Tamper"),
            """    <connection>
      <id>7000</id>
      <facing>6</facing>
      <connectionname>Selection</connectionname>
      <type>7</type>
      <consumer>False</consumer>
      <classes>
        <class><autobind>True</autobind><classname>TEMPERATURE</classname></class>
        <class><autobind>True</autobind><classname>TEMPERATURE_CONTROL</classname></class>
      </classes>
      <hidden>True</hidden>
    </connection>""",
        ],
        "actions": [("Reconnect to Master", "Reconnect"), ("Resend Temperature / Humidity", "ResendValues")],
        "events": [
            ("Leak Detected", "Water leak detected (pads or external probe)"),
            ("Leak Cleared", "Water leak cleared"),
            ("Temperature High", "Temperature above the Protect high threshold"),
            ("Temperature Low", "Temperature below the Protect low threshold"),
            ("Temperature Normal", "Temperature back inside the Protect thresholds"),
            ("Humidity High", "Humidity above the Protect high threshold"),
            ("Humidity Low", "Humidity below the Protect low threshold"),
            ("Humidity Normal", "Humidity back inside the Protect thresholds"),
            ("Temperature Changed", "Temperature reading changed"),
            ("Humidity Changed", "Humidity reading changed"),
        ] + COMMON_EVENTS,
        "properties": head_props("SuperLink environmental sensor in UniFi Protect") + status_props([
            prop("Mount Type", readonly=True),
            prop("Temperature", readonly=True, default="--"),
            prop("Humidity", readonly=True, default="--"),
            prop("Light", readonly=True, default="--"),
            prop("Water Leak", readonly=True, default="--"),
            prop("Leak Contact Closes When Wet", "LIST", "Yes", items=["Yes", "No"]),
            prop("Extras Temperature Unit", "LIST", "Fahrenheit", items=["Fahrenheit", "Celsius"]),
        ]) + [debug_prop()],
    },
    "unifi_protect_smoke_co": {
        "name": "UniFi Protect Smoke CO Alarm",
        "model": "SuperLink Smoke and CO Alarm",
        "categories": ["Sensors"],
        "connections": [
            master_conn(),
            contact_out(100, "Smoke"),
            contact_out(101, "Carbon Monoxide"),
            contact_out(102, "Tamper"),
        ],
        "actions": [("Reconnect to Master", "Reconnect")],
        "events": [
            ("Smoke Alarm", "Smoke alarm sounding"),
            ("CO Alarm", "Carbon monoxide alarm sounding"),
            ("Any Alarm", "Smoke or CO alarm sounding"),
            ("Alarm Cleared", "All alarms cleared"),
            ("Alarm Test", "Alarm self test performed"),
            ("Fault", "Smoke or CO sensor fault"),
            ("Needs Cleaning", "Smoke chamber needs cleaning"),
            ("End of Life", "Alarm reached end of life"),
        ] + COMMON_EVENTS,
        "commands": [{"name": "Reset Alarm State", "desc": "Clear NAME alarm state in Control4"}],
        "properties": head_props("SuperLink Smoke and CO alarm in UniFi Protect") + status_props([
            prop("Alarm State", readonly=True, default="Normal"),
            prop("Contact Closes On Alarm", "LIST", "Yes", items=["Yes", "No"]),
        ]) + [debug_prop()],
    },
    "unifi_protect_siren": {
        "name": "UniFi Protect Siren",
        "model": "SuperLink Siren (USL-Siren / UP-Siren-PoE)",
        "categories": ["Sensors"],
        "connections": [
            master_conn(),
            conn(200, "Trigger", "CONTACT_SENSOR", consumer=True),
        ],
        "actions": [("Reconnect to Master", "Reconnect"), ("Test Siren Sound", "TestSiren")],
        "events": [
            ("Siren Started", "Siren started sounding"),
            ("Siren Stopped", "Siren stopped"),
            ("Siren Online", "Siren reconnected to Protect"),
            ("Siren Offline", "Siren disconnected from Protect"),
        ],
        "commands": [
            {"name": "Sound Siren", "desc": "Sound NAME for PARAM1 seconds",
             "params": [{"name": "Duration", "type": "LIST", "items": ["5", "10", "20", "30"], "default": "10"}]},
            {"name": "Stop Siren", "desc": "Stop NAME"},
            {"name": "Test Sound", "desc": "Test NAME at volume PARAM1",
             "params": [{"name": "Volume", "type": "RANGED_INTEGER", "min": 1, "max": 100, "default": 50}]},
            {"name": "Set Volume", "desc": "Set NAME volume to PARAM1",
             "params": [{"name": "Volume", "type": "RANGED_INTEGER", "min": 1, "max": 100, "default": 100}]},
        ],
        "properties": head_props("Siren in UniFi Protect") + [
            label("Status", "Status"),
            prop("Sensor State", readonly=True),
            prop("Siren State", readonly=True, default="Idle"),
            prop("Volume", readonly=True),
            label("Behavior", "Behavior"),
            prop("Default Duration (seconds)", "LIST", "10", items=["5", "10", "20", "30"]),
            prop("Trigger Input", "LIST", "Sound On Close", items=["Sound On Close", "Sound On Open", "Disabled"]),
            prop("Stop When Trigger Releases", "LIST", "No", items=["No", "Yes"]),
            debug_prop(),
        ],
    },
}


def main():
    for folder, spec in SPECS.items():
        spec["folder"] = folder
        path = os.path.join(ROOT, "drivers", folder, "driver.xml")
        with open(path, "w", encoding="utf-8") as f:
            f.write(render(spec))
        print("wrote", os.path.relpath(path, ROOT))


if __name__ == "__main__":
    main()
