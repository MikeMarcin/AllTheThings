# AllTheThings

AllTheThings is a native macOS file-search app for one fast workflow: type a filename or path query, then act on the matching files from a sortable, live-updating table.

<picture>
  <source srcset="docs/images/allthethings-demo.webp" type="image/webp">
  <img src="docs/images/allthethings-demo.png" alt="AllTheThings filtering a sample project folder with atlas *.swift">
</picture>

## Requirements

- macOS 15 Sequoia or newer
- Apple Silicon Mac
- Xcode 16.2 / Swift 6 toolchain when building from source

## What It Does

- Indexes selected folders and keeps a warm-start snapshot in Application Support.
- Searches filenames and paths as you type.
- Supports fuzzy matches, typo-tolerant filename matches, field filters, exclusions, wildcard patterns, and structured path queries.
- Shows configurable, sortable columns for name, path, modified date, size, created date, extension, kind, and volume.
- Watches indexed folders with FSEvents and refreshes changed paths.
- Opens files, reveals files in Finder, copies paths, renames files, moves files to Trash, opens Quick Look, and opens terminal tabs/windows from matching results.

## First Launch

On first launch, AllTheThings indexes the folders that exist from this default set:

- `~/Desktop`
- `~/Documents`
- `~/Downloads`
- `~/Developer`
- `/Applications`

The footer shows whether indexing is still running, how many records are indexed, how many matches are shown, and how long the current query took. You can start searching while indexing is in progress.

## Managing Indexed Folders

Use the folder-plus toolbar button to add one or more folders to the index. Use the refresh toolbar button to rebuild the current indexed scopes.

AllTheThings remembers indexed folders in macOS preferences. The filename snapshot is stored in:

```text
~/Library/Application Support/AllTheThings/filename-index.json
```

The current MVP skips common high-noise locations such as `node_modules`, `DerivedData`, `.git/objects`, `Library/Caches`, and `.Trash`.

## Searching

Click the search field and type. Results update immediately.

The current table sort applies to both empty and non-empty searches. By default, results are sorted by `Name` ascending. Click a column header to change the sort; AllTheThings remembers the selected sort when you reopen the app.

Queries are case-insensitive and diacritic-insensitive. Separate terms with spaces. Every positive term must match unless you use alternatives.

| Query | Meaning |
| --- | --- |
| `psr` | Fuzzy/acronym match, such as `PhotoSyncReport.final.pdf`. |
| `redme` | Small typo match for a filename like `README.md`. |
| `.swift` or `*.swift` | Match files by extension. |
| `atlas ext:swift` | Match `atlas` and require a Swift extension. |
| `name:Search*.swift` | Match a wildcard pattern against the filename. |
| `path:Sources ext:swift` | Match a folder/path token and require Swift files. |
| `kind:folder` | Show folders only. `kind:file` or `type:file` shows files only. |
| `package !path:node_modules` | Match `package` but exclude paths containing `node_modules`. |
| `ext:swift|md` | Match Swift or Markdown files. |
| `source/**/*.hpp` | Match structured path segments with `**` spanning folders. |

Supported field prefixes:

- Filename fields: `name:`, `file:`, `filename:`, `basename:`
- Path fields: `path:`, `folder:`, `dir:`, `directory:`
- Extension fields: `ext:`, `extension:`, `suffix:`
- Kind fields: `kind:`, `type:`

Use `!` or `-` before a term to exclude it. Use `|` for alternatives. Extension and kind filters also accept comma or semicolon separated alternatives, such as `ext:swift,md`.

Wrap a term in double quotes for an exact substring match. Wildcards use `*` for any run of characters and `?` for one character.

## Reading Results

The table columns are:

- `Name`: filename or folder name. The primary query token is highlighted.
- `Path`: containing folder.
- `Modified`: last modified timestamp.
- `Size`: file size, or `Folder` for directories.
- `Created`: creation timestamp when available.
- `Ext`: lowercase file extension.
- `Kind`: `File` or `Folder`.
- `Volume`: macOS volume name.

