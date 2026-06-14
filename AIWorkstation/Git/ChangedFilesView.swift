import SwiftUI

/// Popover listing `git status` for a panel's working directory (worktree or repo).
/// Fetches lazily on appear / refresh — never on every render.
struct ChangedFilesView: View {
    let directory: String

    @State private var files: [ChangedFile] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Changed Files")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if loaded {
                    Text("\(files.count)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                Button(action: reload) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().overlay(Color.white.opacity(0.08))

            Group {
                if !loaded {
                    placeholder("Reading repo…")
                } else if files.isEmpty {
                    placeholder("No changes")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(files) { file in
                                HStack(spacing: 8) {
                                    Text(file.status.replacingOccurrences(of: " ", with: "·"))
                                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(tint(file))
                                        .frame(width: 22, alignment: .leading)
                                    Text(file.path)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .frame(maxHeight: 280)
                }
            }
        }
        .frame(width: 330)
        .onAppear(perform: reload)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
    }

    private func reload() {
        // git runs off the main thread (it blocks); publish the result back on main.
        let dir = directory
        Task { @MainActor in
            let result = await Task.detached { GitManager.shared.changedFiles(at: dir) }.value
            files = result
            loaded = true
        }
    }

    private func tint(_ file: ChangedFile) -> Color {
        if file.isUntracked { return SessionStatus.waiting.tint }
        let x = file.status.first ?? " "
        switch x {
        case "A": return SessionStatus.done.tint
        case "D": return SessionStatus.error.tint
        case "M", "R", "C": return Theme.accent
        default:  return Theme.textSecondary
        }
    }
}
