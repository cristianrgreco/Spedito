# Releasing Spedito

Spedito early releases are built and published by GitHub Actions from an
explicit semantic version. A push to `main` runs CI but does not publish a
release.

## Current release properties

- Apple Silicon, macOS 14 or later
- Built on GitHub's Apple Silicon `macos-26` runner with Xcode 26.6 selected
  explicitly
- Ad-hoc code signed
- Not Developer ID signed or Apple notarized
- Packaged in a branded DMG with an Applications shortcut for drag-and-drop
  installation
- Published as a normal GitHub release so the website's `releases/latest` link
  resolves
- The static website is published independently from `Website/` by Cloudflare
  Pages
- Clearly labelled as an early preview and provided without warranty

Do not describe these artifacts as trusted, notarized, or production-ready.

## Publishing

1. Confirm `main` contains the intended release and its CI run passed.
2. Confirm the README and product specification describe the release boundary
   accurately.
3. Choose a semantic version below `1.0.0` while the project remains an early
   preview.
4. Open the repository's **Actions** tab, choose **Release**, select **Run
   workflow**, leave the branch set to `main`, enter a version such as `0.1.0`,
   and run it.
5. Watch the workflow. It runs the full test suite, builds the application
   bundle, verifies its ad-hoc signature, creates and validates a DMG and SHA-256
   checksum, creates the annotated version tag, and publishes both files to
   GitHub Releases.
6. Download the published assets on a separate machine or clean user account and
   verify the checksum, launch instructions, and first-run experience.

For the first Spedito-branded build, quit any running StoryPointless build before
launch. Spedito then moves the existing application-support directory and
product control folders to their new names while preserving product data and
preferences.

The same release can be started from the command line by creating and pushing
the version tag:

```sh
git switch main
git pull --ff-only
git tag -a v0.1.0 -m "Spedito v0.1.0"
git push origin v0.1.0
```

The workflow validates the version and uses `--verify-tag`. A manual run creates
its tag only after the tests, app bundle, and DMG have passed validation. Do not
retag or replace a published version. Correct a bad release with a new patch
version and explain the superseded build in its release notes.

## Verifying an artifact

After downloading both assets into one directory:

```sh
shasum -a 256 -c Spedito-0.1.0-SHA256.txt
./scripts/verify_dmg.sh Spedito-0.1.0-macOS-Apple-Silicon.dmg
```

The checksum verifies that the DMG matches the GitHub release asset. The
verification script checks the disk image, drag-and-drop layout assets,
application signature, bundled licence, and Apple Silicon executable. The code
signature verifies bundle integrity, not developer identity. Gatekeeper may
warn because the app is not notarized.

## Future Developer ID releases

When an Apple Developer account is available, the release design must be updated
and reviewed before adding credentials. Signing certificates and notarization
credentials must live in GitHub Actions secrets, be imported only in the release
job, and never be available to pull-request workflows. The release must then:

1. sign the app and every required nested executable with the hardened runtime;
2. submit the exact release artifact or approved intermediate for notarization;
3. staple and verify the notarization ticket where supported;
4. verify the final downloadable artifact on a clean Mac; and
5. update the README and release notes to distinguish the newly notarized build.

Do not reuse Product Owner, Codex, or development credentials for release
signing.
