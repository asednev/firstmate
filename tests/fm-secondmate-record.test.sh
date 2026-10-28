#!/usr/bin/env bash
# fm-secondmate-record.test.sh - the muse-app endpoint record
# (docs/muse-app-backend.md, "The endpoint record"): the provisioning
# writer bin/fm-secondmate-record.sh, the send cases inside
# bin/fm-send.sh, the consumer sweep, and the teardown case inside
# bin/fm-teardown.sh.
#
# Coverage:
#   writer create   - the exact field set, each key exactly once, no
#                     window/terminal/atom/remote_host field, projects=
#                     from the registry line, spawn_gen in fm-spawn's
#                     s<epoch>.<pid>.<random> format.
#   writer create   - refuses to overwrite an existing record.
#   writer create   - refuses a home that disagrees with the registry
#                     line under the canonical path key.
#   writer update   - preserves every other line byte-for-byte (incl.
#                     fields appended by later canonical writers),
#                     rewrites muse_app_chat_id=, rotates spawn_gen=.
#   writer update   - refuses on a wrong expected-old binding and
#                     writes nothing.
#   writer update   - already-applied (new chat already recorded) is a
#                     no-op success, answered on the chat id alone ahead
#                     of any kind=/backend= shape probe.
#   writer update   - repeats the registry/home agreement check.
#   fm-send         - a marked send to a muse-app record succeeds on the
#                     inbox plane: durable inbox record with marker and
#                     corr, a pending-reply record for that corr, and no
#                     doorbell ring attempted (the fake tmux stays silent).
#   fm-send         - a slash steer refuses and arms no expectation: no
#                     inbox record, no pending-reply record.
#   fm-send         - --key refuses ahead of its dispatch.
#   fm-send         - a fire-and-forget slash steer rides the inbox
#                     plane as text (exempt from the slash refusal).
#   fm-send         - a muse-app record with no chat id does not resolve.
#   consumer sweep  - each named other reader's treatment of a muse-app
#                     record matches its treatment of a windowless record
#                     whose target read is empty (fm-send excluded by
#                     design): the shared target reader, the shared
#                     endpoint validator (and with it fm-control's
#                     refusal), the busy library classification the
#                     watcher's ring ladder / stall supervisor and the
#                     supervise daemon consume, fm-crew-state, the fleet
#                     snapshot's per-task state and endpoint treatment,
#                     and the existence-keyed live secondmate sweep in
#                     fm-ff-lib.
#   fm-teardown     - accepts a conforming muse-app record and retires
#                     the mate end to end (registry line, home, record
#                     removed); accepts empty descriptive fields (mode,
#                     yolo, harness, spawn_gen - presence exactly once is
#                     their check); refuses a muse-app-claiming record
#                     that fails the record check (a window field added).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

RECORD="$ROOT/bin/fm-secondmate-record.sh"
SEND="$ROOT/bin/fm-send.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-record)

# assert_line <exact-line> <file> <msg>: the file carries this exact line.
assert_line() {
  grep -Fxq -- "$1" "$2" || fail "$3"
}

# --- fixture homes ---------------------------------------------------------

# make_main_home <name> <mate-id> <mate-home> [projects] -> echoes the dir
# A main home whose registry binds <mate-id> to <mate-home>.
make_main_home() {
  local home="$TMP_ROOT/$1" id=$2 mate_home=$3 projects=${4:-eg1}
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf -- '- %s - %s mate (home: %s; scope: all %s work; projects: %s; added 2026-10-27)\n' \
    "$id" "$id" "$mate_home" "$id" "$projects" > "$home/data/secondmates.md"
  printf '%s\n' "$home"
}

