# Homebrew cask for AIWorkstation.
#
# This file lives in YOUR tap repo, not the main repo: create a public GitHub repo named
# `homebrew-aiworkstation`, drop this at `Casks/aiworkstation.rb`, then users install with:
#
#     brew install --cask sbaruwal/aiworkstation/aiworkstation
#
# Per release: bump `version` and `sha256` to match the notarized DMG
# (`shasum -a 256 build/AIWorkstation-<version>.dmg`), then commit to the tap.
cask "aiworkstation" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/sbaruwal/AIWorkstation/releases/download/v#{version}/AIWorkstation-#{version}.dmg"
  name "AIWorkstation"
  desc "Native macOS canvas for running multiple AI coding agents side by side"
  homepage "https://github.com/sbaruwal/AIWorkstation"

  depends_on macos: ">= :sequoia" # macOS 15+

  app "AIWorkstation.app"

  zap trash: [
    "~/Library/Application Support/AIWorkstation",
    "~/Library/Preferences/com.aiworkstation.app.plist",
  ]
end
