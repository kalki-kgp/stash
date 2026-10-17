# Stash

A clipboard history for macOS that stays small. Native Swift, no Electron.

With the same 1,000-item history (930 texts, 8 images, 28 file copies):

| | Maccy | Stash |
|---|---|---|
| Memory | ~1 GB | ~18 MB |
| History on disk | 369 MB | 8.7 MB |
| ⌘⇧C to panel on screen | | ~15 ms |
| Search per keystroke | | ~1 ms |

## How it stays small

- Text lives in SQLite with a trigram index, so search runs on disk instead of over a copy in memory.
- Formatting (RTF, HTML) is LZFSE-compressed. Web archives and duplicate encodings aren't kept.
- Images are stored once per picture (named by a hash of their pixels) as HEIC, with small thumbnails for the list.
- Decoding a big screenshot happens in a short-lived helper process, so the memory goes back to the system as soon as it's done.

## Keys

Same as Maccy:

| | |
|---|---|
| ⌘⇧C | Open |
| ↩ / click / ⌘1–9 | Copy |
| ⌥↩ / ⌥-click / ⌥1–9 | Copy and paste |
| ⌥⇧↩ / ⌥⇧-click / ⌥⇧1–9 | Paste without formatting |
| ⌥P | Pin / unpin |
| ⌥⌫ | Delete |
| ⌥⌘⌫ | Clear everything except pinned |
| ⇧⌥⌘⌫ | Clear everything |
| ⌥-click the menu bar icon | Pause saving copies |
| ⌥⇧-click the menu bar icon | Skip the next copy |
| Right-click the menu bar icon | Menu (Open at Login, Quit) |

Pasting into the front app needs Accessibility access. macOS asks the first time you use it.

On first launch Stash imports your Maccy history. It only reads Maccy's data and never changes it. Quit Maccy before using Stash, because the app that holds ⌘⇧C first keeps it.

## Install

Download the DMG from Releases and drag Stash to Applications.

The app isn't signed with an Apple developer certificate yet, so macOS blocks the first launch. Open it once, then go to System Settings → Privacy & Security and click **Open Anyway**. Or run:

```sh
xattr -dr com.apple.quarantine /Applications/Stash.app
```

## Build

Needs macOS 26 and the Command Line Tools (Xcode not required).

```sh
./build.sh                 # Stash.app
./test.sh                  # storage, search, capture, paste and import tests
Scripts/make-dmg.sh        # dist/Stash-<version>.dmg
```

`Tests/e2e/run.py` drives a test build (`./build.sh test`) end to end through the real clipboard.
