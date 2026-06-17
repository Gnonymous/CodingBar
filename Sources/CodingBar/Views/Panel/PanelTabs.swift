import SwiftUI
import CodingBarCore

// MARK: - Small shared helpers

struct PanelDivider: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

/// Interactive segmented control (range pills, trend metric).
struct SegToggle: View {
    let options: [String]
    let selected: Int
    let onSelect: (Int) -> Void
    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                Button { onSelect(i) } label: {
                    Text(o)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(i == selected ? Theme.primaryText : Theme.faintText)
                        .padding(.vertical, 2).padding(.horizontal, 7)
                        .background(i == selected ? AnyView(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.10))) : AnyView(Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.18)))
    }
}

private struct TipBox: View {
    let tip: Insight
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lightbulb.fill").font(.system(size: 12)).foregroundStyle(Theme.quotaAmber)
            Text(tip.text).font(.system(size: 12.5)).foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.quotaAmber.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.quotaAmber.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Overview tab

struct OverviewTab: View {
    @ObservedObject var store: UsageStore
    @State private var trendUseCost = true
    private var snap: Snapshot { store.snapshot }
    // The overview for the selected range, from the precomputed set (instant switch).
    private var o: Overview { snap.overviews.first { $0.range == store.selectedRange } ?? snap.overview }
    private var tip: Insight? { snap.coach.first { $0.kind == .tip } }
    private var forecast: Insight? { snap.coach.first { $0.kind == .forecast } }
    private var perLine: String {
        o.output.added > 0 ? String(format: "$%.4f", o.spend.cost / Double(o.output.added)) : "—"
    }
    private var perCommit: String {
        o.output.commits > 0 ? Panel.money(o.spend.cost / Double(o.output.commits)) : "—"
    }
    private var rangeIndex: Int { switch store.selectedRange { case .today: 0; case .week: 1; case .month: 2 } }
    private var rangeWord: String { switch store.selectedRange { case .today: "今日"; case .week: "近7天"; case .month: "近30天" } }
    private var deltaWord: String { switch store.selectedRange { case .today: "较昨日"; case .week: "较上周"; case .month: "较上月" } }
    private func setRangeIndex(_ i: Int) { store.setRange(i == 0 ? .today : (i == 1 ? .week : .month)) }

    var body: some View {
        VStack(spacing: 15) {
            // Hero: 成果 ↔ 代价
            VStack(spacing: 12) {
                SectionHeader(title: "\(rangeWord) · 成果 ↔ 代价") {
                    SegToggle(options: ["今日","周","月"], selected: rangeIndex, onSelect: setRangeIndex)
                }
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("成果").font(.system(size: 10.5, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(Theme.faintText)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("+\(o.output.added.formatted())").font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(Theme.gain)
                            Text("−\(o.output.removed.formatted())").font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.loss)
                        }
                        Text("\(o.output.commits) commit · \(o.output.files) 文件").font(.system(size: 12)).foregroundStyle(Theme.dimText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(Theme.hairline).frame(width: 1, height: 56)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("代价").font(.system(size: 10.5, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(Theme.faintText)
                        Text(Panel.money(o.spend.cost)).font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(Theme.primaryText)
                        HStack(spacing: 8) {
                            Text("\(Panel.tokens(o.spend.tokens.total)) token").font(.system(size: 12)).foregroundStyle(Theme.dimText)
                            deltaView
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                }
                // efficiency strip
                HStack(spacing: 14) {
                    Text("效率").font(.system(size: 10.5, weight: .semibold, design: .monospaced)).tracking(0.8).foregroundStyle(Theme.brandAmber)
                    effItem(perLine, "/行")
                    effItem(perCommit, "/commit")
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8).padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.brandAmber.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.brandAmber.opacity(0.22), lineWidth: 1))
            }

            PanelDivider()

            // 实时教练
            VStack(alignment: .leading, spacing: 11) {
                SectionHeader("实时教练")
                if let f = snap.fuel { FuelGaugeView(fuel: f, active: snap.menu.active) }
                if let tip { TipBox(tip: tip) }
            }

            PanelDivider()

            // 额度 — grouped by provider (Claude / Codex), each window shows 已用%
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "额度 · 已用") { Text("剩余至重置").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.faintText) }
                if snap.quota.isEmpty && snap.quotaNotes.isEmpty {
                    Text("暂无可读取的额度数据").font(.system(size: 12)).foregroundStyle(Theme.faintText)
                } else {
                    quotaGroup(.claude)
                    quotaGroup(.codex)
                    ForEach(snap.quotaNotes, id: \.self) { note in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10)).foregroundStyle(Theme.quotaAmber)
                            Text(note).font(.system(size: 11)).foregroundStyle(Theme.dimText)
                        }
                    }
                }
                if let forecast {
                    HStack(spacing: 7) {
                        Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(Theme.faintText)
                        Text(forecast.text).font(.system(size: 11.5)).foregroundStyle(Theme.dimText)
                    }
                }
            }

            PanelDivider()

            // 趋势
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "趋势 · 近 7 天") {
                    SegToggle(options: ["花费","Token"], selected: trendUseCost ? 0 : 1) { trendUseCost = ($0 == 0) }
                }
                TrendChartView(points: o.trend, useCost: trendUseCost).frame(height: 88)
            }
        }
        .padding(.horizontal, Panel.hPad).padding(.top, 14).padding(.bottom, 16)
    }

    @ViewBuilder
    private func quotaGroup(_ provider: Provider) -> some View {
        let windows = snap.quota.filter { $0.provider == provider }
        if !windows.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                QuotaGroupHeader(provider: provider)
                ForEach(windows) { QuotaRow(window: $0, now: snap.generatedAt) }
            }
        }
    }

    private var deltaView: some View {
        let up = o.deltaVsPrevPct >= 0
        return HStack(spacing: 2) {
            Image(systemName: up ? "arrow.up" : "arrow.down").font(.system(size: 9, weight: .bold))
            Text("\(Int(abs(o.deltaVsPrevPct).rounded()))% \(deltaWord)").font(.system(size: 12))
        }.foregroundStyle(Theme.faintText)
    }
    private func effItem(_ v: String, _ unit: String) -> some View {
        HStack(spacing: 1) {
            Text(v).font(.system(size: 12.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.primaryText)
            Text(unit).font(.system(size: 12)).foregroundStyle(Theme.dimText)
        }
    }
}

