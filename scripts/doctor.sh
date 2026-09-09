#!/usr/bin/env bash
set -euo pipefail

# doctor.sh — "who holds what" in one screen. #267/#605.
#
# Usage: doctor.sh [--project <path>] [--type <type>] [--team <team>] [--redacted] [--json]
#        doctor.sh --help
#
# --json emits the same diagnosis as a single machine-readable JSON payload
# on stdout (Issue #8, schema_version 1 -- see docs/building-on-agmsg.md).
# The JSON and the human-readable report are drawn from the same structured
# observations / findings collected during the scan; the JSON path never
# parses human warning text back into codes.
#
# Default (no filters): the whole installation -- every team, every project,
# every type. --project / --type / --team narrow it and combine freely. This
# matches how claude/codex/brew/flutter doctor all behave (no scope argument,
# default to everything) rather than requiring a cross-section up front --
# koit's call, made explicit because the earlier <project> <type>-required
# form had it backwards: a reporter who doesn't already know which project/type
# to name can't use a doctor that demands one. Positional <project> <type> is
# not kept for compatibility -- koit judged it not worth carrying (see PR/report
# history for round 2), and a stale positional form alongside flags that mean
# something different by default would be its own source of confusion.
#
# Argument parsing is kept separate from scope-building (the SCOPE loop
# below) so that a future change to what the flags are doesn't have to touch
# how a scope, once decided, gets turned into (project, type) pairs.
#
# Read-only: never claims, releases, or removes a lock, pidfile, or
# registration. A stale lock or dead pidfile is reported, not cleaned up --
# #605's reporter was asked not to remove a lock by hand because it erases
# the evidence; a doctor that cleaned up would do the same thing to itself.
#
# Data sources are the existing helpers this project already has for each
# fact -- identities.sh for registrations, actas-lock.sh/instance-id.sh for
# lock ownership and liveness, delivery.sh for mode and watcher/bridge
# status, agmsg_registered_projects for cross-project/cross-type discovery.
# Nothing here recomputes a verdict those already reach; #605's diagnostic
# duplicated agmsg_instance_alive once and that duplication was exactly
# what review pushed back on.
#
# Type-specific extras live in scripts/drivers/types/<type>/_doctor.sh when
# present (codex app-server / bridge-binding state, #5). The per-pair and
# global hook protocol is documented at the call sites below; plugs are
# read-only by contract and reuse the helpers above instead of recomputing
# verdicts.
#
# Exit codes:
#   0  no warnings
#   1  one or more warnings (see WARNINGS section)
#   2  usage or resolution error

_usage() {
  echo "Usage: doctor.sh [--project <path>] [--type <type>] [--team <team>] [--redacted] [--json]" >&2
  echo "       doctor.sh --help" >&2
  echo "  --json: print a single machine-readable JSON payload (schema_version 1) on" >&2
  echo "          stdout and nothing else; rc 2 errors stay human text on stderr." >&2
}

# Scanned for --help before anything else is parsed, same reasoning as
# before: a validation error on some other flag must never suppress --help.
for _arg in "${@:-}"; do
  case "$_arg" in
    -h|--help) _usage; exit 0 ;;
  esac
done
unset _arg

# --- argument parsing: produces FILTER_PROJECT / FILTER_TYPE / FILTER_TEAM /
#     REDACTED only. Deliberately does not decide what a scope IS -- that is
#     entirely the SCOPE-building block below, so a future flag change stays
#     a parsing-only change. No positional arguments are accepted -- any
#     bare token is a usage error. -----------------------------------------
REDACTED=0
JSON_MODE=0
FILTER_PROJECT="" FILTER_TYPE="" FILTER_TEAM=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      case "${2:-}" in ''|-*) echo "doctor: --project requires a value" >&2; exit 2 ;; esac
      FILTER_PROJECT="$2"; shift 2 ;;
    --type)
      case "${2:-}" in ''|-*) echo "doctor: --type requires a value" >&2; exit 2 ;; esac
      FILTER_TYPE="$2"; shift 2 ;;
    --team)
      case "${2:-}" in ''|-*) echo "doctor: --team requires a value" >&2; exit 2 ;; esac
      FILTER_TEAM="$2"; shift 2 ;;
    --redacted) REDACTED=1; shift ;;
    --json) JSON_MODE=1; shift ;;
    -*) echo "doctor: unknown option: $1" >&2; exit 2 ;;
    *) echo "doctor: unexpected argument: '$1' (doctor takes flags only -- see --help)" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/type-registry.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/validate.sh"
# Shared structured delivery evaluator (P1-4): doctor は human text を parse
# せず、この evaluator を直接呼ぶ。human renderer も同一 evaluator から
# 描画するため wording 変更では machine JSON は壊れない。
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/delivery-eval.sh"

# --- fatal-error boundary for --json (P1-2) --------------------------------
# JSON mode では scan 全体を明示的な boundary で保護する: unexpected
# internal/setup 失敗は rc2・stdout 空・stderr concise へ正規化する。
# 個別に `|| true` を増やして silent degradation させない。
_doctor_fatal() {
  printf 'doctor: %s\n' "${1:-internal failure during machine-readable scan}" >&2
  exit 2
}
_doctor_json_err_trap() {
  printf 'doctor: internal failure during machine-readable scan\n' >&2
  exit 2
}
if [ "$JSON_MODE" -eq 1 ]; then
  # ERR trap を functions/command substitutions/subshells へ継承させる
  # (errtrace)。mktemp/store write 等の $(...) 内失敗も rc2 へ正規化する
  # ため。`||` で明示処理した per-scope partial (diagnostic_failure) は
  # trap を発火させない。
  set -E
  trap '_doctor_json_err_trap' ERR
fi

