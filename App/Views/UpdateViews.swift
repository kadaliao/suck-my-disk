import DiskIndex
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
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @State private var language = Language.saved

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
