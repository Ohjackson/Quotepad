<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="QuickMemo icon">
</p>

<h1 align="center">QuickMemo</h1>

<p align="center">
  A Spotlight-style scratchpad for macOS. Press <kbd>⌘</kbd> <kbd>'</kbd> anywhere, jot it down, and get back to work.
</p>

<p align="center">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white">
  <img alt="No dependencies" src="https://img.shields.io/badge/dependencies-none-brightgreen">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

<p align="center">
  <img src="docs/screenshot.png" width="640" alt="QuickMemo overlay with tabs and copyable code boxes">
</p>

## Why

Some notes don't deserve a Notes.app document: an email address you're about to paste, a command you'll run three times today, a phone number from a call. QuickMemo is a single floating panel that appears over whatever you're doing and disappears when you're done. No windows to manage, no Dock icon, no sync, no accounts.

## Features

- **Global hotkey.** <kbd>⌘</kbd> <kbd>'</kbd> toggles the panel from any app, on any Space, even over full-screen apps.
- **Tabs.** Keep several notes side by side. Tab titles come from each note's first line.
- **Copyable code boxes.** Type `/code` and press <kbd>Return</kbd> to insert a one-line box for emails, API keys and shell commands. The box scrolls horizontally and has a one-click copy button. Smart quotes and autocorrect are off inside boxes, so what you copy is exactly what you typed.
- **Survives crashes and power loss.** Notes are saved 1 second after you stop typing (at most 5 seconds during non-stop typing) using `F_FULLFSYNC` and an atomic rename, and are flushed on quit, sleep and shutdown.
- **Make it yours.** Light/dark theme, seven background tints (sticky-note yellow included), background opacity, font size, and system, monospaced or serif fonts.
- **Stays out of the way.** Lives in the menu bar, hides when you click elsewhere (optional), remembers its size and, optionally, its position.
- **Plain text on disk.** Everything lives in one JSON file. Code boxes are stored as Markdown fences, so your notes are readable without the app.
- **Tiny.** One Swift package with AppKit and nothing else.

## Install

QuickMemo isn't notarized yet, so build it from source. You need macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/YOUR_USERNAME/QuickMemo.git
cd QuickMemo
./scripts/build-app.sh --install
```

This builds `QuickMemo.app`, copies it to `~/Applications` and launches it. Look for the note icon in the menu bar.

To start QuickMemo at login, open the gear menu in the panel (or the menu bar icon) and turn on **Launch at login**.

## Usage

| Shortcut | Action |
| --- | --- |
| <kbd>⌘</kbd> <kbd>'</kbd> | Show / hide the panel (works everywhere) |
| <kbd>⌘</kbd> <kbd>T</kbd> | New tab |
| <kbd>⌘</kbd> <kbd>W</kbd> | Close tab (hides the panel on the last tab) |
| <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>[</kbd> / <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>]</kbd> | Previous / next tab |
| <kbd>⌃</kbd> <kbd>Tab</kbd> / <kbd>⌃</kbd> <kbd>⇧</kbd> <kbd>Tab</kbd> | Next / previous tab |
| <kbd>⌘</kbd> <kbd>,</kbd> | Settings |
| <kbd>Esc</kbd> | Hide the panel |
| `/code` <kbd>Return</kbd> | Insert a code box |

Standard editing shortcuts (<kbd>⌘</kbd> <kbd>C</kbd>/<kbd>X</kbd>/<kbd>V</kbd>/<kbd>A</kbd>/<kbd>Z</kbd>, <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>Z</kbd>) work as usual. Shortcuts are matched by key position, so they keep working with non-Latin input sources such as Korean.

Inside a code box, <kbd>Return</kbd> or <kbd>↓</kbd> moves to the line below, <kbd>↑</kbd> moves above, and <kbd>Delete</kbd> in an empty box removes it. Copying a selection that contains boxes puts Markdown fences on the clipboard, and pasting fenced text creates boxes.

Tabs close for good: there's no trash. Click the **×** on a tab, middle-click it, or press <kbd>⌘</kbd> <kbd>W</kbd>.

> [!NOTE]
> The interface is currently in Korean. Localization pull requests are very welcome.

## Where your notes live

```
~/Library/Application Support/QuickMemo/tabs.json
```

Settings are stored in `UserDefaults` under `dev.micheal.QuickMemo`. **Settings → Open data folder** reveals the file in Finder. If the file is ever unreadable, QuickMemo moves it aside as `tabs.corrupt-<timestamp>.json` instead of overwriting it.

## Development

```bash
swift build -c release
QUICKMEMO_DATA_DIR=/tmp/quickmemo-dev ./.build/release/QuickMemo
```

`QUICKMEMO_DATA_DIR` points a development build at a separate folder so it can run next to your installed copy without touching your real notes. Only one instance can use a given data folder at a time.

| Path | Purpose |
| --- | --- |
| `Sources/QuickMemo/AppDelegate.swift` | Panel, tabs, shortcuts, saving, global hotkey |
| `Sources/QuickMemo/CodeBlock.swift` | Code boxes (TextKit 2 view attachments) and the note ⇄ Markdown codec |
| `Sources/QuickMemo/TabBarView.swift` | Tab strip UI |
| `Sources/QuickMemo/DurableStore.swift` | Crash-safe file writes |
| `Sources/QuickMemo/Settings.swift` | Preferences, background tints, login item |
| `Sources/QuickMemo/SettingsViewController.swift` | Settings popover |
| `scripts/build-app.sh` | Builds and installs the `.app` bundle |
| `scripts/make-icon.swift` | Regenerates `Resources/AppIcon.icns` and `docs/icon.png` |

## Contributing

Issues and pull requests are welcome. Keep the app small and dependency-free, and make sure `swift build` finishes without warnings.

## License

[MIT](LICENSE) © Jaehyun Ahn
