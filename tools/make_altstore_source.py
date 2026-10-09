#!/usr/bin/env python3
"""Writes an AltStore / SideStore source file for the latest Storm Radio build.

Usage (run by the GitHub Actions workflow):
    make_altstore_source.py --app Payload/StormRadio.app --ipa StormRadio.ipa --repo owner/name --tag latest \
        --notes "release notes" --out altstore-source.json

Version numbers and permissions are read from the built app's Info.plist so the source always matches the .ipa
(AltStore refuses to install when the listed permissions don't match the app).
"""
import argparse
import datetime
import json
import os
import plistlib

ap = argparse.ArgumentParser()
ap.add_argument("--app", required=True)
ap.add_argument("--ipa", required=True)
ap.add_argument("--repo", required=True)
ap.add_argument("--tag", default="latest")
ap.add_argument("--notes", default="")
ap.add_argument("--out", required=True)
a = ap.parse_args()

with open(os.path.join(a.app, "Info.plist"), "rb") as f:
    info = plistlib.load(f)

base = f"https://github.com/{a.repo}/releases/download/{a.tag}"
privacy = {k: v for k, v in info.items() if k.endswith("UsageDescription")}

source = {
    "name": "Storm Radio",
    "subtitle": "Personal storm alert radio builds",
    "description": "Automatic builds of Storm Radio from GitHub.",
    "iconURL": f"{base}/icon.png",
    "website": f"https://github.com/{a.repo}",
    "tintColor": "#FF9900",
    "apps": [
        {
            "name": "Storm Radio",
            "bundleIdentifier": info["CFBundleIdentifier"],
            "developerName": a.repo.split("/")[0],
            "subtitle": "Storm alerts, reports and SPC products read aloud",
            "localizedDescription": "Reads nearby NWS warnings, updates, storm reports, SPC mesoscale discussions, watches and outlooks aloud, with profiles you control.",
            "iconURL": f"{base}/icon.png",
            "tintColor": "#FF9900",
            "category": "utilities",
            "versions": [
                {
                    "version": info["CFBundleShortVersionString"],
                    "buildVersion": str(info["CFBundleVersion"]),
                    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "localizedDescription": a.notes.strip()[:2000],
                    "downloadURL": f"{base}/StormRadio.ipa",
                    "size": os.path.getsize(a.ipa),
                    "minOSVersion": info.get("MinimumOSVersion", "17.0"),
                }
            ],
            "appPermissions": {"entitlements": [], "privacy": privacy},
        }
    ],
    "news": [],
}

with open(a.out, "w") as f:
    json.dump(source, f, indent=2)
print(json.dumps(source["apps"][0]["versions"][0], indent=2))
