# Dobby in the car, without an Apple CarPlay entitlement

Research date: 2026-08-02. Primary source: [CarPlay Developer Guide, June 2026](https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf) (read in full).

## The gate, stated once

A CarPlay app icon and CarPlay template UI require an Apple-assigned entitlement
(`com.apple.developer.carplay-audio`, or the new iOS 27 `com.apple.developer.carplay-video`).
That entitlement lives in a provisioning profile Apple issues to your account.

- No approval means the key cannot be signed into a build — local, ad-hoc, **or TestFlight**.
  TestFlight uses an App Store distribution profile, same chain, same missing key.
- The Simulator is not a loophole either: "Xcode and Simulator require a Provisioning Profile
  that supports CarPlay."
- iOS 27's video category changes nothing here — same request form, same review.

Everything below assumes that path is closed and asks: what still reaches the car?

---

## Lane 1 — System Now Playing (works today, biggest value per line of code)

CarPlay's Now Playing screen is fed by `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` — the
same pipeline as the lock screen. Any app playing audio appears there with no entitlement. This
is not a consolation prize: it is the *playback* half of a CarPlay audio app, on the car's own
screen, with steering-wheel buttons wired up.

Already working: the web player sets `navigator.mediaSession` (`js/11-media-session.js`), and
as of this session the native KSPlayer lane merges `title` + `poster` artwork into
`nowPlayingInfo` (`Playback/PlaybackCoordinator.swift`).

Still on the table, all entitlement-free:

| Addition | Effect on the car screen |
| --- | --- |
| `skipBackwardCommand`/`skipForwardCommand` + `preferredIntervals` | 30 s skip buttons instead of track skip |
| `changePlaybackPositionCommand` | Draggable scrubber |
| `MPMediaItemPropertyAlbumTitle` / `MPMediaItemPropertyArtist` | Series and author/channel lines |
| `MPNowPlayingInfoPropertyChapterNumber` / `ChapterCount` | "Chapter 4 of 27" for audiobooks |
| `MPNowPlayingInfoPropertyPlaybackRate` + `changePlaybackRateCommand` | Speed control from the car |
| `MPNowPlayingInfoPropertyIsLiveStream` | Correct UI for live YouTube |
| `bookmarkCommand` | Head-unit button drops a Dobby bookmark |

Ceiling: no browsing. You can only control what the phone already started.

## Lane 2 — Audio-only mode + car detection (no approval, needs web-side change)

`/api/smarttube/playback` already returns a separate `audioUrl`, and `PlayNativePayload` carries
it. Playing audio-only means no video decode, no heat, no battery burn, and works with the phone
locked in a pocket.

Detect the car with `AVAudioSession.currentRoute.outputs.contains { $0.portType == .carAudio }`
(plus `.bluetoothA2DP`), and on route change switch Dobby into a car mode: audio-only stream
selection, bigger touch targets on the phone screen, auto-resume of the last item.

Ceiling: still phone-driven. But this is what makes YouTube subscriptions usable as a podcast
feed during a commute.

## Lane 3 — Siri (no CarPlay entitlement, works from the steering wheel)

`INPlayMediaIntent` (SiriKit Media) and App Intents both work in CarPlay without a CarPlay
entitlement — Siri is the one part of the car UI open to non-CarPlay apps.

- "Play *Project Hail Mary* in Dobby", "Resume in Dobby", "Next chapter in Dobby".
- Requires an `AppEntity` for books/shows plus `AppShortcuts` phrases. Known caveat from the
  field: dynamic parameter matching is unreliable; `AppEnum`/`AppEntity`-backed parameters with
  a resolved candidate set behave far better than free-text ones.

Ceiling: voice only, no visual browsing, and Siri media matching is finicky.

## Lane 4 — Live Activity on the CarPlay Dashboard (no approval, iOS 26+)

The guide is explicit: "Your app does not need to be a CarPlay app to support Live Activities in
CarPlay." Support the small activity family and the same view renders on the CarPlay Dashboard:

```swift
.supplementalActivityFamilies([.small])
```

