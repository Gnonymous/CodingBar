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
    private var ov: Overview { snap.overviews.first { $0.range == range } ?? snap.overview }
    private var rangeLabel: String { switch range { case .today: "今日"; case .week: "近 7 天"; case .month: "近 30 天" } }

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
                    DCLabel(metric == .cost ? "花费" : "Token"); Spacer()
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
                            Text("今日")
                        }
                        .font(.system(size: 9)).foregroundStyle(dc.fg3)
                        // Match the sparkline's internal horizontal inset (pad = 3) so the
                        // caption's endpoints line up with the curve, not the section edge.
                        .padding(.horizontal, 3)
                    }
                    .padding(.top, 11)
                }

                HStack(spacing: 6) {
                    effCard(effLines, metric == .cost ? "行 / $" : "行 / M tok")
                    effCard(effPerCommit, "每 commit")
                    effCard(effCache, "缓存抵扣", emphasize: true)
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

    private var startLabel: String { ov.trend.first.map { md($0.date) } ?? "" }
    private func md(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "M/d"; return f.string(from: d) }

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
                    return "当前 ~\(Panel.usd0(snap.burnPerMin * 60))/小时 · 预计今日 ~\(Panel.usd0(cost * 1.32))"
                }
                return "已停止燃烧 · 今日累计 \(Panel.usd(cost))"
            case .week:
                return "日均 ~\(Panel.usd0(cost / 7)) · 本月预计 ~\(Panel.usd0(cost / 7 * 30))"
            case .month:
                return "日均 ~\(Panel.usd0(cost / 30)) · 月度合计 \(Panel.usd0(cost))"
            }
        case .tokens:
            let tk = ov.spend.tokens.total
            switch range {
            case .today:
                if isBurning {
                    return "当前 ~\(Panel.tok(aggTput * 3600))/小时 · 预计今日 ~\(Panel.tok(Int(Double(tk) * 1.32)))"
                }
                return "已停止燃烧 · 今日累计 \(Panel.tok(tk))"
            case .week:
                return "日均 ~\(Panel.tok(tk / 7)) · 本月预计 ~\(Panel.tok(tk / 7 * 30))"
            case .month:
                return "日均 ~\(Panel.tok(tk / 30)) · 月度合计 \(Panel.tok(tk))"
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
                    DCLabel("实时燃烧"); Spacer()
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
                        Text("/ 分钟").font(.system(size: 11)).foregroundStyle(dc.fg3).padding(.bottom, 2)
                        Spacer()
                        Text("\(sessions.count) 个会话并行").font(.system(size: 11)).foregroundStyle(dc.fg2).padding(.bottom, 2)
                    }
                    .padding(.bottom, 11)
                    VStack(spacing: 8) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { i, s in sessionRow(s, index: i) }
                    }
                } else {
                    Text("空闲 · 当前无会话燃烧")
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
                HStack { DCLabel("省钱"); Spacer(); Text("累计").font(.system(size: 10)).foregroundStyle(dc.fg3) }
                    .padding(.bottom, 9)
                HStack(spacing: 8) {
                    Text("✓").font(.system(size: 11, weight: .bold)).foregroundStyle(dc.good)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5).fill(dc.fixedGood.opacity(0.16)))
                    (Text("缓存命中 ") + Text("\(Int((snap.cache.hitRate * 100).rounded()))%").bold()
                        + Text(" · 已省下 ") + Text(Panel.usd(snap.cache.savedUSD)).bold())
                        .font(.system(size: 11.5)).foregroundStyle(dc.fg)
                }
                if let tip { tipCard(tip).padding(.top, 10) }
            }
        }
    }

    private func tipCard(_ tip: Insight) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("省").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(RoundedRectangle(cornerRadius: 5).fill(dc.accent))
            VStack(alignment: .leading, spacing: 6) {
                Text(tip.text).font(.system(size: 11)).foregroundStyle(dc.fg)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                if let sav = tip.savingUSD {
                    HStack(spacing: 7) {
                        Text("今日可省 \(Panel.usd(sav))")
                            .font(.system(size: 10.5, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 6).fill(dc.good))
                        Button { onShowInsights() } label: {
                            Text("更多建议 →").font(.system(size: 10, weight: .semibold)).foregroundStyle(dc.accent)
                        }
                        .buttonStyle(.plain).focusEffectDisabled()
                    }
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
                    DCLabel("额度"); Spacer()
                    Text("联网 · \(Panel.age(snap.quotaFetchedAt ?? snap.generatedAt, now: snap.generatedAt))")
                        .font(.system(size: 9.5)).foregroundStyle(dc.fg3)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 5).fill(dc.hover))
                }
                .padding(.bottom, 9)

                if !snap.quotaNotes.isEmpty { noteCard(snap.quotaNotes[0]).padding(.bottom, 10) }

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
                    Rectangle().fill(dc.sep).frame(height: 1)
                    Text("已用").font(.system(size: 9)).foregroundStyle(dc.fg3)
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
                Text(Panel.windowLabel(w.label)).font(.system(size: 11, weight: .medium))
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
            Text(Panel.quotaReset(w.resetAt, now: snap.generatedAt))
                .font(.system(size: 9.5)).foregroundStyle(dc.fg3)
                .padding(.leading, 92).padding(.bottom, 2)
        }
    }

    private func noteCard(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("⚠").font(.system(size: 12)).foregroundStyle(dc.warn)
            VStack(alignment: .leading, spacing: 3) {
                Text(note).font(.system(size: 10.5)).foregroundStyle(dc.fg).fixedSize(horizontal: false, vertical: true)
                Text("重新登录 →").font(.system(size: 10, weight: .semibold)).foregroundStyle(dc.accent)
            }
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
    let snap: Snapshot
    var metric: MenuMetric = .cost
    @State private var modelsExpanded = false
    @State private var projectsExpanded = false
    private let modelCap = 4
    private let projectCap = 5
    private var maxModelCost: Double { max(snap.models.map { $0.cost }.max() ?? 1, 1e-9) }
    private var maxProjCost: Double { max(snap.projects.map { $0.cost }.max() ?? 1, 1e-9) }
    private var maxModelTokens: Double { max(Double(snap.models.map { $0.tokens.total }.max() ?? 1), 1) }
    private var maxProjTokens: Double { max(Double(snap.projects.map { $0.tokens.total }.max() ?? 1), 1) }
    // Rank by the active metric so the biggest consumer is always on top.
    private var sortedModels: [ModelStat] {
        metric == .cost ? snap.models : snap.models.sorted { $0.tokens.total > $1.tokens.total }
    }
    private var sortedProjects: [ProjectStat] {
        metric == .cost ? snap.projects : snap.projects.sorted { $0.tokens.total > $1.tokens.total }
    }
    private var shownModels: [ModelStat] { modelsExpanded ? sortedModels : Array(sortedModels.prefix(modelCap)) }
    private var shownProjects: [ProjectStat] { projectsExpanded ? sortedProjects : Array(sortedProjects.prefix(projectCap)) }

    var body: some View {
        VStack(spacing: 0) {
            DCSection {
                VStack(alignment: .leading, spacing: 0) {
                    DCLabel(metric == .cost ? "按模型 · 累计花费" : "按模型 · 累计 Token").padding(.bottom, 11)
                    VStack(alignment: .leading, spacing: 11) {
                        ForEach(shownModels) { modelRow($0) }
                    }
                    if snap.models.count > modelCap {
                        expandToggle(modelsExpanded, snap.models.count - modelCap) { modelsExpanded.toggle() }
                            .padding(.top, 10)
                    }
                }
            }
            DCSection {
                VStack(alignment: .leading, spacing: 0) {
                    DCLabel(metric == .cost ? "按项目 · 累计花费" : "按项目 · 累计 Token").padding(.bottom, 11)
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(shownProjects) { projRow($0) }
                    }
                    if snap.projects.count > projectCap {
                        expandToggle(projectsExpanded, snap.projects.count - projectCap) { projectsExpanded.toggle() }
                            .padding(.top, 9)
                    }
                }
            }
        }
    }

    private func expandToggle(_ expanded: Bool, _ hidden: Int, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                Text(expanded ? "收起" : "展开其余 \(hidden) 项").font(.system(size: 10.5, weight: .medium))
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
                Spacer()
                // secondary (the other metric) then primary (the active metric, bold)
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
        if cal.isDateInToday(d) { return "今天" }
        let f = DateFormatter(); f.dateFormat = "M/d"; return f.string(from: d)
    }
}

