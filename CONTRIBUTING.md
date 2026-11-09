# Contributing to SuckMyDisk

**English** · [简体中文](CONTRIBUTING.zh-CN.md)

Thanks for helping. SuckMyDisk deletes files on people's disks, so this guide
is mostly about doing that carefully. Please read it before opening a pull
request.

- [Ways to help](#ways-to-help)
- [Development setup](#development-setup)
- [Testing without risking your disk](#testing-without-risking-your-disk)
- [Safety rules for code that deletes](#safety-rules-for-code-that-deletes)
- [Adding a recognizer](#adding-a-recognizer)
- [Conventions](#conventions)
- [Documentation in two languages](#documentation-in-two-languages)
- [Pull requests](#pull-requests)

## Ways to help

- **Report a bug** with the bug report template. Include your macOS version,
  the SuckMyDisk version, and the output of `smd things` (or the relevant part
  of it) when the problem is about what is listed. Edit out paths you don't
  want to share.
- **Ask for a recognizer**: a tool, cache or app whose space SuckMyDisk
  doesn't explain yet. Say where it keeps its data, whether it has its own
  cleanup command, and how to get the data back.
- **Fix or improve something.** For anything bigger than a small fix, open an
  issue first so we can agree on the approach.
- **Improve the docs or the Chinese / English wording.**

If SuckMyDisk deleted something it shouldn't have, do not file a public
issue; follow [SECURITY.md](SECURITY.md).

## Development setup

Requirements: macOS 26 or later, Xcode 26 or later, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
for the app.

**Engine and CLI.** The Swift package needs no Xcode project:

```sh
cd Packages/DiskCore
swift build                 # debug build: .build/debug/smd
swift test                  # all suites, a few seconds
swift run smd things        # run the CLI
```

**App.** The Xcode project is generated from `project.yml` and is not
committed:

```sh
xcodegen generate
open SuckMyDisk.xcodeproj
```

`project.yml` signs with the maintainer's certificates. Without them, build
with an ad-hoc signature:

```sh
xcodebuild -project SuckMyDisk.xcodeproj -scheme SuckMyDisk -configuration Debug \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

or pick your own team in Xcode. Please don't commit signing changes to
`project.yml`.

Run `xcodegen generate` again whenever you add, remove or rename files in
`App/`.

## Testing without risking your disk

- **Use fixtures.** Tests build small trees in temporary folders and set
  `allowAnyPath` on the recognizer context. Add a test like that for every
  change in what gets listed, preselected or deleted.
- **Use a separate data folder.** `SMD_HOME=/tmp/smd-dev swift run smd things`
  keeps the index, report and journal away from your real ones.
- **Never run `smd reclaim --yes` or the app's Clean Up while developing a
  recognizer** unless you have read the dry run line by line. The dry run
  (`smd reclaim` without `--yes`) is the tool for checking a plan.
- **Prefer headless checks.** Most engine changes can be verified with
  `swift test` and `smd`. The app's `--snapshot <dir>` mode renders every
  section to PNG and quits; `scripts/snapshots.sh` captures them with real
  Liquid Glass (run it from a terminal with Screen Recording permission).
- **Click through UI changes in demo mode.** `--demo` fills the app with
  made-up projects, caches and models (`App/Demo.swift`). It reads nothing
  from the disk, writes no index, and its Clean Up only pretends:

  ```sh
  open -n build/DerivedData/Build/Products/Debug/SuckMyDisk.app --args --demo
  ```

- **Mind privacy prompts.** Without Full Disk Access, nothing may read
  Desktop, Documents, Downloads, iCloud Drive, other apps' containers or
  `/Volumes`. If your change makes macOS show a consent dialog, it is a bug.

### Screenshots

The screenshots in `docs/images/en` and `docs/images/zh-CN` come from demo
mode, so they never show anyone's real folders. After a UI change, build the
Release app and regenerate both sets from a terminal that has Screen
Recording permission:

```sh
xcodebuild -project SuckMyDisk.xcodeproj -scheme SuckMyDisk -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData build
scripts/doc-screenshots.sh
```

If you change what demo mode shows, keep it plausible and keep every path
made up.

## Safety rules for code that deletes

These are not negotiable. A pull request that weakens one will not be merged,
however useful the feature.

1. **Only the executor deletes.** Recognizers describe items; `Executor` acts
   on them after checking `Guards` again. Never call `removefile`,
   `FileManager.removeItem` or a cleanup command from a recognizer.
2. **Guards only grow.** Adding protected locations to `Guards` is welcome;
   removing or loosening one needs a very good reason and its own pull
   request.
3. **Use the tool's own cleanup command** when one exists (`uv cache prune`,
   `brew cleanup`, `ollama rm`…). The tool knows what is still in use. Fall
   back to deleting the folder only when the tool is not installed.
4. **Preselect only with strong evidence**: the item can be rebuilt, there is
   a known way to rebuild it, it is not in active use, and it hasn't changed
   in the last 7 days. When in doubt, list it unticked with a warning that
   says why.
5. **Your own files go to the Trash.** Anything that can't be rebuilt is
   `Tier.yours` with a `.trash` action, never deleted.
6. **Explain and restore.** Every item has a `reason`, and every rebuildable
   item has a `restore` command when there is one.
7. **Count honestly.** If data may be shared through clones or hard links, set
   `estimateIsLowerBound` or measure with `SharedAccounting`. Never promise
   more space than deleting frees. Use `covers` when one item includes
   another.
8. **Respect privacy.** Skip paths for which `ctx.isOffLimits(path)` is true,
   and read file contents only when there is no other way (and say so in the
   user guide's privacy section).
9. **App data is guidance only.** Folders that belong to another app get
   `Tier.guide` and instructions, not a delete action. The one exception is
   `AppRecognizer`: an app's data goes with the whole app, to the Trash, or
   as its caches (Caches, Logs, saved window state, Electron's cache folders),
   never preselected, and those items carry `app` so the executor skips them
   while the app runs. Match data to an app only by bundle id or by a name
   specific to that app.
10. **Erasing records is the user's call.** Records that are neither files nor
   rebuildable (a browser's history, cookies, form entries) are `Tier.erase`
   with an `.erase` action: DELETE / UPDATE statements on the program's own
   SQLite database, run by the executor in one exclusive transaction. Never
   preselected (the planner refuses it anyway), the item carries `app` so it
   is skipped while the program runs, and the program's passwords, bookmarks,
   payment data and extensions are never part of it.

## Adding a recognizer

1. Pick the place: `DevCacheRecognizer` for tool caches,
   `ModelRecognizer` for model stores, `AppRecognizer` for installed apps
   and the folders they keep in `~/Library`, `AppDataRecognizer` for app data
   (guidance only), `ProjectRecognizer` for per-project artifacts. Create a
   new file only for a new kind of thing.
2. Find the data through the tree (`ctx.tree.find`, `ctx.size`), not by
   walking the disk again. If you need a well-known file name inside
   directories, add a marker bit in `CFastScan.h` / `fastscan.c` (and bump
   `SNAP_MAGIC`, see below).
3. Build a `Thing` with one or more `ReclaimItem`s: id (stable across runs,
   since the app keeps selections by id), label, path, bytes, estimate, tier,
   action, restore, reason, preselected, warnings. Skip things too small to
   matter (existing recognizers use 50–200 MB).
4. If it runs a command, check the tool exists with `Shell.which` and keep
   the call cheap: recognition reruns in the background.
5. Register it in `Recognize.all` if it is a new recognizer.
6. Write tests: what is found, what is preselected, what is not.
7. Document it in `docs/user-guide.md` and `docs/user-guide.zh-CN.md`, and add
   a line to both changelogs under *Unreleased* (*未发布* in the Chinese one).

### Changing the index format

If you change `sm_node`, the snapshot layout, or what a flag or marker means,
bump `SNAP_MAGIC` in `fastscan.c`. Old index files are then rejected and the
first launch after upgrading does one full scan. Note it in the changelog.

## Conventions

- **Code style.** Follow the code around you. Keep functions small and names
  plain. Comments explain *why*, briefly; don't narrate what the code does.
- **No new dependencies** without discussing it first. The project uses only
  Apple frameworks and the system SQLite.
- **Both languages, always.** User-facing text in the app and the CLI goes
  through `L("中文", "English")`. Write both; natural Chinese is preferred over
  a literal translation. Sizes use `Fmt.bytes` (decimal units, like Finder).
- **CLI and app agree.** They share the engine; a behavior change in one
  should show up in the other.
- **Commit messages.** A short subject that says what changed, optionally
  followed by a blank line and details. See `git log` for the style.

## Documentation in two languages

Every document readers browse comes in two files: English `name.md` and
Chinese `name.zh-CN.md`, each linking to the other at the top. Update both in
the same pull request. If you can only write one language, say so in the pull
request and a maintainer will add the other before merging.

Files GitHub treats specially (`SECURITY.md`, `CODE_OF_CONDUCT.md`, issue and
pull request templates) hold both languages in one file.

## Pull requests

- Keep each pull request to one change.
- Run `swift test` and make sure the app still builds.
- Fill in the template: what changed, how you tested it, and the safety
  checklist if anything is listed, preselected or deleted differently.
- Add a line under *Unreleased* in `CHANGELOG.md` and *未发布* in `CHANGELOG.zh-CN.md`
  for anything a user would notice.

Releases are cut by the maintainer; see [docs/releasing.md](docs/releasing.md).

By taking part you agree to follow the [code of conduct](CODE_OF_CONDUCT.md).
