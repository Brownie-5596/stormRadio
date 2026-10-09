# Storm Radio — notes for coding sessions

Personal iOS/iPadOS storm-alert "radio" (sideloaded with Sideloadly; single user). Reads NWS alerts, SPC products,
AFDs and storm reports aloud, filtered by a per-profile configuration. See README.md for the feature list.

## Layout
- `Packages/StormRadioCore` — all logic, Foundation-only (builds/tests on Linux). Public API used by the app.
  - `WeatherAlert.swift` (NWS CAP JSON → model, IBW tags, storm motion), `VTEC.swift`, `Geo.swift`
  - `AlertTracker.swift` — groups messages by VTEC event key (watches keyed nationally `SPC.TO.A.0123`),
    emits lifecycle events (initial/issued/updated/partiallyCancelled/cancelled/expired/ended/upgraded) + `AlertChange` diffs.
  - `AlertPhraser.swift` + `Announcement.swift` — wording (template blocks or `{placeholder}` custom format), update/cancel text,
    `StormPath` ETA math, `AlertGeo` distances.
  - `StormMonitor.swift` — **actor**; polls feeds via `WeatherClient`, applies profile rules (range, per-type distance, polygon area),
    produces `Announcement`s. `process(alerts:now:)` / `process(reports:now:)` are network-free entry points for tests.
  - `Settings.swift`, `ProductCatalog.swift` (default rules + built-in profiles), `SettingsIO.swift` (lenient import: deep-merge onto defaults).
  - `StormReports.swift` (IEM LSR GeoJSON, SpotterNetwork placefile, mPING), `SPCProducts.swift` (MD, SEL watch, outlook text + GeoJSON, AFD).
  - `ToneSynth.swift` — built-in tones generated as PCM. `ToneID` is string-backed; `custom:<file>` = user sound in Documents/Sounds
    (played by the app's `TonePlayer` via AVAudioPlayer, falls back to double beep if missing).
- `App/` — SwiftUI app (iOS 17+). Tabs: Radio, Feed, Products (MD/watch/outlook/AFD/report browser), Map, Settings.
  `ReadableText` = tap-a-word-to-read text with spoken-word highlight (SpeechCenter.read / readingHighlight). `AppModel` (@MainActor) owns the monitor loop, `SpeechCenter` (priority queue, interrupts,
  AVSpeechSynthesizer, audio session ducking), `TonePlayer` (AVAudioEngine + silent keep-alive), `LocationService`, `NotificationService`, `Storage`.
- `project.yml` — XcodeGen; `.xcodeproj` is generated and git-ignored.
- `tools/settings-editor.src.html` → `tools/settings-editor.html` via `tools/build_settings_editor.py <defaults.json>` (embeds defaults).

## Build & test
- Linux: Swift toolchain may need installing (swift.org tarball, Ubuntu 24.04). Then `cd Packages/StormRadioCore && swift test`.
- Live check: `swift run stormradio-cli simulate --lat 35.22 --lon -97.44 [--radius 150]`.
- iOS build only happens in GitHub Actions (`.github/workflows/build-ios.yml`, macos-15, Xcode 16.4): runs core tests,
  `xcodegen generate`, unsigned `xcodebuild`, zips `Payload/` → `StormRadio.ipa`, uploads the artifact and publishes the
  `latest` release (see below). Compile errors are printed by the "Show compile errors" step.
- App target uses Swift 5 language mode (minimal concurrency checking).
- Each CI build gets version `0.2.<run number>` / build `<run number>` and is published to the fixed `latest` release
  (`StormRadio.ipa`, `altstore-source.json` made by `tools/make_altstore_source.py`, `icon.png`). The app's `UpdateChecker`
  reads that source file to show "update available".

## Conventions / gotchas
- Settings are Codable with no per-field defaults in decoding; **always go through `SettingsIO.decode`** (it merges onto defaults).
  When adding a setting: add it to the struct + init default, and (optionally) a label in `tools/settings-editor.src.html` LABELS,
  then rebuild the editor HTML.
- New `PhraseBlockKind` cases are appended disabled to old templates by `MessageTemplate.normalize()`.
- NWS `/alerts/active` includes CAN/EXP messages briefly; events missing for 2 polls are treated as ended/expired.
- Keep spoken text TTS-friendly (spell "N W S", avoid URLs; use `Spoken.normalizeForSpeech`).
- No paid-account entitlements (CarPlay, critical alerts, push) — sideloaded with a free Apple ID.
