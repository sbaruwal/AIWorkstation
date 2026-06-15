import SwiftUI
import Combine
import AppKit

/// Owns the workspace, the camera, selection, and chrome visibility.
///
/// This is the single source of truth for the canvas. It deliberately knows
/// nothing about PTYs, agents, or git — those are separate modules
/// (architecture boundary).
@MainActor
final class CanvasState: ObservableObject {

    /// All canvases (multi-canvas). The single source of truth; `workspace` is a
    /// computed view onto the current one, so all existing `workspace.panels` code
    /// keeps working unchanged.
    @Published var workspaces: [Workspace] = []
    @Published var currentWorkspaceID: UUID = UUID()

    /// The active canvas. Reads/writes proxy into `workspaces[current]`.
    var workspace: Workspace {
        get { workspaces.first { $0.id == currentWorkspaceID } ?? workspaces.first ?? Workspace() }
        set {
            if let i = workspaces.firstIndex(where: { $0.id == currentWorkspaceID }) {
                workspaces[i] = newValue
            } else if !workspaces.isEmpty {
                // Stale current id, non-empty array: self-heal to canvas 0 (matches the
                // getter, which returns `workspaces.first` in this case).
                workspaces[0] = newValue
            }
            // Empty array: no-op. We must NOT fabricate a canvas with a fresh UUID here
            // (that would silently discard the real current id). `workspaces` is never
            // empty in normal operation — init and deleteWorkspace both guarantee ≥1.
        }
    }

    @Published var camera = Camera()
    @Published var selection: UUID?

    /// Latest canvas viewport size, kept current by the view so actions like
    /// clone can place new cards without threading the size through everywhere.
    /// Deliberately *not* `@Published`: it changes on every live resize and nothing
    /// renders from it, so publishing would churn the whole canvas for no reason.
    var lastViewport: CGSize = CGSize(width: 1280, height: 800)

    /// Panel currently being dragged (set by the card's move gesture). While set,
    /// auto-reflow is suppressed so the grid doesn't yank out from under the cursor.
    var draggingPanelID: UUID?

    // Chrome visibility. Pin states are UI preferences, persisted to
    // UserDefaults (not the workspace file) so they survive relaunch.
    @Published var sidebarPinned = false {
        didSet { defaults.set(sidebarPinned, forKey: Keys.sidebarPinned) }
    }
    @Published var sidebarHovering = false
    @Published var toolbarPinned = false {
        didSet { defaults.set(toolbarPinned, forKey: Keys.toolbarPinned) }
    }
    @Published var showMinimap = true

    /// Selected canvas backdrop, persisted as a UI preference. Changing it also
    /// re-tints every live terminal so the theme flows through them.
    @Published var canvasTheme: CanvasTheme = .minimal {
        didSet {
            defaults.set(canvasTheme.rawValue, forKey: Keys.canvasTheme)
            terminals.applyTheme(canvasTheme)
        }
    }

