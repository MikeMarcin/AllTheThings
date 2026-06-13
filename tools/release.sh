#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AllTheThings"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="${ROOT_DIR}/Resources/Info.plist"
APP_PATH="${ROOT_DIR}/build/${APP_NAME}.app"
DIST_ROOT="${ROOT_DIR}/build/releases"
DEFAULT_CODESIGN_IDENTITY="Developer ID Application: Michael Marcin (YTQKP2V2A8)"
DEFAULT_NOTARY_PROFILE="AllTheThings-notary"
RELEASE_BUILD_PRESET="app"

CONFIGURE_PRESET="${CONFIGURE_PRESET:-default}"
BUILD_PRESET="${BUILD_PRESET:-${RELEASE_BUILD_PRESET}}"
CODESIGN_IDENTITY="${APPLE_CODESIGN_IDENTITY:-${DEFAULT_CODESIGN_IDENTITY}}"
CODESIGN_ENTITLEMENTS="${CODESIGN_ENTITLEMENTS:-}"
NOTARY_PROFILE="${APPLE_NOTARY_PROFILE:-${DEFAULT_NOTARY_PROFILE}}"

ALLOW_DIRTY=0
SKIP_NOTARIZE=0
SKIP_SIGN=0
SKIP_SAFETY_CHECKS=0
SKIP_TESTS=0
OUTPUT_DIR=""
REQUESTED_VERSION=""

usage() {
    cat <<EOF
Usage: tools/release.sh [options]

Build, sign, optionally notarize, and package ${APP_NAME}.

Options:
  --version VERSION         Assert the Info.plist version matches VERSION.
  --identity NAME          Codesigning identity. Defaults to APPLE_CODESIGN_IDENTITY or ${DEFAULT_CODESIGN_IDENTITY}.
  --entitlements PATH      Optional entitlements plist. Defaults to CODESIGN_ENTITLEMENTS.
  --notary-profile NAME    notarytool keychain profile. Defaults to APPLE_NOTARY_PROFILE or ${DEFAULT_NOTARY_PROFILE}.
  --output-dir DIR         Release output directory. Defaults to build/releases/VERSION.
  --skip-tests             Do not run the CMake check preset.
  --skip-safety-checks     Do not run sanitizer-backed native safety checks.
  --skip-sign              Leave the CMake-built app's existing signature in place.
  --skip-notarize          Do not submit to Apple's notary service or staple a ticket.
  --allow-dirty            Allow packaging with uncommitted git changes.
  -h, --help               Show this help.

Environment:
  APPLE_CODESIGN_IDENTITY  Developer ID Application identity for codesign. Default: ${DEFAULT_CODESIGN_IDENTITY}.
  APPLE_NOTARY_PROFILE     xcrun notarytool keychain profile name. Default: ${DEFAULT_NOTARY_PROFILE}.
  CODESIGN_ENTITLEMENTS    Optional entitlements plist path.
  CONFIGURE_PRESET         CMake configure preset. Default: default.
  BUILD_PRESET             CMake build preset. Must be app for release packaging.
EOF
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '==> %s\n' "$*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "${INFO_PLIST}"
}

trim_blank_lines() {
    sed '/^[[:space:]]*$/d'
}

find_developer_id_identity() {
    local identities
    local count

    identities="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | trim_blank_lines)"
    count="$(printf '%s\n' "${identities}" | trim_blank_lines | wc -l | tr -d ' ')"

    if [[ "${count}" == "1" ]]; then
        printf '%s\n' "${identities}"
        return 0
    fi

    if [[ "${count}" == "0" ]]; then
        return 1
    fi

    fail "Multiple Developer ID Application identities found. Pass --identity or set APPLE_CODESIGN_IDENTITY."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || fail "--version requires a value"
            REQUESTED_VERSION="$2"
            shift 2
            ;;
        --identity)
            [[ $# -ge 2 ]] || fail "--identity requires a value"
            CODESIGN_IDENTITY="$2"
            shift 2
            ;;
        --entitlements)
            [[ $# -ge 2 ]] || fail "--entitlements requires a value"
            CODESIGN_ENTITLEMENTS="$2"
            shift 2
            ;;
        --notary-profile)
            [[ $# -ge 2 ]] || fail "--notary-profile requires a value"
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || fail "--output-dir requires a value"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --skip-tests)
            SKIP_TESTS=1
            shift
            ;;
        --skip-safety-checks)
            SKIP_SAFETY_CHECKS=1
            shift
            ;;
        --skip-sign)
            SKIP_SIGN=1
            shift
            ;;
        --skip-notarize)
            SKIP_NOTARIZE=1
            shift
            ;;
        --allow-dirty)
            ALLOW_DIRTY=1
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

if [[ "${BUILD_PRESET}" != "${RELEASE_BUILD_PRESET}" ]]; then
    fail "Release packaging requires BUILD_PRESET=${RELEASE_BUILD_PRESET}, which builds Swift with -c release. Got BUILD_PRESET=${BUILD_PRESET}."
fi

require_command cmake
require_command codesign
require_command ditto
require_command hdiutil
require_command swift

VERSION="$(plist_value CFBundleShortVersionString)"
BUILD_NUMBER="$(plist_value CFBundleVersion)"
VERSION="${VERSION#v}"

if [[ -n "${REQUESTED_VERSION}" && "${REQUESTED_VERSION#v}" != "${VERSION}" ]]; then
    fail "Requested version ${REQUESTED_VERSION} does not match Info.plist version ${VERSION}."
fi

if [[ -z "${OUTPUT_DIR}" ]]; then
    OUTPUT_DIR="${DIST_ROOT}/${VERSION}"
fi

