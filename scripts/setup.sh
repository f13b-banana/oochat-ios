#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPOSITORY_ROOT
readonly PROJECT_PATH="${REPOSITORY_ROOT}/OOChatIOS.xcodeproj"
readonly SCHEME_NAME="OOChatIOS"
readonly MINIMUM_IOS_MAJOR=17
readonly DEFAULT_DERIVED_DATA_PATH="${REPOSITORY_ROOT}/build/SetupDerivedData"
readonly PORTABLE_SWIFT_PACKAGES_PATH="${REPOSITORY_ROOT}/vendor/swift-packages"

info() {
  printf '[setup] %s\n' "$1"
}

warn() {
  printf '[setup] Warning: %s\n' "$1" >&2
}

fail() {
  printf '[setup] Error: %s\n' "$1" >&2
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Required command '$1' was not found."
  fi
}

find_compatible_python() {
  local candidate
  local candidate_path
  local candidates

  if [[ -n "${PYTHON_BIN:-}" ]]; then
    candidates=("${PYTHON_BIN}")
  else
    candidates=(python3 python3.14 python3.13 python3.12 python3.11 python3.10)
  fi

  for candidate in "${candidates[@]}"; do
    candidate_path="$(command -v "${candidate}" 2>/dev/null || true)"
    if [[ -z "${candidate_path}" ]]; then
      continue
    fi

    if "${candidate_path}" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' \
      >/dev/null 2>&1; then
      printf '%s\n' "${candidate_path}"
      return 0
    fi
  done

  return 1
}

select_simulator() {
  local simulator_json_path=$1
  local requested_udid=${SIMULATOR_UDID:-}
  local requested_name=${SIMULATOR_NAME:-}

  "${PYTHON_PATH}" - "${simulator_json_path}" "${requested_udid}" "${requested_name}" \
    "${MINIMUM_IOS_MAJOR}" <<'PYTHON'
import json
import re
import sys

json_path, requested_udid, requested_name, minimum_major_text = sys.argv[1:]
minimum_major = int(minimum_major_text)

try:
    with open(json_path, encoding="utf-8") as simulator_file:
        payload = json.load(simulator_file)
except (OSError, json.JSONDecodeError) as error:
    print(f"Unable to read Simulator information: {error}", file=sys.stderr)
    raise SystemExit(2)

candidates = []
for runtime_identifier, devices in payload.get("devices", {}).items():
    match = re.search(r"\.iOS-(\d+)(?:-(\d+))?", runtime_identifier)
    if not match:
        continue

    runtime_version = (int(match.group(1)), int(match.group(2) or 0))
    if runtime_version[0] < minimum_major:
        continue

    for device in devices:
        name = device.get("name", "")
        device_type = device.get("deviceTypeIdentifier", "")
        if not (name.startswith("iPhone") or ".iPhone-" in device_type):
            continue
        if device.get("isAvailable") is False:
            continue

        candidates.append(
            {
                "udid": device.get("udid", ""),
                "name": name,
                "runtime": f"iOS {runtime_version[0]}.{runtime_version[1]}",
                "runtime_version": runtime_version,
                "state": device.get("state", "Unknown"),
            }
        )

if requested_udid:
    candidates = [device for device in candidates if device["udid"] == requested_udid]
    if not candidates:
        print(
            f"SIMULATOR_UDID '{requested_udid}' is not an available iPhone "
            f"running iOS {minimum_major} or later.",
            file=sys.stderr,
        )
        raise SystemExit(3)
elif requested_name:
    candidates = [device for device in candidates if device["name"] == requested_name]
    if not candidates:
        print(
            f"SIMULATOR_NAME '{requested_name}' is not an available iPhone "
            f"running iOS {minimum_major} or later.",
            file=sys.stderr,
        )
        raise SystemExit(3)

if not candidates:
    print(
        f"No available iPhone Simulator running iOS {minimum_major} or later was found.",
        file=sys.stderr,
    )
    raise SystemExit(4)

candidates.sort(
    key=lambda device: (
        device["state"] != "Booted",
        -device["runtime_version"][0],
        -device["runtime_version"][1],
        device["name"],
    )
)
selected = candidates[0]
print(
    "\t".join(
        [
            selected["udid"],
            selected["name"],
            selected["runtime"],
            selected["state"],
        ]
    )
)
PYTHON
}

require_command xcode-select
require_command xcodebuild
require_command xcrun

if [[ ! -d "${PROJECT_PATH}" ]]; then
  fail "Xcode project not found at '${PROJECT_PATH}'. Run this script from the source checkout."
fi

DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null || true)"
if [[ -z "${DEVELOPER_DIR_PATH}" || ! -d "${DEVELOPER_DIR_PATH}" ]]; then
  fail "Xcode is not configured. Open Xcode once, complete its setup, and try again."
fi