Without it, CarPlay falls back to your Dynamic Island compact leading/trailing views. So a
"now playing" Live Activity gives Dobby a real card on the car's Dashboard — art, title,
chapter progress — with no entitlement at all.

Cost: a Widget Extension target (the project has none yet).

## Lane 5 — Widget on the Dashboard (partial, hard ceiling)

Widgets also render in CarPlay without an entitlement, but the guide states the limit plainly:
"Your widget can only launch your app in CarPlay if your app is also a CarPlay app." So a widget
is glanceable-only for Dobby. Whether an `AppIntent`-backed interactive button (play/pause) still
runs is not documented either way — worth a 30-minute test with CarPlay Simulator once a widget
target exists, but do not plan around it. Live Activities (Lane 4) are the better use of the same target.

---

## Lane 6 — The one that actually gets a browse UI on the car screen

**Make Dobby's server speak a protocol that an already-entitled CarPlay app understands, and
let that app be the car UI.**

The Subsonic/OpenSubsonic API is the right target: it is small, documented, read-mostly, and
several iOS clients ship CarPlay support with Apple's blessing already granted to *them*:

- **Amperfy** — free, open source, App Store, CarPlay, offline caching.
- **play:Sub** — paid, explicitly advertises CarPlay browsing.

Decisive detail: Subsonic clients talk **directly from the device to your server**, so the
existing `dobby.solarflare-tarpon.ts.net` Tailscale name works as-is. Nothing needs to be
exposed publicly. (This is exactly what kills the podcast-RSS alternative below.)

### What the facade needs

Auth is `md5(password + salt)` sent as `t`/`s`, or an OpenSubsonic `apiKey`; `f=json` for JSON.
A read-only facade over the existing `LibraryStore`/`ProgressStore` is roughly:

| Endpoint | Dobby mapping |
| --- | --- |
| `ping`, `getLicense` | static OK |
| `getMusicFolders`, `getIndexes`, `getArtists`, `getArtist` | authors/narrators from `/api/books` |
| `getAlbum`, `getAlbumList2` | one book = one album, chapters = tracks |
| `getSong`, `stream`, `download` | existing chapter files, Range already handled server-side |
| `getCoverArt` | existing book covers |
| `search2`/`search3` | library search |
| `getPlaylists`/`getPlaylist` | "Continue listening" from `/api/progress` |
| `createBookmark`/`getBookmarks` | **position sync back into Dobby** — Subsonic bookmarks carry a ms position, which is how audiobook clients resume |
| `scrobble` | mark played |
| `getPodcasts` (optional, later) | YouTube subscriptions as channels, audio streams proxied via the existing SmartTube proxy routes |

Estimated ~2 days server-side in Vapor. Watch: `.m4b` should be served as `audio/mp4` with an
`.m4a`-shaped name, since some clients sniff extensions.

Result: full CarPlay browsing of audiobooks — artists, albums, chapters, search, resume, offline
caching — on the car screen, with zero Apple involvement. Movies stay out (they are video, and
their resolve latency is unusable in a car anyway); YouTube audio can follow as a second phase.

### Weaker variants of the same idea

- **Private podcast RSS feed** consumed by Overcast/Pocket Casts (both CarPlay-entitled). Fails
  on the same detail Subsonic wins on: those apps poll feeds **server-side**, so the feed would
  have to be publicly reachable (Tailscale Funnel + secret token), not tailnet-only.
- **Sync M4B files into the Music app** via Finder. The Music app is a full CarPlay app, so the
  files browse natively — but it is a manual copy, with no progress sync and no YouTube.

---

## What shipped (2026-08-02)

Lanes 1, 2, 3, 4 and 6 are implemented. Lane 5 (widget) stays skipped — the guide's
"a widget can only launch your app in CarPlay if your app is also a CarPlay app" is a
hard ceiling, and Lane 4 uses the same extension target better.

