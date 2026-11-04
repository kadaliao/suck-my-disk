# SuckMyDisk

A fast, honest disk-space tool for macOS 26, built for people whose disks fill
up with vibe-coding projects, AI renders and local models.

Instead of listing folders, it recognizes *things* — projects, render frames,
dev caches, models, app data, system space — and for each one says how much
space it really uses, what can be rebuilt, and how to get it back.

## Install

Requires macOS 26. Download `SuckMyDisk-<version>.zip` from Releases, unzip,
and move `SuckMyDisk.app` to `/Applications`. Builds are signed with a
Developer ID and notarized.

For complete numbers, grant Full Disk Access (System Settings → Privacy &
Security → Full Disk Access). Without it, app containers such as WeChat's are
not counted.

The app has five places to reclaim space (projects, render frames, dev caches,
models, app data), a whole-disk treemap, a growth timeline, and a menu bar item
that shows free space. The UI follows the system language (Chinese or English).

## Command line

`smd` uses the same engine and the same index as the app. It is in
`smd-<version>-macos.zip` on the Releases page, or build it yourself:

```sh
cd Packages/DiskCore
swift build -c release
.build/release/smd things          # what uses space, what can go (read-only)
.build/release/smd reclaim         # dry run of the preselected plan
.build/release/smd reclaim --yes   # do it
```

`SMD_LANG=zh` forces Chinese output; otherwise it follows the system language.

## Build the app

```sh
brew install xcodegen
xcodegen generate
open SuckMyDisk.xcodeproj
```

`scripts/release.sh` builds, signs, notarizes (with `NOTARY_PROFILE` set) and
zips a release into `build/release/`.

## How it stays safe

- Rebuildable things (dependencies, build outputs, caches, frames whose final
  video exists) are deleted directly, with a restore command in the journal.
  Your own files go to the Trash.
- Never touches iCloud Drive, cloud-storage folders, Photos / Mail / Messages
  libraries, `.git`, `.ssh`, git-tracked files, or anything changed in the last
  7 days (unless `--force`).
- Tools with their own cleanup command (uv, npm, bun, pnpm, brew, simctl,
  docker builder prune) are run instead of deleting their folders.
  `docker system prune` is never used.
- Space is counted clone- and hard-link-aware: deleting a `.venv` that is an
  APFS clone of the uv cache frees nothing unless both go.

## Layout

```
App/                   SwiftUI app and menu bar item
scripts/release.sh     signed, notarized release build
Packages/DiskCore/
  Sources/CFastScan    parallel getattrlistbulk walker (C)
  Sources/DiskIndex    tree, snapshot, firmlinks, shared-data accounting, SQLite
  Sources/Insights     activity signals (Claude Code, Codex, shell history, Spotlight)
  Sources/Recognizers  projects, frames, dev caches, models, app data, system
  Sources/Reclaim      executor with guards and journal
  Sources/smd          CLI
```
