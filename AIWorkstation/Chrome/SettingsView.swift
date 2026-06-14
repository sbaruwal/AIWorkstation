import SwiftUI

/// Native preferences (⌘,). CLI detection + override, default repo folder, theme,
/// behavior toggles, and a shortcut reference.
struct SettingsView: View {
    @ObservedObject var state: CanvasState

    @State private var claudePath = AgentCLI.shared.resolvedPath(for: .claude)
    @State private var codexPath = AgentCLI.shared.resolvedPath(for: .codex)
    @State private var defaultRepo = WorkspaceStore.shared.defaultRepoFolder

    var body: some View {
        Form {
            Section("Agents") {
                cliRow(.claude, path: $claudePath)
                cliRow(.codex, path: $codexPath)
            }
            Section("Workspace") {
                LabeledContent("Default projects folder") {
                    HStack {
                        Text(defaultRepo?.path ?? "Not set").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") {
                            if let url = RepoPicker.pickDirectory() {
                                WorkspaceStore.shared.defaultRepoFolder = url
                                defaultRepo = url
                            }
                        }
                    }
                }
                LabeledContent("Worktrees folder") {
                    Text(WorkspaceStore.shared.worktreesDir.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Section("Appearance") {
                Picker("App appearance", selection: $state.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Canvas theme", selection: $state.canvasTheme) {
                    ForEach(CanvasTheme.allCases) { Text($0.displayName).tag($0) }
                }
            }
            Section("Behavior") {
                Toggle("Resume last workspace on launch", isOn: $state.autoResume)
                Toggle("Voice input", isOn: $state.voiceEnabled)
                Toggle("Notifications", isOn: $state.notificationsEnabled)
                Text("Toast + macOS notifications when an agent finishes or errors, a worktree is ready, or a CLI is missing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Read constitution.md & memory.md first", isOn: $state.injectContext)
                Text("When launching an agent, tell it to read the repo's constitution.md / memory.md (if present) before the task. The New Agent sheet can override this per launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Shortcuts") {
                shortcut("Command palette", "⌘K")
                shortcut("New Claude / Codex agent", "⌘N · ⇧⌘N")
                shortcut("New canvas · Switch to canvas N", "⌥⌘N · ⌘1–9")
                shortcut("Fit all to window", "⌘0")
                shortcut("Tidy into a grid", "⇧⌘T")
                shortcut("Focus Mode · Exit", "double-click · Esc")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 560)
    }

    private func cliRow(_ kind: AgentKind, path: Binding<String?>) -> some View {
        LabeledContent(kind.displayName) {
            HStack(spacing: 8) {
                Image(systemName: path.wrappedValue != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(path.wrappedValue != nil ? .green : .red)
                Text(path.wrappedValue ?? "Not found").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Locate…") {
                    if let url = RepoPicker.pickExecutable(message: "Locate the \(kind.displayName) CLI") {
                        AgentCLI.shared.setOverride(url.path, for: kind)
                        path.wrappedValue = url.path
                        state.retryMissingCLIs()   // un-block any panels waiting on this CLI
                    }
                }
                Button("Detect") {
                    AgentCLI.shared.setOverride(nil, for: kind)
                    path.wrappedValue = AgentCLI.shared.resolvedPath(for: kind)
                    if path.wrappedValue != nil { state.retryMissingCLIs() }
                }
            }
        }
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) { Text(keys).foregroundStyle(.secondary).font(.system(.body, design: .monospaced)) }
    }
}
