#!/usr/bin/env bash
# codex doctor plug — read-only app-server / bridge-binding diagnosis.
#
# Sourced by doctor.sh (never executed directly). Defines the structured
# collector entry points doctor.sh calls when this file exists:
#   agmsg_doctor_extra_collect <type> <project>   per-(project, codex) records
#   agmsg_doctor_extra_global_collect <type>      installation-wide leftovers
#
# The collectors register findings / component signals / display lines
# directly through doctor.sh's collector API (Issue #8) -- the human WARN
# lines and the --json findings are both rendered from that one store, so
# the two outputs share a single judgment. Nothing here prints a "WARN: "
# line for doctor.sh to parse back; the legacy agmsg_doctor_extra_status /
# agmsg_doctor_extra_global entry points remain as thin wrappers that run
# the same collectors into a scratch store and render the old text protocol
# for any external caller still on it.
#
# Read-only by contract (Issue #5 Phase 1): this file never kills a process
# and never creates, removes, or rewrites any record. A dead pid, a foreign
# listener, or a drifted version is REPORTED, not cleaned up — the evidence
# stays for the human, the same reason doctor.sh itself never cleans (#605).
#
# Each signal is evaluated independently: a dead pid is stale-pid evidence, a
# silent port is endpoint evidence, a version gap is drift evidence. No single
# signal proves ownership — a port that answers does not prove the recorded
# server owns it, a version gap alone does not mark a kill target, and several
# live servers across different projects are normal, not duplicates.

[ -n "${_AGMSG_CODEX_DOCTOR_SH:-}" ] && return 0
_AGMSG_CODEX_DOCTOR_SH=1

: "${SKILL_DIR:?codex _doctor.sh requires SKILL_DIR}"
: "${RUN_DIR:?codex _doctor.sh requires RUN_DIR}"
: "${SCRIPT_DIR:?codex _doctor.sh requires SCRIPT_DIR}"

# agmsg_sha1 (lib/hash.sh), the role-session readers, and the runtime-lock
# readers are the helpers doctor.sh does not already load — liveness, cmdline,
# canonical paths, and the project registry all arrive via doctor.sh's own
# sources. Pure function definitions, so sourcing here is free of side
# effects.
if ! command -v agmsg_sha1 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/hash.sh"
fi
if ! command -v agmsg_role_session_load >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/role-session.sh"
fi
if ! command -v agmsg_runtime_lock_owner >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/storage.sh"
fi

# Scope context for one collector run, set by the entry points below. The
# shared evaluators read these instead of taking scope arguments, so the
# per-pair and global paths cannot diverge in what they record.
_CODEX_DOCTOR_SCOPE_PROJECT=""
_CODEX_DOCTOR_SCOPE_TYPE=""
_CODEX_DOCTOR_DISPLAY_MODE="pair"

# One structured warning. $1 is the stable finding code (kind is always
# condition here; category runtime); $2/$3/$4 are the component target
# (team/agent empty for the scope-singleton app-server). $6 (optional) is
# an opaque global instance ID (P1-6, e.g. global_instance1) for orphan /
# unattributed records; empty means registration instance or null.
# Evidence wording is unchanged from the legacy WARN text -- human output
# stays byte-identical except global raw keys/hashes are opaqueized (P1-5).
_codex_doctor_warn() {
  agmsg_doctor_finding_add "$1" condition runtime \
    "$_CODEX_DOCTOR_SCOPE_PROJECT" "$_CODEX_DOCTOR_SCOPE_TYPE" \
    component "$2" "$3" "$4" "$5" "${6:-}"
}

# One component observation signal. $6 (optional) is the opaque global
# instance ID (P1-6); empty means registration instance or null.
_codex_doctor_signal() {
  agmsg_doctor_component_signal \
    "$_CODEX_DOCTOR_SCOPE_PROJECT" "$_CODEX_DOCTOR_SCOPE_TYPE" \
    "$1" "$2" "$3" "$4" "$5" "${6:-}"
}

# Global opaque instance mapping (P1-5/P1-6): raw orphan hash / bridge key
# を paste-safe opaque (global_instanceN) へ変換する。同一 invocation で
# same raw → same pseudonym を保証し、filename 由来文字列を team.agent と
# 仮定しない。doctor.sh の単一 mapping table (_doctor_global_pseudonym)
# を優先し、standalone legacy 呼び出し時のみ plug-local fallback を使う。
_CODEX_OPAQUE_K=""; _CODEX_OPAQUE_V=""
_codex_doctor_opaque_for() {
  local raw="${1:-}"
  [ -n "$raw" ] || { _CODEX_OPAQUE_OUT=""; return 0; }
  if command -v _doctor_global_pseudonym >/dev/null 2>&1; then
    _doctor_global_pseudonym "$raw"
    _CODEX_OPAQUE_OUT="$_GLOBAL_OUT"
    return 0
  fi
  # Fallback for standalone use (no doctor.sh tables in scope).
  local tab key val
  tab="$(printf '\t')"
  # Linear scan over newline-separated tables (portable, no assoc arrays).
  local i=1 k v
  while true; do
    k="$(printf '%s\n' "$_CODEX_OPAQUE_K" | sed -n "${i}p")"
    [ -n "$k" ] || break
    if [ "$k" = "$raw" ]; then
      v="$(printf '%s\n' "$_CODEX_OPAQUE_V" | sed -n "${i}p")"
      _CODEX_OPAQUE_OUT="$v"
      return 0
    fi
    i=$((i + 1))
  done
  local n
  n="$(printf '%s\n' "$_CODEX_OPAQUE_K" | grep -c . || true)"
  _CODEX_OPAQUE_K="${_CODEX_OPAQUE_K}${raw}"$'\n'
  _CODEX_OPAQUE_V="${_CODEX_OPAQUE_V}global_instance$((n + 1))"$'\n'
  _CODEX_OPAQUE_OUT="global_instance$((n + 1))"
}

# One human display line for the pair's block (pair mode) or the
# installation-wide block (global mode).
_codex_doctor_display() {
  if [ "$_CODEX_DOCTOR_DISPLAY_MODE" = "global" ]; then
    agmsg_doctor_global_display_add "$_CODEX_DOCTOR_SCOPE_TYPE" "$1"
  else
    agmsg_doctor_display_add "$_CODEX_DOCTOR_SCOPE_PROJECT" "$_CODEX_DOCTOR_SCOPE_TYPE" "$1"
  fi
}

# Best-effort memo for the current `codex --version` answer. NOTE on scope:
# doctor.sh calls the collectors below directly in its own shell, but the
# version probe assignments here only dedupe probes WITHIN one entry-point
# call (e.g. several unattributed hashes in one global scan) — each per-pair
# call probes once. That is accepted as is: one `codex --version` per codex
# pair is cheap, and hoisting the probe into the parent is deliberately not
# done (no optimization).
_AGMSG_CODEX_DOCTOR_VERSION_PROBED=""
_AGMSG_CODEX_DOCTOR_VERSION=""
_CODEX_DOCTOR_KNOWN_HASHES=""

# First line of a record file with surrounding whitespace trimmed. Empty when
# the file is missing or unreadable. Only the edges are trimmed — inner
# spaces are significant (`codex --version` prints "codex-cli 0.153.4", and
# the version comparison must see exactly what the monitor wrote). Never
# fails (this file is sourced under `set -e`, so every fallible read carries
# its own guard).
_codex_doctor_read_record() {
  local path="$1" line=""
  [ -f "$path" ] || return 0
  IFS= read -r line < "$path" 2>/dev/null || true
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  printf '%s' "$line"
  return 0
}

# Port validation, mirroring the writer-side rules in _app-server.sh: digits
# only (a numeric PREFIX of a real port is itself a valid port, so the reader
# cannot detect a partial write — but anything outside this shape is
# definitely not a port the monitor wrote).
_codex_doctor_valid_port() {
  case "$1" in
    ''|*[!0-9]*|0*) return 1 ;;
  esac
  [ "${#1}" -le 5 ] || return 1
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || return 1
  return 0
}

