---
name: publish-release
description: Publish AllTheThings releases. Use when asked to cut, package, tag, push, or publish a new AllTheThings version; covers version bumping, release packaging, signing/notarization checks, GitHub release assets, and post-release verification.
---

# Publish Release

Use this workflow to create a real AllTheThings release. The goal is a tagged, pushed, signed, notarized GitHub release with verified assets.

## Release Workflow

1. Inspect the repo state before changing anything:

   ```bash
   git status --short
   git branch --show-current
   git tag --sort=-v:refname | head
   /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist
   /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist
   ```

2. Commit any requested source changes before the version bump. Do not start a production release with unrelated tracked changes in the worktree.

3. Choose the next SemVer:

   - user-specified version wins
   - patch for narrow fixes
   - minor for user-visible features or meaningful behavior changes
   - major only when explicitly requested

   State the assumption before editing if the user did not name a version.

4. Bump `Resources/Info.plist`:

   - `CFBundleShortVersionString` to the release version
   - `CFBundleVersion` to the previous build number plus 1

   Commit the bump as `Bump version to X.Y.Z`.

5. Run the production release script:

   ```bash
   tools/release.sh --version X.Y.Z
   ```

   The script must pass tests, build the app, sign with Developer ID, notarize, staple, run Gatekeeper assessment, and create DMG/ZIP/checksum files in `build/releases/X.Y.Z/`.

6. Inspect checksum files before upload:

   ```bash
   cat build/releases/X.Y.Z/*.sha256
   ```

   Checksum files must contain asset basenames, not `/Users/...`, `$HOME`, or other local absolute paths. If absolute paths appear, fix `tools/release.sh`, commit the fix, and rerun the release package.

7. Create and push the release tag only after packaging succeeds:

   ```bash
   git tag -a vX.Y.Z -m "AllTheThings X.Y.Z"
   git push origin main
   git push origin vX.Y.Z
   ```

8. Create the GitHub release with the notarized assets:

   ```bash
   version=X.Y.Z
   arch="$(uname -m)"
   gh release create "v${version}" \
     "build/releases/${version}/AllTheThings-${version}-macos-${arch}.dmg#AllTheThings ${version} macOS ${arch} DMG" \
     "build/releases/${version}/AllTheThings-${version}-macos-${arch}.dmg.sha256#DMG SHA-256 checksum" \
     "build/releases/${version}/AllTheThings-${version}-macos-${arch}.zip#AllTheThings ${version} macOS ${arch} ZIP" \
     "build/releases/${version}/AllTheThings-${version}-macos-${arch}.zip.sha256#ZIP SHA-256 checksum" \
     --title "AllTheThings ${version}" \
     --notes "Release notes here."
   ```

   Keep notes concise. Include user-visible highlights and state that the macOS app was Developer ID signed, notarized, stapled, and Gatekeeper assessed when those checks passed.

9. Verify the published release:

   ```bash
   gh release view "vX.Y.Z" --json tagName,name,url,isDraft,isPrerelease,assets
   git ls-remote --tags origin "vX.Y.Z"
   git ls-remote --heads origin main
   git status --short --ignored=matching
   ```

## Rules

- Do not use `--skip-sign`, `--skip-notarize`, `--skip-tests`, or `--allow-dirty` for a real release unless the user explicitly requests it.
- Keep generated `build/` and `artifacts/` outputs out of git.
- Do not upload checksum files that contain local machine paths.
- Do not finish while `tools/release.sh` is still running.
- If packaging, notarization, pushing, or `gh release create` fails, stop and report the exact failing step and artifact state.
- In the final response, include release URL, version/build, tag, pushed commit, uploaded asset names, and verification summary.
