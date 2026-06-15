import SwiftUI
import AppKit

/// A glass agent card on the free canvas, hosting a real PTY terminal.
///
/// Rendered at *world* size and scaled by the camera (zoom scales the whole card,
/// terminal included). The header is the drag handle; the bottom-right corner
/// resizes; interacting raises the card above overlapping siblings.
struct PanelCardView: View {
    @ObservedObject var state: CanvasState
    @ObservedObject var terminal: TerminalController
    let panel: PanelModel
    let theme: CanvasTheme
    let isSelected: Bool
    let zoom: CGFloat

    @State private var hovering = false
    @State private var dragStartOrigin: CGPoint?
    @State private var resizeStartSize: CGSize?
    @State private var showChanges = false
    @State private var renaming = false
    @State private var editName = ""
    @State private var pulse = false
    @FocusState private var renameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Status shown in the header reflects the real process AND live output activity
    /// (derived centrally on the controller), not stored metadata.
    private var displayStatus: SessionStatus { terminal.displayStatus }

    /// True while output is actively streaming — drives the subtle "working" pulse
    /// on the status dot so an active agent reads as alive at a glance.
    private var isWorking: Bool { displayStatus == .working }

    /// Status dot with a radar-style pulse while working (suppressed under
    /// Reduce Motion — the color alone still conveys the state).
    private var statusDot: some View {
        ZStack {
            if isWorking && !reduceMotion {
                Circle()
                    .stroke(displayStatus.tint, lineWidth: 1.5)
                    .frame(width: 7, height: 7)
                    .scaleEffect(pulse ? 2.4 : 1)
                    .opacity(pulse ? 0 : 0.7)
            }
            Circle()
                .fill(displayStatus.tint)
                .frame(width: 7, height: 7)
                .shadow(color: displayStatus.tint.opacity(0.7), radius: isWorking ? 4 : 3)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
        .onAppear { pulse = isWorking }
        .onChange(of: isWorking) { _, working in pulse = working }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            terminalBody
        }
        .frame(width: panel.width, height: panel.height)
        .background(cardBackground)
        .themedCardFrame(state.canvasTheme, isSelected: isSelected, accent: state.accent)
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        .shadow(color: Theme.cardShadow, radius: isSelected ? 26 : 16, x: 0, y: 11)
        .onHover { hovering = $0 }
    }

    private func focus() {
        state.selection = panel.id
        state.bringToFront(panel.id)
    }

    // MARK: Header (drag handle)

