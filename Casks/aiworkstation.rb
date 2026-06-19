# Homebrew cask for AIWorkstation.
#
# The LIVE copy users install from lives in the tap repo https://github.com/sbaruwal/homebrew-tap
# (Casks/aiworkstation.rb). This file is the source mirror — keep both in sync on each release.
#
#     brew install --cask sbaruwal/tap/aiworkstation
#
# Per release: bump `version` and `sha256` to match the notarized DMG
# (`shasum -a 256 build/AIWorkstation-<version>.dmg`), then push it to the tap.
cask "aiworkstation" do
  version "0.1.1"
  sha256 "cc4e4ce1ea902969a181185243a4a559a279fc88dc1fc9fe6fa70719c2b04a99"

  url "https://github.com/sbaruwal/AIWorkstation/releases/download/v#{version}/AIWorkstation-#{version}.dmg"
  name "AIWorkstation"
  desc "Native macOS canvas for running multiple AI coding agents side by side"
  homepage "https://github.com/sbaruwal/AIWorkstation"

  depends_on macos: :sequoia # macOS 15+ (bare symbol = minimum version)

  app "AIWorkstation.app"

  zap trash: [
    "~/Library/Application Support/AIWorkstation",
    "~/Library/Preferences/com.aiworkstation.app.plist",
  ]
end