make_mate_home() {  # <name> -> echoes the dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# run_record <home> <args...>: sets RECORD_OUT and RECORD_RC.
run_record() {
  local home=$1; shift
  RECORD_OUT=$(FM_HOME="$home" "$RECORD" "$@" 2>&1) && RECORD_RC=0 || RECORD_RC=$?
}

# --- writer create ---------------------------------------------------------

test_writer_create_exact_fields() {
  local mate_home main_home meta keys expected_keys gen
  mate_home=$(make_mate_home mate-create)
  main_home=$(make_main_home main-create eg1 "$mate_home")
  run_record "$main_home" create eg1 "$mate_home" chat-uuid-0001
  expect_code 0 "$RECORD_RC" "writer create should succeed: $RECORD_OUT"
  meta="$main_home/state/eg1.meta"
  assert_present "$meta" "writer create did not publish the record"
  # The exact key set, in the spec's order, each exactly once.
  keys=$(cut -d= -f1 "$meta" | paste -sd' ' -)
  expected_keys="kind backend muse_app_chat_id endpoint_task_id worktree project home projects mode yolo harness spawn_gen"
  [ "$keys" = "$expected_keys" ] \
    || fail "writer create: record keys are not the exact field set"$'\n'"got: $keys"
  assert_line 'kind=secondmate' "$meta" "kind field wrong"
  assert_line 'backend=muse-app' "$meta" "backend field wrong"
  assert_line 'muse_app_chat_id=chat-uuid-0001' "$meta" "chat id field wrong"
  assert_line 'endpoint_task_id=eg1' "$meta" "endpoint_task_id field wrong"
  assert_line "worktree=$mate_home" "$meta" "worktree field wrong"
  assert_line "project=$mate_home" "$meta" "project field wrong"
  assert_line "home=$mate_home" "$meta" "home field wrong"
  assert_line 'projects=eg1' "$meta" "projects field must carry the registry project list"
  assert_line 'mode=secondmate' "$meta" "mode field wrong"
  assert_line 'yolo=off' "$meta" "yolo field wrong"
  assert_line 'harness=muse' "$meta" "harness field wrong"
  gen=$(sed -n 's/^spawn_gen=//p' "$meta")
  printf '%s' "$gen" | grep -Eq '^s[0-9]+\.[0-9]+\.[0-9]+$' \
    || fail "spawn_gen is not in fm-spawn's s<epoch>.<pid>.<random> format: $gen"
  # No window-shaped or per-backend atom fields anywhere (already implied
  # by the exact key set; named explicitly because the spec names them).
  assert_no_grep 'window=' "$meta" "record must carry no window field"
  assert_no_grep 'terminal=' "$meta" "record must carry no terminal field"
  assert_no_grep 'remote_host=' "$meta" "record must carry no remote_host field"
  pass "writer create: exact endpoint-record field set, each key once, spawn_gen in spawn format"
}

test_writer_create_refuses_overwrite() {
  local mate_home main_home before
  mate_home=$(make_mate_home mate-overwrite)
  main_home=$(make_main_home main-overwrite eg1 "$mate_home")
  run_record "$main_home" create eg1 "$mate_home" chat-uuid-0001
  expect_code 0 "$RECORD_RC" "first create should succeed: $RECORD_OUT"
  before=$(cat "$main_home/state/eg1.meta")
  run_record "$main_home" create eg1 "$mate_home" chat-uuid-0002
  [ "$RECORD_RC" -ne 0 ] || fail "second create must refuse to overwrite an existing record"
  [ "$before" = "$(cat "$main_home/state/eg1.meta")" ] \
    || fail "refused overwrite still changed the record"
  pass "writer create: refuses to overwrite an existing record, record unchanged"
}

test_writer_create_refuses_registry_disagreement() {
  local mate_home other_home main_home
  mate_home=$(make_mate_home mate-registered)
  other_home=$(make_mate_home mate-other)
  main_home=$(make_main_home main-disagree eg1 "$mate_home")
  run_record "$main_home" create eg1 "$other_home" chat-uuid-0001
  [ "$RECORD_RC" -ne 0 ] || fail "create with a home that disagrees with the registry must refuse"
  assert_absent "$main_home/state/eg1.meta" "disagreement refusal still published a record"
  pass "writer create: refuses a home that disagrees with the registry line"
}

# --- writer update ---------------------------------------------------------

# seed_record_with_appends <main-home> <mate-home>: creates a record and
# appends fields the way later canonical writers do; sets SEED_META.
seed_record_with_appends() {
  local main_home=$1 mate_home=$2
  run_record "$main_home" create eg1 "$mate_home" chat-old-0001
  expect_code 0 "$RECORD_RC" "seed create should succeed: $RECORD_OUT"
  SEED_META="$main_home/state/eg1.meta"
  {
    printf 'pr=https://example.invalid/pull/1\n'
    printf 'busy_gen=b123\n'
    printf 'control_relaunch_tx=tx-9\n'
  } >> "$SEED_META"
}

test_writer_update_preserves_and_rotates() {
  local mate_home main_home meta old_gen new_gen
  mate_home=$(make_mate_home mate-update)
  main_home=$(make_main_home main-update eg1 "$mate_home")
  seed_record_with_appends "$main_home" "$mate_home"
  meta=$SEED_META
  old_gen=$(sed -n 's/^spawn_gen=//p' "$meta")
  cp "$meta" "$TMP_ROOT/update-before.meta"
  run_record "$main_home" update eg1 "$mate_home" chat-old-0001 chat-new-0002
  expect_code 0 "$RECORD_RC" "writer update should succeed: $RECORD_OUT"
  assert_line 'muse_app_chat_id=chat-new-0002' "$meta" "update did not rewrite the chat id"
  new_gen=$(sed -n 's/^spawn_gen=//p' "$meta")
  [ -n "$new_gen" ] && [ "$new_gen" != "$old_gen" ] \
    || fail "update did not rotate spawn_gen (old=$old_gen new=$new_gen)"
  printf '%s' "$new_gen" | grep -Eq '^s[0-9]+\.[0-9]+\.[0-9]+$' \
    || fail "rotated spawn_gen is not in spawn format: $new_gen"
  # Every line except the two rewritten fields is byte-for-byte identical,
  # including the fields appended after creation.
  grep -v -e '^muse_app_chat_id=' -e '^spawn_gen=' "$TMP_ROOT/update-before.meta" > "$TMP_ROOT/update-before.rest"
  grep -v -e '^muse_app_chat_id=' -e '^spawn_gen=' "$meta" > "$TMP_ROOT/update-after.rest"
  cmp -s "$TMP_ROOT/update-before.rest" "$TMP_ROOT/update-after.rest" \
    || fail "update changed lines other than muse_app_chat_id= and spawn_gen="
  assert_line 'pr=https://example.invalid/pull/1' "$meta" "appended pr field was lost"
  assert_line 'busy_gen=b123' "$meta" "appended busy_gen field was lost"
  assert_line 'control_relaunch_tx=tx-9' "$meta" "appended control field was lost"
  pass "writer update: chat id rewritten, spawn_gen rotated, every other line byte-for-byte"
}

test_writer_update_refuses_wrong_expected_old() {
  local mate_home main_home meta
  mate_home=$(make_mate_home mate-wrongold)
  main_home=$(make_main_home main-wrongold eg1 "$mate_home")
  seed_record_with_appends "$main_home" "$mate_home"
  meta=$SEED_META
  cp "$meta" "$TMP_ROOT/wrongold-before.meta"
  run_record "$main_home" update eg1 "$mate_home" chat-not-current chat-new-0002
  [ "$RECORD_RC" -ne 0 ] || fail "update with a wrong expected-old binding must refuse"
  cmp -s "$TMP_ROOT/wrongold-before.meta" "$meta" \
    || fail "wrong-expected-old refusal still wrote the record"
  pass "writer update: refuses when the record's chat id is not the expected old binding, no write"
}

test_writer_update_already_applied_is_noop() {
  local mate_home main_home meta
  mate_home=$(make_mate_home mate-applied)
  main_home=$(make_main_home main-applied eg1 "$mate_home")
  seed_record_with_appends "$main_home" "$mate_home"
  meta=$SEED_META
  cp "$meta" "$TMP_ROOT/applied-before.meta"
  # The intended new chat id is the one already recorded: already applied,
  # not an error, and no write (spawn_gen must NOT rotate).
  run_record "$main_home" update eg1 "$mate_home" chat-something-else chat-old-0001
  expect_code 0 "$RECORD_RC" "already-applied update should succeed as a no-op: $RECORD_OUT"
  cmp -s "$TMP_ROOT/applied-before.meta" "$meta" \
    || fail "already-applied update wrote the record (spawn_gen rotated or lines changed)"
  pass "writer update: intended chat already recorded is already-applied success, no write"
}

test_writer_update_already_applied_ignores_shape() {
  local mate_home main_home meta
  mate_home=$(make_mate_home mate-applied-shape)
  main_home=$(make_main_home main-applied-shape eg1 "$mate_home")
  seed_record_with_appends "$main_home" "$mate_home"
  meta=$SEED_META
  # Strip the shape lines the writer's own write path probes. The
  # already-applied answer depends only on the record's current chat id
  # (the spec's update contract keys on the binding alone), so it must
  # still answer success here, ahead of any kind=/backend= probe.
  grep -v -e '^kind=' -e '^backend=' "$meta" > "$TMP_ROOT/applied-shape-stripped.meta"
  cp "$TMP_ROOT/applied-shape-stripped.meta" "$meta"
  cp "$meta" "$TMP_ROOT/applied-shape-before.meta"
  run_record "$main_home" update eg1 "$mate_home" chat-something-else chat-old-0001
  expect_code 0 "$RECORD_RC" "already-applied update must not gate on kind/backend shape: $RECORD_OUT"
  case "$RECORD_OUT" in
    *"already applied"*) ;;
    *) fail "already-applied update did not report already applied: $RECORD_OUT" ;;
  esac
  cmp -s "$TMP_ROOT/applied-shape-before.meta" "$meta" \
    || fail "already-applied update (shape stripped) still wrote the record"
  pass "writer update: already-applied answers on the chat id alone, no shape gate, no write"
}

