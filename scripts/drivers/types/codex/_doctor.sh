#!/usr/bin/env bash
# codex doctor plug — read-only app-server / bridge-binding diagnosis.
#
# Sourced by doctor.sh (never executed directly). Defines the two protocol
# entry points doctor.sh calls when this file exists:
#   agmsg_doctor_extra_status <type> <project>   per-(project, codex) records
#   agmsg_doctor_extra_global <type>             installation-wide leftovers
#
# Protocol: stdout is display lines quoted into the report; lines starting
# with "WARN: " become doctor warnings instead (the prefix is stripped).
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

# Per-run caches, kept in the sourcing shell (never inside a substitution).
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

# Current `codex --version` output, resolved once per doctor run through the
# same override the monitor honors. Empty when unreadable — every version
# verdict below treats that as "cannot tell", never as a mismatch.
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
# that names a project). Prints display lines and WARN: lines.
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
      echo "Codex app-server: no record for this project (never launched, or cleaned)"
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
    none) echo "Codex app-server: no pid record" ;;
    invalid) echo "Codex app-server: pid record invalid ('$pid_raw')" ;;
    dead) echo "Codex app-server: pid $pid_raw not running" ;;
    alive-confirmed) echo "Codex app-server: pid $pid_raw alive (Codex app-server cmdline confirmed)" ;;
    alive-unverified) echo "Codex app-server: pid $pid_raw alive (cmdline unreadable — ownership unverified)" ;;
    alive-foreign) echo "Codex app-server: pid $pid_raw alive but is not a Codex app-server (possible pid reuse)" ;;
  esac
  case "$ep_state" in
    none) echo "Codex app-server endpoint: no port record" ;;
    invalid) echo "Codex app-server endpoint: port record invalid ('$port_raw')" ;;
    silent) echo "Codex app-server endpoint: ${url} unresponsive" ;;
    responsive) echo "Codex app-server endpoint: ${url} answers (listener present — not proof of ownership)" ;;
  esac
  case "$ver_state" in
    unknown-record) echo "Codex app-server version: no version record (recreated on next monitor launch)" ;;
    unknown-current) echo "Codex app-server version: recorded '$ver_raw' (current version unreadable — check skipped)" ;;
    match) echo "Codex app-server version: '$ver_raw' (matches current)" ;;
    drift) echo "Codex app-server version: recorded '$ver_raw', current '$cur' (drift)" ;;
  esac
  if [ "$pid_state" = "alive-confirmed" ] && [ "$ep_state" = "responsive" ] && [ "$ver_state" = "match" ]; then
    echo "Codex app-server: healthy (pid $pid_raw, $url, version '$ver_raw')"
  fi

  # --- warnings: one independent rule per signal. Combined states surface as
  # several warnings, never as a single verdict that needs all of them.
  case "$pid_state" in
    invalid) echo "WARN: stale app-server pid record (invalid pid '$pid_raw')" ;;
    dead) echo "WARN: stale app-server pidfile (pid $pid_raw not running)" ;;
    alive-foreign) echo "WARN: app-server pid $pid_raw is alive but is not a Codex app-server (possible pid reuse); the record does not point at a live server" ;;
  esac
  if [ "$pid_state" = "none" ] && [ "$have_portf" -eq 1 ]; then
    echo "WARN: app-server endpoint record exists but the pid record is missing (incomplete state)"
  fi
  if [ "$ep_state" = "invalid" ]; then
    echo "WARN: stale app-server endpoint record (invalid port '$port_raw')"
  fi
  if [ "$ep_state" = "silent" ] && [ "$pid_state" = "alive-confirmed" ]; then
    echo "WARN: app-server process is alive (pid $pid_raw) but its endpoint is unresponsive ($url)"
  fi
  if [ "$ep_state" = "silent" ] && [ "$pid_state" != "alive-confirmed" ] && [ "$pid_state" != "alive-unverified" ]; then
    echo "WARN: app-server endpoint is unresponsive ($url)"
  fi
  if [ "$ep_state" = "responsive" ]; then
    case "$pid_state" in
      dead|none|invalid)
        echo "WARN: endpoint $url answers but no live recorded server owns it (another process may hold the port)"
        ;;
      alive-foreign)
        echo "WARN: endpoint $url answers but the recorded pid $pid_raw is not a Codex app-server (ownership unproven)"
        ;;
    esac
  fi
  if [ "$ver_state" = "drift" ]; then
    if [ "$attributed" -eq 1 ]; then
      echo "WARN: app-server version drift (recorded '$ver_raw', current '$cur'); relaunch Codex through the monitor to recreate the server"
    else
      echo "WARN: app-server version drift (recorded '$ver_raw', current '$cur'; owning project unknown)"
    fi
  fi
  # Deliberately silent: alive-unverified (ownership genuinely unknown),
  # unknown-record / unknown-current (cannot tell), and the no-record state
  # (a monitor-mode project that never launched is normal).
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
  echo "Codex bridge binding: $key $run_word, app-server=$url_verdict, thread=$thread_verdict"
  if [ -n "$bound_url" ] && [ "$url_verdict" != "unknown" ]; then
    echo "  bound app-server: $bound_url"
  fi

  if [ "$alive" -eq 0 ]; then
    if [ -f "$RUN_DIR/codex-bridge.$key.pid" ]; then
      echo "WARN: stale bridge pidfile ($key, pid '${bridge_pid:-empty}' not running)"
    fi
    return 0
  fi
  if [ "$url_verdict" = "mismatch" ]; then
    if [ -n "$current_url" ]; then
      echo "WARN: bridge $key is bound to a stale app-server (bound '$bound_url', current '$current_url')"
    else
      echo "WARN: bridge $key is alive but this project has no current app-server endpoint (bound '$bound_url')"
    fi
  fi
  if [ "$thread_verdict" = "mismatch" ]; then
    echo "WARN: bridge $key is bound to thread '$bound_thread' but the recorded seat is '$seat'"
  fi
  return 0
}