if [[ "${DEVELOPER_DIR_PATH}" == *"/CommandLineTools" ]]; then
  fail "Only the Command Line Tools are selected. Select the full Xcode installation with xcode-select."
fi

if ! XCODE_VERSION="$(xcodebuild -version 2>/dev/null)"; then
  fail "Unable to use Xcode. Open Xcode once, accept its licence, and install its components."
fi
info "Xcode verified: $(printf '%s' "${XCODE_VERSION}" | head -n 1)"

if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  fail "Xcode first-launch setup is incomplete. Open Xcode and finish installing its components."
fi

if ! PYTHON_PATH="$(find_compatible_python)"; then
  fail "Python 3.10 or later was not found. Set PYTHON_BIN to a compatible Python executable."
fi
PYTHON_VERSION="$("${PYTHON_PATH}" -c 'import platform; print(platform.python_version())')"
info "Python verified: ${PYTHON_VERSION} (${PYTHON_PATH})"

if ! xcrun --find simctl >/dev/null 2>&1; then
  fail "The iOS Simulator tools are unavailable. Install an iOS Simulator runtime from Xcode."
fi

SIMULATOR_JSON="$(mktemp -t oochatios-simulators.XXXXXX)"
trap 'rm -f "${SIMULATOR_JSON}"' EXIT

if ! xcrun simctl list devices available --json >"${SIMULATOR_JSON}"; then
  fail "Unable to query iOS Simulators. Open Xcode and confirm that an iOS runtime is installed."
fi

if ! SELECTED_SIMULATOR="$(select_simulator "${SIMULATOR_JSON}")"; then
  fail "Install a compatible iOS Simulator in Xcode, or set SIMULATOR_NAME/SIMULATOR_UDID."
fi

IFS=$'\t' read -r SIMULATOR_UDID_VALUE SIMULATOR_NAME_VALUE SIMULATOR_RUNTIME_VALUE \
  SIMULATOR_STATE_VALUE <<<"${SELECTED_SIMULATOR}"
info "Simulator verified: ${SIMULATOR_NAME_VALUE} (${SIMULATOR_RUNTIME_VALUE})"

if [[ "${SIMULATOR_STATE_VALUE}" != "Booted" ]]; then
  info "Booting ${SIMULATOR_NAME_VALUE}..."
  xcrun simctl boot "${SIMULATOR_UDID_VALUE}"
fi
xcrun simctl bootstatus "${SIMULATOR_UDID_VALUE}" -b

if [[ "${SKIP_OPEN_SIMULATOR:-0}" != "1" ]]; then
  if ! open -a Simulator; then
    warn "The Simulator app could not be opened automatically."
  fi
fi

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${DEFAULT_DERIVED_DATA_PATH}}"
info "Building ${SCHEME_NAME}..."
XCODEBUILD_ARGUMENTS=(
  -quiet
  -project "${PROJECT_PATH}"
  -scheme "${SCHEME_NAME}"
  -configuration Debug
  -sdk iphonesimulator
  -destination "platform=iOS Simulator,id=${SIMULATOR_UDID_VALUE}"
  -derivedDataPath "${DERIVED_DATA_PATH}"
)

if [[ -d "${PORTABLE_SWIFT_PACKAGES_PATH}/checkouts" ]]; then
  info "Using bundled Swift package dependencies."
  XCODEBUILD_ARGUMENTS+=(
    -clonedSourcePackagesDirPath "${PORTABLE_SWIFT_PACKAGES_PATH}"
    -disableAutomaticPackageResolution
  )
else
  warn "Bundled Swift packages were not found; Xcode may download dependencies."
fi

info "Using Simulator ad-hoc signing; no Apple developer team is required."
xcodebuild \
  "${XCODEBUILD_ARGUMENTS[@]}" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  build

APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Debug-iphonesimulator/OOChatIOS.app"
if [[ ! -d "${APP_PATH}" ]]; then
  fail "The build completed, but the application was not found at '${APP_PATH}'."
fi

if [[ ! -x /usr/libexec/PlistBuddy ]]; then
  fail "PlistBuddy is unavailable, so the built application's bundle identifier cannot be read."
fi
BUNDLE_IDENTIFIER="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_PATH}/Info.plist"
)"
if [[ -z "${BUNDLE_IDENTIFIER}" ]]; then
  fail "The built application does not contain a bundle identifier."
fi

info "Installing ${BUNDLE_IDENTIFIER}..."
xcrun simctl install "${SIMULATOR_UDID_VALUE}" "${APP_PATH}"

xcrun simctl terminate "${SIMULATOR_UDID_VALUE}" "${BUNDLE_IDENTIFIER}" \
  >/dev/null 2>&1 || true
info "Launching ${BUNDLE_IDENTIFIER}..."
xcrun simctl launch "${SIMULATOR_UDID_VALUE}" "${BUNDLE_IDENTIFIER}"

info "Setup complete. OOChatIOS is running on ${SIMULATOR_NAME_VALUE}."