# Loopback TCP probe, the same shape codex-monitor.sh reuses a live server
# with. Answers "something accepts", never "it is ours" — attribution always
# needs pid + cmdline alongside.
_codex_doctor_port_alive() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# Current `codex --version` output, resolved once per entry-point call (see
# the memo note above) through the same override the monitor honors. Empty
# when unreadable — every version verdict below treats that as "cannot
# tell", never as a mismatch.
_codex_doctor_current_version() {
  [ -n "$_AGMSG_CODEX_DOCTOR_VERSION_PROBED" ] && return 0
  _AGMSG_CODEX_DOCTOR_VERSION_PROBED=1
  _AGMSG_CODEX_DOCTOR_VERSION="$("${AGMSG_REAL_CODEX:-codex}" --version 2>/dev/null || true)"
  _AGMSG_CODEX_DOCTOR_VERSION="${_AGMSG_CODEX_DOCTOR_VERSION%%$'\n'*}"
  return 0
}

# Hashes of every registered codex project (raw spelling plus canonical
# spelling — the monitor hashes the physical path while a registration may
# hold a symlinked one). Lets the global scan tell "belongs to a known
# project" apart from "no registered project matches" without guessing.
_codex_doctor_known_hashes() {
  local proj canon
  while IFS= read -r proj; do
    [ -n "$proj" ] || continue
    _CODEX_DOCTOR_KNOWN_HASHES="${_CODEX_DOCTOR_KNOWN_HASHES}$(printf '%s' "$proj" | agmsg_sha1 2>/dev/null)"$'\n'
    canon="$(agmsg_canonical_path "$proj" 2>/dev/null || printf '%s' "$proj")"
    [ "$canon" = "$proj" ] || \
      _CODEX_DOCTOR_KNOWN_HASHES="${_CODEX_DOCTOR_KNOWN_HASHES}$(printf '%s' "$canon" | agmsg_sha1 2>/dev/null)"$'\n'
  done <<< "$(agmsg_registered_projects codex 2>/dev/null | sort -u || true)"
  return 0
}

_codex_doctor_hash_known() {
  case $'\n'"$_CODEX_DOCTOR_KNOWN_HASHES"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

# Is $1 a `codex app-server` command line? `app-server` must be the
# subcommand — the token immediately after the codex binary — not a
# substring anywhere in the arguments: a live `codex exec "investigate
# app-server"` would otherwise read as an app-server (quotes never reach
# ps output, so the inner words are indistinguishable from real tokens).
_codex_doctor_is_appserver_args() {
  local bin="${1%%[[:space:]]*}" rest
  case "$bin" in
    *codex*) ;;
    *) return 1 ;;
  esac
  rest="${1#"$bin"}"
  rest="${rest#"${rest%%[![:space:]]*}"}"
  case "$rest" in
    "app-server"|"app-server"[[:space:]]*) return 0 ;;
  esac
  return 1
}

# Evaluate one app-server record triple by project hash. $2 is 1 when the hash
# is attributed to a known project (per-pair call: relaunch advice applies)
# and 0 when it is not (global call: unknown/ambiguous framing, no advice
# that names a project). $3 (optional) is the opaque global instance ID
# (P1-6) for the unattributed case; empty for the per-pair scope singleton.
# Registers display lines and structured findings through the collector
# helpers above. Sets _CODEX_DOCTOR_EVAL_PID_STATE to the pid verdict
# (empty when no record triple exists at all) so the caller can correlate
# two records that resolve to the same project.
_codex_doctor_eval_appserver() {
  local hash="$1" attributed="$2" opaque="${3:-}"
  _CODEX_DOCTOR_EVAL_PID_STATE=""
  # Global orphan without an explicit opaque: derive one from the hash so
  # multiple orphans never collide into a single null-instance component
  # (P1-6) and raw hashes never reach evidence (P1-5).
  if [ "$attributed" -eq 0 ] && [ -z "$opaque" ]; then
    _codex_doctor_opaque_for "$hash"
    opaque="$_CODEX_OPAQUE_OUT"
  fi
  local pidf="$RUN_DIR/codex-app-server.$hash.pid"
  local portf="$RUN_DIR/codex-app-server.$hash.port"
  local verf="$RUN_DIR/codex-app-server.$hash.version"
  local have_pidf=0 have_portf=0 have_verf=0
  if [ -f "$pidf" ]; then have_pidf=1; fi
  if [ -f "$portf" ]; then have_portf=1; fi
  if [ -f "$verf" ]; then have_verf=1; fi

  if [ "$have_pidf" -eq 0 ] && [ "$have_portf" -eq 0 ] && [ "$have_verf" -eq 0 ]; then
    if [ "$attributed" -eq 1 ]; then
      _codex_doctor_display "Codex app-server: no record for this project (never launched, or cleaned)"
    fi
    return 0
  fi

  local pid_raw port_raw ver_raw
  pid_raw="$(_codex_doctor_read_record "$pidf")"
  port_raw="$(_codex_doctor_read_record "$portf")"
  ver_raw="$(_codex_doctor_read_record "$verf")"

  # --- pid signal. _local, deliberately: the pidfile holds $! from a monitor
  # shell, which lives in the MSYS pid space under Git Bash — asking the
  # native table about it answers "dead" for a running server (#567).
  local pid_state cmdline=""
  if [ "$have_pidf" -eq 0 ]; then
    pid_state="none"
  elif [ -z "$pid_raw" ] || ! _agmsg_pid_valid "$pid_raw"; then
    pid_state="invalid"
  elif ! _agmsg_pid_alive_local "$pid_raw"; then
    pid_state="dead"
  else
    cmdline="$(compat_get_cmdline "$pid_raw" 2>/dev/null || true)"
    if _codex_doctor_is_appserver_args "$cmdline"; then
      pid_state="alive-confirmed"
    elif [ -z "$cmdline" ]; then
      pid_state="alive-unverified"
    else
      pid_state="alive-foreign"
    fi
  fi
  _CODEX_DOCTOR_EVAL_PID_STATE="$pid_state"

  # --- endpoint signal. Responsive proves a listener, never ownership.
  local ep_state="none" url=""
  if [ "$have_portf" -eq 0 ]; then
    ep_state="none"
  elif ! _codex_doctor_valid_port "$port_raw"; then
    ep_state="invalid"
  else
    url="ws://127.0.0.1:$port_raw"
    if _codex_doctor_port_alive "$port_raw"; then
      ep_state="responsive"
    else
      ep_state="silent"
    fi
  fi

  # --- version signal. Drift is evidence, never a kill verdict on its own.
  _codex_doctor_current_version
  local cur="$_AGMSG_CODEX_DOCTOR_VERSION" ver_state
  if [ "$have_verf" -eq 0 ] || [ -z "$ver_raw" ]; then
    ver_state="unknown-record"
  elif [ -z "$cur" ]; then
    ver_state="unknown-current"
  elif [ "$ver_raw" = "$cur" ]; then
    ver_state="match"
  else
    ver_state="drift"
  fi

  # --- display: one line per signal, each stating its own evidence.
  case "$pid_state" in
    none) _codex_doctor_display "Codex app-server: no pid record" ;;
    invalid) _codex_doctor_display "Codex app-server: pid record invalid ('$pid_raw')" ;;
    dead) _codex_doctor_display "Codex app-server: pid $pid_raw not running" ;;
    alive-confirmed) _codex_doctor_display "Codex app-server: pid $pid_raw alive (Codex app-server cmdline confirmed)" ;;
    alive-unverified) _codex_doctor_display "Codex app-server: pid $pid_raw alive (cmdline unreadable — ownership unverified)" ;;
    alive-foreign) _codex_doctor_display "Codex app-server: pid $pid_raw alive but is not a Codex app-server (possible pid reuse)" ;;
  esac
  case "$ep_state" in
    none) _codex_doctor_display "Codex app-server endpoint: no port record" ;;
    invalid) _codex_doctor_display "Codex app-server endpoint: port record invalid ('$port_raw')" ;;
    silent) _codex_doctor_display "Codex app-server endpoint: ${url} unresponsive" ;;
    responsive) _codex_doctor_display "Codex app-server endpoint: ${url} answers (listener present — not proof of ownership)" ;;
  esac
  case "$ver_state" in
    unknown-record) _codex_doctor_display "Codex app-server version: no version record (recreated on next monitor launch)" ;;
    unknown-current) _codex_doctor_display "Codex app-server version: recorded '$ver_raw' (current version unreadable — check skipped)" ;;
    match) _codex_doctor_display "Codex app-server version: '$ver_raw' (matches current)" ;;
    drift) _codex_doctor_display "Codex app-server version: recorded '$ver_raw', current '$cur' (drift)" ;;
  esac
  if [ "$pid_state" = "alive-confirmed" ] && [ "$ep_state" = "responsive" ] && [ "$ver_state" = "match" ]; then
    _codex_doctor_display "Codex app-server: healthy (pid $pid_raw, $url, version '$ver_raw')"
  fi

  # --- component signals: the same three verdicts as observations (a record
  # triple exists -- the no-record early return above stayed silent). No
  # health verdict: attention states are findings below, not signal values.
  # Global orphans carry the opaque instance (P1-6); per-pair stays a scope
  # singleton (null).
  _codex_doctor_signal codex_app_server "" "" process "$pid_state" "$opaque"
  _codex_doctor_signal codex_app_server "" "" endpoint "$ep_state" "$opaque"
  _codex_doctor_signal codex_app_server "" "" version "$ver_state" "$opaque"

  # Evidence wording for the recorded pid: scoped findings may name the raw
  # number (existing convention), but GLOBAL findings (attributed=0, orphan
  # records) must not — a bare pid survives --redacted (the pseudonym table
  # only holds namespaced keys) and leaks a host identifier into paste-safe
  # output. The display lines above keep the number for the human either
  # way; the finding refers to the opaque instance instead.
  local _pidref="pid $pid_raw"
  if [ "$attributed" -eq 0 ]; then _pidref="pid recorded under $opaque"; fi

  # --- warnings: one independent rule per signal. Combined states surface as
  # several warnings, never as a single verdict that needs all of them.
  case "$pid_state" in
    invalid) _codex_doctor_warn codex_pid_invalid "" "" codex_app_server "stale app-server pid record (invalid pid '$pid_raw')" "$opaque" ;;
    dead) _codex_doctor_warn codex_pid_stale "" "" codex_app_server "stale app-server pidfile ($_pidref not running)" "$opaque" ;;
    alive-foreign) _codex_doctor_warn codex_pid_foreign "" "" codex_app_server "app-server $_pidref is alive but is not a Codex app-server (possible pid reuse); the record does not point at a live server" "$opaque" ;;
  esac
  if [ "$pid_state" = "none" ] && [ "$have_portf" -eq 1 ]; then
    _codex_doctor_warn codex_records_incomplete "" "" codex_app_server "app-server endpoint record exists but the pid record is missing (incomplete state)" "$opaque"
  fi
  if [ "$pid_state" = "none" ] && [ "$have_portf" -eq 0 ] && [ "$have_verf" -eq 1 ]; then
    _codex_doctor_warn codex_records_incomplete "" "" codex_app_server "app-server version record exists but the pid and port records are missing (incomplete state)" "$opaque"
  fi
  # alive-confirmed with no port record but a version record present: the
  # monitor writes pid, then port, then version, in that order — a version
  # record already existing refutes "still starting up", so this leftover is
  # genuinely incomplete. Without the version record the same shape is an
  # ordinary startup race (pid written, port banner not yet parsed) and stays
  # silent below.
  if [ "$pid_state" = "alive-confirmed" ] && [ "$ep_state" = "none" ] && [ "$have_verf" -eq 1 ]; then
    _codex_doctor_warn codex_records_incomplete "" "" codex_app_server "app-server $_pidref is alive but the port record is missing while a version record exists (incomplete state — not a startup race)" "$opaque"
  fi
  if [ "$ep_state" = "invalid" ]; then
    _codex_doctor_warn codex_endpoint_invalid "" "" codex_app_server "stale app-server endpoint record (invalid port '$port_raw')" "$opaque"
  fi
  if [ "$ep_state" = "silent" ] && [ "$pid_state" = "alive-confirmed" ]; then
    _codex_doctor_warn codex_endpoint_unresponsive "" "" codex_app_server "app-server process is alive ($_pidref) but its endpoint is unresponsive ($url)" "$opaque"
  fi
  if [ "$ep_state" = "silent" ] && [ "$pid_state" != "alive-confirmed" ] && [ "$pid_state" != "alive-unverified" ]; then
    _codex_doctor_warn codex_endpoint_unresponsive "" "" codex_app_server "app-server endpoint is unresponsive ($url)" "$opaque"
  fi
  if [ "$ep_state" = "responsive" ]; then
    case "$pid_state" in
      dead|none|invalid)
        _codex_doctor_warn codex_endpoint_foreign "" "" codex_app_server "endpoint $url answers but no live recorded server owns it (another process may hold the port)" "$opaque"
        ;;
      alive-foreign)
        _codex_doctor_warn codex_endpoint_foreign "" "" codex_app_server "endpoint $url answers but the recorded $_pidref is not a Codex app-server (ownership unproven)" "$opaque"
        ;;
    esac
  fi
  if [ "$ver_state" = "drift" ]; then
    if [ "$attributed" -eq 1 ]; then
      _codex_doctor_warn codex_version_drift "" "" codex_app_server "app-server version drift (recorded '$ver_raw', current '$cur'); relaunch Codex through the monitor to recreate the server" "$opaque"
    else
      _codex_doctor_warn codex_version_drift "" "" codex_app_server "app-server version drift (recorded '$ver_raw', current '$cur'; owning project unknown)" "$opaque"
    fi
  fi
  # Deliberately silent: alive-unverified (ownership genuinely unknown),
  # unknown-record / unknown-current (cannot tell), the no-record state
  # (a monitor-mode project that never launched is normal), and
  # alive-confirmed with neither a port nor a version record (the monitor
  # writes the pid before the port banner arrives, so that shape is an
  # ordinary startup race).
  return 0
}

