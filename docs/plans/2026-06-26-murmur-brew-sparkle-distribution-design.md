# Murmur — Auto-build + Auto-update (Homebrew cask + Sparkle)

**Status:** design / implementation brief
**Date:** 2026-06-26
**Goal:** Ship Murmur as a signed, notarized macOS app that users install with
`brew install --cask murmur` and that updates itself in-app via Sparkle — built and
signed entirely in CI, with **zero per-app duplication** (a shared CI component every
future app reuses).

---

## 0. Decisions (already made — do not re-litigate)

| Decision | Choice | Why |
|---|---|---|
| Update topology | **Sparkle in-app updates + brew cask, self-hosted feed** | Full parity with Zamok, but no dependency on the Zamok server's uptime. Murmur is free/local → no license layer. |
| Feed/artifact host | **GitHub** (`bshk-app/homebrew-tap`) — zip as a release asset, `appcast.xml` as a raw file | Stable HTTPS, no infra. Same `--store git-release` path the Zamok cask already uses. |
| CI reuse | **One shared reusable workflow** (`zamok/ci` → `.gitea/workflows/macos-cask-release.yml`, `on: workflow_call`); each product repo has a ~10-line caller | DRY across Zamok / Murmur / AgentVault / future apps. One fix, not N. |
| Org / plumbing | Product repos + the `ci` repo live under the **`zamok` Gitea org** | The Tart runner is Organization-scoped to `zamok` and the Developer-ID / notary / tap secrets already exist there. Org name is internal plumbing — it does **not** leak into branding (cask stays `murmur`, bundle `app.bshk.murmur`, tap `bshk-app/homebrew-tap`). `zamok/zamok` itself is untouched (GitOps deploy rides on it). |
| Packaging tool | **`zamokctl`** (host-agnostic, installed from the bshk-app tap) does `package` + `cask` | Already built and proven by the Zamok cask. Murmur adds no bespoke signing code. |
| Provisioning profile | **None** | Murmur has no restricted entitlements (unlike ZamokApp's `keychain-access-groups`). Developer ID + hardened runtime + notarization is enough. |
| Signing identity | Reuse **Developer ID Application**, Team `Q8H6GWJ658` | Same Apple account as Zamok → same `.p12` + notary keys. |

**Fallback if `workflow_call` / `secrets: inherit` is unsupported on this Gitea
(1.26.2):** implement the shared component as a **composite action** (`action.yml`,
`runs.using: composite`) instead — same steps, but the caller passes secrets explicitly
as `with:` inputs. Verify support first (see §7).

---

## 1. Architecture (produce ⊥ consume)

```
  Gitea (truenas / git.bshk.app, NOT internet-exposed)        GitHub (bshk-app, public)
  ┌──────────────────────────────────────────────┐           ┌────────────────────────────┐
  │ zamok/murmur   (code)                         │           │ bshk-app/homebrew-tap       │
  │   .gitea/workflows/release.yml  ── calls ─┐   │  push     │   Casks/murmur.rb           │
  │ zamok/ci   (shared reusable workflow) ◀───┘   │ ───────▶  │   appcast/murmur.xml (raw)  │
  │   builds on the self-hosted Tart macOS runner │  (PAT)    │   releases/murmur-v*/        │
  │   zamokctl: sign → notarize → staple → zip    │           │      Murmur-<ver>.zip        │
  └──────────────────────────────────────────────┘           └────────────────────────────┘
                                                                         ▲          ▲
                                        brew install --cask murmur ──────┘          │
                                        Sparkle SUFeedURL (raw appcast) ────────────┘
```

- **Code + CI** stay on Gitea (private, behind the LAN). **Artifacts + feed** are
  published to GitHub `bshk-app/homebrew-tap` via the `TAP_GITHUB_TOKEN` PAT.
- One zip, two consumers: the cask `url` **and** the Sparkle `<enclosure url>` point at
  the same GitHub release asset.
- `SUFeedURL` (baked into the app) =
  `https://raw.githubusercontent.com/bshk-app/homebrew-tap/main/appcast/murmur.xml`
  (raw caching ~5 min is fine for an appcast; switch to GitHub Pages later if a cleaner
  URL/CDN is wanted — that only changes the constant).

---

## 2. Shared reusable workflow — `zamok/ci`

New repo **`zamok/ci`**, file **`.gitea/workflows/macos-cask-release.yml`**:

```yaml
name: macOS cask release (reusable)

on:
  workflow_call:
    inputs:
      scheme:        { type: string,  required: true }   # Xcode scheme, e.g. "Murmur"
      bundle-id:     { type: string,  required: true }   # e.g. "app.bshk.murmur"
      cask-metadata: { type: string,  required: true }   # path in caller repo to zamokctl cask json
      entitlements:  { type: string,  required: false }  # path in caller repo
      tap:           { type: string,  default: "bshk-app/homebrew-tap" }
      asset-repo:    { type: string,  default: "bshk-app/homebrew-tap" }
      sparkle:       { type: boolean, default: false }
      build-flags:   { type: string,  default: "ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SWIFT_ENABLE_EXPLICIT_MODULES=NO" }
    # secrets reach this workflow via `secrets: inherit` in the caller — no need to declare.

permissions:
  contents: read

jobs:
  release:
    runs-on: macos-latest        # self-hosted Tart VM
    timeout-minutes: 90          # MLX is a heavy build — give it room (see §7)
    steps:
      - uses: actions/checkout@v4            # NB: checks out the CALLER repo (Murmur), not zamok/ci

      - name: Drop leftover signing keychain (persistent runner)
        run: security delete-keychain signing_temp.keychain 2>/dev/null || true

      - name: Import Developer ID certificate
        uses: apple-actions/import-codesign-certs@v3
        with:
          p12-file-base64: ${{ secrets.DEVELOPER_ID_P12 }}
          p12-password:    ${{ secrets.DEVELOPER_ID_P12_PASSWORD }}

      - name: Tooling (zamokctl + tuist)
        run: |
          eval "$(/opt/homebrew/bin/brew shellenv)"
          command -v zamokctl >/dev/null || brew install bshk-app/homebrew-tap/zamokctl
          command -v tuist    >/dev/null || brew install tuist

      - name: Resolve version + signing identity
        id: vars
        run: |
          eval "$(/opt/homebrew/bin/brew shellenv)"
          VERSION="${GITHUB_REF_NAME#*-v}"; VERSION="${VERSION#v}"   # tag "murmur-v1.2.3" or "v1.2.3" → 1.2.3
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"
          SHA1="$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $2; exit}')"
          [ -n "$SHA1" ] || { echo "no Developer ID Application identity" >&2; exit 1; }
          echo "sha1=$SHA1" >> "$GITHUB_OUTPUT"

      - name: Build (unsigned) + sign + notarize + package
        env:
          NOTARY_KEY_P8: ${{ secrets.NOTARY_KEY_P8 }}
          NOTARY_KEY_ID: ${{ secrets.NOTARY_KEY_ID }}
          NOTARY_ISSUER: ${{ secrets.NOTARY_ISSUER }}
        run: |
          eval "$(/opt/homebrew/bin/brew shellenv)"
          tuist install || true
          tuist generate --no-open
          DD="$RUNNER_TEMP/dd"
          xcodebuild -workspace "${{ inputs.scheme }}.xcworkspace" -scheme "${{ inputs.scheme }}" \
            -configuration Release -derivedDataPath "$DD" \
            -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO ${{ inputs.build-flags }} build
          APP="$DD/Build/Products/Release/${{ inputs.scheme }}.app"
          P8="$RUNNER_TEMP/notary.p8"; printf '%s' "$NOTARY_KEY_P8" | base64 --decode > "$P8"
          OUT="$RUNNER_TEMP/dist"; mkdir -p "$OUT"
          ENT=""; [ -n "${{ inputs.entitlements }}" ] && ENT="--entitlements ${{ inputs.entitlements }}"
          zamokctl package --input "$APP" --output-dir "$OUT" --format zip \
            --signing-identity-sha1 "${{ steps.vars.outputs.sha1 }}" $ENT \
            --notary-api-key "$P8" --notary-key-id "$NOTARY_KEY_ID" --notary-issuer "$NOTARY_ISSUER"

      - name: Update Sparkle appcast            # only when sparkle: true
        if: ${{ inputs.sparkle }}
        env:
          SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}
          GITHUB_TOKEN:           ${{ secrets.TAP_GITHUB_TOKEN }}
        run: |
          # See §4 — sign the zip with EdDSA, render/append appcast.xml, push to the tap.
          bash "$GITHUB_ACTION_PATH/../scripts/update-appcast.sh" \
            "$RUNNER_TEMP/dist" "${{ inputs.asset-repo }}" "${{ inputs.bundle-id }}" "${{ steps.vars.outputs.version }}"

      - name: Publish cask → tap
        env:
          GITHUB_TOKEN: ${{ secrets.TAP_GITHUB_TOKEN }}
        run: |
          eval "$(/opt/homebrew/bin/brew shellenv)"
          zamokctl cask --manifest "$RUNNER_TEMP/dist/manifest.json" \
            --metadata "${{ inputs.cask-metadata }}" \
            --store git-release --asset-repo "${{ inputs.asset-repo }}" --tap "${{ inputs.tap }}"

      - name: Remove signing keychain
        if: always()
        run: security delete-keychain signing_temp.keychain 2>/dev/null || true
```

### Caller — `zamok/murmur` → `.gitea/workflows/release.yml`

```yaml
on:
  push:
    tags: ["murmur-v*"]
jobs:
  release:
    uses: zamok/ci/.gitea/workflows/macos-cask-release.yml@v1
    with:
      scheme: Murmur
      bundle-id: app.bshk.murmur
      cask-metadata: Distribution/cask-murmur.json
      entitlements: Murmur.entitlements
      sparkle: true
    secrets: inherit
```

Tag `@v1` is a moving tag on `zamok/ci` (re-point it when the shared workflow changes;
pin to a SHA if you want immutability). Once this works, **refactor Zamok's two existing
workflows** (`zamokctl-release.yml`, `zamok-app-cask.yml`) into callers of the same
reusable workflow to delete the duplication.

---

## 3. Sparkle integration (in the app)

### 3.1 SPM dependency — `Project.swift`

Add to `packages`:
```swift
.remote(url: "https://github.com/sparkle-project/Sparkle",
        requirement: .upToNextMajor(from: "2.6.0")),
```
and to the target `dependencies`: `.package(product: "Sparkle")`.

### 3.2 Info.plist (in `Project.swift` `infoPlist`)

```swift
"SUFeedURL": "https://raw.githubusercontent.com/bshk-app/homebrew-tap/main/appcast/murmur.xml",
"SUPublicEDKey": "<base64 Ed25519 public key from generate_keys>",
"SUEnableAutomaticChecks": true,
"SUScheduledCheckInterval": 86400,   // daily
```

### 3.3 Updater wiring (menu-bar / LSUIElement)

- Own an `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
  userDriverDelegate: nil)`; keep it alive for the app lifetime (e.g. `@State`/singleton
  in the `App`/`AppDelegate`).
- Add a **"Check for Updates…"** item to the status-bar menu, enabled-bound to
  `updater.canCheckForUpdates`, calling `updaterController.checkForUpdates(nil)`.
- **Activation-policy caveat (must handle):** Murmur runs as `.accessory`
  (`LSUIElement`) and already toggles to `.regular` during onboarding. Sparkle's update
  dialog is a window — for an accessory agent it can open behind everything or not take
  focus. When the user invokes a check (or an automatic one wants to show UI), bump to
  `.regular` + `NSApp.activate(...)` while the Sparkle window is up, then drop back to
  `.accessory`. Use `SPUStandardUserDriverDelegate` /
  `SPUUpdaterDelegate.updaterWillShowModalAlert`-style hooks to bracket this. **Verify
  the dialog is focusable** during manual testing.

### 3.4 EdDSA keypair (one-time)

```bash
brew install --cask sparkle           # provides generate_keys / sign_update / generate_appcast
generate_keys                          # creates the private key in the login Keychain, prints the PUBLIC key
generate_keys -x sparkle_private.key   # export the PRIVATE key (base64) for the CI secret
```
- **Public key** → `SUPublicEDKey` in Info.plist (§3.2).
- **Private key** (the exported base64) → Gitea **org** secret `SPARKLE_ED_PRIVATE_KEY`.
  Never commit it.

---

## 4. Appcast generation (the one new piece)

`zamokctl` renders cask + formula but **not** a Sparkle appcast (that was a Zamok-server
feature). Two ways — pick (A) for v1:

- **(A) — recommended v1: Sparkle's official `generate_appcast`** in a small
  `zamok/ci/scripts/update-appcast.sh`:
  1. Import `SPARKLE_ED_PRIVATE_KEY` (write to a temp file / Keychain for the tool).
  2. Place the freshly built `Murmur-<ver>.zip` in a working dir.
  3. `generate_appcast --ed-key-file <priv> --download-url-prefix \
     "https://github.com/bshk-app/homebrew-tap/releases/download/murmur-v<ver>/" <dir>`
     → produces `murmur.xml` with `sparkle:edSignature`, version, length.
  4. Merge/commit `appcast/murmur.xml` into `bshk-app/homebrew-tap` (clone with the PAT,
     copy the new `<item>` in, push). Keep prior items for older versions.
  - Pros: official tool, zero new Swift. Cons: a bash script + a clone/commit.

- **(B) — later consolidation: add `zamokctl appcast`** subcommand (reads
  `manifest.json` + zip, Ed25519-signs, renders/merges `appcast.xml`, pushes to the tap
  via the same TapRepo abstraction as cask/formula). This is the SSOT endgame — all
  release shapes (formula, cask, appcast) come from one tool. Do it once the bash version
  has proven the flow.

**Release-notes** (optional): `generate_appcast` can attach an HTML description per
version if a `*.html` sits next to the zip — wire later.

---

## 5. Entitlements + signing

### 5.1 `Murmur.entitlements` (new file at repo root)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- Microphone access under Hardened Runtime (required for notarization). -->
  <key>com.apple.security.device.audio-input</key><true/>
  <!-- NOT sandboxed: the app types into other apps (CGEvent) + uses Accessibility/Input Monitoring. -->
</dict>
</plist>
```
- Hardened Runtime itself is applied by `zamokctl package` (`codesign --options runtime`),
  not by this file.
- **Possibly needed — VERIFY:** `com.apple.security.cs.disable-library-validation`
  (`true`) if MLX-Swift loads dylibs / the `Cmlx` metallib bundle that fail Developer-ID
  library validation under Hardened Runtime. Default: try **without** it; add **only** if
  notarization or first launch fails on library validation. Do not add speculatively.

### 5.2 `Project.swift` signing — leave local dev as-is

- Keep `CODE_SIGN_STYLE=Automatic` / `Apple Development` for **local** `make run`.
- CI builds **unsigned** (`CODE_SIGNING_ALLOWED=NO`) and `zamokctl` re-signs with
  Developer ID — no Project.swift change needed for CI.
- **Accessibility-grant note:** moving a user from a locally-built (Apple Development)
  install to the brew (Developer ID) build changes the code signature **once** → the
  user re-grants Accessibility/Input Monitoring once. Across brew/Sparkle *updates* the
  signature is stable (same Developer ID cert) → the grant persists.

---

## 6. Cask metadata — `Distribution/cask-murmur.json`

zamokctl cask metadata (mirror the Zamok `cask-zamok-app.json` shape):

```json
{
  "token": "murmur",
  "name": "Murmur",
  "desc": "On-device push-to-talk dictation for macOS",
  "homepage": "https://github.com/bshk-app/murmur",      // TBD — see §7 (homepage URL)
  "autoUpdates": true,                                    // Sparkle owns updates → brew won't fight it
  "dependsOnMacOS": ">= :sequoia",                        // macOS 15 (MLX dev/nemo-mic requirement)
  "appBundle": "Murmur.app",
  "livecheck": true,
  "livecheckUrl": "https://raw.githubusercontent.com/bshk-app/homebrew-tap/main/appcast/murmur.xml",
  "zapTrash": [
    "~/Library/Application Support/Murmur",
    "~/Library/Caches/app.bshk.murmur",
    "~/Library/Preferences/app.bshk.murmur.plist",
    "~/Library/HTTPStorages/app.bshk.murmur",
    "~/Library/Caches/huggingface"                        // VERIFY model-cache path before claiming it in zap
  ]
}
```
`auto_updates true` + `depends_on macos` are required for a clean `brew audit`. The cask
is published by the workflow's "Publish cask" step.

---

## 7. Prerequisites & things to VERIFY (for the implementer)

**One-time setup**
1. Move `beshkenadze/murmur` → **`zamok` org** on Gitea (so the org runner picks up jobs
   and org secrets inherit). Update `origin` remote afterwards.
2. Create **`zamok/ci`** repo with the reusable workflow (§2) + `scripts/update-appcast.sh`
   (§4A). Tag it `v1`.
3. Generate the EdDSA keypair (§3.4): public → `SUPublicEDKey`, private → org secret
   `SPARKLE_ED_PRIVATE_KEY`.
4. Confirm these **org-level** secrets exist on `zamok` (reused from the Zamok pipeline,
   except the last which is new):

   | Secret | Source |
   |---|---|
   | `DEVELOPER_ID_P12` / `DEVELOPER_ID_P12_PASSWORD` | existing (Zamok) |
   | `NOTARY_KEY_P8` / `NOTARY_KEY_ID` / `NOTARY_ISSUER` | existing (Zamok) |
   | `TAP_GITHUB_TOKEN` | existing (least-priv PAT for bshk-app/homebrew-tap) |
   | `SPARKLE_ED_PRIVATE_KEY` | **new** (§3.4) |

**Verify (each previously cost hours elsewhere — do not skip)**
- [x] **MLX notarization under Hardened Runtime** — ✅ RESOLVED 2026-06-26 (local de-risk,
      §8.1, `Distribution/derisk-sign-notarize.sh`). zamokctl signed (Developer ID +
      Hardened Runtime + `Murmur.entitlements`) → notarytool ACCEPTED → spctl "accepted,
      source=Notarized Developer ID" → `codesign --deep --strict` valid. **No
      `disable-library-validation` needed** — the MLX/Cmlx dylibs pass library validation.
- [ ] **zamokctl `--format zip` leaves the inner .app UNSTAPLED** — found in the §8.1 de-risk.
      Notarization succeeds and the ticket IS in Apple's CloudKit (a later `xcrun stapler
      staple` on the extracted app worked offline-cheap, no re-submission), but the zip
      zamokctl distributes has no stapled ticket → first launch would need an online
      Gatekeeper check. Fix in the packaging step (§8.4): staple before zipping. Cleanest =
      in zamokctl (SSOT — it already advertises a "stapled artifact", and the CI/cask hash
      must match the final zip, so the stapler must run inside the tool that hashes). Or use
      `--format dmg` (staples the container directly). Do NOT post-staple+rezip in the CI
      script — that desyncs zamokctl's manifest sha256.
- [ ] **Gitea `workflow_call` + `secrets: inherit`** on this instance (1.26.2). If
      unsupported → composite-action fallback (§0).
- [ ] **`actions/checkout` in a reusable workflow checks out the caller repo** on Gitea
      (true on GitHub; confirm on Gitea).
- [ ] **Sparkle dialog focus** for the `.accessory` agent (§3.3).
- [ ] **HuggingFace model-cache path** before listing it in `zapTrash` (§6).
- [ ] **Cask `homepage`** — Gitea is not internet-exposed, so don't use `git.bshk.app`.
      Use a GitHub mirror of Murmur, a `bshk.app/murmur` landing, or the tap repo.
- [ ] **Tart runner build time** — MLX Release build is heavy; `timeout-minutes: 90` is a
      starting guess, tune it.

**Out of scope for v1**
- `murmur-cli` distribution (formula). It needs the `mlx-swift_Cmlx.bundle` metallib
  copied next to the binary (see `Makefile`) + runtime model downloads — packaging that
  cleanly is its own task. App-only (cask) first.

---

## 8. Implementation order (atomic, each independently verifiable)

1. **De-risk signing/notarization locally.** Add `Murmur.entitlements` (§5.1). Build the
   app, then manually: `zamokctl package --input Murmur.app --format zip
   --signing-identity-sha1 <Developer ID> --entitlements Murmur.entitlements
   --notary-*`. Confirm `notarytool` accepts it and `spctl -a -vvv Murmur.app` passes.
   **If this fails, nothing downstream matters** — fix entitlements/library-validation
   here.
2. **Sparkle in-app.** SPM dep + Info.plist + "Check for Updates…" menu + activation-
   policy handling (§3). Generate the EdDSA keypair. Hand-write a one-item
   `appcast.xml` pointing at a manually uploaded zip; confirm the app detects, downloads,
   and installs an update end-to-end.
3. **Cask metadata** `Distribution/cask-murmur.json` (§6).
4. **Shared workflow** `zamok/ci` + `scripts/update-appcast.sh` (§2, §4A); tag `v1`.
5. **Caller** `zamok/murmur/.gitea/workflows/release.yml` (§2).
6. **Plumbing:** move repo to `zamok` org, set `SPARKLE_ED_PRIVATE_KEY`, confirm the
   runner picks up the job.
7. **End-to-end:** push tag `murmur-v0.x.0` → green CI → `brew install --cask
   bshk-app/homebrew-tap/murmur` → bump version, tag again → confirm Sparkle self-update.
8. **Consolidate (optional):** refactor Zamok's two workflows into callers of
   `zamok/ci`; consider migrating appcast generation from the bash script (§4A) into a
   `zamokctl appcast` subcommand (§4B).
```
