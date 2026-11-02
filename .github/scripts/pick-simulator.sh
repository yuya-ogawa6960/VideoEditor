#!/bin/bash
# いちばん新しい iOS ランタイムの iPhone シミュレータを選んで UDID を出す(無ければ作る)。
# 使い方: UDID=$(.github/scripts/pick-simulator.sh)
set -euo pipefail

/usr/bin/python3 - <<'PY'
import json, subprocess, sys

def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout

def version(runtime_id):
    # com.apple.CoreSimulator.SimRuntime.iOS-27-1 -> (27, 1)
    tail = runtime_id.rsplit(".", 1)[-1]
    return tuple(int(p) for p in tail.split("-")[1:] if p.isdigit())

runtimes = [r for r in json.loads(run("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
            if r.get("isAvailable") and r.get("platform", "iOS") == "iOS" and ".iOS-" in r["identifier"]]
if not runtimes:
    sys.exit("iOS のシミュレータのランタイムがありません")
runtime = max(runtimes, key=lambda r: version(r["identifier"]))
devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"].get(runtime["identifier"], [])
phones = [d for d in devices if d["name"].startswith("iPhone")]
# Pro(6.3 インチ)を優先。無ければ最初の iPhone
phones.sort(key=lambda d: (0 if " Pro" in d["name"] and "Max" not in d["name"] else 1, d["name"]))
if phones:
    device = phones[0]
    print(f"{runtime['name']} / {device['name']}", file=sys.stderr)
    print(device["udid"])
else:
    types = [t for t in runtime.get("supportedDeviceTypes", []) if t["name"].startswith("iPhone")]
    if not types:
        sys.exit("iPhone のシミュレータを作れません")
    t = types[-1]
    udid = run("xcrun", "simctl", "create", "UITests " + t["name"], t["identifier"], runtime["identifier"]).strip()
    print(f"{runtime['name']} / {t['name']} (created)", file=sys.stderr)
    print(udid)
PY
