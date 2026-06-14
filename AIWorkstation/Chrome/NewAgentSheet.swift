import SwiftUI

/// New Agent flow (Steps 1–5): choose agent, repo, repo
/// mode, task (+ templates + context), then a **Review** summary before Launch.
/// Presented as a centered glass card over a dimmed canvas.
struct NewAgentSheet: View {
    @Binding var draft: NewAgentDraft
    @ObservedObject var state: CanvasState
    let viewport: CGSize

    // Repo/CLI facts are resolved by spawning subprocesses, so they're cached and
    // refreshed only when the repo or agent actually changes — never per keystroke
    // (the task field rebuilds the body on every character).
    @State private var isGitCache = false
    @State private var suggestedModeCache: RepoLaunchMode = .separate
    @State private var cliPathCache: String?

    private var isGit: Bool { isGitCache }
    private var canLaunch: Bool { draft.repo != nil }

    private func refreshRepoFacts() {
        if let repo = draft.repo {
            isGitCache = state.isGitRepo(repo)
            suggestedModeCache = state.suggestedMode(for: repo)
        } else {
            isGitCache = false
            suggestedModeCache = .separate
        }
        cliPathCache = AgentCLI.shared.resolvedPath(for: draft.kind)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { state.newAgentDraft = nil }

            card
        }
        .transition(.opacity)
        .onAppear { refreshRepoFacts() }
        .onChange(of: draft.repo) { _, _ in refreshRepoFacts() }
        .onChange(of: draft.kind) { _, _ in cliPathCache = AgentCLI.shared.resolvedPath(for: draft.kind) }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            agentPicker
            repoSection
            if draft.repo != nil { modeSection }
            taskSection
            togglesRow
            reviewBox
            footer
        }
        .padding(22)
        .frame(width: 540)
        .background(glass)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
        .shadow(color: Theme.cardShadow, radius: 40, y: 18)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("New Agent").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Button { state.newAgentDraft = nil } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22).background(Color.white.opacity(0.06), in: Circle())
            }.buttonStyle(.plain)
        }
    }

    // MARK: Agent

    private var agentPicker: some View {
        labeled("Agent") {
            HStack(spacing: 8) {
                ForEach([AgentKind.claude, .codex], id: \.self) { kind in
                    segButton(kind.displayName, systemImage: kind.glyph, tint: kind.tint,
                              selected: draft.kind == kind) { draft.kind = kind }
                }
            }
        }
    }

    // MARK: Repo

    private var repoSection: some View {
        labeled("Repository") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if let repo = draft.repo {
                        HStack(spacing: 6) {
                            Image(systemName: isGit ? "arrow.triangle.branch" : "folder")
                                .font(.system(size: 11)).foregroundStyle(isGit ? Theme.accent : Theme.textSecondary)
                            Text(repo.lastPathComponent).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                            if !isGit { Text("not git").font(.system(size: 10)).foregroundStyle(Theme.textTertiary) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.white.opacity(0.05), in: Capsule())
                    }
                    Button("Browse…") { if let url = RepoPicker.pickDirectory() { selectRepo(url) } }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                    Spacer()
                }
                let recents = WorkspaceStore.shared.recentRepos.filter { $0 != draft.repo }
                if !recents.isEmpty {
                    HStack(spacing: 6) {
                        Text("Recent").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        ForEach(recents.prefix(4), id: \.self) { url in
                            Button(url.lastPathComponent) { selectRepo(url) }
                                .buttonStyle(.plain).font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.white.opacity(0.04), in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private func selectRepo(_ url: URL) {
        draft.repo = url
        draft.mode = state.suggestedMode(for: url)   // facts refresh via onChange(draft.repo)
    }

    /// Apply a task template, replacing any existing template prefix rather than
    /// stacking them (clicking Implement then Review shouldn't yield both prefixes).
    private func applyTemplate(_ t: TaskTemplate) {
        var body = draft.task
        for other in TaskTemplate.allCases where body.hasPrefix(other.prompt) {
            body = String(body.dropFirst(other.prompt.count))
            break
        }
        draft.task = t.prompt + body
    }

    // MARK: Mode

    private var modeSection: some View {
        labeled("Mode") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    segButton("Separate", systemImage: "folder", tint: Theme.accent,
                              selected: draft.mode == .separate) { draft.mode = .separate }
                    segButton("Worktree", systemImage: "arrow.triangle.branch", tint: Theme.accent,
                              selected: draft.mode == .worktree, disabled: !isGit) { if isGit { draft.mode = .worktree } }
                }
                Text(modeNote)
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var modeNote: String {
        if !isGit { return "Not a git repo — the agent runs directly in the folder." }
        switch draft.mode {
        case .worktree: return "Isolated git worktree + branch, so multiple agents never clash. \(suggestedModeCache == .worktree ? "(suggested — another agent already uses this repo)" : "")"
        case .separate: return "Runs in the repo itself. \(suggestedModeCache == .separate ? "(suggested)" : "")"
        case .auto:     return ""
        }
    }

    // MARK: Task

    private var taskSection: some View {
        labeled("Task") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(TaskTemplate.allCases) { t in
                        Button(t.label) { applyTemplate(t) }
                            .buttonStyle(.plain).font(.system(size: 10.5))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.white.opacity(0.04), in: Capsule())
                    }
                }
                TextField("Describe what this agent should do…", text: $draft.task, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2...5)
                    .padding(10)
                    .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.cardStroke, lineWidth: 1))
            }
        }
    }

    private var togglesRow: some View {
        HStack(spacing: 18) {
            toggle("Read constitution.md & memory.md first", $draft.injectContext)
            toggle("Run on launch", $draft.autoRun)
            Spacer()
        }
    }

    // MARK: Review

    private var reviewBox: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("REVIEW").font(.system(size: 9.5, weight: .bold)).tracking(0.6).foregroundStyle(Theme.textTertiary)
            reviewRow("Agent", "\(draft.kind.displayName)  ·  \(cliPathCache ?? "not found")")
            reviewRow("Repo", draft.repo?.path ?? "—")
            reviewRow("Mode", reviewMode)
            if draft.injectContext { reviewRow("Context", "reads constitution.md / memory.md if present, then the task") }
            reviewRow("Command", reviewCommand)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.cardStroke, lineWidth: 1))
    }

    private var reviewMode: String {
        guard draft.repo != nil else { return "—" }
        if !isGit { return "Separate · runs in the folder" }
        return draft.mode == .worktree
            ? "Worktree · new branch agent/\(draft.kind.rawValue)-… in an external worktree"
            : "Separate · runs in the repo"
    }

    private var reviewCommand: String {
        let bin = draft.kind.rawValue
        let trimmed = draft.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return bin }
        return draft.autoRun ? "\(bin) \"…task…\"  (auto-runs)" : "\(bin)  then types the task for review"
    }

    private func reviewRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.textTertiary).frame(width: 64, alignment: .leading)
            Text(v).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary).lineLimit(2).truncationMode(.middle)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { state.newAgentDraft = nil }
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
            Button {
                state.launchDraft(draft, viewportSize: viewport)
            } label: {
                Text("Launch").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(canLaunch ? Theme.accent : Theme.accent.opacity(0.4), in: Capsule())
            }
            .buttonStyle(.plain).disabled(!canLaunch)
        }
    }

    // MARK: Reusable bits

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(0.6).foregroundStyle(Theme.textTertiary)
            content()
        }
    }

    private func segButton(_ title: String, systemImage: String, tint: Color, selected: Bool, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)).foregroundStyle(selected ? tint : Theme.textTertiary)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(selected ? Color.white.opacity(0.07) : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.5) : Theme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(.plain).opacity(disabled ? 0.4 : 1)
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        Button { binding.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: binding.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12)).foregroundStyle(binding.wrappedValue ? Theme.accent : Theme.textTertiary)
                Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
            }
        }.buttonStyle(.plain)
    }

    private var glass: some View {
        ZStack { VisualEffectView(material: .hudWindow, blending: .behindWindow); Theme.chromeFill }
    }
}
