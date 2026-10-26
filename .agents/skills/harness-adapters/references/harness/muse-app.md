# Muse App

The Muse personal agent (Meta) as a Firstmate primary: a hosted conversation, not a terminal harness.
This is not the `muse` harness in this directory; that adapter covers Muse Code, a terminal coding harness with its own `muse` binary, verified for crewmates and scouts only.
This adapter covers a different surface from the same vendor, and its backend key is `muse-app`, never `muse`.
Status: unverified.
[`muse-app-backend.md`](../../../../../docs/muse-app-backend.md) owns the boundary, the acceptance contract, and the required bridge; this file owns the operating facts once the primary runs in-session.

## Operating facts

| Fact | Value |
|---|---|
| Binary | None. Hosted runtime; there is no shell-callable CLI, no launcher, and no process to spawn, watch, or kill. |
| Topology | Relocated: `FM_HOME` lives on Muse's VM under its persistent workspace tree (`~/workspace/firstmate` on the reference VM); the primary first mate is the Muse session itself. Only the home tree survives VM replacement. |
| Captain surface | The Muse chat, not a terminal. |
| Endpoint | A native side chat; its chat id is the durable endpoint id. Create, send, read, and archive map to chat operations on that id. |
| Launch | No launch command. The primary is already running as the session the captain opened. |
| Busy | Read from the state tree, never from a process, pane, or event log. A registered open wait with no report is outstanding; a wait whose endpoint already reported is handled and cleared. |
| Status return | Native. Crewmate endpoints run on the same VM with shell access and append Firstmate's normal lifecycle lines to `state/<id>.status`; the channel is not granted per path. |
| Supervision | Checkpoint-and-wake: [`muse-app.md`](../../../../../docs/supervision-protocols/muse-app.md) owns the protocol. No turn-end guard exists or is possible, and there is no background arm. |
| Session layer | Side chats only — no tmux, no PTY, no pane scraping. This fork supports no other backend; CLI-harness crew is out of scope here. |
| Approvals | Runtime approval cards, which Firstmate cannot pre-clear. Silent: reads, crew creation, state writes. Card: merges, pushes, outward messages. |
| Secrets | Platform vault only. The state tree records that a secret exists, never its value. |
| Trust | No workspace-trust dialog. The analog is the approval card plus per-chat discretion: a crewmate holds only its own charter's access. |
| Resume | A context reset (compaction or a fresh session) is a restart: reconcile from the state tree before acting, and trust state files over recollection. |
| Models | Not selectable through Firstmate. A Muse-native fleet is homogeneous: one model, one toolset. |

## Endpoint lifecycle

The lifecycle contract is the terminal adapters' contract, mapped to chat operations:

```text
create: task id, charter, initial instructions -> chat id, state
send: chat id, text -> accepted or rejected
read: chat id, bounded cursor -> transcript and live state
archive: chat id -> archived or stopped
return: endpoint appends state/<id>.status lifecycle lines
```

The status return channel is mandatory.
A visible chat that cannot report into Firstmate's normal lifecycle is not a complete backend.
Supervision reads are bounded chat reads with a cursor, plus the state tree; an endpoint is stopped by archiving its exact chat, and there is no process to kill.
Crewmate sessions never address the captain directly; their reports arrive in the primary's chat and are relayed.

## Supervision

The primary exposes no turn-end hook Firstmate can install, so supervision is a registry on disk plus a runtime wake hook.
Before ending a turn, the primary registers every open wait (task id, endpoint id, expected report) in the state tree and verifies the write landed; an unregistered wait does not exist.
The runtime hook polls the state tree and endpoint state and wakes the primary only on change.
Wakes are drained and acknowledged, and re-handling after interruption is idempotent.
Waiting is silent, and the primary never polls in-context or simulates a wake with an in-session timer.
If the wake hook is missing or disabled, supervision is down: say so and stop.
State writes are verified, not assumed; the host VM intermittently fails writes, so every lifecycle write is read back or retried, and wake-time reconciliation treats a torn write as an ordinary case.

## Approvals and secrets

Approval cards interrupt the primary inside its own chat, never as terminal prompts.
Record the wait in the checkpoint and end the turn; never route around a pending card.
Per-crewmate credentials live in the platform vault and are requested per chat, so a crewmate's secret never propagates to the crew or into the state tree.

## Maturity and primary limit

Muse app is a blocked boundary, not a selectable backend.
No supported transport lets an external shell process create, message, read, or archive a Muse chat, and the wake path is internal to the Muse runtime, so the backend exists only in the relocated topology with the primary inside the runtime.
Nothing here authorizes adding `muse-app` to the known or spawn-capable backend registries.
The in-session proof ships first: a research crewmate in a side chat, reporting against task ids, is the reference implementation path.
Side chats are crewmate endpoints; secondmates are persistent isolated homes whose session surface is a standing side chat bound to that home.
Secondmate rollout is gated on the FM-SECONDMATE-001 exercise defined in [`docs/muse-app-backend.md`](../../../../docs/muse-app-backend.md).
