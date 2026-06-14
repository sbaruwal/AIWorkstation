import SwiftUI

/// Premium, minimal empty canvas: a few quick actions,
/// no dense tutorial. Shown only when the workspace has zero panels.
struct EmptyStateView: View {
    @ObservedObject var state: CanvasState
    let viewportSize: CGSize

    private var recents: [URL] { WorkspaceStore.shared.recentRepos }

    /// Other canvases (the current one is empty — that's why home is showing).
    private var otherCanvases: [Workspace] {
        state.workspaces.filter { $0.id != state.currentWorkspaceID && !$0.panels.isEmpty }
    }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 34, weight: .ultraLight))
                    .foregroundStyle(Theme.textSecondary)
                Text(state.greeting)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Launch an agent to begin — or type a task below.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 12) {
                quickAction("New Claude agent", "sparkle", tint: AgentKind.claude.tint) {
                    launchAgent(.claude)
                }
                quickAction("New Codex agent", "chevron.left.forwardslash.chevron.right", tint: AgentKind.codex.tint) {
                    launchAgent(.codex)
                }
            }

            if !otherCanvases.isEmpty {
                VStack(spacing: 8) {
                    Text("YOUR CANVASES").font(.system(size: 9.5, weight: .bold)).tracking(0.6).foregroundStyle(Theme.textTertiary)
                    HStack(spacing: 10) {
                        ForEach(otherCanvases.prefix(4)) { ws in
                            workspaceCard(ws)
                        }
                    }
                }
            }

            if !recents.isEmpty {
                VStack(spacing: 8) {
                    Text("RECENT REPOS").font(.system(size: 9.5, weight: .bold)).tracking(0.6).foregroundStyle(Theme.textTertiary)
                    HStack(spacing: 6) {
                        ForEach(recents.prefix(5), id: \.self) { url in
                            Button {
                                state.presentNewAgent(repo: url)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(Theme.accent)
                                    Text(url.lastPathComponent).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.white.opacity(0.05), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: 620)
    }

    /// A card for another canvas — name, what's in it, and last-updated. Click to switch.
    private func workspaceCard(_ ws: Workspace) -> some View {
        let agents = ws.panels.filter { !$0.isBrowser }.count
        let browsers = ws.panels.filter { $0.isBrowser }.count
        return Button {
            state.switchTo(ws.id)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "square.on.square").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                    Text(ws.name.isEmpty ? "Untitled" : ws.name)
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                Text(canvasSummary(agents: agents, browsers: browsers))
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
                Text(relative(ws.updatedAt))
                    .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 138, height: 84, alignment: .topLeading)
            .padding(12)
            .background {
                ZStack {
                    VisualEffectView(material: .hudWindow, blending: .behindWindow)
                    Theme.cardFill
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Switch to \(ws.name)")
    }

    private func canvasSummary(agents: Int, browsers: Int) -> String {
        var parts: [String] = []
        if agents > 0 { parts.append("\(agents) agent\(agents == 1 ? "" : "s")") }
        if browsers > 0 { parts.append("\(browsers) browser\(browsers == 1 ? "" : "s")") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func launchAgent(_ kind: AgentKind) {
        state.presentNewAgent(kind: kind)
    }

    private func quickAction(_ title: String, _ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(width: 168, height: 104)
            .background {
                ZStack {
                    VisualEffectView(material: .hudWindow, blending: .behindWindow)
                    Theme.cardFill
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