**Lane 1 — Now Playing.** `PlaybackCoordinator` merges title, artist, album and poster
artwork into `nowPlayingInfo` (KSPlayer only fills what the *stream* carries, which for
torrent and YouTube URLs is nothing), declares `MPNowPlayingInfoPropertyMediaType =
.audio` and `IsLiveStream`, sets skip intervals to 30 s to match the web player, and
disables next/previous track — KSPlayer wires those to its playlist API, which Dobby
has no use for, leaving two dead buttons on the car. Web side, `js/11-media-session.js`
puts "Book — chapter N of M" in the album line, honours the head unit's own
`details.seekOffset`, and adds a `stop` handler. New payload fields: `artist`, `album`
(`js/21-android-tv.js`, `js/22-smarttube.js` → `PlayNativePayload`).

**Lane 2 — Car detection + audio-only.** `Playback/CarRoute.swift` watches
`AVAudioSession.routeChangeNotification` for a `.carAudio` output. (Bluetooth A2DP is
deliberately not treated as a car: headphones report the same port type.) When a car is
connected, an adaptive YouTube pair plays its **audio representation alone** — no video
decode, no heat, works with the phone pocketed. The flag is latched on
`window.Dobby.isCarAudio` and pushed to `window.bookPlayNativeAudioRoute`.

**Lane 3 — Siri.** `Dobby/Intents/` adds `PlayBookIntent` (a `BookEntity` backed by
`/api/books`, not free text — Siri matches a resolved candidate set far better),
`PlayYouTubeIntent`, `ResumePlaybackIntent`, `StopPlaybackIntent`, plus `AppShortcuts`
phrases ("Play *Project Hail Mary* in Dobby", "Play *lofi* on Dobby", "Resume Dobby",
"Stop Dobby"). Commands park in `VoiceCommandQueue` and are handed to the web app once
it reports `ready`; `js/23-voice.js` runs them through the existing UI entry points.

**Lane 4 — Live Activity.** New `DobbyWidgets` extension target (iOS 26 floor, which is
when `supplementalActivityFamilies([.small])` shipped) renders a Now Playing card on the
lock screen, Dynamic Island **and the CarPlay Dashboard**. Driven by
`Playback/NowPlayingActivity.swift` for the native lane and by the new `setNowPlaying`
bridge action for the web audiobook lane. Pushes are throttled to one per 15 s — the
widget's `ProgressView(timerInterval:)` advances on its own clock in between.

**Lane 6 — OpenSubsonic facade.** `Sources/BookPlayServer/SubsonicRoutes.swift` serves
`/rest/*` (author = artist, book = album, chapter = song), in XML and JSON. Position
sync is real: `createBookmark` / `savePlayQueue` write straight into `ProgressStore`, so
a drive and the web app share one resume point.

**Lane 6b — YouTube in the same facade.** `SubsonicYouTube.swift` adds a synthetic
`YouTube` artist: its albums are "Recently watched" plus one per subscribed channel,
its songs are videos played audio-only, and `search3` returns YouTube hits alongside
book hits so one search box in the car covers both. Ids are `so-yt-<videoId>` /
`al-ytc-<channelId>-<hexTitle>`.

Everything is served by calling this server's own SmartTube endpoints over loopback,
which reuses the whole resolve cascade instead of duplicating it. `stream` resolves
the video and 307s to `/api/smarttube/playback/proxy` — googlevideo signs URLs against
the Pi's outbound IP and rejects the phone's, so the bytes must come back through the
Pi, and that proxy already handles ranges and the 403 user-agent cascade.

Two things to know:

- Audio track selection prefers AAC-in-MP4. AVFoundation cannot decode Opus-in-WebM,
  YouTube's other audio-only option, so an Opus pick would fail silently in the car.
- When a video resolves with no separate audio representation, the muxed progressive
  stream is served instead — audio still plays, but at video bitrate. Each resolve
  logs which path it took, visible with `systemctl --user status bookplay -n 40`:

  ```
  [subsonic] yt e1xr7KiN3KY audio-only audio/mp4; codecs="mp4a.40.2"
  ```

  If that reads `muxed fallback` instead, the resolve cascade is not producing
  adaptive pairs and the car is paying for frames nobody sees.

`/api/smarttube/feed/trending` is deliberately not exposed — it parses to an empty
item list, which in a car is an album that opens onto nothing.

## Lane 7 — Spotify lyrics on the Dashboard (2026-08-03)