# --json is serialized by a Python helper (escaping / schema shaping live
# there, not in Bash string concatenation -- the same split team-list.sh /
# scripts/internal/team-list.py already uses). A missing python3 means no
# authoritative report can be produced, so this is a resolution-class error
# (exit 2, stdout empty, human text on stderr), never a degraded JSON run.
if [ "$JSON_MODE" -eq 1 ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/lib/require-python3.sh"
  agmsg_require_python3 "doctor --json" || exit 2
fi

# --project / --type / --team all validated here, before any scope work:
# an unknown --type or --team is a usage error (exit 2), not left to fail
# quietly into an empty scope -- same "no silent empty-looks-clean report"
# reasoning as the original <project> <type> form's type check. An unknown
# --project has no fixed enum to check against; it falls through to the
# generic "no registrations match this scope" exit 2 below instead, which
# reaches the same exit code by the same means every other empty scope does.
if [ -n "$FILTER_TYPE" ] && ! agmsg_is_known_type "$FILTER_TYPE"; then
  echo "doctor: unknown agent type: '$FILTER_TYPE' (supported: $(agmsg_known_types | sort -u | paste -sd, - | sed 's/,/, /g'))" >&2
  exit 2
fi
if [ -n "$FILTER_TEAM" ]; then
  # --team becomes a path segment below (teams/$FILTER_TEAM/config.json,
  # both here and inside agmsg_registered_projects) whether or not it turns
  # out to name a real team -- validate.sh's header names every entry point
  # that does this ("join.sh, leave.sh, team.sh, rename.sh, rename-team.sh")
  # for exactly this reason: an unvalidated value containing "..", "/", or
  # similar can resolve to a config-shaped file outside teams/ entirely. This
  # is doctor.sh's first --team-shaped entry point, so it needs the same
  # validator every other one already runs through -- not a new check, just
  # this file failing to call the existing one. Runs BEFORE the existence
  # check below: a value validate.sh rejects should never even reach a
  # filesystem lookup.
  agmsg_validate_team_name "$FILTER_TEAM" || exit 2
  if [ ! -f "$SKILL_DIR/teams/$FILTER_TEAM/config.json" ]; then
    echo "doctor: unknown team: '$FILTER_TEAM'" >&2
    exit 2
  fi
fi

# Keep only the "<team>\t<agent>" lines belonging to FILTER_TEAM. A no-op
# (prints input unchanged) when no --team was given. Needed in two places:
# narrowing a (project, type) pair's own registration rows to just the
# requested team, and (identically) deciding whether that team has ANY
# registration at a candidate pair while building SCOPE below.
_team_filter_lines() {
  local input="$1" team="$2" t a
  [ -n "$team" ] || { printf '%s' "$input"; return 0; }
  while IFS=$'\t' read -r t a; do
    [ -z "$t" ] && continue
    [ "$t" = "$team" ] && printf '%s\t%s\n' "$t" "$a"
  done <<< "$input"
  # A while loop's own exit status is whatever its LAST executed command
  # left behind -- here, "[ "$t" = "$team" ] && printf ...", whose short-
  # circuiting means a NON-matching final input line leaves exit 1, even
  # though filtering out a non-match is completely normal. Every caller of
  # this function assigns its output via a bare command substitution (no
  # `|| true`), so under set -e that leaked 1 aborted the whole script --
  # silently, with no output at all, whenever --team's target sorted before
  # some other team on the LAST row of a pair's registrations (identities.sh
  # orders by team name, so this depended on which teams happened to share a
  # project/type and how their names compared). Found by running --team
  # against the real installation, where this ordering wasn't in this
  # branch's favor. return 0 makes "ran to completion, matched or not" the
  # function's actual contract, matching what every caller already assumes.
  return 0
}

# --- scope: build the (project, type) pairs to scan --------------------
#
# One output format regardless of which filters were given: newline-separated
# "project<TAB>type". Everything downstream just iterates this list -- the
# per-pair judgment logic (_doctor_scan_pair) is identical regardless of how
# the list was built.
SCOPE=""

while IFS= read -r _type; do
  [ -n "$_type" ] || continue
  if [ -n "$FILTER_PROJECT" ]; then
    # --project given: no single resolve call applies without a type, so this
    # loops it across every type being scanned (all known types, or just
    # FILTER_TYPE), exactly as identities.sh is then used to confirm a real
    # registration exists there. (An earlier version tried to match the input
    # against agmsg_registered_projects by canonicalizing both sides -- wrong
    # on macOS, where agmsg_canonical_path resolves the /var -> /private/var
    # symlink but the registry stores whatever raw path join.sh was given, so
    # a real registration never matched. agmsg_resolve_project already gets
    # this right per type; reusing it here sidesteps reinventing that
    # matching a second time.) FILTER_TEAM, if given, scopes both the
    # resolution's registry fallback AND which registration counts as a hit.
    _resolved="$(agmsg_resolve_project "$FILTER_PROJECT" "$_type" "$FILTER_TEAM")"
    _hit="$("$SCRIPT_DIR/identities.sh" "$_resolved" "$_type")"
    _hit="$(_team_filter_lines "$_hit" "$FILTER_TEAM")"
    if [ -n "$_hit" ]; then
      SCOPE="${SCOPE}${_resolved}"$'\t'"${_type}"$'\n'
    fi
  else
    # No --project: every project registered for this type (agmsg_registered_projects's
    # own team param does the --team narrowing here, at the source, rather than
    # listing everyone's projects and filtering after). sort -u because
    # agmsg_registered_projects dedups WITHIN one team's config.json via SQL
    # DISTINCT, but concatenates every scanned team's config.json results with
    # no cross-file dedup -- a project registered under two different teams (a
    # real shape: two teams sharing one workspace) comes back twice when no
    # --team narrows it to one file, and without sort -u here that turns into
    # the same (project, type) pair scanned and reported twice, with summary
    # counts inflated to match. Confirmed by direct inspection of its raw
    # output before this fix landed.
    while IFS= read -r _proj; do
      [ -n "$_proj" ] || continue
      SCOPE="${SCOPE}${_proj}"$'\t'"${_type}"$'\n'
    done <<< "$(agmsg_registered_projects "$_type" "$FILTER_TEAM" | sort -u)"
  fi
done <<< "$(if [ -n "$FILTER_TYPE" ]; then printf '%s\n' "$FILTER_TYPE"; else agmsg_known_types | sort -u; fi)"
unset _type _proj _resolved _hit

# An empty SCOPE means two different things depending on whether a filter
# narrowed it: an EXPLICIT --project/--type/--team that matched nothing is
# almost certainly a mistake (a typo'd project path, a team that doesn't
# exist) -- exit 2, as before. But no filters at all, on an installation
# that genuinely has zero registrations anywhere, is a VALID whole-install
# scan whose answer happens to be empty -- that is not a usage error, and
# treating it as one meant "diagnose an empty installation" itself failed
# doctor's own exit-code contract. Falls through to the normal report path
# below, which -- with SCOPE empty -- naturally produces a clean "0 team(s),
# 0 registration(s), 0 warning(s)" / "no warnings." / exit 0 with no special
# casing needed there.
if [ -z "$SCOPE" ] && { [ -n "$FILTER_PROJECT" ] || [ -n "$FILTER_TYPE" ] || [ -n "$FILTER_TEAM" ]; }; then
  echo "doctor: no registrations match this scope" >&2
  exit 2
fi

WARNINGS=""
_warn() { WARNINGS="${WARNINGS}$1"$'\n'; }

# --- redaction: consistent pseudonyms, not one-off masking -----------------
#
# One pseudonym table for the WHOLE run, not per (project, type) pair: with
# --all spanning multiple projects, the same team/agent appearing under two
# different projects has to read as the same pseudonym both times, or the
# output stops being cross-referenceable against itself.
#
# A fixed team1/agent1 substitution (not a hash) so the same name reads the
# same way everywhere it appears in one run -- the #605 reporter hand-redacted
# their own report exactly this way (generic team/agent names, home-relative
# project path); this does the same substitution instead of leaving it to
# whoever pastes the output into a bug report.
# Sets _REDACT_OUT in the CALLER's shell rather than printf+$(...): a pair
# assigned inside a command substitution is a subshell, and the whole point
# here is a mutation (_R_TEAM_K/_R_TEAM_V growing) that has to survive past
# the call. role-session.sh's _agmsg_role_session_path_into hit this same
# shape first -- "a cache entry is only kept when the helper runs in the
# caller's own shell" applies just as much to a pseudonym table as a memo.
_R_TEAM_K=(); _R_TEAM_V=(); _R_AGENT_K=(); _R_AGENT_V=()
_redact_team() {
  [ "$REDACTED" = 1 ] || { _REDACT_OUT="$1"; return 0; }
  local i n=${#_R_TEAM_K[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${_R_TEAM_K[$i]}" = "$1" ]; then _REDACT_OUT="${_R_TEAM_V[$i]}"; return 0; fi
  done
  _R_TEAM_K[$n]="$1"; _R_TEAM_V[$n]="team$((n + 1))"
  _REDACT_OUT="${_R_TEAM_V[$n]}"
}
_redact_agent() {
  [ "$REDACTED" = 1 ] || { _REDACT_OUT="$1"; return 0; }
  local i n=${#_R_AGENT_K[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${_R_AGENT_K[$i]}" = "$1" ]; then _REDACT_OUT="${_R_AGENT_V[$i]}"; return 0; fi
  done
  _R_AGENT_K[$n]="$1"; _R_AGENT_V[$n]="agent$((n + 1))"
  _REDACT_OUT="${_R_AGENT_V[$n]}"
}
# Same idea for project paths as team/agent above: one table for the whole
# run, so the same project reads as the same pseudonym in every (project,
# type) block it appears in under --all, not a fresh placeholder each time.
_R_PROJ_K=(); _R_PROJ_V=()
_redact_project() {
  [ "$REDACTED" = 1 ] || { _REDACT_OUT="$1"; return 0; }
  case "$1" in
    "$HOME"*) _REDACT_OUT="~${1#"$HOME"}"; return 0 ;;
  esac
  local i n=${#_R_PROJ_K[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${_R_PROJ_K[$i]}" = "$1" ]; then _REDACT_OUT="${_R_PROJ_V[$i]}"; return 0; fi
  done
  _R_PROJ_K[$n]="$1"; _R_PROJ_V[$n]="<project$((n + 1))>"
  _REDACT_OUT="${_R_PROJ_V[$n]}"
}
# Plain output shows the owner token IN FULL -- #605 was actually resolved by
# matching this exact value against a "codex-bridge: resumed thread <uuid>"
# line in a bridge log, and a shortened token can't be matched that way. This
# only shortens under --redacted, where the point is the opposite (safe to
# paste), and even then splits on the LAST "." rather than a fixed tail
# length: a fixed suffix cuts at a different point depending on how long the
# leading uuid/sid happens to be, while the part after the last "." is the
# pid every composite token carries -- consistently shaped, and still useful
# on its own (`ps -p <pid>`) even with the rest hidden. A bare token (no ".")
# has no such split point, so that case keeps the old fixed-tail form.
_redact_owner() {
  [ "$REDACTED" = 1 ] || { printf '%s' "$1"; return 0; }
  [ -n "$1" ] || return 0
  if agmsg_instance_is_composite "$1"; then
    printf '...%s' "${1##*.}"
  else
    printf '...%s' "${1: -6}"
  fi
}
# Literal (not glob, not regex) substring replace. A quoted portion of a
# case/parameter-expansion pattern matches literally regardless of what it
# contains, so this needs no escaping for team/agent names or paths that
# happen to hold *, ?, [, or other glob/regex metacharacters. Portable to
# bash 3.2 (macOS).
_replace_literal() {
  local rest="$1" needle="$2" repl="$3" out=""
  [ -n "$needle" ] || { printf '%s' "$rest"; return 0; }
  while true; do
    case "$rest" in
      *"$needle"*)
        out="$out${rest%%"$needle"*}$repl"
        rest="${rest#*"$needle"}"
        ;;
      *) break ;;
    esac
  done
  printf '%s%s' "$out" "$rest"
}
# Applies the SAME substitutions as the fields above to a block of TEXT this
# script did not format itself (delivery.sh's own output) -- --redacted's
# only promise is "safe to paste", so text quoted wholesale from elsewhere
# has to go through the same pseudonym table and $HOME masking as everything
# doctor.sh builds by hand, not get echoed as-is. Takes the CURRENT pair's
# resolved project explicitly (not a global) -- under --all this runs once
# per (project, type) block, each with a different project.
#
# No word boundaries: a team/agent name that also occurs as a substring
# elsewhere in the text (e.g. a team named "agmsg" inside a path like
# ~/.agents/skills/agmsg/run/...) gets replaced there too. Deliberately not
# fixed -- the failure direction is over-redaction, not a leak, which is the
# side --redacted is supposed to fail on.
_redact_text() {
  local text="$1" project="$2" i n
  [ "$REDACTED" = 1 ] || { printf '%s' "$text"; return 0; }
  text="$(_replace_literal "$text" "$HOME" "~")"
  # A project outside $HOME survives the substitution above untouched (no
  # $HOME prefix to catch), and delivery.sh's own output names it directly
  # (its settings-hooks-file path is under it) -- so the exact resolved path
  # is masked here too, the same pseudonym _redact_project produces for it.
  # Skipped for installation-wide text with no project: masking an empty
  # needle is a no-op but registering it would consume a <projectN> number.
  if [ -n "$project" ]; then
    _redact_project "$project"
    text="$(_replace_literal "$text" "$project" "$_REDACT_OUT")"
  fi
  n=${#_R_TEAM_K[@]}
  for ((i = 0; i < n; i++)); do
    text="$(_replace_literal "$text" "${_R_TEAM_K[$i]}" "${_R_TEAM_V[$i]}")"
  done
  n=${#_R_AGENT_K[@]}
  for ((i = 0; i < n; i++)); do
    text="$(_replace_literal "$text" "${_R_AGENT_K[$i]}" "${_R_AGENT_V[$i]}")"
  done
  n=${#_R_SECRET_K[@]}
  for ((i = 0; i < n; i++)); do
    text="$(_replace_literal "$text" "${_R_SECRET_K[$i]}" "${_R_SECRET_V[$i]}")"
  done
  # Global opaque keys (P1-5 defense in depth): raw orphan hash / bridge key
  # が evidence/display へ混入しても --redacted では opaque へ置換する。
  # 通常は plug が事前に opaque 化するためこの置換は no-op である。
  n=${#_R_GLOBAL_K[@]}
  for ((i = 0; i < n; i++)); do
    text="$(_replace_literal "$text" "${_R_GLOBAL_K[$i]}" "${_R_GLOBAL_V[$i]}")"
  done
  printf '%s' "$text"
}

# Session-like identifiers (bridge bound-thread / recorded-seat uuids, etc.)
# are neither team/agent names nor paths, so the tables above never catch
# them -- but --redacted promises paste-safe output including evidence. A
# plug registers such values via agmsg_doctor_note_secret; they are then
# masked everywhere _redact_text runs (human blocks and JSON evidence alike)
# under the same "same raw value, same pseudonym, one table per run" rule.
# No-op unless --redacted (and unless anything was registered), so plain
# output keeps the full values a human needs to match against logs.
_R_SECRET_K=(); _R_SECRET_V=()
agmsg_doctor_note_secret() {
  [ "$REDACTED" = 1 ] || return 0
  [ -n "${1:-}" ] || return 0
  local i n=${#_R_SECRET_K[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${_R_SECRET_K[$i]}" = "$1" ]; then return 0; fi
  done
  _R_SECRET_K[$n]="$1"; _R_SECRET_V[$n]="session$((n + 1))"
}

# Global opaque instance pseudonyms (P1-5/P1-6): orphan app-server hash や
# unattributed bridge key のような、current registration の redaction table
# に存在しない raw 識別子を human evidence へ入れる前に paste-safe opaque
# へ変換する。filename 由来文字列を「必ず team.agent」と仮定しない。
# 同一 invocation では same raw → same pseudonym を保証する。--redacted の
# 有無にかかわらず常に opaque 化する (raw PID/hash/URL/socket/path を
# structured field に出さない契約のため)。
_R_GLOBAL_K=(); _R_GLOBAL_V=()
_doctor_global_pseudonym() {
  # $1: raw key (hash / bridge key 等)。_GLOBAL_OUT に opaque ID を設定。
  local raw="${1:-}" i n=${#_R_GLOBAL_K[@]}
  [ -n "$raw" ] || { _GLOBAL_OUT=""; return 0; }
  for ((i = 0; i < n; i++)); do
    if [ "${_R_GLOBAL_K[$i]}" = "$raw" ]; then _GLOBAL_OUT="${_R_GLOBAL_V[$i]}"; return 0; fi
  done
  _R_GLOBAL_K[$n]="$raw"; _R_GLOBAL_V[$n]="global_instance$((n + 1))"
  _GLOBAL_OUT="${_R_GLOBAL_V[$n]}"
}

# --- structured diagnostics store (Issue #8) --------------------------------
#
# Observations and findings are the PRIMARY record of a scan: every warning
# below registers a structured finding (stable code, kind, category, scope,
# target, evidence) at the same site that builds the human line, and the
# human "warnings:" section plus the --json payload are both drawn from that
# store. Nothing here parses a WARN string back into a code -- the code is
# assigned once, where the condition is observed.
#
# Storage is one record file per kind inside a per-run temp dir (portable
# to bash 3.2 -- no associative arrays), with \037 (ASCII unit separator)
# as the field separator: it is not IFS whitespace, so `read` preserves
# empty fields (which TAB cannot do), and unlike \001 it is honored as an
# IFS delimiter by bash 3.2's read builtin. The Python serializer does all
# JSON escaping, so quotes / backslashes / }] in paths or evidence can never
# break the payload. All values are written post-redaction (the same tables
# above), so the serializer never sees a raw value and --redacted --json
# cannot leak one. Global opaque instance IDs (P1-5/P1-6) travel as an
# explicit trailing field, never as raw PID/hash/URL/socket/path.
_DOCTOR_TMP=""; _DOCTOR_SCOPES_FILE=""; _DOCTOR_REGS_FILE=""
_DOCTOR_COMPS_FILE=""; _DOCTOR_FINDINGS_FILE=""
_DOCTOR_DISPLAY_FILE=""; _DOCTOR_GLOBAL_DISPLAY_FILE=""
_doctor_store_init() {
  _DOCTOR_TMP="$(mktemp -d "${TMPDIR:-/tmp}/agmsg-doctor.XXXXXX")"
  _DOCTOR_SCOPES_FILE="$_DOCTOR_TMP/scopes.tsv"
  _DOCTOR_REGS_FILE="$_DOCTOR_TMP/regs.tsv"
  _DOCTOR_COMPS_FILE="$_DOCTOR_TMP/comps.tsv"
  _DOCTOR_FINDINGS_FILE="$_DOCTOR_TMP/findings.tsv"
  _DOCTOR_DISPLAY_FILE="$_DOCTOR_TMP/display.tsv"
  _DOCTOR_GLOBAL_DISPLAY_FILE="$_DOCTOR_TMP/global_display.tsv"
  # 各 write を明示的に fatal 化する: collector は `|| rc=$?` で呼ばれる
  # ため Bash 3.2 では内側の set -e / ERR trap が信頼できず、裸の write
  # 失敗は false healthy (rc0/record missing) になり得る。
  : > "$_DOCTOR_SCOPES_FILE" || _doctor_fatal "failed to init scan store"
  : > "$_DOCTOR_REGS_FILE" || _doctor_fatal "failed to init scan store"
  : > "$_DOCTOR_COMPS_FILE" || _doctor_fatal "failed to init scan store"
  : > "$_DOCTOR_FINDINGS_FILE" || _doctor_fatal "failed to init scan store"
  : > "$_DOCTOR_DISPLAY_FILE" || _doctor_fatal "failed to init scan store"
  : > "$_DOCTOR_GLOBAL_DISPLAY_FILE" || _doctor_fatal "failed to init scan store"
}
# Control-char singletons ($'...' は command substitution と異なり末尾改行
# strip が起きない。$(printf '\n') は空文字になるため *""* が全値に match
# する事故を起こす。bash 3.2 の ANSI-C quoting で定義する)。
TAB_CHAR=$'\t'
LF_CHAR=$'\n'
CR_CHAR=$'\r'
US_CHAR=$'\037'
X01_CHAR=$'\001'
# Input-boundary validation (P2): control characters are rejected, never
# lossily flattened. TAB/newline/CR/unit-separator in any store field would
# either break TSV framing (newline splits rows) or collide distinct raw
# values into one representation (TAB→space). Stable ABI 前のため今回直す:
# identifier/scope field は rc2 fail-closed、evidence も同一境界で reject
# する (human free text でも複数行 evidence は store 行を壊すため)。
# _doctor_fatal で直接 exit 2 する (set -e + ERR trap だけに頼らない):
# plug collector は `|| _plug_collector_rc=$?` で呼ばれるため、その内側では
# set -e が無効化され、bare な return 1 では fail-closed にならず空 evidence
# 化して silent 継続してしまう。呼び側は `|| true` で握り潰さないこと。
_doctor_flat() {
  local _v="${1:-}"
  case "$_v" in
    *"$TAB_CHAR"*|*"$LF_CHAR"*|*"$CR_CHAR"*|*"$US_CHAR"*|*"$X01_CHAR"*)
      printf 'doctor: rejected control character in store field\n' >&2
      _doctor_fatal "rejected control character in store field"
      ;;
  esac
  _FLAT_OUT="$_v"
}
# Raw control-char validation (P2 ordering): redaction や command
# substitution の前に RAW 値へかける。$() は末尾 newline を削除し、
# redaction は raw を pseudonym へ置換して control char を隠すため、
# 変換後の検査だけでは trailing newline の消失と redacted 時のすり抜けを
# 検出できない。正しい順序は RAW validation → redaction → post 検証 →
# store write である。全 store-bound 値の redaction/$() より前に呼ぶこと。
_doctor_validate_raw_field() {
  local _v="${1:-}"
  case "$_v" in
    *"$TAB_CHAR"*|*"$LF_CHAR"*|*"$CR_CHAR"*|*"$US_CHAR"*|*"$X01_CHAR"*)
      printf 'doctor: rejected control character in store field\n' >&2
      _doctor_fatal "rejected control character in store field"
      ;;
  esac
}
# Scope finding codes (core doctor warnings):
#   lock_stale                    stale actas lock (condition/messaging, registration target)
#   lock_no_watcher               live lock with no watcher pidfile (condition/messaging, registration)
#   turn_mode_multi_registration  >1 registration under turn/both delivery (condition/messaging, scope target)
#   watcher_stale_pidfile         stale watcher/bridge pidfile, per-pair (condition/runtime, scope target)
#   delivery_status_failed        delivery evaluation itself failed, scoped or global (diagnostic_failure/runtime)
#   watcher_stale_pidfile_global  stale watcher pidfile, installation-wide (condition/runtime, global)
#   legacy_plug_unstructured      type plug without structured collectors (diagnostic_failure/unknown)
#   plug_collector_failed         structured collector exited nonzero, or plug source failed (diagnostic_failure/unknown)
#   scan_failed                   per-scope identities/helper lookup failed (diagnostic_failure/unknown)
#
# _doctor_warn <code> <kind> <category> <scope_project_raw> <scope_type>
#              <target_kind> <target_team_raw> <target_agent_raw> <target_component>
#              -- <human warning line, already built>
# Appends the human line to WARNINGS (unchanged rendering) AND a structured
# record to the store. target_kind is "registration", "component", or ""
# (scope/global target, serialized as null). Evidence is the human line minus
# a leading "[...] " scope prefix, passed through _redact_text so secrets
# registered after the line was built are still masked. Core warnings never
# carry an opaque instance (empty trailing field).
_doctor_warn() {
  local code="$1" kind="$2" category="$3" sproj="$4" stype="$5"
  local tkind="$6" tteam="$7" tagent="$8" tcomp="$9"
  shift 9
  case "${1:-}" in --) shift ;; esac
  local human="$1" dproj="" dteam="" dagent="" evidence=""
  # RAW validation first: redaction/$() の前に検査する ($() は末尾 newline
  # を削除し、redaction は raw を pseudonym へ置換して control char を隠す)。
  _doctor_validate_raw_field "$code"; _doctor_validate_raw_field "$kind"
  _doctor_validate_raw_field "$category"; _doctor_validate_raw_field "$sproj"
  _doctor_validate_raw_field "$stype"; _doctor_validate_raw_field "$tkind"
  _doctor_validate_raw_field "$tteam"; _doctor_validate_raw_field "$tagent"
  _doctor_validate_raw_field "$tcomp"; _doctor_validate_raw_field "$human"
  WARNINGS="${WARNINGS}${human}"$'\n'
  [ -n "$sproj" ] && { _redact_project "$sproj"; dproj="$_REDACT_OUT"; }
  if [ -n "$tkind" ] && [ -n "$tteam" ]; then _redact_team "$tteam"; dteam="$_REDACT_OUT"; fi
  if [ -n "$tkind" ] && [ -n "$tagent" ]; then _redact_agent "$tagent"; dagent="$_REDACT_OUT"; fi
  evidence="$human"
  case "$evidence" in \[*\]*\ *) evidence="${evidence#*] }" ;; esac
  evidence="$(_redact_text "$evidence" "$sproj")"
  _doctor_flat "$code"; local fcode="$_FLAT_OUT"
  _doctor_flat "$kind"; local fkind="$_FLAT_OUT"
  _doctor_flat "$category"; local fcat="$_FLAT_OUT"
  _doctor_flat "$dproj"; local fsproj="$_FLAT_OUT"
  _doctor_flat "$stype"; local fstype="$_FLAT_OUT"
  _doctor_flat "$tkind"; local ftkind="$_FLAT_OUT"
  _doctor_flat "$dteam"; local ftteam="$_FLAT_OUT"
  _doctor_flat "$dagent"; local ftagent="$_FLAT_OUT"
  _doctor_flat "$tcomp"; local ftcomp="$_FLAT_OUT"
  _doctor_flat "$evidence"; local fev="$_FLAT_OUT"
  printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' \
    "$fcode" "$fkind" "$fcat" "$fsproj" "$fstype" \
    "$ftkind" "$ftteam" "$ftagent" "$ftcomp" "$fev" "" >> "$_DOCTOR_FINDINGS_FILE" || _doctor_fatal "failed to append finding"
}
# Structured collector API for type plugs (Issue #8 "New collector
# entrypoints" protocol). A plug implementing
#   agmsg_doctor_extra_collect <type> <project>
#   agmsg_doctor_extra_global_collect <type>
# calls these with RAW values; redaction to the run's single mapping table
# happens here, so text and JSON always agree. These functions MUST NOT print
# to stdout (the scan runs in the caller's shell; display lines go to the
# display store, findings to the findings store). Optional trailing opaque
# instance ID (P1-6, e.g. global_instance1) distinguishes multiple global
# components sharing one id; empty means registration instance or null.
agmsg_doctor_finding_add() {
  local code="${1:-}" kind="${2:-}" category="${3:-}" sproj="${4:-}" stype="${5:-}"
  local tkind="${6:-}" tteam="${7:-}" tagent="${8:-}" tcomp="${9:-}" evidence="${10:-}"
  local opaque="${11:-}"
  _doctor_validate_raw_field "$code"; _doctor_validate_raw_field "$kind"
  _doctor_validate_raw_field "$category"; _doctor_validate_raw_field "$sproj"
  _doctor_validate_raw_field "$stype"; _doctor_validate_raw_field "$tkind"
  _doctor_validate_raw_field "$tteam"; _doctor_validate_raw_field "$tagent"
  _doctor_validate_raw_field "$tcomp"; _doctor_validate_raw_field "$evidence"
  _doctor_validate_raw_field "$opaque"
  local dproj="" dteam="" dagent="" ev=""
  [ -n "$sproj" ] && { _redact_project "$sproj"; dproj="$_REDACT_OUT"; }
  if [ -n "$tkind" ] && [ -n "$tteam" ]; then _redact_team "$tteam"; dteam="$_REDACT_OUT"; fi
  if [ -n "$tkind" ] && [ -n "$tagent" ]; then _redact_agent "$tagent"; dagent="$_REDACT_OUT"; fi
  ev="$(_redact_text "$evidence" "$sproj")"
  _doctor_flat "$code"; code="$_FLAT_OUT"
  _doctor_flat "$kind"; kind="$_FLAT_OUT"
  _doctor_flat "$category"; category="$_FLAT_OUT"
  _doctor_flat "$dproj"; dproj="$_FLAT_OUT"
  _doctor_flat "$stype"; stype="$_FLAT_OUT"
  _doctor_flat "$tkind"; tkind="$_FLAT_OUT"
  _doctor_flat "$dteam"; dteam="$_FLAT_OUT"
  _doctor_flat "$dagent"; dagent="$_FLAT_OUT"
  _doctor_flat "$tcomp"; tcomp="$_FLAT_OUT"
  _doctor_flat "$ev"; ev="$_FLAT_OUT"
  _doctor_flat "$opaque"; opaque="$_FLAT_OUT"
  printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' \
    "$code" "$kind" "$category" "$dproj" "$stype" \
    "$tkind" "$dteam" "$dagent" "$tcomp" "$ev" "$opaque" >> "$_DOCTOR_FINDINGS_FILE" || _doctor_fatal "failed to append finding"
}
# agmsg_doctor_component_signal <scope_project_raw> <scope_type> <component_id>
#   <instance_team_raw> <instance_agent_raw> <signal_code> <signal_status> [opaque]
# Empty instance team/agent and empty opaque means a scope singleton
# (serialized as null). Non-empty opaque (P1-6) means an opaque global
# instance (serialized as {"kind":"opaque","id":...}).
agmsg_doctor_component_signal() {
  local sproj="${1:-}" stype="${2:-}" comp="${3:-}" iteam="${4:-}" iagent="${5:-}"
  local scode="${6:-}" sstatus="${7:-}" opaque="${8:-}"
  _doctor_validate_raw_field "$sproj"; _doctor_validate_raw_field "$stype"
  _doctor_validate_raw_field "$comp"; _doctor_validate_raw_field "$iteam"
  _doctor_validate_raw_field "$iagent"; _doctor_validate_raw_field "$scode"
  _doctor_validate_raw_field "$sstatus"; _doctor_validate_raw_field "$opaque"
  local dproj="" dteam="" dagent=""
  [ -n "$sproj" ] && { _redact_project "$sproj"; dproj="$_REDACT_OUT"; }
  if [ -n "$iteam" ]; then _redact_team "$iteam"; dteam="$_REDACT_OUT"; fi
  if [ -n "$iagent" ]; then _redact_agent "$iagent"; dagent="$_REDACT_OUT"; fi
  _doctor_flat "$dproj"; dproj="$_FLAT_OUT"
  _doctor_flat "$stype"; stype="$_FLAT_OUT"
  _doctor_flat "$comp"; comp="$_FLAT_OUT"
  _doctor_flat "$dteam"; dteam="$_FLAT_OUT"
  _doctor_flat "$dagent"; dagent="$_FLAT_OUT"
  _doctor_flat "$scode"; scode="$_FLAT_OUT"
  _doctor_flat "$sstatus"; sstatus="$_FLAT_OUT"
  _doctor_flat "$opaque"; opaque="$_FLAT_OUT"
  printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' \
    "$dproj" "$stype" "$comp" "$dteam" "$dagent" "$scode" "$sstatus" "$opaque" >> "$_DOCTOR_COMPS_FILE" || _doctor_fatal "failed to append component signal"
}
# Plug display lines for the human block (raw; redacted at render time like
# the legacy protocol). One stored line per call.
agmsg_doctor_display_add() {
  local sproj="${1:-}" stype="${2:-}" line="${3:-}"
  _doctor_validate_raw_field "$sproj"; _doctor_validate_raw_field "$stype"
  _doctor_validate_raw_field "$line"
  local dproj=""
  [ -n "$sproj" ] && { _redact_project "$sproj"; dproj="$_REDACT_OUT"; }
  _doctor_flat "$dproj"; dproj="$_FLAT_OUT"
  _doctor_flat "$stype"; stype="$_FLAT_OUT"
  _doctor_flat "$line"; line="$_FLAT_OUT"
  printf '%s\037%s\037%s\n' "$dproj" "$stype" "$line" >> "$_DOCTOR_DISPLAY_FILE" || _doctor_fatal "failed to append display line"
}
agmsg_doctor_global_display_add() {
  local stype="${1:-}" line="${2:-}"
  _doctor_validate_raw_field "$stype"; _doctor_validate_raw_field "$line"
  _doctor_flat "$stype"; stype="$_FLAT_OUT"
  _doctor_flat "$line"; line="$_FLAT_OUT"
  printf '%s\037%s\n' "$stype" "$line" >> "$_DOCTOR_GLOBAL_DISPLAY_FILE" || _doctor_fatal "failed to append display line"
}
# Render the records one structured plug collection appended (lines after
# the given 1-based start offsets) into the human report: findings for this
# scope become project-prefixed warnings, display lines are returned via
# _RENDERED_PLUG_DISPLAY for the caller to quote into the pair's block.
# Human mode only -- JSON mode reads the same store files via the serializer.
# A leading "[...] " scope prefix is NOT re-added here: stored evidence
# already had it stripped at registration, so the prefix below restores
# exactly the shape the legacy WARN protocol produced.
_RENDERED_PLUG_DISPLAY=""
_doctor_render_plug_store() {
  local sproj="$1" stype="$2" fstart="$3" dstart="$4" dproj="" sep
  _redact_project "$sproj"; dproj="$_REDACT_OUT"
  sep="$(printf '\037')"
  _RENDERED_PLUG_DISPLAY=""
  local fcode fkind fcat fsproj fstype ftkind ftteam ftagent ftcomp fev fopaque
  while IFS="$sep" read -r fcode fkind fcat fsproj fstype ftkind ftteam ftagent ftcomp fev fopaque; do
    [ -n "$fcode" ] || continue
    [ "$fsproj" = "$dproj" ] || continue
    [ "$fstype" = "$stype" ] || continue
    WARNINGS="${WARNINGS}[$dproj] $fev"$'\n'
  done <<< "$(tail -n "+$fstart" "$_DOCTOR_FINDINGS_FILE" 2>/dev/null || true)"
  local ddproj ddtype ddline
  while IFS="$sep" read -r ddproj ddtype ddline; do
    [ -n "$ddline" ] || continue
    [ "$ddproj" = "$dproj" ] || continue
    [ "$ddtype" = "$stype" ] || continue
    ddline="$(_redact_text "$ddline" "$sproj")"
    _RENDERED_PLUG_DISPLAY="${_RENDERED_PLUG_DISPLAY}${_RENDERED_PLUG_DISPLAY:+$'\n'}${ddline}"
  done <<< "$(tail -n "+$dstart" "$_DOCTOR_DISPLAY_FILE" 2>/dev/null || true)"
}
# Global counterpart: findings recorded by one global collection (empty scope
# project, matching type) become unprefixed warnings; global display lines go
# to GLOBAL_EXTRA_BLOCKS. Mirrors the legacy global protocol's shapes.
_doctor_render_global_store() {
  local stype="$1" fstart="$2" dstart="$3" sep
  sep="$(printf '\037')"
  local fcode fkind fcat fsproj fstype ftkind ftteam ftagent ftcomp fev fopaque
  while IFS="$sep" read -r fcode fkind fcat fsproj fstype ftkind ftteam ftagent ftcomp fev fopaque; do
    [ -n "$fcode" ] || continue
    [ -z "$fsproj" ] || continue
    [ "$fstype" = "$stype" ] || continue
    WARNINGS="${WARNINGS}${fev}"$'\n'
  done <<< "$(tail -n "+$fstart" "$_DOCTOR_FINDINGS_FILE" 2>/dev/null || true)"
  local gdtype gdline
  while IFS="$sep" read -r gdtype gdline; do
    [ -n "$gdline" ] || continue
    [ "$gdtype" = "$stype" ] || continue
    GLOBAL_EXTRA_BLOCKS="${GLOBAL_EXTRA_BLOCKS}$(_redact_text "$gdline" "")"$'\n'
  done <<< "$(tail -n "+$dstart" "$_DOCTOR_GLOBAL_DISPLAY_FILE" 2>/dev/null || true)"
}
# Per-scope registration observation (core only): lock is none|alive|stale,
# watcher is running|stale-pidfile|none (empty = not applicable, null).
_doctor_reg_add() {
  local sproj="${1:-}" stype="${2:-}" team="${3:-}" agent="${4:-}"
  local lock="${5:-}" watcher="${6:-}"
  _doctor_validate_raw_field "$sproj"; _doctor_validate_raw_field "$stype"
  _doctor_validate_raw_field "$team"; _doctor_validate_raw_field "$agent"
  _doctor_validate_raw_field "$lock"; _doctor_validate_raw_field "$watcher"
  local dproj="" dteam="" dagent=""
  [ -n "$sproj" ] && { _redact_project "$sproj"; dproj="$_REDACT_OUT"; }
  _redact_team "$team"; dteam="$_REDACT_OUT"
  _redact_agent "$agent"; dagent="$_REDACT_OUT"
  _doctor_flat "$dproj"; dproj="$_FLAT_OUT"
  _doctor_flat "$stype"; stype="$_FLAT_OUT"
  _doctor_flat "$dteam"; dteam="$_FLAT_OUT"
  _doctor_flat "$dagent"; dagent="$_FLAT_OUT"
  _doctor_flat "$lock"; lock="$_FLAT_OUT"
  _doctor_flat "$watcher"; watcher="$_FLAT_OUT"
  printf '%s\037%s\037%s\037%s\037%s\037%s\n' \
    "$dproj" "$stype" "$dteam" "$dagent" "$lock" "$watcher" >> "$_DOCTOR_REGS_FILE" || _doctor_fatal "failed to append registration"
}
# Per-scope delivery observation: status is ok|failed|skipped. The mode line
# can name the project (the "off (unrecognized: ...)" annotation quotes the
# settings path it looked for), so it goes through the same redaction as
# every other human-sourced string -- otherwise --redacted --json would leak
# the raw path here while masking it everywhere else.
_doctor_scope_add() {
  local sproj="${1:-}" stype="${2:-}" mode="${3:-}" dstatus="${4:-}"
  _doctor_validate_raw_field "$sproj"; _doctor_validate_raw_field "$stype"
  _doctor_validate_raw_field "$mode"; _doctor_validate_raw_field "$dstatus"
  local dproj=""
  [ -n "$sproj" ] && { _redact_project "$sproj"; dproj="$_REDACT_OUT"; }
  mode="$(_redact_text "$mode" "$sproj")"
  _doctor_flat "$dproj"; dproj="$_FLAT_OUT"
  _doctor_flat "$stype"; stype="$_FLAT_OUT"
  _doctor_flat "$mode"; mode="$_FLAT_OUT"
  _doctor_flat "$dstatus"; dstatus="$_FLAT_OUT"
  printf '%s\037%s\037%s\037%s\n' "$dproj" "$stype" "$mode" "$dstatus" >> "$_DOCTOR_SCOPES_FILE" || _doctor_fatal "failed to append scope"
}

# --- scan one (project, type) pair, buffer its block ------------------------
#
# Buffered into REPORT_BLOCKS rather than printed inline: the summary line
# koit asked for has to come FIRST on screen ("撃った人が最初に見るのはそ
# こ"), but its counts (teams/registrations/warnings) aren't known until
# every pair in the scope has been scanned. Nothing here is large enough for
# buffering to matter -- even the whole install across every team is a
# handful of KB.
REPORT_BLOCKS=""
TOTAL_PAIR_COUNT=0
# The "watch processes: N alive, M stale pidfiles" line the default runtime
# status emits scans the WHOLE run/ directory, not any one (project, type)'s
# own state -- an installation-wide fact, not a per-pair one. Captured ONCE
# here, independent of the scope being scanned, via `delivery.sh status` with
# no <type>/<project> -- do_status's own comment documents this as its
# no-args path: it skips the project-scoped mode line and just reports the
# global watcher state. This independence matters: an earlier version
# captured it opportunistically from whichever pair's own delivery.sh call
# happened to emit it first, which meant it silently never appeared at all
# on an installation whose registrations are ALL a no-delivery type (skips
# the call) and/or codex (overrides runtime status with its own per-role
# bridge lines instead of this one) -- an install like that would lose
# run/watch.*.pid stale-watcher detection entirely, not just deduplicate it.
# Caught in review; the fix is scanning run/ once, unconditionally, not
# deduplicating a per-pair emission that may never happen.
#
# P1-1 fail-closed: output と rc を分離して取得する。grep パイプで rc を
# 握り潰さない。nonzero rc は store 初期化後の global 診断で
# delivery_status_failed (diagnostic_failure) へ正規化し、false healthy
# (rc0/diagnosable:true) にしない。machine の stale count 自体は
# evaluator (P1-4) から取得し、この human text を parse しない。
GLOBAL_DELIVERY_RC=0
GLOBAL_DELIVERY_OUTPUT=""
GLOBAL_DELIVERY_OUTPUT="$(bash "$SCRIPT_DIR/delivery.sh" status 2>&1)" || GLOBAL_DELIVERY_RC=$?
GLOBAL_WATCH_LINE="$(printf '%s\n' "$GLOBAL_DELIVERY_OUTPUT" | grep '^watch processes: ' | head -1 || true)"
_doctor_scan_pair() {
  local project="$1" type="$2"

  # Whether this type already reports its own per-role runtime status
  # (codex's _delivery.sh does, via the embedded delivery-status block --
  # one "Codex bridge: team/agent ..." line per role). Everything else
  # (currently claude-code, opencode) falls through to the default runtime
  # status, which is a single project-wide count with no per-role
  # breakdown, so those types get the watcher= field built below instead.
  # Detected structurally (does the type's plug override the function)
  # rather than hardcoding "codex", so a future type with its own per-role
  # reporting is picked up automatically.
  local type_has_role_runtime=0 type_plug="$SKILL_DIR/scripts/drivers/types/$type/_delivery.sh"
  if [ -f "$type_plug" ] && grep -q '^agmsg_delivery_runtime_status()' "$type_plug" 2>/dev/null; then
    type_has_role_runtime=1
  fi

  # Whether this type has ANY real delivery to ask about. delivery_modes= in
  # the type's manifest lists every mode the type can be SET to; a type whose
  # list is nothing but "off" (agmsg-app, hermes) has no agmsg-side delivery
  # at all -- agmsg-app is the desktop app's own identity, which owns its
  # own send/receive UI. Querying delivery.sh status for such a type exits 1
  # by design (there's nothing to report), and this doctor was turning that
  # into a WARNING on an otherwise completely healthy installation -- a real
  # installation, run once, came back "9 team(s), 56 registration(s), 5
  # warning(s)" purely from this, violating the exit-code contract this
  # command promised on day one (0 = nothing to report). Checked via the
  # manifest (agmsg_type_get, already used by PR #631 for the same key) so a
  # future no-delivery type is picked up the same way automatically, rather
  # than by name.
  local type_has_delivery=0 _dm_tok
  for _dm_tok in $(agmsg_type_get "$type" delivery_modes); do
    if [ "$_dm_tok" != "off" ]; then
      type_has_delivery=1
      break
    fi
  done
  unset _dm_tok

  # delivery 観測は shared evaluator が SSOT (P1-4): doctor は human text を
  # grep/sed して machine field/finding へ変換しない。human 表示用の
  # delivery_output (delivery.sh status の verbatim) と machine 用の
  # evaluator 結果は分離して取得する。human wording 変更だけでは machine
  # JSON は壊れない。delivery.sh 自体の失敗と evaluator 失敗のいずれも
  # delivery_status_failed (diagnostic_failure) へ正規化する。
  # stdout purity (P1-2): evaluator/plug/collector/subprocess の stdout は
  # 最終 stdout へ直接流さない。delivery.sh 呼び出しは $() 捕捉済みであり、
  # plug source/collector は 1>&2 で stderr へ逃がす (後述)。
  local delivery_status=0 delivery_output="" mode="off" eval_ok=1
  local eval_stale=0 eval_stale_ok=1
  if [ "$type_has_delivery" -eq 1 ]; then
    # Machine: mode は evaluator から直接取得 (human text parse 禁止)。
    # stdout 隔離 (1>&2): evaluator/helper の stdout が最終 stdout へ直接
    # 流れないよう stderr へ逃がす。machine evaluator は stdout を contract
    # にしないため、noise があっても JSON を汚さない。
    if agmsg_delivery_eval_mode "$type" "$project" 1>&2 2>/dev/null; then
      mode="$AGMSG_DELIVERY_EVAL_MODE"
    else
      eval_ok=0
      mode="off"
    fi
    # Machine: scoped stale は evaluator から直接取得 (human text parse 禁止)。
    if agmsg_delivery_eval_scoped_stale "$type" "$project" 1>&2 2>/dev/null; then
      eval_stale="$AGMSG_DELIVERY_EVAL_SCOPED_STALE"
    else
      eval_stale_ok=0
      eval_stale=0
    fi
    # Human display: delivery.sh status の verbatim (machine には使わない)。
    delivery_output="$(bash "$SCRIPT_DIR/delivery.sh" status "$type" "$project" 2>&1)" || delivery_status=$?

    # This pair's own delivery.sh call may ALSO emit the same global line
    # (default runtime status, when this type doesn't override it) -- always
    # captured independently above now, so here it's only ever stripped out
    # of this pair's own text, never (re-)captured from it. delivery.sh
    # always emits "mode: ..." before this line when given a type/project
    # (do_status runs agmsg_delivery_status first, unconditionally), so this
    # grep -v never filters every line away in practice -- guarded with
    # || true anyway rather than leaning on that ordering under set -e.
    # NOTE: この grep -v は human 表示整形のみに用い、machine 判定には
    # 使わない (P1-4)。
    delivery_output="$(printf '%s\n' "$delivery_output" | grep -v '^watch processes: ' || true)"
  else
    # No-delivery type (off のみ): evaluator から off を取得する。
    if agmsg_delivery_eval_mode "$type" "$project" 1>&2 2>/dev/null; then
      mode="$AGMSG_DELIVERY_EVAL_MODE"
    else
      mode="off"
    fi
  fi

  # Tracks whether this pair turned out to have anything worth a full block:
  # a warning count taken before/after (any _warn call below flips this,
  # without needing every call site to also set a flag), plus "any lock held
  # at all" and "delivery has more than a bare idle mode line" below. All
  # three false is exactly the shape a healthy, unconfigured project/type has
  # -- 27 such groups on a real install were each 6 lines to say nothing,
  # which is what made the report unreadable at real scale.
  local _warn_count_before
  _warn_count_before="$(printf '%s\n' "$WARNINGS" | grep -c . || true)"

  local pairs pair_count reg_lines="" first_team="" first_agent="" _any_owner=0
  # P1-2: identities 失敗は silent にしない。per-scope partial として
  # scan_failed (diagnostic_failure) へ正規化し、scope 記録を残して継続
  # する (serializer の orphan child 厳格化のため scope entry は必須)。
  # ERR trap による全体 rc2 ではなく partial rc1 を優先する。
  local _ident_rc=0
  pairs="$("$SCRIPT_DIR/identities.sh" "$project" "$type" 2>/dev/null)" || _ident_rc=$?
  if [ "$_ident_rc" -ne 0 ]; then
    _redact_project "$project"
    _doctor_warn scan_failed diagnostic_failure unknown "$project" "$type" \
      "" "" "" "" -- \
      "[$_REDACT_OUT] identities lookup failed for this scope (rc $_ident_rc); structured observations may be incomplete"
    _doctor_scope_add "$project" "$type" "$mode" "failed"
    return 0
  fi
  # FILTER_TEAM, when set, narrows the report to that team's own rows -- a
  # pair SCOPE already guaranteed has at least one registration for that
  # team (see the --project branch above / agmsg_registered_projects's team
  # param), so this never empties a pair SCOPE included.
  pairs="$(_team_filter_lines "$pairs" "$FILTER_TEAM")"
  pair_count="$(printf '%s\n' "$pairs" | grep -c . || true)"
  TOTAL_PAIR_COUNT=$((TOTAL_PAIR_COUNT + pair_count))

  local team agent dteam dagent owner alive_word cc_note pid
  local wpidfile wpid watcher_note first_dteam first_dagent
  if [ "$pair_count" -gt 0 ]; then
    while IFS=$'\t' read -r team agent; do
      [ -z "$team" ] && continue
      [ -n "$first_team" ] || { first_team="$team"; first_agent="$agent"; }

      _redact_team "$team"; dteam="$_REDACT_OUT"
      _redact_agent "$agent"; dagent="$_REDACT_OUT"
      owner="$(actas_lock_owner "$team" "$agent")"

      if [ -z "$owner" ]; then
        reg_lines="${reg_lines}$(printf '  %-22s lock=none' "$dteam/$dagent")"$'\n'
        _doctor_reg_add "$project" "$type" "$team" "$agent" "none" ""
        continue
      fi
      _any_owner=1

      if agmsg_instance_alive "$owner"; then
        alive_word="alive"
      else
        alive_word="STALE"
        _redact_project "$project"
        _doctor_warn lock_stale condition messaging "$project" "$type" \
          registration "$team" "$agent" "" -- \
          "[$_REDACT_OUT] stale lock: $dteam/$dagent (owner=$(_redact_owner "$owner"))"
      fi

      cc_note=""
      if agmsg_instance_is_composite "$owner"; then
        pid="${owner##*.}"
        if [ -f "$RUN_DIR/cc-instance.$pid" ]; then cc_note=" cc-instance=present"; else cc_note=" cc-instance=absent"; fi
      fi

      # Per-role watcher liveness -- only for types whose runtime status
      # doesn't already break this down per role (see type_has_role_runtime
      # above). The pidfile watch.sh's SessionStart directive writes is
      # keyed on the SAME normalized instance id actas-claim.sh records as
      # the lock owner (both go through agmsg_normalize_instance_id on the
      # same session id), so the owner token IS the watcher's pidfile name
      # -- no separate lookup or correlation needed, and no liveness logic
      # of its own: reuses _agmsg_pid_alive_local, the same helper
      # delivery.sh's own default runtime status calls.
      watcher_note=""
      watcher_val=""
      if [ "$type_has_role_runtime" -eq 0 ]; then
        wpidfile="$RUN_DIR/watch.$owner.pid"
        if [ -f "$wpidfile" ]; then
          wpid="$(cat "$wpidfile" 2>/dev/null || true)"
          if [ -n "$wpid" ] && _agmsg_pid_alive_local "$wpid" 2>/dev/null; then
            watcher_note=" watcher=running"
            watcher_val="running"
          else
            watcher_note=" watcher=stale-pidfile"
            watcher_val="stale-pidfile"
          fi
        else
          watcher_note=" watcher=none"
          watcher_val="none"
          # Only when the lock itself is legitimately live: a stale lock
          # having no watcher is unremarkable (already covered above), but
          # an alive lock with no watcher means the role claims exclusivity
          # and isn't receiving -- the shape #605 and koit's own example
          # both were.
          if [ "$alive_word" = "alive" ]; then
            _redact_project "$project"
            _doctor_warn lock_no_watcher condition messaging "$project" "$type" \
              registration "$team" "$agent" "" -- \
              "[$_REDACT_OUT] actas lock held but no watcher: $dteam/$dagent (owner=$(_redact_owner "$owner"))"
          fi
        fi
      fi
      if [ "$alive_word" = "alive" ]; then
        _doctor_reg_add "$project" "$type" "$team" "$agent" "alive" "$watcher_val"
      else
        _doctor_reg_add "$project" "$type" "$team" "$agent" "stale" "$watcher_val"
      fi

      reg_lines="${reg_lines}$(printf '  %-22s lock=owner(%s)=%s%s%s' "$dteam/$dagent" "$alive_word" "$(_redact_owner "$owner")" "$cc_note" "$watcher_note")"$'\n'
    done <<< "$pairs"

    if [ "$pair_count" -gt 1 ] && { [ "$mode" = "turn" ] || [ "$mode" = "both" ]; }; then
      _redact_team "$first_team"; first_dteam="$_REDACT_OUT"
      _redact_agent "$first_agent"; first_dagent="$_REDACT_OUT"
      _redact_project "$project"
      _doctor_warn turn_mode_multi_registration condition messaging "$project" "$type" \
        "" "" "" "" -- \
        "[$_REDACT_OUT] $pair_count registrations for this (project, type) under turn-mode delivery -- only the first registered ($first_dteam/$first_dagent) receives Stop-hook delivery; the rest are silent under turn"
    fi
  fi

  # Scoped stale は shared evaluator が SSOT (P1-4): human text の
  # "stale pidfile (" を grep しない。wording 変更では machine JSON は
  # 壊れない。
  if [ "$eval_stale" = "1" ]; then
    _redact_project "$project"
    _doctor_warn watcher_stale_pidfile condition runtime "$project" "$type" \
      "" "" "" "" -- \
      "[$_REDACT_OUT] watcher/bridge pidfile present but process not running (see delivery status above)"
  fi

  # Type-specific extra diagnosis. A plug at
  # scripts/drivers/types/<type>/_doctor.sh may define the structured
  # collector entry point agmsg_doctor_extra_collect <type> <project>
  # (Issue #8): it registers findings / component signals / display lines
  # directly through the collector API above -- no stdout protocol, nothing
  # reparsed. The human WARN lines and the --json findings below are both
  # rendered from that one store, so the two outputs cannot disagree about
  # what was observed. Only codex ships such a plug today (app-server
  # pid/port/version + bridge binding state, #5); every other type skips
  # this with one file-exists check. Sourced, not shelled out, so the plug
  # reuses this script's own helpers (liveness, cmdline, redaction tables)
  # instead of recomputing them; the plug's own double-source guard makes
  # re-sourcing once per pair a no-op after the first. Read-only by
  # contract: a plug never kills, removes, or restarts anything — stale or
  # foreign state is reported, not cleaned up.
  #
  # A plug file WITHOUT the structured entry point is legacy: human mode
  # keeps the old agmsg_doctor_extra_status stdout protocol (WARN:-prefixed
  # lines become warnings, the rest is quoted into the block), while --json
  # mode refuses to guess codes from that text and records a
  # legacy_plug_unstructured diagnostic_failure instead (fail-closed).
  _extra_plug="$SKILL_DIR/scripts/drivers/types/$type/_doctor.sh"
  _extra_has_collect=0
  if [ -f "$_extra_plug" ]; then
    if grep -q '^agmsg_doctor_extra_collect()' "$_extra_plug" 2>/dev/null; then
      _extra_has_collect=1
    fi
  fi
  if [ "$_extra_has_collect" -eq 1 ]; then
    # P1-2 stdout purity: plug source の stdout が最終 stdout へ直接流れ
    # ないよう 1>&2 へ逃がす。source 不正/失敗は silent にせず
    # plug_collector_failed (diagnostic_failure) へ正規化する。
    _plug_src_rc=0
    # shellcheck disable=SC1091
    . "$_extra_plug" 1>&2 2>/dev/null || _plug_src_rc=$?
    if [ "$_plug_src_rc" -ne 0 ]; then
      agmsg_doctor_finding_add plug_collector_failed diagnostic_failure unknown \
        "$project" "$type" "" "" "" "" \
        "type plug source for '$type' exited $_plug_src_rc during this scope's scan; structured observations for this scope may be incomplete" ""
      if [ "$JSON_MODE" -eq 0 ]; then
        # Human 側にも警告として出すため、store から描画する。
        _plug_fmark="$(wc -l < "$_DOCTOR_FINDINGS_FILE" 2>/dev/null | tr -d ' ')"
        _plug_dmark="$(wc -l < "$_DOCTOR_DISPLAY_FILE" 2>/dev/null | tr -d ' ')"
        _doctor_render_plug_store "$project" "$type" "$((_plug_fmark))" "$((_plug_dmark + 1))"
      fi
    else
      # Called directly in this shell (never inside $()): findings and display
      # lines land in the store files, not on stdout. Stdout is redirected to
      # stderr so a stray plug print can never pollute the --json payload (or
      # silently vanish from the human report); by contract the plug prints
      # nothing there. A nonzero collector exit is captured, never left to
      # trip set -e mid-scan (which would end the run with rc 1 and an empty
      # stdout, violating the exit contract): the scope keeps whatever else
      # was observed and records a plug_collector_failed diagnostic_failure.
      _plug_fmark="$(wc -l < "$_DOCTOR_FINDINGS_FILE" | tr -d ' ')"
      _plug_dmark="$(wc -l < "$_DOCTOR_DISPLAY_FILE" | tr -d ' ')"
      _plug_collector_rc=0
      agmsg_doctor_extra_collect "$type" "$project" 1>&2 || _plug_collector_rc=$?
      if [ "$_plug_collector_rc" -ne 0 ]; then
        agmsg_doctor_finding_add plug_collector_failed diagnostic_failure unknown \
          "$project" "$type" "" "" "" "" \
          "type plug collector for '$type' exited $_plug_collector_rc during this scope's scan; structured observations for this scope may be incomplete" ""
      fi
      if [ "$JSON_MODE" -eq 0 ]; then
        _doctor_render_plug_store "$project" "$type" "$((_plug_fmark + 1))" "$((_plug_dmark + 1))"
        if [ -n "$_RENDERED_PLUG_DISPLAY" ]; then
          delivery_output="${delivery_output}${delivery_output:+$'\n'}${_RENDERED_PLUG_DISPLAY}"
        fi
      fi
    fi
  elif [ -f "$_extra_plug" ]; then
    if [ "$JSON_MODE" -eq 1 ]; then
      _redact_project "$project"
      _doctor_warn legacy_plug_unstructured diagnostic_failure unknown "$project" "$type" \
        "" "" "" "" -- \
        "[$_REDACT_OUT] type plug has no structured collector; this scope cannot be fully diagnosed in machine-readable mode"
    else
      # P1-2: source stdout purity (1>&2) と rc 捕捉。legacy human path
      # でも source 失敗を silent にしない。
      _plug_src_rc=0
      # shellcheck disable=SC1091
      . "$_extra_plug" 1>&2 2>/dev/null || _plug_src_rc=$?
      if [ "$_plug_src_rc" -ne 0 ]; then
        _redact_project "$project"
        _warn "[$_REDACT_OUT] type plug source for '$type' exited $_plug_src_rc"
      elif command -v agmsg_doctor_extra_status >/dev/null 2>&1; then
        _extra_output="$(agmsg_doctor_extra_status "$type" "$project" 2>/dev/null || true)"
        _extra_warns="$(printf '%s\n' "$_extra_output" | grep '^WARN: ' | sed 's/^WARN: //' || true)"
        if [ -n "$_extra_warns" ]; then
          while IFS= read -r _extra_warn; do
            [ -n "$_extra_warn" ] || continue
            _extra_warn_red="$(_redact_text "$_extra_warn" "$project")"
            _redact_project "$project"
            _warn "[$_REDACT_OUT] $_extra_warn_red"
          done <<< "$_extra_warns" || true
        fi
        _extra_display="$(printf '%s\n' "$_extra_output" | grep -v '^WARN: ' || true)"
        if [ -n "$_extra_display" ]; then
          delivery_output="${delivery_output}${delivery_output:+$'\n'}${_extra_display}"
        fi
      fi
    fi
  fi
  unset _extra_plug _extra_has_collect _plug_fmark _plug_dmark _plug_collector_rc _plug_src_rc _extra_output _extra_warns _extra_warn _extra_warn_red _extra_display

  # type is already validated (or came from the registry) before this is
  # ever called, so this is not the "unknown type" case -- some other
  # failure inside delivery evaluation itself (delivery.sh status rc,
  # shared evaluator mode/stale evaluation). Surfaced as a warning rather
  # than swallowed: showing error text on screen while still reporting
  # "no warnings." / exit 0 underneath would be a doctor that lies about
  # its own read. type_has_delivery gates the delivery.sh call happening at
  # all now, so the delivery_status branch can only fire for a type that
  # DOES have delivery to query; evaluator failures are type-independent.
  # P1-1/P1-4: 既存 delivery_status_failed を再利用し、新 code を増やさない。
  if [ "$delivery_status" -ne 0 ] || [ "$eval_ok" -eq 0 ] || [ "$eval_stale_ok" -eq 0 ]; then
    _redact_project "$project"
    _doctor_warn delivery_status_failed diagnostic_failure runtime "$project" "$type" \
      "" "" "" "" -- \
      "[$_REDACT_OUT] delivery.sh status exited $delivery_status (see delivery status above)"
  fi
  if [ "$type_has_delivery" -eq 0 ]; then
    _doctor_scope_add "$project" "$type" "$mode" "skipped"
  elif [ "$delivery_status" -ne 0 ] || [ "$eval_ok" -eq 0 ] || [ "$eval_stale_ok" -eq 0 ]; then
    _doctor_scope_add "$project" "$type" "$mode" "failed"
  else
    _doctor_scope_add "$project" "$type" "$mode" "ok"
  fi

  # "Nothing to report": no lock held (by anyone), no warning raised while
  # scanning this pair, and delivery has nothing beyond a bare idle mode
  # line (no type_has_delivery at all, or mode=off with delivery_output --
  # after the global watch-processes line above was stripped out of it --
  # amounting to just that one "mode: off" line, no hooks/bridge detail
  # worth a look). On a real installation this was 27 of the report's
  # groups, each spending 6 lines to say "nothing here" -- unreadable at
  # real scale even once the exit-code bug above stops making them warnings.
  local _warn_count_after
  _warn_count_after="$(printf '%s\n' "$WARNINGS" | grep -c . || true)"
  local _delivery_line_count
  _delivery_line_count="$(printf '%s\n' "$delivery_output" | grep -c . || true)"
  local _boring=0
  if [ "$_any_owner" -eq 0 ] \
    && [ "$_warn_count_after" -eq "$_warn_count_before" ] \
    && case "$mode" in off\ \(unrecognized:*) false ;; off*) true ;; *) false ;; esac; then
    _boring=1
  fi

  _redact_project "$project"
  # `off` and `off (unrecognized: …)` are not the same state, and only the first
  # one is boring.
  #
  # `off` is a claim about the CONFIGURATION: the settings file was read and no
  # delivery hooks are installed. Nothing to report.
  #
  # `unrecognized` is a claim about THIS CHECK: it could not find or parse the
  # settings file, so it does not know what the configuration is. Collapsing that
  # to "nothing to report" tells the operator their delivery is off when what
  # happened is that we could not tell -- and the annotation it hides ("this
  # project may not be registered") is the one that explains an empty inbox.
  #
  # Measured while merging: this branch's delivery.sh has no bare `off` at all --
  # all four assignments carry an annotation -- so a condition testing for the
  # bare word collapses nothing, and one testing the first word collapses
  # everything including the three unrecognized cases.
  if [ "$_boring" -eq 1 ]; then
    local _noun="registrations"
    [ "$pair_count" -eq 1 ] && _noun="registration"
    # The path stays on the collapsed line. Of the five lines it replaces, four
    # repeat what the summary already says (the mode, and "entries: 0" three
    # times); the path answers a different question -- WHICH file was consulted.
    # That is the difference between "looked and found nothing" and "did not
    # look", and it is the distinction this repo keeps paying for when it goes
    # missing.
    _boring_conf="$(printf '%s\n' "$delivery_output" | sed -n 's/^settings hooks file: //p' | head -1)"
    if [ -n "$_boring_conf" ]; then
      _redact_text_out="$(_redact_text "$_boring_conf" "$project")"
      REPORT_BLOCKS="${REPORT_BLOCKS}$_REDACT_OUT  [$type]  $pair_count $_noun, nothing to report — $_redact_text_out"$'\n'
    else
      REPORT_BLOCKS="${REPORT_BLOCKS}$_REDACT_OUT  [$type]  $pair_count $_noun, nothing to report"$'\n'
    fi
  else
    REPORT_BLOCKS="${REPORT_BLOCKS}project: $_REDACT_OUT"$'\n'
    REPORT_BLOCKS="${REPORT_BLOCKS}type:    $type"$'\n\n'
    REPORT_BLOCKS="${REPORT_BLOCKS}$(_redact_text "$delivery_output" "$project")"$'\n\n'
    REPORT_BLOCKS="${REPORT_BLOCKS}registrations ($pair_count):"$'\n'
    if [ "$pair_count" -eq 0 ]; then
      REPORT_BLOCKS="${REPORT_BLOCKS}  (none for this project/type)"$'\n'
    else
      REPORT_BLOCKS="${REPORT_BLOCKS}${reg_lines}"
    fi
    REPORT_BLOCKS="${REPORT_BLOCKS}"$'\n'
  fi
}

# --- run the whole scope, then print summary -> blocks -> warnings --------
#
# Team count for the summary line is built alongside the scan (every
# distinct team name seen across the scope's registrations, not the count
# of (project, type) pairs) rather than a second pass over SCOPE -- reuses
# the exact identities.sh call _doctor_scan_pair already makes for the same
# pair, instead of querying it twice.
DISTINCT_TEAMS=""
SCANNED_TYPES=""
_doctor_store_init
trap 'rm -rf "${_DOCTOR_TMP:-}"' EXIT INT TERM
while IFS=$'\t' read -r _proj _type; do
  [ -z "$_proj" ] && continue
  _doctor_scan_pair "$_proj" "$_type"
  case $'\n'"$SCANNED_TYPES"$'\n' in
    *$'\n'"$_type"$'\n'*) ;;
    *) SCANNED_TYPES="${SCANNED_TYPES}${_type}"$'\n' ;;
  esac
  while IFS=$'\t' read -r _team _agent; do
    [ -z "$_team" ] && continue
    case $'\n'"$DISTINCT_TEAMS"$'\n' in
      *$'\n'"$_team"$'\n'*) ;;
      *) DISTINCT_TEAMS="${DISTINCT_TEAMS}${_team}"$'\n' ;;
    esac
  done <<< "$(_team_filter_lines "$("$SCRIPT_DIR/identities.sh" "$_proj" "$_type")" "$FILTER_TEAM")"
