import Foundation
import CoreGraphics

/// How an agent uses its repo (Agent Workflow spec, Step 3). `.auto` = smart
/// suggestion (separate unless another agent already uses the repo → worktree).
enum RepoLaunchMode: String, CaseIterable, Identifiable, Equatable {
    case auto
    case separate
    case worktree

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto:     return "Auto"
        case .separate: return "Separate"
        case .worktree: return "Worktree"
        }
    }
}

/// Quick task presets (Agent Workflow spec). Prefill prompt text only — never a
/// planner agent.
enum TaskTemplate: String, CaseIterable, Identifiable {
    case implement, review, refactor, debug, explain, architecture
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var prompt: String {
        switch self {
        case .implement:    return "Implement: "
        case .review:       return "Review the recent changes for bugs and risks: "
        case .refactor:     return "Refactor for clarity without changing behavior: "
        case .debug:        return "Debug this issue: "
        case .explain:      return "Explain how this works: "
        case .architecture: return "Propose an architecture for: "
        }
    }
}

/// Which agent a panel hosts. V1 is locked to Claude Code + Codex; `.shell`
/// exists only as a neutral placeholder for Phase 1 (real PTYs arrive in Phase 2).
enum AgentKind: String, Codable, CaseIterable {
    case claude
    case codex
    case shell

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .shell:  return "Shell"
        }
    }
}

/// Minimal visible status language from the UI/UX constitution.
enum SessionStatus: String, Codable, CaseIterable {
    case idle
    case working
    case waiting
    case error
    case done

    var label: String {
        switch self {
        case .idle:    return "Idle"
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .error:   return "Error"
        case .done:    return "Done"
        }
    }
}

/// A movable/resizable card on the canvas.
///
/// In Phase 1 this is a styled placeholder; the live PTY terminal is added in
/// Phase 2. Position/size are stored in *world* (canvas) coordinates so the
/// camera can pan/zoom independently.
struct PanelModel: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var kind: AgentKind = .shell
    /// Short, unique, addressable node name shown in front of the detail (e.g.
    /// "Bluesky"). Used to target this node from the command bar ("tell Bluesky …",
    /// "close bluesky"). Auto-assigned on creation; renameable.
    var name: String = ""
    var project: String = "Untitled"
    var task: String = ""
    var status: SessionStatus = .idle

    /// Optional working directory for the PTY. Nil → user home. For agents this
    /// is the repo root (separate mode) or the worktree path (same-repo mode).
    var workingDirectory: String? = nil

    /// Main repo top-level (used to detect when agents share a repo). Nil = not git.
    var repoRoot: String? = nil

    /// Same-repo mode metadata. When `worktreePath` is set, the agent runs in an
    /// isolated git worktree on `branch`, so it never shares a working dir.
    var branch: String? = nil
    var worktreePath: String? = nil

    /// Stacking order on the free canvas — higher draws on top. Bumped to the
    /// front when a card is focused/dragged so overlapping cards behave naturally.
    var zIndex: Int = 0

    /// When set, this panel is a **browser** node (an embedded web view at this URL)
    /// rather than a terminal/agent. Optional → backward-compatible decode.
    var browserURL: String? = nil

    var isWorktree: Bool { worktreePath != nil }
    var isBrowser: Bool { browserURL != nil }

    // World-space frame.
    var x: CGFloat = 0
    var y: CGFloat = 0
    var width: CGFloat = 680
    var height: CGFloat = 460

    var position: CGPoint {
        get { CGPoint(x: x, y: y) }
        set { x = newValue.x; y = newValue.y }
    }

    var size: CGSize {
        get { CGSize(width: width, height: height) }
        set { width = newValue.width; height = newValue.height }
    }

    var worldFrame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// The detail line (no name), e.g. `Claude • Pavo • auth-refactor`. In same-repo
    /// mode the branch (sans `agent/`) takes the third slot. Browser nodes show their
    /// site instead of the agent detail.
    var headerDetail: String {
        if isBrowser { return project }
        var parts = [kind.displayName, project]
        if let branch, !branch.isEmpty {
            parts.append(branch.replacingOccurrences(of: "agent/", with: ""))
        } else if !task.isEmpty {
            parts.append(task)
        }
        return parts.joined(separator: "  •  ")
    }

    /// Full one-line title: the name in front, then the detail — e.g.
    /// `Bluesky · Claude • project • task`.
    var headerTitle: String {
        name.isEmpty ? headerDetail : "\(name)  ·  \(headerDetail)"
    }
}