    private var header: some View {
        HStack(spacing: 8) {
            statusDot

            Image(systemName: panel.kind.glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(panel.kind.tint)

            if renaming {
                TextField("", text: $editName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($renameFocused)
                    .frame(maxWidth: 170)
                    .onSubmit(commitRename)
                    .onExitCommand { renaming = false }
            } else {
                HStack(spacing: 5) {
                    if !panel.name.isEmpty {
                        Text(panel.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("·").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                    Text(panel.headerDetail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if hovering {
                headerButton("arrow.up.left.and.arrow.down.right", help: "Focus Mode") { state.enterFocus(panel.id) }
                if panel.repoRoot != nil {
                    headerButton("doc.text.magnifyingglass", help: "Changed files") { showChanges.toggle() }
                }
                headerButton("stop.fill", help: "Interrupt (Ctrl+C)") { terminal.interrupt() }
                headerButton("arrow.clockwise", help: "Restart session") { terminal.restart() }
                headerButton("xmark", help: "Close panel") { state.removePanel(panel.id) }
            } else {
                Text(displayStatus.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.cardHeaderHeight)
        .background(Theme.cardHeaderFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
        .contentShape(Rectangle())
        // A single tap selects the card. Focus Mode is entered explicitly — via the
        // header focus button, the context menu, or the command bar (`focus <name>`) —
        // never a double-tap, which competed with the header buttons (you couldn't
        // reliably hit Close) and needed two tries to register.
        .onTapGesture { focus() }
        .gesture(moveGesture)
        .popover(isPresented: $showChanges, arrowEdge: .bottom) {
            ChangedFilesView(directory: panel.workingDirectory ?? panel.repoRoot ?? "")
        }
        .contextMenu { headerMenu }
    }

    @ViewBuilder private var headerMenu: some View {
        Button { state.enterFocus(panel.id) } label: { Label("Focus Mode", systemImage: "arrow.up.left.and.arrow.down.right") }
        Button { startRename() } label: { Label("Rename", systemImage: "pencil") }
        if state.canClone(panel.id) {
            Button { state.clonePanel(panel.id) } label: { Label("Clone (new worktree)", systemImage: "plus.square.on.square") }
        }
        if state.workspaces.count > 1 {
            Menu {
                ForEach(state.workspaces.filter { $0.id != state.currentWorkspaceID }) { ws in
                    Button { state.movePanel(panel.id, toCanvas: ws.id) } label: {
                        Text(ws.name.isEmpty ? "Untitled" : ws.name)
                    }
                }
            } label: { Label("Move to Canvas", systemImage: "rectangle.portrait.on.rectangle.portrait") }
        }
        Divider()
        Button { SystemOpen.finder(state.workingDir(for: panel.id)) } label: { Label("Open in Finder", systemImage: "folder") }
        Button { SystemOpen.editor(state.workingDir(for: panel.id)) } label: { Label("Open in Editor", systemImage: "chevron.left.forwardslash.chevron.right") }
        Button { SystemOpen.terminal(state.workingDir(for: panel.id)) } label: { Label("Open in Terminal", systemImage: "terminal") }
        Divider()
        Button { terminal.interrupt() } label: { Label("Interrupt (Ctrl+C)", systemImage: "stop.fill") }
        Button { terminal.restart() } label: { Label("Restart session", systemImage: "arrow.clockwise") }
        Divider()
        Button(role: .destructive) { state.removePanel(panel.id) } label: { Label("Close", systemImage: "xmark") }
    }

    private func startRename() {
        editName = panel.name
        renaming = true
        renameFocused = true
    }

    private func commitRename() {
        state.renamePanel(panel.id, to: editName)
        renaming = false
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 17, height: 17)
                .background(Color.white.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Terminal body (real PTY)

    private var terminalBody: some View {
        ZStack {
            // No opaque fill — the terminal is translucent and composites over the
            // glass card (and thus the canvas backdrop) so the theme flows through.
            // While this panel is in Focus Mode, release the PTY view so it can be
            // mounted there instead (avoids a double-mount of the same NSView).
            if state.focusedPanel == panel.id {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 18, weight: .light)).foregroundStyle(Theme.textTertiary)
                    Text("In Focus Mode").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.3))
            } else {
                TerminalHostView(controller: terminal)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
            }

            switch terminal.runState {
            case .exited(let status): exitedOverlay(status: status)
            case .needsCLI(let kind): cliMissingOverlay(kind: kind)
            case .recoverable:        recoverOverlay
            case .preparing:          preparingOverlay
            default:                  EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exitedOverlay(status: ExitStatus) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 10) {
                Image(systemName: status.isClean ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(status.isClean ? SessionStatus.done.tint : SessionStatus.error.tint)
                Text(status.isClean ? "Session ended" : "Session ended · \(status.label)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Button { terminal.restart() } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(state.accent.opacity(0.92), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func cliMissingOverlay(kind: AgentKind) -> some View {
        ZStack {
            Color.black.opacity(0.62)
            VStack(spacing: 10) {
                Image(systemName: "questionmark.app.dashed")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(SessionStatus.error.tint)
                Text("\(kind.displayName) CLI not found")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Make sure it's installed, or locate the binary manually.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Button {
                    if let url = RepoPicker.pickExecutable(message: "Locate the \(kind.displayName) CLI binary") {
                        AgentCLI.shared.setOverride(url.path, for: kind)
                        terminal.retryLaunch()
                    }
                } label: {
                    Label("Locate \(kind.displayName)…", systemImage: "folder")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(state.accent.opacity(0.92), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
    }

    private var preparingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(state.accent)
                Text("Preparing worktree…")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var recoverOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 24, weight: .light)).foregroundStyle(Theme.textSecondary)
                Text("Session ended")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text("Restored from your last workspace")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                Button { terminal.relaunch() } label: {
                    Label("Relaunch", systemImage: "play.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(state.accent.opacity(0.92), in: Capsule())
                        .foregroundStyle(.white)
                }.buttonStyle(.plain)
            }
        }
    }

    private var cardBackground: some View {
        ZStack {
            // Within-window blur samples the canvas backdrop behind the card, so
            // the theme shows through as frosted glass; theme tint colors it.
            VisualEffectView(material: .hudWindow, blending: .withinWindow)
            theme.cardTint
        }
    }

    // MARK: Resize handle

    private var resizeHandle: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(hovering ? Theme.textSecondary : Theme.textTertiary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .gesture(resizeGesture)
            .padding(3)
    }

    // MARK: Gestures (world coords via the shared "canvas" coordinate space)

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
            .onChanged { value in
                if dragStartOrigin == nil {
                    dragStartOrigin = panel.position
                    state.draggingPanelID = panel.id   // suppress auto-reflow while held
                    focus()
                }
                let world = CGPoint(
                    x: dragStartOrigin!.x + value.translation.width / zoom,
                    y: dragStartOrigin!.y + value.translation.height / zoom
                )
                let bypass = NSEvent.modifierFlags.contains(.option)
                state.movePanel(panel.id, to: world, snapping: !bypass)
            }
            .onEnded { _ in
                dragStartOrigin = nil
                state.draggingPanelID = nil
                // Snap the dropped card into the grid at its new reading-order slot
                // (drag = reorder; an off-grid drop just snaps to the nearest slot).
                state.reorderByPosition(viewportSize: state.lastViewport)
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
            .onChanged { value in
                if resizeStartSize == nil { resizeStartSize = panel.size; focus() }
                let new = CGSize(
                    width: resizeStartSize!.width + value.translation.width / zoom,
                    height: resizeStartSize!.height + value.translation.height / zoom
                )
                state.resizePanel(panel.id, to: new)
            }
            .onEnded { _ in resizeStartSize = nil }
    }
}
