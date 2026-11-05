# Releasing

**English** · [简体中文](releasing.zh-CN.md)

For maintainers. A release is a signed, notarized app zip and a CLI zip on
GitHub Releases, built by `scripts/release.sh`.

## Versions

- `MARKETING_VERSION` in `project.yml` is the version users see (`0.2.0`).
  Releases follow semantic versioning: patch for fixes, minor for features,
  major once something users rely on changes incompatibly.
- `CURRENT_PROJECT_VERSION` is the build number; add 1 for every release.
- Tags are `v<version>`, for example `v0.2.0`.

`release.sh` reads the version from `project.yml`, so that file is the only
place to change it.

## One-time setup

1. A **Developer ID Application** certificate in your login keychain. The
   script defaults to `Developer ID Application: Xingyi Liao (HMDAVG9B8J)`;
   set `SIGN_IDENTITY` to use another one (for example in a fork).
2. A **notarytool keychain profile**:

   ```sh
   xcrun notarytool store-credentials <profile-name> \
     --apple-id <apple-id> --team-id <team-id>
   ```

   It asks for an app-specific password and stores everything in the
   keychain. Never commit credentials.
3. `brew install xcodegen gh`, and `gh auth login`.

## Steps

1. **Changelog.** In `CHANGELOG.md` and `CHANGELOG.zh-CN.md`, move the
   *Unreleased* (*未发布*) entries under a new heading with the version and date, and
   update the compare links at the bottom. If `SNAP_MAGIC` changed since the
   last release, add an upgrade note: the first launch does one full scan.
2. **Version.** Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
   `project.yml`.
3. **Test.**

   ```sh
   (cd Packages/DiskCore && swift test)
   ```

4. **Build, sign, notarize, package.**

   ```sh
   NOTARY_PROFILE=<profile-name> scripts/release.sh
   ```

   This regenerates the Xcode project, builds the app (Release), builds `smd`
   as a universal binary (arm64 + x86_64), signs both with the hardened
   runtime, submits them for notarization and waits, staples the app, and
   checks it with `spctl`. Without `NOTARY_PROFILE` the build is signed but
   not notarized; don't publish that.

   Output in `build/release/`:

   | File | |
   | --- | --- |
   | `SuckMyDisk-<version>.zip` | the stapled app |
   | `smd-<version>-macos.zip` | the CLI |
   | `SHA256SUMS` | checksums of both zips |

5. **Smoke test** the zip on a Mac (ideally one that didn't build it): unzip,
   open, check the version in About, and run `smd things` from the CLI zip.
6. **Commit and tag.**

   ```sh
   git commit -am "Release <version>"
   git tag -a v<version> -m "SuckMyDisk <version>"
   git push origin master --tags
   ```

7. **Publish** with bilingual notes (English first, then Chinese, copied from
   the changelogs):

   ```sh
   gh release create v<version> \
     build/release/SuckMyDisk-<version>.zip \
     build/release/smd-<version>-macos.zip \
     build/release/SHA256SUMS \
     --title "SuckMyDisk <version>" --notes-file <notes.md>
   ```

   Start the notes with the requirements line used so far: *Requires macOS 26
   (Apple silicon or Intel). Signed with a Developer ID and notarized.*

## If something fails

- **Notarization rejected.** `xcrun notarytool log <submission-id>
  --keychain-profile <profile-name>` shows why. Usually a binary without the
  hardened runtime or a secure timestamp; `release.sh` passes both.
- **`spctl` rejects the app.** The staple didn't happen or the signature
  changed after stapling. Re-run the script from scratch; it starts by
  deleting `build/release`.
- **A bad release went out.** Don't reuse the version. Mark the GitHub release
  as a pre-release or delete it, fix the problem, and release the next patch
  version.
