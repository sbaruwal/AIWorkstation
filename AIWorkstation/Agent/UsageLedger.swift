import Foundation

/// Approximate, LOCAL-ONLY token usage read from the agent CLIs' own on-disk transcripts,
/// plus a user-configurable $/Mtok ESTIMATE. The dollar figure is NEVER fetched and never
/// authoritative — the CLIs don't emit prices, so it's purely the user's own rate applied
/// to local token counts. Nothing leaves the machine; this only reads files the CLIs wrote.
///
/// Claude Code writes one dir per working directory under
/// `~/.claude/projects/<sanitized-cwd>/<session>.jsonl`, with a `message.usage` block on
/// each assistant turn (verified against real transcripts).
enum UsageLedger {
    struct Usage: Equatable {
        var inputTokens = 0       // fresh input + cache creation (billed ~full input rate)
        var cacheReadTokens = 0   // cached reads (billed at a fraction of input)
        var outputTokens = 0
        var turns = 0
        var totalTokens: Int { inputTokens + cacheReadTokens + outputTokens }
        var isEmpty: Bool { turns == 0 }
    }

    private static var claudeRoot: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
    }

    /// Claude encodes a project dir as the absolute path with every non-`[A-Za-z0-9]` char
    /// replaced by '-' (ASCII-only — Swift's Unicode `isLetter` would diverge for non-ASCII
    /// paths). Verified: /Users/x/aiws-demo → -Users-x-aiws-demo.
    private static func claudeProjectDir(for cwd: String) -> String {
        let encoded = String(cwd.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
        return (claudeRoot as NSString).appendingPathComponent(encoded)
    }

    /// Sum token usage for a Claude agent running in `cwd` (all its sessions in that dir).
    /// Blocking file IO — call from a detached task. nil when there's no transcript dir
    /// (a Codex agent, or a cwd Claude never ran in).
    static func claudeUsage(cwd: String) -> Usage? {
        let dir = claudeProjectDir(for: cwd)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        var u = Usage()
        for f in files where f.hasSuffix(".jsonl") {
            let path = (dir as NSString).appendingPathComponent(f)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { continue }
                func tok(_ k: String) -> Int { (usage[k] as? Int) ?? 0 }
                u.inputTokens += tok("input_tokens") + tok("cache_creation_input_tokens")
                u.cacheReadTokens += tok("cache_read_input_tokens")
                u.outputTokens += tok("output_tokens")
                u.turns += 1
            }
        }
        return u.isEmpty ? nil : u
    }

    static func usage(for kind: AgentKind, cwd: String) -> Usage? {
        kind == .claude ? claudeUsage(cwd: cwd) : nil   // Codex transcript mapping TBD
    }

    // MARK: Cost estimate — user-owned $/Mtok rates (default 0 → tokens only, no $ shown).

    static var inputRate: Double {
        get { UserDefaults.standard.double(forKey: "usage.rate.input") }
        set { UserDefaults.standard.set(newValue, forKey: "usage.rate.input") }
    }
    static var outputRate: Double {
        get { UserDefaults.standard.double(forKey: "usage.rate.output") }
        set { UserDefaults.standard.set(newValue, forKey: "usage.rate.output") }
    }

    /// nil until the user sets a rate — so we never imply a price we don't know. Cached
    /// reads are billed at ~10% of the input rate (they aren't full-price input tokens),
    /// so folding them into the headline estimate at full rate would overstate cost ~8x.
    static func estimatedCost(_ u: Usage) -> Double? {
        guard inputRate > 0 || outputRate > 0 else { return nil }
        return (Double(u.inputTokens) * inputRate
                + Double(u.cacheReadTokens) * inputRate * 0.1
                + Double(u.outputTokens) * outputRate) / 1_000_000
    }

    static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }
}
