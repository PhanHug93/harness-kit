#!/usr/bin/env bash
# Migration runner for the one-shot install/reinstall/update command. Sourced
# by the orchestrator; it defines functions only and has no top-level effects.
#
# Environment (read at call time):
#   TARGET_DIR   project being migrated (required)
#   KIT_DIR      kit version whose migrations/ and lib/knowledge.py are used
#   STAMP        run stamp (default: current time)
#   JOURNAL_DIR  run journal; backups go to $JOURNAL_DIR/migrations/<id>/
#                (default: $TARGET_DIR/.tools/agent-state/journal/$STAMP)
#   MIGRATIONS_DIR  override of $KIT_DIR/migrations (tests)
#
# Interface
#   migrations_select FROM TO MODE
#       Prints the ids to consider, one per line, ordered by version then name
#       (`next` after every version). MODE is install, reinstall or update.
#       update:  FROM < SINCE <= TO and migration_needed; TO may be `next`
#                (unreleased kit: then every `next` migration qualifies). FROM
#                may be empty (unknown, treated as older than everything).
#       install/reinstall: only migrations recorded as pending, failed or
#       accepted (but never applied) in knowledge.
#       Those recorded migrations of any version join every mode when still
#       needed, so a failed or interrupted run is retried by the next one.
#       A decision recorded as declined is left out until its facts hash
#       (SHA-256 of the migration_describe text) changes; then it is asked
#       again in every mode.
#       migration_needed exits 0 (needed) or 1 (not needed); any other exit,
#       and metadata that cannot be read, is a failure: it is reported as
#       failed, selection still prints the other needed ids and returns 1.
#   migrations_facts ID
#       Prints the one-line migration_describe text of ID.
#   migrations_run FROM TO MODE ACCEPTED DECLINED
#       Selects as above and runs in order. ACCEPTED and DECLINED are
#       space- or comma-separated id lists from the user's answers.
#         auto      -> applied when needed.
#         decision  -> in ACCEPTED: recorded accepted, applied, recorded
#                      applied; in DECLINED: recorded declined with the facts
#                      hash; otherwise recorded pending (nothing is changed).
#       A failing migration stops the rest, is reported as failed and makes
#       the function return 1. A kind other than auto or decision is refused
#       (failed) without running anything. Knowledge records the failed id as
#       failed and every selected id not reached as pending, so the next run
#       (also a reinstall) selects them again. Outcomes go to knowledge (knowledge.py
#       decision) and to $MIGRATIONS_RESULT_FILE (reset by every run,
#       $JOURNAL_DIR/migrations/results.tsv).
#   migrations_report
#       Prints the result file: one line per id,
#         id<TAB>status<TAB>summary<TAB>facts
#       with status applied | pending | declined | failed (tabs and newlines
#       in summary and facts are flattened to spaces).
#
# Migration file contract: agent-bootstrap/migrations/<MIGRATION_ID>.sh, where
# the file name is the id. Sourced by a child bash (set -eu) that provides
# TARGET_DIR, KIT_DIR, STAMP, JOURNAL_DIR and the helper `migration_backup
# PATH`, which copies PATH (relative to TARGET_DIR, or absolute) into
# $JOURNAL_DIR/migrations/<id>/ before a write, keeping the relative layout
# (paths outside TARGET_DIR go under _outside/). It defines MIGRATION_ID,
# MIGRATION_SINCE (YYYY.MM.DD.N or next), MIGRATION_KIND (auto|decision),
# MIGRATION_SUMMARY and migration_needed (exit 0 when the project needs it),
# migration_describe (one line of facts), migration_apply (idempotent).
# Migrations never commit, push or switch branches.

_mig_dir() { printf '%s\n' "${MIGRATIONS_DIR:-${KIT_DIR:?KIT_DIR is not set}/migrations}"; }

_mig_prepare() {
  : "${TARGET_DIR:?TARGET_DIR is not set}" "${KIT_DIR:?KIT_DIR is not set}"
  STAMP="${STAMP:-$(date +%Y%m%d-%H%M%S)}"
  JOURNAL_DIR="${JOURNAL_DIR:-$TARGET_DIR/.tools/agent-state/journal/$STAMP}"
  mkdir -p "$JOURNAL_DIR/migrations"
  MIGRATIONS_RESULT_FILE="$JOURNAL_DIR/migrations/results.tsv"
}

_mig_know() { python3 -I -B "$KIT_DIR/lib/knowledge.py" --target "$TARGET_DIR" "$@"; }

