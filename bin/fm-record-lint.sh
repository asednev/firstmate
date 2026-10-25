#!/usr/bin/env bash
# Validate the muse-app supervision records in a state tree against the
# status and checkpoint contract owned by docs/muse-app-runbook.md.
# Usage:
#   fm-record-lint.sh [state-dir]
#
# The state dir defaults to $FM_HOME/state (FM_STATE_OVERRIDE wins when set).
# Relative record paths (a subagent checkpoint's report:) resolve against
# the state dir's parent, which is the home that owns the tree.
# The linter validates record form, not the truth of what is recorded.
# Every finding prints one line: record-lint: <task-id>: <problem>.
# Exit 0 when the tree is clean, 1 when any finding exists, 2 on usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${1:-${FM_STATE_OVERRIDE:-$FM_HOME/state}}"

usage() {
  sed -n '2,12{s/^# \{0,1\}//;p;}' "$0"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ ! -d "$STATE" ]; then
  printf 'record-lint: state dir not found: %s\n' "$STATE" >&2
  exit 2
fi
STATE=$(cd "$STATE" && pwd -P)
HOME_ROOT=$(dirname "$STATE")

findings=0
checked=0
declare -A seen=()

report() {  # <task-id> <problem>
  printf 'record-lint: %s: %s\n' "$1" "$2"
  findings=$((findings + 1))
}

count_lines() {  # <file> <anchored-regex> -> count on stdout
  grep -a -c "$2" "$1" || true
}

first_line_no() {  # <file> <anchored-regex> -> first matching line number, 0 if none
  local n
  n=$(grep -a -n "$2" "$1" | head -n 1 | cut -d: -f1 || true)
  printf '%s' "${n:-0}"
}

last_line_no() {  # <file> <anchored-regex> -> last matching line number, 0 if none
  local n
  n=$(grep -a -n "$2" "$1" | tail -n 1 | cut -d: -f1 || true)
  printf '%s' "${n:-0}"
}

valid_ts() {  # <value> -> 0 when the value is a full ISO-shaped timestamp
  [[ $1 =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])([T\ ][0-9]{2}:[0-9]{2}(:[0-9]{2})?([+-][0-9]{2}:?[0-9]{2}|Z)?)?[[:space:]]*$ ]]
}