# Per-pair bridge-binding check (P1): launcher-generation bridge files for
# roles registered in THIS project, compared against this project's current
# app-server URL and each role's recorded seat. The binding sidecars
# (.appserver/.thread, written by the launcher) mark the generation — the
# bridge itself writes pidfile + .meta in every generation, and delivery.sh's
# own per-role lines already judge liveness and metadata, so keys without
# sidecars stay entirely with delivery.sh (re-judging them here would double
# every bridge warning).
_codex_doctor_pair_bindings() {
  local project="$1" port_raw="$2"
  local current_url=""
  if _codex_doctor_valid_port "$port_raw"; then
    current_url="ws://127.0.0.1:$port_raw"
  fi
  local pairs team name key pidf bridge_pid bound_url bound_thread
  pairs="$("$SCRIPT_DIR/identities.sh" "$project" codex 2>/dev/null || true)"
  if command -v _team_filter_lines >/dev/null 2>&1; then
    pairs="$(_team_filter_lines "$pairs" "${FILTER_TEAM:-}")"
  fi
  [ -n "$pairs" ] || return 0
  while IFS="$(printf '\t')" read -r team name; do
    [ -n "$team" ] || continue
    [ -n "$name" ] || continue
    key="$team.$name"
    pidf="$RUN_DIR/codex-bridge.$key.pid"
    [ -f "$pidf" ] || continue
    if [ ! -f "$RUN_DIR/codex-bridge.$key.appserver" ] && [ ! -f "$RUN_DIR/codex-bridge.$key.thread" ]; then
      continue
    fi
    bridge_pid="$(_codex_doctor_read_record "$pidf")"
    bound_url="$(_codex_doctor_read_record "$RUN_DIR/codex-bridge.$key.appserver")"
    bound_thread="$(_codex_doctor_read_record "$RUN_DIR/codex-bridge.$key.thread")"
    _codex_doctor_eval_binding "$key" "$bridge_pid" "$bound_url" "$bound_thread" "$current_url" "$team" "$name"
  done <<< "$pairs"
  return 0
}

