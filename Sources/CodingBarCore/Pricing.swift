import Foundation

// MARK: - Price table (hardcoded from pricing.json — CodingBarCore has no bundle resources)

public enum Pricing {

    // USD per 1M tokens
    private struct ModelPrice {
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheWrite: Double
    }

    private static let fallback = ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)

    private static let priceTable: [String: ModelPrice] = [
        // Anthropic Claude — official models
        "anthropic/claude-opus-4-8":   ModelPrice(input: 15,   output: 75,  cacheRead: 1.5,   cacheWrite: 18.75),
        "anthropic/claude-opus-4-7":   ModelPrice(input: 15,   output: 75,  cacheRead: 1.5,   cacheWrite: 18.75),
        "anthropic/claude-opus-4-6":   ModelPrice(input: 15,   output: 75,  cacheRead: 1.5,   cacheWrite: 18.75),
        "anthropic/claude-fable-5":    ModelPrice(input: 3,    output: 15,  cacheRead: 0.3,   cacheWrite: 3.75),
        "anthropic/claude-sonnet-4-6": ModelPrice(input: 3,    output: 15,  cacheRead: 0.3,   cacheWrite: 3.75),
        "anthropic/claude-haiku-4-5":  ModelPrice(input: 1,    output: 5,   cacheRead: 0.1,   cacheWrite: 1.25),
        // OpenAI models (accessed via Claude Code remote MCP or Codex)
        "openai/gpt-5.5":              ModelPrice(input: 1.25, output: 10,  cacheRead: 0.125, cacheWrite: 0),
        "openai/gpt-5.4":              ModelPrice(input: 1.25, output: 10,  cacheRead: 0.125, cacheWrite: 0),
        "openai/gpt-5.4-mini":         ModelPrice(input: 0.15, output: 0.6, cacheRead: 0.075, cacheWrite: 0),
        "openai/o1":                   ModelPrice(input: 15,   output: 60,  cacheRead: 7.5,   cacheWrite: 0),
        // Other providers seen in logs (best-effort pricing)
        "deepseek/deepseek-v4-flash":  ModelPrice(input: 0.27, output: 1.1, cacheRead: 0.07,  cacheWrite: 0),
        "deepseek/deepseek-v4-pro":    ModelPrice(input: 0.55, output: 2.19,cacheRead: 0.14,  cacheWrite: 0),
        "mimo/mimo-v2.5-pro":          ModelPrice(input: 1,    output: 4,   cacheRead: 0.5,   cacheWrite: 0),
        "mimo/mimo-v2.5":              ModelPrice(input: 0.5,  output: 2,   cacheRead: 0.25,  cacheWrite: 0),
    ]

    /// alias → canonical model key (exact, lowercase)
    private static let aliasMap: [String: String] = {
        var m: [String: String] = [:]
        // Claude aliases (from pricing.json + variants seen in real logs)
        for alias in ["opus-4.8", "claude-opus-4-8", "opus"] { m[alias] = "anthropic/claude-opus-4-8" }
        for alias in ["opus-4.7", "claude-opus-4-7"] { m[alias] = "anthropic/claude-opus-4-7" }
        for alias in ["opus-4.6", "claude-opus-4-6"] { m[alias] = "anthropic/claude-opus-4-6" }
        for alias in ["fable-5", "claude-fable-5"] { m[alias] = "anthropic/claude-fable-5" }
        for alias in ["sonnet-4.6", "claude-sonnet-4-6", "sonnet"] { m[alias] = "anthropic/claude-sonnet-4-6" }
        for alias in ["haiku-4.5", "claude-haiku-4-5", "haiku",
                      "claude-haiku-4-5-20251001"] { m[alias] = "anthropic/claude-haiku-4-5" }
        // OpenAI aliases
        for alias in ["gpt-5.5", "gpt5.5"] { m[alias] = "openai/gpt-5.5" }
        for alias in ["gpt-5.4"] { m[alias] = "openai/gpt-5.4" }
        for alias in ["gpt-5.4-mini", "gpt-5.4-mini-2026-03-17"] { m[alias] = "openai/gpt-5.4-mini" }
        m["o1"] = "openai/o1"
        // Other
        for alias in ["deepseek-v4-flash"] { m[alias] = "deepseek/deepseek-v4-flash" }
        for alias in ["deepseek-v4-pro"] { m[alias] = "deepseek/deepseek-v4-pro" }
        for alias in ["mimo-v2.5-pro"] { m[alias] = "mimo/mimo-v2.5-pro" }
        for alias in ["mimo-v2.5"] { m[alias] = "mimo/mimo-v2.5" }
        return m
    }()

    // MARK: - Public API

    /// Returns the canonical pricing key for a raw model string.
    public static func normalize(model: String) -> String {
        let lower = model.lowercased()

        // Direct canonical key match
        if priceTable[lower] != nil { return lower }

        // Exact alias lookup
        if let canonical = aliasMap[lower] { return canonical }

        // Family keyword fallback (ordered most-specific first)
        if lower.contains("opus")         { return "anthropic/claude-opus-4-8" }
        if lower.contains("fable")        { return "anthropic/claude-fable-5" }
        if lower.contains("sonnet")       { return "anthropic/claude-sonnet-4-6" }
        if lower.contains("haiku")        { return "anthropic/claude-haiku-4-5" }
        if lower.contains("gpt-5.4-mini") { return "openai/gpt-5.4-mini" }
        if lower.contains("gpt-5.5") || lower.contains("gpt5.5") { return "openai/gpt-5.5" }
        if lower.contains("gpt-5.4")      { return "openai/gpt-5.4" }
        if lower.contains("deepseek-v4-flash") { return "deepseek/deepseek-v4-flash" }
        if lower.contains("deepseek-v4-pro")   { return "deepseek/deepseek-v4-pro" }
        if lower.contains("deepseek")     { return "deepseek/deepseek-v4-flash" }
        if lower.contains("mimo-v2.5-pro") { return "mimo/mimo-v2.5-pro" }
        if lower.contains("mimo")         { return "mimo/mimo-v2.5" }
        if lower.contains("o1")           { return "openai/o1" }

        return "_fallback"
    }

    /// Compute USD cost for a token breakdown, given the raw model string.
    public static func cost(model: String, tokens: TokenBreakdown) -> Double {
        let key = normalize(model: model)
        let p = priceTable[key] ?? fallback

        let c = (Double(tokens.input)      * p.input
               + Double(tokens.output + tokens.reasoning) * p.output
               + Double(tokens.cacheRead)  * p.cacheRead
               + Double(tokens.cacheWrite) * p.cacheWrite) / 1_000_000
        return c
    }

    /// Provider inferred from canonical key.
    public static func provider(forCanonicalKey key: String) -> Provider {
        if key.hasPrefix("openai/") { return .codex }
        // deepseek/mimo/sensenova/glm etc. seen via Claude Code's remote provider routing
        // — treat as claude for aggregation purposes (they appear in Claude logs)
        return .claude
    }

    /// Input price (per 1M) for a canonical key — used for cache savings calculation.
    public static func inputPrice(forCanonicalKey key: String) -> Double {
        (priceTable[key] ?? fallback).input
    }

    /// Cache read price (per 1M) for a canonical key.
    public static func cacheReadPrice(forCanonicalKey key: String) -> Double {
        (priceTable[key] ?? fallback).cacheRead
    }
}
