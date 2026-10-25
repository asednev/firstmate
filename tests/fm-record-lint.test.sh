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

test_both_closures_fail() {
  local dir; dir=$(make_state both-closures)
  write_pair "$dir" FM-T-012 \
    "started: work started
done: report posted" \
    "task: FM-T-012
endpoint_type: crewmate
state: open
state: handled
handled_at: 2026-10-25T00:00:00Z
state: superseded
resolved_by: FM-T-013"
  lint "$dir"
  expect_code 1 "$LINT_CODE" "both closures"
  assert_contains "$LINT_OUTPUT" "both state: handled and state: superseded" "dual closure is named"
  pass "a checkpoint carrying both closures fails"
}

test_superseded_on_done_fails() {
  local dir; dir=$(make_state superseded-on-done)
  write_pair "$dir" FM-T-013 \
    "started: work started
done: report posted" \
    "task: FM-T-013
endpoint_type: crewmate
state: open
state: superseded
resolved_by: FM-T-014"
  lint "$dir"
  expect_code 1 "$LINT_CODE" "superseded on done"
  assert_contains "$LINT_OUTPUT" "not blocked:" "closure/terminal mismatch is named"
  pass "a done: record closed as superseded fails"
}

test_prefix_closure_fails() {
  local dir; dir=$(make_state prefix-closure)
  write_pair "$dir" FM-T-014 \
    "started: work started
done: report posted" \
    "task: FM-T-014
endpoint_type: crewmate
state: open
state: handled-pending-review
handled_at: 2026-10-25T00:00:00Z"
  lint "$dir"
  expect_code 1 "$LINT_CODE" "prefix closure"
  assert_contains "$LINT_OUTPUT" "never closed" "a prefix-matching state line is not a closure"
  pass "a state: handled-pending-review line does not close the wait"
}

test_open_checkpoint_missing_fields_fails() {
  local dir; dir=$(make_state open-missing-fields)
  write_pair "$dir" FM-T-015 \
    "started: work started" \
    "task: FM-T-015
endpoint_type: crewmate
state: open"
  lint "$dir"
  expect_code 1 "$LINT_CODE" "open checkpoint missing fields"
  assert_contains "$LINT_OUTPUT" "missing expected_first_check:" "missing first expectation is named"
  assert_contains "$LINT_OUTPUT" "missing expected_terminal:" "missing terminal expectation is named"
  assert_contains "$LINT_OUTPUT" "missing endpoint_chat:" "missing chat id is named"
  pass "an open checkpoint missing its live fields fails"
}

test_open_subagent_report_missing_fails() {
  local dir; dir=$(make_state subagent-no-report)
  write_pair "$dir" FM-T-016 \
    "started: work started" \
    "task: FM-T-016
endpoint_type: subagent
expected_first_check: 2026-10-25T01:00:00Z
expected_terminal: 2026-10-25T02:00:00Z
state: open"
  lint "$dir"
  expect_code 1 "$LINT_CODE" "subagent without report path"
  assert_contains "$LINT_OUTPUT" "missing report:" "missing report path is named"
  pass "an open subagent checkpoint without a report path fails"
}

test_open_subagent_with_report_passes() {
  local dir; dir=$(make_state subagent-with-report)
  write_pair "$dir" FM-T-017 \
    "started: work started" \
    "task: FM-T-017
endpoint_type: subagent
report: docs/muse-app-runbook.md
expected_first_check: 2026-10-25T01:00:00Z
expected_terminal: 2026-10-25T02:00:00Z
state: open"
  lint "$dir"
  expect_code 0 "$LINT_CODE" "subagent with existing report"
  pass "an open subagent checkpoint whose report file exists passes"
}

test_closure_deferred_passes() {
  local dir; dir=$(make_state deferred)
  write_pair "$dir" FM-T-018 \
    "started: work started
done: report posted" \
    "task: FM-T-018
endpoint_type: crewmate
endpoint_chat: 00000000-0000-0000-0000-000000000000
expected_first_check: 2026-10-25T01:00:00Z
expected_terminal: 2026-10-25T02:00:00Z
state: open
closure_deferred: endpoint report missing; wait stays open per Handle a wake step 5"
  lint "$dir"
  expect_code 0 "$LINT_CODE" "closure deferred with reason"
  pass "a done: wait left open with a recorded closure_deferred: reason passes"
}

test_correction_without_check_fails() {
  local dir; dir=$(make_state correction-no-check)
  write_pair "$dir" FM-T-019 \
    "started: work started
correction: gates are 686/686
done: report posted" \
    "task: FM-T-019
endpoint_type: crewmate
state: open
state: handled
handled_at: 2026-10-25T00:00:00Z"
  lint "$dir"
  expect_code 1 "$LINT_CODE" "correction without check"
  assert_contains "$LINT_OUTPUT" "no earlier check:" "orphan correction is named"
  pass "a correction: with no earlier check: line fails"
}

test_errata_on_open_fails() {
  local dir; dir=$(make_state errata-open)
  write_pair "$dir" FM-T-020 \
    "started: work started" \
    "task: FM-T-020
endpoint_type: crewmate
endpoint_chat: 00000000-0000-0000-0000-000000000000
expected_first_check: 2026-10-25T01:00:00Z
expected_terminal: 2026-10-25T02:00:00Z
state: open
errata: gates figure corrected"
  lint "$dir"
  expect_code 1 "$LINT_CODE" "errata on open checkpoint"
  assert_contains "$LINT_OUTPUT" "not closed" "premature errata is named"
  pass "an errata: note on an unclosed checkpoint fails"
}

test_crlf_fails() {
  local dir; dir=$(make_state crlf)
  printf 'started: work started\r\ndone: report posted\r\n' > "$dir/FM-T-021.status"
  printf '%s\n' "task: FM-T-021
endpoint_type: crewmate
state: open
state: handled
handled_at: 2026-10-25T00:00:00Z" > "$dir/FM-T-021.checkpoint"
  lint "$dir"
  expect_code 1 "$LINT_CODE" "CRLF status"
  assert_contains "$LINT_OUTPUT" "CRLF" "CRLF endings are named"
  pass "a CRLF status file fails"
}

test_handled_at_without_closure_fails() {
  local dir; dir=$(make_state handled-at-orphan)
  write_pair "$dir" FM-T-022 \
    "started: work started" \
    "task: FM-T-022
endpoint_type: crewmate
endpoint_chat: 00000000-0000-0000-0000-000000000000
expected_first_check: 2026-10-25T01:00:00Z
expected_terminal: 2026-10-25T02:00:00Z
state: open
handled_at: 2026-10-25T00:00:00Z"
  lint "$dir"
  expect_code 1 "$LINT_CODE" "handled_at without closure"
  assert_contains "$LINT_OUTPUT" "no closure" "orphan handled_at is named"
  pass "a handled_at: with no closure fails"
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
endpoint_chat: 00000000-0000-0000-0000-000000000000
expected_first_check: 2026-10-25T01:00:00Z
expected_terminal: 2026-10-25T02:00:00Z
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
test_both_closures_fail
test_superseded_on_done_fails
test_prefix_closure_fails
test_open_checkpoint_missing_fields_fails
test_open_subagent_report_missing_fails
test_open_subagent_with_report_passes
test_closure_deferred_passes
test_correction_without_check_fails
test_errata_on_open_fails
test_crlf_fails
test_handled_at_without_closure_fails
