#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/simulator.sh
source "$SCRIPT_DIRECTORY/lib/simulator.sh"

COVERAGE_THRESHOLD="${COVERAGE_THRESHOLD:-70}"   # same gate as the GitHub CI job

usage() {
  cat >&2 <<'USAGE'
Usage: ./scripts/run_tests.sh [--skip-kit] [--only-testing TEST]...

  --skip-kit           do not run the ConnectOnionKit package tests first
  --only-testing TEST  run just this test, for example
                       OOChatIOSTests/HostedAgentConnectionTests
                       (the coverage gate is skipped for partial runs)

Environment: SIMULATOR_NAME, SIMULATOR_UDID, COVERAGE_THRESHOLD, SIMULATOR_BOOT_TIMEOUT
USAGE
}

RUN_KIT=1
ONLY_TESTING=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-kit)
      RUN_KIT=0
      shift
      ;;
    --only-testing)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      ONLY_TESTING+=("-only-testing:$2")
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

cd "$PROJECT_DIRECTORY"

if [[ "$RUN_KIT" == "1" ]]; then
  "$SCRIPT_DIRECTORY/run_kit_tests.sh"
fi

simulator_prepare

DERIVED_DATA_PATH="${TMPDIR:-/tmp}/OOChatIOSDerivedData-${UID}"
RESULT_BUNDLE_PATH="${TMPDIR:-/tmp}/OOChatIOS-${UID}.xcresult"

# xcodebuild refuses to overwrite an existing result bundle.
rm -rf "$RESULT_BUNDLE_PATH"

arguments=(
  test
  -project OOChatIOS.xcodeproj
  -scheme OOChatIOS
  -configuration Debug
  -sdk iphonesimulator
  -destination "platform=iOS Simulator,id=$SIM_UDID"
  -parallel-testing-enabled NO
  -derivedDataPath "$DERIVED_DATA_PATH"
  -enableCodeCoverage YES
  -resultBundlePath "$RESULT_BUNDLE_PATH"
)
if [[ ${#ONLY_TESTING[@]} -gt 0 ]]; then
  arguments+=("${ONLY_TESTING[@]}")
fi

status=0
COPYFILE_DISABLE=1 xcodebuild "${arguments[@]}" || status=$?

if [[ "$status" -ne 0 ]]; then
  echo >&2
  echo "Tests failed (exit $status). Result bundle: $RESULT_BUNDLE_PATH" >&2
  echo "If the failure was a simulator boot timeout, run ./scripts/reset_simulator.sh and try again." >&2
  exit "$status"
fi

echo
echo "Swift code coverage by target:"
xcrun xccov view --report --only-targets "$RESULT_BUNDLE_PATH"

if [[ ${#ONLY_TESTING[@]} -eq 0 && "$COVERAGE_THRESHOLD" != "0" ]]; then
  "$SCRIPT_DIRECTORY/check_coverage.sh" "$RESULT_BUNDLE_PATH" "$COVERAGE_THRESHOLD" OOChatIOS.app
fi