# Sortable key: YYYYMMDDNNNNNN; `next` sorts after everything; anything that
# is not exactly YYYY.MM.DD.N (e.g. 2099.01.01.1-rc1) is unknown and sorts first.
_MIG_VERSION_RE='^([0-9]{4})\.([0-9]{2})\.([0-9]{2})\.([0-9]{1,6})$'
_mig_key() {
  if [ "$1" = next ]; then
    printf '99999999999999\n'
  elif [[ "$1" =~ $_MIG_VERSION_RE ]]; then
    printf '%04d%02d%02d%06d\n' "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))" \
      "$((10#${BASH_REMATCH[3]}))" "$((10#${BASH_REMATCH[4]}))"
  else
    printf '00000000000000\n'
  fi
}

migration_backup() {
  local path="$1" abs rel dest
  case "$path" in /*) abs="$path" ;; *) abs="$TARGET_DIR/$path" ;; esac
  [ -e "$abs" ] || [ -L "$abs" ] || return 0
  case "$abs" in
    "$TARGET_DIR"/*) rel="${abs#"$TARGET_DIR"/}" ;;
    *) rel="_outside/${abs#/}" ;;
  esac
  dest="$JOURNAL_DIR/migrations/$MIGRATION_ID/$rel"
  [ ! -e "$dest" ] || return 0
  mkdir -p "$(dirname "$dest")" && cp -pR "$abs" "$dest"
}

# _mig_exec FILE OP: runs one operation of a migration file in a child bash.
_mig_exec() {
  local driver
  driver="$(declare -f migration_backup)"
  # shellcheck disable=SC2016  # the driver is bash source for the child shell
  driver="$driver"$'\n''set -eu
file=$1; op=$2
. "$file"
case "$op" in
  meta) printf "%s\t%s\t%s\t%s\n" "$MIGRATION_ID" "$MIGRATION_SINCE" "$MIGRATION_KIND" "$MIGRATION_SUMMARY" ;;
  needed) migration_needed ;;
  describe) migration_describe ;;
  apply) migration_apply ;;
esac'
  TARGET_DIR="$TARGET_DIR" KIT_DIR="$KIT_DIR" STAMP="$STAMP" JOURNAL_DIR="$JOURNAL_DIR" \
    bash -c "$driver" _ "$1" "$2"
}

_mig_flat() { printf '%s' "$1" | tr '\t\r\n' '   '; }

_mig_sha() { printf '%s' "$1" | python3 -I -B -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }

# _mig_prev ID: prints "status<TAB>facts_sha256" from knowledge (empty if none).
_mig_prev() {
  python3 -I -B - "$TARGET_DIR/.tools/agent-state/project-knowledge.json" "$1" <<'PY' 2>/dev/null || true
import json, sys
try:
    entry = json.load(open(sys.argv[1])).get("migrations", {}).get(sys.argv[2])
except (OSError, ValueError):
    entry = None
if isinstance(entry, dict):
    print("%s\t%s" % (entry.get("status", ""), entry.get("facts_sha256", "")))
PY
}

_mig_in_list() {
  case ",$(printf '%s' "$1" | tr ' \t' ',,')," in *",$2,"*) return 0 ;; esac
  return 1
}

# _mig_rows: "key<TAB>file<TAB>id<TAB>since<TAB>kind<TAB>summary" sorted. A
# migration whose metadata cannot be read gets kind `error` (selection fails).
_mig_rows() {
  local dir file id since kind summary meta
  dir="$(_mig_dir)"
  for file in "$dir"/*.sh; do
    [ -f "$file" ] || continue
    if ! meta="$(_mig_exec "$file" meta 2>/dev/null)" || [ -z "$meta" ]; then
      printf '00000000000000\t%s\t%s\t?\terror\tunreadable migration\n' "$file" "$(basename "$file" .sh)"
      continue
    fi
    IFS=$'\t' read -r id since kind summary <<<"$meta"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(_mig_key "$since")" "$file" "$id" "$since" "$kind" "$summary"
  done | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2
}

migrations_facts() {
  _mig_prepare
  local facts
  facts="$(_mig_exec "$(_mig_dir)/$1.sh" describe)" || return 1
  _mig_flat "$facts"
  printf '\n'
}

migrations_select() {
  local from="${1:-}" to="${2:-next}" mode="${3:-update}"
  local fromkey tokey key file id since kind summary prev pstatus psha facts in_range rc status=0
  _mig_prepare
  fromkey="$(_mig_key "$from")"
  tokey="$(_mig_key "$to")"
  while IFS=$'\t' read -r key file id since kind summary; do
    [ -n "$id" ] || continue
    if [ "$kind" = error ]; then
      printf 'migrations: cannot read the metadata of %s\n' "$file" >&2
      _mig_result "$id" failed "$summary" "migration metadata could not be read"
      status=1
      continue
    fi
    prev="$(_mig_prev "$id")"
    pstatus="${prev%%$'\t'*}"
    psha="${prev#*$'\t'}"
    in_range=false
    if [ "$mode" = update ] && [[ "$key" > "$fromkey" ]] && ! [[ "$key" > "$tokey" ]]; then
      in_range=true
    fi
    case "$pstatus" in
      pending | declined | failed | accepted) ;;
      *) [ "$in_range" = true ] || continue ;;
    esac
    rc=0
    _mig_exec "$file" needed >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 1 ]; then
      continue
    elif [ "$rc" -ne 0 ]; then
      printf 'migrations: migration_needed of %s failed (exit %s)\n' "$id" "$rc" >&2
      _mig_result "$id" failed "$summary" "migration_needed failed (exit $rc)"
      status=1
      continue
    fi
    if [ "$pstatus" = declined ] && [ "$kind" = decision ]; then
      facts="$(_mig_flat "$(_mig_exec "$file" describe 2>/dev/null)")"
      [ "$(_mig_sha "$facts")" != "$psha" ] || continue
    fi
    printf '%s\n' "$id"
  done < <(_mig_rows)
  return "$status"
}

_mig_result() { # id status summary facts
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(_mig_flat "$3")" "$(_mig_flat "$4")" >>"$MIGRATIONS_RESULT_FILE"
}

_mig_record() { # id status sha
  _mig_know decision "$1" --status "$2" --facts-sha256 "$3" || {
    printf 'migrations: could not record %s as %s in project knowledge\n' "$1" "$2" >&2
    return 1
  }
}

# _mig_stop ID SHA REST...: records ID as failed and every id not reached as
# pending in knowledge (best effort), so the next run selects them again.
_mig_stop() {
  local failed_id="$1" sha="$2" rest
  shift 2
  [ -z "$failed_id" ] || _mig_record "$failed_id" failed "$sha" || true
  for rest in "$@"; do
    _mig_record "$rest" pending "" || true
  done
  return 1
}

migrations_run() {
  local from="${1:-}" to="${2:-next}" mode="${3:-update}" accepted="${4:-}" declined="${5:-}"
  local id file kind summary facts sha rc ids fid fstatus
  local -a todo
  _mig_prepare
  : >"$MIGRATIONS_RESULT_FILE"
  rc=0
  ids="$(migrations_select "$from" "$to" "$mode")" || rc=$?
  # shellcheck disable=SC2206 # ids are migration file names, one per line
  todo=($ids)
  if [ "$rc" -ne 0 ]; then
    while IFS=$'\t' read -r fid fstatus _; do
      [ "$fstatus" != failed ] || _mig_record "$fid" failed "" || true
    done <"$MIGRATIONS_RESULT_FILE"
    _mig_stop "" "" ${todo[@]+"${todo[@]}"}
    return 1
  fi
  while [ "${#todo[@]}" -gt 0 ]; do
    id="${todo[0]}"
    todo=(${todo[@]+"${todo[@]:1}"})
    file="$(_mig_dir)/$id.sh"
    IFS=$'\t' read -r _ kind summary <<<"$(_mig_exec "$file" meta | cut -f1,3,4)"
    case "$kind" in
      auto | decision) ;;
      *)
        _mig_result "$id" failed "$summary" "unknown migration kind: ${kind:-none}"
        _mig_stop "$id" "" ${todo[@]+"${todo[@]}"}
        return 1
        ;;
    esac
    facts="$(_mig_flat "$(_mig_exec "$file" describe)")" || {
      _mig_result "$id" failed "$summary" "migration_describe failed"
      _mig_stop "$id" "" ${todo[@]+"${todo[@]}"}
      return 1
    }
    sha="$(_mig_sha "$facts")"
    if [ "$kind" = decision ]; then
      if _mig_in_list "$accepted" "$id"; then
        _mig_record "$id" accepted "$sha" || {
          _mig_result "$id" failed "$summary" "$facts"
          _mig_stop "$id" "$sha" ${todo[@]+"${todo[@]}"}
          return 1
        }
      elif _mig_in_list "$declined" "$id"; then
        _mig_record "$id" declined "$sha" || return 1
        _mig_result "$id" declined "$summary" "$facts"
        continue
      else
        _mig_record "$id" pending "$sha" || return 1
        _mig_result "$id" pending "$summary" "$facts"
        continue
      fi
    fi
    rc=0
    _mig_exec "$file" apply >&2 || rc=$?
    if [ "$rc" -ne 0 ]; then
      _mig_result "$id" failed "$summary [exit $rc]" "$facts"
      _mig_stop "$id" "$sha" ${todo[@]+"${todo[@]}"}
      return 1
    fi
    _mig_record "$id" applied "$sha" || {
      _mig_result "$id" failed "$summary" "$facts"
      _mig_stop "$id" "$sha" ${todo[@]+"${todo[@]}"}
      return 1
    }
    _mig_result "$id" applied "$summary" "$facts"
  done
  return 0
}

migrations_report() {
  [ -f "${MIGRATIONS_RESULT_FILE:-}" ] && cat "$MIGRATIONS_RESULT_FILE"
  return 0
}
