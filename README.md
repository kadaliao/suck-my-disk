# SuckMyDisk

A fast, honest disk-space tool for macOS 26, built for people whose disks fill
up with vibe-coding projects, AI renders and local models.

Instead of listing folders, it recognizes *things* — projects, render frames,
dev caches, models, app data, system space — and for each one says how much
space it really uses, what can be rebuilt, and how to get it back.

## Status

M1: command-line core (`smd`). The macOS app comes next.

```sh
cd Packages/DiskCore
swift build -c release
.build/release/smd things          # what uses space, what can go (read-only)
.build/release/smd reclaim         # dry run of the preselected plan
.build/release/smd reclaim --yes   # do it
```

`SMD_LANG=zh` forces Chinese output; otherwise it follows the system language.

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
Packages/DiskCore/
  Sources/CFastScan    parallel getattrlistbulk walker (C)
  Sources/DiskIndex    tree, snapshot, firmlinks, shared-data accounting, SQLite
  Sources/Insights     activity signals (Claude Code, Codex, shell history, Spotlight)
  Sources/Recognizers  projects, frames, dev caches, models, app data, system
  Sources/Reclaim      executor with guards and journal
  Sources/smd          CLI
```
