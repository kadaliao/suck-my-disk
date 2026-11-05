# SuckMyDisk user guide

**English** · [简体中文](user-guide.zh-CN.md)

This guide covers the app, the `smd` command line, the safety rules, and what
SuckMyDisk reads and stores. For installation, see the [README](../README.md#install).

- [First run](#first-run)
- [Full Disk Access](#full-disk-access)
- [The window](#the-window)
- [Overview](#overview)
- [Reclaim lists](#reclaim-lists)
  - [Projects](#projects) · [Media](#media) · [Dev caches](#dev-caches) · [Models](#models) · [App data](#app-data)
- [Cleaning up](#cleaning-up)
- [Whole Disk](#whole-disk)
- [Timeline](#timeline)
- [Menu bar](#menu-bar)
- [Live updates and rescanning](#live-updates-and-rescanning)
- [Command line (`smd`)](#command-line-smd)
- [Safety rules](#safety-rules)
- [Data and privacy](#data-and-privacy)
- [Uninstalling](#uninstalling)
- [FAQ and troubleshooting](#faq-and-troubleshooting)
- [Known limitations](#known-limitations)

## First run

The first time you open SuckMyDisk it scans the whole startup disk. On a disk
with about five million files this takes half a minute to a minute; a pill at
the bottom of the window shows the file count and bytes so far.

When the scan finishes, SuckMyDisk recognizes projects, frames, caches and
models, and the overview appears. From then on the index is saved and kept
current through FSEvents, so later launches only replay what changed while the
app was closed (usually under a second).

The app follows the system language: Chinese if Chinese is your first
preferred language, English otherwise.

## Full Disk Access

macOS asks for permission before an app reads some folders: Desktop,
Documents, Downloads, iCloud Drive, other apps' containers and external
volumes. Instead of raising a dialog for each one, SuckMyDisk leaves those
folders out until it has Full Disk Access, and the overview shows a banner
saying what is missing. [External disks](#external-disks) are scanned as soon
as they are plugged in once SuckMyDisk has Full Disk Access; without it, a
disk's page waits for you to click **Scan**, and macOS asks once.

To grant it:

1. Click **Open System Settings** in the banner, or go to System Settings →
   Privacy & Security → Full Disk Access.
2. Turn on SuckMyDisk (use **+** to add it from `/Applications` if it is not
   listed).
3. Quit and reopen SuckMyDisk.

For `smd`, macOS checks the terminal app that runs it, so grant Full Disk
Access to your terminal (Terminal, iTerm2, Ghostty, …) instead.

SuckMyDisk only reads file metadata to measure the disk. See
[Data and privacy](#data-and-privacy) for exactly what it opens.

## The window

The sidebar has three groups, and a fourth when an external disk is connected:

| Group | Sections |
| --- | --- |
| — | **Overview** |
| Reclaim | **Projects**, **Media**, **Dev caches**, **Models**, **App data**; each shows how much it can free |
| Explore | **Whole Disk** (treemap), **Timeline** (growth per day) |
| External Disks | One row per connected disk; see [External disks](#external-disks) |

The toolbar's ↻ button (or **File → Rescan**, ⌘R) rescans the disk on screen:
the startup disk, or the external disk whose page is open. For the startup
disk you rarely need it; see [Live updates](#live-updates-and-rescanning).

## Overview

![Overview](images/en/overview.png)

- **Free space**, with the disk size and used space on the right. Below them,
  a badge shows whether the index is **Live**, catching up, or not following
  the disk, and when recognition last ran.
- **Capacity bar.** Used space split into Projects, Media, Dev caches, Models,
  App data, Your files, Applications, System and Other, plus Free.
- **You can safely free.** The total of the preselected items: only things
  that can be rebuilt, or caches that their tool cleans itself. **Clean Up**
  opens the confirmation sheet for exactly those items.
- **"… more awaits your call."** When more than 1 GB is reclaimable but not
  preselected (simulators, the whole uv cache, projects you are still working
  on), a link takes you to it.
- **Category cards.** One per reclaim list with its total; click to open it.
- **Honest numbers.** Space SuckMyDisk can explain but not reclaim for you:
  - **Trash**: still uses space until emptied.
  - **Local snapshots**: created by macOS updates and Time Machine. Their
    space can't be measured by scanning, and deleted files stay allocated
    while a snapshot holds them.
  - **Not visible to the scan**: the data volume's used space minus what the
    scan found (snapshot space, unreadable folders), and how much macOS marks
    as purgeable.
  - **System, VM and other volumes**: the sealed system volume, swap,
    Preboot, Recovery.

## Reclaim lists

![The Projects list](images/en/projects.png)

Projects, Media, Dev caches, Models and App data share one layout:

- At the top: the total that can be freed, and a sentence on what this list
  is about. The search field in the toolbar filters the list.
- **Groups** (a project, a cache, a model store). Click a row to expand it.
  The circle selects or clears every item in the group (a dash means some are
  selected). Under the title: when it was last active and according to what
  (Claude Code, Codex, shell, file changes, Finder), and its path. On the
  right: what it can free and, in grey, what it occupies in total.
- **Items** inside a group, each with a checkbox, a badge, the reason it is
  listed, and its restore command:

  | Badge | Meaning | Action |
  | --- | --- | --- |
  | rebuildable | Can be rebuilt or downloaded again | Deleted directly, or the tool's cleanup command runs |
  | to Trash | Your own files | Moved to the Trash |
  | guide | Only the app that owns it can clean it | Nothing; instructions are shown |

- A **+** after a size (for example `565 MB+`) means part of the data is
  shared with other files through APFS clones or hard links, so the figure is
  a lower bound. Large items get an exact number after recognition.
- **⚠ warnings** explain why an item is not preselected: changed in the last
  7 days, no lockfile, shared with another folder, and so on.
- Right-click a group or an item for **Show in Finder**.
- When anything is selected, a bar at the bottom shows how many items and how
  much they free, with a **Clean Up…** button.

Your selection survives background refreshes.

### Projects

A project is a git repository, or a folder with a package manifest
(`package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `Package.swift`,
an Xcode project, `pom.xml`, Gradle, `setup.py`, `Gemfile`, `pubspec.yaml`,
`CMakeLists.txt`). Hidden folders in your home folder and `~/Library` are not
searched for projects.

Inside each project SuckMyDisk looks for build output and dependencies:

| Artifact | Recognized when | Restore command |
| --- | --- | --- |
| `node_modules` | next to a `package.json` | `pnpm install`, `bun install`, `yarn install` or `npm ci`, from the lockfile; `npm install` without one |
| virtualenv (`.venv`, any folder with `pyvenv.cfg`) | inside the project | `uv sync`, `poetry install`, or `python3 -m venv` (+ `pip install -r requirements.txt`) |
| `target` | Cargo or Maven project, or a `CACHEDIR.TAG` | `cargo build` / `mvn package` |
| `.next`, `.nuxt`, `.turbo`, `.svelte-kit`, `.parcel-cache`, `.angular` | next to a `package.json` | `npm run build` |
| `.build` | next to `Package.swift` | `swift build` |
| `.gradle` | Gradle project | `./gradlew build` |
| `.dart_tool` | next to `pubspec.yaml` | `flutter pub get` |
| `build`, `dist`, `out` | git ignores the folder, git tracks nothing in it, and it holds no video or audio | `npm run build` for JS projects |
| `__pycache__`, `.mypy_cache`, `.pytest_cache`, `.ruff_cache` | anywhere in the project; listed together as "Python caches" | rebuilt automatically |

A project is **asleep** when nothing shows activity for 30 days. Activity
comes from, newest first: Claude Code and Codex sessions in that folder,
`cd` lines in your fish or zsh history, the Spotlight last-used date, and file
modification times in the project.

An artifact is **preselected** only if the project is asleep, the evidence is
strong (for example a lockfile exists, so a reinstall gives the same
versions), and nothing in it changed in the last 7 days. Active projects are
listed too, unticked, so you can still free their space by hand.

Source code and `.git` are never touched. `smd wake` shows the commands to
bring a project's dependencies back.

### Media

![Render frames](images/en/media.png)

Folders of rendered frames: at least 300 images (`png`, `jpg`, `exr`, `tif`,
`dpx`, …) and 50 MB. Frames are grouped by the project they belong to.

- If a video nearby has a frame count matching its duration × frame rate, the
  frames are **rebuildable**: the final video exists and the frames can be
  rendered again from the source project. They are preselected unless they
  were rendered in the last 7 days.
- If no matching video is found, the folder is listed as an **image
  sequence**, handled as your files (to Trash), and not preselected. Camera
  bursts and photo folders end up here.

Only the frame folder itself is offered, never its parent: render folders
often hold paid text-to-speech audio and stills next to the frames.

### Dev caches

![Dev caches](images/en/dev-caches.png)

| Cache | Action | Preselected |
| --- | --- | --- |
| uv | `uv cache prune` (old-format buckets, unreferenced entries) | yes |
| | `uv cache clean` (everything) | no |
| | `uv cache clean` + the `.venv`s of sleeping projects | when it frees much more than either alone |
| npm | `npm cache clean --force` | yes |
| pnpm store | `pnpm store prune` (packages no project uses) | yes |
| bun | `bun pm cache rm` | yes |
| Yarn | `yarn cache clean` | yes |
| pip | delete `~/Library/Caches/pip` | yes |
| Homebrew | `brew cleanup --prune=all -s` | yes |
| Cargo registry | delete `~/.cargo/registry` | no |
| Puppeteer browsers | delete `~/.cache/puppeteer` | no |
| Xcode DerivedData | delete per project | when the project is gone or unused for 30 days |
| iOS Simulators | `xcrun simctl delete unavailable` | yes |
| | delete simulators not booted for 6 months | no (their apps and data are lost) |
| Docker / OrbStack | `docker builder prune -f`, `docker image prune -f` (dangling images) | yes |

When the tool is not installed, its folder is deleted instead. Caches under
50 MB are not listed.

**Why uv has three options.** uv installs packages into each `.venv` as APFS
clones of its cache. Clones share data blocks, so clearing the cache alone
frees only what no `.venv` uses, and deleting a `.venv` alone frees only what
the cache doesn't hold. SuckMyDisk measures both and offers the combination
(cache + the environments of sleeping projects) when that is where the space
really is. The warnings say how much stays shared.

`docker system prune` is never used, because it also deletes stopped
containers and images you built locally. After Docker cleanup, the virtual
machine's disk image on the Mac may shrink only later.

### Models

![Models](images/en/models.png)

| Source | Action | Restore |
| --- | --- | --- |
| Ollama | `ollama rm <model>` (shared layers counted once) | `ollama pull <model>` |
| Hugging Face | `hf cache rm <repo>` if the `hf` CLI is installed, otherwise delete | downloaded again when used |
| ModelScope | delete | downloaded again when used |
| LM Studio | move to Trash | download again in LM Studio |

Nothing here is preselected.

### App data

![App data](images/en/app-data.png)

Large data that belongs to an app (1 GB or more): WeChat, Chrome, Lark,
Notion, Claude's VM bundles, OrbStack, iPhone backups. Deleting these folders
directly can break the app, so SuckMyDisk only tells you where to clean them
from inside the app, for example *WeChat → Settings → General → Storage*.

## Cleaning up

![The Clean Up sheet](images/en/clean-up.png)

1. Click **Clean Up** on the overview (the preselected items) or **Clean Up…**
   in a list's bottom bar (your selection).
2. The sheet shows the total and every item, grouped by what will happen:
   - **Delete**: rebuildable; the restore steps are logged.
   - **Run the tool's own cleanup**: the tool knows what is still in use.
   - **Move to Trash**: your files, recoverable from the Trash.
3. Click **Clean Up** to confirm, or **Cancel**.

Items run one at a time, with progress in the pill at the bottom. Right before
each one, every [safety rule](#safety-rules) is checked again; anything that
fails is skipped with the reason. When it finishes, a sheet shows how much
space was actually freed (measured from the volume's free space, not
estimated).

Moved-to-Trash items still use space until you empty the Trash.

## Whole Disk

![Whole Disk treemap](images/en/whole-disk.png)

A treemap of the entire disk, colored by category. Click a block to go into
it; click a name in the path above the map to go back. After a cleanup the
map asks for a rescan before it is shown again.

## External disks

![An external disk: projects and render frames on it, with a capacity bar](images/en/external-disk.png)

Every connected disk (USB or Thunderbolt drive, SD card, writable disk image)
gets a row under **External Disks** in the sidebar. Its page shows how much can
be freed on it, a capacity bar, and two views:

- **Reclaim**: projects and render frames on that disk, recognized the same
  way as on the startup disk. Dev caches, models and app data live in your
  home folder, so they stay in their own sections. The disk's top-level hidden
  folders (`.Trashes`, `.Spotlight-V100`, and dot folders moved off the home
  folder, such as `.vscode-server`) are left out.
- **Map**: a treemap of the whole disk, like [Whole Disk](#whole-disk).

**Clean Up…** at the bottom works on that disk only, with the same
[safety rules](#safety-rules), and the result shows the space freed on that
disk. Image sequences without a matching video go to the disk's own Trash,
which frees nothing until you empty it.

External disks are not followed live. A disk is scanned when it is plugged in
(or when SuckMyDisk starts with it connected), when you click ↻ on its page,
and after Clean Up. Meanwhile the page shows what the last scan found and how
long ago that was.

Network shares, read-only disk images and Time Machine disks are not listed.

## Timeline

![Timeline](images/en/timeline.png)

How much each category used, per day, as stacked bars, with free space as a
line underneath. A point is recorded every time recognition runs (at most one
per category per day), so the chart becomes useful after a few days of use.

## Menu bar

The menu bar shows free space. Click it for a small panel with free space, the
capacity bar, how much can still be freed, and **Open SuckMyDisk**. The menu
bar item keeps following the disk while the app runs, even with the window
closed.

## Live updates and rescanning

After the first scan, SuckMyDisk watches the disk through FSEvents:

- A changed folder is re-read on its own, a new folder is scanned, a removed
  one drops out. A 2 GB download shows up within a few seconds.
- Folders that apps rewrite constantly (browser caches, logs) are re-read at
  most every few seconds. Huge ones (a Photos library, a cache with 100,000
  files) are marked stale and refreshed in the background every few minutes.
  Following the disk costs about 1% of one CPU core.
- Recognition (projects, frames, caches) reruns in the background when enough
  has changed.
- On launch, and every time `smd` runs, only the events since the index was
  last saved are replayed.

A full rescan happens on its own when the event history can't be trusted:
macOS dropped events, the volume's event database changed, or a new version of
SuckMyDisk changed the index format. You can also rescan any time with ⌘R.

## Command line (`smd`)

`smd` uses the same engine, index and journal as the app. Output follows the
system language; set `SMD_LANG=zh` or `SMD_LANG=en` to force one.

### `smd things`

What uses space and what can go. Read-only.

```sh
smd things              # brings the index up to date, recognizes, prints the report
smd things -v           # every group and every item
smd things --json       # the full report as JSON
smd things --days 60    # projects count as asleep after 60 days instead of 30
smd things --rescan     # full disk scan first
smd things /Volumes/Backup   # an external disk: projects and render frames on it
```

Each reclaimable item gets a number:

```
━━ Projects  reclaimable 23.7 GB
  my-old-app  1.2 GB  · active 3mo ago（Claude Code）  ~/code/my-old-app
     asleep for 94 days
      1 [x] ● node_modules  845 MB
          npm dependencies, reinstallable from the lockfile  · restore: pnpm install
      2 [x] ● .next  312 MB
          front-end build cache  · restore: npm run build
```

`[x]` marks preselected items, `●` rebuildable ones (deleted, restore command
recorded) and `○` your own files (moved to the Trash). Long lists are cut
short; `-v` shows every item and its number.

### `smd reclaim`

Runs a plan. **It is a dry run unless you add `--yes`.**

```sh
smd reclaim                       # show the preselected plan
smd reclaim --add 12,14           # also include items 12 and 14
smd reclaim --remove 3            # leave item 3 out
smd reclaim --select 1,2,5        # exactly these items instead of the preselection
smd reclaim --add 12 --yes        # do it
smd reclaim --yes --force         # also act on items changed in the last 7 days
smd reclaim /Volumes/Backup --yes # the preselection on an external disk
```

Numbers refer to the last `smd things` report. `reclaim` reuses that report
for an hour, so run `smd things` again if it has been longer or if the disk
changed a lot. `--force` lifts only the 7-day rule; every other safety rule
still applies.

The output lists each item with what will happen (`delete`, `trash`, or the
command), then, with `--yes`, the space each one actually freed and the free
space before and after.

### `smd hibernate` and `smd wake`

Put a whole project to sleep: delete all its rebuildable artifacts, keep the
source and git.

```sh
smd hibernate ~/code/my-old-app          # dry run
smd hibernate ~/code/my-old-app --yes    # do it
smd wake ~/code/my-old-app               # print the commands that bring it back
```

The path must be a project root as shown by `smd things`. `wake` only prints
commands such as `cd ~/code/my-old-app && pnpm install`; it runs nothing.

### `smd journal`

The last 50 actions: time, result (`done`, `skipped`, `failed`), action, space
freed, and item. The app's cleanups are recorded here too.

### `smd top`

The biggest items under a folder, from the index (no rescan).

```sh
smd top                     # your home folder
smd top ~/Library -n 50
```

Tags explain special entries: `folded` (counted as a whole, such as
`node_modules`), `other volume`, `unreadable`, `sparse`, and `shared` (data
shared with other files through clones or hard links).

### `smd scan`

```sh
smd scan                    # full scan of the data volume; saves the index
smd scan ~/code ~/Movies    # one-off scan of these folders; prints totals, saves nothing
smd scan ~/code --threads 8
```

A full scan prints how much of the data volume it could see and how much is
hidden (snapshots, unreadable folders).

### `smd bench`

Scanner speed with 4, 8, 16 and 32 threads, for development. Defaults to
`~/workspace`.

### Environment variables

| Variable | Effect |
| --- | --- |
| `SMD_LANG` | `zh` or `en` forces the output language |
| `SMD_HOME` | Keep the index, report and journal in this folder instead of `~/Library/Application Support/SuckMyDisk` (the app keeps using the default) |

### Using `smd` from scripts and coding agents

`smd things --json` prints the whole report: every group with its kind
(`project`, `media`, `devCache`, `model`, `appData`, `system`), size, last
activity, and items with their tier, action, estimate, restore command,
warnings and whether they are preselected. Progress messages go to stderr, so
stdout is clean JSON.

A safe pattern for an agent: read `smd things --json`, show the person what it
plans to free, run `smd reclaim --select …` without `--yes` to get the dry
run, and only add `--yes` after they agree.

## Safety rules

These apply to the app and the CLI alike, and no recognizer can override them.

**Never deleted or trashed**

- your home folder itself, `~/Library` itself, `/`, `/Users`
- iCloud Drive (`~/Library/Mobile Documents`): deleting there deletes in the
  cloud
- cloud-storage folders (`~/Library/CloudStorage`: Dropbox, OneDrive, Google
  Drive, …)
- `~/Library/Mail`, `~/Library/Messages`, `~/Library/Keychains`, `~/.ssh`,
  `~/.gnupg`
- `/System`, `/usr`, `/bin`, `/sbin`
- anything inside a `.git` folder
- Photos, Music, TV, iMovie and Final Cut libraries

**Checked again right before each item runs**

- the path still exists and is not a symlink
- git tracks no file at or below it (if git can't answer, it is treated as
  tracked)
- it has not changed in the last 7 days (the CLI's `--force` lifts this one)

**How things are removed**

- Rebuildable items are deleted, and the restore command goes into the
  journal. Before a Python virtualenv is deleted, its `pyvenv.cfg` and a
  `pip freeze` are saved in the journal so it can be rebuilt faithfully.
- Your own files are moved to the Trash.
- When a tool has its own cleanup command, that command runs instead.
- App data is never deleted; you get instructions.

## Data and privacy

SuckMyDisk makes no network requests and sends nothing anywhere. There is no
account and no telemetry.

**What it stores**, in `~/Library/Application Support/SuckMyDisk/`:

| File | Contents |
| --- | --- |
| `index-<volume-uuid>.bin` | The disk index: names, sizes and dates of files and folders |
| `last-report.json` | The latest recognition report |
| `report-<volume-uuid>.json` | The latest report for an external disk (its index is an `index-<volume-uuid>.bin` too) |
| `smd.sqlite` | Daily size history (for the Timeline) and the journal of every cleanup |

**What it reads**

- File and folder metadata (names, sizes, dates, clone and hard-link
  information) for the whole data volume, minus the
  [privacy-protected folders](#full-disk-access) when it lacks Full Disk
  Access, and for each connected external disk.
- To estimate when you last worked on a project: the folder names and dates in
  `~/.claude/projects`, the working directory recorded at the start of Codex
  session files (`~/.codex/sessions`), `cd` commands in fish and zsh history,
  and Spotlight's last-used date. Nothing from these is stored apart from the
  resulting date and its source name.
- A few small files to recognize things: `pyvenv.cfg`, Ollama manifests,
  Xcode's `info.plist` in DerivedData, the headers of frame images and
  candidate videos.
- Answers from tools it asks read-only questions: `uv cache dir`,
  `pnpm store path`, `xcrun simctl list devices`, `docker system df`,
  `tmutil listlocalsnapshots`, `git check-ignore` and `git ls-files`.

## Uninstalling

1. Quit SuckMyDisk.
2. Delete `/Applications/SuckMyDisk.app`, and `smd` from wherever you put it.
3. Delete its data:

   ```sh
   rm -rf ~/Library/Application\ Support/SuckMyDisk
   ```

4. Optionally remove SuckMyDisk from System Settings → Privacy & Security →
   Full Disk Access.

## FAQ and troubleshooting

**Why do the numbers differ from Finder or System Settings?**
SuckMyDisk uses decimal units like Finder (1 GB = 1,000,000,000 bytes), but
counts APFS clones and hard links once and reports the data volume, not the
whole APFS container. The overview's *Honest numbers* section accounts for
the rest: snapshots, unreadable folders, purgeable space, and the system
volumes.

**I cleaned up, but free space barely changed.**
Usually one of these:
- A local snapshot still holds the deleted data. It is released when macOS
  removes the snapshot (Time Machine and update snapshots expire on their
  own).
- Items went to the Trash; empty it.
- The data was shared with something you kept (clones, hard links). The
  warnings on the item say how much.
- Docker's virtual disk shrinks later, not immediately.

**Why isn't X preselected?**
Preselection is deliberately conservative. Look at the item's ⚠ warnings:
the project is active, there is no lockfile, it changed in the last 7 days,
its data is shared, or it belongs to a category where nothing is preselected
(models, image sequences, the whole uv cache, old simulators). You can still
tick it yourself.

**An item was skipped with "changed in the last 7 days".**
That rule protects work in progress. Wait, or from the CLI use `--force`.

**How do I get something back?**
Rebuildable items: run the restore command shown in the list, in the journal
(`smd journal`), or from `smd wake <project>`. Your files: open the Trash.

**macOS asked me whether SuckMyDisk may access a folder.**
It shouldn't: without Full Disk Access those folders are skipped. Please
[open an issue](https://github.com/kadaliao/suck-my-disk/issues) with the
folder's name and your macOS version.

**The badge says "Not following".**
The live watcher isn't running, so numbers may be out of date. Rescan with ⌘R.
If it keeps happening, please open an issue.

**Does it scan external drives?**
Yes, in 0.4.0 and newer: each connected disk gets its own page (see
[External disks](#external-disks)), and `smd things /Volumes/<name>` does the
same from the command line. Earlier versions scan only the startup disk.

**Can I change the 30-day "asleep" threshold?**
In the CLI, with `smd things --days N`. The app uses 30 days.

**Can I try SuckMyDisk without letting it scan my disk?**
Start it in demo mode. It shows made-up projects, caches and models, reads
nothing from your disk, writes nothing, and Clean Up only pretends. Quit any
running SuckMyDisk first, then:

```sh
open -n -a SuckMyDisk --args --demo
```

Demo mode needs SuckMyDisk 0.3.0 or later. The screenshots in this guide come
from it.

**Upgrading made the first launch slow.**
When a release changes the index format, the first launch does one full scan.
The release notes say when that happens.

## Known limitations

- External disks are not followed live: they are scanned when plugged in, on
  ↻ and after Clean Up. Only projects and render frames are recognized on
  them.
- The *lossless* tier (merging duplicate files into APFS clones) exists in
  the engine but no recognizer produces it yet.
- Recognizers cover a fixed list of tools. Missing one? See
  [CONTRIBUTING.md](../CONTRIBUTING.md#adding-a-recognizer) or open a
  recognizer request.
- Full Disk Access is requested through a banner only; there is no guided
  setup yet.
