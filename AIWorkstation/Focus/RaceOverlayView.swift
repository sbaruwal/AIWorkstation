import SwiftUI

/// The race compare deck: one prompt run across N agents, each in its own worktree forked
/// from a snapshotted base commit, shown side-by-side. Each column = the racer's live
/// status + cost + test result + its net diff vs the base, and a "Keep this one" that
/// merges that worktree and discards the rest. The defining "diff two PRs in one window"
/// surface. Closing the deck (×) leaves the race running; "Discard all" tears it down.
struct RaceOverlayView: View {
    @ObservedObject var state: CanvasState
    @State private var confirmingDiscard = false

    var body: some View {
        if let race = state.activeRace {
            ZStack {
                Color.black.opacity(0.6).ignoresSafeArea()   // no tap-to-close — too easy to lose the deck
                VStack(spacing: 0) {
                    header(race)
                    Divider().overlay(Color.white.opacity(0.08))
                    HStack(spacing: 0) {
                        ForEach(Array(race.racers.enumerated()), id: \.element.id) { idx, racer in
                            if idx > 0 { Divider().overlay(Color.white.opacity(0.08)) }
                            RaceColumn(state: state, racer: racer)
                        }
                    }
                }
                .background(backdrop)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.chromeStroke, lineWidth: 1))
                .shadow(color: Theme.cardShadow, radius: 36, y: 16)
                .padding(EdgeInsets(top: 56, leading: 24, bottom: 24, trailing: 24))
            }
            .transition(.opacity)
            .confirmationDialog("Discard this race?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard all", role: .destructive) { state.discardRace() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Closes every racer and removes its worktree. Nothing is merged.")
            }
        }
    }

    private func header(_ race: AgentRace) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "flag.checkered").font(.system(size: 13, weight: .semibold)).foregroundStyle(state.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(race.prompt)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                Text("racing \(race.racers.count) agents · from \(race.baseBranch) @ \(String(race.baseSHA.prefix(7)))")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            headerButton("Run tests", "checkmark.diamond") { state.runRaceTests() }
            headerButton("Discard all", "trash", tint: SessionStatus.error.tint) { confirmingDiscard = true }
            Button { state.showRaceOverlay = false } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textTertiary)
                    .frame(width: 26, height: 26)
            }.buttonStyle(.plain).help("Close (the race keeps running)")
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func headerButton(_ label: String, _ icon: String, tint: Color = Theme.textSecondary, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.white.opacity(0.06), in: Capsule())
        }.buttonStyle(.plain)
    }

    private var backdrop: some View {
        ZStack { VisualEffectView(material: .hudWindow, blending: .behindWindow); Theme.chromeFill }
    }
}

/// One racer's column: live header (status/cost/tests) + its diff + Keep-this-one.
private struct RaceColumn: View {
    @ObservedObject var state: CanvasState
    let racer: AgentRace.Racer

    @State private var diffLines: [DiffRow] = []
    @State private var usage: UsageLedger.Usage?
    @State private var loading = false

    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    struct DiffRow: Identifiable { let id: Int; let text: String; let color: Color; let bg: Color }

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider().overlay(Color.white.opacity(0.06))
            diffScroll
            Divider().overlay(Color.white.opacity(0.06))
            keepBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await reload() }
        .onReceive(refreshTimer) { _ in
            // Keep the diff fresh while the racer is still producing output.
            if controller?.displayStatus == .working { Task { await reload() } }
        }
    }

    private var controller: TerminalController? { state.terminals.existingController(for: racer.id) }

    private var columnHeader: some View {
        // Poll for live status/duration (cheap; avoids nested-observable plumbing).
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let status = controller?.displayStatus ?? .idle
            HStack(spacing: 8) {
                Circle().fill(status.tint).frame(width: 7, height: 7)
                Image(systemName: racer.kind.glyph).font(.system(size: 10, weight: .semibold)).foregroundStyle(racer.kind.tint)
                Text(racer.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 6)
                testBadge
                if let u = usage {
                    Text(UsageLedger.formatTokens(u.totalTokens)).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textTertiary)
                        .help("Approx. local tokens for this racer")
                }
                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }.buttonStyle(.plain).help("Refresh diff")
                Button { state.revealAgent(racer.id); state.showRaceOverlay = false } label: {
                    Image(systemName: "terminal").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }.buttonStyle(.plain).help("Open this racer's terminal")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
    }

    @ViewBuilder private var testBadge: some View {
        if state.raceTesting.contains(racer.id) {
            ProgressView().controlSize(.mini)
        } else if let r = state.raceTestResults[racer.id] {
            Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(r.passed ? SessionStatus.done.tint : SessionStatus.error.tint)
                .help(r.passed ? "Tests passed" : "Tests failed · exit \(r.exitCode)")
        }
    }

    private var diffScroll: some View {
        ScrollView([.vertical, .horizontal]) {
            if diffLines.isEmpty {
                Text(loading ? "Loading diff…" : "No changes yet")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).padding(14)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diffLines) { row in
                        Text(row.text)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(row.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .background(row.bg)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var keepBar: some View {
        let preparing = controller?.runState == .preparing
        return Button { state.keepRaceWinner(racer.id) } label: {
            Label(preparing ? "Preparing…" : "Keep this one", systemImage: preparing ? "hourglass" : "checkmark")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background((preparing ? Color.gray : SessionStatus.done.tint).opacity(0.9),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(preparing)
        .padding(10)
    }

    @MainActor private func reload() async {
        // Skip while the worktree is still checking out (the dir doesn't exist yet).
        guard !loading, controller?.runState != .preparing else { return }
        loading = true
        let diff = await state.raceDiff(for: racer.id)
        diffLines = Self.parse(diff, accent: state.accent)
        let kind = racer.kind, wt = racer.worktree
        usage = await Task.detached { UsageLedger.usage(for: kind, cwd: wt) }.value
        loading = false
    }

    /// Pre-parse + pre-style the diff (mirrors FocusMode's renderer), capped for big diffs.
    private static func parse(_ diff: String, accent: Color) -> [DiffRow] {
        guard !diff.isEmpty else { return [] }
        let raw = diff.split(separator: "\n", omittingEmptySubsequences: false)
        var rows: [DiffRow] = []
        let cap = 3000
        for (i, sub) in raw.prefix(cap).enumerated() {
            let line = String(sub)
            rows.append(DiffRow(id: i, text: line.isEmpty ? " " : line, color: color(line, accent), bg: bg(line)))
        }
        if raw.count > cap {
            rows.append(DiffRow(id: cap, text: "… \(raw.count - cap) more lines", color: Theme.textTertiary, bg: .clear))
        }
        return rows
    }
    private static func color(_ line: String, _ accent: Color) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color(red: 0.45, green: 0.85, blue: 0.55) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Color(red: 0.95, green: 0.5, blue: 0.5) }
        if line.hasPrefix("@@") { return accent }
        if line.hasPrefix("diff ") || line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("index ") { return Theme.textTertiary }
        return Theme.textSecondary
    }
    private static func bg(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color(red: 0.2, green: 0.6, blue: 0.3).opacity(0.10) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Color(red: 0.7, green: 0.25, blue: 0.25).opacity(0.10) }
        return .clear
    }
}
