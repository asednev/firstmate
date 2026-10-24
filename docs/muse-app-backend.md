# Muse app backend boundary

Muse is not a selectable Firstmate runtime backend.
Muse (Meta's personal agent) runs as a hosted conversation with tool access to a dedicated VM; it ships no shell-callable CLI, and a Muse chat is not an endpoint an arbitrary shell process can address.
Not the `muse` harness: the adapter registry already contains a `muse` adapter for Muse Code, a terminal coding harness with its own `muse` binary, verified for crewmates and scouts only. This boundary is about the Muse personal agent, a different surface from the same vendor.
Unlike the Codex App boundary, every lifecycle piece exists — but only from inside the Muse runtime, so this backend inverts the usual topology: the Firstmate home lives on Muse's VM, and the primary first mate is the Muse session itself.

## Acceptance contract

A Muse backend must satisfy the same lifecycle contract as terminal-backed adapters, mapped to Muse primitives:

1. Create a task endpoint and return a durable id.
   A native side chat; its chat id is the endpoint id.
2. Send the initial instructions and later operator messages to that endpoint.
   Message dispatch into that chat, addressed to its agent.
3. Read enough live state or bounded transcript to supervise the task.
   Bounded chat reads with a cursor, plus the state tree.
4. Archive, kill, or otherwise stop the exact endpoint.
   Chat archive. There is no process to kill.
5. Let the endpoint append Firstmate's normal lifecycle lines to `state/<id>.status`.
   Crewmate sessions run on the same VM with shell access, so the status return channel is native rather than granted per path.

The status return channel is mandatory.
A visible chat that cannot report into Firstmate's normal lifecycle is not a complete backend.

## Topology

- `FM_HOME` lives under the VM's persistent workspace tree (`~/workspace/firstmate` on the reference VM).
  Only the home tree survives VM replacement; `/tmp` and system paths are ephemeral.
- State stays in-tree, where Firstmate already puts it.
  A VM replacement is indistinguishable from a restart, and restart reconciliation is already Firstmate's contract.
- The captain's surface is the Muse chat, not a terminal.
  This is the GROK_BOT interaction model with the terminal machinery behind it.
- Secrets never sit in the state tree.
  Per-crewmate credentials live in the platform vault; state records that a secret exists, never its value.
- State writes are verified, not assumed.
  The host VM intermittently fails writes, so every lifecycle write is read back or retried, and wake-time reconciliation treats a torn write as an ordinary case.

## Session layer

The session backend is substitutable under this primary.

- Muse-native crew run as side chats: no tmux, no PTY, no pane scraping.
  Supervision is chat state plus the state tree.
- CLI-harness crew (Claude Code, Codex, Grok in tmux or another session backend) remains available unchanged when a task needs an interactive TUI or harness diversity.
- The tradeoff is explicit: a Muse-native fleet is homogeneous — one model, one toolset — in exchange for full tool and connected-account access no CLI harness has.

## Supervision

The primary exposes no turn-end hook Firstmate can install.
Supervision therefore uses bounded checkpoints, adapted from the Codex CLI pattern:

- Before ending a turn, the primary registers every open wait (task id, endpoint id, expected report) in the state tree.
- A runtime hook polls the state tree and endpoint state and wakes the primary only on change.
  Wakes are drained and acknowledged; re-handling after interruption is idempotent.
- A context reset of the primary (compaction or a fresh session) is a restart: reconcile from disk before acting.

[`supervision-protocols/muse-app.md`](supervision-protocols/muse-app.md) owns the step-by-step protocol.

## Approvals

The Muse runtime interrupts the primary with approval cards for consequential actions; Firstmate cannot pre-clear them.
The adapter declares the split: reads, crew creation, and state writes proceed silently; merges, pushes, and outward messages surface as captain approvals.
This is Firstmate's escalation etiquette enforced by the platform instead of the prompt.

## Current blocker

No supported transport lets an external shell process create, message, read, or archive a Muse chat, and the wake path is internal to the Muse runtime.
The backend therefore exists only in the relocated topology, with the primary inside the runtime.
These pieces do not authorize adding `muse-app` to the known or spawn-capable backend registries; the in-session proof ships first.

## Required bridge

A selectable backend becomes possible after Muse exposes one supported interface:

- a CLI wrapper for chat create, send, read, and archive operations;
- a documented JSON-RPC or MCP transport with stable framing; or
- a maintained helper that speaks the supported transport and returns plain JSON to a shell adapter.

The bridge must provide these semantics:

```text
create: task id, charter, initial instructions -> chat id, state
send: chat id, text -> accepted or rejected
read: chat id, bounded cursor -> transcript and live state
archive: chat id -> archived or stopped
return: endpoint appends state/<id>.status lifecycle lines
```

Once available, Firstmate should add a real `bin/backends/muse-app.sh`, persist `backend=muse-app` and `muse_app_chat_id=`, and route spawn, send, peek, watch, and cleanup through the shared dispatcher.
The backend key is `muse-app`, never `muse`: that key belongs to the Muse Code harness.

## Secondmates

Secondmates under this backend are native side chats.
A secondmate is a persistent side chat with a charter and a scope; it idles until the primary routes work to it by message, and its marked replies return to the primary, never to the captain.
Isolation is by charter plus a per-mate state directory inside the main home, not a separate `FM_HOME`: side chats share the VM and filesystem, so the home isolation a terminal secondmate gets from its own directory tree is a convention here, enforced by the charter.
External side chats (messaging counterparts, other agents) are not secondmates; they are counterparty conversations and stay outside this backend's fleet model.

## Rollout

Scout tasks come first.
A research crewmate in a side chat, reporting against task ids, is the reference proof.
Secondmate rollout follows the scout proof and remains gated on create, send, read, status return, and archive working through the normal backend dispatcher.
Until then, Muse remains a blocked backend boundary with a verified in-session capability record, not a selectable backend.