test_writer_update_repeats_registry_check() {
  local mate_home other_home main_home meta
  mate_home=$(make_mate_home mate-recheck)
  other_home=$(make_mate_home mate-recheck-other)
  main_home=$(make_main_home main-recheck eg1 "$mate_home")
  seed_record_with_appends "$main_home" "$mate_home"
  meta=$SEED_META
  cp "$meta" "$TMP_ROOT/recheck-before.meta"
  # The registry now names a different home for this mate.
  printf -- '- eg1 - eg1 mate (home: %s; scope: all eg1 work; projects: eg1; added 2026-10-27)\n' \
    "$other_home" > "$main_home/data/secondmates.md"
  run_record "$main_home" update eg1 "$mate_home" chat-old-0001 chat-new-0002
  [ "$RECORD_RC" -ne 0 ] || fail "update must repeat the registry/home agreement check"
  cmp -s "$TMP_ROOT/recheck-before.meta" "$meta" \
    || fail "registry-disagreement update refusal still wrote the record"
  pass "writer update: repeats the registry/home agreement check and refuses disagreement"
}

# --- fm-send cases ---------------------------------------------------------

# A fake tmux in the marker suite's shape: only literal send-keys text is
# logged, so a doorbell ring would show up as the constant doorbell line.
make_send_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf '%s\n' fm-eg1 window; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <home> <log> <fm-send args...>: sets SEND_OUT/SEND_RC.
run_send() {
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  SEND_OUT=$(env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>&1) && SEND_RC=0 || SEND_RC=$?
}

