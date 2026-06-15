import Foundation

/// What a command-bar line resolves to.
enum ParsedCommand: Equatable {
    case agent(kind: AgentKind, task: String)        // create an agent (task may be empty)
    case browser(url: URL)                           // create a browser node
    case control(name: String, action: ControlAction) // act on an existing node by name
}

/// An action on an existing node, addressed by its name.
enum ControlAction: Equatable {
    case followUp(String)   // send a message into an agent's terminal
    case navigate(URL)      // point a browser node at a URL
    case close              // remove the node
    case stop               // interrupt the agent (Ctrl-C)
    case restart            // restart the agent's session
    case focus              // just select / bring it to front (bare name)
    case enterFocus         // open Focus Mode on an agent ("focus <name>")
}

/// Lightweight view of a live node, so the parser can recognize node names and know
/// whether a target is a browser (navigate) or an agent (follow-up).
struct NodeRef: Equatable {
    let name: String
    let isBrowser: Bool
}

/// Catalog of agent types the parser can route to. Data-driven (rather than
/// hard-coding `claude`/`codex`) — the seam for adding local agents later.
struct AgentType {
    let kind: AgentKind
    let keywords: [String]   // lowercased; the leading word(s) that select this agent
}

enum AgentCatalog {
    static let agents: [AgentType] = [
        AgentType(kind: .claude, keywords: ["claude", "cc"]),
        AgentType(kind: .codex,  keywords: ["codex"]),
    ]
    static func match(_ word: String) -> AgentKind? {
        let w = word.lowercased()
        return agents.first { $0.keywords.contains(w) }?.kind
    }
    static var allKeywords: [String] { agents.flatMap(\.keywords) }
}

/// Pool of short, distinctive node names. Each node gets a unique one on
/// creation, shown in front of the existing detail (e.g. "Bluesky · Claude · project").
enum NodeNames {
    static let pool = [
        "Bluesky", "Aspen", "Cove", "Ember", "Fable", "Glade", "Harbor", "Iris",
        "Juno", "Koi", "Lumen", "Marlow", "Nova", "Onyx", "Pike", "Quill",
        "Reef", "Sage", "Tundra", "Vela", "Willow", "Zephyr", "Atlas", "Birch",
        "Cinder", "Dune", "Echo", "Frost", "Grove", "Haven", "Indigo", "Jade",
    ]

    /// First unused name, or a numbered fallback once the pool is exhausted.
    static func next(taken: Set<String>) -> String {
        let lower = Set(taken.map { $0.lowercased() })
        if let free = pool.first(where: { !lower.contains($0.lowercased()) }) { return free }
        var i = 2
        while lower.contains("node \(i)") { i += 1 }
        return "Node \(i)"
    }
}

/// Deterministic command-bar parser. Recognizes: control of an existing node (by
/// name), browser-open, and agent-create. Returns nil when the intent isn't obvious
/// (the caller may then ask the on-device model); `fallback` resolves to last agent.
enum CommandParser {

    /// - Parameter allowNameFirstCatchAll: when false, a bare leading node name
    ///   (`<name> …` / just `<name>`) is NOT treated as control. The main command bar
    ///   wants it (so `cove navigate to x.com` works); Focus Mode passes `false` so a
    ///   follow-up that merely starts with a node's name (or a prefix of one) goes to
    ///   the focused agent as prose instead of being hijacked into a lifecycle action.
    static func deterministic(_ raw: String, nodes: [NodeRef] = [],
                              allowNameFirstCatchAll: Bool = true) -> ParsedCommand? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()

        // 1) Control an existing node (only matches when a real node name is referenced).
        if let control = controlIntent(text, nodes: nodes, allowNameFirstCatchAll: allowNameFirstCatchAll) { return control }

        // 2) Open a browser.
        if let url = browserTarget(text, lower) { return .browser(url: url) }

