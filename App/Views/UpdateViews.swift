import DiskIndex
import ServiceManagement
import SwiftUI
import Update

/// Bottom of the sidebar, while a newer version is on offer.
struct UpdateCard: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        if let r = updater.release {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("新版本 \(r.version)", "Version \(r.version)"))
                            .font(.callout.weight(.semibold))
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if let p = updater.problem {
                    Text(p).font(.caption).foregroundStyle(.orange).lineLimit(4)
                }
                action
                Button(L("更新内容", "What's New")) { NSWorkspace.shared.open(r.page) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(12)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12))
            .padding(10)
            .help(updater.blocker ?? "")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var status: String {
        switch updater.state {
        case .available: updater.blocker == nil ? L("还没下载", "Not downloaded yet") : L("这里没法自己更新", "Can't update itself here")
        case .downloading: L("正在下载…", "Downloading…")
        case .ready: L("已下载，重新打开即更新", "Downloaded. Relaunch to update.")
        case .installing: L("正在安装…", "Installing…")
        case .installed:
            updater.relaunchPending ? L("等当前的扫描或清理结束后重新打开", "Relaunches when the current scan or cleanup ends")
                : L("已装好，重新打开就能用", "Installed. Relaunch to start using it.")
        case .idle: ""
        }
    }

    @ViewBuilder
    private var action: some View {
        switch updater.state {
        case .downloading, .installing:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        case .installed where updater.relaunchPending:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        default:
            Button {
                Task { await updater.update() }
            } label: {
                Text(actionTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var actionTitle: String {
        if updater.blocker != nil { return L("打开下载页", "Open Download Page") }
        switch updater.state {
        case .ready: return L("重新打开并更新", "Relaunch to Update")
        case .installed: return L("重新打开", "Relaunch")
        default: return L("更新", "Update")
        }
    }
}

/// The menu bar panel's line about a newer version.
struct UpdateMenuRow: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        if let r = updater.release {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                Text(L("新版本 \(r.version)", "Version \(r.version)"))
                Spacer()
                switch updater.state {
                case .downloading, .installing:
                    ProgressView().controlSize(.mini)
                case .installed where updater.relaunchPending:
                    ProgressView().controlSize(.mini)
                case .ready, .installed:
                    Button(L("重新打开", "Relaunch")) { Task { await updater.update() } }.controlSize(.small)
                default:
                    Button(updater.blocker != nil ? L("下载", "Download") : L("更新", "Update")) {
                        Task { await updater.update() }
                    }
                    .controlSize(.small)
                }
            }
            .font(.callout)
        }
    }
}

struct SettingsView: View {
    @Environment(Updater.self) private var updater
    @Environment(Helper.self) private var helper
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @State private var language = Language.saved
    @State private var cli = CommandLineTool()

