# Muse app runbook

Operating procedure for the checkpoint-and-wake protocol in [`supervision-protocols/muse-app.md`](supervision-protocols/muse-app.md), for the backend in [`muse-app-backend.md`](muse-app-backend.md).
Every procedure here was exercised live on 2026-10-23; the evidence is in [`verification/runtime-backends.md`](verification/runtime-backends.md) ("Muse app in-session lifecycle").

## Surfaces and state

- The captain's surface is the Muse chat. The primary is a Muse session. A crewmate is a native side chat created for one brief; it never addresses the captain.
- Crew is tiered. A crewmate's burst workers are that crewmate's own subagents, not additional side chats: subagent output is internal to the crewmate, and the primary drains only the crewmate's report and status file. The primary's own in-turn assistance is likewise subagents, and is not crew. Assign a task to a side-chat crewmate when the captain may need to see it, reach it, or audit it; assign a bounded step inside the primary's or a crewmate's active work to subagents.
- One exception to the assignment rule: a whole task may run on a subagent endpoint under the dispatch exception in "Dispatch a crewmate" below, and only under its conditions.
- State lives in the Firstmate home's state tree on the primary's VM, in the tree's own layout. Two files per supervised task:
  - `state/<task-id>.status` — lifecycle lines appended by the endpoint;
  - `state/<task-id>.checkpoint` — the open-wait record written by the primary.
- Status lines are one per line, in this order: `started:` before work begins, `check:` at a meaningful midpoint, then exactly one terminal line: `done:` after the endpoint's chat report is posted, or `blocked:` with the reason.
- A `correction:` line may appear before the terminal line and supersedes an earlier `check:` figure.
- After a wait is handled, corrections are not appended to the status file; they are recorded as an `errata:` note on the checkpoint, and a corrected figure that already reached the captain is corrected to him in the primary's next reply.
- Secrets never enter the state tree. Credentials stay in the platform vault.

## One-time setup

- The Firstmate home lives in storage that survives a VM replacement; a replacement is an ordinary restart, reconciled from the state tree.
- Firstmate's helper tools (`gh-axi`, `tasks-axi`, `treehouse`, `chrome-devtools-axi`) are invoked by their installed paths; do not assume they are on `PATH`.

## Dispatch a crewmate

Chat creation executes on a genuine captain turn and is refused on event-hook handoff turns, the same capability fact recorded under "Teardown" below.
When a dispatch arises on a captain turn, follow the steps below.
When a dispatch arises on a hook turn, the default is to hold it: write a dispatch-pending record (task id, intended `mate: <slug>`, brief location, and the mandate relied on), note it in the backlog, and execute the dispatch at the next captain turn before new work.
The exception is work the captain's away-mode words require to be done while he is away and that cannot wait for his return: that work may run on a subagent endpoint, provided the checkpoint records `endpoint_type: subagent` and the words relied on at registration time, the work leaves a durable report under the home's `data/<task-id>/`, and the completion relay to the captain discloses the substitution in its first line.

1. Create a native side chat for the task, named `mate: <slug>` with a short lowercase task slug (e.g. `mate: scout`), and record its durable chat id.
2. Send the brief in one message: the charter, the task itself, the task-id marker, the required report against that id (empty and "nothing found" outcomes are reports), and the status-file instructions — the exact status file path and the line order above.
3. The endpoint appends `started:` first and verifies the append by reading the file back before doing any work.
4. Under the subagent exception there is no endpoint chat to create: the primary passes the same brief content and status-file instructions to the subagent, and the checkpoint records no chat id.

## Checkpoint before ending the turn

