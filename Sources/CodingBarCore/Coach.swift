import Foundation

enum Coach {

    // A "simple" turn has zero or one tool call and fewer than 300 output tokens.
    private static func isSimpleTurn(_ record: RawRecord) -> Bool {
        record.toolNames.count <= 1 && record.tokens.output < 300
    }

    static func opusOnSimpleTip(from todayRecords: [RawRecord], language: AppLanguage) -> Insight? {
        let claudeToday = todayRecords.filter { $0.provider == .claude }

        // Compare each turn at its actual Opus rate; cache writes are excluded
        // because switching models would recreate the cache rather than reuse it.
        var totalSaved = 0.0
        var count = 0

        for r in claudeToday {
            let key = Pricing.normalize(model: r.model)
            guard key.hasPrefix("anthropic/claude-opus-"), Pricing.priceIsExact(model: r.model) else { continue }
            guard isSimpleTurn(r) else { continue }
            let compared = TokenBreakdown(input: r.tokens.input, output: r.tokens.output,
                                          cacheRead: r.tokens.cacheRead)
            totalSaved += Pricing.cost(model: r.model, tokens: compared, at: r.timestamp)
                - Pricing.cost(model: "claude-haiku-4-5", tokens: compared, at: r.timestamp)
            count += 1
        }

        guard count >= 3 else { return nil }  // not enough to matter

        guard totalSaved >= 0.2 else { return nil }

        let saved = String(format: "%.2f", totalSaved)
        let text = language.t(
            "\(count) simple tasks ran on Opus. Haiku could handle them — save ~$\(saved) today.",
            "\(count) 个简单任务用了 Opus。换 Haiku 同样能完成，今天可省 ~$\(saved)。")
        return Insight(kind: .tip, text: text, savingUSD: totalSaved)
    }

    static func cacheWasteTip(from todayRecords: [RawRecord], language: AppLanguage) -> Insight? {
        let claudeToday = todayRecords.filter { $0.provider == .claude }

        var totalWrite = 0
        var totalRead = 0
        var totalWriteCost = 0.0
        var totalReadSavings = 0.0

        for r in claudeToday {
            totalWrite += r.tokens.cacheWrite
            totalRead += r.tokens.cacheRead
            let key = Pricing.normalize(model: r.model)
            let promptTokens = r.billingInputTokens ?? (r.tokens.input + r.tokens.cacheRead + r.tokens.cacheWrite)
            let writePrice = Pricing.inputPrice(forCanonicalKey: key, at: r.timestamp,
                                                billingInputTokens: promptTokens)
            let readPrice = Pricing.cacheReadPrice(forCanonicalKey: key, at: r.timestamp,
                                                   billingInputTokens: promptTokens)
            totalWriteCost += Pricing.cost(model: r.model,
                                            tokens: TokenBreakdown(cacheWrite: r.tokens.cacheWrite),
                                            at: r.timestamp,
                                            cacheWrite1h: r.cacheWrite1h,
                                            billingInputTokens: promptTokens)
            totalReadSavings += Double(r.tokens.cacheRead) * (writePrice - readPrice) / 1_000_000
        }

        // Flag: wrote lots of cache but read very little (< 20% of writes re-used)
        guard totalWrite > 10_000 else { return nil }
        let reuseRatio = totalRead > 0 ? Double(totalRead) / Double(totalWrite) : 0
        guard reuseRatio < 0.2 else { return nil }
        // Only flag if cache write cost is material
        guard totalWriteCost >= 0.1 else { return nil }

        let pct = Int((reuseRatio * 100).rounded()), wK = totalWrite / 1000, rK = totalRead / 1000
        let text = language.t(
            "Only \(pct)% cache reuse today (\(wK)K written, \(rK)K reused). Try keeping context across sessions.",
            "今日缓存复用率仅 \(pct)%（写入 \(wK)K token，命中 \(rK)K）。考虑保持上下文跨 session 连续。")
        return Insight(kind: .tip, text: text)
    }

    static func build(from todayRecords: [RawRecord], language: AppLanguage) -> [Insight] {
        var tips: [Insight] = []

        if let t1 = opusOnSimpleTip(from: todayRecords, language: language) {
            tips.append(t1)
        }
        if let t2 = cacheWasteTip(from: todayRecords, language: language) {
            tips.append(t2)
        }

        return Array(tips.prefix(3))
    }
}
