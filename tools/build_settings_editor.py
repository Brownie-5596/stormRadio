#!/usr/bin/env python3
"""Builds tools/settings-editor.html from settings-editor.src.html by embedding the app's default settings.

Run after changing default settings in StormRadioCore:
    cd Packages/StormRadioCore && swift run stormradio-cli defaults > /tmp/defaults.json
    python3 tools/build_settings_editor.py /tmp/defaults.json [--artifact out.html]

--artifact also writes a body-only variant (no doctype/html/head/body tags) for hosting as a claude.ai artifact.
"""
import json
import pathlib
import re
import sys

here = pathlib.Path(__file__).resolve().parent
defaults = json.loads(pathlib.Path(sys.argv[1]).read_text())
src = (here / "settings-editor.src.html").read_text()
embedded = json.dumps(defaults, separators=(",", ":")).replace("</", "<\\/")
out = src.replace("/*DEFAULTS*/", embedded)
(here / "settings-editor.html").write_text(out)
print(f"Wrote {here / 'settings-editor.html'} ({len(out) // 1024} KB)")

if "--artifact" in sys.argv:
    target = pathlib.Path(sys.argv[sys.argv.index("--artifact") + 1])
    head = re.search(r"<head>(.*?)</head>", out, re.S).group(1)
    head = re.sub(r"<meta[^>]*>\s*", "", head)
    body = re.search(r"<body>(.*?)</body>", out, re.S).group(1)
    target.write_text(head.strip() + "\n" + body.strip() + "\n")
    print(f"Wrote {target}")