Write `state/<task-id>.checkpoint` with: task id, endpoint chat id and name (none under the subagent exception), `endpoint_type` (`crewmate` or `subagent`), status file path, the expected terminal line and report, `expected_first_check` (the time by which the endpoint's first `check:` line is expected), `expected_terminal` (the time by which a terminal line is expected), the registration time, the wake hook id, and `state: open`.
The two expectation fields are what the "Endpoint silent past its expected window" failure case reads.
Verify the write by reading the file back. A write that did not land is a lost wait; an unregistered wait does not exist.

## Arm the wake

One hook per open wait. The polling script:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

STATUS="$HOME/<firstmate-home>/state/<task-id>.status"

if [ -f "$STATUS" ] && grep -qE '^(done|blocked):' "$STATUS"; then
  log "terminal line present" '{"task":"<task-id>"}'
  disable_after_run
  wake "<task-id> reached a terminal state" '{"task":"<task-id>"}'
else
  silent "no terminal line in <task-id> status file yet"
fi
```

- Register the hook disabled, with delivery to the primary's chat and a wake instruction that names the checkpoint and status paths.
- Dry-run it before enabling: with no terminal line present the only correct result is silent.
- Enable it, then end the turn. The hook disables itself when it fires, so a wait wakes the primary exactly once.

Optionally, arm a second hook per wait: the silence watchdog.
It polls the same status file against the checkpoint's expectation fields and wakes the primary once when `expected_first_check` passes with no `check:` line yet, or when `expected_terminal` passes with no terminal line.
On that wake the primary reconciles from the state tree: steer the endpoint, extend the expectation in the checkpoint with a reason, or relay the stale wait to the captain.
The watchdog never re-dispatches anything itself, and it disables itself when it fires, like the terminal wake.
`bin/fm-record-lint.sh` validates a state tree against the status and checkpoint contract at reconciliation points (bearings, stow, session start).

## Handle a wake

1. Drain: read the full status file and the endpoint's recent chat messages.
2. Reconcile against the checkpoint: how the wait closes depends on the terminal line, per steps 4 and 5.
3. Relay the outcome to the captain, with the status lines as the evidence for the file return channel. Every relay also states the number of teardowns currently pending (see "Teardown") until that number is zero.
4. On `done:` with the report present, close the wait: read the checkpoint first, and if a `state: handled` line is already present, stop — the wait is already closed. Otherwise append `state: handled` and `handled_at: <timestamp>` and verify by reading it back.
5. On `blocked:`, or if the report is missing, relay that instead and mark nothing handled; the wait stays open. When a successor task later completes the blocked task's objective, close the blocked checkpoint as `state: superseded` with `resolved_by: <successor task id>` and a timestamp — never as handled.

## Return from away mode

Away-mode mandate semantics live in the `/afk` skill; this section owns only the re-entry sequence for this backend.
The captain's first genuine message after an away period runs the gate in order: run the return check, archive the away record, and relay the return brief.
Only then does the primary act on the message's content.
When the first message itself requests new work, the gate still precedes the dispatch.
The brief may be compressed to outcomes, blockers, and waiting decisions when outcomes were already posted incrementally during the away period, but it is never skipped silently.

## Captain decisions

When an endpoint's report reserves a decision for the captain, relaying it does not discharge it.
In the same handling sequence, the primary files it as a held decision item under the captain-hold contract in `AGENTS.md` section 10, which is the custody record until he answers.
A reserved decision may be converted to a default only by naming it in the message that asks his other questions, explicitly marked as a provisional default.
Nothing is built on a provisional default until he answers, and a contrary answer withdraws the default on the record.

## Teardown

Archive the endpoint chat; the archived chat retains its transcript and can be restored.
On a genuine captain turn, a primary running inside a side chat executes chat management directly — create, send, list, and archive (corrected 2026-10-25: 11 crewmates archived directly from the First Mate side chat on captain turns). Record the endpoint chat id in the checkpoint regardless, and do not report teardown as done until the archive call itself returns.
Chat management is refused on event-hook handoff turns, and reading another chat's history is restricted to the main chat. On a hook turn, teardown waits for the next captain turn or routes through the main chat: message the main chat (its chat id is recorded in the home's captain preferences) naming the endpoint's chat id and name and the completed task; the main-chat agent archives the endpoint and confirms back. That routed path was verified live on 2026-10-24 with the FM-CREW-001 endpoint and remains the route wherever a direct archive is refused.
Teardown is part of the handling sequence: archive in the same sequence whenever the turn shape allows it.
When it cannot execute — a hook turn, or a routed archive not yet confirmed — the checkpoint gains `teardown: pending`, naming the route that will close it (the next captain turn, or the main-chat route), and the pending count surfaces in every relay until it reaches zero.
An endpoint deliberately kept open for the captain to read is recorded as `teardown: retained` with the reason, instead of being left silently unarchived.

## Failure cases

- **Hook missing or disabled while a wait is open:** supervision is down. Say so; never cover the gap by polling in-context.
- **Status write fails:** the endpoint retries once, verifies by reading back, and reports the failure in its chat report if the append still fails.
- **Endpoint silent past its expected window:** treat as `stale` per the harness-neutral contract in `AGENTS.md`; reconcile from the state tree before re-dispatching anything.
- **Wake fires but the report is absent:** the wait stays open. Relay the discrepancy; do not mark handled.

## Never

- Never poll for a crewmate from inside the session, and never simulate a wake with a timer.
- Never let a crewmate address the captain directly; reports are relayed by the primary.
- Never end a turn with an open wait that has no checkpoint and no armed wake.
