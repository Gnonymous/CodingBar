import Foundation

// MARK: - Price table (compiled-in; CodingBarCore ships no bundle resources, so this
// Swift table is the single source of truth for USD/1M-token rates)

public enum Pricing {

    // USD per 1M tokens
    private struct ModelPrice {
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheWrite5m: Double
        var cacheWrite1h: Double
        var longContextThreshold: Int? = nil
        var longContextInputMultiplier: Double = 1
        var longContextOutputMultiplier: Double = 1
        var isExact = true
    }

    private static func openAI(input: Double, cachedInput: Double? = nil, output: Double,
                               cacheWrite: Double = 0, longContext: Bool = false,
                               isExact: Bool = true) -> ModelPrice {
        ModelPrice(input: input, output: output, cacheRead: cachedInput ?? input,
                   cacheWrite5m: cacheWrite, cacheWrite1h: cacheWrite,
                   longContextThreshold: longContext ? 272_000 : nil,
                   longContextInputMultiplier: longContext ? 2 : 1,
                   longContextOutputMultiplier: longContext ? 1.5 : 1,
                   isExact: isExact)
    }

    private static let fallback = ModelPrice(input: 3, output: 15, cacheRead: 0.3,
                                             cacheWrite5m: 3.75, cacheWrite1h: 6,
                                             isExact: false)

