import SwiftUI

/// Floating top toolbar pill (auto-hides until hover) — a centered control pill.
/// Holds the canvas switcher + canvas-level actions (new agent, tidy, fit, theme).
struct TopToolbarView: View {
    @ObservedObject var state: CanvasState
    let viewportSize: CGSize

    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { state.sidebarPinned.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle sidebar")

            divider

            canvasMenu

            divider

            attentionBadge

            // Launch a real Claude / Codex agent: pick a repo, start the CLI there.
            toolButton("plus", help: "New Claude agent") {
                launchAgent(.claude)
            }
            toolButton("chevron.left.forwardslash.chevron.right", help: "New Codex agent") {
                launchAgent(.codex)
            }

            divider

            toolButton("rectangle.3.group", help: "Tidy into a grid") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    state.autoTidy(viewportSize: viewportSize)
                }
            }
            toolButton("arrow.up.left.and.arrow.down.right", help: "Fit all to window") {
                state.centerWorkspace(viewportSize: viewportSize)
            }

            divider

            themeMenu

            divider

            // Pin keeps the toolbar from auto-hiding; accent tint when active.
            Button {
                state.toolbarPinned.toggle()
            } label: {
                Image(systemName: state.toolbarPinned ? "pin.fill" : "pin")
            }
            .help(state.toolbarPinned ? "Unpin toolbar" : "Pin toolbar")
            .buttonStyle(ChromeIconButtonStyle(tint: state.toolbarPinned ? state.accent : Theme.textSecondary))
        }
        .buttonStyle(ChromeIconButtonStyle())
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(chromeBackground)
        .clipShape(Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.chromeStroke, lineWidth: 1))
        .shadow(color: Theme.cardShadow, radius: 18, y: 8)
        .alert("Rename Canvas", isPresented: $renaming) {
            TextField("Canvas name", text: $renameText)
            Button("Rename") { state.renameWorkspace(to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete “\(state.workspace.name)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { state.deleteWorkspace(state.currentWorkspaceID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This closes its \(state.workspace.panels.count) card\(state.workspace.panels.count == 1 ? "" : "s") and ends any running sessions.")
        }
    }

    /// Ambient "N agents need you" pill — hidden when zero (the canvas stays calm).
    /// Tinted by the most urgent reason present (red crash · orange blocked · amber
    /// waiting · blue done). Clicking opens the Attention Inbox (the cross-canvas queue;
    /// the inbox / ⌃⌥→ is what jumps to a specific agent). Polls on a light 2s timer to
    /// avoid nested-observable plumbing for a count that can lag a moment harmlessly.
    @ViewBuilder private var attentionBadge: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let waiting = state.agentsNeedingAttention()
            if let worst = waiting.first {
                HStack(spacing: 6) {
                    Button {
                        state.openAttentionInbox()
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(worst.status.tint).frame(width: 7, height: 7)
                            Text("\(waiting.count)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(waiting.count == 1 ? "needs you" : "need you")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(worst.status.tint.opacity(0.14), in: Capsule())
                        .overlay(Capsule().strokeBorder(worst.status.tint.opacity(0.40), lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("\(waiting.count) agent\(waiting.count == 1 ? "" : "s") waiting on you — open the inbox")

                    divider
                }
            }
        }
    }

    /// Canvas switcher: lists every canvas (checkmark = active), plus new / rename /
    /// delete. Replaces the static workspace-name label.
    private var canvasMenu: some View {
        Menu {
            ForEach(state.workspaces) { ws in
                Button {
                    state.switchTo(ws.id)
                } label: {
                    Label(
                        ws.name.isEmpty ? "Untitled" : ws.name,
                        systemImage: ws.id == state.currentWorkspaceID ? "checkmark" : "square.on.square"
                    )
                }
            }

            Divider()

            Button {
                state.newWorkspace()
            } label: {
                Label("New Canvas", systemImage: "plus.square.on.square")
            }
            Button {
                renameText = state.workspace.name
                renaming = true
            } label: {
                Label("Rename Canvas…", systemImage: "pencil")
            }
            Button(role: .destructive) {
                if state.workspace.panels.isEmpty {
                    state.deleteWorkspace(state.currentWorkspaceID)
                } else {
                    confirmingDelete = true
                }
            } label: {
                Label("Delete Canvas", systemImage: "trash")
            }
            .disabled(state.workspaces.count <= 1)
        } label: {
            HStack(spacing: 4) {
                Text(state.workspace.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch, create, or manage canvases")
    }

    /// Canvas backdrop switcher. The selection persists; a checkmark marks the
    /// active theme (inline Picker inside a Menu).
    private var themeMenu: some View {
        Menu {
            Picker("Canvas Theme", selection: $state.canvasTheme) {
                ForEach(CanvasTheme.allCases) { theme in
                    Label(theme.displayName, systemImage: theme.glyph).tag(theme)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Canvas theme")
    }

    private func launchAgent(_ kind: AgentKind) {
        state.presentNewAgent(kind: kind)
    }

    private func toolButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .help(help)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1, height: 16)
    }

    private var chromeBackground: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blending: .behindWindow)
            Theme.chromeFill
        }
    }
}

/// Shared icon-button styling for chrome controls.
struct ChromeIconButtonStyle: ButtonStyle {
    var tint: Color = Theme.textSecondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(configuration.isPressed ? Color.white.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
    }
}
