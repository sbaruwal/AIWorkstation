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
  version "0.1.2"
  sha256 "e2b5e585c817274117957559f8c0adff2c5a362569566fbbfce82130c393c7b5"

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
