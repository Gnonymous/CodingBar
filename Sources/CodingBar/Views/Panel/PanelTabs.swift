import SwiftUI
import CodingBarCore

// MARK: - 总览 Overview (花费英雄 · 实时燃烧 · 省钱 · 额度)

struct OverviewTab: View {
    @Environment(\.dc) private var dc
    @ObservedObject var store: UsageStore
    var onShowInsights: () -> Void

    private var snap: Snapshot { store.snapshot }
    private var range: Range { store.selectedRange }
    private var metric: MenuMetric { store.menuMetric }
    private var lang: AppLanguage { store.language }
    private var ov: Overview { snap.overviews.first { $0.range == range } ?? snap.overview }

    private var sessions: [LiveSession] { snap.liveSessions }
    private var isBurning: Bool { !sessions.isEmpty }
    private var aggTput: Int { Int(sessions.reduce(0.0) { $0 + $1.throughput }.rounded()) }
    private var tip: Insight? { snap.coach.first { $0.kind == .tip } }

    /// Fixed display order for quota windows within a provider group.
    static func windowRank(_ label: String) -> Int {
        switch label {
        case "5h": return 0
        case "7d·Opus": return 1
        case "7d·Sonnet": return 2
        case "7d": return 3
        default: return 4
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            spendHero
            liveBurn
            savings
            quota
        }
    }

    // MARK: 花费英雄

    private var spendHero: some View {
        DCSection(bottomPad: 13) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    DCLabel(metric == .cost ? lang.t("Cost", "花费") : lang.t("Tokens", "Token")); Spacer()
                    DCRangeSeg(selected: range, onSelect: store.setRange)
                }
                .padding(.bottom, 9)

                HStack(alignment: .bottom, spacing: 9) {
                    Text(metric == .cost ? Panel.usd(ov.spend.cost) : Panel.tok(ov.spend.tokens.total))
                        .font(.system(size: 34, weight: .bold)).monospacedDigit().tracking(-0.85)
                        .foregroundStyle(dc.fg)
                    if let dp = ov.delta(for: metric) { deltaPill(dp).padding(.bottom, 4) }
                }

                HStack(spacing: 6) {
                    Text("◔").font(.system(size: 11)).foregroundStyle(dc.warn)
                    Text(projection).font(.system(size: 10.5)).foregroundStyle(dc.fg2)
                }
                .padding(.top, 7)

                if ov.trend.count >= 3 {
                    VStack(spacing: 7) {
                        DCSparkline(values: metric == .cost ? ov.trend.map { $0.cost } : ov.trend.map { Double($0.tokens) })
                        HStack {
                            Text(startLabel)
                            Spacer()
                            gitCaption
                            Spacer()
                            Text(endLabel)
                        }
                        .font(.system(size: 9)).foregroundStyle(dc.fg3)
                        // Match the sparkline's internal horizontal inset (pad = 3) so the
                        // caption's endpoints line up with the curve, not the section edge.
                        .padding(.horizontal, 3)
                    }
                    .padding(.top, 11)
                }

