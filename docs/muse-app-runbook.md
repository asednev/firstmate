# Muse app runbook

Operating procedure for the checkpoint-and-wake protocol in [`supervision-protocols/muse-app.md`](supervision-protocols/muse-app.md), for the backend in [`muse-app-backend.md`](muse-app-backend.md).
Every procedure here was exercised live on 2026-10-23; the evidence is in [`verification/runtime-backends.md`](verification/runtime-backends.md) ("Muse app in-session lifecycle").

## Surfaces and state

- The captain's surface is the Muse chat. The primary is a Muse session. A crewmate is a native side chat created for one brief; it never addresses the captain.
- Crew is tiered. A crewmate's burst workers are that crewmate's own subagents, not additional side chats: subagent output is internal to the crewmate, and the primary drains only the crewmate's report and status file. The primary's own in-turn assistance is likewise subagents, and is not crew. Assign a task to a side-chat crewmate when the captain may need to see it, reach it, or audit it; assign a bounded step inside the primary's or a crewmate's active work to subagents.
- State lives in the Firstmate home's state tree on the primary's VM, in the tree's own layout. Two files per supervised task:
  - `state/<task-id>.status` — lifecycle lines appended by the endpoint;
  - `state/<task-id>.checkpoint` — the open-wait record written by the primary.
- Status lines are one per line, in this order: `started:` before work begins, `check:` at a meaningful midpoint, then exactly one terminal line — `done:` after the endpoint's chat report is posted, or `blocked:` with the reason.
- Secrets never enter the state tree. Credentials stay in the platform vault.

## One-time setup

- The Firstmate home lives in storage that survives a VM replacement; a replacement is an ordinary restart, reconciled from the state tree.
- Firstmate's helper tools (`gh-axi`, `tasks-axi`, `treehouse`, `chrome-devtools-axi`) are invoked by their installed paths; do not assume they are on `PATH`.

## Dispatch a crewmate

1. Create a native side chat for the task and record its durable chat id.
2. Send the brief in one message: the charter, the task itself, the task-id marker, the required report against that id (empty and "nothing found" outcomes are reports), and the status-file instructions — the exact status file path and the line order above.
3. The endpoint appends `started:` first and verifies the append by reading the file back before doing any work.

## Checkpoint before ending the turn

Write `state/<task-id>.checkpoint` with: task id, endpoint chat id and name, status file path, the expected terminal line and report, the registration time, the wake hook id, and `state: open`.
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

## Handle a wake

1. Drain: read the full status file and the endpoint's recent chat messages.
2. Reconcile against the checkpoint: the wait is handled only when a terminal line exists **and** the endpoint report exists.
3. Relay the outcome to the captain, with the status lines as the evidence for the file return channel.
4. Append `state: handled` and `handled_at: <timestamp>` to the checkpoint and verify by reading it back.
5. If the terminal line is `blocked:` or the report is missing, relay that instead; mark nothing handled.

## Teardown

Archive the endpoint chat; the archived chat retains its transcript and can be restored.
Chat management (archive, list) is restricted to the main chat in some session contexts: a primary running inside a side chat may be unable to archive its own crewmates. Record the endpoint chat id in the checkpoint so teardown can be routed to a context that can execute it, and do not report teardown as done until the archive is confirmed.

## Failure cases

- **Hook missing or disabled while a wait is open:** supervision is down. Say so; never cover the gap by polling in-context.
- **Status write fails:** the endpoint retries once, verifies by reading back, and reports the failure in its chat report if the append still fails.
- **Endpoint silent past its expected window:** treat as `stale` per the harness-neutral contract in `AGENTS.md`; reconcile from the state tree before re-dispatching anything.
- **Wake fires but the report is absent:** the wait stays open. Relay the discrepancy; do not mark handled.

## Never

- Never poll for a crewmate from inside the session, and never simulate a wake with a timer.
- Never let a crewmate address the captain directly; reports are relayed by the primary.
- Never end a turn with an open wait that has no checkpoint and no armed wake.
