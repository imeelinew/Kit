<p align="center">
  <img src=".github/assets/readme-icon.png?v=20261024" width="112" height="112" alt="Kit app icon">
</p>

<h1 align="center">Kit</h1>

<p align="center">
  A native macOS clipboard history tool built for keyboard workflows<br>
  Capture text, code, links, and images, then search and paste back into the source app
</p>

<p align="center">
  <a href="README.md">简体中文</a> ·
  <a href="README.en.md">English</a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue.svg" alt="License: AGPL-3.0"></a>
  <img src="https://img.shields.io/badge/macOS-27%2B-black.svg" alt="macOS 27+">
  <img src="https://img.shields.io/badge/Swift-6.4-orange.svg" alt="Swift 6.4">
</p>

<p align="center">
  <img src=".github/assets/readme-screenshot.png" alt="Kit clipboard history palette" width="820">
</p>

## Overview

Kit transforms clipboard history into an on-demand command palette, enabling seamless capture, search, pinning, and pasting entirely via keyboard workflows, with all data kept strictly on your local device

## Key Features

- **Multi-Type Capture & Smart Classification**: Automatically captures plain text, Markdown, code, links, file paths, and images with source app and timestamp metadata, using local rule classification
- **Multi-Dimensional Search & Offline OCR**: Instant results powered by SQLite FTS full-text search, featuring full Pinyin and initialism matching for Chinese, plus local offline OCR to index and highlight matching text within image previews
- **Keyboard-First Workflow**: Summon the palette instantly with a customizable global shortcut, paste directly, copy immediately, or paste continuously while keeping the palette open, automatically switching to English input to ensure uninterrupted typing, with quick deletion undo
- **Image Pinning & Full Preview**: Pin image clippings to the front of the screen as floating sticky notes, supporting small, medium, and large sizing with transparent checkerboard backgrounds, and hover over list items for instant full-size previews
- **Stacks & Organization**: Organize frequent clippings into custom Stacks, with dedicated shortcuts to switch rapidly across groups and content type filters
- **Privacy & Granular Control**: All history resides strictly in local SQLite storage without cloud dependencies, with customizable application exclusion lists (Keychain Access and Passwords excluded by default), retention policies, and temporary capture pausing
- **Native macOS Craftsmanship**: Built purely with Swift and SwiftUI/AppKit and Liquid Glass, offering Light/Dark appearances, subtle keyboard sound effects, and trackpad haptic feedback

## Shortcuts

| Shortcut | Description |
| --- | --- |
| `⌥ W` | Toggle clipboard palette (customizable) |
| `Return` | Paste selected item and close palette |
| `⇧ Return` | Paste selected item and keep palette open |
| `⌘ Return` | Copy selected item to system clipboard |
| `⌘ K` | Open item action menu |
| `⌘ Z` | Undo last deletion (prioritizes text undo when editing) |
| `⌥ ↓` / `⌥ ↑` | Switch to next / previous Stack |
| `⌥ ⌘ ↓` / `⌥ ⌘ ↑` | Switch to next / previous content type filter |

## Privacy and Permissions

All clipboard history and search indexes remain on your Mac without external cloud sync, and macOS Accessibility permission is required on first paste to return content to your active application

## Build from Source

Requirements: macOS 27+, Xcode 27+, Swift 6.4+

```bash
git clone https://github.com/imeelinew/Kit.git
cd Kit
open Kit.xcodeproj
```

Select the **Kit** scheme in Xcode and choose **Product → Run** to build and launch

## License

Kit is open-sourced under the [GNU Affero General Public License v3.0](LICENSE)
