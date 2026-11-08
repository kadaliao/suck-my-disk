# 发版

[English](releasing.md) · **简体中文**

写给维护者。一次发版就是在 GitHub Releases 上放签好名、经过公证的 App 磁盘映像（DMG）和压缩包，再加一个命令行压缩包，都由 `scripts/release.sh` 构建。

## 版本号

- `project.yml` 里的 `MARKETING_VERSION` 是用户看到的版本号（`0.2.0`）。版本号遵循语义化版本：修 bug 升补丁号，加功能升次版本号；等到用户依赖的东西出现不兼容的变化时再升主版本号。
- `CURRENT_PROJECT_VERSION` 是构建号，每次发版加 1。
- 标签格式是 `v<version>`，比如 `v0.2.0`。

`release.sh` 从 `project.yml` 读取版本号，所以改版本号只需要改这一个文件。

## 一次性准备

1. 登录钥匙串里要有 **Developer ID Application** 证书。脚本默认用 `Developer ID Application: Xingyi Liao (HMDAVG9B8J)`；要用别的证书（比如在 fork 里），设置 `SIGN_IDENTITY`。
2. 一个 **notarytool 钥匙串配置**：

   ```sh
   xcrun notarytool store-credentials <profile-name> \
     --apple-id <apple-id> --team-id <team-id>
   ```

   它会要求输入 App 专用密码，然后把所有信息存进钥匙串。绝不要把凭据提交到仓库。
3. `brew install xcodegen gh`，然后 `gh auth login`。

## 步骤

1. **更新日志。** 在 `CHANGELOG.md` 和 `CHANGELOG.zh-CN.md` 里，把「未发布」下的条目移到一个新标题下，写上版本号和日期，并更新底部的对比链接。如果上次发版以来 `SNAP_MAGIC` 改过，加一条升级说明：升级后第一次启动会做一次全盘扫描。
2. **版本号。** 改 `project.yml` 里的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`。
3. **测试。**

   ```sh
   (cd Packages/DiskCore && swift test)
   ```

4. **构建、签名、公证、打包。**

   ```sh
   NOTARY_PROFILE=<profile-name> scripts/release.sh
   ```

   脚本会重新生成 Xcode 工程，以 Release 配置构建 App，把 `smd` 构建成通用二进制（arm64 + x86_64），给两者都用 hardened runtime 签名，提交公证并等待结果，给 App 钉上公证票据（staple），用 `spctl` 检查。接着做磁盘映像（App 旁边放一个「应用程序」的快捷方式），同样签名、公证、钉票据，最后删掉暂存目录里散放的 App。没有设置 `NOTARY_PROFILE` 时，所有产物只签名、不公证；这样的包不要发布。

   产物在 `build/release/`：

   | 文件 | |
   | --- | --- |
   | `SuckMyDisk-<version>.dmg` | 大多数人下载的磁盘映像 |
   | `SuckMyDisk-<version>.zip` | 已钉上公证票据的 App 压缩包 |
   | `smd-<version>-macos.zip` | 命令行工具 |
   | `SHA256SUMS` | 三个文件的校验和 |

5. **冒烟测试。** 在一台 Mac 上（最好不是构建用的那台）打开 DMG，把 App 拖进「应用程序」再打开，在「关于 SuckMyDisk」里核对版本号，再用命令行压缩包里的 `smd` 跑一下 `smd things`。
6. **提交并打标签。**

   ```sh
   git commit -am "Release <version>"
   git tag -a v<version> -m "SuckMyDisk <version>"
   git push origin master --tags
   ```

7. **发布**，附上双语说明（先英文后中文，从两份更新日志里复制）：

   ```sh
   gh release create v<version> \
     build/release/SuckMyDisk-<version>.dmg \
     build/release/SuckMyDisk-<version>.zip \
     build/release/smd-<version>-macos.zip \
     build/release/SHA256SUMS \
     --title "SuckMyDisk <version>" --notes-file <notes.md>
   ```

   发布就等于推送：一天之内，所有 0.5.0 及以后的副本都会下载并安装它（见[自动更新](architecture.zh-CN.md#自动更新updateupdater)）。它需要标签 `v<version>` 和 `.zip`、`SHA256SUMS` 两个附件，并且忽略草稿和 pre-release；想把某个构建分享出去、又不想推给所有人，就发成 pre-release。

   说明开头先放安装说明，再放之前沿用的系统要求那一行：

   > **Install / 安装:** download `SuckMyDisk-<version>.dmg`, open it, and drag SuckMyDisk into Applications. / 下载 `SuckMyDisk-<version>.dmg`，打开后把 SuckMyDisk 拖进「应用程序」。
   >
   > Requires macOS 26 (Apple silicon or Intel). Signed with a Developer ID and notarized.

## 出问题时

- **公证被拒。** `xcrun notarytool log <submission-id> --keychain-profile <profile-name>` 会告诉你原因。通常是某个二进制没开 hardened runtime 或者没有安全时间戳；`release.sh` 这两个参数都传了。
- **`spctl` 不认这个 App。** 要么没钉上公证票据，要么钉完之后签名又变了。从头重跑脚本；它一开始就会删掉 `build/release`。
- **发出去的版本有问题。** 不要复用这个版本号。把这个 GitHub release 标成 pre-release 或者删掉，别的副本就不会再装它；修好问题，尽快发下一个补丁版本：已经更新的副本只会往前升级，修复会作为下一次更新送到它们那里。
