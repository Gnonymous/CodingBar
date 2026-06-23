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
    @State private var launchNeedsApproval = false
    @ObservedObject private var updater = UpdateManager.shared
    @State private var autoUpdate = UpdateManager.shared.automaticChecksEnabled

    // This view owns `store`, so it reads the language directly (it can't read an
    // environment value it sets on itself); descendants still read \.lang.
    private var lang: AppLanguage { store.language }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 0) {
                toggleRow
                divider
                // Metric (花费/Token) is toggled by the header's $ button, so it's not
                // duplicated here — it still persists via that toggle.
                segRow(lang.t("Menu bar quota", "菜单栏额度"), [(Provider.claude, "Claude"), (Provider.codex, "Codex")], $store.menuQuotaSource)
                divider
                segRow(lang.t("Language", "界面语言"), [(AppLanguage.en, "English"), (AppLanguage.zh, "中文")], $store.language)
                divider
                autoUpdateRow
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
            Text(lang.t("Settings", "设置")).font(.system(size: 13, weight: .semibold)).tracking(-0.13).foregroundStyle(dc.fg)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .regular)).foregroundStyle(dc.fg3)
                    .padding(.horizontal, 3).padding(.vertical, 1).contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusEffectDisabled().help(lang.t("Close settings", "关闭设置"))
        }
        .padding(.horizontal, 13).padding(.top, 11).padding(.bottom, 10)
        .overlay(Rectangle().fill(dc.sep).frame(height: 1), alignment: .bottom)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("CodingBar \(versionLabel)").font(.system(size: 10)).foregroundStyle(dc.fg3)
            Spacer()
            Button { NSWorkspace.shared.open(UpdateManager.releasesPageURL) } label: {
                Text("GitHub →").font(.system(size: 10, weight: .medium)).foregroundStyle(dc.accent).contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
        }
        .padding(.horizontal, 13).padding(.top, 8).padding(.bottom, 11)
        .overlay(Rectangle().fill(dc.sep).frame(height: 1), alignment: .top)
    }

    // MARK: Rows

    private var launchCaption: String? {
        if launchUnavailable {
            // A real .app that's just not in a stable location → tell the user to install it;
            // a truly unbundled dev run (no .app) only needs the packaged build.
            return Bundle.main.bundlePath.hasSuffix(".app")
                ? lang.t("Move CodingBar to Applications to enable", "请将 CodingBar 移动到「应用程序」后启用")
                : lang.t("Available in the packaged app", "打包为 App 后可用")
        }
        if launchNeedsApproval {
            return lang.t("Allow it in System Settings → Login Items", "请在 系统设置 → 登录项 中允许")
        }
        return nil
    }

    private var toggleRow: some View {
        row(label: lang.t("Launch at login", "开机自启动"), caption: launchCaption) {
            Toggle("", isOn: $launchAtLogin)
                .labelsHidden().toggleStyle(.switch).tint(dc.accent)
                .disabled(launchUnavailable)
                .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
        }
    }

    /// Opt-in toggle. Default off — Sparkle only schedules background checks once
    /// the user explicitly enables this, keeping the "no automatic network" promise
    /// truthful for users who never flip it.
    private var autoUpdateRow: some View {
        row(
            label: lang.t("Auto-check for updates", "自动检查更新"),
            caption: updater.canUpdate ? nil : lang.t("Available in the packaged app", "打包为 App 后可用")
        ) {
            Toggle("", isOn: $autoUpdate)
                .labelsHidden().toggleStyle(.switch).tint(dc.accent)
                .disabled(!updater.canUpdate)
                .onChange(of: autoUpdate) { _, on in updater.automaticChecksEnabled = on }
        }
    }

    /// Manual "立刻检查" — Sparkle's standard user driver provides the
    /// version dialog, progress and restart prompt; we just trigger it.
    /// When Sparkle has already detected a pending update, swap the label to
    /// "立刻更新" so the affordance reads exactly as it would in the prompt itself.
    private var updateRow: some View {
        row(label: lang.t("Check now", "立刻检查"), caption: nil) {
            if !updater.canUpdate {
                Text(lang.t("Dev build", "开发版")).font(.system(size: 10.5)).foregroundStyle(dc.fg3)
            } else if updater.hasAvailableUpdate {
                actionLink(lang.t("Update now →", "立刻更新 →"), color: dc.accent) { updater.checkForUpdates() }
            } else {
                actionLink(lang.t("Check", "检查"), color: dc.accent) { updater.checkForUpdates() }
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
        let v = UpdateManager.currentVersion
        return v == "dev" ? lang.t("Dev build", "开发版") : "v\(v)"
    }

    private func syncLaunchState() {
        let status = SMAppService.mainApp.status
        launchAtLogin = (status == .enabled)
        launchUnavailable = !isStableInstall
        // Registered but the user switched it off in System Settings; only they can re-enable
        // it there, so surface a hint instead of a toggle that silently snaps back.
        launchNeedsApproval = isStableInstall && (status == .requiresApproval)
    }

    /// A login item must point at a path that survives reboot. Gate availability on this, NOT
    /// on `SMAppService.status`: an ad-hoc-signed .app that has never registered reports
    /// `.notFound` (not `.notRegistered`) yet `register()` succeeds, so keying off `.notFound`
    /// wrongly disabled the toggle for every freshly-installed app. The two genuinely
    /// unregistrable cases are (1) an unbundled dev run (`swift run`: no bundle id / no .app),
    /// where register() fails with errSMAppServiceInvalidArgument, and (2) a non-stable
    /// location — a Gatekeeper-translocated read-only copy or a DMG mount, where register()
    /// would persist a login item pointing at a path that vanishes on eject/relaunch.
    private var isStableInstall: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return false }
        return !path.contains("/AppTranslocation/") && !path.hasPrefix("/Volumes/")
    }

    private func setLaunchAtLogin(_ on: Bool) {
        guard !launchUnavailable else { return }
        // `.requiresApproval` can't be cleared programmatically — bounce the user to the pane.
        // Gate on `on` so the follow-up sync that snaps the toggle back to off doesn't re-fire
        // onChange and open System Settings a second time.
        if SMAppService.mainApp.status == .requiresApproval {
            if on { SMAppService.openSystemSettingsLoginItems() }
            syncLaunchState()
            return
        }
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
        syncLaunchState()
    }
}
