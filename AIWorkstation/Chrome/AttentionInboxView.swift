import SwiftUI

/// The Attention Inbox (⌘I) — a single cross-canvas queue of every agent that wants a
/// human, ranked worst-first (crashed → blocked-on-a-question → your turn → done). Each
/// row shows the agent, the one-line ask, and how long it's been waiting; click (or
/// ⌃⌥→) to jump to it. Read-only aggregation over `CanvasState.agentsNeedingAttention()`;
/// refreshes on a light 1s timer so durations tick and the queue stays current.
struct AttentionInboxView: View {
    @ObservedObject var state: CanvasState

    var body: some View {
        ZStack {
            // Dim, tap-to-dismiss backdrop.
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { state.showAttentionInbox = false }

            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let queue = state.agentsNeedingAttention()
                VStack(alignment: .leading, spacing: 0) {
                    header(count: queue.count)
                    Divider().overlay(Color.white.opacity(0.08))
                    if queue.isEmpty {
                        emptyState
                    } else {
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(queue) { row($0, now: ctx.date) }
                            }
                            .padding(8)
                        }
                        .frame(maxHeight: 440)
                    }
                }
                .frame(width: 470)
                .background(panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.chromeStroke, lineWidth: 1))
                .shadow(color: Theme.cardShadow, radius: 30, y: 14)
            }
        }
        .transition(.opacity)
    }

    // MARK: Header

    private func header(count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(state.accent)
            Text("Needs you")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(state.accent.opacity(0.2), in: Capsule())
            }
            Spacer()
            Text("⌃⌥→ next")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            Button { state.showAttentionInbox = false } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(SessionStatus.working.tint)
            Text("All caught up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("No agents are waiting on you.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: Row

    private func row(_ item: CanvasState.AgentAttention, now: Date) -> some View {
        let controller = state.terminals.existingController(for: item.panel.id)
        let ask = controller?.pendingQuestion
        return Button {
            state.revealAgent(item.panel.id)
            state.showAttentionInbox = false
        } label: {
            HStack(spacing: 11) {
                Circle().fill(item.status.tint).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: item.panel.kind.glyph)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(item.panel.kind.tint)
                        Text(item.panel.name.isEmpty ? item.panel.project : item.panel.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(item.status.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(item.status.tint)
                        if state.workspaces.count > 1 {
                            Text("· \(item.workspaceName)")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Text(subtitle(for: item.panel, ask: ask))
                        .font(.system(size: 11))
                        .foregroundStyle(ask?.isEmpty == false ? Theme.textSecondary : Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let since = controller?.statusSince,
                   let d = TerminalController.durationLabel(since: since, now: now) {
                    Text(d)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(
                state.selection == item.panel.id ? Color.white.opacity(0.05) : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The ask (when blocked) else the repo · branch context.
    private func subtitle(for panel: PanelModel, ask: String?) -> String {
        if let ask, !ask.isEmpty { return ask }
        var parts: [String] = []
        if !panel.project.isEmpty, panel.project != "Untitled" { parts.append(panel.project) }
        if let branch = panel.branch, !branch.isEmpty {
            parts.append(branch.hasPrefix("agent/") ? String(branch.dropFirst("agent/".count)) : branch)
        }
        return parts.isEmpty ? "Awaiting your input" : parts.joined(separator: " · ")
    }

    private var panelBackground: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blending: .behindWindow)
            Theme.chromeFill
        }
    }
}