// MARK: - Habits tab

struct HabitsTab: View {
    let snap: Snapshot
    private var h: Habits { snap.habits }
    var body: some View {
        VStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 11) {
                SectionHeader("工具画像 · 今日")
                if h.toolMix.total == 0 {
                    Text("今日暂无工具调用记录").font(.system(size: 12)).foregroundStyle(Theme.faintText)
                } else {
                    ToolMixBar(mix: h.toolMix)
                }
            }
            PanelDivider()
            VStack(alignment: .leading, spacing: 11) {
                SectionHeader("协作节奏")
                HStack(spacing: 8) {
                    StatCell(String(format: "%.0f", h.rhythm.turnsPerSession), label: "轮 / 会话")
                    StatCell(String(format: "%.0f", h.rhythm.avgMinutes), unit: "min", label: "平均时长")
                    StatCell("\(Int((h.rhythm.interruptRate*100).rounded()))%", label: "打断率")
                }
            }
            PanelDivider()
            VStack(alignment: .leading, spacing: 11) {
                SectionHeader("黄金时段 · 近 30 天")
                if h.heatmap.cells.isEmpty {
                    Text("数据积累中").font(.system(size: 12)).foregroundStyle(Theme.faintText)
                } else {
                    HeatmapView(heat: h.heatmap)
                }
            }
        }
        .padding(.horizontal, Panel.hPad).padding(.top, 14).padding(.bottom, 16)
    }
}

// MARK: - Projects tab

struct ProjectsTab: View {
    let snap: Snapshot
    private var maxProj: Double { max(snap.projects.map { $0.cost }.max() ?? 1, 0.0001) }
    private var maxModel: Double { max(snap.models.map { $0.cost }.max() ?? 1, 0.0001) }
    var body: some View {
        VStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 11) {
                SectionHeader("项目 · 全部")
                ForEach(snap.projects.prefix(5)) { p in
                    BreakdownRow(name: p.name, fraction: p.cost / maxProj, barColor: Theme.brandAmber,
                                 value: "\(Panel.money(p.cost)) · \(Panel.relative(p.lastActive, now: snap.generatedAt))",
                                 nameWidth: 96, valueWidth: 120)
                }
            }
            PanelDivider()
            VStack(alignment: .leading, spacing: 11) {
                SectionHeader("模型分布 · 全部")
                ForEach(snap.models.prefix(5)) { m in
                    BreakdownRow(name: Pricing.displayName(forCanonicalKey: m.model),
                                 dot: m.provider == .claude ? Theme.claudeColor : Theme.codexColor,
                                 fraction: m.cost / maxModel,
                                 barColor: m.provider == .claude ? Theme.claudeColor : Theme.codexColor,
                                 value: "\(Panel.money(m.cost)) · \(Panel.tokens(m.tokens.total))")
                }
            }
            PanelDivider()
            VStack(alignment: .leading, spacing: 11) {
                SectionHeader("缓存效率")
                HStack(spacing: 16) {
                    Text("\(Int((snap.cache.hitRate*100).rounded()))%")
                        .font(.system(size: 30, weight: .bold).monospacedDigit()).foregroundStyle(Theme.quotaGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("命中率").font(.system(size: 12)).foregroundStyle(Theme.dimText)
                        (Text("缓存为你省下 ").foregroundStyle(Theme.dimText)
                         + Text(Panel.money(snap.cache.savedUSD)).foregroundStyle(Theme.primaryText).bold())
                            .font(.system(size: 12.5))
                    }
                }
            }
        }
        .padding(.horizontal, Panel.hPad).padding(.top, 14).padding(.bottom, 16)
    }
}
