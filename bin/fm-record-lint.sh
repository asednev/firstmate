#!/usr/bin/env bash
# Validate the muse-app supervision records in a state tree against the
# status and checkpoint contract owned by docs/muse-app-runbook.md.
# Usage:
#   fm-record-lint.sh [state-dir]
#
# The state dir defaults to $FM_HOME/state (FM_STATE_OVERRIDE wins when set).
# Every finding prints one line: record-lint: <task-id>: <problem>.
# Exit 0 when the tree is clean, 1 when any finding exists, 2 on usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${1:-${FM_STATE_OVERRIDE:-$FM_HOME/state}}"

usage() {
  sed -n '2,9{s/^# \{0,1\}//;p;}' "$0"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ ! -d "$STATE" ]; then
  printf 'record-lint: state dir not found: %s\n' "$STATE" >&2
  exit 2
fi

findings=0
checked=0

report() {  # <task-id> <problem>
  printf 'record-lint: %s: %s\n' "$1" "$2"
  findings=$((findings + 1))
}

count_lines() {  # <file> <anchored-regex> -> count on stdout
  grep -c "$2" "$1" || true
}

# Status-line structure, checked in one awk pass per file. An in-flight file
# with no terminal line yet is clean; anything after a terminal line is not.
lint_status() {  # <task-id> <status-file>
  local id=$1 file=$2 problem
  while IFS= read -r problem; do
    report "$id" "$problem"
  done < <(awk '
    BEGIN { started = 0; terminal = 0; first = 1; seen_check = 0; crlf = 0 }
    {
      if (/\r$/) {
        if (!crlf) { print "file uses CRLF line endings"; crlf = 1 }
        sub(/\r$/, "")
      }
      if (first) {
        if ($0 !~ /^started:/) print "first status line is not started:"
        first = 0
      }
      if ($0 ~ /^started:/) {
        started++
        if (started > 1) print "started: appears more than once"
      } else if ($0 ~ /^check:/) {
        seen_check = 1
      } else if ($0 ~ /^correction:/) {
        if (!seen_check) print "correction: with no earlier check: line to supersede"
      } else if ($0 ~ /^(done|blocked):/) {
        terminal++
        if (terminal > 1) print "more than one terminal line"
      } else {
        printf "unknown status line: %s\n", $0
      }
      if (terminal > 0 && $0 !~ /^(done|blocked):/) {
        printf "status line after the terminal line: %s\n", $0
      }
    }
    END { if (NR == 0) print "status file is empty" }
  ' "$file")
}

lint_pair() {  # <task-id> <status-file> <checkpoint-file>
  local id=$1 status=$2 checkpoint=$3
  local handled_count superseded closed deferred endpoint_type report_path resolved

  handled_count=$(count_lines "$checkpoint" '^state: handled[[:space:]]*$')
  superseded=0
  grep -q '^state: superseded[[:space:]]*$' "$checkpoint" && superseded=1
  closed=0
  if [ "$handled_count" -ge 1 ] || [ "$superseded" -eq 1 ]; then closed=1; fi
  deferred=0
  grep -q '^closure_deferred:' "$checkpoint" && deferred=1

  if ! grep -q '^state:' "$checkpoint"; then
    report "$id" "checkpoint has no state line"
  fi
  if [ "$handled_count" -gt 1 ]; then
    report "$id" "state: handled appears $handled_count times"
  fi
  if [ "$superseded" -eq 1 ] && ! grep -q '^resolved_by: ' "$checkpoint"; then
    report "$id" "state: superseded without resolved_by:"
  fi
  if [ "$handled_count" -ge 1 ] && [ "$superseded" -eq 1 ]; then
    report "$id" "checkpoint carries both state: handled and state: superseded"
  fi

  # A closure must match its terminal line: handled closes done:, superseded
  # closes blocked:.
  if [ "$handled_count" -ge 1 ] && ! grep -q '^done:' "$status"; then
    report "$id" "marked handled but the status terminal line is not done:"
  fi
  if [ "$superseded" -eq 1 ] && ! grep -q '^blocked:' "$status"; then
    report "$id" "closed as superseded but the status terminal line is not blocked:"
  fi
  if grep -q '^done:' "$status" && [ "$closed" -eq 0 ] && [ "$deferred" -eq 0 ]; then
    report "$id" "status reached done: but the wait was never closed"
  fi

  if grep -q '^handled_at:' "$checkpoint" && [ "$closed" -eq 0 ]; then
    report "$id" "handled_at: recorded but the wait has no closure"
  fi
  if grep -q '^errata:' "$checkpoint" && [ "$closed" -eq 0 ]; then
    report "$id" "errata: recorded on a checkpoint that is not closed"
  fi

  # Open waits carry the live contract: the fields the wake and the silence
  # watchdog read. Closed records are history and are not rechecked for them.
  if [ "$closed" -eq 0 ]; then
    endpoint_type=$(sed -n 's/^endpoint_type: //p' "$checkpoint" | head -n 1)
    if [ -z "$endpoint_type" ]; then
      report "$id" "open checkpoint is missing endpoint_type:"
    elif [ "$endpoint_type" != "crewmate" ] && [ "$endpoint_type" != "subagent" ]; then
      report "$id" "open checkpoint has an unrecognized endpoint_type: $endpoint_type"
    fi
    if ! grep -q '^expected_first_check:' "$checkpoint"; then
      report "$id" "open checkpoint is missing expected_first_check:"
    fi
    if ! grep -q '^expected_terminal:' "$checkpoint"; then
      report "$id" "open checkpoint is missing expected_terminal:"
    fi
    if [ "$endpoint_type" = "crewmate" ] && ! grep -q '^endpoint_chat:' "$checkpoint"; then
      report "$id" "open crewmate checkpoint is missing endpoint_chat:"
    fi
    if [ "$endpoint_type" = "subagent" ]; then
      report_path=$(sed -n 's/^report: //p' "$checkpoint" | head -n 1)
      if [ -z "$report_path" ]; then
        report "$id" "open subagent checkpoint is missing report:"
      else
        resolved=$report_path
        case "$resolved" in
          /*) ;;
          *) resolved="$FM_HOME/$resolved" ;;
        esac
        if [ ! -f "$resolved" ]; then
          report "$id" "subagent report not found: $report_path"
        fi
      fi
    fi
  fi
}

for status in "$STATE"/*.status; do
  [ -e "$status" ] || continue
  id=$(basename "$status" .status)
  checked=$((checked + 1))
  if [ ! -f "$status" ]; then
    report "$id" "status path is not a regular file"
    continue
  fi
  lint_status "$id" "$status"

  checkpoint="$STATE/$id.checkpoint"
  if [ ! -f "$checkpoint" ]; then
    report "$id" "status file has no checkpoint"
    continue
  fi
  lint_pair "$id" "$status" "$checkpoint"
done

for checkpoint in "$STATE"/*.checkpoint; do
  [ -e "$checkpoint" ] || continue
  id=$(basename "$checkpoint" .checkpoint)
  if [ ! -f "$STATE/$id.status" ]; then
    checked=$((checked + 1))
    report "$id" "checkpoint has no status file"
  fi
done

if [ "$findings" -gt 0 ]; then
  printf 'record-lint: %s finding(s) across %s task record(s)\n' "$findings" "$checked"
  exit 1
fi
printf 'record-lint: clean (%s task record(s) checked)\n' "$checked"
