# Dobby

Native iOS/macOS wrapper for a PWA video app. A SwiftUI `WKWebView` shell hands
video off to a native player (KSPlayer = AVPlayer + FFmpeg/libass) for the
formats and streaming `<video>` can't do, and adds the OS integrations a web app
lacks: lock-screen / Now Playing controls, background audio, native fullscreen,
ASS subtitles, and Files-visible offline downloads.

All native behavior is gated behind a JS bridge, so the same web app stays
byte-identical in Safari / installed PWA.

## Build

| | |
|---|---|
| macOS app | `./install.sh` → installs to `/Applications` |
| iPhone (dev signing) | `./install.sh device` |
| TestFlight | `./install.sh testflight` (needs App Store Connect API key in env) |
| Mac DMG for friends, with Sparkle OTA updates | `scripts/mac-release.sh` (setup in its header) |

Pushes to `main` auto-release to TestFlight via GitHub Actions.

The Pi's https name (`<pi>.<tailnet>.ts.net`) is not in this repo. Export
`DOBBY_PI_HOST` before any of the builds above (CI takes it from the
`DOBBY_PI_HOST` repo secret); xcodebuild expands it into `WKAppBoundDomains`.
The Pi is retired and no build contacts it (#508), but that name is still the
origin the bundled app and its web data (settings, downloads index, sync state)
live under, so it must keep its exact value forever. `install.sh` and the
TestFlight workflow refuse to build without it (`scripts/mac-release.sh` must
have it exported too). A Debug build without it, on a device that stored no
other origin, says so on screen instead of starting.
