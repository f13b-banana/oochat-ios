# ConnectOnionKit

A Swift package that speaks the [ConnectOnion](https://docs.connectonion.com/) agent protocol (OIP) for Apple platforms. 

## Status

The kit is being built up frame by frame. 

[CONFORMANCE.md](CONFORMANCE.md) is the source of truth for what is implemented. Every frame the spec defines has a row there, and each change is indicated by the cells for the frames it covers.

## Requirements

| | |
|---|---|
| Swift tools | 5.9 |
| iOS | 17.0 or later |
| macOS | 14.0 or later |
| Host | ConnectOnion 1.8.10 (`pip install connectonion==1.8.10`). See [Protocol version](#protocol-version) |
| Dependencies | none |

## Installation

Add it as a local package, which is how the app uses it:

```swift
// Package.swift
dependencies: [
    .package(path: "Packages/ConnectOnionKit")
],
targets: [
    .target(name: "YourTarget", dependencies: ["ConnectOnionKit"])
]
```

In Xcode: **File ▸ Add Package Dependencies… ▸ Add Local…**, then choose this folder.

## Example

Signing a command means hashing exactly the bytes the Python host hashes, so the kit
exposes the canonical encoder:

```swift
import ConnectOnionKit

let payload: [String: JSONValue] = [
    "type": .string("INPUT"),
    "prompt": .string("执行 tree café 🧅")
]

let bytes = CanonicalJSON.data(from: payload)
// {"prompt":"\u6267\u884c tree caf\u00e9 \ud83e\uddc5","type":"INPUT"}
```

There is no connection API yet. When one lands it will be documented here.

## Tests

```bash
cd Packages/ConnectOnionKit
swift test
```

Xcode 16 or later is needed for the `Testing` stub in `ConnectOnionKitTests.swift`; the XCTest
files build on older toolchains.

### Fixtures

`Tests/ConnectOnionKitTests/Fixtures/frames/` holds one JSON file per protocol frame (58 frames,
60 files), loaded in tests through `Bundle.module` because the test target declares
`resources: [.copy("Fixtures")]`.

```swift
let url = Bundle.module.url(forResource: "CONNECTED", withExtension: "json",
                            subdirectory: "Fixtures/frames")!
let data = try Data(contentsOf: url)
```

- A file is named after the frame's `type` exactly, case included (`plan`, `mode_changed` are lower case).
- `NAME.variant.json` is a second shape of the same frame, for example `ERROR.stale_answer.json`.
- Addresses, signatures and nonces are synthetic. All-zero signatures will not verify; the
  fixtures test shape, not cryptography.
- [CONFORMANCE.md](CONFORMANCE.md) records, per frame, whether the JSON is the spec's own
  example (`spec`), assembled from the spec's prose (`spec-text`), or read from the host
  source (`host-src`). Treat `host-src` fixtures as unverified until checked against a running host.

#### Provenance and refreshing

The fixtures come from `connectonion/docs/network/websocket-protocol.md` in the
[`connectonion` 1.8.10](https://pypi.org/project/connectonion/1.8.10/) wheel, with `...` in the
spec's examples replaced by concrete values. To refresh for a new host version:

```bash
pip download connectonion==<version> --no-deps -d /tmp/co
unzip -q /tmp/co/connectonion-*.whl -d /tmp/co/whl
less /tmp/co/whl/connectonion/docs/network/websocket-protocol.md
```

Diff the frame list against CONFORMANCE.md, add rows and fixtures for new frames, and re-verify any
`host-src` row whose source changed. Do not edit a fixture to make a test pass; change it only
because the spec changed.

## When to send SESSION_STATUS
The host answers `{"type":"SESSION_STATUS","session_id":…,"status":"running"|"connected"|"not_found"}`
(`ws_router/session.py`). It gives a real answer only to the identity that
owns the session; everyoneelse gets`not_found`, so the reply is never an existence check.

1. Send it only on a socket that has received `CONNECTED`. There the host
already knows who you are, so `OIPClientFrames.sessionStatus(sessionID:)` (unsigned, exempt from the v2 gate) is enough. Never open a socket just to ask: a status-only socket must sign the query, and the kit has no builder for that.
2. Ask when the host says a run is going (`CONNECTED` or a reply says`running`)and this socket is notwaiting for that run's OUTPUT, for example a run started before areconnect or a relaunch. Ask again every `SessionStatusLabel.pollInterval` (10 s), the interval O Chat's `use-agent-sdk.ts` uses. While your own INPUT is in flight, OUTPUT already tells you when the run ends, so don't poll.
3. Stop when `SessionStatusLabel.keepsPolling(after:)` is false (the answer is not `running`), the socket closes, or the user leaves the chat.
4. `not_found` feeds`SessionEvent.notFound` into`reduce`(`SessionStatusLabel.event(for:)`), which ends the session. `running`and `connected` only change the header text.
5. Show `SessionStatusLabel.text(state:hasBookmark:hostStatus:)` in the chat header, passing the `status` of the last CONNECTED or SESSION_STATUS.

## Protocol version

The spec bundled with host 1.8.10 calls itself **OIP 0.1** and advertises `{"name": "oip", "version": "0.1"}`
in `CONNECTED`. `OIP.descriptor` in this package currently declares version `0.2` with a `0.1`–`0.2`
range. See [CONFORMANCE.md](CONFORMANCE.md) before sending that descriptor to a 1.8.10 host.

## License

MIT, as the repository. See [LICENSE](../../LICENSE).