        // 3) Create an agent: "claude …", "codex", "cc …" — optionally prefixed with a
        // launch verb people naturally type ("open codex", "new claude", "launch cc fix it").
        // Without this, "open codex" wouldn't match here, would fall through to the
        // on-device model, and could come back with an invented task. The agent keyword
        // must immediately follow the (optional) verb; everything after it is the task.
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if !tokens.isEmpty {
            let launchVerbs: Set<String> = ["open", "new", "launch", "start", "run", "create"]
            let kwIndex = (tokens.count >= 2 && launchVerbs.contains(tokens[0].lowercased())) ? 1 : 0
            if let kind = AgentCatalog.match(tokens[kwIndex].lowercased()) {
                let task = tokens.dropFirst(kwIndex + 1).joined(separator: " ")
                return .agent(kind: kind, task: task)
            }
        }
        return nil
    }

    static func fallback(_ raw: String, lastAgent: AgentKind) -> ParsedCommand {
        .agent(kind: lastAgent, task: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Control intents

    private static func controlIntent(_ text: String, nodes: [NodeRef],
                                      allowNameFirstCatchAll: Bool = true) -> ParsedCommand? {
        guard !nodes.isEmpty else { return nil }
        let words = text.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        let firstL = first.lowercased()

        // Resolve a name fragment to a node (exact, case-insensitive; else a ≥3-char prefix).
        func node(_ fragment: String) -> NodeRef? {
            let q = fragment.lowercased()
            return nodes.first { $0.name.lowercased() == q }
                ?? (q.count >= 3 ? nodes.first { $0.name.lowercased().hasPrefix(q) } : nil)
        }
        func message(to ref: NodeRef, _ msg: String) -> ParsedCommand {
            let m = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ref.isBrowser else { return .control(name: ref.name, action: .followUp(m)) }
            // For a browser target, strip leading nav verbs so "tell Rubble open github.com"
            // navigates to github.com rather than searching for "open github.com".
            var parts = m.split(separator: " ").map(String.init)
            while let f = parts.first?.lowercased(), ["open", "go", "goto", "to", "visit", "navigate"].contains(f) {
                parts.removeFirst()
            }
            let url = parts.isEmpty ? m : parts.joined(separator: " ")
            return .control(name: ref.name, action: .navigate(BrowserURL.resolve(url)))
        }

        // Lifecycle: "close/stop/restart/focus <name>" (routing interprets per node type:
        // stop → interrupt agent / stop browser loading; restart → restart agent / reload browser;
        // focus → open Focus Mode on an agent). Allows an optional "on" ("focus on Bluesky").
        if words.count >= 2, ["close", "kill", "stop", "restart", "reload", "focus"].contains(firstL) {
            var restWords = Array(words.dropFirst())
            if firstL == "focus", restWords.first?.lowercased() == "on" { restWords = Array(restWords.dropFirst()) }
            let rest = restWords.joined(separator: " ")
            if let ref = node(rest) {
                switch firstL {
                case "close", "kill":     return .control(name: ref.name, action: .close)
                case "stop":              return .control(name: ref.name, action: .stop)
                case "restart", "reload": return .control(name: ref.name, action: .restart)
                case "focus":             return .control(name: ref.name, action: .enterFocus)
                default: break
                }
            }
        }

        // "tell <name> <msg>" / "ask <name> [to] <msg>"
        if (firstL == "tell" || firstL == "ask"), words.count >= 3, let ref = node(words[1]) {
            var rest = Array(words.dropFirst(2))
            if firstL == "ask", rest.first?.lowercased() == "to" { rest = Array(rest.dropFirst()) }
            let msg = rest.joined(separator: " ")
            if !msg.isEmpty { return message(to: ref, msg) }
        }

        // "@<name> <msg>"
        if first.hasPrefix("@"), words.count >= 2, let ref = node(String(first.dropFirst())) {
            return message(to: ref, words.dropFirst().joined(separator: " "))
        }

        // "<name>: <msg>"
        if first.hasSuffix(":"), words.count >= 2, let ref = node(String(first.dropLast())) {
            return message(to: ref, words.dropFirst().joined(separator: " "))
        }

        // "in <name> open/go/navigate <url>" (browser only)
        if firstL == "in", words.count >= 4, let ref = node(words[1]), ref.isBrowser,
           ["open", "go", "goto", "navigate", "visit"].contains(words[2].lowercased()) {
            var rest = Array(words.dropFirst(3))
            if rest.first?.lowercased() == "to" { rest = Array(rest.dropFirst()) }
            return .control(name: ref.name, action: .navigate(BrowserURL.resolve(rest.joined(separator: " "))))
        }

        // Catch-all: leading word is a node name → control that node. Makes EVERY
        // "<name> …" line deterministic (so it never falls to the model and gets
        // misread as "open a new browser"). Handles "cove close" (lifecycle),
        // "cove navigate to x.com" / "cove x.com" (browser nav), "cove fix the bug"
        // (agent follow-up), and a bare "cove" (focus).
        //
        // Disabled for Focus Mode: there the dominant intent is "talk to THIS agent",
        // so a follow-up that happens to start with a node name (or a prefix of one)
        // must NOT be hijacked into a control action. Explicit forms above still work.
        if allowNameFirstCatchAll, let ref = node(first) {
            let rest = Array(words.dropFirst())
            if rest.isEmpty { return .control(name: ref.name, action: .focus) }
            // name-first lifecycle: "cove close / stop / restart / reload / focus"
            if rest.count == 1 {
                switch rest[0].lowercased() {
                case "close", "kill", "quit": return .control(name: ref.name, action: .close)
                case "stop":                  return .control(name: ref.name, action: .stop)
                case "restart", "reload":     return .control(name: ref.name, action: .restart)
                case "focus":                 return .control(name: ref.name, action: .enterFocus)
                default: break
                }
            }
            // otherwise: navigate (browser, with leading verbs stripped) or follow-up (agent)
            return message(to: ref, rest.joined(separator: " "))
        }
        return nil
    }

    // MARK: Browser create

    private static func browserTarget(_ text: String, _ lower: String) -> URL? {
        var target: String?
        if lower.hasPrefix("browser ") {
            target = String(text.dropFirst("browser ".count))
        } else if lower.hasPrefix("open browser ") {
            target = String(text.dropFirst("open browser ".count))
        } else if lower.hasPrefix("open "), lower.hasSuffix(" in browser") {
            target = String(text.dropFirst("open ".count).dropLast(" in browser".count))
        } else if lower.hasPrefix("open ") {
            let rest = String(text.dropFirst("open ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeURL(rest) { target = rest }
        }
        guard let t = target?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return BrowserURL.resolve(t)
    }

    private static func looksLikeURL(_ s: String) -> Bool {
        s.hasPrefix("http://") || s.hasPrefix("https://") || (s.contains(".") && !s.contains(" "))
    }
}

/// Turns a free-text browser target into a URL: known shortcuts → domains, bare
/// domains → https, everything else → a Google search.
enum BrowserURL {
    static let shortcuts: [String: String] = [
        "google": "www.google.com", "youtube": "www.youtube.com", "github": "github.com",
        "gmail": "mail.google.com", "twitter": "twitter.com", "x": "x.com",
        "reddit": "www.reddit.com", "stackoverflow": "stackoverflow.com",
        "apple": "www.apple.com", "chatgpt": "chatgpt.com",
        "claude": "claude.ai", "hackernews": "news.ycombinator.com", "hn": "news.ycombinator.com",
        "bluesky": "bsky.app",
    ]

    static func resolve(_ raw: String) -> URL {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if let host = shortcuts[lower] { return URL(string: "https://\(host)")! }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: s) ?? search(s)
        }
        if s.contains("."), !s.contains(" ") {
            return URL(string: "https://\(s)") ?? search(s)
        }
        return search(s)
    }

    private static func search(_ query: String) -> URL {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(q)")!
    }
}