record_body() {  # <record-path>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

# make_send_world <name>: sets WORLD_MAIN, WORLD_FB, WORLD_LOG; the main
# home's eg1 record exists, written by the writer.
make_send_world() {
  local name=$1 mate_home main_home
  mate_home=$(make_mate_home "mate-$name")
  main_home=$(make_main_home "main-$name" eg1 "$mate_home")
  mkdir -p "$TMP_ROOT/send-$name"
  WORLD_FB=$(make_send_stubs "$TMP_ROOT/send-$name")
  WORLD_LOG="$TMP_ROOT/send-$name/send.log"
  WORLD_MAIN=$main_home
  run_record "$main_home" create eg1 "$mate_home" chat-uuid-0001
  expect_code 0 "$RECORD_RC" "send world record create should succeed: $RECORD_OUT"
}

pending_reply_count() {  # <state-dir>
  local n=0 f
  for f in "$1/pending-replies"/*; do
    [ -f "$f" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

test_send_marked_success_no_ring() {
  local main_home fb log got corr
  make_send_world marked
  main_home=$WORLD_MAIN; fb=$WORLD_FB; log=$WORLD_LOG
  run_send "$fb" "$main_home" "$log" eg1 "route this task"
  expect_code 0 "$SEND_RC" "marked send to a muse-app record should succeed: $SEND_OUT"
  assert_present "$main_home/state/eg1.inbox/001.msg" "send did not write the durable inbox record"
  got=$(record_body "$main_home/state/eg1.inbox/001.msg")
  case "$got" in
    *"[fm-from-firstmate]"*corr=*route\ this\ task) : ;;
    *) fail "inbox record is not the marked request with corr + body"$'\n'"$got" ;;
  esac
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  corr=$(fm_pending_reply_extract_corr "$got")
  [ -n "$corr" ] || fail "marked send embedded no corr"
  assert_present "$main_home/state/pending-replies/$corr" "marked send created no pending-reply record"
  [ "$(fm_pending_reply_get "$main_home/state/pending-replies/$corr" task_id)" = eg1 ] \
    || fail "pending-reply record names the wrong task"
  # No doorbell ring was attempted: nothing was typed anywhere.
  [ ! -s "$log" ] \
    || fail "a send to a muse-app mate typed a doorbell or payload (log: $(cat "$log"))"
  case "$SEND_OUT" in
    *"did not reach"*|*"doorbell skipped"*)
      fail "send printed a did-not-reach notice for the muse-app ring skip"$'\n'"$SEND_OUT" ;;
  esac
  pass "fm-send: marked send to a muse-app record rides the inbox plane, pending-reply armed, no ring attempted"
}

test_send_slash_refusal_arms_no_expectation() {
  local main_home fb log before
  make_send_world slash
  main_home=$WORLD_MAIN; fb=$WORLD_FB; log=$WORLD_LOG
  before=$(pending_reply_count "$main_home/state")
  run_send "$fb" "$main_home" "$log" eg1 "/compact now"
  [ "$SEND_RC" -ne 0 ] || fail "a slash steer to a muse-app record must refuse"
  assert_absent "$main_home/state/eg1.inbox/001.msg" "slash refusal still wrote an inbox record"
  [ "$(pending_reply_count "$main_home/state")" = "$before" ] \
    || fail "slash refusal armed a pending-reply expectation"
  pass "fm-send: slash steer to a muse-app record refuses and arms no expectation"
}

test_send_key_refusal() {
  local main_home fb log
  make_send_world key
  main_home=$WORLD_MAIN; fb=$WORLD_FB; log=$WORLD_LOG
  run_send "$fb" "$main_home" "$log" eg1 --key Enter
  [ "$SEND_RC" -ne 0 ] || fail "--key to a muse-app record must refuse"
  assert_absent "$main_home/state/eg1.inbox" "key refusal still created an inbox"
  pass "fm-send: --key to a muse-app record refuses ahead of dispatch"
}

test_send_fire_and_forget_slash_rides_inbox() {
  local main_home fb log got before
  make_send_world ff
  main_home=$WORLD_MAIN; fb=$WORLD_FB; log=$WORLD_LOG
  before=$(pending_reply_count "$main_home/state")
  run_send "$fb" "$main_home" "$log" eg1 --fire-and-forget 0123456789abcdef "/status please"
  expect_code 0 "$SEND_RC" "fire-and-forget slash steer should ride the inbox plane: $SEND_OUT"
  got=$(record_body "$main_home/state/eg1.inbox/001.msg")
  case "$got" in
    *delivery=0123456789abcdef*/status\ please*) : ;;
    *) fail "fire-and-forget record does not carry the slash steer as text"$'\n'"$got" ;;
  esac
  [ "$(pending_reply_count "$main_home/state")" = "$before" ] \
    || fail "fire-and-forget send armed a pending-reply expectation"
  pass "fm-send: fire-and-forget slash steer is carried by the inbox plane as text"
}

