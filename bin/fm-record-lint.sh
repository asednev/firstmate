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

# Status-line structure, checked in one awk pass per file. An in-flight file
# with no terminal line yet is clean; anything after a terminal line is not.
lint_status() {  # <task-id> <status-file>
  local id=$1 file=$2 problem
  while IFS= read -r problem; do
    report "$id" "$problem"
  done < <(awk '
    BEGIN { started = 0; terminal = 0; first = 1 }
    {
      if (first) {
        if ($0 !~ /^started:/) print "first status line is not started:"
        first = 0
      }
      if ($0 ~ /^started:/) {
        started++
        if (started > 1) print "started: appears more than once"
      } else if ($0 ~ /^check:/ || $0 ~ /^correction:/) {
        # in-order progress lines; nothing to check
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

for status in "$STATE"/*.status; do
  [ -e "$status" ] || continue
  id=$(basename "$status" .status)
  checked=$((checked + 1))
  lint_status "$id" "$status"

  checkpoint="$STATE/$id.checkpoint"
  if [ ! -f "$checkpoint" ]; then
    report "$id" "status file has no checkpoint"
    continue
  fi

  if ! grep -q '^state:' "$checkpoint"; then
    report "$id" "checkpoint has no state line"
  fi

  handled_count=$(grep -c '^state: handled' "$checkpoint" || true)
  if [ "$handled_count" -gt 1 ]; then
    report "$id" "state: handled appears $handled_count times"
  fi

  superseded=0
  if grep -q '^state: superseded' "$checkpoint"; then
    superseded=1
    if ! grep -q '^resolved_by:' "$checkpoint"; then
      report "$id" "state: superseded without resolved_by:"
    fi
  fi

  if [ "$handled_count" -ge 1 ] && ! grep -q '^done:' "$status"; then
    report "$id" "marked handled but the status terminal line is not done:"
  fi

  if grep -q '^done:' "$status" && [ "$handled_count" -eq 0 ] && [ "$superseded" -eq 0 ]; then
    report "$id" "status reached done: but the wait was never closed"
  fi
done

for checkpoint in "$STATE"/*.checkpoint; do
  [ -e "$checkpoint" ] || continue
  id=$(basename "$checkpoint" .checkpoint)
  if [ ! -f "$STATE/$id.status" ]; then
    report "$id" "checkpoint has no status file"
  fi
done

if [ "$findings" -gt 0 ]; then
  printf 'record-lint: %s finding(s) across %s task record(s)\n' "$findings" "$checked"
  exit 1
fi
printf 'record-lint: clean (%s task record(s) checked)\n' "$checked"
