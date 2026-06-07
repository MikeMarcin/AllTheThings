#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_FULL_SUITE=0
REQUIRE_SANITIZERS=0
RUN_SANITIZERS=1

usage() {
    cat <<'EOF'
Usage: tools/safety-check.sh [options]

Run crash-safety checks for native macOS hazards: raw filesystem APIs,
unchecked Sendable boundaries, indexing concurrency, and FSEvents refresh paths.

Options:
  --full             Also run the full Swift test suite.
  --no-sanitizers    Skip Address Sanitizer and Thread Sanitizer lanes.
  --require-sanitizers
                     Fail if a sanitizer runtime is unavailable.
  -h, --help         Show this help.
EOF
}

log() {
    printf '==> %s\n' "$*"
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --full)
            RUN_FULL_SUITE=1
            shift
            ;;
        --no-sanitizers)
            RUN_SANITIZERS=0
            shift
            ;;
        --require-sanitizers)
            REQUIRE_SANITIZERS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

cd "${ROOT_DIR}"
require_command rg
require_command swift

run_swift_test() {
    local label="$1"
    shift
    log "${label}"
    swift test --disable-sandbox --no-parallel "$@"
}

run_sanitized_test() {
    local sanitizer="$1"
    local scratch="$2"
    local filter="$3"
    local output_log
    output_log="$(mktemp "${TMPDIR:-/tmp}/att-${sanitizer}-test.XXXXXX.log")"
    log "${sanitizer} sanitizer: ${filter}"

    if swift test \
        --scratch-path "${scratch}" \
        --sanitize "${sanitizer}" \
        --disable-sandbox \
        --no-parallel \
        --filter "${filter}" 2>&1 | tee "${output_log}"; then
        rm -f "${output_log}"
        return 0
    fi

    if rg -q 'Sanitizer load violates platform policy|inserted dylib .* could not be loaded|libclang_rt\..* could not be loaded' "${output_log}"; then
        rm -f "${output_log}"
        if [[ "${REQUIRE_SANITIZERS}" == "1" ]]; then
            fail "${sanitizer} sanitizer runtime is blocked by platform policy."
        fi
        log "Skipping ${sanitizer} sanitizer: SwiftPM test helper cannot load the sanitizer runtime in this environment"
        return 0
    fi

    rm -f "${output_log}"
    return 1
}

sanitizer_available() {
    local sanitizer="$1"
    local probe_dir
    probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/att-${sanitizer}-sanitizer.XXXXXX")"

    printf 'print("sanitizer probe")\n' > "${probe_dir}/main.swift"
    if ! swiftc -sanitize="${sanitizer}" "${probe_dir}/main.swift" -o "${probe_dir}/probe" >"${probe_dir}/build.log" 2>&1; then
        sed 's/^/    /' "${probe_dir}/build.log" >&2
        rm -rf "${probe_dir}"
        return 1
    fi

    if ! "${probe_dir}/probe" >"${probe_dir}/run.log" 2>&1; then
        sed 's/^/    /' "${probe_dir}/run.log" >&2
        rm -rf "${probe_dir}"
        return 1
    fi

    rm -rf "${probe_dir}"
    return 0
}

run_sanitized_test_if_available() {
    local sanitizer="$1"
    local scratch="$2"
    local filter="$3"

    if sanitizer_available "${sanitizer}"; then
        run_sanitized_test "${sanitizer}" "${scratch}" "${filter}"
        return
    fi

    if [[ "${REQUIRE_SANITIZERS}" == "1" ]]; then
        fail "${sanitizer} sanitizer runtime is unavailable."
    fi

    log "Skipping ${sanitizer} sanitizer: runtime unavailable in this environment"
}

assert_no_match() {
    local pattern="$1"
    local description="$2"
    local matches
    matches="$(rg -n "${pattern}" Sources -g '*.swift' || true)"
    if [[ -n "${matches}" ]]; then
        printf '%s\n' "${matches}" >&2
        fail "${description}"
    fi
}

assert_no_multiline_match() {
    local pattern="$1"
    local description="$2"
    local matches
    matches="$(rg -n -U "${pattern}" Sources -g '*.swift' || true)"
    if [[ -n "${matches}" ]]; then
        printf '%s\n' "${matches}" >&2
        fail "${description}"
    fi
}

log "Checking banned native-safety patterns"
assert_no_match 'String\(cString:' 'Do not decode filesystem or process data with unbounded String(cString:) in Sources.'
assert_no_match 'entry\.pointee\.d_name|entry\.pointee\.d_type' 'Do not materialize dirent tuple fields from readdir records; use bounded raw-pointer decoding.'
assert_no_multiline_match 'withApplicationAt:[\s\S]{0,600}completionHandler:\s*\{' 'NSWorkspace Open With callbacks must not capture UI state directly; use nil completion or explicit main-actor hops.'

log "Writing current reviewed high-risk Swift pattern inventory"
mkdir -p build
rg -n '@unchecked Sendable|Unsafe(Mutable|Raw)?(Buffer)?Pointer|withMemoryRebound|assumingMemoryBound|mmap|mprotect|readdir|fdopendir|DispatchQueue\.global|Task\.detached|nonisolated\(unsafe\)|NSWorkspace\.shared\.open' Sources Tests -g '*.swift' > build/native-safety-inventory.txt || true
log "Inventory: build/native-safety-inventory.txt"

run_swift_test "Focused dirent guard-page regression" --filter FileIndexTests/directoryEntryDecodingReadsOnlyRecordNameBytes
run_swift_test "Focused indexing and refresh safety tests" --filter 'FileIndexTests|FileExclusionRulesTests|FileSystemWatcherTests'

if [[ "${RUN_FULL_SUITE}" == "1" ]]; then
    run_swift_test "Full Swift test suite"
fi

if [[ "${RUN_SANITIZERS}" == "1" ]]; then
    run_sanitized_test_if_available address .build/safety-address 'FileIndexTests|FileExclusionRulesTests'
    run_sanitized_test_if_available thread .build/safety-thread 'FileIndexTests|FileExclusionRulesTests|FileSystemWatcherTests'
else
    log "Skipping sanitizer lanes"
fi

log "Native safety checks passed"