# Shared binding verdict for one launcher-generation bridge key. $6/$7 (team,
# agent) are set for the per-pair call and empty for the global call, where
# the seat can only be checked for membership in the recorded set rather than
# against one role's seat. Global calls use a paste-safe opaque pseudonym
# (P1-5/P1-6) for display/evidence/instance, never the raw key.
_codex_doctor_eval_binding() {
  local key="$1" bridge_pid="$2" bound_url="$3" bound_thread="$4"
  local current_url="$5" team="${6:-}" name="${7:-}"
  local opaque="" display_key="$key"
  if [ -z "$team" ] && [ -z "$name" ]; then
    _codex_doctor_opaque_for "$key"
    opaque="$_CODEX_OPAQUE_OUT"
    display_key="$opaque"
  fi
  local alive=0
  if [ -n "$bridge_pid" ] && _agmsg_pid_valid "$bridge_pid" 2>/dev/null; then
    # The bridge records its own pid, which comes from outside these shells —
    # the non-local check, per #567 (a bridge is exactly the case the plain
    # helper exists for).
    if _agmsg_pid_alive "$bridge_pid" 2>/dev/null; then alive=1; fi
  fi

  local url_verdict="unknown"
  if [ -n "$bound_url" ] && [ -n "$current_url" ]; then
    if [ "$bound_url" = "$current_url" ]; then url_verdict="match"; else url_verdict="mismatch"; fi
  fi
  local thread_verdict="unknown" seat=""
  if [ -n "$team" ] && [ -n "$name" ]; then
    agmsg_role_session_load "$team" "$name" 2>/dev/null || true
    seat="$AGMSG_ROLE_SESSION_UUID"
    if [ -n "$seat" ] && [ -n "$bound_thread" ]; then
      if [ "$seat" = "$bound_thread" ]; then thread_verdict="match"; else thread_verdict="mismatch"; fi
    fi
  fi

  local run_word="not running"
  if [ "$alive" -eq 1 ]; then run_word="alive (pid $bridge_pid)"; fi
  _codex_doctor_display "Codex bridge binding: $display_key $run_word, app-server=$url_verdict, thread=$thread_verdict"
  if [ -n "$bound_url" ] && [ "$url_verdict" != "unknown" ]; then
    _codex_doctor_display "  bound app-server: $bound_url"
  fi

  # Session-like identifiers travel in evidence -- register them so
  # --redacted masks them everywhere the shared tables run.
  [ -n "$bound_thread" ] && agmsg_doctor_note_secret "$bound_thread"
  [ -n "$seat" ] && [ "$seat" != "$bound_thread" ] && agmsg_doctor_note_secret "$seat"

  # Component observations for this launcher-generation bridge: liveness,
  # the bound app-server URL against the project's current endpoint, and
  # the bound thread against the role's recorded seat.
  local _proc_sig="not-running" _bind_sig="unknown" _seat_sig="unknown"
  if [ "$alive" -eq 1 ]; then _proc_sig="running"; fi
  case "$url_verdict" in
    match) _bind_sig="matched" ;;
    mismatch) _bind_sig="mismatched" ;;
  esac
  case "$thread_verdict" in
    match) _seat_sig="matched" ;;
    mismatch) _seat_sig="mismatched" ;;
  esac
  _codex_doctor_signal codex_bridge "$team" "$name" process "$_proc_sig" "$opaque"
  _codex_doctor_signal codex_bridge "$team" "$name" binding "$_bind_sig" "$opaque"
  _codex_doctor_signal codex_bridge "$team" "$name" seat "$_seat_sig" "$opaque"

  if [ "$alive" -eq 0 ]; then
    if [ -f "$RUN_DIR/codex-bridge.$key.pid" ]; then
      _codex_doctor_warn codex_bridge_stale_pidfile "$team" "$name" codex_bridge "stale bridge pidfile ($display_key, pid '${bridge_pid:-empty}' not running)" "$opaque"
    fi
    return 0
  fi
  if [ "$url_verdict" = "mismatch" ]; then
    if [ -n "$current_url" ]; then
      _codex_doctor_warn codex_bridge_stale_binding "$team" "$name" codex_bridge "bridge $display_key is bound to a stale app-server (bound '$bound_url', current '$current_url')" "$opaque"
    else
      _codex_doctor_warn codex_bridge_stale_binding "$team" "$name" codex_bridge "bridge $display_key is alive but this project has no current app-server endpoint (bound '$bound_url')" "$opaque"
    fi
  fi
  if [ "$thread_verdict" = "mismatch" ]; then
    _codex_doctor_warn codex_bridge_thread_mismatch "$team" "$name" codex_bridge "bridge $display_key is bound to thread '$bound_thread' but the recorded seat is '$seat'" "$opaque"
  fi
  return 0
}

# Union of every registered codex (team, agent) pair, one "team<TAB>name"
# line each. The per-pair call attributes single-role bridge keys against its
# own project's pairs, so the global scan skips whatever this union holds —
# recomputed per call instead of shared as cross-call state.
_codex_doctor_registered_pairs() {
  local proj pair_lines=""
  while IFS= read -r proj; do
    [ -n "$proj" ] || continue
    pair_lines="${pair_lines}$("$SCRIPT_DIR/identities.sh" "$proj" codex 2>/dev/null \
      | awk -F'\t' 'NF >= 2 { print $1 "\t" $2 }' || true)"$'\n'
  done <<< "$(agmsg_registered_projects codex 2>/dev/null | sort -u || true)"
  printf '%s' "$pair_lines" | sort -u
  return 0
}

