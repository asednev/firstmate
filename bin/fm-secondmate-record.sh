#!/usr/bin/env bash
# fm-secondmate-record.sh - write or rebind the endpoint record of a muse-app
# secondmate (docs/muse-app-backend.md, "The endpoint record").
#
# On terminal backends bin/fm-spawn.sh writes state/<id>.meta at launch; on
# the muse-app backend nothing is launched, so the record is written at
# provisioning instead, by this tool, run by the main firstmate when it folds
# the mate's doorbell-confirmation line and before any request is routed.
#
# Usage:
#   fm-secondmate-record.sh create <id> <mate-home> <chat-id>
#       Write state/<id>.meta in this home with exactly the endpoint-record
#       field set (kind=secondmate, backend=muse-app, muse_app_chat_id=,
#       endpoint_task_id=, worktree=/project=/home= naming the mate home,
#       projects= from the registry line, mode=secondmate, yolo=off,
#       harness=muse, spawn_gen= in fm-spawn.sh's s<epoch>.<pid>.<random>
#       format; no window/terminal/atom/remote_host field), each key exactly
#       once. Refuses to overwrite an existing record. The registry line in
#       data/secondmates.md is read at write time and a mate home that
#       disagrees with it under the registry's canonical path key
#       (secondmate_registry_path_key, bin/fm-secondmate-registry-lib.sh) is
#       refused, because the live sweep silently prefers the record's home
#       and no other comparison fires until a later act.
#   fm-secondmate-record.sh update <id> <mate-home> <expected-old-chat-id> <new-chat-id>
#       The writer's only update mode, for a relaunch that replaces the bound
#       chat: a preserving read-modify-write that rewrites muse_app_chat_id=
#       and rotates spawn_gen= (a new chat is a new incarnation) while every
#       other line of the record - including fields later canonical writers
#       appended - survives byte-for-byte. Refuses when the record's current
#       chat id is not <expected-old-chat-id>, the binding being replaced as
#       read from the record in a prior step of the same act; the bounded
#       recovery (re-read against the mate's latest parent-channel
#       confirmation, retry, stop on a third binding) is the caller's act,
#       never this tool's. An update that finds <new-chat-id> already
#       recorded is already applied, not an error, and writes nothing. The
#       registry/home agreement check repeats here.
#
# Both modes publish the way canonical publication does: the record is
# staged beside its target and published under the record's meta lock
# (fm_meta_lock_path) through the canonical atomic-transition publish
# (fm_backlog_atomic_transition publish, the same call fm-spawn.sh makes),
# never by an in-place edit another reader can observe half-written.
set -eu

# Print the header comment as usage before any home resolution, so the
# contract this header owns is reachable through --help.
case "${1:-}" in
  --help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/secondmates.md"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

die() {  # <message>
  echo "error: $1" >&2
  exit 1
}

usage() {
  echo "usage: fm-secondmate-record.sh create <id> <mate-home> <chat-id>" >&2
  echo "       fm-secondmate-record.sh update <id> <mate-home> <expected-old-chat-id> <new-chat-id>" >&2
  exit 2
}

# A value written into the record must stay one line of one key=value pair:
# no whitespace, no control bytes, and no '=' that would blur the key.
record_value_valid() {  # <value>
  case "$1" in
    ''|*[[:space:]]*|*'='*) return 1 ;;
  esac
  return 0
}

# Read one field's value from the record, requiring the key to appear
# exactly once; prints the value, or returns 1.
record_field_exact() {  # <meta> <key>
  local meta=$1 key=$2 count value
  count=$(LC_ALL=C grep -c "^$key=" "$meta" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  value=$(LC_ALL=C grep "^$key=" "$meta" | cut -d= -f2-)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

MODE=${1:-}
case "$MODE" in
  create)
    [ $# -eq 4 ] || usage
    ID=$2; MATE_HOME_ARG=$3; CHAT_ID=$4; EXPECTED_OLD=; NEW_CHAT_ID=
    ;;
  update)
    [ $# -eq 5 ] || usage
    ID=$2; MATE_HOME_ARG=$3; EXPECTED_OLD=$4; NEW_CHAT_ID=$5; CHAT_ID=$NEW_CHAT_ID
    ;;
  *) usage ;;
esac

case "$ID" in
  ''|.|..|*[!A-Za-z0-9._-]*)
    die "invalid secondmate id '$ID' (allowed: A-Z a-z 0-9 . _ -)"
    ;;
esac
record_value_valid "$CHAT_ID" \
  || die "chat id must be a single non-empty token with no whitespace or '='"
if [ "$MODE" = update ]; then
  record_value_valid "$EXPECTED_OLD" \
    || die "expected-old chat id must be a single non-empty token with no whitespace or '='"
