#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AllTheThings"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="${ROOT_DIR}/Resources/Info.plist"
LEGACY_BUNDLE_IDS=("com.gamecoretech.AllTheThings")

DRY_RUN=0
YES=0
QUIT_APP=0

usage() {
    cat <<EOF
Usage: tools/reset-app-state.sh [options]

Delete AllTheThings cached data and settings so the next launch behaves like a
fresh install.

Options:
  --dry-run       Print what would be deleted without changing anything.
  --yes           Do not prompt before deleting state.
  --quit-app      Ask AllTheThings to quit before deleting state.
  -h, --help      Show this help.

This removes:
  - ~/Library/Application Support/AllTheThings
  - AllTheThings user defaults for com.gamecoretech.allthethings
    (including indexed folders and first-run indexing setup state)
  - app caches, HTTP storage, saved window state, and sandbox container state

macOS privacy approvals and Login Items approval are owned by the OS and are not
reset by this script.
EOF
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '==> %s\n' "$*"
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "${INFO_PLIST}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --yes)
            YES=1
            shift
            ;;
        --quit-app)
            QUIT_APP=1
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

[[ -f "${INFO_PLIST}" ]] || fail "Info.plist not found: ${INFO_PLIST}"

BUNDLE_ID="$(plist_value CFBundleIdentifier)"
[[ -n "${BUNDLE_ID}" ]] || fail "Could not read CFBundleIdentifier from ${INFO_PLIST}"

running_pids() {
    pgrep -x "${APP_NAME}" 2>/dev/null || true
}

wait_for_app_exit() {
    local attempt

    for attempt in {1..40}; do
        if [[ -z "$(running_pids)" ]]; then
            return 0
        fi
        sleep 0.25
    done

    return 1
}

quit_app_if_needed() {
    local pids
    pids="$(running_pids)"
    [[ -n "${pids}" ]] || return 0

    if [[ "${DRY_RUN}" == "1" ]]; then
        log "would require ${APP_NAME} to quit; running pid(s): ${pids//$'\n'/, }"
        return 0
    fi

    if [[ "${QUIT_APP}" != "1" ]]; then
        fail "${APP_NAME} is running with pid(s): ${pids//$'\n'/, }. Quit it first or pass --quit-app."
    fi

    log "quitting ${APP_NAME}"
    osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true

    if ! wait_for_app_exit; then
        log "${APP_NAME} did not quit; terminating remaining process(es)"
        pkill -x "${APP_NAME}" 2>/dev/null || true
        wait_for_app_exit || fail "Could not stop ${APP_NAME}; reset aborted."
    fi
}

confirm_reset() {
    if [[ "${DRY_RUN}" == "1" || "${YES}" == "1" ]]; then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        fail "Refusing to delete state without a TTY prompt. Re-run with --yes."
    fi

    printf 'Delete cached data and settings for %s (%s)? [y/N] ' "${APP_NAME}" "${BUNDLE_ID}"
    local answer
    read -r answer

    case "${answer}" in
        y|Y|yes|YES)
            ;;
        *)
            fail "Reset cancelled."
            ;;
    esac
}

remove_path() {
    local path="$1"

    if [[ ! -e "${path}" && ! -L "${path}" ]]; then
        return 0
    fi

    if [[ "${DRY_RUN}" == "1" ]]; then
        log "would remove ${path}"
    else
        log "removing ${path}"
        rm -rf -- "${path}"
    fi
}

remove_matching_files() {
    local directory="$1"
    local name_pattern="$2"

    [[ -d "${directory}" ]] || return 0

    while IFS= read -r -d '' path; do
        remove_path "${path}"
    done < <(find "${directory}" -maxdepth 1 -name "${name_pattern}" -print0)
}

delete_defaults_domain() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        if defaults read "${BUNDLE_ID}" >/dev/null 2>&1; then
            log "would delete defaults domain ${BUNDLE_ID}"
        fi
        for legacy_bundle_id in "${LEGACY_BUNDLE_IDS[@]}"; do
            if defaults read "${legacy_bundle_id}" >/dev/null 2>&1; then
                log "would delete legacy defaults domain ${legacy_bundle_id}"
            fi
        done
        return 0
    fi

    if defaults read "${BUNDLE_ID}" >/dev/null 2>&1; then
        log "deleting defaults domain ${BUNDLE_ID}"
        defaults delete "${BUNDLE_ID}" >/dev/null 2>&1 || true
    fi

    for legacy_bundle_id in "${LEGACY_BUNDLE_IDS[@]}"; do
        if defaults read "${legacy_bundle_id}" >/dev/null 2>&1; then
            log "deleting legacy defaults domain ${legacy_bundle_id}"
            defaults delete "${legacy_bundle_id}" >/dev/null 2>&1 || true
        fi
    done
}

main() {
    local home="${HOME}"
    local preferences_dir="${home}/Library/Preferences"

    confirm_reset
    quit_app_if_needed

    delete_defaults_domain

    remove_path "${home}/Library/Application Support/${APP_NAME}"
    remove_path "${home}/Library/Caches/${BUNDLE_ID}"
    remove_path "${home}/Library/Caches/${APP_NAME}"
    for legacy_bundle_id in "${LEGACY_BUNDLE_IDS[@]}"; do
        remove_path "${home}/Library/Caches/${legacy_bundle_id}"
        remove_path "${home}/Library/HTTPStorages/${legacy_bundle_id}"
        remove_path "${home}/Library/HTTPStorages/${legacy_bundle_id}.binarycookies"
        remove_path "${home}/Library/Saved Application State/${legacy_bundle_id}.savedState"
        remove_path "${preferences_dir}/${legacy_bundle_id}.plist"
        remove_matching_files "${preferences_dir}/ByHost" "${legacy_bundle_id}.*.plist"
        remove_path "${home}/Library/Containers/${legacy_bundle_id}"
        remove_path "${home}/Library/Group Containers/${legacy_bundle_id}"
    done
    remove_path "${home}/Library/HTTPStorages/${BUNDLE_ID}"
    remove_path "${home}/Library/HTTPStorages/${BUNDLE_ID}.binarycookies"
    remove_path "${home}/Library/Saved Application State/${BUNDLE_ID}.savedState"
    remove_path "${preferences_dir}/${BUNDLE_ID}.plist"
    remove_matching_files "${preferences_dir}/ByHost" "${BUNDLE_ID}.*.plist"
    remove_path "${home}/Library/Containers/${BUNDLE_ID}"
    remove_path "${home}/Library/Group Containers/${BUNDLE_ID}"

    if [[ "${DRY_RUN}" != "1" ]]; then
        killall cfprefsd >/dev/null 2>&1 || true
        log "reset complete"
        log "next launch will use first-run settings and rebuild its index"
    else
        log "dry run complete"
    fi
}

main "$@"
