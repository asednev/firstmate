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
  The home tree and the captain's Muse memory store (`~/MEMORY.md`, `~/memory/`) survive VM replacement; `/tmp` and system paths are ephemeral.
- State stays in-tree, where Firstmate already puts it; the one exception is a home's rebuild kit, a small record kept in the captain's Muse memory so a lost home can be re-founded.
  A VM replacement is indistinguishable from a restart, and restart reconciliation is already Firstmate's contract; a home-tree loss is not a restart and is rebuilt under [Home state durability](#home-state-durability).
- The captain's surface is the Muse chat, not a terminal.
  This is the GROK_BOT interaction model with the terminal machinery behind it.
- Secrets never sit in the state tree.
  Per-crewmate credentials live in the platform vault; state records that a secret exists, never its value.
- State writes are verified, not assumed.
  The host VM intermittently fails writes, so every lifecycle write is read back or retried, and wake-time reconciliation treats a torn write as an ordinary case.

## Home state durability

- A home's state is gitignored state inside a git clone, so the clone's tracked history protects none of it: a fresh clone, a reset, or a clean of the home path destroys the state by construction, as the 2026-10-27 re-clone of the main home demonstrated when it wiped that home's registry, config, backlog, and state tree while leaving every tracked file intact.
- Prevention is a fence, not a hope: no actor clones into, resets, or cleans a path that is a live home, and work on this repository that needs a fresh checkout uses a scratch clone outside every home and lands through the ordinary PR path; a path is recognized as a live home by its `.fm-secondmate-home` marker where one exists, and otherwise by the presence of a home's runtime state - `data/`, `state/`, and `config/` content such as a secondmate registry or a backlog - inside a clone of this repository.
- Operational state is not mirrored to memory: checkpoints, inbox and channel traffic, pending replies, and backlog bodies churn constantly, are re-derived or re-driven by ordinary reconciliation where they matter, and would bury a journal; what memory holds for each home is a rebuild kit - the few small facts a lost home cannot re-derive from what survives it.
- The kit is declared under the canonical Memory layering contract, whose schema `docs/configuration.md` owns: the home's `data/captain.md` declares the Muse memory store as a tier for the single class `rebuild kit`, and captain-preference and knowledge classes stay local exactly as the operational-home-layout contract states.
- The tier destination is the captain's Muse memory - the memory notes under `~/MEMORY.md` and `~/memory/` on the VM - which every Muse session serving the captain can reach and no firstmate tool, build, or checkout operation ever writes.
- The kit is not the conversation memory the recovery contract sets aside: a kit entry is a contemporaneous copy written at the lifecycle act it records, the act's own record rather than a recollection recovered from conversation afterward, and AGENTS.md section 5's bar on recollection as authority is untouched by it.
- A home's kit holds, verbatim: its secondmate registry lines as they stand in `data/secondmates.md`; each mate's endpoint record as published; the home's config values as set; each mate's doorbell facts - the hook id, the paths it watches, and the chat it delivers to; each mate's charter text as briefed at provisioning; and the declaration's own text.
- The kit is captured whole, as one entry, at the rare acts that change its contents - a mate provisioned, rebound, or retired, a config value set, a charter amended - by the firstmate who performs the act, as part of that same act; there is no per-write journaling of operational state.
- A kit entry carries the marker `fm-rebuild-kit`, the home's absolute path, the entry's write time in epoch seconds, and the write time of the declaration it was written under; entries are append-only, the latest entry for a home is its current kit, and an entry written under a newer declaration supersedes every earlier entry for that path, so a re-founded home never inherits a prior incarnation's kit.
- Kit entries live in the dated memory logs (`~/memory/<date>.md`); the retention relied on - the dated notes kept as the full trail while curated summaries consolidate - is the memory platform's observed behavior, named as such rather than as a guarantee the fleet controls, and the curated `~/MEMORY.md` summary is not the kit and never substitutes for an entry.
- Capture is agent discipline, as the canonical contract already assumes: no tool parses, validates, or enforces the declaration or the capture, and a lifecycle act whose actor skips the kit leaves the home exactly as exposed as it was before this section.
- The kit is a rebuild source only: while a home's files exist they are authoritative, the kit is never read against them, and the authority rules already stated - the registry line as routing authority, the endpoint record as delivery authority - are untouched.
- After a home-tree loss, the main firstmate rebuilds from the latest kit entry: it restores the config values verbatim, restores each registry line whose named mate home still exists, restores each endpoint record verbatim from the kit after it passes the record check the endpoint-record section assigns to teardown, verifies each mate's doorbell hook is live under `~/hooks` before routing resumes, and places the declaration's text in the rebuilt captain file and in the reconstruction report as a proposal, because the tier is operative again only when the captain re-declares or confirms it.
- Routing to a rebuilt mate resumes only after the mate appends a fresh doorbell confirmation line to the rebuilt parent channel, which the firstmate requests through the mate's chat; the rebuilt channel starts empty, and no confirmation text is ever restored into it from the kit.
- Everything outside the kit is rebuilt by the fleet's ordinary means or is lost, and the reconstruction report says which: project clones are re-cloned, the backlog and learnings are re-founded by the session-start absence handling and the captain's direction, in-flight sends are closed as lost against each mate's `handled/` records, and non-confirmation channel lines and checkpoint records are unrecoverable.
- The rebuilt home reports the rebuild to the captain as a reconstruction, naming the kit entry used, the records restored, the registry lines refused because their mate home is gone, and the classes lost with the tree.

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
Under this backend a secondmate is a persistent home on the VM - a sibling tree, not a directory inside the main home - and a standing side chat bound to that home is its session surface; work routed to the secondmate runs in that surface, in the mate's own subagents, or in per-task crewmate chats briefed from the home (see Crew surfaces inside a mate home).
Isolation therefore comes from the home, exactly as in terminal Firstmate — never from the chat, which shares the VM and filesystem with every other endpoint.
External side chats (messaging counterparts, other agents) are neither crewmates nor secondmates; they are counterparty conversations and stay outside this backend's fleet model.