test_send_no_chat_id_does_not_resolve() {
  local mate_home main_home fb log
  mate_home=$(make_mate_home mate-nochat)
  main_home=$(make_main_home main-nochat eg1 "$mate_home")
  mkdir -p "$TMP_ROOT/send-nochat"
  fb=$(make_send_stubs "$TMP_ROOT/send-nochat")
  log="$TMP_ROOT/send-nochat/send.log"
  # A muse-app record with no chat id, hand-shaped to the writer's field
  # set minus muse_app_chat_id (the writer itself never emits this).
  fm_write_meta "$main_home/state/eg1.meta" \
    "kind=secondmate" "backend=muse-app" "endpoint_task_id=eg1" \
    "worktree=$mate_home" "project=$mate_home" "home=$mate_home" \
    "projects=eg1" "mode=secondmate" "yolo=off" "harness=muse" \
    "spawn_gen=s1.2.3"
  run_send "$fb" "$main_home" "$log" eg1 "route this task"
  [ "$SEND_RC" -ne 0 ] || fail "a muse-app record with no chat id must not resolve"
  assert_absent "$main_home/state/eg1.inbox/001.msg" "unresolvable send still wrote an inbox record"
  pass "fm-send: a muse-app record with no chat id does not resolve"
}

# --- consumer sweep --------------------------------------------------------