    private static let priceTable: [String: ModelPrice] = [
        // Anthropic Claude — official models
        "anthropic/claude-opus-5-5":   ModelPrice(input: 4,    output: 20,  cacheRead: 0.2,   cacheWrite5m: 5, cacheWrite1h: 8),
        "anthropic/claude-opus-5":     ModelPrice(input: 5,    output: 25,  cacheRead: 0.5,   cacheWrite5m: 6.25, cacheWrite1h: 10),
        "anthropic/claude-opus-4-8":   ModelPrice(input: 5,    output: 25,  cacheRead: 0.5,   cacheWrite5m: 6.25, cacheWrite1h: 10),
        "anthropic/claude-opus-4-7":   ModelPrice(input: 5,    output: 25,  cacheRead: 0.5,   cacheWrite5m: 6.25, cacheWrite1h: 10),
        "anthropic/claude-opus-4-6":   ModelPrice(input: 5,    output: 25,  cacheRead: 0.5,   cacheWrite5m: 6.25, cacheWrite1h: 10),
        "anthropic/claude-opus-4-5":   ModelPrice(input: 5,    output: 25,  cacheRead: 0.5,   cacheWrite5m: 6.25, cacheWrite1h: 10),
        // Deprecated (retires 2026-08-05) but priced 3x the 4.5+ tiers, so it must be
        // enumerated: the "unknown Opus → newest" fallback would otherwise bill it at $5/$25.
        "anthropic/claude-opus-4-1":   ModelPrice(input: 15,   output: 75,  cacheRead: 1.5,   cacheWrite5m: 18.75, cacheWrite1h: 30),
        "anthropic/claude-fable-5-1":  ModelPrice(input: 10,   output: 50,  cacheRead: 0.25,  cacheWrite5m: 12.5, cacheWrite1h: 20),
        "anthropic/claude-fable-5":    ModelPrice(input: 10,   output: 50,  cacheRead: 1,     cacheWrite5m: 12.5, cacheWrite1h: 20),
        // Project Glasswing, invitation-only — same tier as Fable 5. Without a row it would
        // land on the generic $3/$15 fallback, i.e. 3.3x underpriced.
        "anthropic/claude-mythos-5-1": ModelPrice(input: 10,   output: 50,  cacheRead: 0.25,  cacheWrite5m: 12.5, cacheWrite1h: 20),
        "anthropic/claude-mythos-5":   ModelPrice(input: 10,   output: 50,  cacheRead: 1,     cacheWrite5m: 12.5, cacheWrite1h: 20),
        "anthropic/claude-sonnet-5":   ModelPrice(input: 2,    output: 10,  cacheRead: 0.2,   cacheWrite5m: 2.5, cacheWrite1h: 4),
        "anthropic/claude-sonnet-4-6": ModelPrice(input: 3,    output: 15,  cacheRead: 0.3,   cacheWrite5m: 3.75, cacheWrite1h: 6),
        "anthropic/claude-haiku-4-5":  ModelPrice(input: 1,    output: 5,   cacheRead: 0.1,   cacheWrite5m: 1.25, cacheWrite1h: 2),
        // OpenAI standard pay-as-you-go rates. Pro models publish no cached-input
        // discount. GPT-6 and GPT-5.6 cache writes use 1.25x input; both TTL fields
        // use that one tier. Source: https://developers.openai.com/api/docs/pricing
        "openai/gpt-6-astra":          openAI(input: 10,   cachedInput: 1,     output: 50,  cacheWrite: 12.5, longContext: true),
        "openai/gpt-6-sol":            openAI(input: 2,    cachedInput: 0.2,   output: 10,  cacheWrite: 2.5,  longContext: true),
        "openai/gpt-6-luna":           openAI(input: 0.1,  cachedInput: 0.01,  output: 0.5, cacheWrite: 0.125,longContext: true),
        // Promotional standard rate confirmed through at least 2026-11-21.
        "openai/gpt-5.6-sol":          openAI(input: 4,    cachedInput: 0.4,   output: 20,  cacheWrite: 5,    longContext: true),
        "openai/gpt-5.6-terra":        openAI(input: 2,    cachedInput: 0.2,   output: 12,  cacheWrite: 2.5,  longContext: true),
        "openai/gpt-5.6-luna":         openAI(input: 0.2,  cachedInput: 0.02,  output: 1.2, cacheWrite: 0.25, longContext: true),
        "openai/gpt-5.5":              openAI(input: 5,    cachedInput: 0.5,   output: 30,  longContext: true),
        "openai/gpt-5.5-pro":          openAI(input: 30,                         output: 180),
        "openai/gpt-5.4":              openAI(input: 2.5,  cachedInput: 0.25,  output: 15,  longContext: true),
        "openai/gpt-5.4-pro":          openAI(input: 30,                         output: 180, longContext: true),
        "openai/gpt-5.4-mini":         openAI(input: 0.75, cachedInput: 0.075, output: 4.5),
        "openai/gpt-5.4-nano":         openAI(input: 0.2,  cachedInput: 0.02,  output: 1.25),
        "openai/gpt-5.3-codex":        openAI(input: 1.75, cachedInput: 0.175, output: 14),
        "openai/gpt-5.2":              openAI(input: 1.75, cachedInput: 0.175, output: 14),
        "openai/gpt-5.2-pro":          openAI(input: 21,                         output: 168),
        "openai/gpt-5.2-codex":        openAI(input: 1.75, cachedInput: 0.175, output: 14),
        "openai/gpt-5.1":              openAI(input: 1.25, cachedInput: 0.125, output: 10),
        "openai/gpt-5.1-codex":        openAI(input: 1.25, cachedInput: 0.125, output: 10),
        "openai/gpt-5.1-codex-max":    openAI(input: 1.25, cachedInput: 0.125, output: 10),
        "openai/gpt-5.1-codex-mini":   openAI(input: 0.25, cachedInput: 0.025, output: 2),
        "openai/gpt-5":                openAI(input: 1.25, cachedInput: 0.125, output: 10),
        "openai/gpt-5-pro":            openAI(input: 15,                         output: 120),
        "openai/gpt-5-mini":           openAI(input: 0.25, cachedInput: 0.025, output: 2),
        "openai/gpt-5-nano":           openAI(input: 0.05, cachedInput: 0.005, output: 0.4),
        "openai/gpt-5-codex":          openAI(input: 1.25, cachedInput: 0.125, output: 10),
        "openai/codex-mini-latest":    openAI(input: 1.5,  cachedInput: 0.375, output: 6),
        "openai/gpt-4.1":              openAI(input: 2,    cachedInput: 0.5,   output: 8),
        "openai/gpt-4.1-mini":         openAI(input: 0.4,  cachedInput: 0.1,   output: 1.6),
        "openai/gpt-4.1-nano":         openAI(input: 0.1,  cachedInput: 0.025, output: 0.4),
        "openai/gpt-4o":               openAI(input: 2.5,  cachedInput: 1.25,  output: 10),
        "openai/gpt-4o-mini":          openAI(input: 0.15, cachedInput: 0.075, output: 0.6),
        "openai/o3-pro":               openAI(input: 20,                         output: 80),
        "openai/o3":                   openAI(input: 2,    cachedInput: 0.5,   output: 8),
        "openai/o4-mini":              openAI(input: 1.1,  cachedInput: 0.275, output: 4.4),
        "openai/o1-pro":               openAI(input: 150,                        output: 600),
        "openai/o1":                   openAI(input: 15,   cachedInput: 7.5,   output: 60),
        "openai/o1-mini":              openAI(input: 1.1,  cachedInput: 0.55,  output: 4.4),
        "openai/o3-mini":              openAI(input: 1.1,  cachedInput: 0.55,  output: 4.4),
        // These IDs occur in local proxy/Codex logs but are not current official model IDs.
        // Keep their family estimate visible while marking it approximate in the UI.
        "openai/gpt-5.5-codex":        openAI(input: 5,    cachedInput: 0.5,   output: 30,  longContext: true, isExact: false),
        "openai/gpt-5.4-codex":        openAI(input: 2.5,  cachedInput: 0.25,  output: 15,  longContext: true, isExact: false),
        // Other providers seen in logs (best-effort pricing)
        "deepseek/deepseek-v4-flash":  ModelPrice(input: 0.27, output: 1.1, cacheRead: 0.07,  cacheWrite5m: 0, cacheWrite1h: 0),
        "deepseek/deepseek-v4-pro":    ModelPrice(input: 0.55, output: 2.19,cacheRead: 0.14,  cacheWrite5m: 0, cacheWrite1h: 0),
        "mimo/mimo-v2.5-pro":          ModelPrice(input: 1,    output: 4,   cacheRead: 0.5,   cacheWrite5m: 0, cacheWrite1h: 0),
        "mimo/mimo-v2.5":              ModelPrice(input: 0.5,  output: 2,   cacheRead: 0.25,  cacheWrite5m: 0, cacheWrite1h: 0),
    ]

