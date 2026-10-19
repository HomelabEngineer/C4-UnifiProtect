#!/usr/bin/env python3
"""Build every UniFi Protect Control4 driver into dist/*.c4z.

    python3 build.py            # generate manifests/icons/docs, run tests, package
    python3 build.py --no-test  # skip the Lua test suite

Package filenames are not versioned: Composer keys a driver's identity (and the
children's master auto-discovery) on the .c4z file name.
"""
import os
import re
import subprocess
import sys
import zipfile
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.abspath(__file__))
DIST = os.path.join(ROOT, "dist")
COMMON = os.path.join(ROOT, "common", "up_common.lua")
sys.path.insert(0, os.path.join(ROOT, "tools"))

DRIVERS = [
    "unifi_protect",
    "unifi_protect_camera",
    "unifi_protect_entry",
    "unifi_protect_motion",
    "unifi_protect_environmental",
    "unifi_protect_smoke_co",
    "unifi_protect_siren",
]


def version():
    m = re.search(r'U\.VERSION\s*=\s*"([^"]+)"', open(COMMON, encoding="utf-8").read())
    return m.group(1)


def check(folder):
    path = os.path.join(ROOT, "drivers", folder)
    tree = ET.parse(os.path.join(path, "driver.xml"))
    problems = []
    for tag in ("small", "large"):
        el = tree.find(tag)
        if el is None or not os.path.exists(os.path.join(path, "www", el.text)):
            problems.append(f"missing {tag} icon")
    script = tree.find("config/script")
    if script is None or not os.path.exists(os.path.join(path, script.get("file"))):
        problems.append("missing driver script")
    doc = tree.find("config/documentation")
    if doc is None or not os.path.exists(os.path.join(path, doc.get("file"))):
        problems.append("missing documentation")
    ids = [c.findtext("id") for c in tree.findall("connections/connection")]
    if len(ids) != len(set(ids)):
        problems.append(f"duplicate connection ids {ids}")
    events = tree.findall("config/events/event")
    names = [e.findtext("name") for e in events]
    eids = [e.findtext("id") for e in events]
    if len(names) != len(set(names)) or len(eids) != len(set(eids)):
        problems.append("duplicate event names/ids")
    # Every event the Lua fires must be declared.
    lua = open(os.path.join(path, "driver.lua"), encoding="utf-8").read() + open(COMMON, encoding="utf-8").read()
    fired = set(re.findall(r'U\.fire\("([^"]+)"\)', lua))
    fired |= set(re.findall(r'"(\w[\w ]+ Detected)"', open(os.path.join(path, "driver.lua"), encoding="utf-8").read()))
    declared = set(names)
    local_fired = set(re.findall(r'U\.fire\("([^"]+)"\)', open(os.path.join(path, "driver.lua"), encoding="utf-8").read()))
    missing = sorted(e for e in local_fired if e not in declared)
    if missing:
        problems.append(f"events fired but not declared: {missing}")
    props = {p.findtext("name") for p in tree.findall("config/properties/property")}
    used = set(re.findall(r'U\.(?:prop|setProp)\("([^"]+)"', open(os.path.join(path, "driver.lua"), encoding="utf-8").read()))
    undeclared = sorted(p for p in used if p not in props)
    if undeclared:
        problems.append(f"properties used but not declared: {undeclared}")
    return problems


def package(folder):
    src = os.path.join(ROOT, "drivers", folder)
    out = os.path.join(DIST, folder + ".c4z")
    if os.path.exists(out):
        os.remove(out)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for base, dirs, files in os.walk(src):
            dirs[:] = sorted(d for d in dirs if d not in ("__pycache__",))
            for f in sorted(files):
                if f.startswith("."):
                    continue
                full = os.path.join(base, f)
                z.write(full, os.path.relpath(full, src).replace(os.sep, "/"))
        z.write(COMMON, "up_common.lua")
    return out


def main():
    import docs
    import gen_sensor_xml
    import make_icons

    v = version()
    gen_sensor_xml.main()
    make_icons.main()
    for folder in DRIVERS:
        with open(os.path.join(ROOT, "drivers", folder, "www", "documentation.html"), "w", encoding="utf-8") as f:
            f.write(docs.render(folder, v))

    failed = False
    for folder in DRIVERS:
        problems = check(folder)
        if problems:
            failed = True
            print(f"{folder}: " + "; ".join(problems))
    if failed:
        sys.exit("manifest checks failed")

    if "--no-test" not in sys.argv:
        subprocess.check_call([sys.executable, os.path.join(ROOT, "tests", "test_drivers.py")])

    os.makedirs(DIST, exist_ok=True)
    for folder in DRIVERS:
        out = package(folder)
        print(f"built {os.path.relpath(out, ROOT)} ({os.path.getsize(out) // 1024} KB)")
    print(f"version {v}")


if __name__ == "__main__":
    main()