# make_sweep_world <name> <shape> -> echoes the main home; shape is
# muse-app or windowless. Both records describe the same mate id; the
# mate home path differs per world and is named sweep-<name>-mate.
make_sweep_world() {
  local name=$1 shape=$2 mate_home home
  mate_home="$TMP_ROOT/sweep-$name-mate"
  mkdir -p "$mate_home"
  home="$TMP_ROOT/sweep-$name"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  : > "$home/state/mate.status"
  if [ "$shape" = muse-app ]; then
    fm_write_meta "$home/state/mate.meta" \
      "kind=secondmate" "backend=muse-app" "muse_app_chat_id=chat-uuid-0001" \
      "endpoint_task_id=mate" "worktree=$mate_home" "project=$mate_home" \
      "home=$mate_home" "projects=eg1" "mode=secondmate" "yolo=off" \
      "harness=muse" "spawn_gen=s123.1.2"
  else
    fm_write_meta "$home/state/mate.meta" \
      "kind=secondmate" \
      "endpoint_task_id=mate" "worktree=$mate_home" "project=$mate_home" \
      "home=$mate_home" "projects=eg1" "mode=secondmate" "yolo=off" \
      "harness=muse" "spawn_gen=s123.1.2"
  fi
  printf '%s\n' "$home"
}

