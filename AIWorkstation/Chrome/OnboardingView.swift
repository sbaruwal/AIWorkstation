import SwiftUI

/// First-run onboarding: detect the CLIs, pick a projects
/// folder, start. Under 60 seconds, no account creation, no cloud.
struct OnboardingView: View {
    @ObservedObject var state: CanvasState

    @State private var claudeFound = AgentCLI.shared.isAvailable(.claude)
    @State private var codexFound = AgentCLI.shared.isAvailable(.codex)
    @State private var folder = WorkspaceStore.shared.defaultRepoFolder

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to AI Workstation").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    Text("Run Claude Code and Codex as real terminal agents on one canvas.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }

                detectRow(.claude, found: $claudeFound)
                detectRow(.codex, found: $codexFound)

                VStack(alignment: .leading, spacing: 6) {
                    Text("DEFAULT PROJECTS FOLDER").font(.system(size: 9.5, weight: .bold)).tracking(0.6).foregroundStyle(Theme.textTertiary)
                    HStack {
                        Text(folder?.path ?? "Optional — choose where your repos live")
                            .font(.system(size: 12)).foregroundStyle(folder == nil ? Theme.textTertiary : Theme.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") {
                            if let url = RepoPicker.pickDirectory() {
                                WorkspaceStore.shared.defaultRepoFolder = url
                                folder = url
                            }
                        }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(.system(size: 12, weight: .medium))
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }

                HStack {
                    Spacer()
                    Button { state.completeOnboarding() } label: {
                        Text("Get Started").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 22).padding(.vertical, 9)
                            .background(Theme.accent, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
            .padding(26)
            .frame(width: 480)
            .background(glass)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
            .shadow(color: Theme.cardShadow, radius: 40, y: 18)
        }
    }

    private func detectRow(_ kind: AgentKind, found: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: found.wrappedValue ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(found.wrappedValue ? SessionStatus.done.tint : SessionStatus.waiting.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(kind.displayName) CLI").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text(found.wrappedValue ? (AgentCLI.shared.resolvedPath(for: kind) ?? "") : "Not found — install it, or locate the binary")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if !found.wrappedValue {
                Button("Locate…") {
                    if let url = RepoPicker.pickExecutable(message: "Locate the \(kind.displayName) CLI") {
                        AgentCLI.shared.setOverride(url.path, for: kind)
                        found.wrappedValue = AgentCLI.shared.isAvailable(kind)
                        if found.wrappedValue { state.retryMissingCLIs() }
                    }
                }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(.system(size: 12, weight: .medium))
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var glass: some View {
        ZStack { VisualEffectView(material: .hudWindow, blending: .behindWindow); Theme.chromeFill }
    }
}