// MARK: - 洞察 Insights (代码产出 · 习惯 · 建议)

struct InsightsTab: View {
    @Environment(\.dc) private var dc
    @ObservedObject var store: UsageStore
    private var snap: Snapshot { store.snapshot }
    private var range: Range { store.selectedRange }
    private var ov: Overview { snap.overviews.first { $0.range == range } ?? snap.overview }
    private var rangeLabel: String { switch range { case .today: "今日"; case .week: "近 7 天"; case .month: "近 30 天" } }

    var body: some View {
        VStack(spacing: 0) {
            codeOutput
            habitsBlock
            coachBlock
        }
    }

    private var codeOutput: some View {
        DCSection {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    DCLabel("代码产出"); Spacer()
                    Text("\(rangeLabel) · git").font(.system(size: 10)).foregroundStyle(dc.fg3)
                }
                .padding(.bottom, 9)
                HStack(spacing: 11) {
                    Text("+\(Panel.int(ov.output.added))").font(.system(size: 15, weight: .bold)).monospacedDigit().foregroundStyle(dc.good)
                    Text("−\(Panel.int(ov.output.removed))").font(.system(size: 15, weight: .bold)).monospacedDigit().foregroundStyle(dc.bad)
                    Spacer()
                    Text("\(ov.output.commits) commit · \(ov.output.files) 文件").font(.system(size: 11)).foregroundStyle(dc.fg2)
                }
                DCRatioBar(added: ov.output.added, removed: ov.output.removed).padding(.top, 8)
            }
        }
    }

    private var habitsBlock: some View {
        DCSection {
            VStack(alignment: .leading, spacing: 0) {
                Text("工具使用占比").font(.system(size: 9.5)).foregroundStyle(dc.fg3).padding(.bottom, 5)
                DCToolMix(mix: snap.habits.toolMix)
                HStack {
                    Text("活跃热力 · 7 天").font(.system(size: 9.5)).foregroundStyle(dc.fg3)
                    Spacer()
                    Text("高峰 \(snap.habits.heatmap.peakLabel)").font(.system(size: 9.5)).foregroundStyle(dc.fg2)
                }
                .padding(.top, 13).padding(.bottom, 6)
                DCHeatGrid(cells: snap.habits.heatmap.cells)
            }
        }
    }

    private var coachBlock: some View {
        DCSection {
            VStack(alignment: .leading, spacing: 0) {
                DCLabel("建议").padding(.bottom, 10)
                VStack(spacing: 8) {
                    ForEach(snap.coach) { coachCard($0) }
                }
            }
        }
    }

    private func coachCard(_ c: Insight) -> some View {
        let meta: (String, Color) = {
            switch c.kind {
            case .tip: return ("省", dc.good)
            case .forecast: return ("预", dc.warn)
            case .milestone: return ("里", dc.accent)
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
                    Text("可省 \(Panel.usd(s))").font(.system(size: 10.5, weight: .bold)).monospacedDigit().foregroundStyle(.white)
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
