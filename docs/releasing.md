# Releasing

**English** · [简体中文](releasing.zh-CN.md)

For maintainers. A release is a signed, notarized disk image and zip of the
app, plus a CLI zip, on
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
2. **Credentials for notarizing**, one of two kinds. Never commit either.

   An **App Store Connect API key** (recommended: nothing is kept in a
   keychain, so nothing can go missing from one). Create a team key in App
   Store Connect → Users and Access → Integrations → App Store Connect API,
   download its `.p8` file once, and note the Key ID and the Issuer ID shown
   on that page. Put the three in `~/.appstoreconnect/notary.env`, which the
   release script reads when no credentials are given on the command line:

   ```sh
   NOTARY_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_<key-id>.p8"
   NOTARY_KEY_ID="<key-id>"
   NOTARY_ISSUER="<issuer-id>"
   ```

   Or a **notarytool keychain profile**:

   ```sh
   xcrun notarytool store-credentials <profile-name> \
     --apple-id <apple-id> --team-id <team-id>
   ```

   It asks for an app-specific password and stores everything in the
   keychain; run the release script with `NOTARY_PROFILE=<profile-name>`. In
   an SSH session the login keychain
   refuses a new profile ("User interaction is not allowed"): add
   `--keychain <file>` to store it in a keychain file of its own, and pass
   that file to the release script as `NOTARY_KEYCHAIN=<file>`.
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
   scripts/release.sh
   ```

   It first checks that the notarizing credentials work, and stops if they
   don't. `NOTARIZE=0` builds and signs without notarizing.

   This regenerates the Xcode project, builds the app (Release), builds `smd`
   as a universal binary (arm64 + x86_64), signs both with the hardened
   runtime, submits them for notarization and waits, staples the app, and
   checks it with `spctl`. It then builds the disk image (the app next to a
   link to Applications), signs, notarizes and staples that too, and deletes
   the loose staging copy of the app. Without credentials everything is
   signed but not notarized; don't publish that.

   Output in `build/release/`:

   | File | |
   | --- | --- |
   | `SuckMyDisk-<version>.dmg` | the disk image most people download |
   | `SuckMyDisk-<version>.zip` | the stapled app, zipped |
   | `smd-<version>-macos.zip` | the CLI |
   | `SHA256SUMS` | checksums of all three |

5. **Smoke test** the DMG on a Mac (ideally one that didn't build it): open
   it, drag the app to Applications, open it, check the version in About, and
   run `smd things` from the CLI zip.
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
     build/release/SuckMyDisk-<version>.dmg \
     build/release/SuckMyDisk-<version>.zip \
     build/release/smd-<version>-macos.zip \
     build/release/SHA256SUMS \
     --title "SuckMyDisk <version>" --notes-file <notes.md>
   ```

   Publishing is shipping: within a day, every copy of 0.5.0 or later
   downloads the release and installs it (see
   [Updates](architecture.md#updates-update-updater)). It needs the tag
   `v<version>` and the `.zip` and `SHA256SUMS` assets, and it ignores drafts
   and pre-releases, so a pre-release is the way to share a build without
   sending it to everyone.

   Start the notes with the install line and the requirements line used so
   far:

   > **Install / 安装:** download `SuckMyDisk-<version>.dmg`, open it, and drag
   > SuckMyDisk into Applications. / 下载 `SuckMyDisk-<version>.dmg`，打开后把
   > SuckMyDisk 拖进「应用程序」。
   >
   > Requires macOS 26 (Apple silicon or Intel). Signed with a Developer ID and
   > notarized.

8. **Homebrew.** Nothing to do: a scheduled workflow in
   [kadaliao/homebrew-tap](https://github.com/kadaliao/homebrew-tap) picks up
   the latest release within 6 hours and updates `Casks/suck-my-disk.rb` (the
   app) and `Formula/smd.rb` (the CLI). To update the tap right away:

   ```sh
   gh workflow run bump.yml -R kadaliao/homebrew-tap
   ```

   Pre-releases are skipped. The tap downloads `SuckMyDisk-<version>.zip` and
   `smd-<version>-macos.zip`; if you rename them, change the URLs in the tap
   too. The cask is marked `auto_updates`: people who installed the app with
   Homebrew get the release from the in-app updater anyway, so the tap is
   what new installs and `brew upgrade smd` see.

## If something fails

- **Notarization rejected.** `xcrun notarytool log <submission-id>
  --keychain-profile <profile-name>` shows why. Usually a binary without the
  hardened runtime or a secure timestamp; `release.sh` passes both.
- **`spctl` rejects the app.** The staple didn't happen or the signature
  changed after stapling. Re-run the script from scratch; it starts by
  deleting `build/release`.
- **A bad release went out.** Don't reuse the version. Mark the GitHub release
  as a pre-release or delete it, which stops further installs of it, fix the
  problem, and release the next patch version soon: copies that already
  updated only move forward, so the fix reaches them as the next update.
