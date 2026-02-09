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
- **Keyboard Navigation** — Use arrow keys to select windows, Enter to activate, Esc to dismiss
- **Window Snapping** — Snap windows to left half, right half, or full screen from the preview panel
- **Settings GUI** — Proper settings window with tabs (General, Appearance, About), accessible via Cmd+, or menu bar
- **Korean / English** — In-app language switching between English and 한국어
- **Force Primary Display** — New app windows always open on your primary monitor
- **Launch at Login** — Start DockPeek automatically when you log in
- **Safe Permission Handling** — Revoking accessibility permission won't freeze your system
- **Configurable** — Adjust thumbnail size, toggle window titles, exclude specific apps

## Install

### Homebrew (Recommended)

```bash
brew tap ongjin/dockpeek
brew install --cask dockpeek
```

> **First launch:** macOS will block the app because it is self-signed (not notarized by Apple).
> Go to **System Settings → Privacy & Security → Security** and click **"Open Anyway"** next to the DockPeek message.

### Build from Source

```bash
git clone https://github.com/ongjin/dockpeek.git
cd dockpeek
make setup
```

> Building from source avoids the Gatekeeper warning entirely.
> After the first `make setup`, use `make dev` for fast rebuilds without re-granting permissions.

## Permissions

DockPeek requires two system permissions:

| Permission | Why | Where to grant |
|---|---|---|
| **Accessibility** | Detect Dock clicks and control windows | System Settings → Privacy & Security → Accessibility |
| **Screen Recording** | Capture window thumbnails | System Settings → Privacy & Security → Screen Recording |

## Usage

1. Launch DockPeek — a menubar icon appears
2. Click the menubar icon for a menu (Settings, About, Quit)
3. Click any Dock icon for an app with 2+ windows
4. A preview panel pops up with thumbnails of all windows
5. Click a thumbnail to switch to that window
6. Hover a thumbnail to see a live preview overlay at the window's actual position
7. Click the X button to close a window right from the panel
8. Use arrow keys (←→) to navigate, Enter to activate, Esc to dismiss
9. Hover over a thumbnail to reveal snap buttons (left half / full / right half)

> Apps with only one window behave normally — DockPeek stays out of the way.

## Settings

Click the menubar icon → **Settings...** (or press **Cmd+,**) to open the settings window.

### General
- **Enable DockPeek** — Toggle the feature on/off
- **Launch at login** — Start DockPeek automatically on login
- **Force new windows to primary display** — New app windows always open on your main monitor
- **Language** — Switch between English and 한국어 (instant, no restart needed)
- **Permission status** — See whether Accessibility permission is granted

### Appearance
- **Thumbnail size** — Adjust preview size (120–360px)
- **Show window titles** — Display titles below thumbnails
- **Live preview on hover** — Show overlay at the window's screen position on hover

### About
- App version info
- **Buy Me a Coffee** — Support development
- **GitHub** link
- **Excluded Apps** — Skip specific apps by Bundle ID

## How It Works

1. A `CGEventTap` (session-level) intercepts global left-click events
2. A fast geometric check determines if the click is in the Dock area
3. Accessibility API identifies which app icon was clicked
4. Window list and thumbnails are captured via `CGWindowListCreateImage`
5. A floating preview panel is displayed with keyboard navigation and snap controls
6. Selecting a window activates it via the SkyLight private API (same approach as AltTab)
7. A background watchdog monitors accessibility permission to prevent system freezes if revoked

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
│   ├── SettingsView.swift         # Settings window with tabs (General/Appearance/About)
│   └── OnboardingView.swift       # First-launch permission guide
├── Models/
│   ├── WindowInfo.swift           # Window metadata + thumbnail
│   └── DockApp.swift              # Dock icon → app mapping
└── Utilities/
    ├── L10n.swift                 # Korean/English localization strings
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