done <<< "$SCOPE"
TEAM_COUNT="$(printf '%s\n' "$DISTINCT_TEAMS" | grep -c . || true)"

# P1-1 fail-closed: global delivery.sh status nonzero を握り潰さない。
# meaningful partial report が可能なため rc1 + JSON (diagnosable:false +
# diagnostic_failure) とし、authoritative report 自体が生成不能な場合のみ
# rc2 (ERR trap / serializer rc2 path) とする。既存 delivery_status_failed
# を global にも再利用する。
if [ "${GLOBAL_DELIVERY_RC:-0}" -ne 0 ]; then
  _doctor_warn delivery_status_failed diagnostic_failure runtime "" "" \
    "" "" "" "" -- \
    "installation-wide delivery status failed (rc $GLOBAL_DELIVERY_RC)"
fi

# Global watcher stale は shared evaluator が SSOT (P1-4): human text の
# GLOBAL_WATCH_LINE を sed して machine count へ変換しない。human 表示は
# GLOBAL_WATCH_LINE をそのまま使い、machine 判定は evaluator の counts を
# 直接使う。wording 変更では JSON は壊れない。
if agmsg_delivery_eval_watchers 1>&2 2>/dev/null; then
  if [ "${AGMSG_DELIVERY_EVAL_WATCH_STALE:-0}" -gt 0 ]; then
    _doctor_warn watcher_stale_pidfile_global condition runtime "" "" \
      "" "" "" "" -- \
      "watcher pidfile present but process not running, installation-wide (see the 'watch processes' line above)"
  fi