    /// alias → canonical model key (exact, lowercase)
    private static let aliasMap: [String: String] = {
        var m: [String: String] = [:]
        // Claude aliases (canonical keys above + variants seen in real logs)
        // The bare selector tokens ("opus", "sonnet", "haiku") are what Claude Code writes
        // when the user picks a family rather than a version, so they mean *the current*
        // model of that family, not the one that was current when this table was written.
        for alias in ["opus-5.5", "claude-opus-5-5", "opus"] { m[alias] = "anthropic/claude-opus-5-5" }
        for alias in ["opus-5", "claude-opus-5"] { m[alias] = "anthropic/claude-opus-5" }
        for alias in ["opus-4.8", "claude-opus-4-8"] { m[alias] = "anthropic/claude-opus-4-8" }
        for alias in ["opus-4.7", "claude-opus-4-7"] { m[alias] = "anthropic/claude-opus-4-7" }
        for alias in ["opus-4.6", "claude-opus-4-6"] { m[alias] = "anthropic/claude-opus-4-6" }
        for alias in ["opus-4.5", "claude-opus-4-5", "claude-opus-4-5-20251101"] { m[alias] = "anthropic/claude-opus-4-5" }
        for alias in ["opus-4.1", "claude-opus-4-1", "claude-opus-4-1-20250805"] { m[alias] = "anthropic/claude-opus-4-1" }
        for alias in ["fable-5.1", "claude-fable-5-1", "fable"] { m[alias] = "anthropic/claude-fable-5-1" }
        for alias in ["fable-5", "claude-fable-5"] { m[alias] = "anthropic/claude-fable-5" }
        for alias in ["mythos-5.1", "claude-mythos-5-1", "mythos"] { m[alias] = "anthropic/claude-mythos-5-1" }
        for alias in ["mythos-5", "claude-mythos-5"] { m[alias] = "anthropic/claude-mythos-5" }
        for alias in ["sonnet-5", "claude-sonnet-5", "sonnet"] { m[alias] = "anthropic/claude-sonnet-5" }
        for alias in ["sonnet-4.6", "claude-sonnet-4-6"] { m[alias] = "anthropic/claude-sonnet-4-6" }
        for alias in ["haiku-4.5", "claude-haiku-4-5", "haiku",
                      "claude-haiku-4-5-20251001"] { m[alias] = "anthropic/claude-haiku-4-5" }
        // Every canonical OpenAI row accepts its bare API model ID. Keeping this generated
        // from priceTable prevents a model from being priced but unreachable from real logs.
        for key in priceTable.keys where key.hasPrefix("openai/") {
            m[String(key.dropFirst("openai/".count))] = key
        }
        m["gpt-5.6"] = "openai/gpt-5.6-sol"
        m["gpt5.5"] = "openai/gpt-5.5"
        for (snapshot, canonical) in [
            "gpt-5.5-2026-04-23": "openai/gpt-5.5",
            "gpt-5.5-pro-2026-04-23": "openai/gpt-5.5-pro",
            "gpt-5.4-2026-03-05": "openai/gpt-5.4",
            "gpt-5.4-pro-2026-03-05": "openai/gpt-5.4-pro",
            "gpt-5.4-mini-2026-03-17": "openai/gpt-5.4-mini",
            "gpt-5.4-nano-2026-03-17": "openai/gpt-5.4-nano",
            "gpt-5.2-2025-12-11": "openai/gpt-5.2",
            "gpt-5.2-pro-2025-12-11": "openai/gpt-5.2-pro",
            "gpt-5.1-2025-11-13": "openai/gpt-5.1",
            "gpt-5-2025-08-07": "openai/gpt-5",
            "gpt-5-pro-2025-10-06": "openai/gpt-5-pro",
            "gpt-5-mini-2025-08-07": "openai/gpt-5-mini",
            "gpt-5-nano-2025-08-07": "openai/gpt-5-nano",
            "gpt-4.1-2025-04-14": "openai/gpt-4.1",
            "gpt-4.1-mini-2025-04-14": "openai/gpt-4.1-mini",
            "gpt-4.1-nano-2025-04-14": "openai/gpt-4.1-nano",
            "gpt-4o-2024-05-13": "openai/gpt-4o",
            "gpt-4o-2024-08-06": "openai/gpt-4o",
            "gpt-4o-2024-11-20": "openai/gpt-4o",
            "gpt-4o-mini-2024-07-18": "openai/gpt-4o-mini",
            "o1-2024-12-17": "openai/o1",
            "o1-mini-2024-09-12": "openai/o1-mini",
            "o3-2025-04-16": "openai/o3",
            "o3-mini-2025-01-31": "openai/o3-mini",
            "o4-mini-2025-04-16": "openai/o4-mini",
        ] { m[snapshot] = canonical }
        // Other
        for alias in ["deepseek-v4-flash"] { m[alias] = "deepseek/deepseek-v4-flash" }
        for alias in ["deepseek-v4-pro"] { m[alias] = "deepseek/deepseek-v4-pro" }
        for alias in ["mimo-v2.5-pro"] { m[alias] = "mimo/mimo-v2.5-pro" }
        for alias in ["mimo-v2.5"] { m[alias] = "mimo/mimo-v2.5" }
        return m
    }()

