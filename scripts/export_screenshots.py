#!/usr/bin/env python3
"""Export XCTAttachment screenshots from an .xcresult bundle into a folder with readable names.

Usage: export_screenshots.py TestResults.xcresult out_dir
Uses `xcrun xcresulttool export attachments` (Xcode 16+), which writes the files plus a manifest.json.
"""
import json
import os
import shutil
import subprocess
import sys

bundle, out = sys.argv[1], sys.argv[2]
tmp = out + "-raw"
shutil.rmtree(tmp, ignore_errors=True)
os.makedirs(tmp, exist_ok=True)
os.makedirs(out, exist_ok=True)
subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", bundle, "--output-path", tmp], check=True)

manifest_path = os.path.join(tmp, "manifest.json")
count = 0
if os.path.exists(manifest_path):
    manifest = json.load(open(manifest_path))
    # manifest is a list of test entries, each with "attachments": [{"exportedFileName", "suggestedHumanReadableName", ...}]
    for entry in manifest:
        for att in entry.get("attachments", []):
            src = os.path.join(tmp, att.get("exportedFileName", ""))
            if not os.path.isfile(src):
                continue
            if not src.lower().endswith((".png", ".jpg", ".jpeg")):
                continue  # skip debug-description .txt attachments from failed queries
            name = att.get("suggestedHumanReadableName") or att.get("exportedFileName")
            base, ext = os.path.splitext(name)
            if not ext:
                ext = os.path.splitext(src)[1] or ".png"
            base = "".join(ch if (ch.isalnum() or ch in "-_.") else "_" for ch in base)[:80]
            dest = os.path.join(out, base + ext)
            i = 2
            while os.path.exists(dest):
                dest = os.path.join(out, f"{base}-{i}{ext}")
                i += 1
            shutil.copyfile(src, dest)
            count += 1
else:
    for f in os.listdir(tmp):
        if f.lower().endswith((".png", ".jpg", ".jpeg")):
            shutil.copyfile(os.path.join(tmp, f), os.path.join(out, f))
            count += 1
print(f"exported {count} screenshots to {out}")
