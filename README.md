# AllTheThings

AllTheThings is a native macOS file-search app. It indexes file metadata locally and returns results as you type.

**[Download the latest release](https://github.com/MikeMarcin/AllTheThings/releases/latest)** for macOS 15 or newer on Apple Silicon. Website: [gamecoretech.com](https://gamecoretech.com/).

<picture>
  <source srcset="docs/images/allthethings-demo.webp" type="image/webp">
  <img src="docs/images/allthethings-demo.png" alt="AllTheThings filtering a safe demo folder for planner Swift files with middle-word match indicators">
</picture>

## Getting started

1. Download the DMG from the [latest release](https://github.com/MikeMarcin/AllTheThings/releases/latest).
2. Move AllTheThings to Applications and open it.
3. Start typing. Search works while the initial index is still being built.

By default the index covers `~/Desktop`, `~/Documents`, `~/Downloads`, and `~/Developer` when they exist. Change the list, add application search folders, or rebuild the index in **Settings > Indexed Folders**.

Two optional global shortcuts live in **Settings > Hotkeys**. Enable launch at login if you want them available right after signing in.

- `Command-Shift-Space` opens file search.
- `Shift-Option-Space` opens application search.

## Searching

Queries are case-insensitive and diacritic-insensitive. Separate terms with spaces to require all of them.

| Query | Meaning |
| --- | --- |
| `psr` | Fuzzy and acronym match, such as `PhotoSyncReport.final.pdf`. |
| `redme` | Small typo match for a filename like `README.md`. |
| `*.swift` | `*` matches any run of characters and `?` matches one. |
| `ext:swift\|md` | `\|` separates alternatives. |
| `name:Search*.swift` | Match a pattern against the file name only. |
| `path:Sources ext:swift` | Combine constraints. Path tokens and extensions stack. |
| `package !path:node_modules` | Exclude with `!` or `-`. |
| `~/Projects/**/*.json` | Search below a folder. `**` spans nested folders. |
| `"query planner"` | Quotes match the exact substring, spaces included. |
| `app:terminal` | Search installed applications instead of files. |
| `history:swift package` | Search your own past queries. |

Syntax reference:

- Prefixes: `name:`, `path:`, `ext:`, and `kind:` constrain file metadata. `app:` and `history:` switch search modes.
- Modifiers: `!` or `-` excludes a term, `|` separates alternatives, and double quotes match an exact substring.
- Wildcards: `*` matches any run of characters, `?` matches one, `[abc]` matches one from a set (`*.[hic]pp` matches `.hpp`, `.ipp`, and `.cpp`), and `**` spans folders.
- Application bundles are indexed separately and searched with `app:`, so their internal files stay out of normal results.

### Search history

- Press `Command-Y`, click the history button, or type `history:` to browse earlier searches. Add text after the prefix to filter, then press Return to restore a query.
- `Control-R` and `Control-Shift-R` step backward and forward through history without opening the browser.
- A query is recorded once it sits unchanged for three seconds or you act on its results. Keystrokes and `history:` lookups are never recorded.
- **Settings > General > Search history retention** keeps 50 searches by default.

Keyboard navigation and management details are in [docs/SEARCH_HISTORY.md](docs/SEARCH_HISTORY.md).

## Actions

Select one or more results to open, reveal in Finder, rename, preview, inspect, or move to Trash.

- `Command-C` copies the files.
- `Command-Option-C` copies their paths.
- With Ghostty or iTerm2 installed, their macOS Services open a terminal in the selected folder.

## Insights

**AllTheThings > Insights...** (`Command-Option-Shift-I`) shows what the index costs: files tracked, disk used by the index package, how each search was routed and how long it took, and CPU time and wakeups over the last hour, day, or three months.

<picture>
  <source srcset="docs/images/allthethings-insights.webp" type="image/webp">
  <img src="docs/images/allthethings-insights.png" alt="The Insights window on the Energy tab, showing CPU share of the system, wakeups per minute, and an hour of CPU history">
</picture>

## Updates

AllTheThings checks GitHub Releases once a day. **AllTheThings > Check for Updates...** checks now; **AllTheThings > Automatically Check for Updates** turns the daily check off.

## Privacy

- The index holds file metadata, not file contents.
- The index, search history, and diagnostic logs stay on your Mac and are never attached to update checks.
- Raw logs can contain queries and paths. Use **AllTheThings > Export Anonymized Diagnostic Log...** before sharing one.
- High-noise directories such as `node_modules`, `DerivedData`, `.git/objects`, `Library/Caches`, and `.Trash` are skipped.
- macOS may ask for access when the index reaches Desktop, Documents, Downloads, or other protected locations. Grant Full Disk Access in **System Settings > Privacy & Security**, or limit the index to folders the app can already read.

## Troubleshooting

- A file is missing: confirm its parent folder is indexed and not inside a skipped directory, then use **Reindex** if needed.
- An application is missing: check the **Application Search** folders in **Settings > Indexed Folders**.

## Contributing

Build instructions, architecture notes, and implementation limits are in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Bug reports with reproducible cases, documentation fixes, and pull requests are welcome. Development is supported through [GitHub Sponsors](https://github.com/sponsors/MikeMarcin).

## License

AllTheThings is released under the [MIT License](LICENSE).
