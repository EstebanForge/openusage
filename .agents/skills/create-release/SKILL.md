---
name: create-release
description: Cut a signed, notarized OpenUsage release by pushing a version tag. Use when asked to ship a release, publish an update, prepare a beta, or set up the one-time release secrets and GitHub Pages feed.
---

# Create Release

Releases are automated. Push a version tag and GitHub builds, signs, notarizes, and publishes the
update; users receive it through Sparkle.

```sh
git tag v1.2.3
git push origin v1.2.3      # builds, notarizes, uploads the DMG, updates the appcast
```

A tag with a pre-release suffix (e.g. `v1.2.3-beta.1`) publishes to the Early Access channel; a plain
tag (`v1.2.3`) publishes to everyone.

## What ships

1. A Developer ID-signed, notarized `OpenUsage-<version>.dmg`, attached to the GitHub Release.
2. An updated `appcast.xml` published to the `gh-pages` branch and served from GitHub Pages (the feed
   URL baked into every build). `generate_appcast` signs the DMG and merges the new entry into the
   existing feed, preserving older versions and the other channel's latest build.

The pipeline lives in `.github/workflows/release.yml`. It builds and notarizes the DMG with
`script/release.sh`, then generates the appcast with Sparkle's official `generate_appcast` tool.

## Versioning

- The tag sets the human version: `v1.2.3` -> `CFBundleShortVersionString = 1.2.3`.
- `CFBundleVersion` is the git commit count, which always increases. Sparkle compares it to decide
  whether a build is newer.

## One-time setup

### 1. Make the repository public

Sparkle downloads the DMG and the appcast without authentication. GitHub release assets and Pages are
only reachable anonymously on a public repo, so the repo must be public before the first real release.

### 2. Add the release secrets

Add these under repo Settings -> Secrets and variables -> Actions. They are all values you control as
the signing owner of the app:

| Secret | What it is |
| --- | --- |
| `APPLE_CERTIFICATE` | base64 of your Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | the password set when exporting that `.p12` |
| `APPLE_ID` | the Apple ID email used for notarization |
| `APPLE_PASSWORD` | an app-specific password for that Apple ID |
| `APPLE_TEAM_ID` | your Apple Developer team ID |
| `SPARKLE_PUBLIC_KEY` | base64 EdDSA public key, baked into the build as `SUPublicEDKey` |
| `SPARKLE_PRIVATE_KEY` | base64 EdDSA private key used by `generate_appcast` to sign the DMG |

To create the certificate value: export your Developer ID Application cert (with its private key) from
Keychain Access as a `.p12`, then `base64 -i DeveloperID.p12 | pbcopy`. App-specific passwords are
created at appleid.apple.com under Sign-In and Security -> App-Specific Passwords. Generate the Sparkle
EdDSA key pair once with Sparkle's `generate_keys` tool and keep the private key backed up safely; the
public and private values must be a matching pair or `generate_appcast` will silently skip signing.

### 3. GitHub Pages

- The first release pushes the `gh-pages` branch with `appcast.xml`.
- Afterwards, in repo Settings -> Pages, confirm the source is the `gh-pages` branch. Auto-updates only
  need the feed URL to be live; the first build is downloaded by hand from the GitHub Release, and every
  later build can update automatically.

## Cutting a release

1. Make sure `main` is green and has the changes you want to ship.
2. Tag and push:
   ```sh
   git tag v1.2.3
   git push origin v1.2.3
   ```
3. Watch the Release workflow. When it finishes you have a notarized DMG on the GitHub Release and an
   updated appcast on `gh-pages`.

For an early-access build, use a pre-release tag: `git tag v1.2.3-beta.1 && git push origin v1.2.3-beta.1`.

## Local dry run

Run the same build locally without uploading anything:

```sh
export CODESIGN_IDENTITY="Developer ID Application: <Your Name> (TEAMID)"
export SPARKLE_PUBLIC_KEY="<your base64 public key>"
export OPENUSAGE_VERSION="1.2.3"
export ALLOW_UNNOTARIZED=1   # skip notarization for a quick local check
./script/release.sh
```

To exercise notarization too, drop `ALLOW_UNNOTARIZED` and export `NOTARY_APPLE_ID`,
`NOTARY_APP_PASSWORD` (an app-specific password), and `NOTARY_TEAM_ID`. Without either path,
`script/release.sh` stops rather than produce an un-notarized build.

`script/release.sh` produces only the DMG in `dist/`. To build an appcast locally for testing, point
`generate_appcast` at a folder holding the DMG (it uses the Sparkle key in your keychain automatically):

```sh
GA=$(find .build/artifacts -name generate_appcast | head -n1)
mkdir -p feed && cp dist/OpenUsage-1.2.3.dmg feed/
"$GA" --download-url-prefix "https://github.com/<owner>/<repo>/releases/download/v1.2.3/" feed
cat feed/appcast.xml
```

For a pre-release, add `--channel beta`. `generate_appcast` only writes the `sparkle:edSignature` when
the DMG's embedded `SUPublicEDKey` matches the signing key, so use the same key pair throughout.

## Guardrails

- Never commit secret values or private keys. They live only in GitHub Actions secrets and your local
  environment.
- The release feed is append-only on purpose: older installs and the other channel's items must keep
  working, so the workflow aborts rather than shrink the appcast.
- Tags are owner-managed. Only the project owner should create `v*` tags.
