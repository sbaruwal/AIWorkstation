#!/usr/bin/env bash
set -euo pipefail

# Bump the Homebrew cask to a released version in BOTH places and push them:
#   • this repo's source mirror   Casks/aiworkstation.rb
#   • the live tap                sbaruwal/homebrew-tap   (the cask `brew` actually reads)
#
# It reads the sha256 straight from build/AIWorkstation-<version>.dmg, so run it AFTER
# scripts/release.sh (and after `gh release create`, so the download URL resolves).
#
# Usage:  ./scripts/bump-cask.sh 0.1.1
#   override the tap with:  TAP_REPO=https://github.com/you/homebrew-tap.git ./scripts/bump-cask.sh 0.1.1

cd "$(dirname "$0")/.."

VERSION="${1:?usage: ./scripts/bump-cask.sh <version>   (e.g. 0.1.1)}"
TAP_REPO="${TAP_REPO:-https://github.com/sbaruwal/homebrew-tap.git}"
DMG="build/AIWorkstation-$VERSION.dmg"
CASK="Casks/aiworkstation.rb"

[ -f "$DMG" ] || { echo "❌ $DMG not found — run ./scripts/release.sh $VERSION first."; exit 1; }
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "▸ AIWorkstation $VERSION  ·  sha256 $SHA"

# In-place bump of the `version "..."` and `sha256 "..."` lines (BSD sed, macOS).
bump() {
  sed -i '' -E \
    "s/^([[:space:]]*version )\"[^\"]*\"/\1\"$VERSION\"/; s/^([[:space:]]*sha256 )\"[^\"]*\"/\1\"$SHA\"/" "$1"
}

# 1) Source mirror in this repo — commit just the cask file, then push.
echo "▸ mirror: $CASK"
bump "$CASK"
if git diff --quiet -- "$CASK"; then
  echo "  (already current)"
else
  git add "$CASK"
  git commit -qm "Cask: bump to $VERSION"
  git push -q
  echo "  ✅ committed + pushed"
fi

# 2) The live tap — clone, bump, push.
echo "▸ tap: $TAP_REPO"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git clone -q "$TAP_REPO" "$TMP"
bump "$TMP/$CASK"
if git -C "$TMP" diff --quiet; then
  echo "  (already current)"
else
  git -C "$TMP" commit -qam "AIWorkstation $VERSION"
  git -C "$TMP" push -q
  echo "  ✅ pushed"
fi

echo
echo "✅ Cask is $VERSION in both places."
echo "   Verify: brew update && brew fetch --cask sbaruwal/tap/aiworkstation"