else
  _doctor_warn delivery_status_failed diagnostic_failure runtime "" "" \
    "" "" "" "" -- \
    "installation-wide watcher evaluation failed; installation-wide observations may be incomplete"
fi

# Installation-wide type-plug diagnosis, once per run rather than per pair:
# records no pair owns (a codex app-server triple whose hash matches no
# registered project, launcher-generation bridge bindings no per-pair call
# attributed). Same plug protocol as the per-pair hook above, minus the
# project: agmsg_doctor_extra_global <type> prints display lines and "WARN: "
# lines, which here carry their own record identifier instead of a project
# prefix. Displayed with the other installation-wide state above the
# per-pair blocks.
#
# Scope rule: an explicit --project never reports out-of-scope installation
# state, and an explicit --type/--team keeps the report to what was asked
# for — both skip plugs their scope did not scan. But a completely
# unfiltered whole-install scan runs EVERY available plug, not just the
# scanned types': a type with zero registrations has no pair to scan, so a
# scanned-types-only rule would blind the report exactly when leftover state
# (records from removed or never-registered projects) needs it most (#5's
# orphan case). --type <t> with zero registrations keeps its existing exit 2
# (decided before any scanning happens), unchanged by this.
GLOBAL_EXTRA_BLOCKS=""
GLOBAL_PLUG_TYPES="$SCANNED_TYPES"
if [ -z "$FILTER_PROJECT" ] && [ -z "$FILTER_TYPE" ] && [ -z "$FILTER_TEAM" ]; then
  for _plug_path in "$SKILL_DIR/scripts/drivers/types/"*/_doctor.sh; do
    [ -f "$_plug_path" ] || continue
    _plug_type="$(basename "$(dirname "$_plug_path")")"
    case $'\n'"$GLOBAL_PLUG_TYPES"$'\n' in
      *$'\n'"$_plug_type"$'\n'*) ;;
      *) GLOBAL_PLUG_TYPES="${GLOBAL_PLUG_TYPES}${_plug_type}"$'\n' ;;
    esac
  done
