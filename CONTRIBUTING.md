# Contributing to AIWorkstation

Thanks for your interest! AIWorkstation is a native macOS app — plain SwiftUI +
AppKit with no exotic dependencies — so getting started is just opening it in Xcode.

## Getting set up

**Requirements** (see the [README](README.md#requirements) for detail):

- **Xcode 26+** to build (the app imports Apple's `FoundationModels`, which only
  exists in the macOS 26 SDK).
- **macOS 15+** on an **Apple Silicon** Mac to run.
- The agent CLIs on your `PATH`: [`claude`](https://docs.anthropic.com/en/docs/claude-code) and/or [`codex`](https://github.com/openai/codex).

```bash
git clone https://github.com/<your-username>/AIWorkstation.git
cd AIWorkstation
open AIWorkstation.xcodeproj      # then ⌘R
```

Swift Package Manager resolves [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) on first build — no manual steps.

## Submitting a change

1. **Fork** the repo and create a branch off `main` (`fix/…`, `feat/…`).
2. Make a **focused** change — one concern per PR is easiest to review.
3. **Build clean** before you open the PR:
   ```bash
   xcodebuild -project AIWorkstation.xcodeproj -scheme AIWorkstation -configuration Debug build
   ```
4. Open a **pull request against `main`** with a short description of what and why.
5. Every PR is reviewed by the maintainer ([@sbaruwal](https://github.com/sbaruwal)) — you'll be tagged automatically via `CODEOWNERS`. A maintainer approval is required before merge.

## Style & scope

- **Match the surrounding code.** Follow the existing naming, comment density, and idioms in the file you're editing.
- **Respect the module boundaries** — `Canvas/`, `Terminal/`, `Agent/`, `Browser/`, `Git/`, `Chrome/`, `DesignSystem/`, etc. each have a clear job.
- **Comments explain *why*, not *what*.** Keep them tidy.
- **No new third-party dependencies** without discussing it first in an issue.
- **Keep it local-first.** No backend, no telemetry, no accounts — that's a core principle. The app drives the user's *own* installed agent CLIs; it is not a planner or autonomous orchestrator.

## Reporting bugs / ideas

Open an issue with what you saw, what you expected, your macOS + Xcode versions, and steps to reproduce. Screenshots help.

## License

By contributing, you agree that your contributions are licensed under the project's [MIT License](LICENSE).