test_consumer_sweep() {
  local home_a home_b target_a target_b busy_a busy_b crew_a crew_b
  local snap_a snap_b ctrl_a ctrl_b ff_a ff_b
  home_a=$(make_sweep_world a muse-app)
  home_b=$(make_sweep_world b windowless)
  # Shared target reader (the read the watcher's ring ladder and stall
  # supervisor, the supervise daemon, crew state, and the fleet snapshot
  # all consume): empty for both.
  target_a=$(bash -c '. "$1"; fm_backend_target_of_meta "$2"' _ "$ROOT/bin/fm-backend.sh" "$home_a/state/mate.meta" || true)
  target_b=$(bash -c '. "$1"; fm_backend_target_of_meta "$2"' _ "$ROOT/bin/fm-backend.sh" "$home_b/state/mate.meta" || true)
  [ -z "$target_a" ] && [ "$target_a" = "$target_b" ] \
    || fail "shared target read differs: muse-app '$target_a' vs windowless '$target_b'"
  # The shared endpoint validator is not taught the shape: it refuses
  # both records, so fm-control refuses a muse-app mate at the same
  # validation it runs on any windowless record.
  if bash -c '. "$1"; fm_backend_validate_task_endpoint "$2" mate' _ "$ROOT/bin/fm-backend.sh" "$home_a/state/mate.meta" >/dev/null 2>&1; then
    fail "shared endpoint validator accepted a muse-app record"
  fi
  if bash -c '. "$1"; fm_backend_validate_task_endpoint "$2" mate' _ "$ROOT/bin/fm-backend.sh" "$home_b/state/mate.meta" >/dev/null 2>&1; then
    fail "shared endpoint validator accepted a windowless record"
  fi
  ctrl_a=$(FM_HOME="$home_a" "$ROOT/bin/fm-control.sh" mate exit 2>&1) || true
  ctrl_b=$(FM_HOME="$home_b" "$ROOT/bin/fm-control.sh" mate exit 2>&1) || true
  [ -n "$ctrl_a" ] && [ "$ctrl_a" = "$ctrl_b" ] \
    || fail "fm-control treatment differs"$'\n'"muse-app: $ctrl_a"$'\n'"windowless: $ctrl_b"
  # Busy library classification (consumed by the watcher's ring ladder
  # and stall supervisor and by the supervise daemon): identical.
  busy_a=$(bash -c '. "$1"; . "$2"; fm_busy_classify_meta "$3" mate "$4"' _ \
    "$ROOT/bin/fm-backend.sh" "$ROOT/bin/fm-busy-lib.sh" "$home_a/state/mate.meta" "$home_a/state")
  busy_b=$(bash -c '. "$1"; . "$2"; fm_busy_classify_meta "$3" mate "$4"' _ \
    "$ROOT/bin/fm-backend.sh" "$ROOT/bin/fm-busy-lib.sh" "$home_b/state/mate.meta" "$home_b/state")
  [ "$busy_a" = "unknown no-target" ] && [ "$busy_a" = "$busy_b" ] \
    || fail "busy classification differs: muse-app '$busy_a' vs windowless '$busy_b'"
  # Crew state: identical verdict line.
  crew_a=$(FM_HOME="$home_a" "$ROOT/bin/fm-crew-state.sh" mate 2>/dev/null)
  crew_b=$(FM_HOME="$home_b" "$ROOT/bin/fm-crew-state.sh" mate 2>/dev/null)
  [ -n "$crew_a" ] && [ "$crew_a" = "$crew_b" ] \
    || fail "crew-state treatment differs"$'\n'"muse-app: $crew_a"$'\n'"windowless: $crew_b"
  # Fleet snapshot: identical per-task current state and endpoint
  # treatment (timestamps excluded).
  if command -v jq >/dev/null 2>&1; then
    snap_a=$(FM_HOME="$home_a" "$ROOT/bin/fm-fleet-snapshot.sh" --json 2>/dev/null \
      | jq -c '.tasks[]? | select(.id=="mate") | {state: (.current_state | del(.observed_at)), endpoint: (.endpoint | del(.observed_at))}')
    snap_b=$(FM_HOME="$home_b" "$ROOT/bin/fm-fleet-snapshot.sh" --json 2>/dev/null \
      | jq -c '.tasks[]? | select(.id=="mate") | {state: (.current_state | del(.observed_at)), endpoint: (.endpoint | del(.observed_at))}')
    [ -n "$snap_a" ] && [ "$snap_a" = "$snap_b" ] \
      || fail "fleet snapshot treatment differs"$'\n'"muse-app: $snap_a"$'\n'"windowless: $snap_b"
  fi
  # The existence-keyed live secondmate sweep (fm-ff-lib) lists the mate
  # from the moment its record exists, with its home and an empty
  # window, exactly as for a windowless record.
  ff_a=$(bash -c '. "$1"; live_secondmate_meta_records "$2"' _ "$ROOT/bin/fm-ff-lib.sh" "$home_a/state")
  ff_b=$(bash -c '. "$1"; live_secondmate_meta_records "$2"' _ "$ROOT/bin/fm-ff-lib.sh" "$home_b/state")
  [ "$ff_a" = "mate|$TMP_ROOT/sweep-a-mate||$home_a/state/mate.meta" ] \
    || fail "ff live sweep does not list the muse-app mate with home and empty window: $ff_a"
  [ "$ff_b" = "mate|$TMP_ROOT/sweep-b-mate||$home_b/state/mate.meta" ] \
    || fail "ff live sweep does not list the windowless mate with home and empty window: $ff_b"
  pass "consumer sweep: muse-app record treatment matches the windowless record's for every named other reader"
}

# --- teardown case ---------------------------------------------------------

