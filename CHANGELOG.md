# Changelog

**English** · [简体中文](CHANGELOG.zh-CN.md)

All notable changes to SuckMyDisk. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[semantic versioning](https://semver.org/).

## [Unreleased]

### Added

- **Language and appearance in Settings.** Settings (⌘,) has a General
  section: **Appearance** picks Light, Dark or the system's, and changes at
  once; **Language** picks 简体中文, English or the system's. A new language
  shows after the app reopens, which **Relaunch Now** does in a second or two
  with scan results kept; the lists are rewritten in the new language right
  after. The `smd` command keeps following the system language.

## [0.5.3] - 2026-11-09

Requires macOS 26 (Apple silicon or Intel). Signed with a Developer ID and
notarized. Copies of 0.5.0 and later get this release through the in-app
update. The index format is unchanged, so upgrading needs no rescan.

### Changed

- **Clean Up has its own page.** Once you confirm, the whole window shows the
  run instead of a small progress pill at the bottom: a ring that fills in item
  by item in each kind's color, the space freed so far (measured from the
  disk's free space as it goes), and every item with what happened to it. When
  the run ends, the same page shows the result, replacing the result sheet,
  and says how much went to the Trash and is freed only once you empty it.
  **Stop** finishes the running item and leaves the rest alone.

## [0.5.2] - 2026-11-08

Requires macOS 26 (Apple silicon or Intel). Signed with a Developer ID and
notarized. Copies of 0.5.0 and later get this release through the in-app
update. The index format is unchanged, so upgrading needs no rescan.

### Fixed

- Opening an external disk's page while that disk was being scanned could
  freeze the window for good (spinning cursor, 100% CPU) until SuckMyDisk was
  force-quit. The list on that page no longer lays itself out lazily, and the
  scan's file count now redraws only its own label instead of the whole page.

## [0.5.1] - 2026-11-08

Requires macOS 26 (Apple silicon or Intel). Signed with a Developer ID and
notarized. The app works exactly like 0.5.0; copies of 0.5.0 get this release
through the in-app update, the first one delivered that way. The index format
is unchanged, so upgrading needs no rescan.

### Added

- **Homebrew.** `brew install --cask kadaliao/tap/suck-my-disk` installs the
  app and `brew install kadaliao/tap/smd` the command line, from the
  [kadaliao/homebrew-tap](https://github.com/kadaliao/homebrew-tap) tap.

## [0.5.0] - 2026-11-08

Requires macOS 26 (Apple silicon or Intel). Signed with a Developer ID and
notarized. The index format is unchanged, so upgrading needs no rescan.

### Added

- **Apps.** A new section lists every app in Applications with the data it
  keeps in your Library (Application Support, Caches, Containers, Group
  Containers, Preferences, saved state, cookies, launch agents), largest
  first, with when you last opened it. Each app can be **uninstalled**, the
  app and all its data moved to the Trash where you can put them back, or
  kept while only its **caches** go: caches, logs, saved window state and
  Electron apps' cache folders. Nothing is preselected, and both are skipped
  while anything runs from the app. Picked by hand they don't wait out the
  7-day rule, since opening an app changes its folders. Apps that belong to
  the system (App Store, installers) are moved by Finder, which asks for your
  password. Warnings say when an app installed components for every user,
  came from Homebrew, or is managed by Setapp.
- `smd apps` lists installed apps; `smd uninstall <app>` uninstalls one
  (`--keep-app` clears only its caches), as a dry run until you add `--yes`.
- **Updates itself.** About once a day SuckMyDisk asks GitHub for the latest
  release. A newer one is downloaded in the background and installed only if
  it matches the release's `SHA256SUMS` and is signed with the project's
  Developer ID and notarized by Apple. It installs while SuckMyDisk is in the
  background with its window closed and nothing is scanning or cleaning, and
  reopens in a second or two, still in the menu bar; while you're using it,
  the sidebar and the menu bar panel offer **Relaunch to Update**, and
  quitting installs it. Full Disk Access carries over. **Check for Updates…**
  is in the SuckMyDisk menu, and Settings (⌘,) turns automatic checks or
  automatic installs off. This is the last version you download by hand.

### Changed

- SuckMyDisk now makes one kind of network request: the update check above,
  to GitHub. It sends only the app's version; nothing about your disk leaves
  the Mac.
- Clean Up refuses anything System Integrity Protection guards, and never
  removes `/Library`, `/Applications/Utilities`, the Applications folders
  themselves, or the `~/Library` folders that hold many apps' data.
- The Clean Up sheet lists uninstalls in their own group, and puts items that
  only move things to the Trash under "Move to Trash".

### Fixed

- Every reclaim list opens its first groups. Only the first list you visited
  did; the others opened collapsed.

## [0.4.1] - 2026-11-07

Requires macOS 26 (Apple silicon or Intel). Signed with a Developer ID and
notarized. The index format is unchanged, so upgrading needs no rescan.

### Added

- **npx cache.** Packages npx installed to run them (`~/.npm/_npx`), one row
  per package with all its versions. `npm cache clean` leaves them alone, and
  each new release of a tool run with npx adds another folder. Packages a
  running program uses (MCP servers often run this way) and ones installed in
  the last 7 days are left out.

### Changed

- Rebuildable items you tick yourself are cleaned even if they changed in the
  last 7 days. A build folder last written a few days ago was skipped on every
  Clean Up, with a hint about `--force`, a CLI flag the app doesn't have.
  Preselected items and your own files still wait the 7 days, and a skipped
  item now says when it can go. In the CLI, items named with `--select` or
  `--add`, and `smd hibernate`'s, count as ticked.
- Nothing a running program uses is deleted: Clean Up checks the running
  programs' command lines right before each item and skips it if one names
  it, naming the program and its PID.
- The uv cache is skipped at once, naming the process, while a uv runs: a
  long-running `uv run` holds the cache lock, and `uv cache prune` waited 5
  minutes for it on every Clean Up and then failed.
- Render frames match a video only if it has the same number of frames, give
  or take a few (it was within 3%), and isn't inside another project or next
  to another frame folder. A frames folder on a test disk was matched to an
  unrelated video in another repo and preselected. When two videos tie (a
  voice-only and a mixed version), the newest is named.

## [0.4.0] - 2026-11-05

Requires macOS 26 (Apple silicon or Intel). Signed with a Developer ID and
notarized. The index format is unchanged, so upgrading needs no rescan.

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

[Unreleased]: https://github.com/kadaliao/suck-my-disk/compare/v0.5.3...HEAD
[0.5.3]: https://github.com/kadaliao/suck-my-disk/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/kadaliao/suck-my-disk/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/kadaliao/suck-my-disk/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/kadaliao/suck-my-disk/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/kadaliao/suck-my-disk/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/kadaliao/suck-my-disk/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/kadaliao/suck-my-disk/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/kadaliao/suck-my-disk/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/kadaliao/suck-my-disk/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kadaliao/suck-my-disk/releases/tag/v0.1.0
