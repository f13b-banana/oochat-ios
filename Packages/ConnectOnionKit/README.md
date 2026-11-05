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

## Protocol version

The spec bundled with host 1.8.10 calls itself **OIP 0.1** and advertises `{"name": "oip", "version": "0.1"}`
in `CONNECTED`. `OIP.descriptor` in this package currently declares version `0.2` with a `0.1`–`0.2`
range. See [CONFORMANCE.md](CONFORMANCE.md) before sending that descriptor to a 1.8.10 host.

## License

MIT, as the repository. See [LICENSE](../../LICENSE).
