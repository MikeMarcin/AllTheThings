# AllTheThings

AllTheThings is a native macOS file-search app focused on one workflow: type a fuzzy filename or path query and get a fast, sortable, live-updating table of files.

This repository currently contains the first AppKit MVP:

- Native Swift/AppKit window with a dark-first table UI.
- Search-as-you-type filename/path fuzzy matching.
- Sortable columns for name, path, modified date, size, created date, extension, kind, and volume.
- Empty-query mode sorted by modified date for watching recent filesystem activity.
- User-selectable indexed folders.
- FSEvents-based live refresh for changed paths.
- Persistent warm-start filename snapshot in Application Support.
- File actions: open, reveal in Finder, and copy path.

## Requirements

- macOS 15 Sequoia or newer
- Apple Silicon target
- Xcode 16.2 / Swift 6 toolchain

## Build

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

The default build task is `CMake: Build App`. The Run and Debug panel has `Run AllTheThings` and `Debug AllTheThings` configurations. Both build `build/AllTheThings-Debug.app` first, then launch the app executable with CodeLLDB.

Use the VSCode Run and Debug panel configuration named `Debug AllTheThings` for direct app debugging. The CMake Tools status-bar debug button can also work if you select the `DebugAllTheThings` launch target first; workspace settings force it to use CodeLLDB instead of the unsupported `lldb --interpreter=mi` path.

`CMake: Run App` opens a visible terminal and waits until the app exits. The CMake Tools status-bar run button uses the `LaunchAllTheThings` executable target, which builds `build/AllTheThings.app` first and then launches it with `open -W`. If prompted to select a launch target for running, choose `LaunchAllTheThings`.

## Current Architecture

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

The core is intentionally isolated in `Sources/ATTCore` so the persistence/search backend can later move to the planned mmap snapshot + WAL design without rewriting the AppKit table experience.

## MVP Limits

This is a working MVP, not the final high-performance engine described in the product design.

- The initial crawler uses Foundation APIs rather than `getattrlistbulk`.
- The snapshot is JSON rather than memory-mapped columnar storage.
- Search is currently in-memory linear scoring over indexed records.
- FSEvents are treated as dirty-path refresh signals, but there is not yet a WAL or full reconciliation scheduler.
- Full Disk Access onboarding and global hotkey support are not implemented yet.

Those are the next major engineering steps after validating the table-first product loop.
