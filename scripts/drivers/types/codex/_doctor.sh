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

# agmsg_sha1 (lib/hash.sh) and the role-session readers are the helpers
# doctor.sh does not already load — liveness, cmdline, canonical paths, and
# the project registry all arrive via doctor.sh's own sources. Pure function
# definitions, so sourcing here is free of side effects.
if ! command -v agmsg_sha1 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/hash.sh"
fi
if ! command -v agmsg_role_session_load >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/role-session.sh"
fi

# Scope context for one collector run, set by the entry points below. The
# shared evaluators read these instead of taking scope arguments, so the
# per-pair and global paths cannot diverge in what they record.
_CODEX_DOCTOR_SCOPE_PROJECT=""
_CODEX_DOCTOR_SCOPE_TYPE=""
_CODEX_DOCTOR_DISPLAY_MODE="pair"

# One structured warning. $1 is the stable finding code (kind is always
# condition here; category runtime); $2/$3/$4 are the component target
# (team/agent empty for the scope-singleton app-server). Evidence wording is
# unchanged from the legacy WARN text -- human output stays byte-identical.
_codex_doctor_warn() {
  agmsg_doctor_finding_add "$1" condition runtime \
    "$_CODEX_DOCTOR_SCOPE_PROJECT" "$_CODEX_DOCTOR_SCOPE_TYPE" \
    component "$2" "$3" "$4" "$5"
}

