# Releasing AIWorkstation

How to cut a signed + **notarized** macOS build that opens on any Mac without the
"unidentified developer" / "damaged" Gatekeeper wall.

Two paths:

- **Local (recommended):** `scripts/release.sh` on your Mac. Reliable, because your machine
  already has Xcode 26 (the macOS 26 SDK that `FoundationModels` needs) and your Developer ID
  cert in the keychain.
- **CI:** `.github/workflows/release.yml` on a tag push. Convenient once it works, but hosted
  runners may not carry Xcode 26 yet — see the caveat in that file.

---

## One-time setup

### 1. Developer ID Application certificate
Xcode → Settings → Accounts → (your team) → **Manage Certificates** → **+** →
**Developer ID Application**. Confirm it landed:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. App Store Connect API key (for notarization)
App Store Connect → **Users and Access** → **Integrations** → **App Store Connect API** →
**+**. Give it the **Developer** role. Download the `AuthKey_XXXXXXXXXX.p8` (you only get one
download) and note the **Key ID** and **Issuer ID**.

Store it as a reusable keychain profile so no keys live in scripts:

```sh
xcrun notarytool store-credentials AIWorkstation \
  --key ~/path/AuthKey_XXXXXXXXXX.p8 \
  --key-id <KEY_ID> \
  --issuer <ISSUER_ID>
```

The script defaults to the profile name `AIWorkstation` (override with `NOTARY_PROFILE`).

### 3. Nicer DMG (optional)
```sh
brew install create-dmg   # script falls back to hdiutil if absent
```

---

## Cut a release (local)

```sh
./scripts/release.sh 0.1.0
```

It archives Release with hardened runtime + secure timestamp, exports a Developer-ID-signed
`.app`, builds `build/AIWorkstation-0.1.0.dmg`, notarizes, and staples. On success it prints
the DMG path + sha256. Then publish:

```sh
gh release create v0.1.0 build/AIWorkstation-0.1.0.dmg --generate-notes
```

> If `xcodebuild -version` in the script output isn't 26.x, your `xcode-select` points at the
> wrong Xcode. Fix it for the run:
> `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./scripts/release.sh 0.1.0`

### Verify it'll open clean
```sh
xcrun stapler validate build/AIWorkstation-0.1.0.dmg
spctl -a -vvv -t install build/AIWorkstation-0.1.0.dmg   # expects "accepted / Notarized Developer ID"
```
Best check: open the DMG on a Mac that never built the app.

---

## Cut a release (CI)

Add these repo **Secrets** (Settings → Secrets and variables → Actions):

| Secret | What |
| --- | --- |
| `MACOS_CERT_P12_BASE64` | `base64 -i DeveloperID.p12 \| pbcopy` — export the cert+key from Keychain Access as `.p12` first |
| `MACOS_CERT_PASSWORD` | the password you set on that `.p12` |
| `MACOS_TEAM_ID` | your 10-char Apple Team ID (`security find-identity` shows it in parens) |
| `MACOS_NOTARY_KEY_ID` | App Store Connect API **Key ID** |
| `MACOS_NOTARY_ISSUER_ID` | App Store Connect **Issuer ID** |
| `MACOS_NOTARY_KEY_P8_BASE64` | `base64 -i AuthKey_XXXX.p8 \| pbcopy` |

Then push a tag — the workflow archives, notarizes, and attaches the DMG to the release:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

> Hosted-runner caveat: if `macos-15` lacks Xcode 26 the build fails at compile. Either wait
> for the image to ship it, or register your Mac as a **self-hosted runner** and change
> `runs-on:` to its label.

---

## Homebrew

The tap is live at **[sbaruwal/homebrew-tap](https://github.com/sbaruwal/homebrew-tap)**, so users install with:

```sh
brew install --cask sbaruwal/tap/aiworkstation
```

**On each release**, after `release.sh` + `gh release create`, bump both casks with one command:

```sh
./scripts/bump-cask.sh <version>      # e.g. ./scripts/bump-cask.sh 0.1.1
```

It reads the sha256 from `build/AIWorkstation-<version>.dmg`, then updates **and pushes** both the
tap's `Casks/aiworkstation.rb` (what `brew` reads) and this repo's
[`Casks/aiworkstation.rb`](Casks/aiworkstation.rb) mirror. Users then `brew upgrade --cask aiworkstation`.

---

## Versioning
`MARKETING_VERSION` is set per build from the script/tag argument — no need to bump it in the
Xcode project. Tag names are `vX.Y.Z`; the DMG and release drop the `v`.
