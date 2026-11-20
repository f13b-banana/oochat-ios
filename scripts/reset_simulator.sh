#!/bin/bash
set -euo pipefail

# Fixes "Timed out trying to boot simulator". Restarts CoreSimulator, erases the
# simulator the tests use (its data only, not the runtime), and boots it again
# until it is fully up.
#
#   ./scripts/reset_simulator.sh          the simulator run_tests.sh would pick
#   ./scripts/reset_simulator.sh --all    erase every simulator

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/simulator.sh
source "$SCRIPT_DIRECTORY/lib/simulator.sh"

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--all" ) ]]; then
  echo "Usage: ./scripts/reset_simulator.sh [--all]" >&2
  exit 2
fi

sim_info "Stopping CoreSimulator"
xcrun simctl shutdown all >/dev/null 2>&1 || true
killall -9 com.apple.CoreSimulator.CoreSimulatorService >/dev/null 2>&1 || true
killall Simulator >/dev/null 2>&1 || true
sleep 2

if [[ "${1:-}" == "--all" ]]; then
  sim_info "Erasing all simulators"
  xcrun simctl erase all
fi

selected="$(simulator_select)" || sim_fail "no usable iPhone simulator."
IFS=$'\t' read -r SIM_UDID SIM_NAME SIM_RUNTIME _ <<<"$selected"

if [[ "${1:-}" != "--all" ]]; then
  sim_info "Erasing $SIM_NAME ($SIM_RUNTIME)"
  xcrun simctl erase "$SIM_UDID"
fi

sim_info "Booting $SIM_NAME; the first boot after an erase can take a few minutes"
simulator_boot "$SIM_UDID" "Shutdown"
sim_info "Ready: $SIM_UDID"
