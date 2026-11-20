#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib/simulator.sh
source "$SCRIPT_DIRECTORY/lib/simulator.sh"

usage() {
  echo "Usage: ./scripts/bootstrap-dev.sh [--reset]" >&2
  echo "  --reset  also delete the local build folder and package caches" >&2
}

if [[ $# -gt 1 || "${1:-}" == "--help" ]]; then
  usage
  exit 2
fi
if [[ $# -eq 1 && "$1" != "--reset" ]]; then
  usage
  exit 2
fi

step() {
  printf '[bootstrap] %s\n' "$1"
}

command -v xcodebuild >/dev/null 2>&1 \
  || { echo "error: Xcode is not installed or not selected (xcode-select)." >&2; exit 2; }
case "$(xcode-select -p)" in
  */CommandLineTools)
    echo "error: only the Command Line Tools are selected. Run: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 2
    ;;
esac
xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 \
  || { echo "error: finish Xcode's first-launch setup (open Xcode once)." >&2; exit 2; }
step "Using $(xcodebuild -version | head -n 1)"

if ! command -v brew >/dev/null 2>&1; then
  echo "error: Homebrew is required for SwiftLint. See https://brew.sh" >&2
  exit 2
fi
step "Installing tools from Brewfile"
brew bundle --file "$PROJECT_DIRECTORY/Brewfile"

if [[ "${1:-}" == "--reset" ]]; then
  step "Removing build folders"
  rm -rf "$PROJECT_DIRECTORY/build" "$PROJECT_DIRECTORY/Packages/ConnectOnionKit/.build"
fi

step "Resolving Swift packages"
(
  cd "$PROJECT_DIRECTORY"
  xcodebuild -resolvePackageDependencies -project OOChatIOS.xcodeproj -scheme OOChatIOS >/dev/null
)

step "Booting a simulator so the first test run does not time out"
simulator_prepare

echo "Development environment ready. Next: ./scripts/run_tests.sh"
