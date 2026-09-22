<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="Kit">
</p>

<h1 align="center">Kit</h1>

<p align="center">
  A native macOS clipboard history tool built for keyboard workflows<br>
  Text, code, link, and image capture with full-text search, Pinyin search, and fast paste-back
</p>

<p align="center">
  <a href="#workflow">Workflow</a> ·
  <a href="#build-from-source">Build from source</a>
</p>

<p align="center">
  <a href="README.en.md">English</a>
  <a href="README.md">简体中文</a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License: AGPL-3.0"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/storage-SQLite-2f74c0" alt="SQLite">
</p>

---

<p align="center">
  <img alt="Kit clipboard history palette" src=".github/assets/app.png" width="860">
</p>

## About

Kit is a native macOS clipboard history tool that keeps copied content inside a lightweight command palette. It recognizes text, code, links, and images, records the source application, and turns search, selection, and paste-back into a keyboard-driven workflow.

History is stored in a local SQLite database, with image payloads managed as local files. SQLite FTS5 and a Pinyin index search the complete history, including Chinese text found through full spelling or initials.

## Why Kit

The system clipboard remembers only the latest copy, while many clipboard managers turn into permanent, feature-heavy windows. Kit behaves more like a focused command palette: summon it when needed, find and paste an item, then return immediately to the previous app.

- **Multiple content types**: classifies plain text, code, links, and images
- **Full-history search**: SQLite FTS5 searches beyond the in-memory window
- **Pinyin search**: supports full spelling and initials with source-text highlighting
- **Keyboard first**: arrow-key selection plus shortcuts for paste, pin, preview, and actions
- **Image preview**: on-demand thumbnails and a Space-bar Quick Look sized to available screen space
- **Source aware**: displays the copy source and pastes back into the app that was active before the palette opened

## Workflow

Press `Option + W` to show or hide the palette. Type to search, move with the arrow keys, and press Return to paste.

- `Return`: paste and close the palette
- `Command + Return`: copy the selected item
- `Command + P`: pin or unpin an item
- `Space`: preview an image
- Action menu: paste while keeping the palette open, reveal images in Finder, delete entries, and more

The global shortcut is configurable. Kit can also switch to an English input source when the palette opens, making Pinyin queries immediately available.

## Local Storage and Privacy

The clipboard database and image files stay on the Mac; no cloud service is required. Retention can be set from one day to forever, and pinned items are exempt from automatic pruning.

Applications can be excluded from capture. Keychain Access and Passwords are excluded by default so sensitive content does not enter history. Accessibility permission is required to deliver the selected item reliably to the original target app.

## More Features

- Sections for pinned, today, yesterday, past seven days, past thirty days, and earlier
- Code syntax highlighting and link recognition
- Memory-bounded image caches with background downsampling
- Launch at login
- System, light, and dark appearances
- Simplified Chinese and English interfaces

## Build from Source

You need macOS 26, Xcode 26, and Swift 6.

```bash
git clone https://github.com/imeelinew/Kit.git
cd Kit
open Kit.xcodeproj
```

Select the **Kit** scheme and choose **Product → Run**. Grant Accessibility permission when prompted before the first paste operation.
