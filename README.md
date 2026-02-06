# DockPeek

**Windows-style window preview for macOS Dock.**

Click any Dock icon to see thumbnail previews of all open windows for that app.
Pick the exact window you want — no more cycling through them all.

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Window Preview** — Click a Dock icon to see thumbnails of every open window for that app
- **Single Window Activation** — Click a thumbnail to bring just that window to the front (works with full-screen Spaces too)
- **Live Preview on Hover** — Hover over a thumbnail to see where the window is on your screen
- **Close from Preview** — Hit the X button on a thumbnail to close that window directly
- **Configurable** — Adjust thumbnail size, toggle window titles, exclude specific apps

## Install

### Homebrew (Recommended)

```bash
brew tap ongjin/dockpeek
brew install --cask dockpeek
```

### Build from Source

```bash
git clone https://github.com/ongjin/dockpeek.git
cd dockpeek
make setup
```

> On first launch, you'll need to grant Accessibility permission.
> After that, use `make dev` for fast rebuilds without re-granting.

## Permissions

DockPeek requires two system permissions:

| Permission | Why | Where to grant |
|---|---|---|
| **Accessibility** | Detect Dock clicks and control windows | System Settings → Privacy & Security → Accessibility |
| **Screen Recording** | Capture window thumbnails | System Settings → Privacy & Security → Screen Recording |

## Usage

1. Launch DockPeek — a menubar icon appears
2. Click any Dock icon for an app with 2+ windows
3. A preview panel pops up with thumbnails of all windows
4. Click a thumbnail to switch to that window
5. Hover a thumbnail to see a live preview overlay at the window's actual position
6. Click the X button to close a window right from the panel

> Apps with only one window behave normally — DockPeek stays out of the way.

## Settings

Click the menubar icon to open the settings popover:

- **Enable DockPeek** — Toggle the feature on/off
- **Thumbnail size** — Adjust preview size (120–360px)
- **Show window titles** — Display titles below thumbnails
- **Live preview on hover** — Show overlay at the window's screen position on hover
- **Excluded Apps** — Skip specific apps by Bundle ID

## How It Works

1. A `CGEventTap` intercepts global left-click events
2. A fast geometric check determines if the click is in the Dock area
3. Accessibility API identifies which app icon was clicked
4. Window list and thumbnails are captured via `CGWindowListCreateImage`
5. A floating preview panel is displayed, and selecting a window activates it via the SkyLight private API (same approach as AltTab)

## Project Structure

```
DockPeek/
├── App/
│   ├── DockPeekApp.swift          # @main entry point
│   ├── AppDelegate.swift          # Menubar, event handling, orchestration
│   └── AppState.swift             # User settings (ObservableObject)
├── Core/
│   ├── EventTapManager.swift      # CGEventTap for global click interception
│   ├── DockAXInspector.swift      # Accessibility hit-test for Dock icons
│   ├── WindowManager.swift        # Window enumeration, thumbnails, activation
│   └── AccessibilityManager.swift # Permission check & prompt
├── UI/
│   ├── PreviewPanel.swift         # Floating NSPanel (non-activating)
│   ├── PreviewContentView.swift   # SwiftUI thumbnail grid with close button
│   ├── HighlightOverlay.swift     # Live preview overlay at window position
│   ├── SettingsView.swift         # Menubar popover settings
│   └── OnboardingView.swift       # First-launch permission guide
├── Models/
│   ├── WindowInfo.swift           # Window metadata + thumbnail
│   └── DockApp.swift              # Dock icon → app mapping
└── Utilities/
    └── DebugLog.swift             # Debug-only logging
```

## Development

```bash
make setup      # First time: build → install to /Applications → launch
make dev        # Dev loop: swap binary in-place (permissions preserved)
make kill       # Stop running DockPeek
make dist       # Build release zip for distribution
make clean      # Remove build artifacts
```

## Known Limitations

- macOS has no official Dock click API — DockPeek relies on Accessibility hit-testing, which may change across OS versions
- `CGWindowListCreateImage` is deprecated since macOS 14 but still works; future versions may require ScreenCaptureKit migration
- Auto-hide Dock can cause timing edge cases where the hit-test misses

## License

MIT
