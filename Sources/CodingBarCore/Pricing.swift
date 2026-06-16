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
        "anthropic/claude-opus-4-8":   ModelPrice(input: 15,   output: 75, cacheRead: 1.5,   cacheWrite: 18.75),
        "anthropic/claude-sonnet-4-6": ModelPrice(input: 3,    output: 15, cacheRead: 0.3,   cacheWrite: 3.75),
        "anthropic/claude-haiku-4-5":  ModelPrice(input: 1,    output: 5,  cacheRead: 0.1,   cacheWrite: 1.25),
        "openai/gpt-5.5":              ModelPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0),
        "openai/o1":                   ModelPrice(input: 15,   output: 60, cacheRead: 7.5,   cacheWrite: 0),
    ]

    /// alias → canonical model key
    private static let aliasMap: [String: String] = {
        var m: [String: String] = [:]
        // claude models
        for alias in ["opus-4.8", "claude-opus-4-8", "opus"] { m[alias] = "anthropic/claude-opus-4-8" }
        for alias in ["sonnet-4.6", "claude-sonnet-4-6", "sonnet"] { m[alias] = "anthropic/claude-sonnet-4-6" }
        for alias in ["haiku-4.5", "claude-haiku-4-5", "haiku"] { m[alias] = "anthropic/claude-haiku-4-5" }
        // openai models
        for alias in ["gpt-5.5", "gpt5.5"] { m[alias] = "openai/gpt-5.5" }
        m["o1"] = "openai/o1"
        return m
    }()

    // MARK: - Public API

    /// Returns the canonical pricing key for a raw model string (e.g. "claude-opus-4-8" → "anthropic/claude-opus-4-8").
    public static func normalize(model: String) -> String {
        let lower = model.lowercased()

        // Direct canonical key match
        if priceTable[lower] != nil { return lower }

        // Alias lookup (try exact lowercase)
        if let canonical = aliasMap[lower] { return canonical }

        // Partial alias: scan alias map for prefix/suffix match
        for (alias, canonical) in aliasMap {
            if lower.contains(alias) { return canonical }
        }

        // Family keyword fallback
        if lower.contains("opus")    { return "anthropic/claude-opus-4-8" }
        if lower.contains("sonnet")  { return "anthropic/claude-sonnet-4-6" }
        if lower.contains("haiku")   { return "anthropic/claude-haiku-4-5" }
        if lower.contains("gpt-5.5") || lower.contains("gpt5.5") { return "openai/gpt-5.5" }
        if lower.contains("o1")      { return "openai/o1" }

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
