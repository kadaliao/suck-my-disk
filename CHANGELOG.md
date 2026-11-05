# Changelog

**English** · [简体中文](CHANGELOG.zh-CN.md)

All notable changes to SuckMyDisk. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[semantic versioning](https://semver.org/).

## [Unreleased]

### Added

- **Demo mode.** `--demo` shows made-up projects, caches and models without
  reading or writing the disk; Clean Up only pretends. The screenshots in the
  docs come from it (`scripts/doc-screenshots.sh`).
- Documentation for a long-lived open-source project, in English and Chinese:
  README with a usage introduction, user guide, architecture overview,
  contributing guide, release process, security policy, code of conduct, and
  issue and pull request templates, with screenshots in both languages.
- MIT license.

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

[Unreleased]: https://github.com/kadaliao/suck-my-disk/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/kadaliao/suck-my-disk/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kadaliao/suck-my-disk/releases/tag/v0.1.0
