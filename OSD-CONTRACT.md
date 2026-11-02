# Player OSD contract (#466)

The Mac/iOS player OSD is split so the Android-parity entries (E2-E11) each fill their own
files and never edit someone else's. This page is the whole contract; the Android reference is
`PlaybackActivity.java` and `OsdTint.java` in the Android wrapper.

## Who owns which file

| entry | files (Dobby/Playback/) |
|---|---|
| E1 (scaffold) | PlayerView.swift (composition, input), PlayerControls.swift (state, layers, router), OSDStyle.swift, OSDSheet.swift, PlayNativePayload.swift, this page |
| E2 control bar, progress, seek | ControlBar.swift, PlayerControls+Transport.swift, ScrubState.swift |
| E3 subtitles sheet | SubtitleSheet.swift, SubtitleOrdering.swift (pure) |
| E4 audio + quality sheets | AudioSheet.swift, QualitySheet.swift |
| E5 style sheet + subtitle render | StyleSheet.swift, SubtitleOverlay.swift |
| E6 subtitle delay pill | SubsDelayPill.swift, SubsDelayModel.swift (pure) |
| E7 aspect | AspectSheet.swift, AspectModel.swift (pure) |
| E8 coordinator + bridge | PlaybackCoordinator.swift (`requestBookmark()` is stubbed there) |
| E9 More menu, Pause on OK, shortcuts, Speed | MoreMenu.swift, ShortcutsOverlay.swift |
| E10 pause info cards | PauseInfoCards.swift |
| E11 loaders | PlayerLoaders.swift |

Rules:
- Edit only your files. If you need something in an E1 file, say so in your report; do not edit it.
- Your state goes in the struct your file declares (`ControlBarState`, `TransportState`,
  `SubtitleSheetState`, `SubtitleStyleSettings`, `SubsDelayModel`, `AspectModel`,
  `MoreMenuState`). PlayerControls holds one `@Published var` per struct, so a mutation
  re-renders the OSD. Add fields to your struct; never add stored properties to PlayerControls.
- Functions go in `extension PlayerControls` (logic, keys) and `extension PlayerView` (views) in
  your file. PlayerView's state (`controls`, `playback`, `time`, `subtitles`, `scrub`,
  `isPlaying`) is internal so your extension can read it. View-local animation state can live
  in your own `struct ...: View` inside your file.
- Pure files (SubtitleOrdering, SubsDelayModel, AspectModel) import Foundation only.
  Tests/run-checks.sh already compiles each with `Tests/<Name>Check.swift`; extend that check.
- New Swift files under Dobby/ are picked up by xcodegen (`xcodegen generate`); project.yml
  does not change.
