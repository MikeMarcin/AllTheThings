# Development

This document is for contributors building or changing AllTheThings from source. The main [README](../README.md) stays focused on using the app.

## Requirements

- macOS 15 Sequoia or newer
- Apple Silicon Mac
- Xcode 16.2 / Swift 6 toolchain

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
- Full Disk Access onboarding is not implemented yet.
