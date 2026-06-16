import SwiftUI

@main
struct AIWorkstationApp: App {
    @StateObject private var state = CanvasState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CanvasView(state: state)
                .frame(minWidth: 820, minHeight: 560)
                .preferredColorScheme(state.appearance.colorScheme)   // nil → follow system
                .ignoresSafeArea()
                .onAppear { appDelegate.state = state }
                .onDisappear { state.persist(synchronously: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)
        .commands {
            // Replace default "New" with our canvas action wiring (the real
            // shortcuts live in CanvasView where the viewport size is known).
            CommandGroup(replacing: .newItem) {}
        }
        // Flush when the app is backgrounded/hidden — a debounced autosave may have
        // edits still pending, and `.onDisappear` alone is unreliable on ⌘Q.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { state.persist(synchronously: true) }
        }

        // Native preferences window (⌘,).
        Settings {
            SettingsView(state: state)
        }
    }
}

/// Catches `applicationWillTerminate` — the one hook guaranteed to fire on ⌘Q —
/// to flush the workspace synchronously so the last edits are never lost. Also owns the
/// global summon hotkey.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: CanvasState?
    private var summonHotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⌃⌥Space from anywhere → summon the canvas to the front (press again to dismiss).
        summonHotKey = GlobalHotKey.summon {
            Task { @MainActor in AppDelegate.toggleVisibility() }
        }
    }

    /// Summon the app forward, or hide it if it's already active — a Quake-console-style
    /// toggle so the canvas is one keystroke away from any app and one keystroke gone.
    @MainActor static func toggleVisibility() {
        // Hide only when active AND already showing a real window; otherwise SUMMON —
        // un-hide, activate, deminiaturize a Dock-minimized window (makeKeyAndOrderFront
        // alone won't restore one), and bring a window to the front.
        let hasLiveWindow = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
        if NSApp.isActive && hasLiveWindow {
            NSApp.hide(nil)
        } else {
            NSApp.unhide(nil)
            NSApp.activate()
            for w in NSApp.windows where w.isMiniaturized { w.deminiaturize(nil) }
            (NSApp.windows.first { $0.canBecomeKey } ?? NSApp.windows.first)?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Always invoked on the main thread; assert that so we can touch the
        // @MainActor state synchronously before the process exits.
        MainActor.assumeIsolated {
            state?.persist(synchronously: true)
        }
    }
}