The rest of this section is the secondmate design for this backend.
It follows canonical Firstmate (the repo's `AGENTS.md` supervisor contract, [`secondmate-parent-channel.md`](secondmate-parent-channel.md), and the secondmate provisioning skill) without deviation except the two flagged deviations below: the crew-surface rule, and one clause in The charter.

### Shape on this backend

- A secondmate home lives at `~/workspace/firstmate-homes/<id>/`, a sibling tree beside the main home, holding a dedicated checkout of this repo plus the home's own `config/`, `data/`, `state/`, and `projects/` trees.
- The home carries the canonical identity markers: `.fm-secondmate-parent` binds it to the main home, and `.fm-secondmate-home` marks it as a secondmate home.
- A standing side chat named `second: <project>` is bound to the home as its session surface.
- The home is the identity and the chat is replaceable: if the chat is lost, a fresh chat bound to the same home resumes the mate.
- The binding is recorded in the main home's registry line, in the mate home's parent marker, and in the endpoint record (see The endpoint record); the registry line is the routing authority and the endpoint record is the delivery authority.
- On the start phrase, the mate's chat takes the First Mate role scoped to its home, reading its charter the way the main home reads its captain file.
- The home's `data/` carries `data/captain.md` (the captain-shared rules) alongside the charter; the charter adds the mate's persistent responsibility on top of those rules, never instead of them.
- At provisioning the main firstmate checks the mate id against the main home's existing state record basenames and refuses a collision, because the parent channel shares the state namespace with task records; no tool performs this check, so the check is part of the provisioning act itself.

### The endpoint record

- `bin/fm-send.sh` finds a secondmate through its endpoint record, `state/<id>.meta` in the main home: it resolves the delivery target from the record before it classifies the send, and a mate with no record does not resolve.
- On terminal backends `bin/fm-spawn.sh` writes that record at launch; on this backend nothing is launched, so the record is written at provisioning instead (captain decision, 2026-10-27: the seed writes the meta at provisioning).
- The writer is a provisioning tool, `bin/fm-secondmate-record.sh`, run by the main firstmate with the mate id, the mate home, and the bound chat's id; it writes the field set below with each key exactly once, it refuses to overwrite an existing record, and it publishes the way canonical publication does - under the record's meta lock, through the canonical atomic-transition publish, never by an in-place edit another reader can observe half-written.
- Timing is part of the contract: the main firstmate runs the writer when it folds the mate's doorbell-confirmation line (see Routed requests and the doorbell), before any request is routed, so the record never stands for a mate that has not confirmed its doorbell.
- A mate founded before this rule (the `eg1` pilot) receives its record from the same writer, run by the main firstmate as the first step of the next routing act or of the build's live proof, whichever comes first; its doorbell confirmation is already on record, so the timing rule is satisfied rather than re-triggered.
- When a relaunch replaces the bound chat (see Liveness and relaunch), the main firstmate updates the record in the same act through the writer's only update mode: a read-modify-write under the same lock and atomic publication that preserves every other line of the record byte-for-byte, including fields later canonical writers appended, rewrites the chat id field, and mints a fresh `spawn_gen=`, because a new chat is a new incarnation; the update refuses when the record's chat id is not the expected old binding the caller names, meaning the binding being replaced, read from the record in a prior step of the same act; a refusal is recovered by re-reading the record against the mate's latest parent-channel confirmation and retrying against the fresh value, never by forcing the stale write; the retry is bounded by the record's authority - a fresh value that is neither the expected old binding nor the intended new one stops the act with no write, and the main firstmate reconciles which binding is live before any further attempt, and where the latest confirmation names a chat the record does not hold, the record governs delivery and the confirmation is stale evidence of an unrecorded rebind, never a value to write on its own say-so; and an update that finds the intended chat already recorded is already applied, not an error, and no request is routed to the new binding until the mate has confirmed the new binding on the parent channel after its cold-start doorbell verification.
- The record is written with exactly these fields: `kind=secondmate`, `backend=muse-app`, `muse_app_chat_id=` naming the bound chat (the field reserved for this backend in `docs/configuration.md`), `endpoint_task_id=` naming the mate id, `worktree=`, `project=`, and `home=` each naming the mate home, `projects=` carrying the registry project list, `mode=secondmate`, `yolo=off`, `harness=muse`, and `spawn_gen=` carrying one identity token in the format `bin/fm-spawn.sh` publishes (`s<epoch>.<pid>.<random>`).
- Exactly is a write-time and read-time rule with two named exceptions: later canonical writers may append their own fields to the record, exactly as they do to a spawn-written record, and readers take the named fields as they find them; the exceptions are the writer's own exact-once emission and teardown's shape check below, and neither rejects a record for carrying additional fields.
- The record carries no `window=`, no `terminal=`, no per-backend atom fields, and no `remote_host=`: this backend has no terminal endpoint, and a window-shaped value would be read by window-shaped tooling as a real pane.
- The refusals that guard this shape stand in a stated order: restart capability refuses it first because the record names no endpoint, `bin/fm-control.sh` refuses it at its endpoint validation, and behind both stands a second lock - the control plane's harness-kind gate declares `muse` unverified for secondmate records - so teaching the first checks this shape one day would not by itself open a spawn-based restart or control path; the harness value stays because it is the truthful one, and leaving the backend is a retirement followed by a fresh provisioning under the new backend, never an in-place relaunch of this record.
- Delivery resolution learns one case, inside `bin/fm-send.sh` only: a record carrying `backend=muse-app` with `kind=secondmate` resolves its delivery target from `muse_app_chat_id=`, a muse-app record with no chat id does not resolve, and the same case governs the final delivery revalidation, where fm-send re-reads the target under the record lock before it writes the inbox record; the shared backend target readers are unchanged, so every other consumer keeps the windowless view of the record it has today.
- Backend validation learns the same boundary at the same place: `bin/fm-send.sh` validates after resolution and accepts `muse-app` there for a secondmate record, reading `kind=` from the resolved record because resolution exposes no kind of its own; the shared known-backend and spawnable-backend lists are unchanged, so every other validation caller keeps refusing the value and no launch path opens.
- Two send paths never apply to a muse-app record, and each refusal is an explicit check at a named site rather than a side effect: the parser-native carve-out (a steer beginning with a slash) refuses at the head of the text-steer path, after fm-send has set aside the pre-marker text its classification reads and before the marking block creates the pending-reply expectation, so a refused steer arms no expectation - a check at target resolution cannot serve, because the send flags are still unparsed there and the pre-marker text does not exist yet, and the existing plane-selection classification sits downstream of that creation and does not discharge this check; the refusal does not extend to a fire-and-forget steer, which the inbox plane carries as chat text and never as a parser command, exactly as it does to a launched mate - and `--key` refuses inside the key branch ahead of its dispatch; every other steer rides the inbox plane, writes the durable inbox record, and confirms the pending-reply expectation exactly as canonical specifies.
- A send to a muse-app mate attempts no doorbell ring (the wake path is the doorbell under Routed requests and the doorbell), and the skip reports success to the send's own bookkeeping: no retry ring is armed and no did-not-reach notice prints, because the doorbell's polling is this backend's wake and retry alike.
- The record's existence lifts no send gate: until the doorbell-confirmation line exists, senders send nothing marked, as Routed requests and the doorbell already rules; the record is what makes a send possible, the confirmation is what makes it permitted, and before this design the missing record enforced that rule by refusal.
- Retirement learns the shape inside `bin/fm-teardown.sh`, at its windowless-shape probe: a record carrying `backend=muse-app` with `kind=secondmate` is classified into the windowless class from its own kind and backend fields, never by the probe's synthetic-copy validation, which would refuse a backend it has never heard of; class membership confers the windowless treatment directly - endpoint validation skipped, the backend-prerequisites gate running with the class's default backend presentation and passing, no endpoint kill dispatched, and the transition-clearing call receiving the class's empty target - and it does not pass through the legacy branches, which key that treatment on missing or legacy generation tokens a conforming record never carries; ahead of those gates teardown checks the record itself (the named fields present, each exactly once, `worktree=`, `project=`, and `home=` naming the same existing mate home, no window or terminal field, and additional fields appended by canonical writers do not fail the check) before retirement proceeds canonically: the registry line, the home, and the record are removed.
- The shared endpoint validator is not taught the shape and keeps refusing windowless records, so `bin/fm-control.sh` refuses a muse-app mate at the same validation it runs today, and the shape probes in `bin/fm-procevent.sh` and `bin/fm-update.sh` behave exactly as they do on any windowless record.
- Every other reader of the shared target, validation, and record functions keeps today's behavior by construction - the watcher's ring ladder and stall supervisor, crew state, the fleet snapshot, the supervise daemon, and the busy library - and the build's proof includes a sweep showing each one's treatment of a muse-app record matches its treatment of a windowless record whose target read is empty; `bin/fm-send.sh` itself is excluded from that baseline by design, because it is the one reader whose behavior changes.
- Readers that key on the record's existence rather than its fields - the live secondmate sweep in `bin/fm-ff-lib.sh`, run at session start and by `bin/fm-update.sh`, and its consumers, including `bin/fm-config-push.sh` - treat the mate's home the way they treat a launched mate's home from the moment the record exists: its checkout fast-forwards under the sweep's guards and allowlisted config propagates into it; `bin/fm-update.sh`'s registry backstop already fast-forwarded the home with no record at all, so what the record newly brings the mate under is the session-start sweep and config push; that treatment is the designed one, the timing rule above is what makes it safe to begin, and the build's proof sweep extends to these readers against the launched-record baseline.
- Identity-keyed tooling applies to this shape unchanged: `bin/fm-secondmate-reconcile.sh` keys the mate's identity on `spawn_gen=` exactly as it does for a launched mate, and because the update mode rotates the token at a rebind, a sample taken against the old binding refuses after it, as canonical intends; the stated cost of reusing that signal is that a fleet snapshot pass straddling a rebind discards the mate's captured observations as generation-stale although its work state is continuous - accepted, because a token that never rotated would blind the expected-generation guards the fleet already runs.
- Liveness and restart tooling learn nothing: canonical liveness gates on the window field before it consults any target, so it stays silent on the mate and its verdicts remain the observable facts under Liveness and relaunch, and no tool relaunches, kills, or restarts a muse-app mate; the relaunch that exists on this backend is the First Mate's chat act defined there.
- The registry line is written at seed time and the endpoint record at the confirmation fold, both from the same home path, and the writer is the comparison that keeps them agreeing on the routing path: the live sweep silently prefers the record's home, and the comparisons the fleet does have - the public-followup home resolver, which refuses a disagreement, and retirement's binding check - fire only on their own acts, so the writer reads the registry line at write time and refuses a home that disagrees with it, compared under the registry's canonical path key rather than as raw strings, and the update mode repeats that check.
- `bin/fm-send.sh` gains no registry fallback: a mate with no endpoint record does not resolve, exactly as a terminal mate whose launch never published one.
- The build that implements this record proves it live before the queued routing that depends on it resumes: a canonical `bin/fm-send.sh` marked send to the founded `eg1` mate, answered on the parent channel, with no hand-written inbox record anywhere in the proof.

### Registry and routing

- The main home records the mate in `data/secondmates.md` in the canonical one-line format, with the mate's natural-language scope, its non-exclusive project list, and its home path.
- Routing follows canonical intake: the main firstmate routes by scope with judgment, and bypasses a fitting mate only when the mate is blocked or the captain explicitly redirects the work.
- Once a route exists, the main home does not also register the mate's projects as its own; a domain has exactly one operating home.
- The pilot route is `eg1`: its scope is all EG1 ship and scout work, and its project list is `eg1` (`direct-PR`), which satisfies the canonical eligibility rule that secondmate projects are `no-mistakes` or `direct-PR` projects only.
- Provisioning runs on a captain turn in the main home, and the route is in force for that session from that turn.
- A First Mate session that started before provisioning re-reads `data/secondmates.md` at its next intake before dispatching project work; until it has, its stale project registration must not be used to bypass the mate.

### Crew surfaces inside a mate home

- Inside a mate home the default crew surface is the mate's own subagents: briefed from the mate home, checkpointed in its state tree, and reporting through the mate, exactly as the fleet's tiered crews already run under a crewmate.
- Side-chat crewmates from a mate home are created only on a genuine captain turn in the mate's chat, under the runbook's turn-shape rule; the mate keeps a dispatch queue of work waiting for such a turn and drains it then.
- A task queues for a crewmate chat only when the captain may need to see it, reach it, or audit it (the runbook's criterion, applied inside the home); everything else runs on subagents.
- The mate reports its dispatch-queue depth on the parent channel whenever it changes, so a queue waiting on a captain turn is a declared wait, never a silent one.
- At every restart the mate reconciles each open subagent wait in its state tree - closing it as superseded or re-dispatching it under the runbook's stale rule - and never leaves a wait open on the assumption its worker still exists.
- Intra-home staleness is therefore discovered at the mate's next wake, and for routed work the parent channel's expectation and one-repost path bounds the total delay.
- Every outcome line the mate appends to the parent channel names the surface that ran the work (subagent or crewmate chat), so the choice of surface is always disclosed in the record.
- This is a substrate-forced deviation from canonical, where a mate delegates to crewmate endpoints with the normal lifecycle: chat creation executes only on captain turns in this runtime, while a mate's normal wake is a doorbell turn, so crewmate chats cannot be its default surface.
- The deviation is in the surface only: briefs, checkpoints, status records, and review duties are unchanged, and the mate never asks the main home to create its crewmates, so canonical's rule against supervising a mate's child tree from the main home stands.

### The charter

- The charter is generated by the canonical scaffold (`bin/fm-brief.sh <id> --secondmate`) and copied into the mate home as `data/charter.md` at seed time; the scaffold's generated sections are preserved, and the captain-supplied text names the persistent responsibility, the clones, and the domain hard rules.
- EG1's domain hard rules include its delivery posture (`direct-PR`, merges only on the captain's explicit word), the pack version-bump and dirty-profile verification rules, ear-gate ownership by the captain, alpha before production, and CI spend discipline (local gates first, no redundant dispatches).
- One clause is an addition beyond canonical, adopted by captain decision on 2026-10-25: when a direct captain intervention in the mate's chat changes the mate's work, the mate appends a one-line note of that fact to the parent channel.
- Canonical deliberately leaves that case to the mate's reasoning with no durable evidence (see the parent channel design's evidence table); the clause closes the invisibility hole at the cost of one line, and the rest of the captain-contact contract below is canonical without exception.
- Dated captain orders (a budget posture, a freeze, a deadline) belong in the mate's `data/captain.md` or its backlog, never in the charter; the charter carries only durable rules.