Click a column header to sort. Right-click the header row to show or hide optional columns. `Name` stays visible so the table always has a primary label. Drag column headers to reorder them. Resize columns from their dividers. AllTheThings remembers the selected sort and visible columns when you reopen the app.

## Working With Results

Select one or more rows, then use the toolbar or context menu:

- Double-click or press the open toolbar button to open the selected item.
- Use the Finder toolbar button or `Reveal in Finder` to select the item in Finder.
- Use the copy toolbar button to copy selected paths.
- Press `Command-C` to copy selected files to the pasteboard.
- Press `Command-Option-C` to copy selected paths as text.
- Right-click for `Open With`, `Move to Trash`, `Get Info`, `Rename`, `Quick Look`, `Copy`, `Copy Path`, and `Reveal in Finder`.
- If Ghostty or iTerm2 is installed and exposes macOS Services, the context menu can open a new terminal tab or window at the selected file's folder.

## Updates

AllTheThings checks GitHub for new releases from `MikeMarcin/AllTheThings` once per day on launch. You can also run the check manually from **AllTheThings > Check for Updates...** or disable automatic checks from **AllTheThings > Automatically Check for Updates**.

The updater expects published GitHub releases with a downloadable `.dmg`, `.zip`, `.tar.gz`, or `.tgz` asset. If no installable asset is attached, the app opens the release page instead.

## Privacy Notes

AllTheThings indexes file metadata needed for search: paths, names, extensions, sizes, timestamps, folder/file status, hidden status, and volume names. It does not read file contents for search indexing.

Be careful when sharing screenshots or recordings. A file-search window can expose usernames, project names, client names, cloud folder names, and recently touched files. For public media, use a throwaway folder with sample files, temporarily index only that folder, and verify the footer/path column before publishing.

## Troubleshooting

If expected files are missing:

- Confirm the parent folder is in the indexed scopes.
- Click the refresh toolbar button to rebuild the index.
- Check whether the path is under an excluded folder such as `node_modules`, `DerivedData`, `.git/objects`, `Library/Caches`, or `.Trash`.
- macOS privacy protections may hide protected folders until the app has permission. Full Disk Access onboarding is not implemented yet.

If the app opens an existing running instance instead of starting a second copy, use **AllTheThings > Allow Multiple Instances**.

## Build From Source

```sh
cmake --preset default
cmake --build --preset check
cmake --build --preset app
```

The app bundle is written to:

```text
build/AllTheThings.app
```

Run it with:

```sh
cmake --build --preset run
```

## VSCode

The repository includes VSCode workspace tasks:

- `CMake: Build App`
- `CMake: Run App`
- `CMake: Test`
- `CMake: Build Debug App`
- `CMake: Clean App Bundles`

The Run and Debug panel has `Run AllTheThings` and `Debug AllTheThings` configurations. Both build `build/AllTheThings-Debug.app` first, then launch the app executable with CodeLLDB.

Use the VSCode Run and Debug panel configuration named `Debug AllTheThings` for direct app debugging. If prompted to select a launch target for running, choose `LaunchAllTheThings`.

## Architecture

```text
Swift/AppKit UI
        +
ATTCore Swift package
        +
filesystem crawler
        +
JSON snapshot persistence
        +
FSEvents refresh pipeline
```

The core is isolated in `Sources/ATTCore` so the persistence/search backend can later move to the planned mmap snapshot and WAL design without rewriting the AppKit table experience.

## Current Limits

This is a working MVP, not the final high-performance engine described in the product design.

- The initial crawler uses Foundation APIs rather than `getattrlistbulk`.
- The snapshot is JSON rather than memory-mapped columnar storage.
- Search is currently in-memory scoring over indexed records, with supporting indexes for common fast paths.
- FSEvents are treated as dirty-path refresh signals, but there is not yet a WAL or full reconciliation scheduler.
- Full Disk Access onboarding and global hotkey support are not implemented yet.

## Support Development

If AllTheThings saves you time, consider supporting continued work through [GitHub Sponsors](https://github.com/sponsors/MikeMarcin), starring the repository, or filing focused issues with reproducible examples.