                HStack(spacing: 6) {
                    effCard(effLines, metric == .cost ? lang.t("lines / $", "行 / $") : lang.t("lines / M tok", "行 / M tok"))
                    effCard(effPerCommit, lang.t("per commit", "每 commit"))
                    effCard(effCache, lang.t("cache savings", "缓存抵扣"), emphasize: true)
                }
                .padding(.top, 11)
            }
        }
    }

    private func deltaPill(_ dp: Double) -> some View {
        let up = dp >= 0
        return HStack(spacing: 2) {
            Text(up ? "↑" : "↓")
            Text(String(format: "%.1f%%", abs(dp)))
        }
        .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
        .foregroundStyle(up ? dc.warn : dc.good)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(up ? dc.deltaUpBg : dc.deltaDownBg))
    }

    // Today buckets by hour, so its caption reads "9:00 → 现在"; the wider ranges
    // read "M/d → 今日". Both endpoints must match the bucketing in Aggregator.
    private var startLabel: String {
        guard let first = ov.trend.first?.date else { return "" }
        return range == .today ? hm(first) : md(first)
    }
    private var endLabel: String { range == .today ? lang.t("now", "现在") : lang.t("Today", "今日") }
    private func md(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "M/d"; return f.string(from: d) }
    private func hm(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "H:mm"; return f.string(from: d) }

    /// Git change summary under the sparkline: +added (green) −removed (red) · N commit.
    private var gitCaption: Text {
        Text("+\(Panel.int(ov.output.added))").foregroundStyle(dc.good).fontWeight(.medium)
            + Text(" −\(Panel.int(ov.output.removed))").foregroundStyle(dc.bad).fontWeight(.medium)
            + Text(" · \(ov.output.commits) commit").foregroundStyle(dc.fg3)
    }

    private var projection: String {
        switch metric {
        case .cost:
            let cost = ov.spend.cost
            switch range {
            case .today:
                if isBurning {
                    return lang.t("~\(Panel.usd0(snap.burnPerMin * 60))/hr now · ~\(Panel.usd0(cost * 1.32)) projected today",
                                  "当前 ~\(Panel.usd0(snap.burnPerMin * 60))/小时 · 预计今日 ~\(Panel.usd0(cost * 1.32))")
                }
                return lang.t("Idle · \(Panel.usd(cost)) today", "已停止燃烧 · 今日累计 \(Panel.usd(cost))")
            case .week:
                return lang.t("~\(Panel.usd0(cost / 7))/day · ~\(Panel.usd0(cost / 7 * 30)) projected this month",
                              "日均 ~\(Panel.usd0(cost / 7)) · 本月预计 ~\(Panel.usd0(cost / 7 * 30))")
            case .month:
                return lang.t("~\(Panel.usd0(cost / 30))/day · \(Panel.usd0(cost)) this month",
                              "日均 ~\(Panel.usd0(cost / 30)) · 月度合计 \(Panel.usd0(cost))")
            }
        case .tokens:
            let tk = ov.spend.tokens.total
            switch range {
            case .today:
                if isBurning {
                    return lang.t("~\(Panel.tok(aggTput * 3600))/hr now · ~\(Panel.tok(Int(Double(tk) * 1.32))) projected today",
                                  "当前 ~\(Panel.tok(aggTput * 3600))/小时 · 预计今日 ~\(Panel.tok(Int(Double(tk) * 1.32)))")
                }
                return lang.t("Idle · \(Panel.tok(tk)) today", "已停止燃烧 · 今日累计 \(Panel.tok(tk))")
            case .week:
                return lang.t("~\(Panel.tok(tk / 7))/day · ~\(Panel.tok(tk / 7 * 30)) projected this month",
                              "日均 ~\(Panel.tok(tk / 7)) · 本月预计 ~\(Panel.tok(tk / 7 * 30))")
            case .month:
                return lang.t("~\(Panel.tok(tk / 30))/day · \(Panel.tok(tk)) this month",
                              "日均 ~\(Panel.tok(tk / 30)) · 月度合计 \(Panel.tok(tk))")
            }
        }
    }

    // 行 / $ (cost) or 行 / 百万 token (tokens).
    private var effLines: String {
        switch metric {
        case .cost:
            return ov.spend.cost > 0 ? Panel.int(Int((Double(ov.output.added) / ov.spend.cost).rounded())) : "0"
        case .tokens:
            let mtok = Double(ov.spend.tokens.total) / 1_000_000
            return mtok > 0 ? Panel.int(Int((Double(ov.output.added) / mtok).rounded())) : "0"
        }
    }
    // $ per commit (cost) or tokens per commit (tokens) — the per-commit consumption.
    private var effPerCommit: String {
        guard ov.output.commits > 0 else { return metric == .cost ? "$0" : "0" }
        switch metric {
        case .cost:   return Panel.usd0(ov.spend.cost / Double(ov.output.commits))
        case .tokens: return Panel.tok(ov.spend.tokens.total / ov.output.commits)
        }
    }
    private var effCache: String { "\(Int((snap.cache.hitRate * 100).rounded()))%" }

    private func effCard(_ value: String, _ label: String, emphasize: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 13, weight: .bold)).monospacedDigit()
                .foregroundStyle(emphasize ? dc.good : dc.fg)
            Text(label).font(.system(size: 8.5)).foregroundStyle(dc.fg3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(dc.elev))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(dc.sep2, lineWidth: 0.5))
    }

    // MARK: 实时燃烧

    private var liveBurn: some View {
        DCSection {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    BreathingDot(size: 7, color: isBurning ? dc.good : dc.fg3, animate: isBurning)
                    DCLabel(lang.t("Live burn", "实时燃烧")); Spacer()
                    if isBurning {
                        Text("\(aggTput) tok/s").font(.system(size: 11)).monospacedDigit().foregroundStyle(dc.fg2)
                    }
                }
                .padding(.bottom, 9)

                if isBurning {
                    HStack(alignment: .bottom, spacing: 7) {
                        Text(metric == .cost ? Panel.usd(snap.burnPerMin) : Panel.tok(aggTput * 60))
                            .font(.system(size: 23, weight: .bold)).monospacedDigit().tracking(-0.46)
                            .foregroundStyle(dc.fg)
                        Text(lang.t("/ min", "/ 分钟")).font(.system(size: 11)).foregroundStyle(dc.fg3).padding(.bottom, 2)
                        Spacer()
                        Text(lang.t("\(sessions.count) in parallel", "\(sessions.count) 个会话并行")).font(.system(size: 11)).foregroundStyle(dc.fg2).padding(.bottom, 2)
                    }
                    .padding(.bottom, 11)
                    VStack(spacing: 8) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { i, s in sessionRow(s, index: i) }
                    }
                } else {
                    Text(lang.t("Idle · no active sessions", "空闲 · 当前无会话燃烧"))
                        .font(.system(size: 11)).foregroundStyle(dc.fg3)
                        .frame(maxWidth: .infinity).padding(12)
                        .background(RoundedRectangle(cornerRadius: 9).fill(dc.elev))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(dc.sep2, lineWidth: 0.5))
                }
            }
        }
    }

    private func sessionRow(_ s: LiveSession, index: Int) -> some View {
        let ratio = Double(s.usedTokens) / Double(max(s.maxTokens, 1))
        return HStack(spacing: 8) {
            BreathingDot(size: 6, color: dc.provider(s.provider), animate: true, delay: Double(index) * 0.4)
            Text(s.name).font(.system(size: 11, weight: .medium)).foregroundStyle(dc.fg)
                .lineLimit(1).truncationMode(.tail).frame(width: 78, alignment: .leading)
            Text(s.model).font(.system(size: 9)).foregroundStyle(dc.fg2)
                .lineLimit(1).truncationMode(.tail).multilineTextAlignment(.center)
                .padding(.horizontal, 5).padding(.vertical, 1).frame(width: 60)
                .background(RoundedRectangle(cornerRadius: 5).fill(dc.hover))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(dc.track)
                    RoundedRectangle(cornerRadius: 3).fill(dc.barSev(ratio))
                        .frame(width: g.size.width * min(max(ratio, 0), 1))
                }
            }
            .frame(height: 5)
            Text("\(Int(s.throughput.rounded())) t/s").font(.system(size: 9.5)).monospacedDigit()
                .foregroundStyle(dc.fg3).frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: 省钱

    private var savings: some View {
        DCSection {
            VStack(alignment: .leading, spacing: 0) {
                HStack { DCLabel(lang.t("Savings", "省钱")); Spacer(); Text(lang.t("all-time", "累计")).font(.system(size: 10)).foregroundStyle(dc.fg3) }
                    .padding(.bottom, 9)
                HStack(spacing: 8) {
                    Text("✓").font(.system(size: 11, weight: .bold)).foregroundStyle(dc.good)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5).fill(dc.fixedGood.opacity(0.16)))
                    (Text(lang.t("Cache hit ", "缓存命中 ")) + Text("\(Int((snap.cache.hitRate * 100).rounded()))%").bold()
                        + Text(lang.t(" · saved ", " · 已省下 ")) + Text(Panel.usd(snap.cache.savedUSD)).bold())
                        .font(.system(size: 11.5)).foregroundStyle(dc.fg)
                }
                if let tip { tipCard(tip).padding(.top, 10) }
            }
        }
    }

    private func tipCard(_ tip: Insight) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tip.text).font(.system(size: 11)).foregroundStyle(dc.fg)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            if let sav = tip.savingUSD {
                HStack(spacing: 7) {
                    Text(lang.t("Save \(Panel.usd(sav)) today", "今日可省 \(Panel.usd(sav))"))
                        .font(.system(size: 10.5, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(dc.good))
                    Button { onShowInsights() } label: {
                        Text(lang.t("More tips →", "更多建议 →")).font(.system(size: 10, weight: .semibold)).foregroundStyle(dc.accent)
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(dc.tipBg))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(dc.tipBorder, lineWidth: 0.5))
    }

    // MARK: 额度

    private var quota: some View {
        DCSection {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    DCLabel(lang.t("Quota", "额度")); Spacer()
                    // nil fetchedAt = nothing fetched; show "offline", not a "just now"
                    // that the `?? generatedAt` fallback would otherwise fake as online.
                    Text(snap.quotaFetchedAt == nil
                         ? lang.t("offline", "未连接")
                         : lang.t("online · ", "联网 · ") + Panel.age(snap.quotaFetchedAt, now: snap.generatedAt, lang: lang))
                        .font(.system(size: 9.5)).foregroundStyle(dc.fg3)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 5).fill(dc.hover))
                }
                .padding(.bottom, 9)

                // Render EVERY provider's degradation note (Claude + Codex can both
                // fail at once); the old `quotaNotes[0]` silently swallowed the second.
                ForEach(Array(snap.quotaNotes.enumerated()), id: \.offset) { _, note in
                    noteCard(note).padding(.bottom, 10)
                }

                quotaGroup(.claude)
                quotaGroup(.codex)
            }
        }
    }

    @ViewBuilder
    private func quotaGroup(_ provider: Provider) -> some View {
        // Fixed window order (not usage-based): 5h on top, the sub-model 7d windows
        // (Opus / Sonnet) in the middle, the main 7d at the bottom. Stable on ties.
        let windows = snap.quota.filter { $0.provider == provider }
            .enumerated()
            .sorted { (Self.windowRank($0.element.label), $0.offset) < (Self.windowRank($1.element.label), $1.offset) }
            .map { $0.element }
        if !windows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(dc.provider(provider)).frame(width: 7, height: 7)
                    Text(provider == .claude ? "Claude" : "Codex")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(dc.fg)
                    // This provider's true data age (ages during cache-hits / failures;
                    // resets only on a real fetch), so a stale group reads honestly.
                    if let fetched = snap.quotaFetchedByProvider[provider.rawValue] {
                        Text(Panel.age(fetched, now: snap.generatedAt, lang: lang))
                            .font(.system(size: 9)).foregroundStyle(dc.fg3)
                    }
                    Rectangle().fill(dc.sep).frame(height: 1)
                    Text(lang.t("used", "已用")).font(.system(size: 9)).foregroundStyle(dc.fg3)
                }
                .padding(.top, 2).padding(.bottom, 7)

                VStack(alignment: .leading, spacing: 0) { ForEach(windows) { windowRow($0) } }
                    .padding(.bottom, 11)

                if let fc = snap.quotaForecast[provider.rawValue] {
                    HStack(spacing: 6) {
                        Text("◔").font(.system(size: 11)).foregroundStyle(dc.warn)
                        Text(fc).font(.system(size: 10)).foregroundStyle(dc.fg2)
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func windowRow(_ w: QuotaWindow) -> some View {
        let used = 1 - w.remaining
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(Panel.windowLabel(w.label, lang: lang)).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(dc.fg).frame(width: 84, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(dc.track)
                        RoundedRectangle(cornerRadius: 4).fill(dc.usedSev(used))
                            .frame(width: g.size.width * min(max(used, 0), 1))
                    }
                }
                .frame(height: 6)
                Text("\(Int((used * 100).rounded()))%")
                    .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(dc.usedSev(used)).frame(width: 32, alignment: .trailing)
            }
            .padding(.top, 4)
            Text(Panel.quotaReset(w.resetAt, now: snap.generatedAt, lang: lang))
                .font(.system(size: 9.5)).foregroundStyle(dc.fg3)
                .padding(.leading, 92).padding(.bottom, 2)
        }
    }

    private func noteCard(_ note: String) -> some View {
        // The note text carries the actionable guidance (e.g. "Claude 需要重新登录").
        // The old "重新登录 →" affordance was a plain Text with no handler — a dead
        // link — so it's removed rather than left looking tappable.
        HStack(alignment: .top, spacing: 7) {
            Text("⚠").font(.system(size: 12)).foregroundStyle(dc.warn)
            Text(note).font(.system(size: 10.5)).foregroundStyle(dc.fg).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(dc.warnBg))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(dc.warnBorder, lineWidth: 0.5))
    }
}

