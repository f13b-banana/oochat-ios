#!/bin/bash
# Shared simulator helpers. Source this file; do not run it.
#
#   source "$SCRIPT_DIRECTORY/lib/simulator.sh"
#
# Environment (all optional):
#   SIMULATOR_UDID          use exactly this device
#   SIMULATOR_NAME          use the newest available device with this name
#   SIMULATOR_BOOT_TIMEOUT  seconds to wait for a full boot (default 420)
#   MINIMUM_IOS_MAJOR       lowest iOS major version to consider (default 17)
#
# Written for the bash 3.2 that ships with macOS: no mapfile, no associative
# arrays, and no expansion of an empty array under `set -u`.

MINIMUM_IOS_MAJOR="${MINIMUM_IOS_MAJOR:-17}"

sim_info() {
  printf '[sim] %s\n' "$1"
}

sim_fail() {
  printf '[sim] error: %s\n' "$1" >&2
  exit 1
}

sim_python() {
  if [[ -x /usr/bin/python3 ]]; then
    printf '%s\n' /usr/bin/python3
  elif command -v python3 >/dev/null 2>&1; then
    command -v python3
  else
    return 1
  fi
}

# Prints the installed iOS runtime versions, one per line, newest first.
simulator_runtimes() {
  local python_path json_path
  python_path="$(sim_python)" || sim_fail "python3 was not found."
  json_path="$(mktemp -t oochatios-runtimes.XXXXXX)"
  xcrun simctl list runtimes available --json >"$json_path" \
    || { rm -f "$json_path"; sim_fail "could not list simulator runtimes."; }
  "$python_path" - "$json_path" "$MINIMUM_IOS_MAJOR" <<'PYTHON'
import json
import sys

path, minimum_text = sys.argv[1:]
minimum = int(minimum_text)
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)

versions = set()
for runtime in payload.get("runtimes", []):
    if runtime.get("platform", "iOS") != "iOS":
        continue
    if runtime.get("isAvailable") is False:
        continue
    version = runtime.get("version", "")
    parts = version.split(".")
    if not parts or not parts[0].isdigit() or int(parts[0]) < minimum:
        continue
    versions.add(tuple(int(p) for p in parts if p.isdigit()))

for version in sorted(versions, reverse=True):
    print(".".join(str(p) for p in version))
PYTHON
  rm -f "$json_path"
}

# simulator_select [RUNTIME_VERSION]
# Prints "udid<TAB>name<TAB>runtime<TAB>state" for the best iPhone: a booted one
# first, then the newest runtime, then by name. With RUNTIME_VERSION (for
# example 18.5) only that runtime is considered.
simulator_select() {
  local wanted_runtime="${1:-}"
  local python_path json_path
  python_path="$(sim_python)" || sim_fail "python3 was not found."
  json_path="$(mktemp -t oochatios-simulators.XXXXXX)"
  xcrun simctl list devices available --json >"$json_path" \
    || { rm -f "$json_path"; sim_fail "could not list simulators. Is an iOS runtime installed in Xcode?"; }

  local status=0
  "$python_path" - "$json_path" "${SIMULATOR_UDID:-}" "${SIMULATOR_NAME:-}" \
    "$MINIMUM_IOS_MAJOR" "$wanted_runtime" <<'PYTHON' || status=$?
import json
import re
import sys

path, requested_udid, requested_name, minimum_text, wanted_runtime = sys.argv[1:]
minimum = int(minimum_text)

try:
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, json.JSONDecodeError) as error:
    print(f"could not read simulator list: {error}", file=sys.stderr)
    raise SystemExit(2)

candidates = []
for runtime_identifier, devices in payload.get("devices", {}).items():
    match = re.search(r"\.iOS-(\d+)(?:-(\d+))?", runtime_identifier)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2) or 0))
    if version[0] < minimum:
        continue
    version_text = f"{version[0]}.{version[1]}"
    if wanted_runtime and wanted_runtime not in (version_text, str(version[0])):
        continue
    for device in devices:
        name = device.get("name", "")
        device_type = device.get("deviceTypeIdentifier", "")
        if not (name.startswith("iPhone") or ".iPhone-" in device_type):
            continue
        if device.get("isAvailable") is False:
            continue
        candidates.append({
            "udid": device.get("udid", ""),
            "name": name,
            "runtime": f"iOS {version_text}",
            "version": version,
            "state": device.get("state", "Unknown"),
        })

if requested_udid:
    candidates = [d for d in candidates if d["udid"] == requested_udid]
elif requested_name:
    candidates = [d for d in candidates if d["name"] == requested_name]

if not candidates:
    print("no available iPhone simulator matches"
          f" (iOS {minimum}+, runtime '{wanted_runtime or 'any'}',"
          f" udid '{requested_udid}', name '{requested_name}').", file=sys.stderr)
    raise SystemExit(4)

candidates.sort(key=lambda d: (d["state"] != "Booted", -d["version"][0], -d["version"][1], d["name"]))
chosen = candidates[0]
print("\t".join([chosen["udid"], chosen["name"], chosen["runtime"], chosen["state"]]))
PYTHON
  rm -f "$json_path"
  return "$status"
}

# simulator_boot UDID STATE
# Boots the device if needed and waits until it has fully finished booting.
# Xcode itself only waits 60 s, and the first boot of a new runtime can take
# several minutes, so booting here first is what stops "Timed out trying to
# boot simulator".
simulator_boot() {
  local udid="$1" state="$2"
  local timeout="${SIMULATOR_BOOT_TIMEOUT:-420}"
  local output

  if [[ "$state" != "Booted" ]]; then
    if ! output="$(xcrun simctl boot "$udid" 2>&1)"; then
      case "$output" in
        *"current state: Boot"*) ;;   # already Booted or Booting
        *) sim_fail "could not boot $udid: $output" ;;
      esac
    fi
  fi

  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= timeout )); then
      kill "$pid" 2>/dev/null || true
      sim_fail "simulator $udid did not finish booting in ${timeout}s. Run ./scripts/reset_simulator.sh"
    fi
    sleep 2
    waited=$((waited + 2))
  done
  wait "$pid" || sim_fail "simulator $udid failed while booting. Run ./scripts/reset_simulator.sh"
}

# simulator_prepare [RUNTIME_VERSION]
# Selects and boots a simulator, then sets SIM_UDID, SIM_NAME and SIM_RUNTIME.
simulator_prepare() {
  local selected
  selected="$(simulator_select "${1:-}")" || sim_fail "no usable iPhone simulator. Set SIMULATOR_NAME or SIMULATOR_UDID, or install a runtime in Xcode."
  IFS=$'\t' read -r SIM_UDID SIM_NAME SIM_RUNTIME SIM_STATE <<<"$selected"
  sim_info "Using $SIM_NAME ($SIM_RUNTIME), $SIM_UDID, currently $SIM_STATE"
  simulator_boot "$SIM_UDID" "$SIM_STATE"
  sim_info "Booted."
}