### The parent channel on this backend

- The parent channel is a file, as canonical specifies: the mate's status stream at `state/<id>.status` in the main home.
- The mate appends its judgement lines there in the canonical escalation vocabulary, and script-published outcomes land there at record time or at the next supervision poll; the publishers and the delivery-key dedup rule are canonical and owned by [`secondmate-parent-channel.md`](secondmate-parent-channel.md).
- On this backend the endpoint sessions run on the same VM, so appending to the channel is a local file write from the mate's surface or its home's scripts, verified by read-back like every lifecycle write in this topology.
- The main firstmate folds new channel lines on every wake under [`supervision-protocols/muse-app.md`](supervision-protocols/muse-app.md), and never reads the mate's chat: canonical forbids it, and this substrate's chat reads are bounded to the main chat, so the contract and the constraint agree.
- The acceptance contract's read requirement is discharged for secondmates by the channel and by reads of the mate's validated home, not by transcript reads of the mate's chat.
- The mate's write grant into the main home is exactly two canonical surfaces: appends to its parent channel (`state/<id>.status`) and acknowledgement moves inside its own steering inbox (`state/<id>.inbox/`).
- That grant is convention-enforced, not technically enforced: every endpoint shares the VM filesystem, so nothing prevents a confused mate from writing other main-home records; the record linter catches form errors after the fact, and supervision surfaces any other mate-authored main-home write as a defect, never as a mechanism.
- Lifecycle writes from inside a mate home use absolute paths, and that grant binds the mate's subagents exactly as it binds the mate.