# One component observation signal.
_codex_doctor_signal() {
  agmsg_doctor_component_signal \
    "$_CODEX_DOCTOR_SCOPE_PROJECT" "$_CODEX_DOCTOR_SCOPE_TYPE" \
    "$1" "$2" "$3" "$4" "$5"
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

# Evaluate one app-server record triple by project hash. $2 is 1 when the hash
# is attributed to a known project (per-pair call: relaunch advice applies)
# and 0 when it is not (global call: unknown/ambiguous framing, no advice
# that names a project). Registers display lines and structured findings
# through the collector helpers above.
_codex_doctor_eval_appserver() {
  local hash="$1" attributed="$2"
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
    case "$cmdline" in
      *codex*app-server*) pid_state="alive-confirmed" ;;
      *)
        if [ -z "$cmdline" ]; then
          pid_state="alive-unverified"
        else
          pid_state="alive-foreign"
        fi
        ;;
    esac
  fi

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
  _codex_doctor_signal codex_app_server "" "" process "$pid_state"
  _codex_doctor_signal codex_app_server "" "" endpoint "$ep_state"
  _codex_doctor_signal codex_app_server "" "" version "$ver_state"

  # --- warnings: one independent rule per signal. Combined states surface as
  # several warnings, never as a single verdict that needs all of them.
  case "$pid_state" in
    invalid) _codex_doctor_warn codex_pid_invalid "" "" codex_app_server "stale app-server pid record (invalid pid '$pid_raw')" ;;
    dead) _codex_doctor_warn codex_pid_stale "" "" codex_app_server "stale app-server pidfile (pid $pid_raw not running)" ;;
    alive-foreign) _codex_doctor_warn codex_pid_foreign "" "" codex_app_server "app-server pid $pid_raw is alive but is not a Codex app-server (possible pid reuse); the record does not point at a live server" ;;
  esac
  if [ "$pid_state" = "none" ] && [ "$have_portf" -eq 1 ]; then
    _codex_doctor_warn codex_records_incomplete "" "" codex_app_server "app-server endpoint record exists but the pid record is missing (incomplete state)"
  fi
  if [ "$pid_state" = "none" ] && [ "$have_portf" -eq 0 ] && [ "$have_verf" -eq 1 ]; then
    _codex_doctor_warn codex_records_incomplete "" "" codex_app_server "app-server version record exists but the pid and port records are missing (incomplete state)"
  fi
  # alive-confirmed with no port record but a version record present: the
  # monitor writes pid, then port, then version, in that order — a version
  # record already existing refutes "still starting up", so this leftover is
  # genuinely incomplete. Without the version record the same shape is an
  # ordinary startup race (pid written, port banner not yet parsed) and stays
  # silent below.
  if [ "$pid_state" = "alive-confirmed" ] && [ "$ep_state" = "none" ] && [ "$have_verf" -eq 1 ]; then
    _codex_doctor_warn codex_records_incomplete "" "" codex_app_server "app-server pid $pid_raw is alive but the port record is missing while a version record exists (incomplete state — not a startup race)"
  fi
  if [ "$ep_state" = "invalid" ]; then
    _codex_doctor_warn codex_endpoint_invalid "" "" codex_app_server "stale app-server endpoint record (invalid port '$port_raw')"
  fi
  if [ "$ep_state" = "silent" ] && [ "$pid_state" = "alive-confirmed" ]; then
    _codex_doctor_warn codex_endpoint_unresponsive "" "" codex_app_server "app-server process is alive (pid $pid_raw) but its endpoint is unresponsive ($url)"
  fi
  if [ "$ep_state" = "silent" ] && [ "$pid_state" != "alive-confirmed" ] && [ "$pid_state" != "alive-unverified" ]; then
    _codex_doctor_warn codex_endpoint_unresponsive "" "" codex_app_server "app-server endpoint is unresponsive ($url)"
  fi
  if [ "$ep_state" = "responsive" ]; then
    case "$pid_state" in
      dead|none|invalid)
        _codex_doctor_warn codex_endpoint_foreign "" "" codex_app_server "endpoint $url answers but no live recorded server owns it (another process may hold the port)"
        ;;
      alive-foreign)
        _codex_doctor_warn codex_endpoint_foreign "" "" codex_app_server "endpoint $url answers but the recorded pid $pid_raw is not a Codex app-server (ownership unproven)"
        ;;
    esac
  fi
  if [ "$ver_state" = "drift" ]; then
    if [ "$attributed" -eq 1 ]; then
      _codex_doctor_warn codex_version_drift "" "" codex_app_server "app-server version drift (recorded '$ver_raw', current '$cur'); relaunch Codex through the monitor to recreate the server"
    else
      _codex_doctor_warn codex_version_drift "" "" codex_app_server "app-server version drift (recorded '$ver_raw', current '$cur'; owning project unknown)"
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
# against one role's seat.
_codex_doctor_eval_binding() {
  local key="$1" bridge_pid="$2" bound_url="$3" bound_thread="$4"
  local current_url="$5" team="${6:-}" name="${7:-}"
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
  _codex_doctor_display "Codex bridge binding: $key $run_word, app-server=$url_verdict, thread=$thread_verdict"
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
  _codex_doctor_signal codex_bridge "$team" "$name" process "$_proc_sig"
  _codex_doctor_signal codex_bridge "$team" "$name" binding "$_bind_sig"
  _codex_doctor_signal codex_bridge "$team" "$name" seat "$_seat_sig"

  if [ "$alive" -eq 0 ]; then
    if [ -f "$RUN_DIR/codex-bridge.$key.pid" ]; then
      _codex_doctor_warn codex_bridge_stale_pidfile "$team" "$name" codex_bridge "stale bridge pidfile ($key, pid '${bridge_pid:-empty}' not running)"
    fi
    return 0
  fi
  if [ "$url_verdict" = "mismatch" ]; then
    if [ -n "$current_url" ]; then
      _codex_doctor_warn codex_bridge_stale_binding "$team" "$name" codex_bridge "bridge $key is bound to a stale app-server (bound '$bound_url', current '$current_url')"
    else
      _codex_doctor_warn codex_bridge_stale_binding "$team" "$name" codex_bridge "bridge $key is alive but this project has no current app-server endpoint (bound '$bound_url')"
    fi
  fi
  if [ "$thread_verdict" = "mismatch" ]; then
    _codex_doctor_warn codex_bridge_thread_mismatch "$team" "$name" codex_bridge "bridge $key is bound to thread '$bound_thread' but the recorded seat is '$seat'"
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
_codex_doctor_global_bindings() {
  local tab pair_union pidf key bridge_pid bound_url bound_thread bound_port seated
  tab="$(printf '\t')"
  pair_union="$(_codex_doctor_registered_pairs)"
  for pidf in "$RUN_DIR"/codex-bridge.*.pid; do
    [ -f "$pidf" ] || continue
    key="${pidf##*/codex-bridge.}"
    key="${key%.pid}"
    case "$key" in ''|*/*) continue ;; esac
    case $'\n'"$pair_union"$'\n' in
      *$'\n'"${key%%.*}${tab}${key#*.}"$'\n'*) continue ;;
    esac
    # Keys without launcher sidecars belong to delivery.sh's own per-role
    # verdicts (see the per-pair comment above) — judging them here too would
    # double-report.
    if [ ! -f "$RUN_DIR/codex-bridge.$key.appserver" ] && [ ! -f "$RUN_DIR/codex-bridge.$key.thread" ]; then
      continue
    fi
    bridge_pid="$(_codex_doctor_read_record "$pidf")"
    bound_url="$(_codex_doctor_read_record "$RUN_DIR/codex-bridge.$key.appserver")"
    bound_thread="$(_codex_doctor_read_record "$RUN_DIR/codex-bridge.$key.thread")"
    [ -n "$bound_thread" ] && agmsg_doctor_note_secret "$bound_thread"
    if [ -n "$bridge_pid" ] && _agmsg_pid_valid "$bridge_pid" 2>/dev/null \
      && _agmsg_pid_alive "$bridge_pid" 2>/dev/null; then
      bound_port=""
      case "$bound_url" in
        ws://127.0.0.1:*) bound_port="${bound_url##*:}" ;;
      esac
      if [ -n "$bound_port" ] && _codex_doctor_valid_port "$bound_port" \
        && ! _codex_doctor_port_alive "$bound_port"; then
        _codex_doctor_display "Codex bridge binding: $key alive (pid $bridge_pid), bound endpoint $bound_url unresponsive"
        _codex_doctor_warn codex_bridge_endpoint_unresponsive "" "" codex_bridge "bridge $key is alive but its bound endpoint is unresponsive ($bound_url)"
        _codex_doctor_signal codex_bridge "" "" process "running"
        _codex_doctor_signal codex_bridge "" "" endpoint "unresponsive"
        _codex_doctor_signal codex_bridge "" "" seat "unknown"
      elif [ -n "$bound_thread" ]; then
        seated="$(agmsg_role_session_recorded_uuids codex 2>/dev/null || true)"
        case $'\n'"$seated"$'\n' in
          *$'\n'"$bound_thread"$'\n'*)
            _codex_doctor_signal codex_bridge "" "" process "running"
            _codex_doctor_signal codex_bridge "" "" endpoint "unknown"
            _codex_doctor_signal codex_bridge "" "" seat "matched"
            ;;
          *)
            _codex_doctor_display "Codex bridge binding: $key alive (pid $bridge_pid), bound thread matches no recorded seat (ambiguous — not attributed)"
            _codex_doctor_signal codex_bridge "" "" process "running"
            _codex_doctor_signal codex_bridge "" "" endpoint "unknown"
            _codex_doctor_signal codex_bridge "" "" seat "unknown"
            ;;
        esac
      else
        _codex_doctor_signal codex_bridge "" "" process "running"
        _codex_doctor_signal codex_bridge "" "" endpoint "unknown"
        _codex_doctor_signal codex_bridge "" "" seat "unknown"
      fi
    else
      _codex_doctor_display "Codex bridge binding: $key not running (pid '${bridge_pid:-empty}')"
      _codex_doctor_warn codex_bridge_stale_pidfile "" "" codex_bridge "stale bridge pidfile ($key, pid '${bridge_pid:-empty}' not running)"
      _codex_doctor_signal codex_bridge "" "" process "not-running"
      _codex_doctor_signal codex_bridge "" "" endpoint "unknown"
      _codex_doctor_signal codex_bridge "" "" seat "unknown"
    fi
  done
  return 0
}

agmsg_doctor_extra_collect() {
  local type="$1" project="$2"
  [ "$type" = "codex" ] || return 0
  _CODEX_DOCTOR_SCOPE_PROJECT="$project"
  _CODEX_DOCTOR_SCOPE_TYPE="$type"
  _CODEX_DOCTOR_DISPLAY_MODE="pair"
  local hash port_raw
  hash="$(printf '%s' "$project" | agmsg_sha1 2>/dev/null || true)"
  [ -n "$hash" ] || return 0
  _codex_doctor_eval_appserver "$hash" 1
  port_raw="$(_codex_doctor_read_record "$RUN_DIR/codex-app-server.$hash.port")"
  _codex_doctor_pair_bindings "$project" "$port_raw"
  return 0
}

agmsg_doctor_extra_global_collect() {
  local type="$1"
  [ "$type" = "codex" ] || return 0
  _CODEX_DOCTOR_SCOPE_PROJECT=""
  _CODEX_DOCTOR_SCOPE_TYPE="$type"
  _CODEX_DOCTOR_DISPLAY_MODE="global"
  _codex_doctor_known_hashes
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
  local recf base hash short seen_hashes=""
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
    short="$hash"
    if [ "${#short}" -gt 12 ]; then short="${short:0:12}…"; fi
    _codex_doctor_display "Codex app-server record '$short' matches no registered project (unknown — not attributed)"
    _codex_doctor_eval_appserver "$hash" 0
  done
  _codex_doctor_global_bindings
  return 0
}

# Legacy text-protocol wrappers (human compatibility for external callers
# still on agmsg_doctor_extra_status / agmsg_doctor_extra_global).
# doctor.sh itself uses the collectors above, never these. Each wrapper runs
# the matching collector into a scratch store and renders the old shapes
# (display lines verbatim, findings as "WARN: <evidence>"); judgments stay
# single-sourced in the shared evaluators.
_codex_doctor_legacy_render() {
  local findings_file="$1" display_file="$2" line i
  local sep
  sep="$(printf '\037')"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    for ((i = 0; i < 9; i++)); do line="${line#*$sep}"; done
    printf 'WARN: %s\n' "$line"
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
