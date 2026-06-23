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
- **Privacy boundary.** Two read-only network paths, both carrying no local data: (1) the quota path (the user's own usage, with their OAuth token); (2) Sparkle's update channel — the app pulls a small `appcast.xml` from GitHub Releases on a daily schedule **only after the user opts in** via Settings → "自动检查更新" (default off, persisted by Sparkle in NSUserDefaults), and downloads an update zip only after the user confirms in Sparkle's prompt. Every update is EdDSA-signature-verified against the public key in `Info.plist` (`SUPublicEDKey`), so a tampered feed/zip is silently rejected. No auth, no telemetry, no local data uploaded on either path. Never add code that uploads local logs, content, or telemetry.
- **Git attribution is approximate** (changes in the session's cwd within its time window), and the code labels it as such. Keep it honest.
- **Releases are ad-hoc signed** (no paid Developer ID). `Scripts/package.sh` assembles the `.app` and accepts `CODINGBAR_VERSION` to stamp `Info.plist` (CI passes the git tag). Pushing a `v*` tag triggers `.github/workflows/release.yml`, which builds, signs, packages a `.dmg`/`.zip`, generates an EdDSA-signed `appcast.xml` (Sparkle feed) using the `SPARKLE_PRIVATE_KEY` secret, and calls `gh release create … --generate-notes` (so the auto-body is minimal by design). The real per-version notes live in `release-notes/vX.Y.Z.md` — after CI publishes the release, overwrite the body with `gh release edit vX.Y.Z --notes-file release-notes/vX.Y.Z.md`. Add the notes file in the same PR that ships the feature, not as an after-thought.
- **Sparkle integration.** `package.sh` embeds `Sparkle.framework` from `.build/release/` into `Contents/Frameworks/` (SwiftPM stages the framework there automatically, including the nested Autoupdate / Updater.app / XPCServices — already ad-hoc signed by upstream). The binary needs `@executable_path/../Frameworks` added to its rpath via `install_name_tool` because SwiftPM doesn't know it's targeting an .app bundle. Signing order is inner-first WITHOUT `--deep` on the outer .app — `--deep` would rewrite Sparkle's nested signatures and break its internal trust chain.
- **Sparkle key setup (one-time, before the first auto-update-capable release).** (1) Download Sparkle's release archive and run `bin/generate_keys` — it writes the **private** key to the macOS Keychain ("Private key for signing Sparkle updates") and prints the **public** key to stdout. (2) Paste the public key into `Scripts/Info.plist`'s `SUPublicEDKey` (replacing `REPLACE_WITH_YOUR_PUBLIC_KEY`). (3) Export the private key with `bin/generate_keys -x sparkle_private.key`, paste its contents into a GitHub Actions repo secret named `SPARKLE_PRIVATE_KEY`, then `rm sparkle_private.key` (never commit it). To rotate the key, repeat all three steps — old clients won't be able to install new updates until they manually upgrade once.

## Design

Design tokens live in `Theme.swift` (`DCTheme` for the panel, `Theme` for the menu bar). Rendered reference screenshots are in `docs/assets/` (regenerate with `swift run CodingBar --render-panel <png> <tab> [light|dark] [scenario] [cost|tokens]`).
