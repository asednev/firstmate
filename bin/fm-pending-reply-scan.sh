#!/usr/bin/env bash
# fm-pending-reply-scan.sh - run one pending-reply reconciliation tick
# over a home's state tree: resolve correlated parent reports, observe
# turn completion, send the one recovery repost after grace, and
# escalate once if the recovery turn is also missed
# (bin/fm-pending-reply-lib.sh, fm_pending_reply_tick).
#
# On watcher backends bin/fm-watch.sh runs the tick inside its poll
# loop. The muse-app backend has no watcher, so this entry point is
# what its runners call instead: the runtime hook that polls the
# home's state/pending-replies/ directory, and the First Mate's
# checkpoint scan (docs/muse-app-backend.md, "Correlation and the
# parent channel"; docs/muse-app-runbook.md). One pass is safe to run
# at any cadence: settled records are pre-selected out in a single
# read, and every per-record step is idempotent.
#
# Usage:
#   fm-pending-reply-scan.sh [state-dir]
#
# The state dir defaults to $FM_HOME/state (FM_STATE_OVERRIDE wins when
# set). Exit 0 after a completed pass, 2 on usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${1:-${FM_STATE_OVERRIDE:-$FM_HOME/state}}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,22{s/^# \{0,1\}//;p;}' "$0"
  exit 0
fi

if [ ! -d "$STATE" ]; then
  printf 'pending-reply-scan: state dir not found: %s\n' "$STATE" >&2
  exit 2
fi

# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

# Called exactly as bin/fm-watch.sh calls it: the tick's per-record
# steps are individually guarded and its aggregate status carries no
# meaning, so a nonzero return must not abort the runner under set -e.
fm_pending_reply_tick "$STATE" || true
