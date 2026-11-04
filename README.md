> [!IMPORTANT]
> This repository has no affiliation with NetEase Cloud Music, and contains none of its domains or API addresses.

<div align="right">

**English** | [简体中文](README_CN.md)

</div>

<div align="center">

<img src="docs/icon.png" width="140" alt="Kumone" />

# Kumone

**雲の音 — A native music player for macOS and iOS**

Built with SwiftUI · No third-party server · Sparkle auto-updates

[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue?logo=apple)](#building)
[![Swift](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](Package.swift)
[![License](https://img.shields.io/badge/license-LGPL--3.0--only-orange)](LICENSE)

<table>
  <tr>
    <td><img src="docs/screenshot-home.png" alt="Home" /></td>
    <td><img src="docs/screenshot-nowplaying.png" alt="Now Playing" /></td>
  </tr>
  <tr>
    <td><img src="docs/screenshot-daily.png" alt="Daily Recommendations" /></td>
    <td><img src="docs/screenshot-lyrics.png" alt="Lyrics Panel" /></td>
  </tr>
</table>

</div>

## About the Name

**Kumone** comes from the Japanese **雲の音** (*kumo no ne*, "the sound of clouds"), contracted into one word — **雲音** (くもね, *kumone*). The music drifting down to you from the cloud.

## Features

- 🔐 **QR code login** — scan with the official app; cookies are persisted locally and auto-refreshed
- 🏠 **Home** — daily recommendations, Personal FM, Heartbeat Mode, recommended playlists, radar playlists (Personal Radar family, personalized per account), charts, new albums, recommended artists
- 🧭 **Explore** — category playlists (curated / official / charts / mood) with infinite scrolling
- 🎵 **Playback** — AVPlayer engine, Standard to Hi-Res quality (lossless with 黑胶 VIP, automatic fallback), shuffle / repeat one / repeat all, play-next queue, gray track detection
- 🚗 **CarPlay (iOS, opt-in)** — Now Playing, tabbed library, queue, and search templates ship in the binary; activation requires an [Apple CarPlay audio entitlement](https://developer.apple.com/contact/carplay/), which is not granted to most accounts. Build defaults to disabled so the source tree stays open-source-friendly; see [Enabling CarPlay](#enabling-carplay-ios) below
- 🔓 **Gray track unblocking** — native implementation of the common unblock sources (pyncmd / Kuwo / Kugou); unavailable or trial-only tracks automatically resolve from third-party sources
- 🖼 **Immersive now-playing page** — artwork-tinted gradient backdrop, large artwork, big synced lyrics (click the player-bar artwork to open, Esc to close)
- 📻 **Personal FM** — immersive roaming page with trash / skip
- 📝 **Lyrics** — glass side panel with line-synced lyrics + translation, click to seek
- 🪟 **Desktop lyrics** — LyricsX-style floating always-on-top lyric line with translation; draggable, persisted position, visible across Spaces and full-screen apps
- 📚 **Library** — liked songs, created / subscribed playlists, saved albums, followed artists, recently played, cloud disk
- ✏️ **Playlist management** — create / delete / subscribe playlists, add / remove tracks, heart songs
- 🔍 **Search** — aggregate / songs / artists / albums / playlists, trending keyword placeholder
- ⌨️ **System integration** — media keys / Control Center (Now Playing), scrobbling, playback queue restored across launches
- ☁️ **iCloud Sync** — hand off playback progress and queues between Mac and iPhone, sync preferences, and share sign-in sessions; works via iCloud Drive shared folders and natively supports sideloaded builds without central servers (see [documentation](docs/icloud-sync/icloud-sync.md))
- 🌐 **Localization** — English and Simplified Chinese, following the system language; bilingual release notes in Sparkle updates

## Installation

Requires macOS 15+ (Universal: Apple Silicon and Intel).

### Homebrew

```bash
brew install owo-network/brew/kumone --cask
```

### Manual download

Download the latest `Kumone-x.y.z.zip` from
[Releases](https://github.com/missuo/kumone/releases/latest), unzip, and drag
it into Applications.

The app is signed with a Developer ID certificate and notarized by Apple, with
built-in Sparkle automatic updates (menu bar: Kumone → Check for Updates…).

### iOS / iPadOS (sideload)

Every release ships an **unsigned** `Kumone-iOS-x.y.z.ipa` (iOS 16+). Kumone
is an unofficial client and will not be on the App Store or TestFlight, so
install it with a sideloading tool that signs the IPA with your own Apple ID —
[AltStore](https://altstore.io), [SideStore](https://sidestore.io),
[Sideloadly](https://sideloadly.io) or Xcode all work. On iOS 26+ the tab bar is the system’s native Liquid Glass; on iOS 16–25 it falls back to a simulated glass bar.

Updating: iOS apps can't replace themselves. Settings → About → **Check for
Updates** tells you when a newer release exists and links to it; download the
new IPA and reinstall with the same tool — sign-in state and settings are kept.
AltStore / SideStore can also track the release automatically: add the source
<https://github.com/missuo/kumone/releases/latest/download/altstore.json> and
new versions show up in their update list on their own.

#### In-app auto-update (TrollStore only)

On a device with **[TrollStore](https://github.com/opa334/TrollStore)** (巨魔),
Kumone updates itself: Settings → About → **Check for Updates** (it also checks
on launch) downloads the new IPA with a progress ring and hands it to TrollStore
via `apple-magnifier://install?url=…` for a one-tap, fully automatic install —
the same mechanism Dopamine uses. This works **only under TrollStore**: a plain
AltStore/SideStore sideload is signed with a personal certificate and has no way
to install an IPA on-device, so there it degrades to opening the release page
for a manual re-sideload.

### Enabling CarPlay (iOS)

CarPlay support is fully implemented in `Sources/Kumone/Core/CarPlay/`, but the
**default build ships none of it**: no `com.apple.developer.carplay-audio`
entitlement, no `UISupportsCarPlay`, and no CarPlay scene declaration. Apple
only grants that entitlement after you submit a CarPlay audio app
[application](https://developer.apple.com/contact/carplay/), and building with
it unapproved fails to sign with:

> Entitlement com.apple.developer.carplay-audio not found and could not be
> included in profile.

So CarPlay is a one-command opt-in instead:

```bash
make configure-carplay   # enable
make configure           # back to the default, CarPlay-free build
```

`make configure-carplay` derives a CarPlay copy of `Config/Info.plist` and
`Config/KumoneIOS.entitlements` into `ios/Config/Generated/`, then writes
`ios/Config/CarPlay.local.xcconfig` to point the build at them. All three files
are untracked, and the Xcode project itself is never modified — so enabling
CarPlay leaves `git status` clean and produces nothing to review.

Once your developer account has the entitlement approved:

1. Apply for and obtain the **CarPlay (Audio)** capability for your App ID in
   [Apple Developer → Identifiers](https://developer.apple.com/account/resources/identifiers/list).
2. Regenerate the provisioning profile so it carries the new capability.
3. Run `make configure-carplay`.
4. `Cmd + Shift + K` and rebuild on a device.

To test without a car, use the CarPlay Simulator: Xcode ▸ Open Developer Tool ▸
Simulator, then I/O ▸ External Displays ▸ CarPlay.

### TestFlight (iOS)

The sideload build updates itself from GitHub releases (TrollStore hand-off or
an IPA download), which App Review does not allow. Builds for App Store Connect
therefore use the `TestFlight` configuration: Release plus
`ios/Config/TestFlight.xcconfig`, which writes `KumoneDistribution = testflight`
into Info.plist. `DistributionChannel` reads it at launch and hides the
in-app updater; everything else is the same binary. Debug and Release are
untouched, so CI and contributors keep the sideload build.

```bash
export KUMONE_TEAM_ID=XXXXXXXXXX          # or DEVELOPMENT_TEAM in ios/Config/TestFlight.local.xcconfig
make testflight                           # archive + export .build/testflight/export/KumoneIOS.ipa
make testflight UPLOAD=1                  # archive + upload to App Store Connect
make testflight UPLOAD=1 CARPLAY=1        # once the carplay-audio entitlement is approved
```

The version comes from the latest `v*` tag and the build number from the commit
count, the same as the release workflow; override with
`Scripts/testflight.sh --version 0.4.0 --build 1234`. Set `ASC_KEY_ID`,
`ASC_ISSUER_ID` and `ASC_KEY_PATH` to an App Store Connect API key for
unattended provisioning and upload; without them Xcode's signed-in account is
used. `CARPLAY=1` goes through the same `make configure-carplay` overlay as a
device build, so it fails to sign until the App ID has the capability.


## Building

Requires macOS 15+ and Xcode 26+.

```bash
swift build                    # compile
Scripts/build-app.sh           # package the .app (outputs .build/app/Kumone.app)
Scripts/compile_and_run.sh     # kill → repackage → relaunch
```

## Architecture

```
Sources/Kumone/
├── Core/
│   ├── API/            # RequestCrypto (weapi/eapi encryption), MusicClient (transport + cookies), MusicAPI (~50 endpoints)
│   ├── Models/         # unified Track model (tolerates both JSON shapes), lyrics parser
│   ├── Player/         # PlayerService (queue / shuffle / repeat / FM / URL resolution), UnblockService, NowPlayingManager
│   ├── Storage/        # AccountStore, SettingsManager, two-tier image cache
│   └── Sync/           # SyncService (cross-device playback handoff, preferences & login sync via iCloud Drive)
├── DesignSystem/       # design tokens, button styles (hover scale / row highlight / chips), skeletons, cards, marquee, artwork palette
└── Features/           # pages + player bar + immersive now-playing + lyrics/queue panels
```

No third-party API server involved: weapi (double AES-CBC + RSA) and eapi
(AES-ECB + MD5 digest) encryption are implemented natively in Swift.

## Credits

Kumone is written from scratch in Swift. No code was copied from the projects
below, but their design and implementation ideas were referenced extensively:

- [YesPlayMusic](https://github.com/qier222/YesPlayMusic) (MIT, © qier222) — feature design, and a reference for their API design conventions
- [kaset](https://github.com/sozercan/kaset) (MIT, © sozercan) — UI design system, motion, and SwiftPM packaging approach
- The open-source gray-track unblock server project (LGPL-3.0-only) — a reference for their API design conventions and source matching strategy (`UnblockService.swift` is an independent Swift reimplementation)
- [LyricsX](https://github.com/ddddxxx/LyricsX) (MPL-2.0, © ddddxxx) — desktop lyrics window design reference (window configuration, screen-factor positioning; `DesktopLyrics.swift` is an independent SwiftUI implementation)

## License

Licensed under [LGPL-3.0-only](LICENSE) (the [GPL-3.0](COPYING) text is
included alongside). For learning and personal use only — all music data and
rights belong to their respective owners and source platforms. No
downloading, no social features.
