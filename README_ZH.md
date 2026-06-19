<h4 align="right"><a href="README.md">English</a> | <strong>简体中文</strong></h4>

<div align="center">
  <h1>CodingBar</h1>
  <p><b>你的 AI 编程助手干了什么——看菜单栏就知道。</b></p>
  <a href="https://github.com/Gnonymous/CodingBar/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/Gnonymous/CodingBar/ci.yml?branch=main&style=flat-square&label=build" alt="Build"></a>
  <a href="https://github.com/Gnonymous/CodingBar/stargazers"><img src="https://img.shields.io/github/stars/Gnonymous/CodingBar?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/Gnonymous/CodingBar/releases"><img src="https://img.shields.io/github/v/tag/Gnonymous/CodingBar?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache_2.0-blue.svg?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-orange?style=flat-square" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift_6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
</div>

<p align="center">
  <img src="docs/assets/social.png" width="840" alt="CodingBar — 你的 Claude Code 与 Codex 用量仪表盘，就在菜单栏" />
</p>

<p align="center">
  <img src="docs/assets/menubar.png" width="760" alt="CodingBar 菜单栏 — 额度状态" />
</p>

<p align="center">
  <img src="docs/assets/panel-overview.png" width="320" alt="CodingBar 面板 — 总览" />
</p>

<p align="center"><sub><em>截图由 <code>--render-panel</code> 基于样本数据渲染。</em></sub></p>

<details>
<summary><strong>更多视图 — 构成 · 洞察 · 浅色模式</strong></summary>
<br/>
<table>
  <tr>
    <td><img src="docs/assets/panel-composition.png" alt="构成 Tab" /></td>
    <td><img src="docs/assets/panel-insights.png" alt="洞察 Tab" /></td>
    <td><img src="docs/assets/panel-light.png" alt="浅色模式" /></td>
  </tr>
</table>
</details>

## 为什么

Tokei / CodexBar 给你看的是**账单**。CodingBar 给你看的是**仪表盘**：你和 AI 干成了什么、值不值、下次怎么花得更聪明。token 和成本是底座，洞察才是重点。

所有数据从本地 **Claude Code** 与 **Codex** 日志读取——增量扫描、零外部依赖、不需要 Xcode。**唯一自动联网的是额度查询**——用你自己的 token 发只读请求（外加一个可选、需手动触发的更新检查）。

## 特性

<table>
  <tr>
    <td width="50%"><img src="docs/assets/feature-outcome.png" alt="成果优先于花费 — 花的钱读成干成的活" /></td>
    <td width="50%"><img src="docs/assets/feature-coach.png" alt="实时教练 — 上下文燃料、额度燃尽、省钱提示" /></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/assets/feature-behavior.png" alt="行为镜子 — 工具占比、节奏、黄金时段热力" /></td>
    <td width="50%"><img src="docs/assets/feature-privacy.png" alt="本地优先、隐私至上 — 日志永不离开你的机器" /></td>
  </tr>
</table>

<p align="center"><sub><em>功能卡为示意 — 数字均为样本数据。</em></sub></p>

- **成果优先于花费**：git 产出（+/− 行 · commit · 文件）与今日花费并置，附 `$/行`、`$/commit`。花的钱终于能读成*干成的活*。
- **实时教练**：当前会话的上下文燃料表（含 1M-context 识别）、额度燃尽预测，以及省钱提示——如*「8 个简单任务用了 Opus，换 Haiku 可省 $0.9」*。
- **行为镜子**：工具使用占比（写 / 读 / 跑 / 搜）、协作节奏、黄金时段热力图——全来自日志里的 `tool_use` 事件。
- **活着的菜单栏**：单色脉冲随实时吞吐跳动，两行严格等宽数字——今日 token / 花费与剩余额度，随时可见。
- **本地优先、隐私至上**：用量、成本、行为、git 全部 100% 离线。唯一自动联网调用是额度——只读查*你自己*的用量，不上传内容，不弹密码框（唯一例外是可选、需手动点击的更新检查）。
- **原生、零依赖**：纯 SwiftPM，无 Xcode 工程，无第三方包。直接增量读取 `~/.claude/projects` 与 `~/.codex/sessions`。

## 安装

### 下载