field_value() {  # <file> <key> -> last value recorded for the key, empty if none
  sed -n "s/^$2: //p" "$1" | tail -n 1
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
  local handled_count superseded_count superseded closed deferred
  local closure_no open_no handled_at_no errata_no task_field endpoint_type
  local report_path resolved canonical

  if grep -q $'\r' "$checkpoint"; then
    report "$id" "checkpoint file uses CRLF line endings"
  fi

  task_field=$(field_value "$checkpoint" task)
  if [ -n "$task_field" ] && [ "$task_field" != "$id" ]; then
    report "$id" "checkpoint task: names $task_field, not $id"
  fi

  handled_count=$(count_lines "$checkpoint" '^state: handled[[:space:]]*$')
  superseded_count=$(count_lines "$checkpoint" '^state: superseded[[:space:]]*$')
  superseded=0
  if [ "$superseded_count" -ge 1 ]; then superseded=1; fi
  closed=0
  if [ "$handled_count" -ge 1 ] || [ "$superseded" -eq 1 ]; then closed=1; fi
  deferred=0
  if grep -q '^closure_deferred:[[:space:]]*\S' "$checkpoint"; then deferred=1; fi

  if ! grep -q '^state:' "$checkpoint"; then
    report "$id" "checkpoint has no state line"
  fi
  if [ "$handled_count" -gt 1 ]; then
    report "$id" "state: handled appears $handled_count times"
  fi
  if [ "$superseded_count" -gt 1 ]; then
    report "$id" "state: superseded appears $superseded_count times"
  fi
  if [ "$superseded" -eq 1 ] && ! grep -q '^resolved_by: \S' "$checkpoint"; then
    report "$id" "state: superseded without a resolved_by: value"
  fi
  if [ "$superseded" -eq 1 ] && grep -q '^resolved_by: ' "$checkpoint"; then
    resolved=$(field_value "$checkpoint" resolved_by)
    resolved=${resolved%"${resolved##*[![:space:]]}"}
    case "$resolved" in
      */*|..|.)
        report "$id" "resolved_by: value is not a plain task id: $resolved"
        ;;
      captain-ruling)
        ;;
      *)
        if [ ! -e "$STATE/$resolved.status" ] && [ ! -e "$STATE/$resolved.checkpoint" ]; then
          report "$id" "resolved_by: names $resolved, which has no record in this tree"
        fi
        ;;
    esac
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
  if grep -q '^closure_deferred:' "$checkpoint" && [ "$deferred" -eq 0 ]; then
    report "$id" "closure_deferred: without a reason"
  fi
  # Closure bookkeeping order: the closure line comes first, then its
  # timestamp, then any errata; a state: open line after the closure is a
  # contradiction.
  closure_no=$(first_line_no "$checkpoint" '^state: \(handled\|superseded\)[[:space:]]*$')
  open_no=$(last_line_no "$checkpoint" '^state: open[[:space:]]*$')
  handled_at_no=$(first_line_no "$checkpoint" '^handled_at:')
  errata_no=$(first_line_no "$checkpoint" '^errata:')
  if [ "$closed" -eq 1 ]; then
    if [ "$handled_at_no" -eq 0 ]; then
      report "$id" "closed without a handled_at: timestamp"
    elif [ "$handled_at_no" -lt "$closure_no" ]; then
      report "$id" "handled_at: recorded before the closure line"
    elif ! valid_ts "$(field_value "$checkpoint" handled_at)"; then
      report "$id" "handled_at: is not a timestamp"
    fi
    if [ "$open_no" -gt "$closure_no" ]; then
      report "$id" "state: open recorded after the closure"
    fi
    if [ "$errata_no" -gt 0 ] && [ "$errata_no" -lt "$closure_no" ]; then
      report "$id" "errata: recorded before the closure"
    fi
  else
    if [ "$handled_at_no" -gt 0 ]; then
      report "$id" "handled_at: recorded but the wait has no closure"
    fi
    if [ "$errata_no" -gt 0 ]; then
      report "$id" "errata: recorded on a checkpoint that is not closed"
    fi
  fi

  endpoint_type=$(field_value "$checkpoint" endpoint_type)
  local key
  for key in task endpoint_type endpoint_chat status_file expected registered \
    wake_hook expected_first_check expected_terminal mandate_words report \
    resolved_by handled_at; do
    if [ "$(count_lines "$checkpoint" "^$key:")" -gt 1 ]; then
      report "$id" "$key: appears more than once"
    fi
  done
  if [ -n "$endpoint_type" ] \
    && [ "$endpoint_type" != "crewmate" ] && [ "$endpoint_type" != "subagent" ]; then
    report "$id" "checkpoint has an unrecognized endpoint_type: $endpoint_type"
  fi

  # Open waits carry the live contract: the fields the wake and the silence
  # watchdog read. Closed records are history and are not rechecked for them,
  # except subagent records, whose exception duties bind the record itself.
  if [ "$closed" -eq 0 ]; then
    if [ -z "$endpoint_type" ]; then
      report "$id" "open checkpoint is missing endpoint_type:"
    fi
    if ! valid_ts "$(field_value "$checkpoint" expected_first_check)"; then
      report "$id" "open checkpoint is missing a valid expected_first_check: timestamp"
    fi
    if ! valid_ts "$(field_value "$checkpoint" expected_terminal)"; then
      report "$id" "open checkpoint is missing a valid expected_terminal: timestamp"
    fi
    if ! grep -q '^status_file: \S' "$checkpoint"; then
      report "$id" "open checkpoint is missing status_file:"
    fi
    if ! grep -q '^expected: \S' "$checkpoint"; then
      report "$id" "open checkpoint is missing expected:"
    fi
    if ! grep -q '^registered: \S' "$checkpoint"; then
      report "$id" "open checkpoint is missing registered:"
    fi
    if ! grep -q '^wake_hook: \S' "$checkpoint"; then
      report "$id" "open checkpoint is missing wake_hook:"
    fi
    if [ "$endpoint_type" = "crewmate" ] && ! grep -q '^endpoint_chat: \S' "$checkpoint"; then
      report "$id" "open crewmate checkpoint is missing endpoint_chat:"
    fi
  fi

  if [ "$endpoint_type" = "subagent" ]; then
    if ! grep -q '^mandate_words: \S' "$checkpoint"; then
      report "$id" "subagent checkpoint is missing mandate_words:"
    fi
    report_path=$(field_value "$checkpoint" report)
    if [ -z "$report_path" ]; then
      report "$id" "subagent checkpoint is missing report:"
    else
      resolved=$report_path
      case "$resolved" in
        /*) ;;
        *) resolved="$HOME_ROOT/$resolved" ;;
      esac
      if ! canonical=$(readlink -f "$resolved" 2>/dev/null); then
        report "$id" "subagent report path cannot be canonicalized: $report_path"
      else
        prefix_dir="$HOME_ROOT/data/$id"
        if [ -d "$prefix_dir" ]; then
          prefix_dir=$(readlink -f "$prefix_dir" 2>/dev/null || printf '%s' "$prefix_dir")
        fi
        if [ "$canonical" = "$prefix_dir" ]; then
          report "$id" "subagent report is not a regular file: $report_path"
        else
          case "$canonical" in
            "$prefix_dir/"*)
              if [ ! -f "$canonical" ]; then
                report "$id" "subagent report is not a regular file: $report_path"
              elif [ ! -s "$canonical" ]; then
                report "$id" "subagent report is empty: $report_path"
              fi
              ;;
            *)
              report "$id" "subagent report is outside data/$id/: $report_path"
              ;;
          esac
        fi
      fi
    fi
  fi
}

for status in "$STATE"/*.status; do
  [ -e "$status" ] || continue
  id=$(basename "$status" .status)
  seen[$id]=1
  checked=$((checked + 1))
  if [ ! -f "$status" ]; then
    report "$id" "status path is not a regular file"
    continue
  fi
  if [ ! -r "$status" ]; then
    report "$id" "status file is not readable"
    continue
  fi
  lint_status "$id" "$status"

  checkpoint="$STATE/$id.checkpoint"
  if [ ! -e "$checkpoint" ]; then
    report "$id" "status file has no checkpoint"
    continue
  fi
  if [ ! -f "$checkpoint" ]; then
    report "$id" "checkpoint path is not a regular file"
    continue
  fi
  if [ ! -r "$checkpoint" ]; then
    report "$id" "checkpoint file is not readable"
    continue
  fi
  lint_pair "$id" "$status" "$checkpoint"
done

for checkpoint in "$STATE"/*.checkpoint; do
  [ -e "$checkpoint" ] || continue
  id=$(basename "$checkpoint" .checkpoint)
  if [ -z "${seen[$id]:-}" ] && [ ! -e "$STATE/$id.status" ]; then
    checked=$((checked + 1))
    if [ ! -f "$checkpoint" ]; then
      report "$id" "checkpoint path is not a regular file"
    else
      report "$id" "checkpoint has no status file"
    fi
  fi
done

if [ "$findings" -gt 0 ]; then
  printf 'record-lint: %s finding(s) across %s task record(s)\n' "$findings" "$checked"
  exit 1
fi
printf 'record-lint: clean (%s task record(s) checked)\n' "$checked"
