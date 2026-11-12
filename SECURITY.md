# Security policy · 安全政策

[English](#english) · [简体中文](#简体中文)

## English

SuckMyDisk deletes files, so for this project a security problem includes
anything that could make it remove data it shouldn't.

### What to report privately

- SuckMyDisk deleted or trashed something that was not rebuildable, or
  something inside a protected location (iCloud Drive, cloud-storage folders,
  Photos / Mail / Messages libraries, `.git`, git-tracked files, `.ssh`,
  Keychains).
- A way to make a recognizer or the executor act outside what it listed, for
  example through a crafted file or folder name, a symlink, or a cleanup
  command.
- SuckMyDisk reading privacy-protected folders without Full Disk Access, or
  sending data off the Mac.
- A way to make the updater install anything other than a newer, genuine,
  notarized SuckMyDisk release.
- A way to make the helper (the part that runs as root once you turn on
  **Uninstall system apps without a password**) act for anything other than
  SuckMyDisk itself, or do anything other than move an app from the
  Applications folder to the caller's own Trash.
- Problems with the signed and notarized release builds.

Ordinary bugs (wrong numbers, a missing recognizer, a crash) can go in a
public issue.

### How to report

Use GitHub's private reporting: **Security → Report a vulnerability** on the
repository, or open
<https://github.com/kadaliao/suck-my-disk/security/advisories/new>. If that
doesn't work for you, email kadaliao@gmail.com.

Please include the SuckMyDisk version, your macOS version, whether you used
the app or `smd`, what was removed, and the matching lines from `smd journal`
(edit out paths you don't want to share). Steps to reproduce on a test folder
help most.

The maintainer aims to reply within a week, and will credit you in the
release notes unless you'd rather not be named.

### Supported versions

Fixes go into the latest release. Please update before reporting.

### If you lost data

- Your own files went to the Trash; look there first.
- Rebuildable items have a restore command in `smd journal` and `smd wake`.
- Time Machine, or a local APFS snapshot (`tmutil listlocalsnapshots /`), may
  still hold the data. Avoid writing large amounts to the disk until you have
  checked.

## 简体中文

SuckMyDisk 会删除文件，所以在这个项目里，凡是可能让它删掉不该删的数据的问题，都算安全问题。

### 哪些问题请私下报告

- SuckMyDisk 删除了不可再生的东西，或者把受保护位置里的东西删掉或移进了废纸篓（iCloud 云盘、云存储文件夹、照片 / 邮件 / 信息的资料库、`.git`、git 跟踪的文件、`.ssh`、钥匙串）。
- 能让识别器或执行器越过它列出的范围去动别的东西，比如借助特制的文件名或文件夹名、符号链接、清理命令。
- 没有「完全磁盘访问」时读取了受隐私保护的文件夹，或者把数据发到了本机以外。
- 能让自动更新装上任何不是「更新的、正版的、经过公证的 SuckMyDisk 版本」的东西。
- 能让卸载助手（打开 **卸载系统应用时不用输密码** 以后以 root 身份运行的那部分）听 SuckMyDisk 以外的程序的话，或者做「把『应用程序』文件夹里的应用移到调用者自己的废纸篓」以外的任何事。
- 已签名、已公证的发布版本本身有问题。

一般的 bug（数字不对、少了某个识别器、崩溃）直接提公开 issue 就行。

### 怎么报告

用 GitHub 的私密报告：在仓库的 **Security → Report a vulnerability**，或者直接打开
<https://github.com/kadaliao/suck-my-disk/security/advisories/new>。用不了的话，发邮件到 kadaliao@gmail.com。

请写明 SuckMyDisk 版本、macOS 版本、用的是 App 还是 `smd`、删掉了什么，以及 `smd journal` 里对应的几行（不想公开的路径可以抹掉）。最有帮助的是能在测试文件夹里复现的步骤。

维护者会尽量在一周内回复。发布说明里会致谢报告人，不想署名可以说一声。

### 支持的版本

修复只进最新版本。报告前请先升级。

### 如果数据已经丢了

- 你自己的文件进的是废纸篓，先去那里找。
- 可再生的东西在 `smd journal` 和 `smd wake` 里有恢复命令。
- 时间机器或本地 APFS 快照（`tmutil listlocalsnapshots /`）可能还留着数据。确认之前，尽量别往这块盘写入大量数据。