从 [Releases](https://github.com/Gnonymous/CodingBar/releases) 下载最新的 `.dmg`（或 `.zip`），打开后把 **CodingBar** 拖进「应用程序」。

应用是 **ad-hoc 签名**（无付费 Apple Developer ID），首次启动 Gatekeeper 会拦。右键 → **打开**，或清掉隔离标记：

```bash
xattr -dr com.apple.quarantine /Applications/CodingBar.app
```

脉冲图标会出现在菜单栏右侧。

### 从源码构建

需要 macOS 14+ 与 Swift 6 工具链（Command Line Tools 即可，无需 Xcode）。

```bash
make run        # 调试运行（菜单栏出现脉冲图标）
make dump       # 打印计算出的 Snapshot JSON（验证数据层，不开 GUI）
make test       # 可运行自检
make package    # 产出 dist/CodingBar.app
```

## 面板

点击菜单栏图标，打开三 Tab 面板：

- **总览**（Overview）— 成果与代价并置（git 产出 ‖ 今日花费）、`$/行` 与 `$/commit`、实时教练（上下文燃料 + 省钱提示）、额度进度条与燃尽预测、近 7 天趋势。
- **构成**（Composition）— 钱花在哪：按模型和按项目拆解花费。
- **洞察**（Insights）— 代码产出、工具使用占比、黄金时段热力图、省钱提示、额度燃尽预测。

> **数字是怎么算的。** *花费*是按 **API 现付价估算**（`Pricing.swift`），**不是你的订阅账单**——包月 Max / ChatGPT 用户应把它读作「等价 API 价值」，而非实际扣款。*代码产出*是**近似的 git 归因**：会话工作目录在时间窗内的全部非 merge 提交——无法区分手写与 AI 提交，且不含未提交改动。*Codex* 的 token 总量按每个会话的累计计数器（`total_token_usage`）做差分去重，不再把重复事件算两遍。

## 隐私

- **用量 / 成本 / 行为 / git** — 100% 本地、离线。只读取 `~/.claude/projects/**/*.jsonl` 与 `~/.codex/sessions/**/*.jsonl`。价格为编译期内置默认值（见 `Sources/CodingBarCore/Pricing.swift`）。
- **额度** — 唯一*自动*联网的部分。带你自己的 OAuth token 向各家用量接口发**只读 GET**（Claude `api.anthropic.com/api/oauth/usage`、Codex `chatgpt.com/backend-api/wham/usage`）。不上传任何本地内容、不查消费明细。5 分钟 TTL 缓存。
- **更新检查** — 唯一的*另一条*联网：**用户主动触发**的对公开 GitHub Releases API 的只读 GET，仅在你于设置中点「检查更新」时发起。无鉴权、无遥测、不上传任何内容。
- **不弹密码框** — Claude 的 OAuth token 存在 Keychain。自签名进程直接读会被 macOS 反复弹窗，CodingBar 改为调用 Apple 签名的 `/usr/bin/security`（在该条目可信 ACL 内）静默读取，读不到就降级为*「额度不可用」*。**始终无弹窗。** Codex 走 `~/.codex/auth.json`。

## 架构

纯 SwiftPM，两个 target，数据层与 UI 完全解耦：

- **`CodingBarCore`** — 无 UI、可测的数据层：`Scanner`（增量缓存）、`ClaudeScanner` / `CodexScanner`、`Pricing`、`Aggregator`，四支柱（`Behavior` / `Fuel` / `Forecast` / `Coach`）加 `GitCorrelator`，以及 `Quota/`（`Credentials`、Claude/Codex fetcher、5min TTL 缓存的 `QuotaService`）。产出一个不可变 `Snapshot`。
- **`CodingBar`** — AppKit `NSStatusItem` + SwiftUI 应用：`UsageStore`（`@MainActor ObservableObject`）、`RefreshLoop`、`StatusItemController`、`MenuBarItemView`，以及三 Tab 面板。

因为分层解耦，`swift run CodingBar --dump-json` 可不开 GUI 用真实日志验证数据，`--render-menubar` / `--render-panel` 能把 UI 离屏渲染成 PNG。完整地图见 [`CLAUDE.md`](CLAUDE.md)。

## 路线

v1 已交付上述全部。接下来：

- 打通范围切换器（总览为「今日」；模型 / 项目 / 缓存为「全部」，已如实标注）。
- 画一个正式 app 图标（菜单栏目前用占位脉冲 glyph）。
- 自动更新（Sparkle）与公证构建。

## 贡献

欢迎 Issue 和 PR。动手前请先看 [`CLAUDE.md`](CLAUDE.md)——里面写了架构、`Models.swift` 冻结契约、注释哲学，还有凭证 / 隐私方面的雷区。CI 在每次 push 时保持 `swift build` 与 `swift test` 绿灯。

## License

[Apache License 2.0](LICENSE)。如果你 fork CodingBar 做自己的产品，换个名字、注明出处就好。参考项目（KeyStats / Tokei / CodexBar）仅作本地研究，不随仓库分发。
