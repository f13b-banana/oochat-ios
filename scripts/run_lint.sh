#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
# The GitLab lint job runs ghcr.io/realm/swiftlint at this version.
EXPECTED_SWIFTLINT_VERSION="0.65.1"
ACTION="${1:-all}"

usage() {
  echo "Usage: ./scripts/run_lint.sh [all|swift|shell]" >&2
}

run_swift_lint() {
  if ! command -v swiftlint >/dev/null 2>&1; then
    echo "error: SwiftLint is not installed." >&2
    echo "Run: brew bundle --file Brewfile" >&2
    return 127
  fi

  local installed_version
  installed_version="$(swiftlint version)"
  if [[ "$installed_version" != "$EXPECTED_SWIFTLINT_VERSION" ]]; then
    echo "warning: CI uses SwiftLint $EXPECTED_SWIFTLINT_VERSION, found $installed_version." >&2
    echo "         The baseline can differ between versions." >&2
  fi

  local arguments=(lint --strict --config "$PROJECT_DIRECTORY/.swiftlint.yml" --no-cache)
  if [[ -n "${SWIFTLINT_REPORTER:-}" ]]; then
    arguments+=(--reporter "$SWIFTLINT_REPORTER")
  fi

  echo "Running Swift lint with SwiftLint $installed_version"
  (
    cd "$PROJECT_DIRECTORY"
    swiftlint "${arguments[@]}"
  )
}

run_shell_lint() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "error: ShellCheck is not installed." >&2
    echo "Run: brew bundle --file Brewfile" >&2
    return 127
  fi

  echo "Running shell lint with ShellCheck $(shellcheck --version | sed -n 's/^version: //p')"
  (
    cd "$PROJECT_DIRECTORY"
    shellcheck -x scripts/*.sh scripts/lib/*.sh
  )
}

if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi

case "$ACTION" in
  all)
    run_swift_lint
    run_shell_lint
    ;;
  swift)
    run_swift_lint
    ;;
  shell)
    run_shell_lint
    ;;
  *)
    usage
    exit 2
    ;;
esac
