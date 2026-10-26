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

This fork supports exactly one runtime backend: `muse-app`.
Its session layer is side chats, full stop: no tmux, no PTY, no pane scraping, and no substitute layer waiting behind them.
Crew are Muse-native endpoints, supervised through chat state plus the state tree.
CLI-harness crew under an upstream session backend (tmux, Herdr, Zellij, Orca, cmux, Paseo, Rex) is out of scope for this backend; those backends remain upstream's concern, neither extended nor certified here.
The tradeoff is explicit: the fleet is homogeneous — one model, one toolset — in exchange for full tool and connected-account access no CLI harness has.

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

Side chats are crewmate endpoints, not secondmates.
A side chat is a task endpoint: created for a brief, supervised through its reports and the state tree, archived at teardown — however long it happens to live.
What makes a secondmate is the home: an isolated `FM_HOME` with its own state, backlog, projects, and charter.
Under this backend a secondmate is a persistent home on the VM — a sibling tree, not a directory inside the main home — and a standing side chat bound to that home is its session surface; work routed to the secondmate runs in that surface, or in per-task crewmate chats briefed from the home.
Isolation therefore comes from the home, exactly as in terminal Firstmate — never from the chat, which shares the VM and filesystem with every other endpoint.
External side chats (messaging counterparts, other agents) are neither crewmates nor secondmates; they are counterparty conversations and stay outside this backend's fleet model.

The rest of this section is the secondmate design for this backend.
It follows canonical Firstmate (the repo's `AGENTS.md` supervisor contract, [`secondmate-parent-channel.md`](secondmate-parent-channel.md), and the secondmate provisioning skill) without deviation except the one clause flagged in The charter below.

### Shape on this backend

- A secondmate home lives at `~/workspace/firstmate/homes/<id>/`, a sibling tree to the main home, holding a dedicated checkout of this repo plus the home's own `config/`, `data/`, `state/`, and `projects/` trees.
- The home carries the canonical identity markers: `.fm-secondmate-parent` binds it to the main home, and `.fm-secondmate-home` marks it as a secondmate home.
- A standing side chat named `second: <project>` is bound to the home as its session surface.
- The home is the identity and the chat is replaceable: if the chat is lost, a fresh chat bound to the same home resumes the mate.
- The binding is recorded in the main home's registry line and in the mate home's parent marker; no other record of the binding is authoritative.
- On the start phrase, the mate's chat takes the First Mate role scoped to its home, reading its charter the way the main home reads its captain file.

### Registry and routing

- The main home records the mate in `data/secondmates.md` in the canonical one-line format, with the mate's natural-language scope, its non-exclusive project list, and its home path.
- Routing follows canonical intake: the main firstmate routes by scope with judgment, and bypasses a fitting mate only when the mate is blocked or the captain explicitly redirects the work.
- Once a route exists, the main home does not also register the mate's projects as its own; a domain has exactly one operating home.
- The pilot route is `eg1`: its scope is all EG1 ship and scout work, and its project list is `eg1` (`direct-PR`), which satisfies the canonical eligibility rule that secondmate projects are `no-mistakes` or `direct-PR` projects only.

### The charter

- The charter is generated by the canonical scaffold (`bin/fm-brief.sh <id> --secondmate`) and copied into the mate home as `data/charter.md` at seed time; the scaffold's generated sections are preserved, and the captain-supplied text names the persistent responsibility, the clones, and the domain hard rules.
- EG1's domain hard rules include its delivery posture (`direct-PR`, merges only on the captain's explicit word), the pack version-bump and dirty-profile verification rules, ear-gate ownership by the captain, alpha before production, and CI spend discipline (local gates first, no redundant dispatches).
- One clause is an addition beyond canonical, adopted by captain decision on 2026-10-25: when a direct captain intervention in the mate's chat changes the mate's work, the mate appends a one-line note of that fact to the parent channel.
- Canonical deliberately leaves that case to the mate's reasoning with no durable evidence (see the parent channel design's evidence table); the clause closes the invisibility hole at the cost of one line, and the rest of the captain-contact contract below is canonical without exception.

### The parent channel on this backend

- The parent channel is a file, as canonical specifies: the mate's status stream at `state/<id>.status` in the main home.
- The mate appends its judgement lines there in the canonical escalation vocabulary, and script-published outcomes land there at record time or at the next supervision poll; the publishers and the delivery-key dedup rule are canonical and owned by [`secondmate-parent-channel.md`](secondmate-parent-channel.md).
- On this backend the endpoint sessions run on the same VM, so appending to the channel is a local file write from the mate's surface or its home's scripts, verified by read-back like every lifecycle write in this topology.
- The main firstmate folds new channel lines on every wake under [`supervision-protocols/muse-app.md`](supervision-protocols/muse-app.md), and never reads the mate's chat: canonical forbids it, and this substrate's chat reads are bounded to the main chat, so the contract and the constraint agree.
- The acceptance contract's read requirement is discharged for secondmates by the channel and by reads of the mate's validated home, not by transcript reads of the mate's chat.

