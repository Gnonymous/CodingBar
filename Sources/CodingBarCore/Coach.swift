import Foundation

enum Coach {

    // Canonical keys for Opus and Haiku pricing families
    private static let opusKeys: Set<String> = [
        "anthropic/claude-opus-4-8",
        "anthropic/claude-opus-4-7",
        "anthropic/claude-opus-4-6",
    ]
    private static let haikuKeys: Set<String> = [
        "anthropic/claude-haiku-4-5",
    ]

    // A "simple" turn has zero or one tool call and fewer than 300 output tokens.
    private static func isSimpleTurn(_ record: RawRecord) -> Bool {
        record.toolNames.count <= 1 && record.tokens.output < 300
    }

    static func opusOnSimpleTip(from todayRecords: [RawRecord]) -> Insight? {
        let claudeToday = todayRecords.filter { $0.provider == .claude }

        // Cost delta: only count the non-cached input (cache tokens are already cheap
        // regardless of model — switching models won't help much there).
        var totalSimpleNetInput = 0   // non-cached input tokens only
        var totalSimpleCacheRead = 0  // cache-read tokens (priced differently)
        var totalSimpleOutput = 0
        var count = 0

        for r in claudeToday {
            let key = Pricing.normalize(model: r.model)
            guard opusKeys.contains(key) else { continue }
            guard isSimpleTurn(r) else { continue }
            totalSimpleNetInput += r.tokens.input
            totalSimpleCacheRead += r.tokens.cacheRead
            totalSimpleOutput += r.tokens.output
            count += 1
        }

        guard count >= 3 else { return nil }  // not enough to matter

        let opusKey = "anthropic/claude-opus-4-8"
        let haikuKey = "anthropic/claude-haiku-4-5"
        let opusInputPrice  = Pricing.inputPrice(forCanonicalKey: opusKey)
        let haikuInputPrice = Pricing.inputPrice(forCanonicalKey: haikuKey)
        // Cache read price delta is small; include it for completeness
        let opusCacheReadPrice  = Pricing.cacheReadPrice(forCanonicalKey: opusKey)
        let haikuCacheReadPrice = Pricing.cacheReadPrice(forCanonicalKey: haikuKey)
        let opusOutputPricePerM  = 75.0   // USD/1M
        let haikuOutputPricePerM =  5.0   // USD/1M

        let savedInput     = Double(totalSimpleNetInput)  * (opusInputPrice  - haikuInputPrice)  / 1_000_000
        let savedCacheRead = Double(totalSimpleCacheRead) * (opusCacheReadPrice - haikuCacheReadPrice) / 1_000_000
        let savedOutput    = Double(totalSimpleOutput)    * (opusOutputPricePerM - haikuOutputPricePerM) / 1_000_000
        let totalSaved = savedInput + savedCacheRead + savedOutput

        guard totalSaved >= 0.2 else { return nil }

        let text = "\(count) 个简单任务用了 Opus。换 Haiku 同样能完成，今天可省 ~$\(String(format: "%.2f", totalSaved))。"
        return Insight(kind: .tip, text: text, savingUSD: totalSaved)
    }

    static func cacheWasteTip(from todayRecords: [RawRecord]) -> Insight? {
        let claudeToday = todayRecords.filter { $0.provider == .claude }

        var totalWrite = 0
        var totalRead = 0
        var totalWriteCost = 0.0
        var totalReadSavings = 0.0

        for r in claudeToday {
            totalWrite += r.tokens.cacheWrite
            totalRead += r.tokens.cacheRead
            let key = Pricing.normalize(model: r.model)
            let writePrice = Pricing.inputPrice(forCanonicalKey: key)    // creation ≈ input price
            let readPrice = Pricing.cacheReadPrice(forCanonicalKey: key)
            totalWriteCost += Double(r.tokens.cacheWrite) * writePrice / 1_000_000
            totalReadSavings += Double(r.tokens.cacheRead) * (writePrice - readPrice) / 1_000_000
        }

        // Flag: wrote lots of cache but read very little (< 20% of writes re-used)
        guard totalWrite > 10_000 else { return nil }
        let reuseRatio = totalRead > 0 ? Double(totalRead) / Double(totalWrite) : 0
        guard reuseRatio < 0.2 else { return nil }
        // Only flag if cache write cost is material
        guard totalWriteCost >= 0.1 else { return nil }

        let text = String(format: "今日缓存复用率仅 %.0f%%（写入 %dK token，命中 %dK）。考虑保持上下文跨 session 连续。",
                          reuseRatio * 100,
                          totalWrite / 1000,
                          totalRead / 1000)
        return Insight(kind: .tip, text: text)
    }

    static func build(from todayRecords: [RawRecord]) -> [Insight] {
        var tips: [Insight] = []

        if let t1 = opusOnSimpleTip(from: todayRecords) {
            tips.append(t1)
        }
        if let t2 = cacheWasteTip(from: todayRecords) {
            tips.append(t2)
        }

        return Array(tips.prefix(3))
    }
}
