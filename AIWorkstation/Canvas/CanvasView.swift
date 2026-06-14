import SwiftUI
import UniformTypeIdentifiers

/// The free infinite canvas: a themed backdrop with
/// freely positioned, draggable/resizable, overlap-capable glass agent cards;
/// trackpad pan + pinch zoom; a minimap to navigate. The window is a viewport
/// onto the canvas — cards keep their positions; you pan/zoom (or hit Fit) to
/// frame them.
struct CanvasView: View {
    @ObservedObject var state: CanvasState

    @State private var topHovering = false
    @State private var toolbarHovering = false
    @State private var leftEdgeHovering = false
    @State private var dropTargeted = false

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size

            ZStack(alignment: .topLeading) {
                CanvasBackgroundView(theme: state.canvasTheme, camera: state.camera)

                contentLayer(viewport: viewport)

                CanvasEventCatcher(
                    panelScreenFrames: state.panels.map { state.camera.screenRect($0.worldFrame) },
                    onScrollPan: { delta in state.panBy(delta) },
                    onMagnify: { mag, anchor in state.zoom(by: mag, at: anchor) },
                    onDragPan: { delta in state.panBy(delta) },
                    onClickEmpty: { state.selection = nil }
                )

                overlays(viewport: viewport)

                // Focus Mode — one agent enlarged, but inset like a single fill-tile so
                // the toolbar + backdrop stay visible and it reads as in-app, not a
                // fullscreen takeover. (Same insets as the tile grid: 64 top / 92 bottom
                // / 20 sides.)
                if let id = state.focusedPanel, let focused = state.panel(id) {
                    FocusModeView(
                        state: state,
                        terminal: state.terminals.controller(for: focused),
                        panel: focused,
                        theme: state.canvasTheme
                    )
                    // Identity tied to the focused panel: switching agents tears down
                    // and rebuilds with fresh state (no stale diff / file list carried
                    // over from the previously focused agent).
                    .id(focused.id)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.cardStrokeSelected, lineWidth: 1.5))
                    .shadow(color: Theme.cardShadow, radius: 30, y: 14)
                    .padding(EdgeInsets(top: 64, leading: 20, bottom: 92, trailing: 20))
                    .frame(width: viewport.width, height: viewport.height)
                    .zIndex(200)
                }

                hiddenShortcuts(viewport: viewport)
            }
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            .clipped()
            .coordinateSpace(.named("canvas"))
            .background(Color.black)
            // Drop a folder → launch an agent in it; drop a URL/webloc → open a browser.
            .onDrop(of: [.fileURL, .url], isTargeted: $dropTargeted) { providers in
                handleDrop(providers, viewport: viewport)
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 0)
                        .strokeBorder(Theme.accent.opacity(0.8), lineWidth: 3)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                state.lastViewport = viewport
                // Fill-tile sizes the cards to the *current* view, so they're always
                // on-screen regardless of the restored camera.
                state.relayout(viewportSize: viewport)
            }
            // Reflow the grid as the window resizes so it always fills the window and
            // never crops (the column count tracks the current width).
            .onChange(of: viewport) { _, newValue in
                state.lastViewport = newValue
                state.relayout(viewportSize: newValue)
            }
        }
    }

    // MARK: Drag-and-drop onto the canvas

    private func handleDrop(_ providers: [NSItemProvider], viewport: CGSize) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let u = item as? URL { url = u }
                    else { url = nil }
                    if let url {
                        Task { @MainActor in state.handleDroppedFile(url, viewportSize: viewport) }
                    }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, (url.scheme == "http" || url.scheme == "https") {
                        Task { @MainActor in state.openBrowser(url: url, viewportSize: viewport) }
                    }
                }
            }
        }
        return handled
    }

    // MARK: Cards (free-positioned, z-ordered)

    private func contentLayer(viewport: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(state.panels) { panel in
                let origin = state.camera.worldToScreen(panel.position)
                Group {
                    if panel.isBrowser {
                        BrowserCardView(
                            state: state,
                            controller: state.browsers.controller(for: panel),
                            panel: panel,
                            theme: state.canvasTheme,
                            isSelected: state.selection == panel.id,
                            zoom: state.camera.zoom
                        )
                    } else {
                        PanelCardView(
                            state: state,
                            terminal: state.terminals.controller(for: panel),
                            panel: panel,
                            theme: state.canvasTheme,
                            isSelected: state.selection == panel.id,
                            zoom: state.camera.zoom
                        )
                    }
                }
                .scaleEffect(state.camera.zoom, anchor: .topLeading)
                .offset(x: origin.x, y: origin.y)
                .zIndex(Double(panel.zIndex))
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.panels.count)
    }

    // MARK: Floating chrome

    @ViewBuilder
    private func overlays(viewport: CGSize) -> some View {
        if state.panels.isEmpty {
            EmptyStateView(state: state, viewportSize: viewport)
                .frame(width: viewport.width, height: viewport.height)
                .transition(.opacity)
        }

        // Top toolbar (auto-hide): thin strip reveals it, toolbar's own hover keeps it.
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 24)
                .contentShape(Rectangle())
                .onHover { topHovering = $0 }
            Spacer()
        }
        VStack {
            if topHovering || toolbarHovering || state.toolbarPinned || state.panels.isEmpty {
                TopToolbarView(state: state, viewportSize: viewport)
                    .padding(.top, 14)
                    .onHover { toolbarHovering = $0 }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.easeInOut(duration: 0.2), value: topHovering)
        .animation(.easeInOut(duration: 0.2), value: toolbarHovering)
        .animation(.easeInOut(duration: 0.2), value: state.toolbarPinned)

        // Sidebar (auto-hide on left-edge hover, or pinned).
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 10)
                .contentShape(Rectangle())
                .onHover { leftEdgeHovering = $0 }
            Spacer()
        }
        HStack {
            if state.sidebarPinned || leftEdgeHovering || state.sidebarHovering {
                SidebarView(state: state, viewportSize: viewport)
                    .onHover { state.sidebarHovering = $0 }
                    .transition(.move(edge: .leading))
            }
            Spacer()
        }
        .animation(.easeInOut(duration: 0.22), value: state.sidebarPinned)
        .animation(.easeInOut(duration: 0.22), value: leftEdgeHovering)
        .animation(.easeInOut(duration: 0.22), value: state.sidebarHovering)

        // Minimap (bottom-right) — click to navigate. Lifted above the command bar.
        if state.showMinimap && !state.panels.isEmpty {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    MinimapView(
                        panels: state.panels,
                        camera: state.camera,
                        viewportSize: viewport,
                        onNavigate: { world in state.centerCamera(on: world, viewportSize: viewport) }
                    )
                    .padding(.trailing, 16)
                    .padding(.bottom, 82)
                }
            }
        }

        // Command bar (bottom-center) — the composer/launcher.
        VStack {
            Spacer()
            CommandBarView(state: state, viewportSize: viewport)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, alignment: .center)

        // Modal overlays (top-most): New Agent flow and the command palette.
        if state.newAgentDraft != nil {
            NewAgentSheet(
                // Safe binding: returns a throwaway default if it goes nil mid-update
                // (e.g. on Launch) instead of force-unwrapping and crashing.
                draft: Binding(get: { state.newAgentDraft ?? NewAgentDraft() }, set: { state.newAgentDraft = $0 }),
                state: state,
                viewport: viewport
            )
            .zIndex(100)
        }
        if state.showCommandPalette {
            CommandPaletteView(state: state, viewport: viewport)
                .zIndex(100)
        }
        if state.showOnboarding {
            OnboardingView(state: state)
                .zIndex(300)
        }

        // Transient in-app notifications (top-right), above everything else.
        ToastOverlayView(notifier: state.notifier)
            .zIndex(400)
    }

    // MARK: Keyboard shortcuts

    private func hiddenShortcuts(viewport: CGSize) -> some View {
        Group {
            Button("") { state.presentNewAgent(kind: .claude) }
                .keyboardShortcut("n", modifiers: .command)
            Button("") { state.presentNewAgent(kind: .codex) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("") { state.showCommandPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
            Button("") { state.centerWorkspace(viewportSize: viewport) }   // Fit to all
                .keyboardShortcut("0", modifiers: .command)
            Button("") { withAnimation { state.autoTidy(viewportSize: viewport) } }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("") { state.newWorkspace() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            // ⌘1…⌘9 jump straight to the Nth canvas (no-op if it doesn't exist yet).
            ForEach(1...9, id: \.self) { n in
                Button("") {
                    let idx = n - 1
                    if state.workspaces.indices.contains(idx) {
                        state.switchTo(state.workspaces[idx].id)
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Button("") { dismissTopMostOrDeselect() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func dismissTopMostOrDeselect() {
        if state.showCommandPalette { state.showCommandPalette = false }
        else if state.newAgentDraft != nil { state.newAgentDraft = nil }
        else if state.focusedPanel != nil { state.exitFocus() }
        else { state.selection = nil }
    }
}