// MARK: - 构成 Cost (按模型 · 按项目)

struct CostTab: View {
    @Environment(\.dc) private var dc
    @ObservedObject var store: UsageStore
    @State private var modelsExpanded = false
    @State private var projectsExpanded = false
    private let modelCap = 4
    private let projectCap = 5

    private var snap: Snapshot { store.snapshot }
    private var metric: MenuMetric { store.menuMetric }
    private var range: Range { store.selectedRange }
    private var lang: AppLanguage { store.language }
    private var ov: Overview { snap.overviews.first { $0.range == range } ?? snap.overview }
    private var rangeLabel: String { switch range { case .today: lang.t("Today", "今日"); case .week: lang.t("Last 7d", "近 7 天"); case .month: lang.t("Last 30d", "近 30 天") } }
    // Only fall back to the all-time lists for placeholder snapshots that carry NO
    // per-range composition at all (sample / --render-panel). A real snapshot whose
    // *selected* range is genuinely empty (no activity yet today) must render empty to
    // match the $0 overview hero — not silently show lifetime totals under a 今日 pill.
    // Gate on all overviews, not just `ov`, or an empty selected range re-triggers the bug.
    private var hasRangeComposition: Bool { snap.overviews.contains { !$0.models.isEmpty || !$0.projects.isEmpty } }
    private var rangeModels: [ModelStat] { hasRangeComposition ? ov.models : snap.models }
    private var rangeProjects: [ProjectStat] { hasRangeComposition ? ov.projects : snap.projects }