- A guard in Tests/run-checks.sh pins your file? Keep it green or update its needle in the same
  commit. Known ones: ControlBar.swift (#115 / #128 / #129 / #131 Slider rules), the #205
  `dobbyNative*` callback set (E8 adds `dobbyNativeBookmarkRequest` and
  `dobbyNativeSubtitleTracks` to its EXPECTED set).

## Composition (PlayerView.body, bottom to top)

video (`.aspectTransform(controls.aspect)`, E7) · picture clicks (Mac) / tap regions (iOS) ·
`subtitleOverlay` (E5) · `playerLoaders` (E11) · info stats · `pauseInfoCards` (E10) ·
`controlBarLayer` (E2) · close button · `moreMenu` (E9) · `shortcutsOverlay` (E9) · the open
sheet (`OSDSheetView`, E1) · `subsDelayPill` (E6) · toast.

Every component view is always in the tree and decides itself whether to draw (an empty
`ZStack` when closed), so you never need PlayerView to gate you.

## Layers and the key router

Layers, top first: subtitle delay pill (`subsDelayOpen`) > sheet (`sheet`) > shortcuts card
(`shortcutsOpen`) > More menu (`moreOpen`) > control bar (`visible`) > bare picture. The flags
live in PlayerControls; open and close them only through:

- `openSheet(.x)`, `toggleSheet(.x)`, `closeSheet()` (focus lands on the selected row)
- `openSubsDelay()` (SubsDelayPill.swift), `openMoreMenu()` (MoreMenu.swift), `toggleShortcuts()`
- `closeTopLayer()` (Esc, iOS edge swipe), `hide()` (bar and every layer), `wake()` /
  `forceShow()` / `scheduleHide()` (bar; auto-hide 5 s while playing, never while paused, a
  resume from pause hides it at once)
- or set your own flag to `false` directly (`subsDelayOpen = false`, `moreOpen = false`).

Whenever the bar and every layer are closed the router calls `onBarePicture()` (MoreMenu.swift),
the Pause-on-OK resume hook; it may be called repeatedly and must check its own flag.

Keys: PlayerView's NSEvent monitor (keyDown and keyUp, Command/Control chords excluded) maps to
`OSDKey` (`.left .right .up .down .ret .escape .space`, `.char(c)` for the US-layout key at that
position: a s d f b q w i , . / and `?` = Shift-slash) and calls `controls.keyDown(_:isRepeat:)`
/ `keyUp(_:)`. On iOS a hardware keyboard (iPad) feeds the same keys through PlayerView's
`HardwareKeys` first responder (UIKit sends no auto-repeat there), and the left-edge swipe is
`.escape` through the same router (#487).

    func <name>HandleKey(_ key: OSDKey) -> Bool   // in extension PlayerControls

Return `true` when your layer consumed the key (it is swallowed), `false` to let it fall to
the layer below. The router asks each OPEN layer in priority order; a key nobody takes ends at
the bare picture, so Space, f and the sheet letters work with a layer open. Esc closes the top
layer if its handler did not take it. Return repeats never reach a handler; Return's keyUp
only ends the hold timer. Handlers the router calls:

| handler | file | called when |
|---|---|---|
| `subsDelayHandleKey` | SubsDelayPill.swift | pill open |
| `subtitleSheetHandleKey`, `audioSheetHandleKey`, `qualitySheetHandleKey`, `speedSheetHandleKey`, `aspectSheetHandleKey`, `styleSheetHandleKey` | the sheet's file | that sheet open, BEFORE the generic sheet keys |
| `shortcutsHandleKey` | ShortcutsOverlay.swift | card open |
| `moreMenuHandleKey` | MoreMenu.swift | More menu open |
| `controlBarHandleKey` | ControlBar.swift | bar visible |
| bare picture (router) | PlayerControls.swift | nothing above took it |

Bare picture: Space `togglePlay()`, left/right `seekKey(∓1)`, up/down `jumpKey(±1)`
(Transport, E2), Return `okPress()` (show/hide the bar; calls `pauseOnOkIfEnabled()` first,
E9) and arms the 550 ms hold that opens the shortcuts card, `?` shortcuts, `,` `.` `/`
`subsDelayGlobalKey` (E6, return false to pass), b `bookmark()`, s/a/q/w/d the subtitles /
audio / quality / aspect / speed sheets, f fullscreen, i info, Esc leaves fullscreen then closes
the player. A click on the picture is `okPress()`, a double-click fullscreen.

## Sheets

A sheet component provides `func <name>SheetContent() -> OSDSheetContent` (title, rows, optional
tabs with `activeTab` and `selectTab`), rebuilt from live state on every render, and is a case of
`PlayerControls.Sheet` (subtitles, audio, quality, speed, aspect, style). `OSDSheetView` draws it:
centred 420 pt card, at most 60 % of the height, rows filled `row`, focused row filled `accent`
with `onAccent` text, "✓ " before a selected row, disabled rows dimmed. macOS: a click outside the card
closes the sheet. iOS: the sheet has no dismiss layer, so the bar and the close X stay tappable
under it; a tap on the picture (ControlBar.swift `touchRegions`) closes the top layer. Rows, tabs
and chevrons are at least 44 pt tall on iOS; macOS keeps its sizes (#487).

Rows are `OSDItem(id:label:detail:selected:enabled:adjust:action:)`. `action` runs on Return or a
click; picking never closes the sheet (call `closeSheet()` in your action for Android's
close-on-pick). A row with `adjust` is an arrow row "◀ label ▶": left/right or a chevron click
call `adjust(-1 / +1)`.

Generic sheet keys (after your handler declined): up/down move `focusIndex` (wrapping);
left/right adjust the focused arrow row, else switch tabs when the sheet has tabs, else left
closes and right picks; Return picks.

Focus: `controls.focusIndex` is the one row index for keyboard and mouse. Hover sets it, a click
sets it and picks, the keys move it, `openSheet` puts it on the first selected row. Draw focus
from it; never keep a second index for the same rows.

## Colours and toast

`controls.tint` is the `OsdTint` for the payload's `skin` ("appletv" = Apple TV, anything else
Simple): `accent`, `onAccent`, `progress` (nil = platform tint), `osdFill`, `panel`, `sheet`,
`row`, `text`, `tabText`, `menuCard`, `menuSelected`, plus `accent(alpha)` / `text(alpha)` for
Android's alpha bytes (0x66 hairline, 0x4D sheet hairline, 0xB3 meta). Cards use
`.osdCard(fill:radius:hairline:)`. Sizes: Android dp as points, Android raw px halved.

Toast: `controls.flash("text")` shows the top-centre pill for 1.4 s; a new flash replaces it.