    private static func exactCanonicalKey(model: String) -> String? {
        let lower = model.lowercased()
        if priceTable[lower] != nil { return lower }
        if let canonical = aliasMap[lower] { return canonical }
        let modelID = String(lower.split(separator: "/").last ?? Substring(lower))
        if let canonical = aliasMap[modelID] { return canonical }
        // Claude's dated IDs append YYYYMMDD to an otherwise exact model ID. Match
        // only that suffix; `claude-opus-5-6` must not inherit Opus 5's exact price.
        for key in priceTable.keys where key.hasPrefix("anthropic/") {
            let bare = String(key.dropFirst("anthropic/".count))
            guard modelID.hasPrefix(bare + "-") else { continue }
            let suffix = modelID.dropFirst(bare.count + 1)
            if suffix.count == 8 && suffix.allSatisfy(\.isNumber) { return key }
        }
        return nil
    }

    /// Returns the canonical pricing key for a known model, otherwise its raw ID.
    public static func normalize(model: String) -> String {
        exactCanonicalKey(model: model) ?? model.lowercased()
    }

    /// False for the generic fallback and for observed provider aliases whose public
    /// price is only a family estimate. Official canonical IDs, snapshots, and provider-
    /// prefixed forms of those exact IDs remain exact.
    public static func priceIsExact(model: String) -> Bool {
        guard let key = exactCanonicalKey(model: model) else { return false }
        return priceTable[key]?.isExact ?? false
    }