# make_teardown_world <name>: seeds a real project-less mate home via
# fm-home-seed and writes its record with the writer; sets TD_MAIN/TD_MATE.
make_teardown_world() {
  local name=$1 out
  TD_MAIN="$TMP_ROOT/td-$name-main"
  TD_MATE="$TMP_ROOT/td-$name-mate"
  mkdir -p "$TD_MAIN/data" "$TD_MAIN/state" "$TD_MAIN/config" "$TD_MAIN/projects"
  out=$(FM_HOME="$TD_MAIN" FM_SECONDMATE_CHARTER='smoke mate charter' \
    FM_SECONDMATE_SCOPE='smoke testing' \
    "$ROOT/bin/fm-home-seed.sh" smoke "$TD_MATE" --no-projects 2>&1) \
    || fail "teardown world seed failed: $out"
  run_record "$TD_MAIN" create smoke "$TD_MATE" chat-smoke-0001
  expect_code 0 "$RECORD_RC" "teardown world record create should succeed: $RECORD_OUT"
}

run_teardown() {  # <main-home>
  TD_OUT=$(FM_HOME="$1" FM_ROOT_OVERRIDE="$1" "$TEARDOWN" smoke 2>&1) && TD_RC=0 || TD_RC=$?
}

test_teardown_retires_muse_app_mate() {
  make_teardown_world retire
  run_teardown "$TD_MAIN"
  expect_code 0 "$TD_RC" "teardown of a muse-app mate should succeed: $TD_OUT"
  assert_absent "$TD_MATE" "teardown did not remove the muse-app mate home"
  assert_absent "$TD_MAIN/state/smoke.meta" "teardown did not remove the endpoint record"
  assert_no_grep '- smoke ' "$TD_MAIN/data/secondmates.md" "teardown did not remove the registry line"
  pass "fm-teardown: a muse-app mate retires end to end (registry line, home, record removed)"
}

test_teardown_tolerates_empty_descriptive_fields() {
  make_teardown_world empties
  # The descriptive named fields (mode, yolo, harness, spawn_gen) are
  # checked for presence exactly once; readers take the named fields as
  # they find them, so empty values do not fail teardown's record check.
  local meta="$TD_MAIN/state/smoke.meta"
  sed -e 's/^mode=.*/mode=/' -e 's/^yolo=.*/yolo=/' \
      -e 's/^harness=.*/harness=/' -e 's/^spawn_gen=.*/spawn_gen=/' \
      "$meta" > "$TMP_ROOT/empties.meta"
  cp "$TMP_ROOT/empties.meta" "$meta"
  run_teardown "$TD_MAIN"
  expect_code 0 "$TD_RC" "teardown must accept empty descriptive fields: $TD_OUT"
  assert_absent "$TD_MATE" "teardown did not remove the mate home (empty descriptive fields)"
  assert_absent "$TD_MAIN/state/smoke.meta" "teardown did not remove the record (empty descriptive fields)"
  pass "fm-teardown: empty descriptive fields (mode/yolo/harness/spawn_gen) do not fail the record check"
}

test_teardown_refuses_misshapen_muse_app_record() {
  make_teardown_world misshapen
  # A window field makes the record fail teardown's muse-app record check.
  printf 'window=some:fm-smoke\n' >> "$TD_MAIN/state/smoke.meta"
  run_teardown "$TD_MAIN"
  [ "$TD_RC" -ne 0 ] || fail "teardown must refuse a muse-app record carrying a window field"
  assert_present "$TD_MATE" "refused teardown still removed the mate home"
  assert_present "$TD_MAIN/state/smoke.meta" "refused teardown still removed the record"
  pass "fm-teardown: a muse-app-claiming record that fails the record check is refused, nothing removed"
}

test_writer_create_exact_fields
test_writer_create_refuses_overwrite
test_writer_create_refuses_registry_disagreement
test_writer_update_preserves_and_rotates
test_writer_update_refuses_wrong_expected_old
test_writer_update_already_applied_is_noop
test_writer_update_already_applied_ignores_shape
test_writer_update_repeats_registry_check
test_send_marked_success_no_ring
test_send_slash_refusal_arms_no_expectation
test_send_key_refusal
test_send_fire_and_forget_slash_rides_inbox
test_send_no_chat_id_does_not_resolve
test_consumer_sweep
test_teardown_retires_muse_app_mate
test_teardown_tolerates_empty_descriptive_fields
test_teardown_refuses_misshapen_muse_app_record