if [[ "${ALLOW_DIRTY}" == "0" ]] && git -C "${ROOT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ -n "$(git -C "${ROOT_DIR}" status --porcelain)" ]]; then
        fail "Working tree has uncommitted changes. Commit them or pass --allow-dirty."
    fi
fi

if [[ "${SKIP_SIGN}" == "0" ]]; then
    require_command security

    if [[ -z "${CODESIGN_IDENTITY}" ]]; then
        CODESIGN_IDENTITY="$(find_developer_id_identity)" || fail "No Developer ID Application identity found. Pass --identity or set APPLE_CODESIGN_IDENTITY."
        log "Using codesigning identity: ${CODESIGN_IDENTITY}"
    fi

    if [[ -n "${CODESIGN_ENTITLEMENTS}" && ! -f "${CODESIGN_ENTITLEMENTS}" ]]; then
        fail "Entitlements file not found: ${CODESIGN_ENTITLEMENTS}"
    fi
fi

if [[ "${SKIP_NOTARIZE}" == "0" ]]; then
    require_command spctl
    require_command xcrun

    if [[ -z "${NOTARY_PROFILE}" ]]; then
        fail "No notary profile configured. Pass --notary-profile or set APPLE_NOTARY_PROFILE."
    fi

    if [[ "${SKIP_SIGN}" == "1" ]]; then
        fail "Notarization requires Developer ID signing. Remove --skip-sign or add --skip-notarize."
    fi
fi

log "Configuring ${APP_NAME}"
cmake --preset "${CONFIGURE_PRESET}"

if [[ "${SKIP_TESTS}" == "0" ]]; then
    log "Running tests"
    cmake --build --preset check
    if [[ "${SKIP_SAFETY_CHECKS}" == "0" ]]; then
        log "Running native safety checks"
        "${ROOT_DIR}/tools/safety-check.sh"
    else
        log "Skipping native safety checks"
    fi
else
    log "Skipping tests and native safety checks"
fi

log "Building optimized release app bundle"
cmake --build --preset "${BUILD_PRESET}"

[[ -d "${APP_PATH}" ]] || fail "Expected app bundle was not built: ${APP_PATH}"

if [[ "${SKIP_SIGN}" == "0" ]]; then
    log "Signing with Developer ID"
    codesign_args=(
        --force
        --timestamp
        --options runtime
        --sign "${CODESIGN_IDENTITY}"
    )

    if [[ -n "${CODESIGN_ENTITLEMENTS}" ]]; then
        codesign_args+=(--entitlements "${CODESIGN_ENTITLEMENTS}")
    fi

    codesign "${codesign_args[@]}" "${APP_PATH}"
else
    log "Skipping Developer ID signing"
fi

log "Verifying code signature"
codesign --verify --strict --verbose=4 "${APP_PATH}"

mkdir -p "${OUTPUT_DIR}"

ARCH="$(uname -m)"
ASSET_BASE="${APP_NAME}-${VERSION}-macos-${ARCH}"
DMG_PATH="${OUTPUT_DIR}/${ASSET_BASE}.dmg"
ZIP_PATH="${OUTPUT_DIR}/${ASSET_BASE}.zip"
DMG_CHECKSUM_PATH="${DMG_PATH}.sha256"
ZIP_CHECKSUM_PATH="${ZIP_PATH}.sha256"
DMG_ROOT="${OUTPUT_DIR}/${ASSET_BASE}-dmg-root"

rm -f "${DMG_PATH}" "${ZIP_PATH}" "${DMG_CHECKSUM_PATH}" "${ZIP_CHECKSUM_PATH}"
rm -rf "${DMG_ROOT}"
mkdir -p "${DMG_ROOT}"
ditto "${APP_PATH}" "${DMG_ROOT}/${APP_NAME}.app"
ln -s /Applications "${DMG_ROOT}/Applications"

log "Creating release DMG"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_ROOT}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"
rm -rf "${DMG_ROOT}"

if [[ "${SKIP_SIGN}" == "0" ]]; then
    log "Signing release DMG"
    codesign --force --timestamp --sign "${CODESIGN_IDENTITY}" "${DMG_PATH}"
else
    log "Skipping DMG signing"
fi

log "Verifying DMG signature"
codesign --verify --strict --verbose=4 "${DMG_PATH}"

if [[ "${SKIP_NOTARIZE}" == "0" ]]; then
    log "Submitting DMG to Apple notary service"
    xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait

    log "Stapling notarization ticket to DMG"
    xcrun stapler staple "${DMG_PATH}"
    xcrun stapler validate "${DMG_PATH}"

    log "Assessing DMG with Gatekeeper"
    spctl --assess --type open --context context:primary-signature --verbose=4 "${DMG_PATH}"

    log "Stapling notarization ticket to app"
    xcrun stapler staple "${APP_PATH}"
    xcrun stapler validate "${APP_PATH}"

    log "Assessing app with Gatekeeper"
    spctl --assess --type execute --verbose=4 "${APP_PATH}"
else
    log "Skipping notarization"
fi

log "Creating backup release ZIP"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

log "Writing SHA-256 checksums"
(
    cd "${OUTPUT_DIR}"
    shasum -a 256 "$(basename "${DMG_PATH}")" > "$(basename "${DMG_CHECKSUM_PATH}")"
    shasum -a 256 "$(basename "${ZIP_PATH}")" > "$(basename "${ZIP_CHECKSUM_PATH}")"
)

cat <<EOF

Release package complete
  App:      ${APP_PATH}
  Version:  ${VERSION}
  Build:    ${BUILD_NUMBER}
  DMG:      ${DMG_PATH}
  ZIP:      ${ZIP_PATH}
  SHA-256:  ${DMG_CHECKSUM_PATH}
           ${ZIP_CHECKSUM_PATH}
EOF
