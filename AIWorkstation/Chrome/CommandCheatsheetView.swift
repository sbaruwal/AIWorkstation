import SwiftUI

/// A compact reference for the command-bar grammar, shown in a popover from the
/// command bar's "?" button. Keeps the single-field composer discoverable: every
/// thing you can type is documented here, grouped by intent. Examples use real
/// node names so they read like something you'd actually type.
struct CommandCheatsheetView: View {
    /// Live node names on the current canvas, so the examples reference real nodes
    /// when there are any (falls back to a friendly placeholder otherwise).
    let nodeNames: [String]

    private var sampleName: String { nodeNames.first ?? "Bluesky" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(
                        "Start an agent",
                        rows: [
                            ("claude <task>", "New Claude agent on the chosen repo"),
                            ("codex <task>", "New Codex agent"),
                            ("cc <task>", "Shorthand for Claude"),
                            ("<just a task>", "Uses the last agent you started"),
                        ]
                    )
                    section(
                        "Open a browser",
                        rows: [
                            ("open <site> in browser", "e.g. open figma in browser"),
                            ("open github.com", "A bare URL opens directly"),
                            ("browser <site>", "Same thing, fewer words"),
                        ]
                    )
                    section(
                        "Talk to a node — by name",
                        subtitle: "Names are case-insensitive; a 3-letter prefix is enough.",
                        rows: [
                            ("\(sampleName) <message>", "Send a follow-up to that agent"),
                            ("\(sampleName) <url>", "Point that browser at a site"),
                            ("tell \(sampleName) <message>", "Same as above, spelled out"),
                            ("@\(sampleName) <message>", "Or  \(sampleName.lowercased()): <message>"),
                        ]
                    )
                    section(
                        "Control a node",
                        rows: [
                            ("focus \(sampleName.lowercased())", "Open that agent in Focus Mode"),
                            ("\(sampleName) close", "Close it  ·  also  close \(sampleName.lowercased())"),
                            ("\(sampleName) stop", "Interrupt agent / stop page load"),
                            ("\(sampleName) restart", "Restart agent / reload page"),
                            ("\(sampleName)", "Just the name → select & bring forward"),
                        ]
                    )
                    section(
                        "Site shortcuts",
                        subtitle: "Type the keyword instead of the URL.",
                        rows: [
                            ("hn", "Hacker News"),
                            ("gh / github", "GitHub"),
                            ("yt / youtube", "YouTube"),
                            ("anything else", "Falls back to a Google search"),
                        ]
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .frame(width: 360, height: 460)
        .background(Theme.chromeFill)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "command")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text("Command Bar")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("⌘K palette")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.04))
    }

    private func section(_ title: String, subtitle: String? = nil, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textSecondary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 1)
            }
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.0)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 150, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