The one car experience that does not need Dobby to play anything. Spotify keeps the
audio, the CarPlay screen and the steering-wheel controls; Dobby only answers "what
words are these". Research notes first, because three of them decided the shape:

**There is no way to read another app's Now Playing on iOS.** `MPNowPlayingInfoCenter`
is write-only for your own app, and the private `MediaRemote` route that works on macOS
is sandboxed away on iOS. Knowing what Spotify plays means asking Spotify.

**The Spotify iOS SDK is the wrong tool here.** App Remote is push-based and would
avoid polling entirely, but Spotify's own guidance is to *disconnect* it when your app
backgrounds, and it drops the connection after ~30 s idle. Backgrounded is precisely
when this lane has to work, so the Web API's `GET /v1/me/player/currently-playing` is
the source instead — and the SDK's binary framework never enters the tree.

**Spotify's quota is small and undocumented.** Development Mode apps (5 users, app
owner must have Premium) share one quota per developer account; a 429 now carries
`"reason": "QUOTA_EXCEEDED"` and often no `Retry-After`. So a reading is treated as a
*resync*, never a tick: the phone runs its own clock and the network only disciplines it.

**The Pi polls; the phone listens.** `GET /api/spotify/stream` is SSE. The Pi runs one
watcher — 2 s while a track plays, 10 s while paused, and it wakes *exactly* at the end
of a song rather than a couple of seconds into the next — and it only runs while someone
is connected, so an idle app costs zero quota. Every listener shares that one upstream
call. The first design had the phone polling every 10 s, which is how long the previous
song's words could stay up after a skip.

**Clock discipline, not a deadband.** The phone anchors on `progress_ms + ageMs` and
advances on `ProcessInfo.systemUptime` (monotonic — a wall-clock correction mid-song
would shift every remaining line). Each event computes the error: over 1.2 s it is a
seek, a skip or a phone that was asleep, and it snaps; under that it folds in 35 % of the
error per event, converging in a few seconds without yanking the highlighted line
backwards mid-word. Track changes and pause/resume always snap, since both change what
the clock means. The earlier "ignore anything under 1.5 s" rule *was* the desync people
saw: being 1.4 s out simply never corrected. This also sidesteps the long-standing bug
class where `progress_ms` goes stale between pause/seek events on some clients.

**What is left over is a knob, because it is not derivable.** LRCLIB timings are
contributed against whichever release the contributor owned, and Spotify's reported
position carries a lag of its own. `LyricsView` has a ±0.25 s nudge that persists in
`UserDefaults` (tap the readout to zero it).

