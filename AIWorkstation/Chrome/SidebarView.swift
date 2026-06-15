import SwiftUI

/// Collapsible left sidebar. Hidden by default; reveals on edge hover or via the
/// toolbar/pin. Surfaces the live panel list and saved-layout affordance;
/// Projects / recent repos are not yet implemented.
struct SidebarView: View {
    @ObservedObject var state: CanvasState
    let viewportSize: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            section("Active Panels") {
                if state.panels.isEmpty {
                    Text("No panels yet")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(state.panels) { panel in
                        if panel.isBrowser {
                            panelRow(panel, status: panel.status)
                        } else {
                            // Observe the live controller so the dot tracks Working/
                            // Waiting/Idle in real time, not the stale stored status.
                            AgentStatusRow(controller: state.terminals.controller(for: panel)) { controller in
                                panelRow(panel, status: controller.displayStatus, controller: controller)
                            }
                        }
                    }
                }
            }

            Spacer()

            section("Layout") {
                Button {
                    state.persist()
                } label: {
                    Label("Save layout snapshot", systemImage: "square.and.arrow.down")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        // Extra top inset so the header clears the window's traffic-light buttons
        // (we use a hidden title bar, so content runs to the very top-left).
        .padding(.top, 34)
        .frame(width: 244)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(sidebarBackground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.accent.opacity(0.85))
                .frame(width: 9, height: 9)
            Text("AI Workstation")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { state.sidebarPinned.toggle() }
            } label: {
                Image(systemName: state.sidebarPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help(state.sidebarPinned ? "Unpin sidebar" : "Pin sidebar")
        }
    }

    private func panelRow(_ panel: PanelModel, status: SessionStatus, controller: TerminalController? = nil) -> some View {
        Button {
            // Center the camera on *this* panel (and raise it), rather than fitting
            // the whole workspace — clicking a row should take you to that agent.
            state.selection = panel.id
            state.bringToFront(panel.id)
            state.centerCamera(on: CGPoint(x: panel.worldFrame.midX, y: panel.worldFrame.midY),
                               viewportSize: viewportSize)
        } label: {
            HStack(spacing: 8) {
                Circle().fill(status.tint).frame(width: 6, height: 6)
                Image(systemName: panel.isBrowser ? "globe" : panel.kind.glyph)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(panel.isBrowser ? state.accent : panel.kind.tint)
                Text(panel.name.isEmpty ? panel.project : panel.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                // Live "how long" for the states where it matters (agents only).
                if let controller, status == .waiting || status == .blocked || status == .error {
                    TimelineView(.periodic(from: .now, by: 15)) { ctx in
                        if let d = TerminalController.durationLabel(since: controller.statusSince, now: ctx.date) {
                            Text(d)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                state.selection == panel.id ? Color.white.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                .tracking(0.6)
            content()
        }
    }

    private var sidebarBackground: some View {
        ZStack {
            VisualEffectView(material: .sidebar, blending: .behindWindow)
            Theme.chromeFill.opacity(0.6)
        }
    }
}

/// Observes a single `TerminalController` and hands its live `displayStatus` to a
/// row builder, so a sidebar row re-renders when that agent's activity changes.
private struct AgentStatusRow<Content: View>: View {
    @ObservedObject var controller: TerminalController
    @ViewBuilder let content: (TerminalController) -> Content
    var body: some View { content(controller) }
}
