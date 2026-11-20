#!/bin/bash
set -euo pipefail

# Runs the SwiftData persistence tests on every installed iOS runtime, newest
# first. One runtime hid a bug that only iOS 17 showed (see
# .github/workflows/ios-persistence-matrix.yml), so this is the local version
# of that matrix.
#
#   ./scripts/run_robustness_tests.sh              every installed runtime
#   IOS_RUNTIMES="17.5 26.0" ./scripts/run_robustness_tests.sh

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/simulator.sh
source "$SCRIPT_DIRECTORY/lib/simulator.sh"

cd "$PROJECT_DIRECTORY"

if [[ -n "${IOS_RUNTIMES:-}" ]]; then
  RUNTIMES="$IOS_RUNTIMES"
else
  RUNTIMES="$(simulator_runtimes)"
fi
[[ -n "$RUNTIMES" ]] || sim_fail "no iOS $MINIMUM_IOS_MAJOR+ runtime is installed."

DERIVED_DATA_PATH="${TMPDIR:-/tmp}/OOChatIOSRobustnessDerivedData-${UID}"
failed=""
passed=""

for runtime in $RUNTIMES; do
  echo
  echo "=== iOS $runtime ==="
  if ! selected="$(simulator_select "$runtime")"; then
    echo "No simulator for iOS $runtime; skipping."
    continue
  fi
  IFS=$'\t' read -r SIM_UDID _ _ SIM_STATE <<<"$selected"
  simulator_boot "$SIM_UDID" "$SIM_STATE"

  result_bundle="${TMPDIR:-/tmp}/OOChatIOS-persistence-${runtime}-${UID}.xcresult"
  rm -rf "$result_bundle"
  if COPYFILE_DISABLE=1 xcodebuild test \
      -project OOChatIOS.xcodeproj \
      -scheme OOChatIOS \
      -configuration Debug \
      -sdk iphonesimulator \
      -destination "platform=iOS Simulator,id=$SIM_UDID" \
      -parallel-testing-enabled NO \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      -only-testing:OOChatIOSTests/SwiftDataConversationRepositoryTests \
      -resultBundlePath "$result_bundle"; then
    passed="$passed $runtime"
  else
    failed="$failed $runtime"
  fi
done

echo
echo "Passed:${passed:- none}"
echo "Failed:${failed:- none}"
[[ -z "$failed" ]]