fi
case "$MATE_HOME_ARG" in
  /*) ;;
  *) die "mate home must be an absolute path: $MATE_HOME_ARG" ;;
esac
[ -d "$MATE_HOME_ARG" ] || die "mate home is not an existing directory: $MATE_HOME_ARG"
[ -d "$STATE" ] || die "state dir '$STATE' is missing; fm-secondmate-record cannot write the record for FM_HOME '$FM_HOME'"

# The registry is the routing authority and this writer is the comparison
# that keeps the record agreeing with it on the routing path: read the
# registry line at write time, refuse a home that disagrees under the
# registry's canonical path key, and take projects= from that line.
secondmate_registry_validate_bindings "$REG" secondmate_registry_path_key "$ID" "$MATE_HOME_ARG" \
  || die "registry/home disagreement for secondmate $ID: $SECONDMATE_REGISTRY_ERROR"
[ "$SECONDMATE_REGISTRY_MATCH_REMOTE" = 0 ] \
  || die "secondmate $ID is registered as a remote mate; a muse-app endpoint record names a local mate home"
REGISTRY_PROJECTS=$SECONDMATE_REGISTRY_MATCH_PROJECTS
case "$REGISTRY_PROJECTS" in
  *$'\n'*|*$'\r'*|*$'\t'*)
    die "registry project list for secondmate $ID is not one line and cannot be recorded: '$REGISTRY_PROJECTS'"
    ;;
esac
MATE_HOME=$(secondmate_registry_path_key "$MATE_HOME_ARG") \
  || die "mate home cannot be resolved to a canonical path: $MATE_HOME_ARG"

META="$STATE/$ID.meta"
META_LOCK=$(fm_meta_lock_path "$META") || die "could not resolve the record lock for $ID"
fm_lock_acquire_wait "$META_LOCK" || die "could not lock the record for $ID"
trap 'fm_lock_release "$META_LOCK" || true' EXIT

SPAWN_GEN="s$(date +%s).${BASHPID:-$$}.$RANDOM"

if [ "$MODE" = create ]; then
  if [ -e "$META" ] || [ -L "$META" ]; then
    die "endpoint record already exists at $META; refusing to overwrite it (use update to rebind its chat)"
  fi
  STAGED="$STATE/.$ID.meta.record.${BASHPID:-$$}"
  {
    printf 'kind=secondmate\n'
    printf 'backend=muse-app\n'
    printf 'muse_app_chat_id=%s\n' "$CHAT_ID"
    printf 'endpoint_task_id=%s\n' "$ID"
    printf 'worktree=%s\n' "$MATE_HOME"
    printf 'project=%s\n' "$MATE_HOME"
    printf 'home=%s\n' "$MATE_HOME"
    printf 'projects=%s\n' "$REGISTRY_PROJECTS"
    printf 'mode=secondmate\n'
    printf 'yolo=off\n'
    printf 'harness=muse\n'
    printf 'spawn_gen=%s\n' "$SPAWN_GEN"
  } > "$STAGED" || die "could not stage the endpoint record for $ID"
  if ! fm_backlog_atomic_transition publish "$STAGED" "$META" "task record" "$STATE"; then
    rm -f -- "$STAGED"
    die "endpoint record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)"
  fi
  printf 'created endpoint record for secondmate %s at %s (chat %s, spawn_gen %s)\n' \
    "$ID" "$META" "$CHAT_ID" "$SPAWN_GEN"
  exit 0
fi

# update: the record must exist and carry exactly one chat id line; the
# binding questions come before any shape question, in the spec's order -
# an update that finds the intended chat already recorded is already
# applied, not an error, whatever else the record carries, and a current
# binding that is not the expected old one refuses. Only a caller whose
# binding checks pass reaches the shape probes guarding the write itself.
[ -f "$META" ] && [ ! -L "$META" ] \
  || die "no endpoint record at $META; nothing to rebind (create it first)"
CURRENT_CHAT=$(record_field_exact "$META" muse_app_chat_id) \
  || die "endpoint record at $META does not carry exactly one muse_app_chat_id=; refusing to rebind a record this writer did not shape"
if [ "$CURRENT_CHAT" = "$NEW_CHAT_ID" ]; then
  printf 'endpoint record for secondmate %s already names chat %s; already applied, nothing written\n' \
    "$ID" "$NEW_CHAT_ID"
  exit 0
fi
[ "$CURRENT_CHAT" = "$EXPECTED_OLD" ] \
  || die "endpoint record for $ID names chat '$CURRENT_CHAT', not the expected old binding '$EXPECTED_OLD'; refusing the rebind - re-read the record against the mate's latest parent-channel confirmation and retry against the fresh value"
[ "$(record_field_exact "$META" backend || true)" = muse-app ] \
  && [ "$(record_field_exact "$META" kind || true)" = secondmate ] \
  || die "endpoint record at $META is not a muse-app secondmate record; refusing to rebind it"

STAGED="$STATE/.$ID.meta.record.${BASHPID:-$$}"
awk -v chat="$NEW_CHAT_ID" -v gen="$SPAWN_GEN" '
  /^muse_app_chat_id=/ { print "muse_app_chat_id=" chat; next }
  /^spawn_gen=/ { print "spawn_gen=" gen; next }
  { print }
' "$META" > "$STAGED" || die "could not stage the rebound endpoint record for $ID"
# Prove the staged copy is the record with exactly its two fields rewritten:
# both target keys still exactly once, and every other line byte-for-byte.
[ "$(record_field_exact "$STAGED" muse_app_chat_id || true)" = "$NEW_CHAT_ID" ] \
  || { rm -f -- "$STAGED"; die "staged record for $ID lost its muse_app_chat_id=; nothing was published"; }
[ "$(record_field_exact "$STAGED" spawn_gen || true)" = "$SPAWN_GEN" ] \
  || { rm -f -- "$STAGED"; die "staged record for $ID lost its spawn_gen=; nothing was published"; }
if ! fm_backlog_atomic_transition publish "$STAGED" "$META" "task record" "$STATE"; then
  rm -f -- "$STAGED"
  die "endpoint record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)"
fi
printf 'rebound endpoint record for secondmate %s at %s (chat %s -> %s, spawn_gen %s)\n' \
  "$ID" "$META" "$EXPECTED_OLD" "$NEW_CHAT_ID" "$SPAWN_GEN"
