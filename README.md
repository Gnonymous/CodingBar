# CodingBar

> 常驻 Mac 菜单栏的 **AI 编程副驾驶仪表盘**。用量/成本/行为全部读本地 agent 日志；**仅额度查询联网**（带你自己的 OAuth token 读官方用量接口，只读、不上传）。

Tokei / CodexBar 是**账单**（你花了多少钱）。CodingBar 想做的是**副驾驶仪表盘**：你和 AI 一起干成了什么、值不值、怎么更值。token / 成本 / 额度退居底座，洞察上位。

目前支持 **Claude Code** 与 **Codex**，从 `~/.claude/projects` 与 `~/.codex/sessions` 的本地 jsonl 读取，增量扫描、无外部依赖、无 Xcode（纯 SwiftPM）。

## 它长什么样

**菜单栏**：一个单色脉冲图标 + 两行严格等宽数字。默认上行今日 Token、下行额度剩余 % + 同行变色进度条（绿 ≥50 / 琥珀 25–49 / 红 <25）。脉冲随实时吞吐跳动。点底栏的 `123` 图标可切换上行为今日花费 `$`。

**点开后的面板**（三个 Tab）：
- **总览** — 英雄区把「成果 ↔ 代价」并置（git 产出 +/−行·commit·文件 ‖ 今日花费·token），效率行 `$/行`、`$/commit`；实时教练（当前会话上下文燃料表 + 省钱提示）；额度（Claude 5h/7d/7d·Opus/7d·Sonnet + Codex 5h/7d 实时进度条 + 燃尽预测，凭证失效时降级提示）；近 7 天趋势曲线。
- **习惯** — 工具画像（写/读/跑/搜 占比）、协作节奏（轮数/时长/打断率）、黄金时段热力图。
- **项目** — 项目排行、模型分布、缓存命中率与省下的钱。

设计真源见 `mockups/`（`menubar-numbers-v4.html`、`panel-02.html`）。

## 四大洞察支柱

1. **产出关联**（git）— 把花费翻译成产出：今天 agent 协助产生了多少 +/−行、commit、文件，以及 `$/行`、`$/commit`。归因用「会话时间窗内 cwd 的 git 改动」近似（非精确，诚实标注）。
2. **实时教练** — 当前会话上下文燃料表（含 1M-context 模型识别）、额度燃尽线性预测、省钱/换模型提示（如「N 个简单任务用了 Opus，换 Haiku 可省 $X」）。额度来自官方用量接口（Claude `api.anthropic.com/api/oauth/usage`、Codex `chatgpt.com/backend-api/wham/usage`），OAuth token 从本地 Keychain / `auth.json` 静默读取。
3. **行为镜子** — 工具使用画像、协作节奏、按时段的活跃热力图，全部来自 jsonl 的 `tool_use` 与时间戳。
4. **活着的菜单栏** — 脉冲图标随实时吞吐跳动、里程碑感。

## 运行

需要 macOS 14+ 与 Swift 工具链（Command Line Tools 即可，无需 Xcode）。

```bash
make run        # 调试运行（菜单栏出现脉冲图标）
make dump       # 打印计算出的 Snapshot JSON（验证数据层，不开 GUI）
make test       # 可运行自检（CLT 下没有 XCTest，用这个）
make package    # 产出 dist/CodingBar.app，可双击运行
```

打包后：`open dist/CodingBar.app`，在菜单栏右侧找脉冲图标。

## 架构

纯 SwiftPM，两个 target：

- **`CodingBarCore`** — 数据层（可测、无 UI）：`Scanner`（增量缓存）、`ClaudeScanner`/`CodexScanner`、`Pricing`、`Aggregator`，四支柱 `Behavior`/`Fuel`/`Forecast`/`Coach`/`GitCorrelator`，以及 `Quota/`（`Credentials` 防弹窗凭证读取、`ClaudeQuotaFetcher`/`CodexQuotaFetcher` 联网查额度、`QuotaService` 并发+5min TTL 缓存）。产出一个 `Snapshot`。
- **`CodingBar`** — App（AppKit `NSStatusItem` + SwiftUI）：`UsageStore`（@MainActor ObservableObject）、`RefreshLoop`（30s）、`StatusItemController`（菜单栏 + NSPopover）、`MenuBarItemView`、三 Tab 面板。

数据层与 UI 解耦：`swift run CodingBar --dump-json` 可在不开 GUI 的情况下用真实日志验证数据；UI 用 `--render-menubar` / `--render-panel` 离屏渲染成 PNG 自检。

## 数据与隐私

- **用量 / 成本 / 行为 / git**：100% 本地、离线。只读取 `~/.claude/projects/**/*.jsonl` 与 `~/.codex/sessions/**/*.jsonl`。价格表 `Sources/CodingBar/Resources/pricing.json` 用户可改。
- **额度**：唯一联网的部分。带你自己的 OAuth token 向官方用量接口发 **只读 GET**（查你自己的额度），不上传任何本地内容、不查消费明细。5 分钟 TTL 缓存，不频繁打接口。
- **凭证读取防弹窗**：Claude 的 OAuth token 存在 Keychain（`Claude Code-credentials`）。自签名进程直接读会被 macOS 反复弹密码框，因此 CodingBar **spawn Apple 签名的 `/usr/bin/security`** 来静默读取（它在该条目的可信 ACL 内）；读不到就优雅降级为「额度不可用」，**绝不弹窗**。Codex 走 `~/.codex/auth.json`。

## 现状与路线

v1 已实现上述全部。已知取舍与后续：
- **额度**：Claude + Codex 均改为联网读官方用量接口（实时、含 Claude 细分窗口），防弹窗静默读凭证。接口为非公开端点，官方若调整字段需跟随更新。
- **范围**：总览为「今日」；模型/项目/缓存为「全部」（已如实标注），范围切换器目前是视觉占位，范围联动为路线项。
- **git 产出**为近似归因，非逐行精确。
- **图标**：菜单栏用占位脉冲 glyph，正式图标待设计。
- 未签名公证（本地 ad-hoc）；自动更新（Sparkle）为路线项。

## License

私有项目。参考项目（KeyStats / Tokei / CodexBar）仅作本地研究，不随仓库分发。
