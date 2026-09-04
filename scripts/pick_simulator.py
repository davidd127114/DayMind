#!/usr/bin/env python3
"""Print `udid=<UDID>` of the newest available iPhone simulator (for GitHub Actions)."""
import json
import subprocess

out = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
devices = json.loads(out)["devices"]
best = None
for runtime, devs in devices.items():
    if "iOS" not in runtime:
        continue
    for dev in devs:
        if "iPhone" in dev["name"] and dev.get("isAvailable"):
            # Prefer newest runtime, then a plain "iPhone NN" over Pro/Max/SE variants (they boot faster).
            plain = "Pro" not in dev["name"] and "Max" not in dev["name"] and "SE" not in dev["name"]
            key = (runtime, plain, dev["name"])
            if best is None or key > best[0]:
                best = (key, dev["udid"], dev["name"], runtime)
if not best:
    raise SystemExit("No iPhone simulator available")
print(f"udid={best[1]}")
print(f"name={best[2]}")
print(f"runtime={best[3]}")
