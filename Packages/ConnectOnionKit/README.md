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

The kit does not open the agent's WebSocket. The app owns that connection and decodes each server frame with
`OIPServerFrame.decode`. It feeds the frames named in `WorkRoomStore.frameTypes` to a `WorkRoomStore` and
gives the store a `WorkRoomTransport`, through which the store sends its signed commands. The transport
reports a failed write (`sendReportingFailure:`), and the request it carried then ends at once.

The kit opens two other kinds of connection itself. Device Link uses Network.framework (`NWBrowser`,
`NWListener`, `NWConnection`) on the local network, and `SessionsClient` makes signed HTTPS requests to
the agent's host with `URLSession`. Both are described below.

## Hosted History

`SessionsClient` reads the person's own sessions from one agent's host: `listSessions()` is
`GET /sessions` and `session(id:)` is `GET /sessions/{id}`. Each request carries the `x-co-*` headers
from `SignedRequestHeaders.make`, an Ed25519 signature over the method, path, query, body hash,
timestamp, request ID and the agent's Address, in the shape a ConnectOnion 1.8.10 host verifies.
The replies decode to `ConnectOnionHostedSession`; `UnixTime.date` reads the host's times, which
may be in seconds or milliseconds.

```swift
let client = SessionsClient(baseURL: hostURL, agentAddress: agent.address, keyStore: store)
for session in try await client.listSessions() { restore(session) }
```

Related helpers:

- `TurnRole` names who spoke a turn. Hosted messages (`turnRole`) and `CONNECTED`'s `chat_items` both map to it.
- `MirroredTurn` reads a turn another device started (`prompt(fromUserMessage:)`, `items(fromChatItems:)`,
  `catchUpSteps`), and `ViewerTurnState` says whether this chat's running turn belongs to this device.
- `AgentAddress.normalized` and `AgentAddress.same` hold the 0x Address rule: `0x` and 64 hex digits, any case.
- `PreviousIdentity` marks chats made under an Address this device no longer holds, with the copy the apps show.

## Device Link

Copies the Identity from one of a person's Apple devices to another over the local network
(Bonjour service `_oochat-link._tcp`, which each app declares under `NSBonjourServices`).
Either side may display the offer as a QR (`qrPayload`) or a 10-character Link Code; the other scans or types it.

```swift
// Receiving Device shows the code, Giving Device scans it. (Either can display:
// DeviceLinkGiver(displayingWith:) and DeviceLinkReceiver(scanning:) are the other way round.)
let receiver = try DeviceLinkReceiver()
show(try receiver.offer.qrPayload, receiver.offer.linkCode)
let identity = try await receiver.link(accept: { await personAccepts($0.address) })
try store.replacePrivateKey(with: identity.privateKey)

// `entered:` takes a scanned QR or a typed code, and restamps the expiry on this device's clock.
let offer = try DeviceLinkOffer(entered: scanned, displayer: .receiving, now: Date())
let giver = try DeviceLinkGiver(scanning: offer, keyStore: store)
try await giver.link(approve: { await ownerConfirmsAndAuthenticates() })
try store.markLinked()
```

Each offer lasts two minutes and is used once, whether or not the attempt succeeds. Cancelling the
task running `link` closes the listener and connection, and no Identity is delivered. The receiver
asks its person only after the Identity has passed every check, while the connection is still open,
and answers the giver: the giver's `link` returns once the receiver accepted, and throws `.cancelled`
if it declined or hung up. Only the giver checks the code; when it fails, the giver tells the receiver
before hanging up, so both sides report `.wrongCode`. A scanning side that can't find the displaying device within 30 seconds
gives up with a timeout.
`DeviceLinkError` names each protocol failure (`malformed`, `expired`, `reused`, `wrongCode`, `addressMismatch`, `tampered`, `cancelled`, `noIdentity`).
A giver with no saved key throws `noIdentity` and sends nothing.
`malformed` is an offer or message that doesn't parse: `DeviceLinkFlow` shows it as `mistypedCode` only before
connecting, and as the general failure (`other`) after.

The giver's Agent Name list travels sealed with the key: pass `agentNames:` (`DeviceLinkAgentName`, a
lower-cased 0x Address and a name) to `DeviceLinkGiver` or `DeviceLinkFlow`, and the receiver reads
`identity.agentNames` or gets them in the flow's `onAgentNames`, after the key is replaced and before
`onReplaced`. `DeviceLinkAgentName.apply` and `.duplicates` hold the rename/add rule and the
one-agent-per-Address merge. Protocol version 2; version 1 offers are refused.

### Link sheet

Both apps use the same sheet content and state; only the chrome around it differs.

```swift
// Settings › Identity rows: DeviceLinkRole.giving.settingsTitle, DeviceLinkRole.receiving.settingsTitle
let flow = DeviceLinkFlow(role: .receiving, keyStore: identityStore, displaysCode: true,
                          onReplaced: { reconnectAllAgents() })
NavigationStack {
    DeviceLinkView(flow: flow)                                    // Mac: shows its code, or types one
        .navigationTitle(flow.role.settingsTitle)
}
DeviceLinkView(flow: flow) { Scanner(onCode: flow.submit) }       // iPhone: camera above the field
```

- `DeviceLinkKeyStore` is what an app's identity store adds for linking: `loadPrivateKey()` (the saved key or
  nil, never a new one), `replacePrivateKey(with:)` (atomic
  write, cached key cleared, linked flag set), `isLinked` (false by default, gone with the key) and
  `markLinked()`. `InMemoryPrivateKeyStore` conforms, for tests.
- `DeviceLinkFlow` is the main-actor, observable state machine. `displaysCode` picks whether this device shows
  its code or enters the other's, in either role (the iPhone enters, the Mac shows; left out, the receiver
  shows and the giver enters), and `switchCodeMode()` flips it and starts over. The receiver gets the
  Identity (from its own code, or by entering the giver's), then
  `confirmingReplace(current:incoming:)`, then replaces the key before telling the giver it accepted (a key
  it can't save is declined and shown as `couldNotSave`), runs `onReplaced` and ends in `done`;
  the giver connects (from its own code, or by entering the receiver's), asks `confirmingSend`, runs the device-owner check
  (`DeviceLinkFlow.checkDeviceOwner()`, LocalAuthentication `.deviceOwnerAuthentication`), sends, marks
  itself linked and ends in `done`. Any step can end in `failed(DeviceLinkFailure)`.
- `DeviceLinkView` starts the flow when it appears and cancels it when it disappears, so closing the sheet
  cancels the link on both devices. It offers "Show my code instead" on code entry, and "Scan a code
  instead" (or "Type a code instead" without a scanner) under its own code. A "no" at either confirmation closes the sheet.
- `DeviceLinkFailure` turns any thrown error into one of the named failures (`expired`, `notOnSameNetwork`,
  `wrongCode`, `mistypedCode`, `cancelledOnOtherDevice`, `localNetworkDenied`, `couldNotSave`, `other`), each with a `title` and a `nextStep`.
- The flow injects the owner check, clock, randomness and the two link operations, so tests drive it with
  in-memory link operations and never open a socket.

## Tests

```bash
cd Packages/ConnectOnionKit
swift test
```

Xcode 16 or later is needed for the `Testing` stub in `ConnectOnionKitTests.swift`; the XCTest
files build on older toolchains.

### Fixtures

`Tests/ConnectOnionKitTests/Fixtures/frames/` holds one JSON file per protocol frame (68 frames,
116 files, counting variants), loaded in tests through `Bundle.module` because the test target declares
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