extension PanelModel {
    private enum CodingKeys: String, CodingKey {
        case id, kind, name, project, task, status
        case workingDirectory, repoRoot, branch, worktreePath, zIndex, browserURL
        case x, y, width, height
    }

    /// Tolerant decoder: every field falls back to its default when absent. The
    /// synthesized `Decodable` uses `decode` (not `decodeIfPresent`) and ignores
    /// property defaults, so adding a new non-optional field like `zIndex` would
    /// otherwise throw `keyNotFound` on any pre-existing `workspace.json` and wipe
    /// the whole saved workspace. Decoding key-by-key keeps old saves loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        kind = try c.decodeIfPresent(AgentKind.self, forKey: .kind) ?? kind
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? name
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? project
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? task
        status = try c.decodeIfPresent(SessionStatus.self, forKey: .status) ?? status
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        repoRoot = try c.decodeIfPresent(String.self, forKey: .repoRoot)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        zIndex = try c.decodeIfPresent(Int.self, forKey: .zIndex) ?? zIndex
        browserURL = try c.decodeIfPresent(String.self, forKey: .browserURL)
        x = try c.decodeIfPresent(CGFloat.self, forKey: .x) ?? x
        y = try c.decodeIfPresent(CGFloat.self, forKey: .y) ?? y
        width = try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? width
        height = try c.decodeIfPresent(CGFloat.self, forKey: .height) ?? height
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(project, forKey: .project)
        try c.encode(task, forKey: .task)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try c.encodeIfPresent(repoRoot, forKey: .repoRoot)
        try c.encodeIfPresent(branch, forKey: .branch)
        try c.encodeIfPresent(worktreePath, forKey: .worktreePath)
        try c.encode(zIndex, forKey: .zIndex)
        try c.encodeIfPresent(browserURL, forKey: .browserURL)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
    }
}

/// In-progress configuration for the New Agent flow (not persisted).
struct NewAgentDraft: Equatable {
    var kind: AgentKind = .claude
    var repo: URL?
    var mode: RepoLaunchMode = .separate
    var task: String = ""
    var injectContext: Bool = true
    var autoRun: Bool = true
}

/// A saved canvas environment: panels plus camera state.
struct Workspace: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = "Workspace"
    var panels: [PanelModel] = []

    // Persisted camera so the view restores exactly.
    var cameraPanX: CGFloat = 0
    var cameraPanY: CGFloat = 0
    var cameraZoom: CGFloat = 1.0

    /// Repo this canvas launches agents in by default — remembered across relaunches
    /// and per-canvas (so multiple canvases each keep their own). Optional, so older
    /// saved files decode fine (a missing key → nil). Stored as a path string to
    /// avoid URL's Codable quirks.
    var defaultRepoPath: String? = nil

    /// The agent kind last launched on this canvas — keyword-less command-bar input
    /// (e.g. just "fix the bug") routes here. Optional → backward-compatible decode.
    var lastAgentID: String? = nil

    var updatedAt: Date = Date()
}

/// On-disk container for multiple canvases. The previous format was a single bare
/// `Workspace`; `WorkspaceStore.loadAll` falls back to decoding that and wrapping it,
/// so old saves migrate transparently.
struct WorkspaceFile: Codable, Equatable {
    var workspaces: [Workspace] = []
    var currentWorkspaceID: UUID = UUID()
}
