# ⛈️ Storm Radio

A personal weather radio for iPhone and iPad, built for storm chasing and staying weather-aware.
Unlike a NOAA weather radio, it only reads what matters to **you**: alerts and reports near your
location (or a place or area you choose), in the order and wording you want. It also tells you when
something **changes**.

> Not an official warning system. Always have more than one way to receive warnings.

## What it does

**Warnings & watches (NWS)**
- Reads new alerts in your area, e.g.:
  *"A considerable severe thunderstorm warning was issued 6 miles to the northeast. 60 mile per hour wind gusts
  were indicated by radar and 2 inch, hen egg size hail was observed by N W S employee. It expires in 50 minutes, at 7:30."*
- Tags: PDS, tornado/flash flood emergency, considerable, destructive, catastrophic.
- "Issued X minutes ago" (only when it isn't brand new; can be turned off), distance + direction (to the nearest edge, the center, or the storm), threats and how they were detected, who reported it, expiration (minutes left and clock time), optional cities, counties, storm motion, NWS headline, instructions.
- **Updates**: hail/wind size changed, tornado now radar-indicated or observed, tags raised/lowered, became PDS/emergency, time extended, area reduced or expanded, part of it cancelled, cancelled (with the reason), expired or "will be allowed to expire", no longer in effect, moved in/out of range.
- **You entered / left a warning** while driving (GPS mode).
- **In the path**: uses the storm location and motion in each warning to estimate whether a storm will reach you and when. Has a 1–5 risk index (so a 1" hail / 60 mph storm doesn't bother you) and warns at lead times you pick (e.g. 30, 15 and 5 minutes out).

**SPC & forecast products**
- Mesoscale discussions (nationwide or near you), with the area, concern, watch probability and distance from you.
- New tornado / severe thunderstorm watches nationwide, including PDS watches, with primary threats.
- Day 1–3 convective outlooks with the highest risk and the risk at your location.
- Area Forecast Discussions from your office (and others you add), with chosen sections read aloud.

**Storm reports**
- NWS Local Storm Reports, SpotterNetwork, and mPING (needs a free token).
- Per report type: on/off, speak or tone, minimum hail size or wind gust.
- Handles late reports: skips old ones and says when it actually happened (*"Delayed report. It happened at 6:05, 40 minutes ago."*).

**The radio**
- Priority queue: a tornado warning can cut off a storm report mid-sentence (you choose what can interrupt what, with boosts for PDS, destructive, observed tornado and emergencies).
- Speak, tone + speak, tone only (a different synthesized sound per type), or silent (feed only).
- **Repeat last**, stop, skip, snooze (priority 9+ still speaks), and buttons to read nearby alerts, the latest/nearest MD, SPC watches, Day 1/2 outlooks, the AFD, and recent storm reports.
- Feed tab: a notification center with everything announced (even silent ones), full text, links to the event page, speak again, share.
- Map tab: warning polygons, storm reports, MDs and your monitoring area.
- Works in the background, with the screen locked and through CarPlay or Bluetooth audio, ducking your music like a navigation app.

**Profiles & settings**
- Profiles (Chase, Home, Quiet, Overnight + your own). Switch from the Radio tab.
- Location: follow GPS or a fixed point (search a town, use current location or tap the map). Area: a radius, or a polygon or box you draw on the map.
- Every warning type has its own on/off, mode, sound, distance (so a Special Weather Statement 100 miles away stays quiet), priority, interrupt, update and notification settings.
- **Message builder**: reorder and toggle the building blocks, or write your own format like
  `{tags} {event} {distance}. {threats}. {expires}`. Live preview + "speak preview".
- Voice speed, pitch, voice choice, volumes, pause between messages.
- **Export/import settings** as a JSON file: AirDrop between iPhone and iPad, save to iCloud Drive, or edit on a computer with the web editor (below).

## Installing on your iPhone / iPad (Sideloadly)

1. **Get the app file.** Every push builds the app automatically. Download `StormRadio.ipa` from the
   [Releases page](https://github.com/Brownie-5596/stormRadio/releases) (pre-release named "Storm Radio build"),
   or from the latest run on the [Actions tab](https://github.com/Brownie-5596/stormRadio/actions) (Artifacts → StormRadio-ipa).
2. Open **Sideloadly** on your computer, plug in your iPhone/iPad, drag `StormRadio.ipa` in, enter your Apple ID and press **Start**.
3. On the device: **Settings → General → VPN & Device Management** → trust your Apple ID's developer profile.
   On iOS 16+ also turn on **Settings → Privacy & Security → Developer Mode** if asked.
4. With a free Apple ID the app must be re-signed every 7 days (Sideloadly can auto-refresh). Your settings stay.

## First run

1. Open Storm Radio and allow **Location** ("While Using" is enough; "Always" makes background more robust) and **Notifications**.
2. Pick a profile (top right of the Radio tab) and tap the **power button**.
3. Optional: Settings → Data sources → put your email as the NWS contact (they ask apps to identify themselves).

**While chasing:** leave monitoring on. The app can be in the background or the screen locked. Don't swipe it away
(force-quitting stops it). If iOS ever suspends it (most likely with a fixed location), turn on
*Settings → Data sources → Keep app alive with silent audio*.

## Moving settings between devices / editing on a computer

- **Phone ↔ iPad:** Settings → Import / export → *Share settings file* → AirDrop → on the other device, save it to Files and use *Import*.
- **On a computer (or iPad browser):** open [`tools/settings-editor.html`](tools/settings-editor.html) in any browser (download the file and double-click it).
  It opens with the default settings; load your exported file to edit yours. Change anything (every profile, rule table, building blocks…),
  then *Save settings file* and import it in the app. Everything stays in your browser.
- **Same device:** in the editor press *Copy settings*, then in the app use *Import from clipboard* (works with Universal Clipboard from a Mac too).
- The app also keeps `settings.json` in **Files → On My iPhone → Storm Radio**.

Older settings files keep working: anything missing is filled in with defaults.

## Data sources

| Source | Used for |
|---|---|
| api.weather.gov (NWS) | Alerts, your NWS office/county/zone, AFDs, SPC text products (MDs, watches, outlooks) |
| spc.noaa.gov | Outlook risk areas (GeoJSON) |
| Iowa Environmental Mesonet | NWS Local Storm Reports (GeoJSON) |
| SpotterNetwork | Spotter reports placefile |
| mPING | Crowd-sourced reports (optional, needs an API token) |

Alert downloads are limited to your state + neighbors by default to save cellular data.

## Known limitations / ideas for later

- Hasn't been tested on a real device yet. Please report anything odd (what you heard vs. what you expected).
- CarPlay: speech plays through CarPlay audio, but a CarPlay *screen* needs an Apple entitlement that sideloaded apps can't get.
- iOS can't play "critical alert" sounds through silent mode without an Apple entitlement; keep the ringer/volume up.
- Ideas: storm-track based (radar) ETAs, quiet hours, spoken county names for zone alerts, Siri/Shortcuts buttons, an iOS widget, Live Activities.

## For developers

```
Packages/StormRadioCore/   Swift package with all the logic (parsing, tracking, wording, settings) – runs on Linux/macOS
  Sources/StormRadioCore/  Geo, VTEC, WeatherAlert, AlertTracker, AlertPhraser, StormMonitor, Settings, …
  Sources/stormradio-cli/  Command-line simulator (run the engine against live data)
  Tests/                   Unit tests using real feed samples
App/                       SwiftUI iOS app (services + views)
project.yml                XcodeGen spec (the .xcodeproj is generated)
tools/                     Web settings editor
.github/workflows/         Builds the unsigned IPA on macOS
```

```bash
cd Packages/StormRadioCore
swift test                                                    # unit tests
swift run stormradio-cli simulate --lat 35.22 --lon -97.44   # run the radio against live data
swift run stormradio-cli simulate --lat 35.22 --lon -97.44 --minutes 30   # keep polling
swift run stormradio-cli defaults                             # print default settings JSON
```

On a Mac: `brew install xcodegen && xcodegen generate && open StormRadio.xcodeproj`.