    /// The active theme's accent color. Chrome (command bar, selection, chips, empty
    /// state) reads this instead of the fixed `Theme.accent`, so the whole UI retints
    /// with the canvas theme — blue (Minimal), amber-teal (Futuristic), turquoise (Nature).
    var accent: Color { canvasTheme.accent }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let sidebarPinned = "chrome.sidebarPinned"
        static let toolbarPinned = "chrome.toolbarPinned"
        static let canvasTheme = "canvas.theme"
        static let autoResume = "behavior.autoResume"
        static let voiceEnabled = "behavior.voiceEnabled"
        static let injectContext = "behavior.injectContext"
        static let notificationsEnabled = "behavior.notificationsEnabled"
        static let appearance = "behavior.appearance"
        static let onboardingDone = "onboarding.done"
    }

    func completeOnboarding() {
        defaults.set(true, forKey: Keys.onboardingDone)
        showOnboarding = false
    }

    /// Greeting for the home/empty state. Uses the local account's full name.
    var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return name.isEmpty ? part : "\(part), \(name)"
    }

    /// Snap threshold in *world* units; bypassed while a modifier is held.
    let snapThreshold: CGFloat = 8

    /// Live terminal engine. Holds PTY-backed controllers per panel (in memory).
    let terminals = TerminalRegistry()

    /// Live browser nodes — holds one WKWebView controller per browser panel.
    let browsers = BrowserRegistry()

    /// In-app + macOS notifications for agent/worktree/CLI events.
    let notifier = AppNotifier()

    /// Agent kind last launched on this canvas — keyword-less command input routes here.
    var lastAgent: AgentKind {
        get { workspace.lastAgentID.flatMap(AgentKind.init(rawValue:)) ?? .claude }
        set { workspace.lastAgentID = newValue.rawValue }
    }

    private var autosave: AnyCancellable?
    private let store = WorkspaceStore.shared

    var sidebarVisible: Bool { sidebarPinned || sidebarHovering }

    /// Settings. Persisted to UserDefaults.
    @Published var autoResume: Bool = true {
        didSet { defaults.set(autoResume, forKey: Keys.autoResume) }
    }
    @Published var voiceEnabled: Bool = true {
        didSet { defaults.set(voiceEnabled, forKey: Keys.voiceEnabled) }
    }
    /// Default for the context-injection step (read constitution.md / memory.md
    /// first). Governs the quick-launch paths (command bar, clone); the New Agent
    /// sheet's per-launch checkbox is seeded from this and can override it.
    @Published var injectContext: Bool = true {
        didSet { defaults.set(injectContext, forKey: Keys.injectContext) }
    }
    /// In-app + macOS notifications for agent/worktree/CLI events (Settings → Behavior).
    @Published var notificationsEnabled: Bool = true {
        didSet {
            defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
            notifier.enabled = notificationsEnabled
        }
    }
    /// App appearance: follow the system, or force light/dark (Settings → Appearance).
    @Published var appearance: AppAppearance = .system {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    @Published var showOnboarding: Bool = false

    init() {
        // Resume the last canvases unless disabled (Settings → Behavior).
        let resume = defaults.object(forKey: Keys.autoResume) as? Bool ?? true
        if resume, let file = store.loadAll(), !file.workspaces.isEmpty {
            workspaces = file.workspaces
            // Honor the saved current canvas; fall back to the first if it's stale.
            currentWorkspaceID = file.workspaces.contains { $0.id == file.currentWorkspaceID }
                ? file.currentWorkspaceID : file.workspaces[0].id
            let loaded = workspace
            camera = Camera(
                pan: CGSize(width: loaded.cameraPanX, height: loaded.cameraPanY),
                zoom: loaded.cameraZoom
            )
            // Backfill names for panels saved before naming existed, so every restored
            // node is addressable from the command bar ("tell <name> …", "close <name>").
            for wi in workspaces.indices {
                for pi in workspaces[wi].panels.indices where workspaces[wi].panels[pi].name.isEmpty {
                    let taken = Set(workspaces[wi].panels.map(\.name).filter { !$0.isEmpty })
                    workspaces[wi].panels[pi].name = NodeNames.next(taken: taken)
                }
            }
            // Restored sessions (across all canvases) are recoverable, not auto-relaunched.
            terminals.restoredIds = Set(workspaces.flatMap { $0.panels.map(\.id) })
        } else {
            let ws = Workspace(name: "My Workspace")
            workspaces = [ws]
            currentWorkspaceID = ws.id
        }
        autoResume = resume
        voiceEnabled = defaults.object(forKey: Keys.voiceEnabled) as? Bool ?? true
        injectContext = defaults.object(forKey: Keys.injectContext) as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        if let raw = defaults.string(forKey: Keys.appearance), let a = AppAppearance(rawValue: raw) {
            appearance = a
        } else {
            appearance = .dark   // preserve the app's dark identity unless the user opts in
        }
        showOnboarding = !defaults.bool(forKey: Keys.onboardingDone)

        // Restore persisted chrome preferences (didSet won't fire during init).
        sidebarPinned = defaults.bool(forKey: Keys.sidebarPinned)
        toolbarPinned = defaults.bool(forKey: Keys.toolbarPinned)
        if let raw = defaults.string(forKey: Keys.canvasTheme), let theme = CanvasTheme(rawValue: raw) {
            canvasTheme = theme
        }
        terminals.applyTheme(canvasTheme)   // didSet doesn't fire during init
        notifier.enabled = notificationsEnabled

        // Wire each new terminal's lifecycle events to the notifier. Controllers are
        // created lazily (and shared across canvases), so this hooks every one as it
        // appears — exits/CLI-missing surface as toasts + macOS notifications.
        terminals.onControllerCreated = { [weak self] controller in
            // Capture value-typed id/kind, NOT the controller — capturing `controller`
            // in a closure stored on `controller.onExit` would be a retain cycle and
            // leak the PTY after the card is closed.
            let cid = controller.id
            let ckind = controller.kind
            controller.onExit = { [weak self] status, userInitiated in
                self?.handleAgentExit(id: cid, kind: ckind, status: status, userInitiated: userInitiated)
            }
            controller.onNeedsCLI = { [weak self] kind in
                guard let self else { return }
                self.notifier.post("\(kind.displayName) CLI not found",
                                   body: "Locate the binary in Settings to launch \(self.panelName(for: cid)).",
                                   kind: .error)
            }
            controller.onNeedsInput = { [weak self] question in
                self?.handleAgentNeedsInput(id: cid, question: question)
            }
        }

        // Debounced autosave: every change to any canvas / the current selection /
        // the camera is flushed to JSON.
        autosave = Publishers.CombineLatest3($workspaces, $currentWorkspaceID, $camera)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persist() }
    }

    // MARK: Persistence

    /// Flush the workspace to disk. `synchronously: true` is used on quit so the
    /// write completes before the process exits (the debounced autosave path leaves
    /// it false and writes off the main thread).
    func persist(synchronously: Bool = false) {
        // Build a local snapshot with the live camera baked into the *current* canvas.
        // Crucially we do NOT mutate `@Published workspaces` here — that would re-fire
        // the debounced autosave and loop. The snapshot is a value copy.
        var snapshot = workspaces
        if let i = snapshot.firstIndex(where: { $0.id == currentWorkspaceID }) {
            snapshot[i].cameraPanX = camera.pan.width
            snapshot[i].cameraPanY = camera.pan.height
            snapshot[i].cameraZoom = camera.zoom
            snapshot[i].updatedAt = Date()
        }
        let file = WorkspaceFile(workspaces: snapshot, currentWorkspaceID: currentWorkspaceID)
        if synchronously {
            store.saveAllSynchronously(file)
        } else {
            store.saveAll(file)
        }
    }

    /// Retry any sessions that were blocked on a missing CLI — call after the user
    /// locates or installs the binary (Settings / Onboarding).
    func retryMissingCLIs() {
        terminals.retryMissingCLIs()
    }

    /// This canvas's default repo (persisted on the Workspace, so it survives
    /// relaunch and is per-canvas). The command bar / New Agent flow pre-select it.
    var defaultRepo: URL? {
        get { workspace.defaultRepoPath.map { URL(fileURLWithPath: $0) } }
        set { workspace.defaultRepoPath = newValue?.path }
    }

    // MARK: Multi-canvas

    /// Bake the live camera into the current canvas so switching away and back
    /// restores its exact pan/zoom. Called before any canvas switch.
    private func stashCamera() {
        if let i = workspaces.firstIndex(where: { $0.id == currentWorkspaceID }) {
            workspaces[i].cameraPanX = camera.pan.width
            workspaces[i].cameraPanY = camera.pan.height
            workspaces[i].cameraZoom = camera.zoom
        }
    }

    /// Switch to another canvas: stash this one's camera, load that one's camera,
    /// reset transient view state, and re-fill the window with its cards.
    func switchTo(_ id: UUID) {
        guard id != currentWorkspaceID, workspaces.contains(where: { $0.id == id }) else { return }
        stashCamera()
        focusedPanel = nil
        selection = nil
        currentWorkspaceID = id
        let ws = workspace
        camera = Camera(pan: CGSize(width: ws.cameraPanX, height: ws.cameraPanY), zoom: ws.cameraZoom)
        relayout(viewportSize: lastViewport)
    }

    /// Create a fresh empty canvas and switch to it.
    @discardableResult
    func newWorkspace(named name: String? = nil) -> UUID {
        stashCamera()
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (n?.isEmpty == false) ? n! : "Canvas \(workspaces.count + 1)"
        var ws = Workspace(name: title)
        // A new canvas inherits the repo context so the command bar works immediately.
        ws.defaultRepoPath = workspace.defaultRepoPath
        ws.lastAgentID = workspace.lastAgentID
        workspaces.append(ws)
        focusedPanel = nil
        selection = nil
        currentWorkspaceID = ws.id
        camera = Camera(pan: .zero, zoom: 1)
        return ws.id
    }

    /// Rename a canvas (by id; defaults to the current one).
    func renameWorkspace(_ id: UUID? = nil, to newName: String) {
        let target = id ?? currentWorkspaceID
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = workspaces.firstIndex(where: { $0.id == target }) else { return }
        workspaces[i].name = trimmed
    }

    /// Move a node to another canvas WITHOUT tearing it down. The terminal/browser
    /// controller lives in an id-keyed registry shared across canvases, so the agent
    /// keeps running through the move — it just re-mounts when the target is shown.
    func movePanel(_ id: UUID, toCanvas target: UUID) {
        guard target != currentWorkspaceID,
              let src = workspaces.firstIndex(where: { $0.id == currentWorkspaceID }),
              let dst = workspaces.firstIndex(where: { $0.id == target }),
              let pi = workspaces[src].panels.firstIndex(where: { $0.id == id })
        else { return }

        var moved = workspaces[src].panels.remove(at: pi)
        // Drop it on top of the destination's stack so it isn't hidden when shown.
        moved.zIndex = (workspaces[dst].panels.map(\.zIndex).max() ?? 0) + 1
        workspaces[dst].panels.append(moved)

        if selection == id { selection = nil }
        if focusedPanel == id { focusedPanel = nil }
        // The source canvas lost a card → re-fill it. The destination re-tiles when
        // the user switches to it (switchTo calls relayout).
        relayout(viewportSize: lastViewport)
    }

    /// Delete a canvas. Tears down its terminals/browsers, removes it, and — if it
    /// was the active one — switches to a neighbor. Never leaves zero canvases.
    func deleteWorkspace(_ id: UUID) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }
        // Tear down live sessions belonging to that canvas so we don't leak PTYs/webviews.
        for panel in workspaces[idx].panels {
            terminals.remove(panel.id)
            browsers.remove(panel.id)
        }
        let wasCurrent = (id == currentWorkspaceID)
        workspaces.remove(at: idx)
        if workspaces.isEmpty {
            focusedPanel = nil          // the focused agent (if any) lived on the deleted canvas
            selection = nil
            let ws = Workspace(name: "My Workspace")
            workspaces = [ws]
            currentWorkspaceID = ws.id
            camera = Camera(pan: .zero, zoom: 1)
        } else if wasCurrent {
            // Switch to the nearest remaining canvas (prefer the one now at idx, else last).
            let next = workspaces[min(idx, workspaces.count - 1)]
            focusedPanel = nil
            selection = nil
            currentWorkspaceID = next.id
            camera = Camera(pan: CGSize(width: next.cameraPanX, height: next.cameraPanY), zoom: next.cameraZoom)
            relayout(viewportSize: lastViewport)
        }
    }

    // MARK: Panels

    var panels: [PanelModel] { workspace.panels }

    /// Next unique node name from the pool (avoids names already on the canvas).
    private func nextNodeName() -> String {
        NodeNames.next(taken: Set(workspace.panels.map(\.name).filter { !$0.isEmpty }))
    }

    func panel(_ id: UUID) -> PanelModel? { workspace.panels.first { $0.id == id } }

    func binding(for id: UUID) -> Binding<PanelModel>? {
        guard workspace.panels.contains(where: { $0.id == id }) else { return nil }
        // Resolve the index by id INSIDE the closure on every access. Capturing a
        // fixed index would dangle if panels are removed or the canvas is switched
        // while a view still holds this binding (multi-canvas widens that window) →
        // wrong-panel write or an out-of-range crash. The get falls back to the last
        // known value if the panel disappears mid-flight; the set becomes a no-op.
        return Binding(
            get: { self.workspace.panels.first { $0.id == id } ?? PanelModel(id: id) },
            set: { newValue in
                if let i = self.workspace.panels.firstIndex(where: { $0.id == id }) {
                    self.workspace.panels[i] = newValue
                }
            }
        )
    }

    /// Adds a panel, sized relative to the window and placed in the first free
    /// on-screen grid slot so it's fully visible.
    @discardableResult
    func addPanel(kind: AgentKind, project: String, task: String = "", viewportSize: CGSize) -> UUID {
        var panel = PanelModel(kind: kind, project: project, task: task, status: .idle)
        panel.name = nextNodeName()
        panel.size = initialPanelSize(viewportSize: viewportSize)
        panel.position = autoPlace(size: panel.size, viewportSize: viewportSize)
        panel.zIndex = topZIndex()
        workspace.panels.append(panel)
        selection = panel.id
        relayout(viewportSize: viewportSize)
        return panel.id
    }

    /// Launch a Claude/Codex agent in a chosen repo.
    ///
    /// Smart mode: the *first* agent on a repo runs in the
    /// repo itself; any *additional* agent on the same git repo is isolated in its
    /// own worktree + branch so two agents never write to the same directory.
    @discardableResult
    func addAgentPanel(kind: AgentKind, repoURL: URL, mode: RepoLaunchMode = .auto, viewportSize: CGSize) -> UUID {
        WorkspaceStore.shared.defaultRepoFolder = repoURL.deletingLastPathComponent()
        WorkspaceStore.shared.pushRecentRepo(repoURL)
        defaultRepo = repoURL   // remember this canvas's repo across relaunches

        let git = GitManager.shared
        let pickedPath = repoURL.path
        // Repo-root detection stays synchronous: it's a fast `rev-parse` and keeps
        // the "another agent already on this repo?" check deterministic and ordered,
        // so two quick launches on the same repo can't both pick "separate" and
        // collide. Only the slow worktree *checkout* is deferred off-main below.
        let root = git.repoRoot(pickedPath)

        let panelId = UUID()
        let repoHasAgent = root != nil && workspace.panels.contains { $0.repoRoot == root }
        let useWorktree: Bool
        switch mode {
        case .separate: useWorktree = false
        case .worktree: useWorktree = (root != nil)
        case .auto:     useWorktree = repoHasAgent
        }

        var panel = PanelModel()
        panel.id = panelId
        panel.kind = kind
        panel.name = nextNodeName()
        panel.project = repoURL.lastPathComponent
        panel.status = .idle
        panel.repoRoot = root
        panel.size = initialPanelSize(viewportSize: viewportSize)
        panel.position = autoPlace(size: panel.size, viewportSize: viewportSize)
        panel.zIndex = topZIndex()

        if useWorktree, let root {
            // Same-repo mode → isolate in a worktree. `git worktree add` does a full
            // checkout and can be slow on a large repo, so it runs OFF the main
            // thread: the card appears immediately in a `.preparing` state and the
            // PTY starts once the worktree exists (or falls back to the repo root).
            //
            // branch + path are recorded on the panel UP FRONT so any worktree that
            // actually lands on disk is always referenced by a panel — recoverable on
            // the next launch (via removePanel's cleanup) even if the app quits
            // mid-checkout, so we never orphan a worktree.
            let branch = git.makeBranchName(kind: kind, taskSlug: nil)
            let path = git.worktreePath(workspaceId: workspace.id, agentId: panelId)
            panel.workingDirectory = root        // provisional until prep finishes
            panel.branch = branch
            panel.worktreePath = path
            workspace.panels.append(panel)
            selection = panelId
            terminals.controller(for: panel).beginPreparing()
            startWorktreeCreation(panelId: panelId, repoRoot: root, branch: branch, path: path)
        } else {
            panel.workingDirectory = root ?? pickedPath
            workspace.panels.append(panel)
            selection = panelId
        }
        relayout(viewportSize: viewportSize)   // re-tile to fill the window as cards are added
        return panelId
    }

    /// Create the worktree off the main thread, then finalize the panel + start the
    /// PTY back on the main actor. Only the `git worktree add` checkout is dispatched
    /// off-main; branch + path are passed in (already recorded on the panel).
    ///
    /// Ordering is safe by construction: this fires an unstructured `Task` that
    /// inherits the main actor, so `finalizeWorktreeLaunch` cannot run until the
    /// synchronous launch code (which stages `initialPrompt` in `deliverLaunch`)
    /// has returned and the main actor is free.
    private func startWorktreeCreation(panelId: UUID, repoRoot: String, branch: String, path: String) {
        Task { [weak self] in
            let errorMessage = await Task.detached { () -> String? in
                do {
                    try GitManager.shared.createWorktree(repoRoot: repoRoot, branch: branch, at: path)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            self?.finalizeWorktreeLaunch(panelId: panelId, repoRoot: repoRoot, path: path, errorMessage: errorMessage)
        }
    }

    private func finalizeWorktreeLaunch(panelId: UUID, repoRoot: String, path: String, errorMessage: String?) {
        guard let idx = workspace.panels.firstIndex(where: { $0.id == panelId }) else {
            // The card was closed while the worktree was being created — don't leave
            // the freshly-created worktree orphaned on disk. (Closing mid-prep takes
            // removePanel's fast path, so this runs *after* the checkout — no race.)
            if errorMessage == nil {
                Task.detached { try? GitManager.shared.removeWorktree(repoRoot: repoRoot, at: path, force: true) }
            }
            return
        }
        let controller = terminals.existingController(for: panelId)
        if let errorMessage {
            // Checkout failed → no worktree exists; clear the provisional metadata so
            // nothing points at a missing dir, and run in the repo root (user warned).
            workspace.panels[idx].branch = nil
            workspace.panels[idx].worktreePath = nil
            workspace.panels[idx].workingDirectory = repoRoot
            presentGitErrorAlert(message: errorMessage)
            controller?.finishPreparing(workingDirectory: repoRoot)
        } else {
            // branch + worktreePath were recorded up front; just point the PTY at it.
            workspace.panels[idx].workingDirectory = path
            controller?.finishPreparing(workingDirectory: path)
            let name = workspace.panels[idx].name
            let branch = workspace.panels[idx].branch.map { $0.replacingOccurrences(of: "agent/", with: "") }
            notifier.post("Worktree ready",
                          body: "\(name.isEmpty ? "Agent" : name) is isolated on \(branch ?? "a new branch").",
                          kind: .success, system: false)
        }
    }

    // MARK: Notifications

    /// Display name of a panel by id, searched across ALL canvases (controllers are
    /// shared, so an event can originate from a background canvas).
    private func panelName(for id: UUID) -> String {
        for ws in workspaces {
            if let p = ws.panels.first(where: { $0.id == id }) {
                return p.name.isEmpty ? p.project : p.name
            }
        }
        return "Agent"
    }

    /// Surface an unsolicited process end as a notification. Self-inflicted exits
    /// (close / restart) and plain-shell clean exits are intentionally silent.
    private func handleAgentExit(id: UUID, kind: AgentKind, status: ExitStatus, userInitiated: Bool) {
        guard !userInitiated else { return }
        let name = panelName(for: id)
        if status.isClean {
            guard kind != .shell else { return }
            notifier.post("\(name) finished", body: "\(kind.displayName) session ended cleanly.", kind: .success)
        } else {
            notifier.post("\(name) exited", body: "\(kind.displayName) ended — \(status.label).", kind: .error)
        }
    }

    /// A running agent just started awaiting an answer (the classifier flipped it to
    /// blocked). Surface a typed toast + OS notification whose tap jumps to the agent —
    /// so a question 10 minutes deep doesn't sit silent while you're in another app.
    private func handleAgentNeedsInput(id: UUID, question: String?) {
        let name = panelName(for: id)
        let q = question?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (q?.isEmpty == false) ? q : "is waiting for your input."
        notifier.post("\(name) needs you", body: body, kind: .info,
                      onTap: { [weak self] in self?.revealAgent(id) })
    }

    // MARK: Session controls

    func renamePanel(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = workspace.panels.firstIndex(where: { $0.id == id }) else { return }
        // Names are the sole addressing key for command-bar control, so keep them
        // unique (case-insensitive) — a duplicate would make a node unaddressable and
        // could mis-target a destructive `close <name>`.
        let lower = trimmed.lowercased()
        guard lower != "all" else { return }   // reserved: "all" is the broadcast keyword
        guard !workspace.panels.contains(where: { $0.id != id && $0.name.lowercased() == lower }) else { return }
        workspace.panels[idx].name = trimmed   // the addressable node name
    }

    /// Can this panel be cloned? (Agent panels rooted in a git repo.)
    func canClone(_ id: UUID) -> Bool {
        guard let panel = panel(id) else { return false }
        return panel.kind != .shell && panel.repoRoot != nil
    }

    /// Clone an agent into the same repo with the same task. In a git repo this
    /// becomes an isolated worktree + branch since the repo is already busy.
    func clonePanel(_ id: UUID) {
        guard let src = panel(id), let root = src.repoRoot, src.kind != .shell else { return }
        deliverLaunch(kind: src.kind, repoURL: URL(fileURLWithPath: root), mode: .auto,
                      task: src.task, injectContext: injectContext, autoRun: !src.task.isEmpty,
                      viewportSize: lastViewport)
    }

    /// Folder a panel's session controls should target (worktree, repo, or home).
    func workingDir(for id: UUID) -> String {
        guard let panel = panel(id) else { return FileManager.default.homeDirectoryForCurrentUser.path }
        return panel.workingDirectory ?? panel.repoRoot ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Raise a card above all others (focus / drag). Keeps overlapping cards usable.
    func bringToFront(_ id: UUID) {
        guard let idx = workspace.panels.firstIndex(where: { $0.id == id }) else { return }
        let maxZ = workspace.panels.map(\.zIndex).max() ?? 0
        if workspace.panels[idx].zIndex != maxZ {
            workspace.panels[idx].zIndex = maxZ + 1
        }
    }

    private func topZIndex() -> Int { (workspace.panels.map(\.zIndex).max() ?? 0) + 1 }

    /// Recenter the camera on a world point (used by the minimap and jump actions).
    func centerCamera(on world: CGPoint, viewportSize: CGSize) {
        withCameraAnimation {
            self.camera.pan = CGSize(
                width: viewportSize.width / 2 - world.x * self.camera.zoom,
                height: viewportSize.height / 2 - world.y * self.camera.zoom
            )
        }
    }

    /// Launch an agent from the command bar (quick path: auto repo mode).
    @discardableResult
    func launchFromCommandBar(kind: AgentKind, repoURL: URL, task: String, autoRun: Bool, viewportSize: CGSize) -> UUID {
        deliverLaunch(kind: kind, repoURL: repoURL, mode: .auto, task: task,
                      injectContext: injectContext, autoRun: autoRun, viewportSize: viewportSize)
    }

    /// Parse a command-bar line and act on it: launch an agent or open a browser.
    /// Deterministic first (instant), then the on-device model for ambiguous input,
    /// then a safe fallback to the last-used agent.
    func runCommand(_ raw: String, repo: URL?, autoRun: Bool, viewportSize: CGSize) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastCommandUsedModel = false        // reflect only this command's parse method

        let nodes = workspace.panels
            .filter { !$0.name.isEmpty }
            .map { NodeRef(name: $0.name, isBrowser: $0.isBrowser) }

        let parsed: ParsedCommand
        if let deterministic = CommandParser.deterministic(text, nodes: nodes) {
            parsed = deterministic            // instant — no model, no spinner
        } else {
            isParsingCommand = true           // the on-device parse can take ~1s; show feedback
            let fromModel = await FoundationModelParser.parse(text, nodeNames: nodes.map(\.name), lastAgent: lastAgent)
            isParsingCommand = false
            if let fromModel {
                parsed = fromModel
                lastCommandUsedModel = true   // resolved by Apple's on-device model
            } else {
                parsed = CommandParser.fallback(text, lastAgent: lastAgent)
            }
        }

        switch parsed {
        case .browser(let url):
            openBrowser(url: url, viewportSize: viewportSize)
        case .agent(let kind, let task):
            lastAgent = kind
            guard let target = repo ?? defaultRepo ?? RepoPicker.pickDirectory() else { return }
            launchFromCommandBar(kind: kind, repoURL: target, task: task, autoRun: autoRun, viewportSize: viewportSize)
        case .control(let name, let action):
            applyControl(name: name, action: action)
        case .broadcast(let message):
            broadcastToAgents(message)
        }
    }

    /// Fan a user-typed follow-up to every RUNNING agent on the current canvas ("tell all
    /// run the tests"). Pure fan-out of the user's own message — never autonomous, and
    /// scoped to live agents so a broadcast can't silently wake dead/recoverable sessions.
    func broadcastToAgents(_ message: String) {
        let targets = workspace.panels.filter {
            !$0.isBrowser && terminals.existingController(for: $0.id)?.runState == .running
        }
        guard !targets.isEmpty else {
            notifier.post("No running agents", body: "Nothing to broadcast to.", kind: .info, system: false)
            return
        }
        for panel in targets { deliverToAgent(panel, message: message) }
        notifier.post("Sent to \(targets.count) agent\(targets.count == 1 ? "" : "s") on this canvas",
                      body: message, kind: .success, system: false)
    }

    /// Focus-mode composer. A plain message is a follow-up to the focused agent; a
    /// recognized command (open a browser, control another node, spawn an agent)
    /// routes exactly like the main command bar. Deterministic-only — focus stays
    /// instant, and plain prose never gets misread as a new-browser request.
    func sendFromFocus(_ raw: String, focusedId: UUID, viewportSize: CGSize) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Exclude the focused panel and disable the bare-name catch-all: in focus the
        // default is a follow-up to THIS agent, so prose that merely starts with a node
        // name (or a prefix of one) must not be hijacked into a control action. Only
        // explicit commands (claude/codex …, open … in browser, tell/ask/@/name:, or a
        // verb-first "close <name>") divert; everything else goes to the focused agent.
        let nodes = workspace.panels
            .filter { $0.id != focusedId && !$0.name.isEmpty }
            .map { NodeRef(name: $0.name, isBrowser: $0.isBrowser) }

        if let parsed = CommandParser.deterministic(text, nodes: nodes, allowNameFirstCatchAll: false) {
            switch parsed {
            case .browser(let url):
                openBrowser(url: url, viewportSize: viewportSize)
            case .agent(let kind, let task):
                lastAgent = kind
                guard let target = defaultRepo ?? RepoPicker.pickDirectory() else { return }
                launchFromCommandBar(kind: kind, repoURL: target, task: task, autoRun: true, viewportSize: viewportSize)
            case .control(let name, let action):
                applyControl(name: name, action: action)
            case .broadcast(let message):
                broadcastToAgents(message)
            }
        } else if let panel = panel(focusedId) {
            deliverToAgent(panel, message: text)   // plain prose → follow-up to this agent
        }
    }

    /// Apply a command-bar control action to the live node with this name.
    private func applyControl(name: String, action: ControlAction) {
        guard let panel = workspace.panels.first(where: { $0.name.lowercased() == name.lowercased() }) else { return }
        if action != .close { selection = panel.id; bringToFront(panel.id) }   // surface the target
        switch action {
        case .followUp(let msg):
            if panel.isBrowser { browsers.controller(for: panel).load(BrowserURL.resolve(msg)) }
            else { deliverToAgent(panel, message: msg) }
        case .navigate(let url):
            if panel.isBrowser { browsers.controller(for: panel).load(url) }
            else { deliverToAgent(panel, message: url.absoluteString) }   // agent (FM mis-route) → don't silently drop
        case .close:
            removePanel(panel.id)
        case .stop:
            if panel.isBrowser { browsers.controller(for: panel).stopLoading() }
            else {
                let c = terminals.controller(for: panel)
                if c.runState == .running { c.interrupt() }   // nothing to interrupt if not running
            }
        case .restart:
            if panel.isBrowser { browsers.controller(for: panel).reload() }
            else { terminals.controller(for: panel).restart() }
        case .focus:
            break   // selection + bringToFront already done above
        case .enterFocus:
            if !panel.isBrowser { enterFocus(panel.id) }   // browsers have no Focus Mode (just selected above)
        }
    }

    /// Deliver a follow-up message to an agent, accounting for its run state so the
    /// message is never typed into a dead PTY. A restored/exited/missing-CLI session
    /// is relaunched with the message staged as its first prompt; a still-preparing
    /// one stages it for `finishPreparing`; a running one receives it live.
    private func deliverToAgent(_ panel: PanelModel, message: String) {
        let c = terminals.controller(for: panel)
        switch c.runState {
        case .running:
            c.sendInput(message, submit: true)
        case .recoverable, .exited:
            c.initialPrompt = message; c.autoRunInitialPrompt = true; c.relaunch()
        case .needsCLI:
            c.initialPrompt = message; c.autoRunInitialPrompt = true; c.retryLaunch()
        case .preparing, .idle:
            // Not started yet (worktree checkout in flight, or just created): stage the
            // prompt so it's delivered when the PTY starts. `.preparing` ignores
            // startIfNeeded (finishPreparing delivers it); `.idle` starts now.
            c.initialPrompt = message; c.autoRunInitialPrompt = true
            c.startIfNeeded()
        }
    }

    /// Whether on-device command parsing (Apple Foundation Models) is available now.
    var foundationModelAvailable: Bool { FoundationModelParser.isAvailable }

    /// Drop a folder/file on the canvas → launch the last-used agent in it (the
    /// folder, or a dropped file's parent). A `.webloc` opens as a browser node.
    func handleDroppedFile(_ url: URL, viewportSize: CGSize) {
        if url.pathExtension.lowercased() == "webloc" {
            if let dict = NSDictionary(contentsOf: url), let s = dict["URL"] as? String, let target = URL(string: s) {
                openBrowser(url: target, viewportSize: viewportSize)
            }
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            notifier.post("Can't open that", body: "“\(url.lastPathComponent)” no longer exists.", kind: .error, system: false)
            return
        }
        let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
        deliverLaunch(kind: lastAgent, repoURL: folder, mode: .auto, task: "",
                      injectContext: injectContext, autoRun: false, viewportSize: viewportSize)
    }

    /// Open a browser node on the canvas at `url`.
    @discardableResult
    func openBrowser(url: URL, viewportSize: CGSize) -> UUID {
        var panel = PanelModel()
        panel.kind = .shell                    // not an agent; browserURL is the discriminator
        panel.name = nextNodeName()
        panel.project = url.host ?? "Browser"
        panel.browserURL = url.absoluteString
        panel.zIndex = topZIndex()
        workspace.panels.append(panel)
        // Opened while an agent is focused (e.g. "open … in browser" from the focus
        // re-prompt bar)? `focusedPanel` is unchanged, so the suppression didSet won't
        // fire for this new panel — suppress it explicitly so its web view mounts hidden
        // and never flashes over the cockpit. Minting is correct: it's on this canvas,
        // about to mount.
        if focusedPanel != nil { browsers.controller(for: panel).isSuppressed = true }
        selection = panel.id
        relayout(viewportSize: viewportSize)
        return panel.id
    }

    /// Core launch used by both the command bar and the New Agent flow.
    @discardableResult
    /// Whether a folder is a usable launch target (exists and is a directory).
    private func repoIsAccessible(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func deliverLaunch(kind: AgentKind, repoURL: URL, mode: RepoLaunchMode, task: String,
                       injectContext: Bool, autoRun: Bool, viewportSize: CGSize,
                       extraArgs: String = "", extraEnv: String = "") -> UUID {
        // Validate the target before creating anything — launching into a missing or
        // inaccessible folder would spawn a PTY in the wrong place with no feedback.
        guard repoIsAccessible(repoURL) else {
            notifier.post("Can't launch agent",
                          body: "“\(repoURL.lastPathComponent)” isn't an accessible folder. Pick another repo.",
                          kind: .error, system: false)
            // If the dead path was the saved default, clear it so it stops being reused.
            if defaultRepo?.path == repoURL.path { defaultRepo = nil }
            return UUID()
        }
        let id = addAgentPanel(kind: kind, repoURL: repoURL, mode: mode, viewportSize: viewportSize)
        guard let panel = panel(id) else { return id }
        // Set user-owned flags/env up front (before any early return), so they apply even
        // to a no-task launch. Used when the PTY starts (worktree mode defers the start).
        let controller = terminals.controller(for: panel)
        controller.extraArgs = extraArgs
        controller.extraEnv = extraEnv

        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return id }
        if let idx = workspace.panels.firstIndex(where: { $0.id == id }) {
            workspace.panels[idx].task = trimmed
        }
        // The agent runs in the worktree (worktree mode) or the repo root; in both
        // cases the context files — if committed — live at the repo root, so probe
        // there (falling back to the working dir for a non-git folder).
        let contextDir = panel.repoRoot ?? panel.workingDirectory
        controller.initialPrompt = buildLaunchPrompt(task: trimmed, injectContext: injectContext, directory: contextDir)
        controller.autoRunInitialPrompt = autoRun
        return id
    }

    /// Names of project context files the launch prompt can point an agent at.
    private static let contextFileNames = ["constitution.md", "memory.md"]

    /// Visible launch prompt: don't paste files — tell the agent to
    /// read the project's context files, then do the task.
    ///
    /// Only the context files that **actually exist** in `directory` are named, so an
    /// agent launched in a repo without them gets a clean task prompt instead of
    /// hunting for missing files and reporting "couldn't find them."
    func buildLaunchPrompt(task: String, injectContext: Bool, directory: String?) -> String {
        guard injectContext, let directory else { return task }
        let fm = FileManager.default
        let present = Self.contextFileNames.filter {
            fm.fileExists(atPath: (directory as NSString).appendingPathComponent($0))
        }
        guard !present.isEmpty else { return task }
        let list = present.map { "./\($0)" }.joined(separator: " and ")
        return "Read \(list) in this repo first and follow the guidance there. Then complete this task: \(task)"
    }

    // MARK: New Agent flow + command palette

    @Published var newAgentDraft: NewAgentDraft?
    @Published var showCommandPalette = false
    /// The Attention Inbox (⌘I) — the cross-canvas queue of agents needing a human.
    @Published var showAttentionInbox = false
    @Published var focusedPanel: UUID? {
        didSet {
            guard focusedPanel != oldValue else { return }
            updateBrowserSuppression()   // hide/show browser web surfaces (see below)
        }
    }
    /// True while the on-device model is parsing a command-bar line (drives a spinner).
    @Published var isParsingCommand = false
    /// Whether the *last* command-bar line was resolved by Apple's on-device model
    /// (vs the instant deterministic parser) — drives the "✦ on-device" hint.
    @Published var lastCommandUsedModel = false

    func enterFocus(_ id: UUID) {
        // Focus Mode is terminal-only; never focus a browser node (it would mint a
        // TerminalController and spawn a stray shell).
        guard let p = panel(id), !p.isBrowser else { return }
        selection = id
        bringToFront(id)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { focusedPanel = id }
    }

    func exitFocus() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { focusedPanel = nil }
    }

    // MARK: Attention aggregation (the "N need you" badge + the Attention Inbox)

    /// An agent (on any canvas) that currently wants a human, with the reason.
    struct AgentAttention: Identifiable {
        let panel: PanelModel
        let workspaceID: UUID
        let workspaceName: String
        let status: SessionStatus
        var id: UUID { panel.id }
    }

    /// Urgency order for the attention set; nil = not in the set (busy or idle). error first.
    static func attentionRank(_ s: SessionStatus) -> Int? {
        switch s {
        case .error:   return 0   // crashed
        case .blocked: return 1   // asking you a question
        case .waiting: return 2   // your turn / awaiting input
        case .done:    return 3   // process finished
        case .idle, .working: return nil
        }
    }

    /// Every agent across every canvas that isn't actively working or idle — blocked on a
    /// question, crashed, or awaiting your input/review — worst-first. Read-only; never
    /// mints a controller. The badge and inbox poll this on a light timer, which sidesteps
    /// nested-observable plumbing for a value that can lag a couple seconds without harm.
    /// Terminal-state agents (done/crashed) the user has already SEEN (revealed) — held
    /// out of the badge/inbox until they change state, so a finished agent left on the
    /// canvas doesn't pin "N need you" forever. Plain (non-published): mutated during the
    /// poll without triggering a view-update cycle; re-armed when the agent leaves the state.
    private var acknowledgedAttention: Set<UUID> = []

    func agentsNeedingAttention() -> [AgentAttention] {
        var out: [AgentAttention] = []
        for ws in workspaces {
            for panel in ws.panels where !panel.isBrowser {
                guard let c = terminals.existingController(for: panel.id) else {
                    acknowledgedAttention.remove(panel.id); continue
                }
                let s = c.displayStatus
                guard Self.attentionRank(s) != nil else {
                    acknowledgedAttention.remove(panel.id); continue   // busy/idle → re-arm
                }
                let isTerminalState = (s == .done || s == .error)
                if !isTerminalState {
                    acknowledgedAttention.remove(panel.id)             // left terminal state → re-arm
                } else if acknowledgedAttention.contains(panel.id) {
                    continue                                           // already seen → stay calm
                }
                out.append(AgentAttention(panel: panel, workspaceID: ws.id,
                                          workspaceName: ws.name, status: s))
            }
        }
        return out.sorted {
            (Self.attentionRank($0.status) ?? 9, $0.panel.name) <
            (Self.attentionRank($1.status) ?? 9, $1.panel.name)
        }
    }

    /// Toggle the Attention Inbox open.
    func openAttentionInbox() { showAttentionInbox = true }

    /// Reveal the next agent needing attention in priority order, cycling from the current
    /// selection — the keyboard triage loop (⌃⌥→). Closes the inbox so the agent is visible.
    func jumpToNextAttention() {
        let queue = agentsNeedingAttention()
        guard !queue.isEmpty else { return }
        showAttentionInbox = false
        let start = queue.firstIndex { $0.panel.id == selection }
        let target = start.map { queue[($0 + 1) % queue.count] } ?? queue[0]
        revealAgent(target.panel.id)
    }

    /// Bring an agent (possibly on another canvas) into view: switch canvas if needed,
    /// center the camera on it, select + raise it. Used by the badge and the inbox.
    func revealAgent(_ panelId: UUID) {
        guard let ws = workspaces.first(where: { $0.panels.contains { $0.id == panelId } }) else { return }
        if ws.id != currentWorkspaceID { switchTo(ws.id) }                 // switchTo clears focus
        if focusedPanel != nil, focusedPanel != panelId { exitFocus() }    // same-canvas: leave focus so the agent is actually visible
        guard let p = panel(panelId) else { return }
        selection = panelId
        bringToFront(panelId)
        centerCamera(on: CGPoint(x: p.worldFrame.midX, y: p.worldFrame.midY), viewportSize: lastViewport)
        // Acknowledge a terminal-state agent on reveal — you've now seen the finish/crash,
        // so it drops out of the attention set until it changes state again.
        if let c = terminals.existingController(for: panelId), c.displayStatus == .done || c.displayStatus == .error {
            acknowledgedAttention.insert(panelId)
        }
    }

    // MARK: Ship It (review → merge)

    /// Commit the worktree's changes (no merge), so you can checkpoint without shipping.
    func commitWorktree(_ id: UUID, message: String) {
        guard let panel = panel(id), let worktree = panel.worktreePath else { return }
        let name = panelName(for: id)
        Task { @MainActor in
            do {
                let made = try await Task.detached { try GitManager.shared.commitAll(at: worktree, message: message) }.value
                notifier.post(made ? "Committed \(name)" : "Nothing to commit",
                              body: made ? message : nil, kind: made ? .success : .info, system: false)
            } catch {
                notifier.post("Commit failed", body: error.localizedDescription, kind: .error)
            }
        }
    }

    /// Accept a worktree agent's work: commit it, merge the branch into the main repo's
    /// current branch, then remove the worktree + close the card. All git mutations run
    /// off-main; a conflict aborts the merge and surfaces an error — nothing is removed,
    /// so the user can resolve manually. Only ever invoked from an explicit, confirmed tap.
    func shipPanel(_ id: UUID, message: String) {
        guard let panel = panel(id), let repoRoot = panel.repoRoot,
              let branch = panel.branch, let worktree = panel.worktreePath else { return }
        let name = panelName(for: id)
        Task { @MainActor in
            do {
                // Returns (shipped, base): shipped == false when there was nothing to commit
                // AND no unmerged commits — so we don't claim a merge that didn't happen.
                let outcome = try await Task.detached { () -> (shipped: Bool, base: String) in
                    let committed = try GitManager.shared.commitAll(at: worktree, message: message)
                    let pending = GitManager.shared.unmergedCommitCount(repoRoot: repoRoot, branch: branch)
                    let base = GitManager.shared.currentBranch(at: repoRoot) ?? "the base branch"
                    guard committed || pending > 0 else { return (false, base) }
                    try GitManager.shared.mergeBranch(branch, into: repoRoot)
                    return (true, base)
                }.value
                if outcome.shipped {
                    let short = branch.replacingOccurrences(of: "agent/", with: "")
                    notifier.post("Shipped \(name)", body: "Merged \(short) into \(outcome.base) and cleaned up.", kind: .success)
                    // Worktree is committed + merged → clean → removePanel takes its no-confirm path.
                    removePanel(id)
                } else {
                    notifier.post("Nothing to ship", body: "\(name) has no changes or commits to merge.", kind: .info, system: false)
                }
            } catch {
                notifier.post("Couldn't ship \(name)", body: error.localizedDescription, kind: .error)
            }
        }
    }

    /// Open a GitHub PR for a worktree agent: commit its changes, push the branch, then
    /// `gh pr create --fill`, and open the PR in the browser. Off-main; uses the user's
    /// already-authed optional `gh` CLI — adds no accounts/backend.
    func openPullRequest(_ id: UUID, message: String) {
        guard let panel = panel(id), let branch = panel.branch, let worktree = panel.worktreePath else { return }
        let name = panelName(for: id)
        let short = branch.replacingOccurrences(of: "agent/", with: "")
        notifier.post("Opening PR for \(name)…", body: "Committing + pushing \(short).", kind: .info, system: false)
        Task { @MainActor in
            let result = await Task.detached { () -> Result<String, GitError> in
                do { _ = try GitManager.shared.commitAll(at: worktree, message: message) }
                catch { return .failure(.command(error.localizedDescription)) }
                return GHCli.openPR(worktree: worktree, branch: branch)
            }.value
            switch result {
            case .success(let url):
                notifier.post("PR opened for \(name)", body: url, kind: .success)
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            case .failure(let err):
                notifier.post("Couldn't open PR for \(name)", body: err.errorDescription ?? "gh failed", kind: .error)
            }
        }
    }

    /// While any agent is in Focus Mode, hide every browser's web surface so its
    /// separate WebContent-process layer can't composite over the focus cockpit (a
    /// SwiftUI overlay can't be z-ordered above a sibling WKWebView's remote layer).
    /// Unconditional — no geometry — so browsers parked in the inset margins simply
    /// drop their web view; the card shows a themed "paused" state instead. Driven off
    /// `focusedPanel` exactly like PanelCardView releases its PTY when focused. Spans
    /// all canvases but never mints a controller, so it can't spawn stray web views.
    func updateBrowserSuppression() {
        let active = focusedPanel != nil
        // Flip without animation. `webView.isHidden` is a non-animatable AppKit mutation
        // (the surface re-composites on the next frame), so the card's matching cosmetic
        // swap — dropping the white backing and the "Paused" overlay — must happen in the
        // same frame. This runs inside enterFocus/exitFocus's `withAnimation`, so without
        // an explicit transaction those views would inherit the 0.4s focus spring and the
        // "Paused" text would ghost over the re-shown live page on exit. The FocusModeView
        // spring is driven by `focusedPanel` (assigned outside this transaction) and is
        // unaffected.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            for ws in workspaces {
                for panel in ws.panels where panel.isBrowser {
                    browsers.existingController(for: panel.id)?.isSuppressed = active
                }
            }
        }
    }

    func isGitRepo(_ url: URL) -> Bool { GitManager.shared.repoRoot(url.path) != nil }

    /// Smart suggested mode: worktree if another agent already uses this repo.
    func suggestedMode(for url: URL) -> RepoLaunchMode {
        guard let root = GitManager.shared.repoRoot(url.path) else { return .separate }
        return workspace.panels.contains { $0.repoRoot == root } ? .worktree : .separate
    }

    func presentNewAgent(kind: AgentKind = .claude, repo: URL? = nil) {
        var draft = NewAgentDraft(kind: kind)
        draft.injectContext = injectContext   // seed the sheet's checkbox from the global default
        if let target = repo ?? defaultRepo ?? WorkspaceStore.shared.recentRepos.first {
            draft.repo = target
            draft.mode = suggestedMode(for: target)
        }
        newAgentDraft = draft
    }

    func launchDraft(_ draft: NewAgentDraft, viewportSize: CGSize) {
        guard let repo = draft.repo else { return }
        deliverLaunch(kind: draft.kind, repoURL: repo, mode: draft.mode, task: draft.task,
                      injectContext: draft.injectContext, autoRun: draft.autoRun, viewportSize: viewportSize,
                      extraArgs: draft.extraArgs, extraEnv: draft.extraEnv)
        newAgentDraft = nil
    }

    /// Worktree panels whose async close (inspect → confirm → remove) is in flight.
    /// Blocks a re-entrant second close from stacking a duplicate confirmation alert
    /// or racing a second `removeWorktree` on the same dir.
    private var removingPanels: Set<UUID> = []

    func removePanel(_ id: UUID) {
        guard let panel = panel(id) else { return }

        // Fast path: nothing to inspect on disk. Either there's no worktree, OR the
        // worktree is still being created (closing mid-prep) — in that case just drop
        // the panel and let finalizeWorktreeLaunch remove the worktree once the
        // in-flight checkout completes (sequential → no create/remove race).
        let preparing = terminals.existingController(for: id)?.runState == .preparing
        guard let wt = panel.worktreePath, let root = panel.repoRoot, !preparing else {
            terminals.remove(id)
            browsers.remove(id)                    // no-op for non-browser panels
            workspace.panels.removeAll { $0.id == id }
            if selection == id { selection = nil }
            removingPanels.remove(id)
            relayout(viewportSize: lastViewport)   // following cards pull up to fill the gap
            return
        }

        // One close flow per panel: a second click during the async inspect/confirm
        // window (the panel is still visible meanwhile) is ignored.
        guard removingPanels.insert(id).inserted else { return }

        // Worktree → inspect for unsaved work OFF the main thread (uncommitted edits
        // and unmerged commits), then confirm on the main actor, then remove off-main.
        // The panel stays put until the user decides; nothing blocks the UI meanwhile.
        let branch = panel.branch ?? ""
        Task { [weak self] in
            defer { self?.removingPanels.remove(id) }   // clears on every exit (main actor)
            let (changedCount, committed) = await Task.detached { () -> (Int, Int) in
                let changes = GitManager.shared.changedFiles(at: wt).count
                let commits = branch.isEmpty ? 0 : GitManager.shared.unmergedCommitCount(repoRoot: root, branch: branch)
                return (changes, commits)
            }.value
            guard let self else { return }

            let decision: WorktreeCleanup = (changedCount == 0 && committed == 0)
                ? .discard
                : self.presentWorktreeCleanupAlert(changedCount: changedCount, committedCount: committed, branch: branch)

            switch decision {
            case .cancel:
                return                          // keep the panel + worktree
            case .keep:
                self.terminals.remove(id)       // leave the worktree on disk
            case .discard:
                self.terminals.remove(id)
                await Task.detached { try? GitManager.shared.removeWorktree(repoRoot: root, at: wt, force: true) }.value
            }
            self.workspace.panels.removeAll { $0.id == id }
            if self.selection == id { self.selection = nil }
            self.relayout(viewportSize: self.lastViewport)   // following cards pull up to fill the gap
        }
    }

    // MARK: Destructive-action confirmations

    private enum WorktreeCleanup { case discard, keep, cancel }

    private func presentWorktreeCleanupAlert(changedCount: Int, committedCount: Int, branch: String) -> WorktreeCleanup {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove this agent's worktree?"
        var parts: [String] = []
        if changedCount > 0 { parts.append("\(changedCount) uncommitted change\(changedCount == 1 ? "" : "s")") }
        if committedCount > 0 { parts.append("\(committedCount) unmerged commit\(committedCount == 1 ? "" : "s")") }
        let summary = parts.joined(separator: " and ")
        alert.informativeText = "Branch \(branch) has \(summary). Removing the worktree discards that work. Keep it to merge/review later."
        alert.addButton(withTitle: "Keep Worktree")     // default
        alert.addButton(withTitle: "Discard & Remove")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .keep
        case .alertSecondButtonReturn: return .discard
        default:                       return .cancel
        }
    }

    private func presentGitErrorAlert(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't create worktree"
        alert.informativeText = "\(message)\n\nThe agent will start in the repo instead."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Move / resize with magnetic snapping

    func movePanel(_ id: UUID, to worldOrigin: CGPoint, snapping: Bool) {
        guard let idx = workspace.panels.firstIndex(where: { $0.id == id }) else { return }
        var origin = worldOrigin
        if snapping {
            origin = snap(origin: origin, size: workspace.panels[idx].size, excluding: id)
        }
        workspace.panels[idx].position = origin
    }

    func resizePanel(_ id: UUID, to size: CGSize) {
        guard let idx = workspace.panels.firstIndex(where: { $0.id == id }) else { return }
        workspace.panels[idx].size = CGSize(
            width: max(Theme.minPanelSize.width, size.width),
            height: max(Theme.minPanelSize.height, size.height)
        )
    }

    /// Snap a moving panel's edges/centers to nearby panels' edges/centers.
    private func snap(origin: CGPoint, size: CGSize, excluding id: UUID) -> CGPoint {
        let moving = CGRect(origin: origin, size: size)
        var best = origin

        // Candidate guide lines from every other panel.
        var xLines: [CGFloat] = []
        var yLines: [CGFloat] = []
        for p in workspace.panels where p.id != id {
            let f = p.worldFrame
            xLines += [f.minX, f.midX, f.maxX]
            yLines += [f.minY, f.midY, f.maxY]
        }

        // Try to align moving panel's own left/center/right to any guide line.
        let xCandidates: [CGFloat] = [moving.minX, moving.midX, moving.maxX]
        let yCandidates: [CGFloat] = [moving.minY, moving.midY, moving.maxY]

        if let (delta, _) = nearestDelta(from: xCandidates, to: xLines) {
            best.x += delta
        }
        if let (delta, _) = nearestDelta(from: yCandidates, to: yLines) {
            best.y += delta
        }
        return best
    }

    private func nearestDelta(from candidates: [CGFloat], to lines: [CGFloat]) -> (CGFloat, CGFloat)? {
        var bestDelta: CGFloat?
        for c in candidates {
            for l in lines {
                let d = l - c
                if abs(d) <= snapThreshold {
                    if bestDelta == nil || abs(d) < abs(bestDelta!) { bestDelta = d }
                }
            }
        }
        guard let d = bestDelta else { return nil }
        return (d, 0)
    }

    // MARK: Initial size & placement

    /// New-panel size in **world** units: a fraction of the window, clamped to
    /// [min, max]. Deliberately INDEPENDENT of the current zoom — every card gets the
    /// same world size, so cards spawned at different zoom levels stay consistent with
    /// each other. (Previously `/ zoom` baked the zoom-at-creation into the size, so a
    /// card made while zoomed out came out larger in world space than one made at 1×.)
    func initialPanelSize(viewportSize: CGSize) -> CGSize {
        let w = min(Theme.maxPanelSize.width,
                    max(Theme.minPanelSize.width, viewportSize.width * Theme.panelWidthFraction))
        let h = min(Theme.maxPanelSize.height,
                    max(Theme.minPanelSize.height, viewportSize.height * Theme.panelHeightFraction))
        return CGSize(width: w, height: h)
    }

    /// World-space gap between auto-placed / tidied cards (uniform regardless of zoom).
    private static let placementGap: CGFloat = 28

    /// Place a new panel in the first free slot of a uniform grid anchored to the
    /// visible area, so new cards tile neatly side-by-side — consistent size and gap,
    /// no manual Tidy needed. The grid is computed in WORLD units, so spacing doesn't
    /// stretch or shrink with zoom. Falls back to a gentle cascade once it's full.
    private func autoPlace(size: CGSize, viewportSize: CGSize) -> CGPoint {
        let gap = Self.placementGap
        let topInset: CGFloat = 80      // screen px — clear the floating toolbar
        let inset: CGFloat = 28         // screen px
        let zoom = max(camera.zoom, 0.01)

        // Anchor at the visible top-left; lay out cells in world units.
        let originWorld = camera.screenToWorld(CGPoint(x: inset, y: topInset))
        let cellW = size.width + gap
        let cellH = size.height + gap

        // How many columns/rows fit in the visible viewport (converted to world units).
        let usableW = (viewportSize.width - inset * 2) / zoom
        let usableH = (viewportSize.height - topInset - inset) / zoom
        let cols = max(1, Int((usableW + gap) / cellW))
        let rows = max(1, Int((usableH + gap) / cellH))

        for idx in 0..<(cols * rows) {
            let col = idx % cols
            let row = idx / cols
            let origin = CGPoint(x: originWorld.x + CGFloat(col) * cellW,
                                 y: originWorld.y + CGFloat(row) * cellH)
            let frame = CGRect(origin: origin, size: size)
            let occupied = workspace.panels.contains {
                $0.worldFrame.insetBy(dx: -8, dy: -8).intersects(frame)
            }
            if !occupied { return origin }
        }

        // Visible grid is full → gentle cascade from the anchor.
        let n = CGFloat(workspace.panels.count)
        return CGPoint(x: originWorld.x + n * 36, y: originWorld.y + n * 32)
    }

    // MARK: Camera commands

    func panBy(_ delta: CGSize) {
        camera.pan.width += delta.width
        camera.pan.height += delta.height
    }

    func zoom(by magnification: CGFloat, at anchor: CGPoint) {
        camera.zoomBy(1 + magnification, anchor: anchor, minZoom: Theme.minZoom, maxZoom: Theme.maxZoom)
    }

    /// Fit all panels into the viewport; if none, just recenter at zoom 1.
    func centerWorkspace(viewportSize: CGSize) {
        guard !workspace.panels.isEmpty else {
            withCameraAnimation { self.camera = Camera(pan: .zero, zoom: 1.0) }
            return
        }
        let bounds = workspace.panels
            .map(\.worldFrame)
            .reduce(workspace.panels[0].worldFrame) { $0.union($1) }
            .insetBy(dx: -80, dy: -80)

        let zoom = min(
            Theme.maxZoom,
            max(Theme.minZoom, min(viewportSize.width / bounds.width, viewportSize.height / bounds.height))
        )
        let pan = CGSize(
            width: viewportSize.width / 2 - bounds.midX * zoom,
            height: viewportSize.height / 2 - bounds.midY * zoom
        )
        withCameraAnimation { self.camera = Camera(pan: pan, zoom: zoom) }
    }

    func relayout(viewportSize: CGSize) {
        // Don't reflow while a card is being dragged — it would yank the grid out
        // from under the cursor. The drop handler re-grids it (reorderByPosition).
        guard draggingPanelID == nil else { return }
        arrange(viewportSize: viewportSize)
    }

    /// Manual Tidy (⇧⌘T / palette): reset the view to 1× and re-fill the window.
    func autoTidy(viewportSize: CGSize) {
        camera = Camera(pan: .zero, zoom: 1)
        arrange(viewportSize: viewportSize)
    }

    /// **Fill-tile layout.** The cards STRETCH to fill the visible window,
    /// split into a balanced grid: 1 node fills the window, 2 split it in half, 3 in
    /// thirds, 4 → 2×2, 5 → 3×2, and so on. Re-runs on add / remove / resize so the
    /// window is always filled (no fixed-size cards, no wasted margin, no cropping).
    ///
    /// Columns are derived from the WINDOW width (zoom-independent, so zooming can't
    /// re-stack the grid); the tiles are then sized in WORLD units to fill the visible
    /// viewport. Many nodes clamp to a minimum tile height and overflow downward.
    private func arrange(viewportSize: CGSize) {
        guard !workspace.panels.isEmpty else { return }
        let n = workspace.panels.count
        let margin: CGFloat = 20
        let topInset: CGFloat = 64       // clears the floating toolbar pill
        let bottomInset: CGFloat = 92    // clears the floating command bar
        let gapScreen: CGFloat = 14
        let zoom = max(camera.zoom, 0.01)

        // Balanced grid: as many columns as the window comfortably fits (capped at 3),
        // then balance rows/cols so tiles stay roughly square — 4 → 2×2,
        // 5 → 3×2, 7 → 3×3. A narrow window drops the cap to 2 or 1.
        let minTileScreenW: CGFloat = 440
        let fits = Int((viewportSize.width - margin * 2 + gapScreen) / (minTileScreenW + gapScreen))
        let maxCols = max(1, min(3, fits))
        let rows = max(1, Int(ceil(Double(n) / Double(maxCols))))
        let cols = max(1, Int(ceil(Double(n) / Double(rows))))

        // Fill the visible viewport (converted to world units at the current zoom).
        let origin = camera.screenToWorld(CGPoint(x: margin, y: topInset))
        let gap = gapScreen / zoom
        let areaW = (viewportSize.width - margin * 2) / zoom
        let areaH = (viewportSize.height - topInset - bottomInset) / zoom
        let tileW = (areaW - CGFloat(cols - 1) * gap) / CGFloat(cols)
        let minTileH: CGFloat = 240 / zoom
        let tileH = max(minTileH, (areaH - CGFloat(rows - 1) * gap) / CGFloat(rows))

        for (i, idx) in workspace.panels.indices.enumerated() {
            if workspace.panels[idx].id == draggingPanelID { continue }   // don't fight the cursor
            let col = i % cols, row = i / cols
            workspace.panels[idx].size = CGSize(width: tileW, height: tileH)
            workspace.panels[idx].position = CGPoint(
                x: origin.x + CGFloat(col) * (tileW + gap),
                y: origin.y + CGFloat(row) * (tileH + gap))
        }
    }

    /// Reorder panels to match their on-screen reading order (row-major), then re-tile.
    /// Called when a drag ends: the card lands in the slot it was dropped near, and an
    /// off-grid drop simply snaps into the nearest slot.
    func reorderByPosition(viewportSize: CGSize) {
        let rowBand = (workspace.panels.first?.height ?? 300) * 0.5
        workspace.panels.sort { a, b in
            abs(a.y - b.y) > rowBand ? a.y < b.y : a.x < b.x
        }
        relayout(viewportSize: viewportSize)
    }

    private func withCameraAnimation(_ body: () -> Void) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { body() }
    }
}
