import SwiftUI

/// A browser node on the canvas — a glass card hosting an embedded web view with a
/// nav bar. Mirrors `PanelCardView`'s chrome/gestures (drag header, resize corner,
/// bring-to-front, close) but renders web content instead of a terminal.
struct BrowserCardView: View {
    @ObservedObject var state: CanvasState
    @ObservedObject var controller: BrowserController
    let panel: PanelModel
    let theme: CanvasTheme
    let isSelected: Bool
    let zoom: CGFloat

    @State private var hovering = false
    @State private var dragStartOrigin: CGPoint?
    @State private var resizeStartSize: CGSize?

    var body: some View {
        VStack(spacing: 0) {
            header
            navBar
            ZStack {
                WebHostView(controller: controller)
                    // Pages expect an opaque backdrop — but only while shown. In Focus
                    // Mode the web view is hidden (so it can't punch through the overlay),
                    // so drop the white (which would be a blank hole where the card peeks
                    // past the cockpit) and let the card's themed glass show through.
                    .background(controller.isSuppressed ? Color.clear : Color.white)
                if controller.isSuppressed { pausedOverlay }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(state.accent)
            if !panel.name.isEmpty {
                Text(panel.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("·").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            Text(controller.displayTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle)

            Spacer(minLength: 8)

            if controller.isLoading {
                ProgressView().controlSize(.mini)
            }
            if hovering {
                headerButton("arrow.clockwise", help: "Reload") { controller.reload() }
                headerButton("xmark", help: "Close") { state.removePanel(panel.id) }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.cardHeaderHeight)
        .background(Theme.cardHeaderFill)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { focus() }
        .gesture(moveGesture)
        .contextMenu { headerMenu }
    }

    @ViewBuilder private var headerMenu: some View {
        Button { controller.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
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
        Button(role: .destructive) { state.removePanel(panel.id) } label: { Label("Close", systemImage: "xmark") }
    }

    // MARK: Nav bar

    private var navBar: some View {
        HStack(spacing: 8) {
            navButton("chevron.left", enabled: controller.canGoBack) { controller.goBack() }
            navButton("chevron.right", enabled: controller.canGoForward) { controller.goForward() }
            navButton("arrow.clockwise", enabled: true) { controller.reload() }

            TextField("Search or enter address", text: $controller.addressText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textPrimary)
                .onSubmit { controller.loadAddress() }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Color.black.opacity(0.22), in: Capsule())
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.cardHeaderFill.opacity(0.6))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
    }

    private func navButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? Theme.textSecondary : Theme.textTertiary.opacity(0.5))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
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

    private var cardBackground: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blending: .withinWindow)
            theme.cardTint
        }
    }

    /// Covers the (hidden) web area while this browser is paused for Focus Mode, so the
    /// card reads as intentionally parked rather than blank. Purely decorative.
    private var pausedOverlay: some View {
        VStack(spacing: 6) {
            Image(systemName: "pause.circle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("Paused in Focus Mode")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
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
                    state.draggingPanelID = panel.id
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