### Routed requests and the doorbell

- A routed request is a durable record in the steering inbox in the main home (`state/<id>.inbox/` in the main home's state tree), written by the canonical send tooling and read and acknowledged by the mate from there, carrying the canonical marker and a `corr=<id>` token; the mate's answer carries the token on the parent channel.
- Correlation state lives in the main home's `state/pending-replies/`; a missing answer gets exactly one repost before escalation, as canonical specifies.
- The doorbell is a runtime hook that watches the main home's steering inbox for the mate and the mate home's own state tree and wakes the mate's chat on change, the same watch pattern the main home already uses for its state tree.
- The hook is a persistent polling hook whose delivery names the mate's chat; it is not the one-shot per-wait pattern, which would die on the first routed request.
- Bootstrap order is explicit: the First Mate creates the mate's chat and sends the founding brief on a captain turn in the main home; on its founding turn the mate registers the doorbell, and provisioning is not complete until the mate confirms the registration with a line on the parent channel.
- Hook registration is not chat management and is permitted on the founding turn; the turn-shape refusal covers chat creation and messaging, not file-defined watches.
- The route goes live only after that confirmation; requests that land in the inbox earlier are durable files, drained when the doorbell first fires - deferred, never lost.
- Until that confirmation exists the First Mate sends no marked request, because a pending-reply expectation's clock starts at send and a pre-live send could exhaust its one repost before the mate has ever woken.

### Liveness and relaunch

- A side chat has no process to probe, so canonical's `dead` and `missing` verdicts map only to observable facts: the bound chat is archived or deleted (visible in the chat list), or a marked request has gone unanswered past its expectation and its one canonical repost.
- Channel silence alone is never a death verdict: a healthy mate is silent by design, idle with an empty queue.
- The doorbell's health is proven positively, not probed: the mate verifies its doorbell registration at every cold start, and a missing doorbell surfaces only as unanswered marked requests under the rule above.
- Relaunch never creates a second home: it unarchives the bound chat or creates a fresh `second: <project>` chat bound to the surviving home, and the mate reconciles from its home before acting, exactly as a restart does.
- Relaunch attempts are capped by the canonical liveness budget; past the cap the mate is parked behind its marker and escalated to the captain once.
- One archive exception: if a relaunched chat is archived again, the second archive is treated as the captain's intent - the mate is parked and escalated immediately, with no further unarchive attempts.
- A mate whose chat is mid-restart (including a context compaction) is not dead: it reconciles silently and idles, and an empty queue authorizes nothing.

### Authority

- Inside its home the mate holds the full firstmate authority set under the repo's `AGENTS.md` contract, which binds primary firstmates and persistent secondmates identically.
- It dispatches its own crew on the surfaces defined under Crew surfaces inside a mate home, ships through its projects' registered delivery modes, and publishes captain decisions as holds up the parent channel.
- Merges remain the captain's explicit word in every home; EG1's `direct-PR` posture carries no standing merge relaxation.
- The mate generates no work of its own, acts only on routed work and direct captain intervention, and never launches a secondmate.
- Under away mode the mate works the queue the main firstmate routed to it under the main home's mandate; it holds no mandate of its own and cannot widen its scope while the captain is away.

### Captain contact

- A message the captain types directly into the mate's chat is authoritative captain intervention: unmediated, conversational, and binding immediately, exactly as canonical specifies.
- There is no guardrail on that path and no approval step; the firstmate remains the default communication point because outcomes surface on the parent channel, not because the direct path is restricted.
- Captain-facing content from the mate exists only on the parent channel; a captain-facing sentence in the mate's chat has not been sent.
- The one added clause (see The charter) covers the record of a direct intervention, never permission for it.
- The test for a direct intervention is turn provenance, not the absence of a marker: a captain-typed turn in the mate's chat is intervention, while a message relayed from the First Mate's chat and a hook payload are not, whatever they say.
- The First Mate's founding brief, and any later message from the First Mate's chat, carries no captain authority beyond the routed request it accompanies; its authority flows from the captain turn that ordered it, recorded in the main home.
- The note duty in The charter therefore triggers on captain-typed turns only.
- When a captain intervention supersedes or redirects work under a pending marked request, the mate answers that request on the parent channel with its corr token, naming the intervention as the resolution, so the First Mate never escalates a phantom missing answer.

### Record intake for an inherited domain

- Provisioning a mate for an existing domain follows the canonical record-intake duty before the mate acts: reconcile every inherited plan against the project's `origin/main` and its live deployments, and seed only genuinely open work plus the domain's durable knowledge.
- Queued items in the main backlog that match the mate's scope move to the mate's backlog with the canonical handoff (byte-exact, atomic, idempotent); work already in flight in the main home finishes there unless the captain directs otherwise.
- For the EG1 pilot, the intake reconciles the edu-games repo state and both live deployments, and the seeded backlog carries EG1's open PRs, pending captain ear gates, and open field items as the mate's starting queue.

### Proof exercise

- FM-SECONDMATE-001 closes the rollout gate in two parts.
- Part one provisions the real mate: provision the `eg1` home, charter, and registry route; launch `second: eg1`; route one real EG1 task from the main firstmate through the inbox to the mate and its crew; land the outcome on the parent channel and fold it into a captain report; publish one captain hold up the channel and have it answered by the captain in the same sitting; and record one direct captain intervention in the mate's chat with its note line on the channel.
- The intervention leg is performed during the provisioning captain turn, when the captain is present in the mate's chat by definition, so the gate never waits on an unscheduled captain act.
- Part two proves retirement before any persistent mate depends on it: provision a disposable mate, route one task through it, and retire it end to end under the canonical refusal checks.
- The EG1 mate is not retired by the exercise, and its results are recorded in [`verification/runtime-backends.md`](verification/runtime-backends.md) beside the crewmate lifecycle proof.

## Rollout

Scout tasks come first.
A research crewmate in a side chat, reporting against task ids, is the reference proof.
Secondmate rollout follows the crewmate proof and is gated on the FM-SECONDMATE-001 exercise defined in the Secondmates section above; the dispatcher-based lifecycle gate this replaces assumed a bridge this backend does not use, and for secondmates its read leg is the parent channel and the mate's validated home.
Until then, Muse remains a blocked backend boundary with a verified in-session capability record, not a selectable backend.

[`verification/runtime-backends.md`](verification/runtime-backends.md#muse-app-in-session-lifecycle) owns the in-session lifecycle smoke without exposing task-specific chat ids or local paths.
