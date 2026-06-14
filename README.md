# AllTheThings

AllTheThings is a native macOS file-search app built for one fast loop: type a filename or path query, scan live results, then open, reveal, copy, rename, preview, or trash the matching files.

<picture>
  <source srcset="docs/images/allthethings-demo.webp" type="image/webp">
  <img src="docs/images/allthethings-demo.png" alt="AllTheThings filtering a safe demo folder for planner Swift files with middle-word match indicators">
</picture>

## Requirements

- macOS 15 Sequoia or newer
- Apple Silicon Mac

## Getting Started

On first launch, AllTheThings indexes the default folders that exist on your Mac: `~/Desktop`, `~/Documents`, `~/Downloads`, and `~/Developer`. Applications are searched separately with `app:` so bundle internals are not part of normal filename/path search. If setup suggestions are available, they appear at the top of the search window instead of blocking the app.

Use **Settings > Indexed Folders** to add or remove indexed folders, manage application search folders, check Full Disk Access status, and rebuild the index. The search window toolbar opens Settings and Insights, and enables Open, Reveal, and Copy Path actions when results are selected. The footer defaults to a simple shown/matches count; **Settings > General** can switch it to detailed indexing state, match count, query time, memory, and version info. The default global search shortcut is `Command-Shift-Space`; enable it from the setup suggestion, or disable/remap it in **Settings > Hotkeys**. The default global app search shortcut is `Shift-Option-Space`; enable it from the setup suggestion or **Settings > Hotkeys** to open search with `app:` prefilled. Enable launch at login to keep shortcuts available after signing in. The optional menu bar icon can focus search, open Settings or Insights, toggle launch at login, or quit the app.

High-noise folders such as `node_modules`, `DerivedData`, `.git/objects`, `Library/Caches`, and `.Trash` are skipped.

## Searching

Type in the search field and results update immediately. Queries are case-insensitive and diacritic-insensitive. Space-separated positive terms must all match unless you use alternatives.

| Query | Meaning |
| --- | --- |
| `psr` | Fuzzy/acronym match, such as `PhotoSyncReport.final.pdf`. |
| `redme` | Small typo match for a filename like `README.md`. |
| `.swift` or `*.swift` | Match files by extension. |
| `atlas ext:swift` | Match `atlas` and require a Swift extension. |
| `name:Search*.swift` | Match a wildcard pattern against the filename. |
| `path:Sources ext:swift` | Match a path token and require Swift files. |
| `package !path:node_modules` | Match `package` but exclude `node_modules` paths. |
| `source/**/*.hpp` | Match structured path segments with `**` spanning folders. |
| `app:terminal` | Search launchable `.app` bundles from configured application search folders. |

Useful prefixes include `app:`, `name:`, `path:`, `ext:`, and `kind:`. The aliases `apps:`, `application:`, `applications:`, `file:`, `filename:`, `basename:`, `folder:`, `dir:`, `directory:`, `extension:`, `suffix:`, and `type:` are also supported.

Use `!` or `-` to exclude a term, `|` for alternatives, and double quotes for an exact substring. Wildcards use `*` for any run of characters and `?` for one character.

## Results

Results are shown in a sortable table. The default sort is `Name` ascending, and AllTheThings remembers your selected sort when you reopen the app.

Right-click the header row to show or hide optional columns. `Name` stays visible so the table always has a primary label. Available columns include name, path, modified date, size, created date, extension, kind, and volume.

## Actions

Select one or more rows, then use the toolbar, context menu, or app menus:

- Open files, reveal them in Finder, or copy their paths from the toolbar.
- Copy selected files with `Command-C` or paths with `Command-Option-C`.
- Rename files, move files to Trash, open Quick Look, or open Get Info.
- Open terminal tabs/windows at the selected file's folder when Ghostty or iTerm2 exposes the matching macOS Services.

## Updates

AllTheThings checks GitHub for new releases from `MikeMarcin/AllTheThings` once per day on launch. The primary release download is a Developer ID signed and Apple-notarized DMG, with a ZIP provided as a backup artifact. When an installable release archive is available, AllTheThings can download the update, replace the current app bundle, and relaunch the updated app. You can run a manual check from **AllTheThings > Check for Updates...** or disable automatic checks from **AllTheThings > Automatically Check for Updates**.

## Privacy

AllTheThings indexes file metadata needed for search: paths, names, extensions, sizes, timestamps, folder/file status, hidden status, and volume names. It does not read file contents for search indexing.

macOS protects locations such as Desktop, Documents, Downloads, some external or cloud folders, and other privacy-sensitive folders. AllTheThings can index folders you explicitly choose without Full Disk Access, but macOS may prompt when the app indexes or refreshes protected locations. Broad indexing works best after granting Full Disk Access in **System Settings > Privacy & Security > Full Disk Access**.

AllTheThings keeps structured diagnostic logs only on your Mac under its local Application Support folder. These raw logs may include search queries, file paths, file action context, and error messages so local diagnosis has enough detail to be useful. Logs are capped to about 50 MB and 30 days, are not sent over the network, and are not attached to update checks. Use **AllTheThings > Export Anonymized Diagnostic Log...** to create a shareable JSONL export that replaces sensitive strings such as paths and queries with deterministic same-length gibberish. **Export Raw Diagnostic Log...** preserves the local raw values and should be shared only when you intend to disclose that detail.

Use **AllTheThings > Settings > Indexed Folders** to check Full Disk Access status, open the matching System Settings pane, add and remove indexed folders, manage application search folders, or rebuild the local index.

Be careful when sharing screenshots or recordings. A file-search window can expose usernames, project names, client names, cloud folder names, and recently touched files.

## Troubleshooting

If expected files are missing, confirm the parent folder is indexed in **Settings > Indexed Folders**, use **Reindex** to rebuild the local index, check whether the file is under a skipped folder, and make sure macOS privacy protections are not hiding the location. For application results, confirm the app bundle is under one of the configured **Application Search** folders in **Settings > Indexed Folders**. Grant Full Disk Access or remove protected folders from indexing if macOS keeps asking for folder access.

If the app opens an existing running instance instead of starting a second copy, use **AllTheThings > Allow Multiple Instances**.

## Development

Source builds, VSCode tasks, architecture notes, and current implementation limits live in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Support Development

If AllTheThings saves you time, consider supporting continued work through [GitHub Sponsors](https://github.com/sponsors/MikeMarcin), starring the repository, or filing focused issues with reproducible examples.