# Global bridge check: launcher-generation keys no per-pair call attributed
# (multi-role hash keys, or roles under projects outside a filtered scope).
# Project-independent signals only — liveness, bound-endpoint responsiveness,
# and seat-set membership. A thread outside the recorded set is a note, never
# a verdict: seats predate the record format and removed roles leave none.
#
# $1 is the registered-pair union already computed by the caller (shared with
# the orphan-seat pass so neither recomputes the installation's pair set).
_codex_doctor_global_bindings() {
  local tab pair_union pidf key bridge_pid bound_url bound_thread bound_port seated _gopaque _gdisplay
  local _claimed _pt _pa
  tab="$(printf '\t')"
  pair_union="$1"
  for pidf in "$RUN_DIR"/codex-bridge.*.pid; do
    [ -f "$pidf" ] || continue
    key="${pidf##*/codex-bridge.}"
    key="${key%.pid}"
    case "$key" in ''|*/*) continue ;; esac
    # A registered pair claims its key by FORWARD construction (team.agent):
    # the filename cannot be split back — team "foo.bar" + agent "alice" is
    # the key "foo.bar.alice", which a first-dot split would misread as
    # foo/bar.alice and orphan a live registered bridge.
    _claimed=0
    while IFS="$tab" read -r _pt _pa; do
      [ -n "$_pt" ] && [ -n "$_pa" ] || continue
      if [ "$key" = "$_pt.$_pa" ]; then _claimed=1; break; fi
    done <<< "$pair_union"
    [ "$_claimed" -eq 1 ] && continue
    bridge_pid="$(_codex_doctor_read_record "$pidf")"
    # Keys without launcher sidecars belong to delivery.sh's own per-role
    # verdicts (see the per-pair comment above) WHEN their role is still
    # registered — those keys never reach this line. A key reaching here
    # without sidecars is claimed by nobody: judge liveness only, since
    # there is no binding to compare and nothing else ever will.
    if [ ! -f "$RUN_DIR/codex-bridge.$key.appserver" ] && [ ! -f "$RUN_DIR/codex-bridge.$key.thread" ]; then
      _codex_doctor_opaque_for "$key"
      _gopaque="$_CODEX_OPAQUE_OUT"
      if [ -n "$bridge_pid" ] && _agmsg_pid_valid "$bridge_pid" 2>/dev/null \
        && _agmsg_pid_alive "$bridge_pid" 2>/dev/null; then
        _codex_doctor_display "Codex bridge: $_gopaque alive (pid $bridge_pid) but no registered role claims its key (ambiguous — a dropped role's bridge may not have exited yet)"
        _codex_doctor_signal codex_bridge "" "" process "running" "$_gopaque"
        _codex_doctor_signal codex_bridge "" "" endpoint "unknown" "$_gopaque"
        _codex_doctor_signal codex_bridge "" "" seat "unknown" "$_gopaque"
      else
        _codex_doctor_display "Codex bridge: $_gopaque not running (pid '${bridge_pid:-empty}')"
        # Global findings keep host pids out of structured evidence — the
        # opaque instance stands in for them (raw pids stay on the
        # human-only display line above).
        _codex_doctor_warn codex_bridge_stale_pidfile "" "" codex_bridge "stale bridge pidfile ($_gopaque — recorded pid not running)" "$_gopaque"
        _codex_doctor_signal codex_bridge "" "" process "not-running" "$_gopaque"
        _codex_doctor_signal codex_bridge "" "" endpoint "unknown" "$_gopaque"
        _codex_doctor_signal codex_bridge "" "" seat "unknown" "$_gopaque"
      fi
      continue
    fi
    bound_url="$(_codex_doctor_read_record "$RUN_DIR/codex-bridge.$key.appserver")"
    bound_thread="$(_codex_doctor_read_record "$RUN_DIR/codex-bridge.$key.thread")"
    [ -n "$bound_thread" ] && agmsg_doctor_note_secret "$bound_thread"
    # P1-5/P1-6: raw key を opaque へ変換し、display/evidence/instance に
    # 使う。same raw → same opaque、distinct raw → distinct opaque。
    _codex_doctor_opaque_for "$key"
    _gopaque="$_CODEX_OPAQUE_OUT"
    _gdisplay="$_gopaque"
    if [ -n "$bridge_pid" ] && _agmsg_pid_valid "$bridge_pid" 2>/dev/null \
      && _agmsg_pid_alive "$bridge_pid" 2>/dev/null; then
      bound_port=""
      case "$bound_url" in
        ws://127.0.0.1:*) bound_port="${bound_url##*:}" ;;
      esac
      if [ -n "$bound_port" ] && _codex_doctor_valid_port "$bound_port" \
        && ! _codex_doctor_port_alive "$bound_port"; then
        _codex_doctor_display "Codex bridge binding: $_gdisplay alive (pid $bridge_pid), bound endpoint $bound_url unresponsive"
        _codex_doctor_warn codex_bridge_endpoint_unresponsive "" "" codex_bridge "bridge $_gdisplay is alive but its bound endpoint is unresponsive ($bound_url)" "$_gopaque"
        _codex_doctor_signal codex_bridge "" "" process "running" "$_gopaque"
        _codex_doctor_signal codex_bridge "" "" endpoint "unresponsive" "$_gopaque"
        _codex_doctor_signal codex_bridge "" "" seat "unknown" "$_gopaque"
      elif [ -n "$bound_thread" ]; then
        seated="$(agmsg_role_session_recorded_uuids codex 2>/dev/null || true)"
        case $'\n'"$seated"$'\n' in
          *$'\n'"$bound_thread"$'\n'*)
            _codex_doctor_signal codex_bridge "" "" process "running" "$_gopaque"
            _codex_doctor_signal codex_bridge "" "" endpoint "unknown" "$_gopaque"
            _codex_doctor_signal codex_bridge "" "" seat "matched" "$_gopaque"
            ;;
          *)
            _codex_doctor_display "Codex bridge binding: $_gdisplay alive (pid $bridge_pid), bound thread matches no recorded seat (ambiguous — not attributed)"
            _codex_doctor_signal codex_bridge "" "" process "running" "$_gopaque"
            _codex_doctor_signal codex_bridge "" "" endpoint "unknown" "$_gopaque"
            _codex_doctor_signal codex_bridge "" "" seat "unknown" "$_gopaque"
            ;;
        esac
      else
        _codex_doctor_signal codex_bridge "" "" process "running" "$_gopaque"
        _codex_doctor_signal codex_bridge "" "" endpoint "unknown" "$_gopaque"
        _codex_doctor_signal codex_bridge "" "" seat "unknown" "$_gopaque"
      fi
    else
      _codex_doctor_display "Codex bridge binding: $_gdisplay not running (pid '${bridge_pid:-empty}')"
      # Same global-evidence rule as the no-sidecar branch: no raw host pid
      # in the finding — the opaque instance is its stand-in.
      _codex_doctor_warn codex_bridge_stale_pidfile "" "" codex_bridge "stale bridge pidfile ($_gdisplay — recorded pid not running)" "$_gopaque"
      _codex_doctor_signal codex_bridge "" "" process "not-running" "$_gopaque"
      _codex_doctor_signal codex_bridge "" "" endpoint "unknown" "$_gopaque"
      _codex_doctor_signal codex_bridge "" "" seat "unknown" "$_gopaque"
    fi
  done
  return 0
}

# Live `codex app-server` processes as "pid<TAB>args" lines. Read-only: a
# single `ps` snapshot (never a signal). AGMSG_DOCTOR_PS_SNAPSHOT substitutes
# a fixture file — the real process table is neither deterministic nor safe
# to depend on in tests. rc 1 means the scan itself is unavailable; callers
# degrade to a note rather than guessing.
_codex_doctor_process_scan() {
  local raw
  if [ -n "${AGMSG_DOCTOR_PS_SNAPSHOT:-}" ]; then
    [ -f "$AGMSG_DOCTOR_PS_SNAPSHOT" ] || return 1
    raw="$(cat "$AGMSG_DOCTOR_PS_SNAPSHOT" 2>/dev/null || true)"
  else
    command -v ps >/dev/null 2>&1 || return 1
    raw="$(ps -eo pid=,args= 2>/dev/null)" || return 1
  fi
  local pid args
  while read -r pid args || [ -n "$pid$args" ]; do
    _agmsg_pid_valid "$pid" 2>/dev/null || continue
    _codex_doctor_is_appserver_args "$args" || continue
    [ "$pid" = "$$" ] && continue
    printf '%s\t%s\n' "$pid" "$args"
  done <<EOF
$raw
EOF
  return 0
}

# Live app-server processes no record triple in this install claims — the
# untracked-orphan case of Issue #5. $1 is the newline-separated set of pids
# already read from every codex-app-server.*.pid file (known hashes included,
# so a healthy tracked server is never flagged). A live-but-untracked pid is
# ambiguous: a manual `codex app-server`, another install's server, or a
# leaked launch. Reported as a warning so the leftover is visible, with no
# attribution invented and nothing suggested beyond manual verification.
_codex_doctor_untracked_processes() {
  local recorded_pids="$1" scan spid sargs
  if ! scan="$(_codex_doctor_process_scan)"; then
    _codex_doctor_display "Codex app-server process scan unavailable (untracked-process check skipped)"
    return 0
  fi
  while IFS="$(printf '\t')" read -r spid sargs; do
    [ -n "$spid" ] || continue
    case $'\n'"$recorded_pids"$'\n' in
      *$'\n'"$spid"$'\n'*) continue ;;
    esac
    # The snapshot can be stale (or a fixture): only a pid still live now is
    # a finding.
    _agmsg_pid_alive_local "$spid" 2>/dev/null || continue
    _codex_doctor_opaque_for "appserver-pid:$spid"
    _codex_doctor_display "Codex app-server process: pid $spid is live but no record tracks it ($_CODEX_OPAQUE_OUT)"
    # Global evidence must not carry the raw host pid: the pseudonym table
    # holds "appserver-pid:<pid>", never the bare number, so a literal pid
    # here would also survive --redacted. The display line keeps it for the
    # human; the finding refers to the opaque instance instead.
    _codex_doctor_warn codex_process_untracked "" "" codex_app_server \
      "live Codex app-server process ($_CODEX_OPAQUE_OUT) is not tracked by any record in this install (a manual 'codex app-server' or another install may own it — ambiguous; verify before stopping)" \
      "$_CODEX_OPAQUE_OUT"
    _codex_doctor_signal codex_app_server "" "" process "untracked-live" "$_CODEX_OPAQUE_OUT"
  done <<< "$scan"
  return 0
}

# Orphan role-session records: a seat whose (team, agent) no registration
# holds is a routine post-drop leftover, but it still occupies its thread in
# the seated set — which changes how a missing bridge gets explained.
# Surfaced as advisory state, not a warning: the record is safe to remove by
# hand and nothing here proves it should be.
_codex_doctor_orphan_seats() {
  local pair_union="$1" tab f rtype rteam ragent rteam_d ragent_d rsess
  tab="$(printf '\t')"
  for f in "$RUN_DIR"/role-session.*; do
    [ -f "$f" ] || continue
    rtype="$(_agmsg_role_session_field "$f" type)"
    [ "$rtype" = "codex" ] || continue
    rteam="$(_agmsg_role_session_field "$f" team)"
    ragent="$(_agmsg_role_session_field "$f" agent)"
    [ -n "$rteam" ] && [ -n "$ragent" ] || continue
    case $'\n'"$pair_union"$'\n' in
      *$'\n'"${rteam}${tab}${ragent}"$'\n'*) continue ;;
    esac
    # Same secret-table hygiene as the bound-thread read above: this seat's
    # session id is never printed, but masking it keeps any other line that
    # happens to carry it safe under --redacted.
    rsess="$(_agmsg_role_session_field "$f" session)"
    [ -n "$rsess" ] && agmsg_doctor_note_secret "$rsess"
    # Register pseudonyms before the display line is built: names absent from
    # the registration store were never _redact_*-mapped, so under
    # --redacted they would otherwise reach the line raw.
    if command -v _redact_team >/dev/null 2>&1; then
      _redact_team "$rteam"; rteam_d="$_REDACT_OUT"
      _redact_agent "$ragent"; ragent_d="$_REDACT_OUT"
    else
      rteam_d="$rteam"; ragent_d="$ragent"
    fi
    _codex_doctor_display "Codex role-session: $rteam_d/$ragent_d holds a seat record but no registration (advisory leftover — still occupies its thread in the seated set)"
    _codex_doctor_signal codex_role_session "$rteam" "$ragent" seat "orphan" ""
  done
  return 0
}

# The optional PATH shim (~/.agents/bin/codex) routes interactive launches
# through the monitor for monitor-mode projects. Install-global state, so it
# is diagnosed here rather than per pair. Read-only: file reads, a grep for
# the shim marker, and `command -v` resolution — nothing is executed through
# the shim itself.
_codex_doctor_shim_check() {
  local shim_bin="$HOME/.agents/bin/codex"
  local marker="Optional Codex entrypoint shim for agmsg monitor mode"
  local codex_dir="$SKILL_DIR/scripts/drivers/types/codex"
  local owner="" resolved=""
  if [ ! -f "$shim_bin" ]; then
    _codex_doctor_display "Codex shim: not installed ($shim_bin absent; optional — the shell function or codex-monitor.sh can also route monitor launches)"
    _codex_doctor_signal codex_shim "" "" install "absent" ""
    return 0
  fi
  if ! grep -q "$marker" "$shim_bin" 2>/dev/null; then
    _codex_doctor_display "Codex shim: $shim_bin exists but is not an agmsg shim — left untouched, and it does not route through this install"
    _codex_doctor_signal codex_shim "" "" install "foreign-file" ""
    return 0
  fi
  # The installer stamps `# agmsg-shim-owner: <quoted dir>` so an installed
  # shim can be attributed to one agmsg checkout; pre-stamp shims are
  # attributed to nothing and stay "unknown".
  owner="$(sed -n 's/^# agmsg-shim-owner: //p' "$shim_bin" 2>/dev/null | head -1)"
  if [ -z "$owner" ]; then
    # A legacy shim predates the owner stamp, so which install it should
    # dispatch into cannot be proven — but whether it dispatches into ANY
    # codex-shim.sh can: a marker+body truncated to `exit 0` routes nowhere.
    if grep -q '^exec .*codex-shim\.sh' "$shim_bin" 2>/dev/null; then
      _codex_doctor_display "Codex shim: installed ($shim_bin), owner unknown (predates ownership tracking)"
      _codex_doctor_signal codex_shim "" "" owner "legacy-unknown" ""
      _codex_doctor_signal codex_shim "" "" dispatch "unverified" ""
    else
      _codex_doctor_display "Codex shim: installed ($shim_bin), owner unknown, and its body never execs a codex-shim.sh"
      _codex_doctor_signal codex_shim "" "" owner "legacy-unknown" ""
      _codex_doctor_signal codex_shim "" "" dispatch "missing" ""
      _codex_doctor_warn codex_shim_no_dispatch "" "" codex_shim \
        "codex shim $shim_bin predates ownership tracking and never execs a codex-shim.sh (truncated or repointed body); launches through it reach no monitor" ""
    fi
  elif [ "$owner" = "$(printf '%q' "$codex_dir")" ]; then
    # The owner stamp proves attribution, not content: a truncated or
    # repointed body keeps marker+owner while no longer execing anywhere
    # (a bare `exit 0` reads as a healthy shim). The only line that routes
    # launches is the exact `exec <this install>/codex-shim.sh "$@"` the
    # installer writes (same %q quoting) — require it verbatim, plus an
    # executable exec target, before reporting the dispatch intact.
    local _expected_exec="exec $(printf '%q' "$codex_dir/codex-shim.sh") \"\$@\""
    if ! grep -qxF "$_expected_exec" "$shim_bin" 2>/dev/null; then
      _codex_doctor_display "Codex shim: installed ($shim_bin), owned by this install, but its body never execs this install's codex-shim.sh"
      _codex_doctor_signal codex_shim "" "" owner "self" ""
      _codex_doctor_signal codex_shim "" "" dispatch "missing" ""
      _codex_doctor_warn codex_shim_no_dispatch "" "" codex_shim \
        "codex shim $shim_bin is stamped as owned by this install but never execs this install's codex-shim.sh (truncated or repointed body); monitor launches through it do not reach the monitor" ""
    elif [ -x "$codex_dir/codex-shim.sh" ] && [ -f "$SKILL_DIR/scripts/delivery.sh" ]; then
      _codex_doctor_display "Codex shim: installed ($shim_bin), owned by this install, dispatch target intact"
      _codex_doctor_signal codex_shim "" "" owner "self" ""
      _codex_doctor_signal codex_shim "" "" dispatch "intact" ""
    else
      _codex_doctor_display "Codex shim: installed ($shim_bin), owned by this install, but its dispatch target is incomplete"
      _codex_doctor_signal codex_shim "" "" owner "self" ""
      _codex_doctor_signal codex_shim "" "" dispatch "target-incomplete" ""
      _codex_doctor_warn codex_shim_broken_target "" "" codex_shim \
        "codex shim $shim_bin points at this install but the driver directory is missing pieces or codex-shim.sh is not executable; launches through the shim fall back to plain codex" ""
    fi
  else
    _codex_doctor_display "Codex shim: installed ($shim_bin), owned by a different agmsg install ($owner)"
    _codex_doctor_signal codex_shim "" "" owner "foreign" ""
    _codex_doctor_warn codex_shim_foreign_owner "" "" codex_shim \
      "codex shim $shim_bin is owned by a different agmsg install ($owner); every codex launch through it dispatches into that install's storage and drivers" ""
  fi
  # PATH effectiveness: `codex` resolving elsewhere only means the PATH shim
  # is not the entrypoint — a shell function (invisible from this subshell)
  # may still route launches, so this is a note, never a warning. Same
  # conservatism as delivery.sh's own shim-path note.
  resolved="$(command -v codex 2>/dev/null || true)"
  if [ -z "$resolved" ]; then
    _codex_doctor_display "Codex shim PATH: 'codex' is not on PATH in this shell"
    _codex_doctor_signal codex_shim "" "" path_effect "no-codex" ""
  elif [ "$resolved" = "$shim_bin" ]; then
    _codex_doctor_display "Codex shim PATH: 'codex' resolves to the shim (PATH-effective)"
    _codex_doctor_signal codex_shim "" "" path_effect "effective" ""
  elif [ -f "$resolved" ] && grep -q "$marker" "$resolved" 2>/dev/null; then
    _codex_doctor_display "Codex shim PATH: 'codex' resolves to a different agmsg shim ($resolved)"
    _codex_doctor_signal codex_shim "" "" path_effect "other-shim" ""
  else
    case "$resolved" in
      */*)
        _codex_doctor_display "Codex shim PATH: 'codex' resolves to $resolved, not the shim — a shell function may still route launches (unverifiable from here)"
        _codex_doctor_signal codex_shim "" "" path_effect "shadowed" "" ;;
      *)
        _codex_doctor_display "Codex shim PATH: 'codex' resolves to a non-path ($resolved)"
        _codex_doctor_signal codex_shim "" "" path_effect "non-path" "" ;;
    esac
  fi
  return 0
}

