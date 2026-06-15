import SwiftUI

/// Command composer, floating bottom-center. Type (or dictate) a single
/// command — `claude fix the bug`, `codex`, `open google in browser`, or just a task
/// — and the parser routes it to an agent terminal or a browser. No agent dropdown:
/// the leading word picks the agent; the on-device model handles fuzzy phrasing.
struct CommandBarView: View {
    @ObservedObject var state: CanvasState
    let viewportSize: CGSize

    @State private var task = ""
    @State private var autoRun = true
    @State private var dictationBase = ""     // field text captured when dictation starts
    @State private var showHelp = false
    @StateObject private var voice = VoiceInput()
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            repoButton
            divider

            TextField(placeholder, text: $task)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onSubmit(submit)

            if state.voiceEnabled { micButton }

            helpButton

            sparkleIndicator

            // Auto-run toggle: ON → agent runs the task immediately;
            // OFF → task is pre-filled in the agent for you to review and send.
            Button { autoRun.toggle() } label: {
                Image(systemName: autoRun ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(autoRun ? state.accent : Theme.textTertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(autoRun ? "Auto-run the task on launch" : "Pre-fill the task; review before running")

            Button(action: submit) {
                if state.isParsingCommand {
                    ProgressView().controlSize(.small).tint(state.accent).frame(width: 21, height: 21)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 21))
                        .foregroundStyle(state.accent)
                }
            }
            .buttonStyle(.plain)
            .disabled(state.isParsingCommand)
            .help("Run command")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 640)
        .background(chromeBackground)
        .clipShape(Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.chromeStroke, lineWidth: 1))
        .shadow(color: Theme.cardShadow, radius: 20, y: 9)
    }

    private var placeholder: String {
        // Kept intentionally minimal — the full command grammar lives in the "?" help
        // popover, so the bar stays uncluttered.
        voice.isRecording ? "Listening…" : "Type a command…"
    }

    /// On-device parsing (Apple Foundation Models) status: dim when unavailable,
    /// secondary when available, accent when the last command was resolved by it.
    private var sparkleIndicator: some View {
        let available = state.foundationModelAvailable
        let used = state.lastCommandUsedModel
        return Image(systemName: "sparkles")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(!available ? Theme.textTertiary.opacity(0.35)
                             : (used ? state.accent : Theme.textSecondary))
            .scaleEffect(used ? 1.12 : 1)
            .animation(.easeInOut(duration: 0.2), value: used)
            .help(!available
                  ? "On-device parsing unavailable — enable Apple Intelligence in System Settings"
                  : (used ? "Last command parsed on-device (Apple Intelligence)"
                          : "On-device parsing available (Apple Intelligence)"))
    }

    /// "?" popover documenting the full command grammar — keeps the single-field
    /// composer discoverable without a visible cheatsheet cluttering the canvas.
    private var helpButton: some View {
        Button { showHelp.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(showHelp ? state.accent : Theme.textSecondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help("What can I type?")
        .popover(isPresented: $showHelp, arrowEdge: .top) {
            CommandCheatsheetView(nodeNames: state.panels.compactMap { $0.name.isEmpty ? nil : $0.name })
        }
    }

    /// Push-to-talk: hold to record, release to stop. Transcript flows into the field.
    private var micButton: some View {
        Image(systemName: voice.isRecording ? "mic.fill" : "mic")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(voice.isRecording ? Color(red: 0.95, green: 0.42, blue: 0.42) : Theme.textSecondary)
            .frame(width: 24, height: 24)
            .background(voice.isRecording ? Color.red.opacity(0.14) : .clear, in: Circle())
            .scaleEffect(voice.isRecording ? 1.12 : 1)
            .animation(.easeInOut(duration: 0.18), value: voice.isRecording)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !voice.isRecording {
                            dictationBase = task.isEmpty ? "" : task + " "
                            voice.start()
                        }
                    }
                    .onEnded { _ in voice.stop() }
            )
            .help(voice.unavailableReason ?? "Hold to dictate")
            .onChange(of: voice.transcript) { _, newValue in
                if !newValue.isEmpty { task = dictationBase + newValue }
            }
    }

    private var repoButton: some View {
        Button {
            if let url = RepoPicker.pickDirectory() { state.defaultRepo = url }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Text(state.defaultRepo?.lastPathComponent ?? "Choose repo")
                    .font(.system(size: 12))
                    .foregroundStyle(state.defaultRepo == nil ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help("Repo agents launch in (browser commands don't need one)")
        .fixedSize()
    }

    private func submit() {
        let text = task
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        task = ""
        Task { await state.runCommand(text, repo: state.defaultRepo, autoRun: autoRun, viewportSize: viewportSize) }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1, height: 18)
    }

    private var chromeBackground: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blending: .behindWindow)
            Theme.chromeFill
        }
    }
}
