# CLAUDE.md

Guidance for AI agents (and humans) working in this repo. Keep it accurate; update it when the architecture changes.

## What this is

CodingBar is a macOS menu-bar app that visualizes local AI-coding-agent usage (Claude Code + Codex). Usage, cost, behavior and git output are read **100% locally** from agent log files; **only live quota is networked** (read-only GET to official usage endpoints with the user's own OAuth token).

## Build / run / test

Requires macOS 14+ and a Swift 6 toolchain (Command Line Tools is enough — no Xcode project). Pure SwiftPM.

```bash
make build      # swift build
make run        # launch the menu-bar app
make dump       # print the computed Snapshot as JSON (verify the data layer headlessly)
make test       # swift run CodingBar --self-test (works on CLT; no XCTest needed)
make package    # build dist/CodingBar.app
swift test      # the XCTest smoke suite (needs Xcode toolchain; this is what CI runs)
```

UI is verifiable without a display: `swift run CodingBar --render-menubar <png>` and `--render-panel <png> <tab> [light|dark] [scenario] [cost|tokens]` rasterize components offscreen.

## Architecture

Two SwiftPM targets, data layer fully decoupled from UI:

- **`CodingBarCore`** — headless, testable data library. `ClaudeScanner` parses `~/.claude/projects/**/*.jsonl`, `CodexScanner` parses `~/.codex/sessions/**/rollout-*.jsonl`, both through a shared `Scanner` with an **mtime+size signature cache** (incremental). They produce internal `RawRecord`s. **`Aggregator.run()` is the single orchestrator**: it combines records with the `Pricing` table and the four insight pillars — `Behavior` (→ Habits), `FuelCalculator` (→ live context-window gauge), `Forecaster` (→ quota-depletion forecast), `Coach` (→ cost-saving tips) — plus `GitCorrelator` (code-output stats), and returns one immutable `Snapshot`.
- **`CodingBar`** — AppKit `NSStatusItem` + SwiftUI executable. `main.swift` dispatches CLI flags (`--dump-json` / `--self-test` / `--render-*`) to headless paths or boots the GUI via `AppDelegate` → `{UsageStore, StatusItemController, RefreshLoop}`. `UsageStore` (`@MainActor ObservableObject`) is the single source of truth: it runs aggregation off the main actor and publishes the `Snapshot` to `MenuBarItemView` (status item) and `PanelView` (the `NSPopover` panel with Overview / Cost / Insights tabs built from `PanelKit`/`PanelCharts` atoms, themed via the `DCTheme` environment token).

**Quota** is the only networked path. `Quota/` holds the `QuotaService` actor (5-min TTL cache, last-good fallback), the Claude/Codex fetchers, and `Credentials`. It is **injected into `Aggregator.run(quota:)`** as a parameter, never scanned.

## Conventions & landmines

- **`Models.swift` is a frozen cross-target contract.** `Snapshot` and every nested type are `Codable`/`Sendable` value types shared by both targets and the tests. Do not rename or restructure its public symbols without updating all call sites and the JSON contract.
- **Comment philosophy: high-signal WHY only.** This codebase deliberately keeps comments that explain non-obvious decisions (the Keychain re-prompt workaround, git-attribution approximation, layout/alignment rationale, concurrency reasoning, units, `0...1` fraction semantics, non-public API endpoint notes). Do **not** add narration that restates the code. If you remove a WHY comment, you are probably making a mistake.
- **Credentials never trigger a password prompt.** Claude's OAuth token lives in the Keychain entry `Claude Code-credentials`; a self-signed process reading it directly makes macOS re-prompt endlessly, so CodingBar **spawns the Apple-signed `/usr/bin/security`** (which is inside that entry's trusted ACL) to read it silently, and degrades gracefully to "quota unavailable" if it can't. Codex reads `~/.codex/auth.json`. See `Quota/Credentials.swift` — do not "simplify" this into `SecItemCopyMatching`.
- **Privacy boundary.** Only the quota path touches the network, and only with a read-only GET of the user's own usage. Never add code that uploads local logs, content, or telemetry.
- **Git attribution is approximate** (changes in the session's cwd within its time window), and the code labels it as such. Keep it honest.
- **Releases are ad-hoc signed** (no paid Developer ID). `Scripts/package.sh` assembles the `.app` and accepts `CODINGBAR_VERSION` to stamp `Info.plist` (CI passes the git tag).

## Design

Design tokens live in `Theme.swift` (`DCTheme` for the panel, `Theme` for the menu bar). Rendered reference screenshots are in `docs/assets/` (regenerate with `swift run CodingBar --render-panel <png> <tab> [light|dark] [scenario] [cost|tokens]`).
