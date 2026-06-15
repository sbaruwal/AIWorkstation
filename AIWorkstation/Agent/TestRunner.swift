import Foundation

/// Runs a project's test command on demand and reports the exit code + tail output.
/// Deliberately DUMB: it never auto-runs and never interprets pass/fail beyond the
/// process exit code — judging results would drift toward an autonomous QA agent (a
/// hard-stop). The command is auto-detected from project markers, overridable per repo
/// (stored locally in UserDefaults).
enum TestRunner {
    private static func key(_ dir: String) -> String { "test.command:\(dir)" }

    /// The effective command for a dir: a saved per-repo override, else a detected default.
    static func command(for dir: String) -> String {
        if let override = UserDefaults.standard.string(forKey: key(dir)), !override.isEmpty { return override }
        return detect(in: dir) ?? ""
    }

    static func setCommand(_ cmd: String, for dir: String) {
        let t = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { UserDefaults.standard.removeObject(forKey: key(dir)) }
        else { UserDefaults.standard.set(t, forKey: key(dir)) }
    }

    /// Best-guess test command from common project markers.
    static func detect(in dir: String) -> String? {
        let fm = FileManager.default
        func has(_ f: String) -> Bool { fm.fileExists(atPath: (dir as NSString).appendingPathComponent(f)) }
        if has("Package.swift") { return "swift test" }
        if has("Cargo.toml") { return "cargo test" }
        if has("package.json") { return "npm test" }
        if has("pyproject.toml") || has("pytest.ini") || has("setup.cfg") { return "pytest" }
        if has("go.mod") { return "go test ./..." }
        if has("Makefile") || has("makefile") { return "make test" }
        return nil
    }

    struct Result: Equatable {
        let exitCode: Int32
        let output: String
        var passed: Bool { exitCode == 0 }
    }

    /// Run `command` in `dir` via the user's login shell (so PATH/toolchains resolve like
    /// their terminal). BLOCKING — call from a detached task. Output is tail-truncated.
    static func run(_ command: String, in dir: String) -> Result {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-i", "-l", "-c", command]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return Result(exitCode: -1, output: error.localizedDescription) }

        // Drain on a background queue before waiting, so a large test log can't fill the
        // pipe buffer and deadlock the child (same hazard GitManager.run guards against).
        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
        }
        group.wait()
        p.waitUntilExit()

        var out = String(data: data, encoding: .utf8) ?? ""
        let maxChars = 4000   // keep the tail — test summaries live at the end
        if out.count > maxChars { out = "…\n" + String(out.suffix(maxChars)) }
        return Result(exitCode: p.terminationStatus, output: out)
    }
}
