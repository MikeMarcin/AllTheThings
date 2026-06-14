---
name: update-promo-assets
description: Regenerate AllTheThings promotional screenshots and animated WebP recordings. Use when asked to update marketing, README, website, hero, demo, screenshot, screen recording, or promo assets for AllTheThings, especially when the assets must use a personal-information-safe demo index and also update gamecoretech.com.
---

# Update Promo Assets

Use this workflow to regenerate AllTheThings promo media from a real app screen recording, not from a manually assembled screenshot sequence. The capture must show only a synthetic, personal-information-safe demo index.

## Safety Rules

- Do not index or capture real user folders, file names, account names, home paths, recent files, browser tabs, notifications, or other personal data.
- Do not hardcode personal absolute paths or local usernames in instructions, scripts, generated metadata, or committed files.
- Use repo-relative paths for AllTheThings files. Use `GAMECORETECH_SITE_ROOT` for the website checkout when available; otherwise locate or ask for the `gamecoretech.com` checkout without recording a personal folder structure in the skill or generated assets.
- Use a temporary synthetic index root with product-like sample names, such as a Project Atlas fixture. Temporary paths like `/tmp/...` are acceptable in demo assets.
- Before recording, take a preflight screenshot and visually confirm that the capture region contains only the AllTheThings window and safe synthetic paths.
- Restore the user's AllTheThings preferences and application support data after capture, even if asset generation fails.

## Workflow

1. Inspect state:

   ```bash
   git status --short
   cmake --build --preset app
   ```

   In the website checkout, also inspect `git status --short` before editing static assets.

2. Determine the release label from source or the built app:

   ```bash
   /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist
   ```

   The app title in the capture should match the current release.

3. Prepare a safe demo index in a temporary location. Include enough files for the query `atlas ext:swift` to produce multiple Swift results and visible Match indicators. Keep all names synthetic and non-personal. Include a release-note fixture matching the current release version so pre-query rows are not stale.

4. Back up local app state before changing defaults:

   ```bash
   backup_root="$(mktemp -d "${TMPDIR:-/tmp}/allthethings-promo-backup.XXXXXX")"
   printf '%s' "$backup_root" > "${TMPDIR:-/tmp}/allthethings-promo-backup-path"
   osascript -e 'tell application "AllTheThings" to quit' >/dev/null 2>&1 || true
   if defaults export com.gamecoretech.allthethings "$backup_root/defaults.plist" >/dev/null 2>&1; then
     printf '1' > "$backup_root/had-defaults"
   else
     printf '0' > "$backup_root/had-defaults"
   fi
   if [[ -d "$HOME/Library/Application Support/AllTheThings" ]]; then
     printf '1' > "$backup_root/had-app-support"
     mkdir -p "$backup_root/Application Support"
     ditto "$HOME/Library/Application Support/AllTheThings" "$backup_root/Application Support/AllTheThings"
   else
     printf '0' > "$backup_root/had-app-support"
   fi
   ```

5. Configure capture-only defaults. Point `ATTIndexedRoots` at the synthetic index, mark setup complete, disable the global hotkey and automatic update checks, force dark appearance, and show the columns needed for marketing:

   ```bash
   defaults delete com.gamecoretech.allthethings >/dev/null 2>&1 || true
   defaults write com.gamecoretech.allthethings ATTIndexedRoots -array "$safe_index_root"
   defaults write com.gamecoretech.allthethings ATTIndexedRootsInitialized -bool true
   defaults write com.gamecoretech.allthethings ATTIndexingSetupCompleted -bool true
   defaults write com.gamecoretech.allthethings ATTFullDiskAccessOnboardingShown -bool true
   defaults write com.gamecoretech.allthethings ATTGlobalSearchHotKeyEnabled -bool false
   defaults write com.gamecoretech.allthethings ATTGlobalSearchHotKeyConfirmationResolved -bool true
   defaults write com.gamecoretech.allthethings ATTAutomaticallyCheckForUpdates -bool false
   defaults write com.gamecoretech.allthethings ATTThemePreference -string dark
   defaults write com.gamecoretech.allthethings ATTHighlightSearchText -bool true
   defaults write com.gamecoretech.allthethings ATTShowHiddenFiles -bool false
   defaults write com.gamecoretech.allthethings ATTSortColumn -string name
   defaults write com.gamecoretech.allthethings ATTSortAscending -bool true
   defaults write com.gamecoretech.allthethings ATTVisibleColumns -array match name path modified size created
   defaults write com.gamecoretech.allthethings ATTVisibleColumnsSchema -int 3
   killall cfprefsd >/dev/null 2>&1 || true
   ```

6. Launch the built app, position it consistently, and wait for indexing to finish. Use AppleScript or UI automation to place the main window at a fixed rectangle such as `{90, 80, 1060, 622}`. Capture a preflight image from the same rectangle and inspect it before recording.

7. Record an isolated movie from the window rectangle:

   ```bash
   screencapture -x -v -V 6.2 -R90,80,1060,622 "$work_dir/allthethings-demo.mov" &
   ```

   During recording, clear the search field and type `atlas`, pause briefly, then type ` ext:swift` at a slower human cadence. The final frame should show:

   - title for the current AllTheThings release
   - query `atlas ext:swift`
   - Match column visible with indicators
   - only synthetic temporary paths
   - 8 or more clean demo matches when possible
   - status text showing the safe index count

8. Extract frames from the movie with AVFoundation or another local tool that does not require internet access. Generate:

   - a README/static PNG at `docs/images/allthethings-demo.png`, normally `1280x751`
   - a site hero PNG at `gamecoretech.com/static/images/allthethings-demo.png`, normally `1840x1080`
   - animated WebPs at both destinations, normally `1280x751`, derived from the recorded movie frames

   ImageMagick is acceptable for resizing and WebP assembly. Preserve the screen-recording source of truth: extract the final PNG from the movie, then build WebP frames from the same movie.

9. Copy the regenerated assets into the AllTheThings repo and the `gamecoretech.com` checkout. If the website has a generated `public/images` directory already present, refresh the matching files there too, but do not rely on generated public files as the source asset.

10. Restore the user's app state:

    ```bash
    backup_root="$(cat "${TMPDIR:-/tmp}/allthethings-promo-backup-path")"
    osascript -e 'tell application "AllTheThings" to quit' >/dev/null 2>&1 || true
    if [[ "$(cat "$backup_root/had-defaults")" == "1" ]]; then
      defaults import com.gamecoretech.allthethings "$backup_root/defaults.plist"
    else
      defaults delete com.gamecoretech.allthethings >/dev/null 2>&1 || true
    fi
    rm -rf "$HOME/Library/Application Support/AllTheThings"
    if [[ "$(cat "$backup_root/had-app-support")" == "1" ]]; then
      mkdir -p "$HOME/Library/Application Support"
      ditto "$backup_root/Application Support/AllTheThings" "$HOME/Library/Application Support/AllTheThings"
    fi
    killall cfprefsd >/dev/null 2>&1 || true
    ```

## Verification

Run these before finishing:

```bash
cmake --build --preset check
magick identify docs/images/allthethings-demo.png docs/images/allthethings-demo.webp
webpmux -info docs/images/allthethings-demo.webp
```

In the `gamecoretech.com` checkout:

```bash
hugo build
magick identify static/images/allthethings-demo.png static/images/allthethings-demo.webp
webpmux -info static/images/allthethings-demo.webp
```

Confirm the AllTheThings app is not left running. Report changed files, asset dimensions, WebP frame count, test/build results, and whether any site warnings were pre-existing. If a capture or generated asset reveals non-synthetic paths, discard it and recapture before replacing tracked files.