    var body: some View {
        @Bindable var updater = updater
        Form {
            SwiftUI.Section {
                Picker(L("外观", "Appearance"), selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("语言", "Language"), selection: $language) {
                    ForEach(Language.allCases) { Text($0.title).tag($0) }
                }
                if language.isChinese != Fmt.isChinese {
                    HStack {
                        Text(L("重新打开 SuckMyDisk 后换成 English。", "Switches to 简体中文 when SuckMyDisk reopens.")
                             + (updater.isBusy ? L("正在扫描或清理，结束后才能重新打开。", " It can reopen once scanning or cleaning ends.") : ""))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("立即重新打开", "Relaunch Now"), action: relaunch)
                            .disabled(updater.isBusy)
                    }
                }
            } header: {
                Text(L("通用", "General"))
            }
            .onChange(of: appearance) { Appearance.apply(appearance) }
            .onChange(of: language) { Language.save(language) }

            if cli.bundled != nil {
                SwiftUI.Section {
                    if let installed = cli.installed {
                        HStack {
                            Label(installed.path, systemImage: "checkmark.circle.fill")
                                .symbolRenderingMode(.multicolor)
                                .textSelection(.enabled)
                            Spacer()
                            if installed.path == CommandLineTool.link {
                                Button(L("移除", "Remove"), action: cli.remove).disabled(cli.isWorking)
                            }
                        }
                    } else {
                        HStack {
                            Text(L("终端里还找不到 smd", "Your shell can't find smd yet"))
                            Spacer()
                            if cli.isWorking { ProgressView().controlSize(.small) }
                            Button(L("安装", "Install"), action: cli.install)
                                .disabled(cli.isWorking || !cli.canInstall)
                        }
                    }
                    ForEach(cli.copies.filter { !$0.current }) { c in
                        Label(cliNote(c), systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    if cli.installed == nil, !cli.appIsInPlace {
                        Text(L("先把 SuckMyDisk 移到“应用程序”文件夹再安装：现在它从磁盘映像或下载文件夹里运行，链接会失效。",
                               "Move SuckMyDisk to the Applications folder first: it is running from the disk image or Downloads, and a link to it there would break."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let problem = cli.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text(L("命令行", "Command Line"))
                } footer: {
                    Text(L("smd 和 App 用同一个引擎、同一份索引，加 --json 输出 JSON，方便脚本和编程 agent 调用；运行 smd help 看用法。它在 App 里面，跟着 App 一起更新。安装会在 /usr/local/bin 放一个指向它的链接，要输一次管理员密码；用 Homebrew 安装 App 时会自动链接。",
                           "smd uses the same engine and index as the app and prints JSON with --json, for scripts and coding agents; run smd help to see what it does. It is inside the app and updates with it. Installing puts a link to it in /usr/local/bin and takes an administrator password once; Homebrew links it when it installs the app."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onAppear { cli.refresh() }
            }

            SwiftUI.Section {
                Toggle(L("卸载系统应用时不用输密码", "Uninstall system apps without a password"), isOn: helperOn)
                if helper.state == .needsApproval {
                    HStack {
                        Text(L("还差一步：在系统设置的“登录项与扩展”里允许 SuckMyDisk。", "One more step: allow SuckMyDisk in System Settings, under Login Items & Extensions."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("打开系统设置", "Open System Settings")) { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let problem = helper.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(L("卸载", "Uninstalling"))
            } footer: {
                Text(helperFooter).font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!helper.available)
            .onAppear { helper.refresh() }

            SwiftUI.Section {
                Toggle(L("自动检查更新", "Check for updates automatically"), isOn: $updater.checksAutomatically)
                Toggle(L("自动下载并安装", "Download and install automatically"), isOn: $updater.installsAutomatically)
                    .disabled(!updater.checksAutomatically)
            } header: {
                Text(L("更新", "Updates"))
            } footer: {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!updater.enabled)

            SwiftUI.Section {
                LabeledContent(L("当前版本", "Version"), value: updater.current.description)
                LabeledContent(L("上次检查", "Last checked"), value: lastChecked)
                HStack {
                    Spacer()
                    if updater.isWorking { ProgressView().controlSize(.small) }
                    Button(L("立即检查", "Check Now")) { Task { await updater.check(userInitiated: true) } }
                        .disabled(updater.isWorking)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Scan results are kept: the index is saved on quit, and the lists are rewritten in the new language.
    private func relaunch() {
        do {
            try Updates.relaunch(Bundle.main.bundleURL)
            NSApp.terminate(nil)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// An smd that doesn't update with the app, or a link that no longer leads anywhere.
    private func cliNote(_ c: CommandLineTool.Copy) -> String {
        let here = c.path == CommandLineTool.link && cli.installed == nil
        if c.broken {
            return here
                ? L("\(c.path) 指向的 SuckMyDisk 已经不在原处，点“安装”重新链接。", "\(c.path) leads to a SuckMyDisk that is no longer there. Install links it again.")
                : L("\(c.path) 指向的 SuckMyDisk 已经不在原处。用 Homebrew 装的话：brew reinstall --cask suck-my-disk",
                    "\(c.path) leads to a SuckMyDisk that is no longer there. If Homebrew installed the app: brew reinstall --cask suck-my-disk")
        }
        switch c.kind {
        case .formula:
            return L("\(c.path) 是 Homebrew 单独装的 smd，不跟着 App 更新，终端可能先找到它。改用 App 里的这份：brew uninstall smd",
                     "\(c.path) is Homebrew's separate smd: it doesn't update with the app, and your shell may find it first. To use the app's: brew uninstall smd")
        case .other:
            return here
                ? L("\(c.path) 是单独放进去的一份，不跟着 App 更新。点“安装”会换成 App 里的这份。",
                    "\(c.path) was put there by hand and doesn't update with the app. Install replaces it with the app's.")
                : L("\(c.path) 是单独放进去的一份，不跟着 App 更新，终端可能先找到它，可以删掉。",
                    "\(c.path) was put there by hand: it doesn't update with the app, and your shell may find it first. You can delete it.")
        case .app:
            return c.path
        }
    }

    private var helperOn: Binding<Bool> {
        Binding(get: { helper.state != .off }, set: { $0 ? helper.turnOn() : helper.turnOff() })
    }

    private var helperFooter: String {
        guard helper.available else {
            return L("只有从 GitHub Releases 下载的正式版本带这个助手。", "Only release builds downloaded from GitHub have this helper.")
        }
        return L("App Store 和安装器装的应用属于系统，移到废纸篓要管理员密码。打开后，SuckMyDisk 会装一个以管理员权限运行的小助手，macOS 只在这时请你确认一次，之后卸载不再弹密码框。助手只做一件事：把“应用程序”文件夹里的应用移到你的废纸篓（应用留在后台运行的服务会先停掉），而且只听这份 SuckMyDisk 的；随时可以在这里或系统设置里关掉。",
                 "Apps from the App Store or an installer belong to the system, so moving them to the Trash takes an administrator password. Turned on, SuckMyDisk installs a small helper that runs with administrator rights; macOS asks you to allow it once, and uninstalling no longer brings up a password dialog. The helper does one thing: move apps in the Applications folder to your Trash (stopping first any service the app left running in the background), and only when this copy of SuckMyDisk asks. Turn it off here or in System Settings at any time.")
    }

    private var footer: String {
        guard updater.enabled else {
            return L("只有从 GitHub Releases 下载的正式版本会自己更新。", "Only release builds downloaded from GitHub update themselves.")
        }
        return L("大约每天检查一次 GitHub Releases。新版本在后台下载，签名必须和这个版本出自同一个开发者、并经过 Apple 公证才会安装。安装在 SuckMyDisk 处于后台、窗口关着、没有扫描或清理时进行，一两秒后它自己重新打开；也会在你退出时装上。",
                 "Checks GitHub Releases about once a day. A new version downloads in the background and installs only if it is signed by the same developer as this one and notarized by Apple. It installs while SuckMyDisk is in the background with its window closed and nothing is scanning or cleaning, then reopens in a second or two, or when you quit.")
    }

    private var lastChecked: String {
        guard let d = updater.lastCheck else { return L("从未", "Never") }
        return d.formatted(.relative(presentation: .named).locale(Locale(identifier: Fmt.isChinese ? "zh_Hans" : "en")))
    }
}
