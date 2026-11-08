# 参与贡献 SuckMyDisk

[English](CONTRIBUTING.md) · **简体中文**

感谢你来帮忙。SuckMyDisk 会删别人磁盘上的文件，所以这份指南主要讲的是怎样小心地做这件事。提 PR 之前请先读一遍。

- [参与方式](#参与方式)
- [开发环境](#开发环境)
- [测试时不要拿真实磁盘冒险](#测试时不要拿真实磁盘冒险)
- [删除相关代码的安全规则](#删除相关代码的安全规则)
- [添加识别器](#添加识别器)
- [代码约定](#代码约定)
- [双语文档](#双语文档)
- [提交 PR](#提交-pr)

## 参与方式

- **报告 bug**：用 bug 报告模板。写上 macOS 版本、SuckMyDisk 版本；如果问题和列出的内容有关，附上 `smd things` 的输出（或相关部分）。不想公开的路径可以先删掉。
- **请求新的识别器**：某个工具、缓存或 App 占的空间，SuckMyDisk 还解释不了。请说明它把数据放在哪里、有没有自带的清理命令、删了之后怎么恢复。
- **修 bug 或做改进**：比小修小补大的改动，先开一个 issue，我们先把做法谈妥。
- **改进文档，或者中英文措辞。**

如果 SuckMyDisk 删了不该删的东西，不要开公开 issue，按 [SECURITY.md](SECURITY.md) 的说明报告。

## 开发环境

需要 macOS 26 或更新版本、Xcode 26 或更新版本；构建 App 还需要 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

**引擎和命令行。** Swift 包不需要 Xcode 工程：

```sh
cd Packages/DiskCore
swift build                 # debug build: .build/debug/smd
swift test                  # all suites, a few seconds
swift run smd things        # run the CLI
```

**App。** Xcode 工程由 `project.yml` 生成，不提交到仓库：

```sh
xcodegen generate
open SuckMyDisk.xcodeproj
```

`project.yml` 用的是维护者的证书签名。没有这些证书的话，用 ad-hoc 签名构建：

```sh
xcodebuild -project SuckMyDisk.xcodeproj -scheme SuckMyDisk -configuration Debug \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

或者在 Xcode 里选你自己的 team。请不要把签名相关的改动提交到 `project.yml`。

每次在 `App/` 里新增、删除或重命名文件后，都要重新运行一次 `xcodegen generate`。

## 测试时不要拿真实磁盘冒险

- **用测试数据。** 测试会在临时目录里搭小目录树，并在识别上下文里打开 `allowAnyPath`。凡是改了「列出什么、预选什么、删什么」，都要照这个方式加一个测试。
- **用单独的数据目录。** `SMD_HOME=/tmp/smd-dev swift run smd things` 会把索引、报告和日志放在别处，不影响你真正在用的那份。
- **开发识别器时，不要运行 `smd reclaim --yes`，也不要点 App 里的「一键清理」**，除非你已经逐行看过预演结果。检查清理计划就用预演（不加 `--yes` 的 `smd reclaim`）。
- **能不开界面就不开。** 大部分引擎改动用 `swift test` 和 `smd` 就能验证。App 的 `--snapshot <dir>` 模式会把每个页面渲染成 PNG 然后退出；`scripts/snapshots.sh` 能截出带真实 Liquid Glass 效果的图（要在有屏幕录制权限的终端里运行）。
- **改界面时用演示模式点一遍。** `--demo` 会让 App 显示一套虚构的项目、缓存和模型（`App/Demo.swift`）。它不读磁盘、不写索引，「清理」也只是做做样子：

  ```sh
  open -n build/DerivedData/Build/Products/Debug/SuckMyDisk.app --args --demo
  ```

- **留意隐私弹窗。** 没有完全磁盘访问时，任何代码都不能读桌面、文稿、下载、iCloud 云盘、其他 App 的容器或 `/Volumes`。如果你的改动让 macOS 弹出了授权对话框，那就是 bug。

### 截图

`docs/images/en` 和 `docs/images/zh-CN` 里的截图都来自演示模式，所以不会露出任何人的真实目录。改了界面之后，先编译 Release 版，再在有屏幕录制权限的终端里重新生成两套截图：

```sh
xcodebuild -project SuckMyDisk.xcodeproj -scheme SuckMyDisk -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData build
scripts/doc-screenshots.sh
```

如果要改演示模式显示的内容，数据要像真的，路径必须是虚构的。

## 删除相关代码的安全规则

这些规则没有商量余地。削弱其中任何一条的 PR 都不会合并，不管功能多有用。

1. **只有执行器能删东西。** 识别器只负责描述清理项；`Executor` 再检查一遍 `Guards` 之后才动手。不要在识别器里调用 `removefile`、`FileManager.removeItem` 或任何清理命令。
2. **保护规则只增不减。** 欢迎往 `Guards` 里加受保护的位置；删掉或放宽任何一条，都要有非常充分的理由，并且单独提一个 PR。
3. **工具有自带的清理命令就用它**（`uv cache prune`、`brew cleanup`、`ollama rm` 等）。工具自己知道哪些还在用。只有工具没装时，才退回到直接删目录。
4. **证据足够才预选**：能重建、有已知的重建方法、没在用、最近 7 天没改过。拿不准时就列出来但不勾，并写一条警告说明原因。
5. **你自己的文件进废纸篓。** 凡是不能重建的，都用 `Tier.yours` 加 `.trash` 动作，绝不直接删。
6. **要解释，也要能恢复。** 每一项都要有 `reason`；可再生的项只要有恢复办法，就要写上 `restore` 命令。
7. **账要算实。** 数据可能通过克隆或硬链接和别处共享时，设置 `estimateIsLowerBound`，或者用 `SharedAccounting` 实测。永远不要承诺比删除实际能腾出的更多。一项包含另一项时，用 `covers` 标出来。
8. **尊重隐私。** `ctx.isOffLimits(path)` 为真的路径一律跳过。只在别无办法时才读文件内容（并在用户指南的隐私部分写清楚）。
9. **应用数据只给指引。** 属于其他 App 的目录用 `Tier.guide` 加说明，不给删除动作。唯一的例外是 `AppRecognizer`：应用的数据只会跟着整个应用进废纸篓，或者作为它的缓存被删（Caches、Logs、窗口状态、Electron 的缓存文件夹），从不预选；这些条目带着 `app`，应用在运行时执行器会跳过。只能按 bundle id 或专属于这个应用的名字把数据认给它。

## 添加识别器

1. 选好位置：工具缓存放 `DevCacheRecognizer`，模型仓库放 `ModelRecognizer`，已安装的应用和它们在 `~/Library` 里的文件夹放 `AppRecognizer`，应用数据（只给指引）放 `AppDataRecognizer`，项目里的产物放 `ProjectRecognizer`。只有出现一类全新的东西时才新建文件。
2. 通过树来找数据（`ctx.tree.find`、`ctx.size`），不要再遍历一遍磁盘。如果需要识别目录里某个常见文件名，就在 `CFastScan.h` / `fastscan.c` 里加一个标记位（同时改 `SNAP_MAGIC`，见下文）。
3. 构造一个 `Thing`，里面放一个或多个 `ReclaimItem`：id（多次运行之间要保持不变，因为 App 按 id 记住用户的勾选）、label、path、bytes、estimate、tier、action、restore、reason、preselected、warnings。太小、不值得管的跳过（现有识别器的门槛在 50–200 MB 之间）。
4. 如果要运行命令，先用 `Shell.which` 确认工具存在，并让调用尽量轻：识别会在后台反复运行。
5. 如果是新的识别器，在 `Recognize.all` 里注册。
6. 写测试：能找到什么，预选什么，不预选什么。
7. 在 `docs/user-guide.md` 和 `docs/user-guide.zh-CN.md` 里写上说明，并在两份更新日志的「未发布」下各加一行。

### 修改索引格式

如果改了 `sm_node`、快照布局，或者某个标志位、标记位的含义，就要改 `fastscan.c` 里的 `SNAP_MAGIC`。这样旧的索引文件会被拒绝，升级后第一次启动会做一次全盘扫描。在更新日志里注明这一点。

## 代码约定

- **代码风格。** 跟着周围的代码写。函数短小，命名直白。注释简短地解释*为什么*，不要复述代码在做什么。
- **不加新依赖**，除非先讨论过。项目只用 Apple 的框架和系统自带的 SQLite。
- **两种语言都要写。** App 和命令行里给用户看的文字都通过 `L("中文", "English")` 输出。两种都要写；中文要自然，不要逐字翻译。大小用 `Fmt.bytes`（十进制单位，和访达一致）。
- **命令行和 App 行为一致。** 它们共用同一个引擎；一边的行为变了，另一边也应该体现出来。
- **提交信息。** 一行简短的标题说明改了什么，需要的话空一行再写细节。风格参考 `git log`。

## 双语文档

读者会翻阅的每篇文档都有两个文件：英文的 `name.md` 和中文的 `name.zh-CN.md`，开头互相链接。两份要在同一个 PR 里一起更新。如果你只会写一种语言，在 PR 里说明，维护者会在合并前补上另一种。

GitHub 会特殊对待的文件（`SECURITY.md`、`CODE_OF_CONDUCT.md`、issue 和 PR 模板）把两种语言写在同一个文件里。

## 提交 PR

- 一个 PR 只做一件事。
- 运行 `swift test`，并确认 App 还能构建。
- 按模板填写：改了什么、怎么测的；如果列出、预选或删除的行为有变化，还要勾完安全检查清单。
- 用户能感知到的改动，在 `CHANGELOG.md` 和 `CHANGELOG.zh-CN.md` 的「未发布」下各加一行。

发版由维护者负责，见 [docs/releasing.zh-CN.md](docs/releasing.zh-CN.md)。

参与本项目即表示你同意遵守[行为准则](CODE_OF_CONDUCT.md)。
