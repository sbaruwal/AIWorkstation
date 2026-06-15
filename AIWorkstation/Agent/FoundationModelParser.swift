import Foundation
import FoundationModels

/// On-device command parsing via Apple's Foundation Models (the ~3B Apple
/// Intelligence model). Used only for command-bar input the deterministic parser
/// couldn't classify — short, structured classification, squarely in this model's
/// wheelhouse. Guided generation guarantees a schema-valid result.
///
/// Entirely gated on macOS 26+ and runtime availability (Apple Intelligence enabled
/// on an eligible Apple-silicon Mac); returns nil otherwise so the caller falls back
/// to the deterministic / last-agent path. The app works fully without it.
enum FoundationModelParser {
    /// Whether the on-device model is usable right now.
    static var isAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return SystemLanguageModel.default.isAvailable
    }

    static func parse(_ text: String, nodeNames: [String], lastAgent: AgentKind) async -> ParsedCommand? {
        guard #available(macOS 26.0, *) else { return nil }
        return await FMParser.run(text, nodeNames: nodeNames, lastAgent: lastAgent)
    }
}

@available(macOS 26.0, *)
private enum FMParser {
    static func run(_ text: String, nodeNames: [String], lastAgent: AgentKind) async -> ParsedCommand? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        do {
            let session = LanguageModelSession(instructions: instructions(nodeNames: nodeNames))
            let intent = try await session.respond(to: text, generating: FMIntent.self).content
            return intent.toParsed(nodeNames: nodeNames, lastAgent: lastAgent)
        } catch {
            return nil
        }
    }

    static func instructions(nodeNames: [String]) -> String {
        let names = nodeNames.isEmpty ? "(none yet)" : nodeNames.joined(separator: ", ")
        return """
        You classify ONE command-bar line for a developer tool that runs coding agents and browser windows on a canvas. Existing node names on the canvas: \(names).
        Decide the action:
        • "create_agent" — start a NEW coding agent in a terminal (e.g. "have claude review the tests"). Set agent (or "auto" if unnamed) and put the work in message, verbatim, without the agent name.
        • "create_browser" — open a NEW browser window (e.g. "open the github repo"). Put the site/URL in target.
        • "control" — act on an EXISTING node named above. Set target to that node's name and verb to one of: followup (send a message into it → message), navigate (point a browser at a URL → message), close, stop, restart.
        Prefer "control" only when the line clearly references one of the existing node names.
        """
    }
}

@available(macOS 26.0, *)
@Generable
private struct FMIntent {
    @Guide(description: "create_agent, create_browser, or control", .anyOf(["create_agent", "create_browser", "control"]))
    var action: String

    // NOTE: `.anyOf` is constrained decoding and needs a literal, so keep this in sync
    // with AgentCatalog.allKeywords (+ "auto") by hand. Currently equivalent.
    @Guide(description: "which agent for create_agent, else auto", .anyOf(["claude", "cc", "codex", "auto"]))
    var agent: String

    @Guide(description: "for control: which existing node name; for create_browser: the site/URL")
    var target: String

    @Guide(description: "for control: followup, navigate, close, stop, or restart", .anyOf(["followup", "navigate", "close", "stop", "restart", "none"]))
    var verb: String

    @Guide(description: "the task (create_agent) or the message/URL for a control followup/navigate, verbatim")
    var message: String

    func toParsed(nodeNames: [String], lastAgent: AgentKind) -> ParsedCommand? {
        switch action {
        case "create_browser":
            let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            return .browser(url: BrowserURL.resolve(t, unresolved: BrowserURL.repo))

        case "control":
            // Match the model's target to a real node name (case-insensitive / prefix).
            let q = target.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            // Exact match for any length; prefix only for ≥3 chars (parity with the
            // deterministic parser) so a garbled 1–2 char model target can't silently
            // resolve to whichever node sorts first — important for destructive `close`.
            guard !q.isEmpty,
                  let name = nodeNames.first(where: { $0.lowercased() == q })
                    ?? (q.count >= 3 ? nodeNames.first(where: { $0.lowercased().hasPrefix(q) }) : nil)
            else { return nil }
            let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
            switch verb {
            case "close":    return .control(name: name, action: .close)
            case "stop":     return .control(name: name, action: .stop)
            case "restart":  return .control(name: name, action: .restart)
            case "navigate": return .control(name: name, action: .navigate(BrowserURL.resolve(msg)))
            default:         return msg.isEmpty ? nil : .control(name: name, action: .followUp(msg))
            }

        default: // create_agent
            let kind = AgentCatalog.match(agent) ?? lastAgent
            return .agent(kind: kind, task: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