# One logical runtime lock (launcher dispatcher / role child), evaluated
# across every lock resource the project-hash spellings can name. Locks live
# in the runtime store's `locks` table — read-only here: never acquire or
# release, and the caller guarantees the db file already exists (sqlite3
# creates an empty file on open, so even a SELECT on a missing path would be
# a write). The spellings name ONE logical lock — a second launch under the
# other spelling would block on the first's lock — so their owner rows are
# aggregated into a single verdict: emitting two states on one component
# would leave consumers unable to tell which is current. A dead-owner row is
# stale evidence of an unclean exit — the next monitor launch CAS-reclaims
# it (acquire_runtime_lock) — so it is reported, not treated as a blocker.
_codex_doctor_eval_locks() {
  local label="$1" team="$2" agent="$3" comp="$4" code="$5" conflict_code="$6"
  shift 6
  local res owner alive="" dead="" _pw
  for res in "$@"; do
    [ -n "$res" ] || continue
    owner="$(agmsg_runtime_lock_owner "$res" 2>/dev/null || true)"
    [ -n "$owner" ] || continue
    # One pid holding both spelling resources is still one owner.
    case " $alive $dead " in *" $owner "*) continue ;; esac
    # _local: the owner pid is a launcher shell's $$, minted in the MSYS pid
    # space under Git Bash — same choice acquire_runtime_lock makes (#567).
    if _agmsg_pid_alive_local "$owner" 2>/dev/null; then
      alive="${alive:+$alive }$owner"
    else
      dead="${dead:+$dead }$owner"
    fi
  done
  if [ -z "$alive$dead" ]; then
    _codex_doctor_signal "$comp" "$team" "$agent" lock "none" ""
    return 0
  fi
  local msg=""
  if [ -n "$alive" ]; then
    _pw="pid"; case "$alive" in *" "*) _pw="pids" ;; esac
    msg="held by live $_pw $alive"
  fi
  if [ -n "$dead" ]; then
    _pw="pid"; case "$dead" in *" "*) _pw="pids" ;; esac
    msg="${msg:+$msg; }held by dead $_pw $dead"
  fi
  _codex_doctor_display "Codex $label lock: $msg"
  if [ -n "$alive" ]; then
    _codex_doctor_signal "$comp" "$team" "$agent" lock "held-alive" ""
  else
    _codex_doctor_signal "$comp" "$team" "$agent" lock "held-stale" ""
  fi
  # Distinct live owners cannot be one launcher: the per-spelling resources
  # are separate database keys (codex-bridge-launcher builds each from its
  # own PROJECT_HASH), so they never block each other — two live owners is
  # a real duplicate-launcher conflict, not a single healthy lock.
  case "$alive" in
    *" "*)
      _codex_doctor_warn "$conflict_code" "$team" "$agent" "$comp" \
        "$label lock is held by multiple live processes (pids $alive) — lock resources under different path spellings are distinct keys and do not block each other; duplicate launchers may be running" ""
      ;;
  esac
  if [ -n "$dead" ]; then
    _pw="pid"; case "$dead" in *" "*) _pw="pids" ;; esac
    _codex_doctor_warn "$code" "$team" "$agent" "$comp" \
      "stale $label lock (owner $_pw $dead not running); reclaimed automatically on the next monitor launch" ""
  fi
  return 0
}

