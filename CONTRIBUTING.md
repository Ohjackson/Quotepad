# Contributing to Quotepad

Thanks for helping out! Bug reports, ideas, translations and code are all welcome.

## Reporting bugs and requesting features

Open an [issue](https://github.com/Ohjackson/Quotepad/issues/new/choose) using one of the templates. For bugs, include your macOS version and steps to reproduce.

## Making a change

1. Fork the repository and create a branch from `main`.
2. Make your change (see the guidelines below).
3. Build and try it without touching your own notes:

   ```bash
   swift build -c release
   QUOTEPAD_DATA_DIR=/tmp/quotepad-dev ./.build/release/Quotepad
   ```

   `QUOTEPAD_DATA_DIR` keeps a development build's notes and lock file in a separate folder, so it can run next to an installed copy. Quit the installed app first if you want to test the global hotkey (<kbd>⌘</kbd> <kbd>'</kbd>), since only one app can own it.

4. To try the real app bundle (icon, login item, settings), run `./scripts/build-app.sh --install`.
5. Open a pull request against `main` and fill in the template.

## Guidelines

- **No dependencies.** Quotepad is AppKit and the Swift standard library only.
- **No warnings.** `swift build -c release` should finish cleanly.
- **Keep it small.** Quotepad is a scratchpad, not a notes database. Open an issue before starting large features so we can agree on the approach.
- **Never lose notes.** Changes to saving or the on-disk format (`tabs.json`, Markdown fences for code boxes) must stay backward compatible and crash-safe; see `DurableStore.swift`.
- **Input sources.** Shortcuts are matched by key code so they work with non-Latin keyboards such as Korean. Keep new shortcuts key-code based, and check they don't collide with standard text-editing bindings (`/System/Library/Frameworks/AppKit.framework/Resources/StandardKeyBinding.dict`).
- **UI text.** The interface is currently Korean. Localization (for example, moving strings to `Localizable.strings`) is a very welcome contribution.
- **Icon.** Edit `scripts/make-icon.swift` and run `swift scripts/make-icon.swift` rather than editing the generated files.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
