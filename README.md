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

Pushes to `main` auto-release to TestFlight via GitHub Actions.