# Runtime-lock state for this project: one dispatcher lock per project hash,
# one child lock per registered role (codex-bridge-launcher.sh). Silent when
# the runtime store does not exist at all — monitor never ran here. $2 and
# $3 are the registered-spelling and canonical-spelling project hashes: the
# launcher hashes whichever spelling it was launched under, so a lock can sit
# under either — both resources are passed to the aggregation above, which
# emits one verdict per component. Role identity lines are narrowed by
# doctor.sh's --team filter so a scan of team A never reports team B's lock.
_codex_doctor_pair_locks() {
  local project="$1" hash="$2" canon_hash="${3:-}" db
  command -v agmsg_runtime_lock_owner >/dev/null 2>&1 || return 0
  db="$(_agmsg_runtime_db_path 2>/dev/null || true)"
  [ -n "$db" ] && [ -f "$db" ] || return 0
  local team name tab child_res alt idents
  tab="$(printf '\t')"
  alt=""
  if [ -n "$canon_hash" ] && [ "$canon_hash" != "$hash" ]; then
    alt="codex-dispatcher:$canon_hash"
  fi
  _codex_doctor_eval_locks "dispatcher" "" "" codex_dispatcher \
    codex_dispatcher_lock_stale codex_dispatcher_lock_conflict \
    "codex-dispatcher:$hash" "$alt"
  idents="$("$SCRIPT_DIR/identities.sh" "$project" codex 2>/dev/null || true)"
  if command -v _team_filter_lines >/dev/null 2>&1; then
    idents="$(_team_filter_lines "$idents" "${FILTER_TEAM:-}")"
  fi
  while IFS="$tab" read -r team name; do
    [ -n "$team" ] && [ -n "$name" ] || continue
    child_res="$(printf '%s' "${team}${tab}${name}" | agmsg_sha1 2>/dev/null)"
    alt=""
    if [ -n "$canon_hash" ] && [ "$canon_hash" != "$hash" ]; then
      alt="codex-child:$canon_hash:$child_res"
    fi
    _codex_doctor_eval_locks "bridge-launcher child" "$team" "$name" \
      codex_child codex_child_lock_stale codex_child_lock_conflict \
      "codex-child:$hash:$child_res" "$alt"
  done <<< "$idents"
  return 0
}

agmsg_doctor_extra_collect() {
  local type="$1" project="$2"
  [ "$type" = "codex" ] || return 0
  _CODEX_DOCTOR_SCOPE_PROJECT="$project"
  _CODEX_DOCTOR_SCOPE_TYPE="$type"
  _CODEX_DOCTOR_DISPLAY_MODE="pair"
  local hash port_raw canon canon_hash _raw_pid_state="" _canon_pid_state=""
  local _raw_has=0 _canon_has=0
  hash="$(printf '%s' "$project" | agmsg_sha1 2>/dev/null || true)"
  [ -n "$hash" ] || return 0
  # Canonical-spelling fallback: the monitor hashes the logical path it was
  # launched with, while a registration can hold another spelling of the
  # same directory (symlinked vs physical — /var vs /private/var on macOS).
  # A record under the canonical hash is otherwise seen by NO scan: the
  # global pass already counts it among the known hashes and skips it.
  canon="$(agmsg_canonical_path "$project" 2>/dev/null || printf '%s' "$project")"
  canon_hash=""
  if [ "$canon" != "$project" ]; then
    canon_hash="$(printf '%s' "$canon" | agmsg_sha1 2>/dev/null || true)"
  fi
  if [ -f "$RUN_DIR/codex-app-server.$hash.pid" ] \
    || [ -f "$RUN_DIR/codex-app-server.$hash.port" ] \
    || [ -f "$RUN_DIR/codex-app-server.$hash.version" ]; then
    _raw_has=1
  fi
  if [ -n "$canon_hash" ] && [ "$canon_hash" != "$hash" ] \
    && { [ -f "$RUN_DIR/codex-app-server.$canon_hash.pid" ] \
      || [ -f "$RUN_DIR/codex-app-server.$canon_hash.port" ] \
      || [ -f "$RUN_DIR/codex-app-server.$canon_hash.version" ]; }; then
    _canon_has=1
  fi
  # Two record sets are two objects: giving each its own opaque instance
  # keeps their signals from merging into one contradictory null-instance
  # codex_app_server component (a stale raw record beside a healthy
  # canonical record would otherwise read as process=dead AND
  # process=alive-confirmed on one component). Seeding the pseudonym from
  # the record's hash makes the scoped instance correlate with any
  # global-orphan component for the same record set.
  local _canon_opaque="" _raw_opaque=""
  if [ "$_raw_has" -eq 1 ] && [ "$_canon_has" -eq 1 ]; then
    _codex_doctor_opaque_for "$canon_hash"; _canon_opaque="$_CODEX_OPAQUE_OUT"
    _codex_doctor_opaque_for "$hash"; _raw_opaque="$_CODEX_OPAQUE_OUT"
  fi
  # Evaluate the canonical-spelling record first when it exists so the raw
  # hash's "no record" line never contradicts a record that is really there.
  if [ "$_canon_has" -eq 1 ]; then
    _codex_doctor_display "Codex app-server: a record set exists under this project's canonical spelling"
    _codex_doctor_eval_appserver "$canon_hash" 1 "$_canon_opaque"
    _canon_pid_state="$_CODEX_DOCTOR_EVAL_PID_STATE"
  fi
  if [ "$_raw_has" -eq 1 ] || [ "$_canon_has" -eq 0 ]; then
    if [ "$_canon_has" -eq 1 ]; then
      _codex_doctor_display "Codex app-server: record set under this project's registered spelling"
    fi
    _codex_doctor_eval_appserver "$hash" 1 "$_raw_opaque"
    _raw_pid_state="$_CODEX_DOCTOR_EVAL_PID_STATE"
  fi
  if [ "$_raw_pid_state" = "alive-confirmed" ] \
    && [ "$_canon_pid_state" = "alive-confirmed" ]; then
    _codex_doctor_warn codex_records_duplicate "" "" codex_app_server \
      "two app-server record sets (registered and canonical spellings) both hold live pids for this project — a duplicate server pair" ""
  fi
  # The "current" endpoint a bridge binding is compared against must come
  # from the record that evaluated live. With records under both spellings
  # and exactly one live record, that record's port is current; when neither
  # (or both) is live there is no single current endpoint — leaving the
  # comparison unknown beats comparing bridges against a stale spelling.
  local _sel=""
  if [ "$_raw_has" -eq 1 ] && [ "$_canon_has" -eq 1 ]; then
    local _raw_live=0 _canon_live=0
    case "$_raw_pid_state" in alive-confirmed|alive-unverified) _raw_live=1 ;; esac
    case "$_canon_pid_state" in alive-confirmed|alive-unverified) _canon_live=1 ;; esac
    if [ "$_raw_live" -eq 1 ] && [ "$_canon_live" -eq 0 ]; then
      _sel=raw
    elif [ "$_canon_live" -eq 1 ] && [ "$_raw_live" -eq 0 ]; then
      _sel=canon
    else
      _codex_doctor_display "Codex app-server endpoint: records under both spellings cannot be disambiguated — current endpoint unknown"
    fi
  elif [ "$_canon_has" -eq 1 ]; then
    _sel=canon
  else
    _sel=raw
  fi
  port_raw=""
  case "$_sel" in
    raw) port_raw="$(_codex_doctor_read_record "$RUN_DIR/codex-app-server.$hash.port")" ;;
    canon) port_raw="$(_codex_doctor_read_record "$RUN_DIR/codex-app-server.$canon_hash.port")" ;;
  esac
  _codex_doctor_pair_bindings "$project" "$port_raw"
  _codex_doctor_pair_locks "$project" "$hash" "$canon_hash"
  return 0
}