### Routed requests and the doorbell

- A routed request is a durable record in the mate home's steering inbox (`state/<id>.inbox/` in the mate home), carrying the canonical marker and a `corr=<id>` token; the mate's answer carries the token on the parent channel.
- Correlation state lives in the main home's `state/pending-replies/`; a missing answer gets exactly one repost before escalation, as canonical specifies.
- The doorbell is a runtime hook that watches the mate home's inbox and state tree and wakes the mate's chat on change, the same watch pattern the main home already uses for its state tree.
- The hook is registered from the mate's chat, because in this runtime a watch wakes the chat that owns it; the main home's own hook watches the parent channel in its state tree the same way.

### Liveness and relaunch

- A side chat has no process to probe, so canonical's `dead` and `missing` verdicts map to chat-level facts: the bound chat was archived or deleted, or its doorbell hook has failed past the liveness cadence.
- Relaunch never creates a second home: it unarchives the bound chat or creates a fresh `second: <project>` chat bound to the surviving home, and the mate reconciles from its home before acting, exactly as a restart does.
- Relaunch attempts are capped by the canonical liveness budget; past the cap the mate is parked behind its marker and escalated to the captain once.
- A mate whose chat is mid-restart (including a context compaction) is not dead: it reconciles silently and idles, and an empty queue authorizes nothing.

### Authority

- Inside its home the mate holds the full firstmate authority set under the repo's `AGENTS.md` contract, which binds primary firstmates and persistent secondmates identically.
- It dispatches its own crewmates, ships through its projects' registered delivery modes, and publishes captain decisions as holds up the parent channel.
- Merges remain the captain's explicit word in every home; EG1's `direct-PR` posture carries no standing merge relaxation.
- The mate generates no work of its own, acts only on routed work and direct captain intervention, and never launches a secondmate.
- Under away mode the mate works the queue the main firstmate routed to it under the main home's mandate; it holds no mandate of its own and cannot widen its scope while the captain is away.

### Captain contact

- A message the captain types directly into the mate's chat is authoritative captain intervention: unmediated, conversational, and binding immediately, exactly as canonical specifies.
- There is no guardrail on that path and no approval step; the firstmate remains the default communication point because outcomes surface on the parent channel, not because the direct path is restricted.
- Captain-facing content from the mate exists only on the parent channel; a captain-facing sentence in the mate's chat has not been sent.
- The one added clause (see The charter) covers the record of a direct intervention, never permission for it.

### Record intake for an inherited domain

- Provisioning a mate for an existing domain follows the canonical record-intake duty before the mate acts: reconcile every inherited plan against the project's `origin/main` and its live deployments, and seed only genuinely open work plus the domain's durable knowledge.
- Queued items in the main backlog that match the mate's scope move to the mate's backlog with the canonical handoff (byte-exact, atomic, idempotent); work already in flight in the main home finishes there unless the captain directs otherwise.
- For the EG1 pilot, the intake reconciles the edu-games repo state and both live deployments, and the seeded backlog carries EG1's open PRs, pending captain ear gates, and open field items as the mate's starting queue.

### Proof exercise

- FM-SECONDMATE-001 closes the rollout gate: provision the `eg1` home, charter, and registry route; launch `second: eg1`; route one real EG1 task from the main firstmate through the inbox to the mate and its own crewmate; land the outcome on the parent channel and fold it into a captain report; publish one captain hold up the channel and answer it; and record one direct captain intervention in the mate's chat with its note line on the channel.
- The exercise retires nothing, and its result is recorded in [`verification/runtime-backends.md`](verification/runtime-backends.md) beside the crewmate lifecycle proof.

## Rollout

Scout tasks come first.
A research crewmate in a side chat, reporting against task ids, is the reference proof.
Secondmate rollout follows the crewmate proof and is gated on the FM-SECONDMATE-001 exercise defined in the Secondmates section above; the dispatcher-based lifecycle gate this replaces assumed a bridge this backend does not use, and for secondmates its read leg is the parent channel and the mate's validated home.
Until then, Muse remains a blocked backend boundary with a verified in-session capability record, not a selectable backend.

[`verification/runtime-backends.md`](verification/runtime-backends.md#muse-app-in-session-lifecycle) owns the in-session lifecycle smoke without exposing task-specific chat ids or local paths.