# Union of every registered codex (team, agent) pair, one "team<TAB>name"
# line each. The per-pair call attributes single-role bridge keys against its
# own project's pairs, so the global scan skips whatever this union holds —
# no cross-call state needed (doctor.sh invokes both entry points inside
# command substitutions, where assignments would be lost with the subshell).
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
    if [ -n "$bridge_pid" ] && _agmsg_pid_valid "$bridge_pid" 2>/dev/null \
      && _agmsg_pid_alive "$bridge_pid" 2>/dev/null; then
      bound_port=""
      case "$bound_url" in
        ws://127.0.0.1:*) bound_port="${bound_url##*:}" ;;
      esac
      if [ -n "$bound_port" ] && _codex_doctor_valid_port "$bound_port" \
        && ! _codex_doctor_port_alive "$bound_port"; then
        echo "Codex bridge binding: $key alive (pid $bridge_pid), bound endpoint $bound_url unresponsive"
        echo "WARN: bridge $key is alive but its bound endpoint is unresponsive ($bound_url)"
      elif [ -n "$bound_thread" ]; then
        seated="$(agmsg_role_session_recorded_uuids codex 2>/dev/null || true)"
        case $'\n'"$seated"$'\n' in
          *$'\n'"$bound_thread"$'\n'*) ;;
          *)
            echo "Codex bridge binding: $key alive (pid $bridge_pid), bound thread matches no recorded seat (ambiguous — not attributed)"
            ;;
        esac
      fi
    else
      echo "Codex bridge binding: $key not running (pid '${bridge_pid:-empty}')"
      echo "WARN: stale bridge pidfile ($key, pid '${bridge_pid:-empty}' not running)"
    fi
  done
  return 0
}

agmsg_doctor_extra_status() {
  local type="$1" project="$2"
  [ "$type" = "codex" ] || return 0
  local hash port_raw
  hash="$(printf '%s' "$project" | agmsg_sha1 2>/dev/null || true)"
  [ -n "$hash" ] || return 0
  _codex_doctor_eval_appserver "$hash" 1
  port_raw="$(_codex_doctor_read_record "$RUN_DIR/codex-app-server.$hash.port")"
  _codex_doctor_pair_bindings "$project" "$port_raw"
  return 0
}

agmsg_doctor_extra_global() {
  local type="$1"
  [ "$type" = "codex" ] || return 0
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
    echo "Codex app-server record '$short' matches no registered project (unknown — not attributed)"
    _codex_doctor_eval_appserver "$hash" 0
  done
  _codex_doctor_global_bindings
  return 0
}