fi
if [ -z "$FILTER_PROJECT" ]; then
  while IFS= read -r _extra_type; do
    [ -n "$_extra_type" ] || continue
    _extra_plug="$SKILL_DIR/scripts/drivers/types/$_extra_type/_doctor.sh"
    [ -f "$_extra_plug" ] || continue
    if grep -q '^agmsg_doctor_extra_global_collect()' "$_extra_plug" 2>/dev/null; then
      # P1-2: source stdout purity (1>&2) と rc 捕捉。source 失敗は
      # plug_collector_failed へ正規化し silent にしない。
      _plug_gsrc_rc=0
      # shellcheck disable=SC1091
      . "$_extra_plug" 1>&2 2>/dev/null || _plug_gsrc_rc=$?
      if [ "$_plug_gsrc_rc" -ne 0 ]; then
        agmsg_doctor_finding_add plug_collector_failed diagnostic_failure unknown \
          "" "$_extra_type" "" "" "" "" \
          "type plug global source for '$_extra_type' exited $_plug_gsrc_rc; installation-wide observations may be incomplete" ""
      else
        _plug_gfmark="$(wc -l < "$_DOCTOR_FINDINGS_FILE" | tr -d ' ')"
        _plug_gdmark="$(wc -l < "$_DOCTOR_GLOBAL_DISPLAY_FILE" | tr -d ' ')"
        # Same nonzero capture as the per-pair collector above: a failing
        # global collector degrades to a diagnostic_failure finding, never to
        # an aborted run with an empty stdout.
        _plug_gcollector_rc=0
        agmsg_doctor_extra_global_collect "$_extra_type" 1>&2 || _plug_gcollector_rc=$?
        if [ "$_plug_gcollector_rc" -ne 0 ]; then
          agmsg_doctor_finding_add plug_collector_failed diagnostic_failure unknown \
            "" "$_extra_type" "" "" "" "" \
            "type plug global collector for '$_extra_type' exited $_plug_gcollector_rc; installation-wide observations may be incomplete" ""
        fi
        if [ "$JSON_MODE" -eq 0 ]; then
          _doctor_render_global_store "$_extra_type" "$((_plug_gfmark + 1))" "$((_plug_gdmark + 1))"
        fi
      fi
    elif [ "$JSON_MODE" -eq 1 ]; then
      agmsg_doctor_finding_add legacy_plug_unstructured diagnostic_failure unknown \
        "" "$_extra_type" "" "" "" "" \
        "type plug for '$_extra_type' has no structured collector; installation-wide state cannot be fully diagnosed in machine-readable mode"
    else
      # P1-2: legacy human path でも source stdout purity と rc 捕捉。
      _plug_gsrc_rc=0
      # shellcheck disable=SC1091
      . "$_extra_plug" 1>&2 2>/dev/null || _plug_gsrc_rc=$?
      if [ "$_plug_gsrc_rc" -ne 0 ]; then
        _warn "type plug global source for '$_extra_type' exited $_plug_gsrc_rc"
      elif command -v agmsg_doctor_extra_global >/dev/null 2>&1; then
        _extra_output="$(agmsg_doctor_extra_global "$_extra_type" 2>/dev/null || true)"
        _extra_warns="$(printf '%s\n' "$_extra_output" | grep '^WARN: ' | sed 's/^WARN: //' || true)"
        if [ -n "$_extra_warns" ]; then
          while IFS= read -r _extra_warn; do
            [ -n "$_extra_warn" ] || continue
            _warn "$(_redact_text "$_extra_warn" "")"
          done <<< "$_extra_warns" || true
        fi
        _extra_display="$(printf '%s\n' "$_extra_output" | grep -v '^WARN: ' || true)"
        if [ -n "$_extra_display" ]; then
          GLOBAL_EXTRA_BLOCKS="${GLOBAL_EXTRA_BLOCKS}$(_redact_text "$_extra_display" "")"$'\n'
        fi
      fi
    fi
  done <<< "$GLOBAL_PLUG_TYPES" || true
