Mode: Muse app checkpoint-and-wake supervision.

This protocol belongs to the Muse personal-agent primary in [`muse-app-backend.md`](../muse-app-backend.md).
It is not a protocol for the `muse` (Muse Code) harness, which is crewmate- and scout-only and never runs a primary.
The Muse primary has no installable turn-end hook and no background arm.
Supervision is a registry on disk plus a runtime wake hook; this protocol is the whole mechanism.

When this session owns supervision and away mode is not active:
1. Drain first.
   Read the state tree and every unread crewmate report (bounded chat reads with cursors) before acting.
   Reconcile each registered open wait against reality: a wait whose endpoint already reported is handled and cleared, never re-dispatched.
2. Dispatch by message.
   Each task goes to its crewmate endpoint with a task-id marker and a required report against that id.
   Empty and "nothing happened" outcomes are reports too.
3. Checkpoint before ending the turn.
   Write every open wait (task id, endpoint id, expected report, since when) into the state tree and verify the write landed.
   An unregistered wait does not exist.
4. Arm the wake.
   A runtime hook polls the state tree and endpoint state and wakes this session on change only.
   Waiting is silent.
   Never poll in-context, and never simulate a wake by re-reading on a timer inside the session.
5. On wake, drain again (step 1), handle `signal`, `stale`, `check`, or `heartbeat` per the harness-neutral contract in `AGENTS.md`, relay outcomes to the captain, and re-checkpoint before ending the turn.
6. A context reset (compaction or a fresh session) is a restart.
   Reconcile from disk first; trust state files over recollection.
7. Approvals interrupt as runtime cards, never as terminal prompts.
   Record the wait in the checkpoint and end the turn; never route around a pending card.
8. If the wake hook is missing or disabled, supervision is down.
   Say so and stop rather than covering the gap with in-context polling.

The captain's surface is this chat.
Crewmate sessions never address the captain directly; their reports arrive here and are relayed.
Side-chat crew are the only crew surface under this backend; there is no pane layer and no second supervision protocol.
Operating procedure — dispatch, status-file discipline, checkpoint fields, hook arming, wake handling, teardown, failure cases — lives in [`muse-app-runbook.md`](../muse-app-runbook.md).
