import SwiftUI
import ServiceManagement
import CodingBarCore

// MARK: - 设置 (个性化)
// Shown in place of the tab content (the panel lives in a .transient NSPopover, so a
// full-panel swap is more robust than a nested popover/sheet). Reached from the header
// gear; the gear, refresh and metric toggle share one button style.
struct SettingsView: View {
    @Environment(\.dc) private var dc
    @ObservedObject var store: UsageStore
    var onClose: () -> Void

    @State private var launchAtLogin = false
    @State private var launchUnavailable = false
    @State private var updateState: UpdateState = .idle

    private enum UpdateState: Equatable { case idle, checking, done(UpdateChecker.Result) }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 0) {
                toggleRow
                divider
                // Metric (花费/Token) is toggled by the header's $ button, so it's not
                // duplicated here — it still persists via that toggle.
                segRow("菜单栏额度", [(Provider.claude, "Claude"), (Provider.codex, "Codex")], $store.menuQuotaSource)
                divider
                languageRow
                divider
                updateRow
            }
            .padding(.vertical, 2)
            footer
        }
        .frame(width: Panel.width)
        .background(dc.bg)
        .onAppear(perform: syncLaunchState)
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            Text("设置").font(.system(size: 13, weight: .semibold)).tracking(-0.13).foregroundStyle(dc.fg)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .regular)).foregroundStyle(dc.fg3)
                    .padding(.horizontal, 3).padding(.vertical, 1).contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusEffectDisabled().help("关闭设置")
        }
        .padding(.horizontal, 13).padding(.top, 11).padding(.bottom, 10)
        .overlay(Rectangle().fill(dc.sep).frame(height: 1), alignment: .bottom)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("CodingBar \(versionLabel)").font(.system(size: 10)).foregroundStyle(dc.fg3)
            Spacer()
            Button { NSWorkspace.shared.open(UpdateChecker.releasesPageURL) } label: {
                Text("GitHub →").font(.system(size: 10, weight: .medium)).foregroundStyle(dc.accent).contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
        }
        .padding(.horizontal, 13).padding(.top, 8).padding(.bottom, 11)
        .overlay(Rectangle().fill(dc.sep).frame(height: 1), alignment: .top)
    }

    // MARK: Rows

    private var toggleRow: some View {
        row(label: "开机自启动", caption: launchUnavailable ? "打包为 App 后可用" : nil) {
            Toggle("", isOn: $launchAtLogin)
                .labelsHidden().toggleStyle(.switch).tint(dc.accent)
                .disabled(launchUnavailable)
                .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
        }
    }

    private var languageRow: some View {
        // Placeholder: the data layer still emits Chinese strings, so a real language
        // switch waits for the i18n batch. Surfaced here so the slot exists.
        row(label: "界面语言", caption: "跟随系统 · 多语言即将支持") {
            Text("中文").font(.system(size: 11, weight: .medium)).foregroundStyle(dc.fg3)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(dc.segbg))
        }
    }

    private var updateRow: some View {
        row(label: "检查更新", caption: nil) {
            switch updateState {
            case .idle:
                actionLink("检查", color: dc.accent) { runUpdateCheck() }
            case .checking:
                ProgressView().controlSize(.small).scaleEffect(0.85).frame(height: 18)
            case .done(.upToDate(let v)):
                Text("已是最新 v\(v)").font(.system(size: 10.5)).foregroundStyle(dc.fg3)
            case .done(.updateAvailable(let v)):
                actionLink("有新版本 v\(v) →", color: dc.accent) { NSWorkspace.shared.open(UpdateChecker.releasesPageURL) }
            case .done(.failed):
                actionLink("检查失败 · 重试", color: dc.warn) { runUpdateCheck() }
            }
        }
    }

    private func actionLink(_ text: String, color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
    }

    /// Label (+ optional caption) on the left, control on the right.
    private func row<Control: View>(label: String, caption: String?, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(dc.fg)
                if let caption { Text(caption).font(.system(size: 9.5)).foregroundStyle(dc.fg3) }
            }
            Spacer()
            control()
        }
        .padding(.horizontal, Panel.hPad).padding(.vertical, 10)
    }

    /// On-theme segmented control mirroring DCRangeSeg (same as the range pills).
    private func segRow<T: Hashable>(_ label: String, _ options: [(T, String)], _ selection: Binding<T>) -> some View {
        row(label: label, caption: nil) {
            HStack(spacing: 1) {
                ForEach(options, id: \.0) { value, title in
                    let on = selection.wrappedValue == value
                    Button { selection.wrappedValue = value } label: {
                        Text(title)
                            .font(.system(size: 10.5, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? dc.fg : dc.fg2)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(on ? dc.segsel : Color.clear)
                                    .shadow(color: on ? Color.black.opacity(0.18) : .clear, radius: 0.75, y: 0.5)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                }
            }
            .padding(2).background(RoundedRectangle(cornerRadius: 7).fill(dc.segbg))
        }
    }

    private var divider: some View { Rectangle().fill(dc.sep).frame(height: 1).padding(.leading, Panel.hPad) }

    // MARK: Actions

    private var versionLabel: String {
        let v = UpdateChecker.currentVersion
        return v == "dev" ? "开发版" : "v\(v)"
    }

    private func runUpdateCheck() {
        updateState = .checking
        Task {
            let result = await UpdateChecker.check()
            await MainActor.run { updateState = .done(result) }
        }
    }

    private func syncLaunchState() {
        let status = SMAppService.mainApp.status
        launchAtLogin = (status == .enabled)
        // `.notFound` = running unbundled (e.g. `swift run`); registration isn't possible.
        launchUnavailable = (status == .notFound)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        guard !launchUnavailable else { return }
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration can fail (needs approval, unbundled) — reflect the real state.
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}
