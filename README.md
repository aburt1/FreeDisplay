# FreeDisplay

> **Free & open-source alternative to [BetterDisplay](https://github.com/waydabber/BetterDisplay)** — all the core display management features, zero cost.

A macOS menu-bar app that gives you DDC brightness/contrast control, HiDPI virtual displays, display arrangement, color profile switching, software display disconnect, and more — without the paid Pro tier.

This is a fork of [huberdf/FreeDisplay](https://github.com/huberdf/FreeDisplay) with the UI translated to English and several new features (see [What's new in this fork](#whats-new-in-this-fork)).

[Report an Issue](https://github.com/aburt1/FreeDisplay/issues)

---

## What's new in this fork

| Change | Notes |
|--------|-------|
| **English UI** | Every user-facing string translated from the upstream's Chinese-only UI. |
| **Software display disconnect** | Per-display toggle to make macOS treat an external monitor as unplugged. Uses the same private SkyLight API path Lunar and BetterDisplay use (`SLSBeginDisplayConfiguration` / `SLSConfigureDisplayEnabled` / `SLSCompleteDisplayConfiguration`). Apple Silicon, macOS 13+. The panel itself enters self-sleep because it sees no HPD signal. |
| **Disconnect persists across restarts** | Disconnected displays are remembered by stable UUID in `UserDefaults`, re-applied on next launch. Logout/reboot clears state (uses `kCGConfigureForSession`) so there's always a recovery escape hatch. The currently-main display is never auto-disconnected on launch, even if it was last session. |
| **Ghost rows for disconnected displays** | A disconnected display vanishes from `CGGetOnlineDisplayList` but stays visible in the FreeDisplay menu so you can toggle it back on. |
| **Auto-restore on reconnect** | After a disconnect/reconnect cycle, FreeDisplay re-applies your saved resolution, software brightness, and gamma — WindowServer otherwise defaults to a base mode after SLS toggles. The same re-apply runs on app launch (the upstream only re-applied on wake-from-sleep). |
| **Layout fix** | Fixes a regression where the menu's `ScrollView` inside `MenuBarExtra(style: .window)` collapsed to zero height, showing only the Quit button. |
| **Security fix** | `HiDPIService.executePrivilegedCommand` now AppleScript- and shell-escapes its arguments. The upstream version interpolated paths into `do shell script ... with administrator privileges` with no escaping — a future caller passing untrusted input would have been a root RCE. |
| **Cleaner build defaults** | Project signs ad-hoc by default, no `DEVELOPMENT_TEAM` required. Anyone can `git clone && xcodegen && xcodebuild` without flags or an Apple Developer account. |

---

## Features

| BetterDisplay feature | FreeDisplay | Notes |
|----------------------|:-----------:|-------|
| DDC Brightness & Contrast | ✅ | Hardware control via IOKit I2C (Intel) / IOAVService (Apple Silicon) |
| Software Brightness (Gamma) | ✅ | Per-display gamma table control with smooth transitions |
| Keyboard Brightness Keys for External Displays | ✅ | Intercepts brightness keys when the cursor is on an external display, shows the native macOS OSD |
| Auto Brightness Sync | ✅ | Syncs external display brightness with the built-in display |
| HiDPI Virtual Displays | ✅ | Creates HiDPI dummy displays via `CGVirtualDisplay` private API |
| Display Arrangement | ✅ | Position displays (external above built-in, etc.) |
| Resolution & HiDPI Switching | ✅ | Browse and switch all available display modes including HiDPI |
| ICC Color Profile Management | ✅ | Switch color profiles per display via ColorSync |
| Image Adjustment (Gamma/Temperature) | ✅ | Software contrast, color temperature, RGB channels, invert |
| Display Presets | ✅ | Save & restore full display configurations with one click |
| Virtual Display (Dummy) | ✅ | Create headless virtual displays |
| Notch Management | ✅ | Hide the MacBook notch with a black overlay |
| **Software Display Disconnect** | ✅ **(new in this fork)** | Toggle a display off so macOS treats it as unplugged |
| Launch at Login | ✅ | Via `SMAppService` |

### Not included (intentionally)

- Screen streaming / PiP — rarely used, adds complexity
- EDID override — requires SIP disabled
- XDR/HDR extra brightness — requires specific hardware

---

## Installation

There are no signed binary releases of this fork. Build it from source — it's ~30 seconds once Xcode and `xcodegen` are installed.

### Prerequisites

- macOS 14 or later (macOS 13+ for the disconnect feature)
- Apple Silicon (Intel works for most features; disconnect is Apple-Silicon-only)
- [Xcode](https://apps.apple.com/us/app/xcode/id497799835) (the full IDE — not just Command Line Tools)
- [Homebrew](https://brew.sh)

### Build & install

```bash
# Install xcodegen
brew install xcodegen

# Clone and build
git clone https://github.com/aburt1/FreeDisplay.git
cd FreeDisplay
xcodegen generate
xcodebuild -scheme FreeDisplay -configuration Release build

# Find the built app and move it to /Applications
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "FreeDisplay.app" -path "*/Build/Products/Release/*" -print -quit)
cp -R "$APP" /Applications/

# Clear the quarantine attribute so Gatekeeper doesn't block first launch
xattr -dr com.apple.quarantine /Applications/FreeDisplay.app

# Launch it
open /Applications/FreeDisplay.app
```

FreeDisplay sits in the menu bar — look for the monitor icon up top.

### First-launch notes

- The app is **ad-hoc signed**, not Developer-ID signed. macOS treats it as untrusted by default.
- The `xattr -dr com.apple.quarantine` step above tells Gatekeeper to skip the warning. If you skip that step, the first launch needs **right-click → Open** (one-time approval).
- The app will not auto-update — pull from this repo when you want changes.

### Updating

```bash
cd /path/to/FreeDisplay
git pull
xcodebuild -scheme FreeDisplay -configuration Release build
killall FreeDisplay 2>/dev/null
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "FreeDisplay.app" -path "*/Build/Products/Release/*" -print -quit)
rm -rf /Applications/FreeDisplay.app && cp -R "$APP" /Applications/
xattr -dr com.apple.quarantine /Applications/FreeDisplay.app
open /Applications/FreeDisplay.app
```

---

## Permissions

| Permission | Why |
|------------|-----|
| **Accessibility** | Required for brightness key interception on external displays. Grant in System Settings → Privacy & Security → Accessibility on first use. |

You can deny the optional screen-recording prompt if it appears — nothing in the code reads screen contents.

No internet connection required (except optional update checks against the GitHub Releases API, which are inert until you publish releases under this fork).

---

## How it works

FreeDisplay sits in your menu bar and talks directly to your displays:

- **External monitors** — DDC/CI protocol over I2C (Intel) or IOAVService (Apple Silicon) for hardware brightness, contrast, and input control.
- **Built-in display** — CoreGraphics gamma tables for software brightness adjustment.
- **Brightness keys** — A `CGEventTap` intercepts brightness up/down media-key events (no other keys observed) and routes them to the display under your cursor, then shows the native OSD via XPC to `com.apple.OSDUIHelper`.
- **Auto brightness** — Polls the built-in display brightness via the private CoreDisplay API (`dlsym`) and proportionally adjusts external displays.
- **HiDPI** — Creates virtual displays via `CGVirtualDisplay`, or writes display-override plists for persistent HiDPI (requires admin authentication on toggle).
- **Software disconnect** — Wraps the private `SLSConfigureDisplayEnabled` transactional pattern (`SLSBegin…` → `SLSConfigure…` → `SLSComplete…`) to mark a display as offline at the WindowServer level. The panel sees no HPD signal and enters self-sleep on its own.

---

## Tech stack

- **Swift 6** + **SwiftUI** (`MenuBarExtra`)
- **IOKit** — DDC/CI I2C for hardware brightness/contrast
- **CoreGraphics** — Display enumeration, resolution, arrangement
- **ColorSync** — ICC color profile management
- **SkyLight (private)** — Display disconnect transaction (`dlsym`)
- **CGVirtualDisplay (private)** — Virtual display creation (macOS 14+)
- **CoreDisplay (private)** — Built-in display brightness reading (`dlsym`)
- Zero third-party dependencies

---

## Project structure

```
FreeDisplay/
├── App/              # AppDelegate, app entry point
├── Models/           # DisplayInfo, DisplayMode, DisplayPreset
├── Services/         # System-level services (DDC, brightness, resolution, gamma, disconnect, …)
└── Views/            # SwiftUI views for each feature section
```

---

## Contributing

Issues and PRs welcome. This project uses:

- `xcodegen` for project generation — edit `project.yml`, not `.xcodeproj`
- Swift 6 with `SWIFT_STRICT_CONCURRENCY: minimal`
- MVVM architecture (View → ViewModel → Service)

---

## License

MIT — see [LICENSE](LICENSE).

---

## Acknowledgments

- [**huberdf/FreeDisplay**](https://github.com/huberdf/FreeDisplay) — the original project this fork is built on
- Inspired by [BetterDisplay](https://github.com/waydabber/BetterDisplay), [MonitorControl](https://github.com/MonitorControl/MonitorControl), and [Lunar](https://lunar.fyi/)
- Software-disconnect technique referenced from the open-source [Lumen](https://github.com/trollzem/Lumen) project (`SLSConfigureDisplayEnabled` transactional pattern)
- `CGVirtualDisplay` bridging header based on [Chromium's `virtual_display_mac_util.mm`](https://chromium.googlesource.com/chromium/src/+/main/ui/display/mac/test/virtual_display_mac_util.mm)
