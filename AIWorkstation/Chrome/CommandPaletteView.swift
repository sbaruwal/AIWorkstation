import SwiftUI

/// Global command palette (⌘K). Fuzzy-filter and run common actions: new agent,
/// fit/tidy, switch theme, focus a panel, save layout. Enter runs the top match.
struct CommandPaletteView: View {
    @ObservedObject var state: CanvasState
    let viewport: CGSize

    @State private var query = ""
    @FocusState private var focused: Bool

    private struct Command: Identifiable {
        // Explicit stable id — titles aren't guaranteed unique (two panels can share a
        // project), so deriving id from title would collide in the ForEach. A fresh
        // UUID per rebuild would instead churn identity every keystroke.
        var id: String
        let title: String
        let subtitle: String
        let icon: String
        let run: () -> Void

        init(id: String? = nil, title: String, subtitle: String, icon: String, run: @escaping () -> Void) {
            self.id = id ?? title
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.run = run
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                searchField
                Divider().overlay(Color.white.opacity(0.08))
                results
            }
            .frame(width: 540)
            .background(glass)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
            .shadow(color: Theme.cardShadow, radius: 36, y: 16)
            .padding(.top, 120)
        }
        .onAppear { focused = true }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            TextField("Type a command…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onSubmit { filtered.first?.run(); close() }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var results: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filtered) { command in
                    Button {
                        command.run()
                        close()
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: command.icon)
                                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(command.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                                Text(command.subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if filtered.isEmpty {
                    Text("No matching commands").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                        .padding(.vertical, 16)
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 360)
    }

    private var filtered: [Command] {
        guard !query.isEmpty else { return commands }
        return commands.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    private var commands: [Command] {
        var list: [Command] = [
            Command(title: "New Claude agent", subtitle: "Open the New Agent flow", icon: "sparkle") {
                state.presentNewAgent(kind: .claude)
            },
            Command(title: "New Codex agent", subtitle: "Open the New Agent flow", icon: "chevron.left.forwardslash.chevron.right") {
                state.presentNewAgent(kind: .codex)
            },
            Command(title: "Fit all to window", subtitle: "Frame every card", icon: "arrow.up.left.and.arrow.down.right") {
                state.centerWorkspace(viewportSize: viewport)
            },
            Command(title: "Tidy into a grid", subtitle: "Arrange the cards neatly", icon: "rectangle.3.group") {
                state.autoTidy(viewportSize: viewport)
            },
            Command(title: "Save layout", subtitle: "Snapshot the workspace", icon: "square.and.arrow.down") {
                state.persist()
            }
        ]
        for theme in CanvasTheme.allCases {
            list.append(Command(title: "Theme: \(theme.displayName)", subtitle: "Switch the canvas backdrop", icon: theme.glyph) {
                state.canvasTheme = theme
            })
        }
        for panel in state.panels {
            let label = panel.name.isEmpty ? panel.project : panel.name
            list.append(Command(id: "focus-\(panel.id)", title: "Focus \(label)", subtitle: panel.headerTitle, icon: panel.isBrowser ? "globe" : panel.kind.glyph) {
                state.selection = panel.id
                state.bringToFront(panel.id)
                state.centerCamera(on: CGPoint(x: panel.worldFrame.midX, y: panel.worldFrame.midY), viewportSize: viewport)
            })
        }
        return list
    }

    private func close() { state.showCommandPalette = false }

    private var glass: some View {
        ZStack { VisualEffectView(material: .hudWindow, blending: .behindWindow); Theme.chromeFill }
    }
}