    // MARK: - Display names

    /// Short, prefix-free names for the UI (the provider is shown via the colored dot).
    private static let displayNames: [String: String] = [
        "anthropic/claude-opus-5-5":   "Opus 5.5",
        "anthropic/claude-opus-5":     "Opus 5",
        "anthropic/claude-opus-4-8":   "Opus 4.8",
        "anthropic/claude-opus-4-7":   "Opus 4.7",
        "anthropic/claude-opus-4-6":   "Opus 4.6",
        "anthropic/claude-opus-4-5":   "Opus 4.5",
        "anthropic/claude-opus-4-1":   "Opus 4.1",
        "anthropic/claude-fable-5-1":  "Fable 5.1",
        "anthropic/claude-fable-5":    "Fable 5",
        "anthropic/claude-mythos-5-1": "Mythos 5.1",
        "anthropic/claude-mythos-5":   "Mythos 5",
        "anthropic/claude-sonnet-5":   "Sonnet 5",
        "anthropic/claude-sonnet-4-6": "Sonnet 4.6",
        "anthropic/claude-haiku-4-5":  "Haiku 4.5",
        "openai/gpt-6-astra":          "GPT-6 Astra",
        "openai/gpt-6-sol":            "GPT-6 Sol",
        "openai/gpt-6-luna":           "GPT-6 Luna",
        "openai/gpt-5.6-sol":          "GPT-5.6 Sol",
        "openai/gpt-5.6-terra":        "GPT-5.6 Terra",
        "openai/gpt-5.6-luna":         "GPT-5.6 Luna",
        "openai/gpt-5.5":              "GPT-5.5",
        "openai/gpt-5.5-pro":          "GPT-5.5 Pro",
        "openai/gpt-5.4":              "GPT-5.4",
        "openai/gpt-5.4-pro":          "GPT-5.4 Pro",
        "openai/gpt-5.4-mini":         "GPT-5.4 mini",
        "openai/gpt-5.4-nano":         "GPT-5.4 nano",
        "openai/gpt-5.3-codex":        "GPT-5.3 Codex",
        "openai/gpt-5.2":              "GPT-5.2",
        "openai/gpt-5.2-pro":          "GPT-5.2 Pro",
        "openai/gpt-5.2-codex":        "GPT-5.2 Codex",
        "openai/gpt-5.1":              "GPT-5.1",
        "openai/gpt-5.1-codex":        "GPT-5.1 Codex",
        "openai/gpt-5.1-codex-max":    "GPT-5.1 Codex Max",
        "openai/gpt-5.1-codex-mini":   "GPT-5.1 Codex mini",
        "openai/gpt-5":                "GPT-5",
        "openai/gpt-5-pro":            "GPT-5 Pro",
        "openai/gpt-5-mini":           "GPT-5 mini",
        "openai/gpt-5-nano":           "GPT-5 nano",
        "openai/gpt-5-codex":          "GPT-5 Codex",
        "openai/codex-mini-latest":    "Codex mini",
        "openai/gpt-4.1":              "GPT-4.1",
        "openai/gpt-4.1-mini":         "GPT-4.1 mini",
        "openai/gpt-4.1-nano":         "GPT-4.1 nano",
        "openai/gpt-4o":               "GPT-4o",
        "openai/gpt-4o-mini":          "GPT-4o mini",
        "openai/o3-pro":               "o3 Pro",
        "openai/o3":                   "o3",
        "openai/o4-mini":              "o4-mini",
        "openai/o1-pro":               "o1 Pro",
        "openai/o1":                   "o1",
        "openai/o1-mini":              "o1-mini",
        "openai/o3-mini":              "o3-mini",
        "openai/gpt-5.5-codex":        "GPT-5.5 Codex",
        "openai/gpt-5.4-codex":        "GPT-5.4 Codex",
        "deepseek/deepseek-v4-flash":  "DeepSeek Flash",
        "deepseek/deepseek-v4-pro":    "DeepSeek Pro",
        "mimo/mimo-v2.5-pro":          "MiMo v2.5 Pro",
        "mimo/mimo-v2.5":              "MiMo v2.5",
    ]