    private var maxModelCost: Double { max(rangeModels.map { $0.cost }.max() ?? 1, 1e-9) }
    private var maxProjCost: Double { max(rangeProjects.map { $0.cost }.max() ?? 1, 1e-9) }
    private var maxModelTokens: Double { max(Double(rangeModels.map { $0.tokens.total }.max() ?? 1), 1) }
    private var maxProjTokens: Double { max(Double(rangeProjects.map { $0.tokens.total }.max() ?? 1), 1) }
    // Rank by the active metric so the biggest consumer is always on top.
    private var sortedModels: [ModelStat] {
        metric == .cost ? rangeModels : rangeModels.sorted { $0.tokens.total > $1.tokens.total }
    }
    private var sortedProjects: [ProjectStat] {
        metric == .cost ? rangeProjects : rangeProjects.sorted { $0.tokens.total > $1.tokens.total }
    }
    private var shownModels: [ModelStat] { modelsExpanded ? sortedModels : Array(sortedModels.prefix(modelCap)) }
    private var shownProjects: [ProjectStat] { projectsExpanded ? sortedProjects : Array(sortedProjects.prefix(projectCap)) }

    var body: some View {
        VStack(spacing: 0) {
            DCSection {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        DCLabel(metric == .cost ? lang.t("By model · cost", "按模型 · 花费") : lang.t("By model · tokens", "按模型 · Token"))
                        Spacer()
                        DCRangeSeg(selected: range, onSelect: store.setRange)
                    }
                    .padding(.bottom, 11)
                    if sortedModels.isEmpty {
                        emptyHint
                    } else {
                        VStack(alignment: .leading, spacing: 11) {
                            ForEach(shownModels) { modelRow($0) }
                        }
                        if sortedModels.count > modelCap {
                            expandToggle(modelsExpanded, sortedModels.count - modelCap) { modelsExpanded.toggle() }
                                .padding(.top, 10)
                        }
                    }
                }
            }
            if !sortedProjects.isEmpty {
                DCSection {
                    VStack(alignment: .leading, spacing: 0) {
                        DCLabel(metric == .cost ? lang.t("By project · cost", "按项目 · 花费") : lang.t("By project · tokens", "按项目 · Token")).padding(.bottom, 11)
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(shownProjects) { projRow($0) }
                        }
                        if sortedProjects.count > projectCap {
                            expandToggle(projectsExpanded, sortedProjects.count - projectCap) { projectsExpanded.toggle() }
                                .padding(.top, 9)
                        }
                    }
                }
            }
            contextSection
            attributionSection
        }
    }

    // MARK: 用量归因 — Skills / Subagents / Plugins / MCP servers (`/usage` "% of usage").
    // Claude-only (Codex carries no attribution tags); follows the range pill + metric.

    @ViewBuilder
    private var attributionSection: some View {
        let a = ov.attribution
        let total = metric == .cost ? a.totalCost : Double(a.totalTokens)
        if !a.isEmpty && total > 0 {
            DCSection {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        DCLabel(lang.t("Usage attribution", "用量归因"))
                        Spacer()
                        Text(lang.t("Claude · approx", "Claude · 近似")).font(.system(size: 9.5)).foregroundStyle(dc.fg3)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 5).fill(dc.hover))
                    }
                    AttributionTable(title: lang.t("Skills · % of usage", "Skill · 占用量"),
                                     rows: a.skills, metric: metric, total: total, dot: dc.accent)
                    AttributionTable(title: lang.t("Subagents · % of usage", "子代理 · 占用量"),
                                     rows: a.subagents, metric: metric, total: total, dot: dc.good)
                    AttributionTable(title: lang.t("Plugins · % of usage", "插件 · 占用量"),
                                     rows: a.plugins, metric: metric, total: total, dot: dc.warn)
                    AttributionTable(title: lang.t("MCP servers · % of usage", "MCP 服务 · 占用量"),
                                     rows: a.mcpServers, metric: metric, total: total, dot: dc.codex)
                }
            }
        }
    }

    // MARK: 按上下文体量 — the `/usage` "what's contributing to your usage" lens.
    // Claude-only (Codex tokens are deltas, not absolute context); follows the range pill
    // and the cost/tokens metric like the rest of this tab.

    private func ctxMetric(_ b: ContextBucket) -> Double { metric == .cost ? b.cost : Double(b.tokens) }
    private var ctxTotal: Double { max(metric == .cost ? ov.contextSpend.totalCost : Double(ov.contextSpend.totalTokens), 1e-9) }

    @ViewBuilder
    private var contextSection: some View {
        let cs = ov.contextSpend
        let total = metric == .cost ? cs.totalCost : Double(cs.totalTokens)
        if total > 0 {
            DCSection {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        DCLabel(metric == .cost ? lang.t("By context size · cost", "按上下文体量 · 花费")
                                                : lang.t("By context size · tokens", "按上下文体量 · Token"))
                        Spacer()
                        Text(lang.t("Claude · approx", "Claude · 近似")).font(.system(size: 9.5)).foregroundStyle(dc.fg3)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 5).fill(dc.hover))
                    }
                    .padding(.bottom, 11)

                    // Stacked share bar (small → mid → large), colored by severity.
                    GeometryReader { g in
                        HStack(spacing: 1) {
                            seg(ctxMetric(cs.small), dc.good, g.size.width)
                            seg(ctxMetric(cs.mid), dc.warn, g.size.width)
                            seg(ctxMetric(cs.large), dc.bad, g.size.width)
                        }
                    }
                    .frame(height: 8).clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.bottom, 12)

                    VStack(alignment: .leading, spacing: 9) {
                        ctxRow(lang.t("≤50k ctx", "≤5万 上下文"), cs.small, dc.good)
                        ctxRow(lang.t("50–150k ctx", "5–15万 上下文"), cs.mid, dc.warn)
                        ctxRow(lang.t(">150k ctx", ">15万 上下文"), cs.large, dc.bad)
                    }

                    // Actionable callout only when large-context spend is non-trivial.
                    let largeShare = ctxMetric(cs.large) / ctxTotal
                    if largeShare >= 0.10 { contextTip(largeShare).padding(.top, 12) }
                }
            }
        }
    }

    private func seg(_ v: Double, _ color: Color, _ width: CGFloat) -> some View {
        Rectangle().fill(color).frame(width: width * (v / ctxTotal))
    }

    private func ctxRow(_ label: String, _ b: ContextBucket, _ color: Color) -> some View {
        let share = ctxMetric(b) / ctxTotal
        return HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(dc.fg)
                .frame(width: 86, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(dc.track)
                    RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.55)).frame(width: g.size.width * share)
                }
            }
            .frame(height: 4)
            Text(metric == .cost ? Panel.usd(b.cost) : Panel.tok(b.tokens))
                .font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(dc.fg)
                .frame(width: 56, alignment: .trailing)
            Text("\(Int((share * 100).rounded()))%").font(.system(size: 10.5)).monospacedDigit()
                .foregroundStyle(dc.fg3).frame(width: 32, alignment: .trailing)
        }
    }

    private func contextTip(_ share: Double) -> some View {
        let pct = Int((share * 100).rounded())
        let text = metric == .cost
            ? lang.t("\(pct)% of spend came from >150k-context turns — /compact mid-task, /clear when switching tasks.",
                     "\(pct)% 的花费来自 >15万 上下文的会话 —— 任务中途 /compact、换任务时 /clear 可省。")
            : lang.t("\(pct)% of tokens came from >150k-context turns — /compact mid-task, /clear when switching tasks.",
                     "\(pct)% 的 Token 来自 >15万 上下文的会话 —— 任务中途 /compact、换任务时 /clear 可省。")
        return HStack(alignment: .top, spacing: 9) {
            Text("◔").font(.system(size: 11, weight: .bold)).foregroundStyle(dc.warn)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(dc.warn.opacity(0.16)))
            Text(text).font(.system(size: 11)).foregroundStyle(dc.fg)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(dc.warnBg))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(dc.warnBorder, lineWidth: 0.5))
    }

    // Empty-state copy needs its own English wording: "No spend in Today" / "in Last 7d"
    // are ungrammatical, so it diverges from the range label used in the section header.
    private var emptyHintText: String {
        switch range {
        case .today: return lang.t("No spend today", "今日暂无消费记录")
        case .week:  return lang.t("No spend in the last 7d", "近 7 天暂无消费记录")
        case .month: return lang.t("No spend in the last 30d", "近 30 天暂无消费记录")
        }
    }

    private var emptyHint: some View {
        Text(emptyHintText)
            .font(.system(size: 11)).foregroundStyle(dc.fg3)
            .frame(maxWidth: .infinity).padding(12)
            .background(RoundedRectangle(cornerRadius: 9).fill(dc.elev))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(dc.sep2, lineWidth: 0.5))
    }

    private func expandToggle(_ expanded: Bool, _ hidden: Int, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                Text(expanded ? lang.t("Collapse", "收起") : lang.t("Show \(hidden) more", "展开其余 \(hidden) 项")).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(dc.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
    }

    private func modelRow(_ m: ModelStat) -> some View {
        let name = (m.provider == .claude ? "Claude " : "Codex ") + Pricing.displayName(forCanonicalKey: m.model)
        let metricVal = metric == .cost ? m.cost : Double(m.tokens.total)
        let maxVal = metric == .cost ? maxModelCost : maxModelTokens
        let share = max(3.0, metricVal / maxVal * 100)
        return VStack(spacing: 4) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2).fill(dc.provider(m.provider)).frame(width: 6, height: 6)
                Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(dc.fg)
                // Off-table models priced by a family guess / fallback rate are flagged
                // so the cost isn't read as exact.
                if !m.pricedExact {
                    Text("?").font(.system(size: 8.5, weight: .bold)).foregroundStyle(dc.warn)
                        .frame(width: 12, height: 12)
                        .background(Circle().fill(dc.warn.opacity(0.16)))
                        .help(lang.t("Estimated price: model not in the pricing table (family/fallback rate used)",
                                     "价格为近似估算：该模型不在内置价格表，按家族/兜底价计"))
                }
                Spacer()
                Text(metric == .cost ? Panel.tok(m.tokens.total) : Panel.usd(m.cost))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(dc.fg3)
                Text(metric == .cost ? Panel.usd(m.cost) : Panel.tok(m.tokens.total))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(dc.fg).frame(width: 66, alignment: .trailing)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(dc.track)
                    RoundedRectangle(cornerRadius: 3).fill(dc.provider(m.provider).opacity(0.65))
                        .frame(width: g.size.width * share / 100)
                }
            }
            .frame(height: 4)
        }
    }

    private func projRow(_ p: ProjectStat) -> some View {
        let metricVal = metric == .cost ? p.cost : Double(p.tokens.total)
        let maxVal = metric == .cost ? maxProjCost : maxProjTokens
        let share = max(3.0, metricVal / maxVal * 100)
        return HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 4) {
                Text(p.name).font(.system(size: 11, weight: .medium)).foregroundStyle(dc.fg).lineLimit(1)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(dc.track)
                        RoundedRectangle(cornerRadius: 2).fill(dc.accent.opacity(0.55))
                            .frame(width: g.size.width * share / 100)
                    }
                }
                .frame(height: 3)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(metric == .cost ? Panel.usd(p.cost) : Panel.tok(p.tokens.total))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(dc.fg)
                Text(lastLabel(p.lastActive)).font(.system(size: 9)).foregroundStyle(dc.fg3)
            }
        }
    }

    private func lastLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return lang.t("today", "今天") }
        let f = DateFormatter(); f.dateFormat = "M/d"; return f.string(from: d)
    }
}

