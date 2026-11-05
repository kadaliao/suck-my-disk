# Changelog

**English** · [简体中文](CHANGELOG.zh-CN.md)

All notable changes to SuckMyDisk. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[semantic versioning](https://semver.org/).

## [Unreleased]

### Added

- **External disks.** Each connected disk (USB or Thunderbolt drive, SD card,
  writable disk image) gets a row in the sidebar and its own page: projects
  and render frames on it, a map, and a Clean Up that works on that disk and
  measures the space freed there. Disks are scanned when plugged in, on Rescan
  and after Clean Up, not followed live; the last scan is shown meanwhile.
  Without Full Disk Access a disk is scanned only when you click Scan.
- `smd things /Volumes/<name>` and `smd reclaim /Volumes/<name>` for external
  disks. `smd things` lists connected disks at the end.

### Changed

- The toolbar's Rescan (⌘R) rescans the disk on screen.
- A disk's own root folder can never be deleted.
- bun's global packages folder (`bun/install/global`) is never treated as a
  project, wherever it lives.

## [0.3.1] - 2026-11-05

Requires macOS 26 (Apple silicon or Intel). Signed with a Developer ID and
notarized. The index format is unchanged, so upgrading needs no rescan.

### Fixed

- Tools that are Node scripts (npm, Yarn, pnpm) failed in the app with
  `env: node: No such file or directory`: cleaning the npm cache never worked,
  so it kept coming back, and the pnpm store was never found. An app opened
  from Finder only has `/usr/bin:/bin` on its PATH; commands now also get the
  tool's own folder and the usual Homebrew and user locations.
- The result sheet showed a green check even when items failed. Failures are
  now marked in orange and listed apart from skipped items.

## [0.3.0] - 2026-11-05

Requires macOS 26 (Apple silicon or Intel). Signed with a Developer ID and
notarized. The index format is unchanged, so upgrading needs no rescan.

### Added

- **Demo mode.** `--demo` shows made-up projects, caches and models without
  reading or writing the disk; Clean Up only pretends. The screenshots in the
  docs come from it (`scripts/doc-screenshots.sh`).
- Documentation for a long-lived open-source project, in English and Chinese:
  README with a usage introduction, user guide, architecture overview,
  contributing guide, release process, security policy, code of conduct, and
  issue and pull request templates, with screenshots in both languages.
- MIT license.
- Releases include a signed, notarized `.dmg`: open it and drag the app into
  Applications. Added to 0.2.0 as well.

## [0.2.0] - 2026-11-04

Requires macOS 26 (Apple silicon or Intel). Signed with a Developer ID and
notarized.

### Added

- **Live updates.** After the first scan, the index follows the disk through
  FSEvents: a changed folder is re-read on its own, new folders are scanned,
  removed ones drop out. A 2 GB download shows up within a few seconds.
- Opening the app, or running `smd`, replays only what changed while it was
  closed instead of rescanning. On a five-million-file disk: 0.3 s instead of
  about 50 s.
- Busy folders (browser caches, logs) are re-read at most every few seconds;
  huge ones (a Photos library, 100k-file caches) are refreshed in the
  background every few minutes.
- Numbers update right away; recognition reruns in the background when enough
  has changed. Checkbox choices survive refreshes.
- **App icon**: a tapered spiral in the five category colors, built with Icon
  Composer (Liquid Glass, light and dark).
- **Privacy**: without Full Disk Access, folders macOS asks about one by one
  (Desktop, Documents, Downloads, iCloud Drive, other apps' data, external
  volumes) are left alone instead of raising dialogs. The overview says so and
  links to System Settings.

### Changed

- Project recognition runs git checks only for artifacts big enough to list,
  in parallel (12 s → under 1 s on a large disk).

### Fixed

- The app starts working even when it launches without its main window (menu
  bar only).
- The whole-disk map stays valid while the disk changes.

### Upgrade note

The index format changed, so the first launch of 0.2.0 does one full scan.

## [0.1.0] - 2026-11-04

First release. Requires macOS 26 (Apple silicon or Intel). Signed with a
Developer ID and notarized.

### Added

- **Overview**: free space, a capacity bar split by kind (projects, render
  frames, dev caches, models, app data, your files, apps, system), and how
  much can safely be freed.
- **Reclaim lists**: forgotten projects (dependencies and build output; source
  and git untouched, restore command recorded), render frames whose final
  video exists, dev caches cleaned by each tool's own command, local models,
  and app data with in-app cleanup instructions.
- **Clone-aware numbers**: a `.venv` cloned from the uv cache frees nothing
  unless both go, and the app says so.
- Whole-disk treemap colored by kind, a daily growth timeline, and a menu bar
  item with free space.
- Chinese and English, following the system language.
- **`smd`** command line with the same engine and index: `smd things`,
  `smd reclaim` (dry run by default), `smd hibernate`, `smd wake`,
  `smd journal`.

[Unreleased]: https://github.com/kadaliao/suck-my-disk/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/kadaliao/suck-my-disk/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/kadaliao/suck-my-disk/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/kadaliao/suck-my-disk/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kadaliao/suck-my-disk/releases/tag/v0.1.0
