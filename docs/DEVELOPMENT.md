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

## Release Packaging

Create a Developer ID Application certificate in your Apple Developer account or in Xcode, then install it in your login keychain. Store notarization credentials once with:

```sh
xcrun notarytool store-credentials "AllTheThings-notary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID1234" \
  --password "app-specific-password"
```

Package a release with:

```sh
APPLE_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID1234)" \
APPLE_NOTARY_PROFILE="AllTheThings-notary" \
tools/release.sh
```

The script reads the version from `Resources/Info.plist`, runs the test suite, runs sanitizer-backed native safety checks, builds `build/AllTheThings.app`, signs it with hardened runtime, creates and signs a DMG, submits the DMG for notarization, staples and validates the DMG, then writes the DMG, a backup ZIP, and SHA-256 checksums under `build/releases/<version>/`. Upload the DMG as the primary GitHub Release asset. Upload the ZIP as a backup asset so the in-app updater still has a fallback archive format.

For a local packaging smoke test without Developer ID credentials:

```sh
tools/release.sh --skip-sign --skip-notarize --allow-dirty
```

## Native Safety Checks

Run the native safety gate before shipping changes that touch indexing, filesystem watching, raw Darwin APIs, AppKit callbacks, or `@unchecked Sendable` types:

```sh
tools/safety-check.sh
```

The gate rejects previously crash-prone patterns such as `String(cString:)` in app sources, direct `dirent.d_name` / `dirent.d_type` tuple access, and Open With completion blocks that can accidentally touch UI state off-main. It also writes a reviewed high-risk pattern inventory to `build/native-safety-inventory.txt`, runs the focused indexing, exclusion-rule, and FSEvents suites, then reruns those crash-prone paths under Address Sanitizer and Thread Sanitizer when the local Xcode/macOS policy allows sanitizer runtimes to load.

To require sanitizer runtime availability, use:

```sh
tools/safety-check.sh --require-sanitizers
```

For the broader local gate, run:

```sh
tools/safety-check.sh --full
```

The release script runs `tools/safety-check.sh` after the normal test suite. Use `--skip-safety-checks` only for local packaging experiments where sanitizer coverage is intentionally deferred.

## VSCode

The repository includes VSCode workspace tasks:

- `CMake: Build App`
- `CMake: Run App`
- `CMake: Test`
- `CMake: Run Native Safety Checks`
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
mmap-backed snapshot package
        +
FSEvents refresh pipeline
```

The core is isolated in `Sources/ATTCore` so the mmap snapshot and refresh-overlay backend can evolve without rewriting the AppKit table experience.

## Current Limits

This is a working MVP, not the final high-performance engine described in the product design.

- The initial crawler uses Foundation APIs rather than `getattrlistbulk`.
- The saved snapshot is a v6 `filename-index-v6.attindex` package with mapped record rows, string/path lookup data, visibility sidecars, component namespace rows, and persisted search structures.
- Search scores lightweight record views and only materializes `FileRecord` values for returned rows, with persisted indexes and sorted orders for common fast paths.
- FSEvents are treated as dirty-path refresh signals, but there is not yet a WAL or full reconciliation scheduler.
- Full Disk Access status is informational and conservative; indexing behavior has not been overhauled around macOS privacy prompts yet.

## Memory Diagnostics

Index load, rebuild, refresh, snapshot build, and persistence paths emit `com.allthethings.index` memory log events with `task_vm_info` counters and index structure sizes. For synthetic budget checks without creating files on disk, run:

```sh
ATT_MEMORY_BENCH_RECORDS=250000 swift test --filter optInSyntheticMemoryBenchmark
```

Use a larger value, such as `5000000`, for local stress testing on a machine with enough memory headroom.
Initial scan parallelism defaults to `min(8, max(2, activeProcessorCount))`; set `ATT_INDEX_SCAN_WORKERS` to compare filesystem throughput with a fixed worker count.