agmsg_doctor_extra_global_collect() {
  local type="$1"
  [ "$type" = "codex" ] || return 0
  _CODEX_DOCTOR_SCOPE_PROJECT=""
  _CODEX_DOCTOR_SCOPE_TYPE="$type"
  _CODEX_DOCTOR_DISPLAY_MODE="global"
  _codex_doctor_shim_check
  _codex_doctor_known_hashes
  # Pids claimed by every record file — known hashes included — so the
  # untracked-process scan below never flags a healthy tracked server.
  local recorded_pids="" _pf _rp
  for _pf in "$RUN_DIR"/codex-app-server.*.pid; do
    [ -f "$_pf" ] || continue
    _rp="$(_codex_doctor_read_record "$_pf")"
    [ -n "$_rp" ] && recorded_pids="${recorded_pids}${_rp}"$'\n'
  done
  # Hashes from every record kind, not just pidfiles: the monitor writes the
  # pid record first and every cleanup path removes pid/port/version
  # together, so a port/version record without a pid is never a normal
  # steady state — only a crash between writes or a partial manual cleanup
  # leaves one behind (humans do hand-edit these files when recovering from
  # a wedged Codex). The shared evaluator already reports that shape as an
  # incomplete state with a warning; it only needs enumerating here. The
  # .log sibling is deliberately excluded: the version-mismatch recreation
  # path keeps the log while replacing the triple, so a log-only leftover is
  # routine rotation, not evidence.
  # Bridge sidecars (.appserver/.thread) without a pidfile are likewise NOT
  # enumerated: codex-bridge.js removes pidfile+meta on every normal exit
  # while the launcher-owned sidecars wait to be overwritten, so that shape
  # is the ordinary post-TUI-close state — reporting it would warn on every
  # cleanly closed session with no actionable signal behind it.
  local recf base hash seen_hashes="" _opaque pair_union
  for recf in "$RUN_DIR"/codex-app-server.*.pid \
             "$RUN_DIR"/codex-app-server.*.port \
             "$RUN_DIR"/codex-app-server.*.version; do
    [ -f "$recf" ] || continue
    base="${recf##*/}"
    hash="${base#codex-app-server.}"
    hash="${hash%.*}"
    case "$hash" in ''|*/*|*.*) continue ;; esac
    case $'\n'"$seen_hashes"$'\n' in
      *$'\n'"$hash"$'\n'*) continue ;;
    esac
    seen_hashes="${seen_hashes}${hash}"$'\n'
    _codex_doctor_hash_known "$hash" && continue
    # P1-5/P1-6: raw hash を表示/evidence に出さず opaque instance へ変換
    # する。same hash → same opaque、distinct hash → distinct opaque。
    _codex_doctor_opaque_for "$hash"
    _opaque="$_CODEX_OPAQUE_OUT"
    _codex_doctor_display "Codex app-server record '$_opaque' matches no registered project (unknown — not attributed)"
    _codex_doctor_eval_appserver "$hash" 0 "$_opaque"
  done
  _codex_doctor_untracked_processes "$recorded_pids"
  pair_union="$(_codex_doctor_registered_pairs)"
  _codex_doctor_global_bindings "$pair_union"
  _codex_doctor_orphan_seats "$pair_union"
  return 0
}

# Legacy text-protocol wrappers (human compatibility for external callers
# still on agmsg_doctor_extra_status / agmsg_doctor_extra_global).
# doctor.sh itself uses the collectors above, never these. Each wrapper runs
# the matching collector into a scratch store and renders the old shapes
# (display lines verbatim, findings as "WARN: <evidence>"); judgments stay
# single-sourced in the shared evaluators.
_codex_doctor_legacy_render() {
  local findings_file="$1" display_file="$2" line
  local sep fcode fkind fcat fsproj fstype ftkind ftteam ftagent ftcomp fev fopaque
  sep="$(printf '\037')"
  while IFS="$sep" read -r fcode fkind fcat fsproj fstype ftkind ftteam ftagent ftcomp fev fopaque; do
    [ -n "$fcode" ] || continue
    printf 'WARN: %s\n' "$fev"
  done < "$findings_file"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    line="${line#*$sep}"; line="${line#*$sep}"
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
  done < "$display_file"
  return 0
}

agmsg_doctor_extra_status() {
  local type="$1" project="$2"
  [ "$type" = "codex" ] || return 0
  local _sv_findings="${_DOCTOR_FINDINGS_FILE:-}" _sv_display="${_DOCTOR_DISPLAY_FILE:-}"
  local _sv_comps="${_DOCTOR_COMPS_FILE:-}" _tmp
  _tmp="$(mktemp -d "${TMPDIR:-/tmp}/agmsg-codex-doctor.XXXXXX")"
  _DOCTOR_FINDINGS_FILE="$_tmp/findings.tsv"; : > "$_DOCTOR_FINDINGS_FILE"
  _DOCTOR_DISPLAY_FILE="$_tmp/display.tsv"; : > "$_DOCTOR_DISPLAY_FILE"
  _DOCTOR_COMPS_FILE="$_tmp/comps.tsv"; : > "$_DOCTOR_COMPS_FILE"
  agmsg_doctor_extra_collect "$type" "$project" 2>/dev/null
  _codex_doctor_legacy_render "$_DOCTOR_FINDINGS_FILE" "$_DOCTOR_DISPLAY_FILE"
  _DOCTOR_FINDINGS_FILE="$_sv_findings"; _DOCTOR_DISPLAY_FILE="$_sv_display"
  _DOCTOR_COMPS_FILE="$_sv_comps"
  rm -rf "$_tmp"
  return 0
}

agmsg_doctor_extra_global() {
  local type="$1"
  [ "$type" = "codex" ] || return 0
  local _sv_findings="${_DOCTOR_FINDINGS_FILE:-}" _sv_gdisplay="${_DOCTOR_GLOBAL_DISPLAY_FILE:-}"
  local _sv_comps="${_DOCTOR_COMPS_FILE:-}" _tmp
  _tmp="$(mktemp -d "${TMPDIR:-/tmp}/agmsg-codex-doctor.XXXXXX")"
  _DOCTOR_FINDINGS_FILE="$_tmp/findings.tsv"; : > "$_DOCTOR_FINDINGS_FILE"
  _DOCTOR_GLOBAL_DISPLAY_FILE="$_tmp/gdisplay.tsv"; : > "$_DOCTOR_GLOBAL_DISPLAY_FILE"
  _DOCTOR_COMPS_FILE="$_tmp/comps.tsv"; : > "$_DOCTOR_COMPS_FILE"
  agmsg_doctor_extra_global_collect "$type" 2>/dev/null
  _codex_doctor_legacy_render "$_DOCTOR_FINDINGS_FILE" "$_DOCTOR_GLOBAL_DISPLAY_FILE"
  _DOCTOR_FINDINGS_FILE="$_sv_findings"; _DOCTOR_GLOBAL_DISPLAY_FILE="$_sv_gdisplay"
  _DOCTOR_COMPS_FILE="$_sv_comps"
  rm -rf "$_tmp"
  return 0
}
