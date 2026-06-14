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
/// to flush the workspace synchronously so the last edits are never lost.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: CanvasState?

    func applicationWillTerminate(_ notification: Notification) {
        // Always invoked on the main thread; assert that so we can touch the
        // @MainActor state synchronously before the process exits.
        MainActor.assumeIsolated {
            state?.persist(synchronously: true)
        }
    }
}