// MARK: - 洞察 Insights (代码产出 · 习惯 · 建议)

struct InsightsTab: View {
    @Environment(\.dc) private var dc
    @ObservedObject var store: UsageStore
    private var snap: Snapshot { store.snapshot }
    private var range: Range { store.selectedRange }
    private var lang: AppLanguage { store.language }
    private var ov: Overview { snap.overviews.first { $0.range == range } ?? snap.overview }
    private var rangeLabel: String { switch range { case .today: lang.t("Today", "今日"); case .week: lang.t("Last 7d", "近 7 天"); case .month: lang.t("Last 30d", "近 30 天") } }

    private var p: ProfileStats { snap.profile }

    var body: some View {
        VStack(spacing: 0) {
            profileBlock
            codeOutput
            habitsBlock
            coachBlock
        }
    }

    // MARK: 档案 — all-time stat-card grid + contribution calendar (Claude-Desktop-style)

    private var profileBlock: some View {
        DCSection {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    DCLabel(lang.t("Profile", "档案")); Spacer()
                    Text(lang.t("all-time", "累计")).font(.system(size: 10)).foregroundStyle(dc.fg3)
                }
                .padding(.bottom, 10)

                DCStatGrid(items: statItems)

                HStack {
                    Text(lang.t("Activity · last 90d", "活跃日历 · 近 90 天")).font(.system(size: 9.5)).foregroundStyle(dc.fg3)
                    Spacer()
                    if p.peakHour >= 0 {
                        Text(lang.t("Peak \(peakHourLabel)", "高峰 \(peakHourLabel)")).font(.system(size: 9.5)).foregroundStyle(dc.fg2)
                    }
                }
                .padding(.top, 14).padding(.bottom, 7)
                DCContribCalendar(cells: p.calendar)

                if let fun = funFact {
                    HStack(alignment: .top, spacing: 6) {
                        Text("✦").font(.system(size: 10)).foregroundStyle(dc.accent)
                        Text(fun).font(.system(size: 10.5)).foregroundStyle(dc.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 11)
                }
            }
        }
    }

    private var statItems: [(label: String, value: String)] {
        [
            (lang.t("Sessions", "会话"), Panel.int(p.sessions)),
            (lang.t("Messages", "消息"), Panel.int(p.messages)),
            (lang.t("Total tokens", "总 Token"), Panel.tok(p.totalTokens)),
            (lang.t("Active days", "活跃天数"), Panel.int(p.activeDays)),
            (lang.t("Current streak", "当前连续"), streakText(p.currentStreak)),
            (lang.t("Longest streak", "最长连续"), streakText(p.longestStreak)),
            (lang.t("Peak hour", "高峰时段"), p.peakHour >= 0 ? peakHourLabel : "—"),
            (lang.t("Favorite model", "最爱模型"), favoriteModelText),
        ]
    }

    private func streakText(_ n: Int) -> String { lang.t("\(n)d", "\(n) 天") }

    // EN reads 12-hour (4 PM); ZH reads 24-hour (16:00), matching each locale's habit.
    private var peakHourLabel: String {
        let h = p.peakHour
        guard h >= 0 else { return "—" }
        let h12 = h % 12 == 0 ? 12 : h % 12
        return lang.t("\(h12) \(h < 12 ? "AM" : "PM")", String(format: "%02d:00", h))
    }

    private var favoriteModelText: String {
        p.favoriteModel.isEmpty ? "—" : Pricing.displayName(forCanonicalKey: p.favoriteModel)
    }

    // Flourish from Claude Desktop's Overview. ~100K tokens ≈ the text of the first
    // Harry Potter (~77K words). Purely cosmetic, computed from the all-time total.
    private var funFact: String? {
        let t = p.totalTokens
        guard t > 0 else { return nil }
        let books = Double(t) / 100_000.0
        let mult = books >= 1 ? Panel.int(Int(books.rounded())) : String(format: "%.1f", books)
        return lang.t("You've burned ~\(mult)× the text of Harry Potter and the Philosopher's Stone.",
                      "你已经烧掉约 \(mult) 本《哈利·波特与魔法石》的文字量。")
    }

    private var codeOutput: some View {
        DCSection {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    DCLabel(lang.t("Code output", "代码产出")); Spacer()
                    Text("\(rangeLabel) · git").font(.system(size: 10)).foregroundStyle(dc.fg3)
                }
                .padding(.bottom, 9)
                HStack(spacing: 11) {
                    Text("+\(Panel.int(ov.output.added))").font(.system(size: 15, weight: .bold)).monospacedDigit().foregroundStyle(dc.good)
                    Text("−\(Panel.int(ov.output.removed))").font(.system(size: 15, weight: .bold)).monospacedDigit().foregroundStyle(dc.bad)
                    Spacer()
                    Text(lang.t("\(ov.output.commits) commits · \(ov.output.files) files", "\(ov.output.commits) commit · \(ov.output.files) 文件")).font(.system(size: 11)).foregroundStyle(dc.fg2)
                }
                DCRatioBar(added: ov.output.added, removed: ov.output.removed).padding(.top, 8)
            }
        }
    }

    private var habitsBlock: some View {
        DCSection {
            VStack(alignment: .leading, spacing: 0) {
                Text(lang.t("Tool usage mix", "工具使用占比")).font(.system(size: 9.5)).foregroundStyle(dc.fg3).padding(.bottom, 5)
                DCToolMix(mix: snap.habits.toolMix)
            }
        }
    }

    private var coachBlock: some View {
        DCSection {
            VStack(alignment: .leading, spacing: 0) {
                DCLabel(lang.t("Tips", "建议")).padding(.bottom, 10)
                VStack(spacing: 8) {
                    ForEach(snap.coach) { coachCard($0) }
                }
            }
        }
    }

    private func coachCard(_ c: Insight) -> some View {
        let meta: (String, Color) = {
            switch c.kind {
            case .tip: return (lang.t("$", "省"), dc.good)
            case .forecast: return (lang.t("~", "预"), dc.warn)
            case .milestone: return (lang.t("★", "里"), dc.accent)
            }
        }()
        return HStack(alignment: .top, spacing: 9) {
            Text(meta.0).font(.system(size: 9, weight: .bold)).foregroundStyle(meta.1)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(dc.coachIconBg(c.kind)))
            VStack(alignment: .leading, spacing: 7) {
                Text(c.text).font(.system(size: 11)).foregroundStyle(dc.fg)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                if let s = c.savingUSD {
                    Text(lang.t("Save \(Panel.usd(s))", "可省 \(Panel.usd(s))")).font(.system(size: 10.5, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(dc.good))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(dc.elev))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(dc.sep2, lineWidth: 0.5))
    }
}
