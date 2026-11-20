#!/bin/bash
set -euo pipefail

# Runs the ConnectOnionKit package tests. No simulator is needed, so this is
# the fastest check after a kit change. Set KIT_PEER_DIRECTORY to the other
# app's checkout (for example ../oo-macos) to also confirm both copies of the
# kit are identical, which the Merging Rules require after every merge.

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
KIT_DIRECTORY="$PROJECT_DIRECTORY/Packages/ConnectOnionKit"

cd "$PROJECT_DIRECTORY"

swift test --package-path "$KIT_DIRECTORY" "$@"

if [[ -n "${KIT_PEER_DIRECTORY:-}" ]]; then
  PEER_KIT="$KIT_PEER_DIRECTORY/Packages/ConnectOnionKit"
  if [[ ! -d "$PEER_KIT" ]]; then
    echo "error: no kit at $PEER_KIT" >&2
    exit 2
  fi
  if diff -r --exclude=.build --exclude=.swiftpm "$KIT_DIRECTORY" "$PEER_KIT"; then
    echo "Kit copies are IDENTICAL."
  else
    echo "error: the two kit copies differ." >&2
    exit 1
  fi
fi