fi
unset _extra_type _extra_plug _extra_output _extra_warns _extra_warn _extra_display
unset _plug_path _plug_type _plug_gfmark _plug_gdmark _plug_gcollector_rc _plug_gsrc_rc GLOBAL_PLUG_TYPES GLOBAL_DELIVERY_RC GLOBAL_DELIVERY_OUTPUT
WARN_COUNT="$(printf '%s\n' "$WARNINGS" | grep -c . || true)"

# --json: the scan above collected everything into the store; serialize it
# as the ONLY stdout payload (Issue #8 strict stdout contract). rc 0/1
# always carry parseable JSON; rc 2 paths exit before this point with stdout
# empty and human text on stderr. Requested-scope echo uses the same
# pseudonym tables, so --redacted --json agrees with the human report.
if [ "$JSON_MODE" -eq 1 ]; then
  _json_filter_project=""
  _json_filter_team=""
  if [ -n "$FILTER_PROJECT" ]; then
    _redact_project "$FILTER_PROJECT"; _json_filter_project="$_REDACT_OUT"
  fi
  if [ -n "$FILTER_TEAM" ]; then
    _redact_team "$FILTER_TEAM"; _json_filter_team="$_REDACT_OUT"
  fi
  if python3 "$SCRIPT_DIR/internal/doctor-json.py" \
    --scopes "$_DOCTOR_SCOPES_FILE" \
    --registrations "$_DOCTOR_REGS_FILE" \
    --components "$_DOCTOR_COMPS_FILE" \
    --findings "$_DOCTOR_FINDINGS_FILE" \
    --filter-project "$_json_filter_project" \
    --filter-type "$FILTER_TYPE" \
    --filter-team "$_json_filter_team" \
    --teams "$TEAM_COUNT" >"$_DOCTOR_TMP/serializer-out.json" 2>"$_DOCTOR_TMP/serializer-err.txt"; then
    _json_rc=0
  else
    _json_rc=$?
  fi
  # Publish boundary: serializer の stdout を直接最終 stdout へ出さず、
  # temp へ出して rc/output を検証してから初めて publish する。serializer
  # process の起動失敗・初期化失敗 (例: broken PYTHONIOENCODING) は
  # Python 側が rc 1 で stdout 空になり得るため、そのまま返すと rc1/empty
  # stdout の契約違反になる。rc 0/1 かつ valid JSON のときのみ publish し、
  # それ以外は rc2・stdout 空へ正規化する。validator 用 python3 自体が
  # 壊れている場合も validation 失敗として rc2 になる (正しい)。
  if { [ "$_json_rc" -eq 0 ] || [ "$_json_rc" -eq 1 ]; } \
    && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
      "$_DOCTOR_TMP/serializer-out.json" 2>/dev/null; then
    cat "$_DOCTOR_TMP/serializer-out.json" || _doctor_fatal "failed to publish machine-readable report"
    exit "$_json_rc"
  else
    # serializer の stderr (concise 診断) があれば引き継ぐ。なければ
    # 汎用メッセージを出す。stdout には何も出さない。
    if [ -s "$_DOCTOR_TMP/serializer-err.txt" ]; then
      cat "$_DOCTOR_TMP/serializer-err.txt" >&2 || true
    else
      printf 'doctor: serializer failed (rc %s)\n' "$_json_rc" >&2
    fi
    exit 2
  fi
fi

echo "$TEAM_COUNT team(s), $TOTAL_PAIR_COUNT registration(s), $WARN_COUNT warning(s)"
echo
if [ -n "$GLOBAL_WATCH_LINE" ]; then
  echo "$GLOBAL_WATCH_LINE"
  echo
fi
if [ -n "$GLOBAL_EXTRA_BLOCKS" ]; then
  printf '%s' "$GLOBAL_EXTRA_BLOCKS"
  echo
fi
printf '%s' "$REPORT_BLOCKS"

if [ -n "$WARNINGS" ]; then
  echo "warnings:"
  printf '%s' "$WARNINGS" | sed 's/^/  - /'
  exit 1
fi
echo "no warnings."
exit 0
