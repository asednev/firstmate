#!/usr/bin/env bash
# tests/fm-record-lint.test.sh - the muse-app supervision record validator
# (bin/fm-record-lint.sh): the status/checkpoint contract owned by
# docs/muse-app-runbook.md, exercised through the executable against fixture
# state trees: a clean closed pair, a clean in-flight pair, a pre-terminal
# correction, a superseded closure with and without its resolver, and the
# violation shapes the validator exists to catch - handled on a blocked
# terminal, handled twice, a status line after the terminal line, and a
# done: wait that was never closed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-record-lint.sh"
TMP_ROOT=$(fm_test_tmproot fm-record-lint-tests)

make_state() {  # <name> -> prints the state dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

write_pair() {  # <state-dir> <task-id> <status-body> <checkpoint-body>
  local dir=$1 id=$2
  printf '%s\n' "$3" > "$dir/$id.status"
  printf '%s\n' "$4" > "$dir/$id.checkpoint"
}

lint() {  # <state-dir> -> combined output; exit code in $LINT_CODE
  local dir=$1
  LINT_OUTPUT=$(FM_STATE_OVERRIDE="$dir" "$LINT" 2>&1)
  LINT_CODE=$?
}

test_clean_closed_pair_passes() {
  local dir; dir=$(make_state closed)
  write_pair "$dir" FM-T-001 \
    "started: work started
check: midpoint reached
done: report posted" \
    "task: FM-T-001
endpoint_type: crewmate
state: open
state: handled
handled_at: 2026-10-25T00:00:00Z"
  lint "$dir"
  expect_code 0 "$LINT_CODE" "clean closed pair"
  assert_contains "$LINT_OUTPUT" "clean" "clean closed pair reports clean"
  pass "a clean closed record pair passes"
}

test_clean_in_flight_pair_passes() {
  local dir; dir=$(make_state inflight)
  write_pair "$dir" FM-T-002 \
    "started: work started
check: midpoint reached" \
    "task: FM-T-002
endpoint_type: crewmate
state: open"
  lint "$dir"
  expect_code 0 "$LINT_CODE" "clean in-flight pair"
  pass "an in-flight pair with no terminal line passes"
}

test_pre_terminal_correction_passes() {
  local dir; dir=$(make_state correction-ok)
  write_pair "$dir" FM-T-003 \
    "started: work started
check: gates 674/674
correction: gates are 686/686
done: report posted" \
    "task: FM-T-003
endpoint_type: crewmate
state: open
state: handled
handled_at: 2026-10-25T00:00:00Z"
  lint "$dir"
  expect_code 0 "$LINT_CODE" "pre-terminal correction"
  pass "a correction: line before the terminal line passes"
}

test_superseded_with_resolver_passes() {
  local dir; dir=$(make_state superseded-ok)
  write_pair "$dir" FM-T-004 \
    "started: work started
blocked: merge conflict needs a successor" \
    "task: FM-T-004
endpoint_type: crewmate
state: open
state: superseded
resolved_by: FM-T-005
handled_at: 2026-10-25T00:00:00Z"
  lint "$dir"
  expect_code 0 "$LINT_CODE" "superseded with resolver"
  pass "a blocked record closed as superseded with resolved_by: passes"
}

test_handled_on_blocked_fails() {
  local dir; dir=$(make_state blocked-handled)
  write_pair "$dir" FM-T-006 \
    "started: work started
blocked: merge conflict needs a successor" \
    "task: FM-T-006
endpoint_type: crewmate
state: open
state: handled
handled_at: 2026-10-25T00:00:00Z"
  lint "$dir"
  expect_code 1 "$LINT_CODE" "handled on blocked"
  assert_contains "$LINT_OUTPUT" "not done:" "handled on blocked names the defect"
  pass "a blocked record marked handled fails"
}

test_handled_twice_fails() {
  local dir; dir=$(make_state handled-twice)
  write_pair "$dir" FM-T-007 \
    "started: work started
done: report posted" \
    "task: FM-T-007
endpoint_type: crewmate
state: open
state: handled
handled_at: 2026-10-25T00:00:00Z
state: handled
handled_at: 2026-10-25T00:01:00Z"
  lint "$dir"
  expect_code 1 "$LINT_CODE" "handled twice"
  assert_contains "$LINT_OUTPUT" "appears 2 times" "handled twice names the count"
  pass "a checkpoint handled twice fails"
}

test_line_after_terminal_fails() {
  local dir; dir=$(make_state post-terminal)
  write_pair "$dir" FM-T-008 \
    "started: work started
check: gates 674/674
done: report posted
correction: gates are 686/686" \
    "task: FM-T-008
endpoint_type: crewmate
state: open
state: handled
handled_at: 2026-10-25T00:00:00Z"
  lint "$dir"
  expect_code 1 "$LINT_CODE" "line after terminal"
  assert_contains "$LINT_OUTPUT" "after the terminal line" "post-terminal line is named"
  pass "a status line after the terminal line fails"
}

test_done_never_closed_fails() {
  local dir; dir=$(make_state never-closed)
  write_pair "$dir" FM-T-009 \
    "started: work started
done: report posted" \
    "task: FM-T-009
endpoint_type: crewmate
state: open"
  lint "$dir"
  expect_code 1 "$LINT_CODE" "done never closed"
  assert_contains "$LINT_OUTPUT" "never closed" "unclosed done: is named"
  pass "a done: wait that was never closed fails"
}

test_superseded_without_resolver_fails() {
  local dir; dir=$(make_state superseded-bad)
  write_pair "$dir" FM-T-010 \
    "started: work started
blocked: merge conflict needs a successor" \
    "task: FM-T-010
endpoint_type: crewmate
state: open
state: superseded
handled_at: 2026-10-25T00:00:00Z"
  lint "$dir"
  expect_code 1 "$LINT_CODE" "superseded without resolver"
  assert_contains "$LINT_OUTPUT" "without resolved_by:" "missing resolver is named"
  pass "a superseded closure without resolved_by: fails"
}

test_unknown_status_line_fails() {
  local dir; dir=$(make_state unknown-line)
  write_pair "$dir" FM-T-011 \
    "started: work started
progress: halfway there
done: report posted" \
    "task: FM-T-011
endpoint_type: crewmate
state: open
state: handled
handled_at: 2026-10-25T00:00:00Z"
  lint "$dir"
  expect_code 1 "$LINT_CODE" "unknown status line"
  assert_contains "$LINT_OUTPUT" "unknown status line" "unknown line is named"
  pass "an out-of-vocabulary status line fails"
}

test_clean_closed_pair_passes
test_clean_in_flight_pair_passes
test_pre_terminal_correction_passes
test_superseded_with_resolver_passes
test_handled_on_blocked_fails
test_handled_twice_fails
test_line_after_terminal_fails
test_done_never_closed_fails
test_superseded_without_resolver_fails
test_unknown_status_line_fails