**Lyrics do not come from Spotify at all** — its lyrics are a Musixmatch licence with no
public API. [LRCLIB](https://lrclib.net) is free and keyless: `/api/get` wants artist +
track + album + duration and 404s if the duration is more than ~2 s off, so a
`/api/search` fallback picks the nearest duration within 10 s (preferring a synced entry)
— without that window, "Creep" resolves to an acoustic cut whose timings are wrong.
A plain miss is usually a *naming* miss, not an absent song, so the same lookup is
retried with Spotify's decorations stripped ("- 2011 Remaster", "(feat. …)") and the
lead artist alone, then as free text. Lyrics are cached per track id on the Pi forever;
misses expire after a week, since LRCLIB gains transcriptions over time. Cache filenames
carry a matcher generation (`-m2`) — a cached miss only means "the matcher of the day
found nothing", so improving the matcher has to invalidate them.

### Shape

Server (`Sources/BookPlayServer/SpotifyLyrics.swift`, `SpotifyRoutes.swift` in the
`dobby` repo) owns the OAuth round trip and the token. That is not an aesthetic
preference: Spotify only accepts **HTTPS** redirect URIs, and the Pi is the side with a
certificate (`tailscale serve`). PKCE means there is no client secret to copy anywhere.
The phone opens `/api/spotify/login?redirect=dobby://spotify-connected` in an
`ASWebAuthenticationSession` and the browser closes itself when the token lands.

The screen holds `GET /api/spotify/stream?have=<trackId>` open; `GET
/api/spotify/state?have=<trackId>` is the same payload as a one-shot, used before the
screen is open and as a probe. It returns the track,
`progressMs` with the `ageMs` it already spent on the Pi, and the whole lyric timeline —
omitted once the caller says it has it, so the steady-state response is a few hundred
bytes. Scopes are read-only (`user-read-currently-playing`, `user-read-playback-state`):
a leaked token cannot touch anyone's playback.

Phone (`Dobby/Spotify/`) runs the clock. `SpotifyLyricsSession` ticks at 4 Hz, tracks the
current line, and pushes it to two places: `LyricsView` (full-screen, big type,
auto-scrolling — for a mounted phone) and the Lane 4 Live Activity with `kind == "lyrics"`
(current line bold, next line dim — for the CarPlay Dashboard). `LyricsBody` renders
tighter when `@Environment(\.activityFamily) == .small`, which is the size class CarPlay
uses.

### The part that is a hack, named as such

A Live Activity can only be updated **in process**, and unlike the progress bar there is
no widget primitive that walks arbitrary text on its own clock — `Text(timerInterval:)`
counts, it does not read. So the lyrics freeze the moment iOS suspends Dobby, which is
seconds after the user switches to Spotify. `AudioKeepAlive` holds the app open with a
1-second near-silent WAV looped through an `AVAudioSession` set to `.playback` +
`.mixWithOthers`: mixable so Spotify is neither interrupted nor ducked, near-silent
rather than all zeroes because iOS reclaims apps that hold a session and emit nothing.
Dobby never claims Now Playing, so Spotify keeps the car's metadata and buttons.

The `audio` background mode was already declared for the audiobook lane, so nothing new
is requested. Two things to know anyway:

- App Store review guideline 2.5.4 exists and this stretches it. Irrelevant for a
  sideloaded/`@live`-signed build; it would be a conversation for a public release.
- The keepalive only runs while a lyrics session is on, and stops with it.

**Push-based updating was considered and rejected**: ActivityKit's push budget is hourly
and throttles even with `NSSupportsLiveActivitiesFrequentUpdates`, whereas a line changes
every few seconds. Local updates from a running app are not on that budget — hence the
keepalive rather than APNs.

### Turning on the lyrics lane

1. Create an app at [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard)
   (the owner needs Premium) with redirect URI
   `https://dobby.solarflare-tarpon.ts.net/api/spotify/callback`, and add your own
   account under *Users Management* — Development Mode 403s tokens that are not
   allowlisted.
2. Paste the client ID into Dobby settings (`spotifyClientId`; `spotifyRedirectURI`
   overrides the default if you registered a different one — it must match exactly).
3. Open Dobby with Spotify playing: a pill appears top-right. Tap it, connect once, and
   the lyrics take over. Plugging into the car auto-starts it from then on.

Failure modes are visible rather than silent: "No lyrics for this track" when LRCLIB has
nothing, "Spotify is throttling — following on the local clock" on a 429 (the line keeps
advancing; it just stops resyncing until the backoff clears).

### Turning on the Subsonic facade

Disabled unless a password is set — an open library endpoint is not a safe default.
In `bookplay.service`:

```
Environment=BOOKPLAY_SUBSONIC_USER=dobby
Environment=BOOKPLAY_SUBSONIC_PASSWORD=<pick one>
```

Then in Amperfy (or play:Sub): server `https://dobby.solarflare-tarpon.ts.net`, that
username and password. The phone must be on the tailnet; nothing is exposed publicly.

## Sources

- [CarPlay Developer Guide, June 2026 (PDF)](https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf)
- [Requesting CarPlay Entitlements](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
- [OpenSubsonic API reference](https://opensubsonic.netlify.app/docs/api-reference/) ·
  [endpoint list](https://opensubsonic.netlify.app/docs/endpoints/)
- [Amperfy (BLeeEZ/amperfy)](https://github.com/BLeeEZ/amperfy) · [play:Sub](https://apps.apple.com/app/play-sub-music-streamer/id955329386)
- Now Playing works without entitlement: [Apple forum thread 96104](https://developer.apple.com/forums/thread/96104)