    /// A clean, prefix-free label for a canonical key (or any raw model id).
    public static func displayName(forCanonicalKey key: String) -> String {
        if let n = displayNames[key] { return n }
        // Unknown id: drop any "provider/" prefix, keep the rest.
        if let slash = key.lastIndex(of: "/") {
            return String(key[key.index(after: slash)...])
        }
        return key
    }

    private static func price(forCanonicalKey key: String, at timestamp: Date) -> ModelPrice {
        _ = timestamp
        // Keep known-family estimates for unrecognized versions while preserving the
        // raw ID (and priceIsExact == false) in the UI.
        if priceTable[key] == nil {
            let modelID = String(key.lowercased().split(separator: "/").last ?? Substring(key.lowercased()))
            if modelID.hasPrefix("claude-opus-") { return priceTable["anthropic/claude-opus-5-5"]! }
            if modelID.hasPrefix("claude-fable-") { return priceTable["anthropic/claude-fable-5-1"]! }
            if modelID.hasPrefix("claude-mythos-") { return priceTable["anthropic/claude-mythos-5-1"]! }
            if modelID.hasPrefix("claude-sonnet-") { return priceTable["anthropic/claude-sonnet-5"]! }
            if modelID.hasPrefix("claude-haiku-") { return priceTable["anthropic/claude-haiku-4-5"]! }
        }
        return priceTable[key] ?? fallback
    }

    private static func multipliers(for price: ModelPrice, billingInputTokens: Int) -> (input: Double, output: Double) {
        guard let threshold = price.longContextThreshold, billingInputTokens > threshold else {
            return (1, 1)
        }
        return (price.longContextInputMultiplier, price.longContextOutputMultiplier)
    }

    /// Compute USD cost for one log record at its historical price point. Claude usage
    /// carries the absolute prompt size in the token fields; Codex passes last_token_usage's
    /// input count because its billable TokenBreakdown is a delta of cumulative counters.
    public static func cost(model: String, tokens: TokenBreakdown, at timestamp: Date,
                            cacheWrite1h: Int = 0, billingInputTokens: Int? = nil) -> Double {
        let key = normalize(model: model)
        let p = price(forCanonicalKey: key, at: timestamp)
        let oneHourWrites = min(max(cacheWrite1h, 0), tokens.cacheWrite)
        let fiveMinuteWrites = tokens.cacheWrite - oneHourWrites
        let promptTokens = max(0, billingInputTokens ?? (tokens.input + tokens.cacheRead + tokens.cacheWrite))
        let multiplier = multipliers(for: p, billingInputTokens: promptTokens)

        let c = (Double(tokens.input)      * p.input * multiplier.input
               + Double(tokens.output + tokens.reasoning) * p.output * multiplier.output
               + Double(tokens.cacheRead)  * p.cacheRead * multiplier.input
               + Double(fiveMinuteWrites)  * p.cacheWrite5m * multiplier.input
               + Double(oneHourWrites)     * p.cacheWrite1h * multiplier.input) / 1_000_000
        return c
    }

    /// Provider inferred from canonical key.
    public static func provider(forCanonicalKey key: String) -> Provider {
        if key.hasPrefix("openai/") { return .codex }
        let lower = key.lowercased()
        // Unmatched OpenAI/Codex variants (kept under their own id) still read as codex.
        if lower.contains("gpt") || lower.contains("codex") || lower == "o1" { return .codex }
        // deepseek/mimo/sensenova/glm etc. seen via Claude Code's remote provider routing
        // — treat as claude for aggregation purposes (they appear in Claude logs)
        return .claude
    }

    /// Input price (per 1M) for a canonical key — used for cache savings calculation.
    public static func inputPrice(forCanonicalKey key: String, at timestamp: Date = Date(),
                                  billingInputTokens: Int = 0) -> Double {
        let p = price(forCanonicalKey: key, at: timestamp)
        return p.input * multipliers(for: p, billingInputTokens: billingInputTokens).input
    }

    /// Cache read price (per 1M) for a canonical key.
    public static func cacheReadPrice(forCanonicalKey key: String, at timestamp: Date = Date(),
                                      billingInputTokens: Int = 0) -> Double {
        let p = price(forCanonicalKey: key, at: timestamp)
        return p.cacheRead * multipliers(for: p, billingInputTokens: billingInputTokens).input
    }
}
