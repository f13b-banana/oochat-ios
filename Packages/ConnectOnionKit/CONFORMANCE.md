# Conformance

Based on the ConnectOnion host 1.8.10 Websocket spec, this is a checklist for ConnectOnionKit

- Spec: `connectonion/docs/network/websocket-protocol.md`, shipped in the
  [`connectonion` 1.8.10](https://github.com/openonion/connectonion/blob/v1.8.10/docs/network/websocket-protocol.md) wheel. OIP 0.1
- Fixtures: [`Tests/ConnectOnionKitTests/Fixtures/frames/`](Tests/ConnectOnionKitTests/Fixtures/frames/). One JSON file per frame, plus a `.variant.json` where the spec shows a second shape.
- 58 frames:
  - 22 Client to Server
  - 33 Server to Client
  - 3 both ways

## How to fill in a row

Each kit MR changes only the cells of the frames it implements.

| Mark | Meaning |
|---|---|
| ⬜ | not started |
| 🟡 | partial. Say what is missing in **Notes** |
| ✅ | done, and the **Test** column names the test that decodes or encodes the fixture |
| n/a | the frame only travels the other way |

**Encode** applies to frames the client sends, **Decode** to frames it receives. A "both" frame needs both.
**Kit type** is the Swift type that models the frame. `OIPFrameType` currently holds names only, so those rows say "name only".

**Basis** shows the source of each frametype and its associated JSON

| Basis | Meaning |
|---|---|
| `spec` | the spec's own example, with `...` replaced by real values |
| `spec-text` | the spec prose names the fields; the JSON is assembled from them |
| `host-src` | the spec names the frame only; fields are read from the 1.8.10 host source. Verify against a real host before relying on them |

Addresses, signatures and nonces in the fixtures are synthetic. The all-zero signatures will not verify; they exist to test shape, not cryptography.

## Frames

| Frame | Dir | Spec section (`websocket-protocol.md`) | Fixture | Basis | Kit type | Encode | Decode | Test | Notes |
|---|---|---|---|---|---|---|---|---|---|
| `CONNECT` | C→S | Message Reference › CONNECT | `CONNECT.json` | spec | `OIPFrameType.connect` (name only) | ⬜ | n/a | | First frame on every socket. Signed; fresh `nonce` each time. Also a v1 form without `signed_commands`. |
| `INPUT` | C→S | Message Reference › INPUT | `INPUT.json` | spec |  | ⬜ | n/a | | Command fields duplicated top-level for v1 hosts; a v2 host executes `payload` only. Mid-turn it becomes runtime input. |
| `EXEC` | C→S | Message Reference › EXEC | `EXEC.json` | spec |  | ⬜ | n/a | | Direct tool call, no LLM. Several can be pipelined; `exec_id` correlates the reply. |
| `PONG` | C→S | Message Reference › PONG | `PONG.json` | spec |  | ⬜ | n/a | | Transport frame; unsigned. |
| `ASK_USER_RESPONSE` | C→S | Message Reference › ASK_USER_RESPONSE | `ASK_USER_RESPONSE.json` | spec |  | ⬜ | n/a | | Names the request it answers via `request_id`; a stale one gets `ERROR` `STALE_ANSWER`. |
| `APPROVAL_RESPONSE` | C→S | Message Reference › APPROVAL_RESPONSE | `APPROVAL_RESPONSE.json` | spec |  | ⬜ | n/a | | Same `request_id` rule as ASK_USER_RESPONSE. |
| `INTERRUPT` | C→S | Multiple devices (named only) | `INTERRUPT.json` | host-src |  | ⬜ | n/a | | Spec only names it. Host 1.8.10 reads no fields; replies `ERROR` if no turn is running. |
| `mode_change` | C→S | Message Reference › mode_change | `mode_change.json` | spec |  | ⬜ | n/a | | Lower-case type. Accepted only while the session is idle and owned by the caller. |
| `SESSION_STATUS` | both | Protocol Flows (named only); Authentication | `SESSION_STATUS.request.json`<br>`SESSION_STATUS.json` | host-src | `OIPFrameType.sessionStatus` (name only) | ⬜ | ⬜ | | Spec names it and says it needs no fresh signature on a live socket. Request shape and reply shape are from host source. `status` is `running`, `connected` or `not_found`. |
| `SESSION_SYNC` | C→S | Message Reference › Session Sync extension | `SESSION_SYNC.json` | spec |  | ⬜ | n/a | | Spec example is unwrapped; the spec says all four Session Sync frames use the signed command envelope, so the encoder must wrap it. |
| `SESSION_GET` | C→S | Message Reference › Session Sync extension | `SESSION_GET.json` | spec |  | ⬜ | n/a | | Signed envelope applies (see SESSION_SYNC). |
| `SESSION_WATCH` | C→S | Message Reference › Session Sync extension | `SESSION_WATCH.json` | host-src |  | ⬜ | n/a | | Spec describes it in prose only. Fields (`cursor` required, `include_archived` bool) from host source. Signed envelope applies. |
| `SESSION_UPDATE` | C→S | Message Reference › Session Sync extension | `SESSION_UPDATE.json` | spec |  | ⬜ | n/a | | 0.1 patch supports `title` and `archived` only. Signed envelope applies. |
| `ONBOARD_SUBMIT` | C→S | Message Reference › ONBOARD_SUBMIT | `ONBOARD_SUBMIT.json` | spec |  | ⬜ | n/a | | Answer to ONBOARD_REQUIRED on the same socket. `invite_code` or `payment`, not both. |
| `SEAL` | C→S | Message Reference › SEAL / SEALED_OK / SEALED | `SEAL.json` | spec |  | ⬜ | n/a | | Must be the very first frame on a socket. Signature is over the canonical JSON of the other five fields. |
| `SEALED` | both | Message Reference › SEAL / SEALED_OK / SEALED | `SEALED.json` | spec |  | ⬜ | ⬜ | | Wraps every frame after the handshake. `n` is a per-direction counter from 1. |
| `PROXY_ATTACH` | C→S | Message Reference › PROXY_ATTACH | `PROXY_ATTACH.json` | spec |  | ⬜ | n/a | | Direct sockets only, never via the relay. Signed command. |
| `PROXY_STREAM` | both | Message Reference › PROXY_STREAM | `PROXY_STREAM.json` | spec |  | ⬜ | ⬜ | | Eight `op` values (resolve, connect, data, eof, close, error, …); this fixture is the `connect` op, host → laptop. Host → laptop frames are unsigned. |
| `PROVIDER_INTERRUPT` | C→S | Overview › Scoped native-provider stop | `PROVIDER_INTERRUPT.json` | spec-text |  | ⬜ | n/a | | Spec gives only the ACK. Request fields `requestId`, `invocationId`, optional `stateRevision` are named in prose and host source. |
| `PROVIDER_PERMISSION_CHANGE` | C→S | Overview › Provider-native permission change | `PROVIDER_PERMISSION_CHANGE.json` | spec |  | ⬜ | n/a | | Elevated Full Access options need `confirmRisk: true`. |
| `WIKI_READ` | C→S | Server → Client › WIKI_READ / WIKI_RESULT | `WIKI_READ.json` | spec |  | ⬜ | n/a | | Owner only. |
| `ADMIN_PROMOTE` | C→S | Server → Client › ADMIN_RESULT | `ADMIN_PROMOTE.json` | host-src |  | ⬜ | n/a | | Spec describes `ADMIN_*` as signed commands but shows no request. Fields from host source; admin callers only. |
| `ADMIN_DEMOTE` | C→S | Server → Client › ADMIN_RESULT | `ADMIN_DEMOTE.json` | host-src |  | ⬜ | n/a | | Spec describes `ADMIN_*` as signed commands but shows no request. Fields from host source; admin callers only. |
| `ADMIN_BLOCK` | C→S | Server → Client › ADMIN_RESULT | `ADMIN_BLOCK.json` | host-src |  | ⬜ | n/a | | Spec describes `ADMIN_*` as signed commands but shows no request. Fields from host source; admin callers only. |
| `ADMIN_UNBLOCK` | C→S | Server → Client › ADMIN_RESULT | `ADMIN_UNBLOCK.json` | host-src |  | ⬜ | n/a | | Spec describes `ADMIN_*` as signed commands but shows no request. Fields from host source; admin callers only. |
| `CONNECTED` | S→C | Message Reference › CONNECTED | `CONNECTED.json` | spec | `OIPFrameType.connected` (name only) | n/a | ⬜ | | `status` is `new`, `connected`, `running` (or `index` for a session-sync-only socket). `server_newer`, `session`, `chat_items` appear only when the host is ahead. |
| `OUTPUT` | S→C | Message Reference › OUTPUT | `OUTPUT.json` | spec | `OIPFrameType.output` (name only) | n/a | ⬜ | | Turn finished; session stays alive. |
| `plan` | S→C | Message Reference › plan | `plan.json` | spec |  | n/a | ⬜ | | Lower-case. Each frame replaces the whole plan; empty `entries` clears it. |
| `EXEC_RESULT` | S→C | Message Reference › EXEC_RESULT | `EXEC_RESULT.json` | spec | `OIPFrameType.execResult` (name only) | n/a | ⬜ | | On failure `status` is `error` and `error` replaces `result`. |
| `PING` | S→C | Message Reference › PING | `PING.json` | spec | `OIPFrameType.ping` (name only) | n/a | ⬜ | | Every 30 s. Client replies PONG. |
| `thinking` | S→C | Message Reference › Stream Events | `thinking.json` | host-src |  | n/a | ⬜ | | Stream event; spec lists the name only. Host emits it with no required fields. |
| `tool_call` | S→C | Message Reference › Stream Events | `tool_call.json` | host-src |  | n/a | ⬜ | | Spec lists the name only. `tool_id` (the LLM's call id) correlates with `tool_result`; `id` is per event. |
| `tool_result` | S→C | Message Reference › Stream Events | `tool_result.json` | host-src |  | n/a | ⬜ | | Correlate on `tool_id`, not `id`. |
| `ask_user` | S→C | Message Reference › Stream Events | `ask_user.json` | host-src |  | n/a | ⬜ | | Answer with ASK_USER_RESPONSE echoing `id` as `request_id`. `fields` optional. |
| `approval_needed` | S→C | Message Reference › Stream Events | `approval_needed.json` | host-src |  | n/a | ⬜ | | Answer with APPROVAL_RESPONSE echoing `id` as `request_id`. |
| `compact` | S→C | Message Reference › Stream Events | `compact.json` | host-src |  | n/a | ⬜ | | `status` is `compacting`, `done` or `error`; the other fields differ per status. This fixture is `done`. |
| `user_message` | S→C | Message Reference › Stream Events; Multiple devices | `user_message.json` | spec |  | n/a | ⬜ | | Prompt of a turn typed on another device; not sent to the device that typed it. |
| `user_input` | S→C | Multiple devices (named only) | `user_input.json` | host-src |  | n/a | ⬜ | | The agent's own trace event; sent to every connection including the typist. Spec shows no fields; `prompt` is a guess from the trace, treat as unverified. |
| `AGENT_PROFILE` | S→C | Message Reference › AGENT_PROFILE | `AGENT_PROFILE.json` | spec | `OIPFrameType.agentProfile` (name only) | n/a | ⬜ | | Authenticated, larger than the public `/info`. Sent once after CONNECTED. |
| `DASHBOARD_SNAPSHOT` | S→C | Message Reference › DASHBOARD_SNAPSHOT | `DASHBOARD_SNAPSHOT.json` | spec |  | n/a | ⬜ | | HTML is untrusted: render sandboxed with scripts and network blocked. Files over 2 MB are never sent. |
| `WIKI_RESULT` | S→C | Message Reference › WIKI_READ / WIKI_RESULT | `WIKI_RESULT.json` | spec |  | n/a | ⬜ | | HTML capped at 16 MiB. |
| `CONTROL_CENTER_APP` | S→C | Message Reference › CONTROL_CENTER_APP (preview) | `CONTROL_CENTER_APP.json` | spec |  | n/a | ⬜ | | Preview in 1.8.10; the host does not emit it yet. Never hand-author an `approved` descriptor. |
| `RUNTIME_INPUT_ACK` | S→C | Message Reference › RUNTIME_INPUT_ACK | `RUNTIME_INPUT_ACK.json` | spec |  | n/a | ⬜ | | Reply to an INPUT sent mid-turn. |
| `ONBOARD_REQUIRED` | S→C | Message Reference › ONBOARD_REQUIRED | `ONBOARD_REQUIRED.json` | spec |  | n/a | ⬜ | | CONNECT is held open, not failed. `payment_*` present only when `payment` is in `methods`. |
| `ONBOARD_SUCCESS` | S→C | Message Reference › ONBOARD_SUCCESS | `ONBOARD_SUCCESS.json` | spec |  | n/a | ⬜ | | CONNECTED follows by itself; do not resend CONNECT. |
| `ADMIN_RESULT` | S→C | Message Reference › ADMIN_RESULT | `ADMIN_RESULT.json` | spec |  | n/a | ⬜ | | Fields beyond `action` are whatever the trust handler returned. |
| `ERROR` | S→C | Message Reference › ERROR; CONNECT; APPROVAL_RESPONSE | `ERROR.json`<br>`ERROR.stale_answer.json` | spec | `OIPFrameType.error` (name only) | n/a | ⬜ | | Also how a refused onboard comes back; there is no dedicated failure frame. `code` may be a string (`STALE_ANSWER`) or an integer (`-32603`). |
| `PROXY_ATTACHED` | S→C | Message Reference › PROXY_ATTACHED | `PROXY_ATTACHED.json` | spec |  | n/a | ⬜ | | A refusal is an `ERROR` starting `proxy attach refused:`. |
| `SEALED_OK` | S→C | Message Reference › SEAL / SEALED_OK / SEALED | `SEALED_OK.json` | spec |  | n/a | ⬜ | | Verify `signature` against the host address; `client_ephemeral` must echo the SEAL's key. |
| `SESSION_SYNC_RESULT` | S→C | Message Reference › Session Sync extension | `SESSION_SYNC_RESULT.json` | spec |  | n/a | ⬜ | | `next_page_token` replaces `cursor` on non-final pages. `cursor_expired` error → one full sync. |
| `SESSION_SNAPSHOT` | S→C | Message Reference › Session Sync extension | `SESSION_SNAPSHOT.json` | spec-text |  | n/a | ⬜ | | Spec lists `summary`, `snapshot_revision`, `records`, optional `next_page_token`; record `kind` values and `data` are not enumerated, so `data` here is a placeholder. |
| `SESSION_NOT_MODIFIED` | S→C | Message Reference › Session Sync extension | `SESSION_NOT_MODIFIED.json` | spec-text |  | n/a | ⬜ | | Reply to SESSION_GET when `if_revision` is current. Other fields unspecified. |
| `SESSION_WATCHED` | S→C | Message Reference › Session Sync extension | `SESSION_WATCHED.json` | host-src |  | n/a | ⬜ | | Ack for SESSION_WATCH; echoes the cursor. |
| `SESSION_CHANGED` | S→C | Message Reference › Session Sync extension | `SESSION_CHANGED.json` | host-src |  | n/a | ⬜ | | Sent only when summaries or removals exist; same body as a SESSION_SYNC_RESULT, no `request_id`. Watch delivery is not durable. |
| `PROVIDER_INTERRUPT_ACK` | S→C | Overview › Scoped native-provider stop | `PROVIDER_INTERRUPT_ACK.json` | spec |  | n/a | ⬜ | | `accepted: true` is not the terminal outcome; the `provider_invocation` `cancelled` event is. Reasons: `not_active`, `invalid_request`. |
| `PROVIDER_PERMISSION_ACK` | S→C | Overview › Provider-native permission change | `PROVIDER_PERMISSION_ACK.json` | spec-text |  | n/a | ⬜ | | Fixture is the rejection form, which is fully specified. The accepted form adds a `providerPermission` object whose shape the spec does not give. |
| `mode_changed` | S→C | Message Reference › mode_change | `mode_changed.json` | host-src | `OIPFrameType.modeChanged` (name only) | n/a | ⬜ | | Lower-case. Means the durable commit completed. Followed by `provider_invocation` frames if Work Rooms narrowed. |
| `provider_invocation` | S→C | Overview › Provider-native permission change | `provider_invocation.json` | spec-text |  | n/a | ⬜ | | Lower-case. Spec shows no full body; fixture holds only fields the spec names (`status`, `stateRevision`, `invocationId`). Incomplete by design. |

## Named in the spec but not client frames

These appear in `websocket-protocol.md` but are not frames a client sends or receives on the `/ws` socket, so they have no row.

| Name | What it is |
|---|---|
| `ANNOUNCE` | agent ↔ relay registration frame; the client never sees it |
| `proxy_grant` | object nested inside `PROXY_ATTACH`, covered by that fixture |
| `OIP_COMPAT` | a debug log record on the host, not a wire frame |
| `send_message`, `run_skill` | Control Center web app actions over a `MessagePort`, not socket frames |

## In the host source but not in the spec

Host 1.8.10 accepts or sends these, but `websocket-protocol.md` does not describe them, so they have no row and no fixture. Decide whether the kit handles them; an unknown frame type is answered with `ERROR unknown message type`.

| Frame | Dir | Seen in |
|---|---|---|
| `PROVIDER_INPUT` / `PROVIDER_INPUT_ACK` | C→S / S→C | `ws_router/session.py` |
| `PROVIDER_STATION_ATTACH` / `_ACK` | C→S / S→C | `ws_router/session.py` |
| `PROVIDER_CONTROL` / `_ACK` | C→S / S→C | `ws_router/session.py` |
| `provider_session`, `provider_activity`, `provider_artifact`, `provider_message` | S→C | `ws_router/session.py`, `provider_workroom.py` |
| `CONTROL_CENTER_COMMAND` | C→S | `ws_router/session.py` |
| `REMOTE_BROWSER` | C→S | `ws_router/session.py` |
| `RUNTIME_INPUT` | agent-internal | `ws_router/session.py` |
| `ADMIN_GET_LEVEL`, `ADMIN_ADD`, `ADMIN_REMOVE` | C→S | `network/trust/ws_admin.py` |
| `tool_call_update` | S→C | `network/connect.py` |
