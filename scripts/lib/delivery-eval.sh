#!/usr/bin/env bash
# delivery-eval.sh — shared structured delivery evaluator (Issue #8, P1-4).
#
# 概念:
#   shared delivery evaluator
#           ├─ delivery.sh human renderer
#           └─ doctor structured observation
#
# doctor は delivery.sh status の human text を grep/sed して machine field /
# finding へ変換しない (Issue #8 で禁止した経路)。代わりに doctor はこの
# evaluator を直接呼び、human renderer も同じ evaluator から描画する。
# human wording/order 変更だけでは doctor machine JSON は壊れない。
#
# 最低限の structured source:
#   - delivery mode (full mode string, human の "mode: ..." と同一値)
#   - delivery status success/failure (evaluator 自体の rc)
#   - watcher process state (alive/stale counts)
#   - scoped stale pidfile presence (per-(project,type) boolean)
#
# 下層の観測源は human renderer と同一ファイル群である (hooks JSON / rule
# file / run/*.pid)。human 出力を parse しない。
#
# Sourced, never executed. Requires SKILL_DIR / SCRIPT_DIR / RUN_DIR in
# scope (both delivery.sh and doctor.sh set them).

[ -n "${_AGMSG_DELIVERY_EVAL_SH:-}" ] && return 0
_AGMSG_DELIVERY_EVAL_SH=1

# --- dependencies (guarded, portable to both sourcing contexts) -------------
if ! command -v agmsg_sqlite_mem >/dev/null 2>&1; then
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/storage.sh" 2>/dev/null || true
  elif [ -n "${SKILL_DIR:-}" ]; then
    # shellcheck disable=SC1091
    . "$SKILL_DIR/scripts/lib/storage.sh" 2>/dev/null || true
  fi
fi
if ! command -v agmsg_sql_readfile_path >/dev/null 2>&1; then
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sqlpath.sh" 2>/dev/null || true
  elif [ -n "${SKILL_DIR:-}" ]; then
    # shellcheck disable=SC1091
    . "$SKILL_DIR/scripts/lib/sqlpath.sh" 2>/dev/null || true
  fi
fi
if ! command -v agmsg_type_get >/dev/null 2>&1; then
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/type-registry.sh" 2>/dev/null || true
  elif [ -n "${SKILL_DIR:-}" ]; then
    # shellcheck disable=SC1091
    . "$SKILL_DIR/scripts/lib/type-registry.sh" 2>/dev/null || true
  fi
fi

# resolve_hooks_file は delivery.sh から移動した共有実装である。type の
# manifest hooks_file= (project-relative) を project 絶対パスへ解決する。
# human renderer と evaluator の双方がここを使う。
resolve_hooks_file() {
  local type="$1"
  local project="$2"
  local rel
  rel="$(agmsg_type_get "$type" hooks_file)"
  if [ -z "$rel" ]; then
    echo "Unknown agent type: $type" >&2
    return 1
  fi
  case "$rel" in
    /*|*..*) echo "Invalid hooks_file for $type: $rel" >&2; return 1 ;;
  esac
  echo "$project/$rel"
}

# agmsg_delivery_eval_mode <type> <project>
#   成功時: AGMSG_DELIVERY_EVAL_MODE に full mode string を設定し rc 0。
#   失敗時 (unknown type / resolve 失敗等): rc 非ゼロ (呼び出し側は
#   delivery_status_failed 相当の diagnostic_failure へ正規化する)。
# human の "mode: ..." 行と同一値を返すが、human text を経由しない。
agmsg_delivery_eval_mode() {
  local type="$1" project="$2"
  AGMSG_DELIVERY_EVAL_MODE=""
  AGMSG_DELIVERY_EVAL_OK=0

  # delivery_modes=off のみの type (agmsg-app, hermes) は hook file を
  # 持たず mode は常に off である。manifest で判定し、存在しない type は
  # 失敗として返す (usage ではなく evaluator 失敗として扱うのは呼び側)。
  local modes=""
  modes="$(agmsg_type_get "$type" delivery_modes 2>/dev/null || true)"
  if [ -z "$modes" ]; then
    # manifest に key がない type は full set 扱い (delivery.sh do_set と同一)。
    modes="monitor turn both off"
  fi
  # 未知 type (manifest 自体がない) は agmsg_type_get が空を返し続けるが、
  # resolve_hooks_file が Unknown agent type で失敗するため、ここでは
  # modes のみで未知判定しない。delivery_modes=off 単独の既知 type だけ
  # を早期 off とする。
  if [ "$modes" = "off" ]; then
    # hermes は hooks_file を持たないため resolve せず off を返す。
    # agmsg-app も同様 (no agmsg-side delivery)。
    AGMSG_DELIVERY_EVAL_MODE="off"
    AGMSG_DELIVERY_EVAL_OK=1
    return 0
  fi

  local hf=""
  hf="$(resolve_hooks_file "$type" "$project")" || return 1

  # type plug が agmsg_delivery_status を override しているかで JSON-hook
  # 系か rule-file 系かを構造的に判定する (human text の parse ではない)。
  # 判定は plug file の存在と override 有無のみに基づく。
  local plug_has_status_override=0
  if [ -n "${SKILL_DIR:-}" ]; then
    local _plug_path="$SKILL_DIR/scripts/drivers/types/$type/_delivery.sh"
    if [ -f "$_plug_path" ] && grep -q '^agmsg_delivery_status()' "$_plug_path" 2>/dev/null; then
      plug_has_status_override=1
    fi
  fi

  if [ "$plug_has_status_override" -eq 0 ]; then
    # --- default JSON event-hooks 系 (claude-code, codex 等) ---
    # delivery.sh agmsg_delivery_status_default と同一 SQL 判定を structured
    # に行う。human renderer はこの値を "mode: ..." として描画する。
    local has_ss=0 has_st=0 hf_readable=0
    if [ -f "$hf" ]; then
      local sql_hf
      sql_hf="$(agmsg_sql_readfile_path "$hf")" || return 1
      local valid=""
      valid="$(agmsg_sqlite_mem "SELECT json_valid(readfile('$sql_hf'));" 2>/dev/null || echo "")"
      if [ "$valid" = "1" ]; then
        hf_readable=1
        local skill="${SKILL_NAME:-$(basename "${SKILL_DIR:-agmsg}")}"
        has_ss="$(agmsg_sqlite_mem "
          SELECT EXISTS(
            SELECT 1 FROM json_each(json_extract(readfile('$sql_hf'), '\$.hooks.SessionStart')) AS s,
              json_each(json_extract(s.value, '\$.hooks')) AS h
            WHERE instr(json_extract(h.value, '\$.command'), '$skill') > 0
          );" 2>/dev/null || echo 0)"
        has_st="$(agmsg_sqlite_mem "
          SELECT EXISTS(
            SELECT 1 FROM json_each(json_extract(readfile('$sql_hf'), '\$.hooks.Stop')) AS s,
              json_each(json_extract(s.value, '\$.hooks')) AS h
            WHERE instr(json_extract(h.value, '\$.command'), '$skill') > 0
          );" 2>/dev/null || echo 0)"
      fi
    fi
    local mode="off (no agmsg delivery hooks installed for this project)"
    if [ "$has_ss" = "1" ] && [ "$has_st" = "1" ]; then mode="both"
    elif [ "$has_ss" = "1" ]; then mode="monitor"
    elif [ "$has_st" = "1" ]; then mode="turn"
    elif [ ! -f "$hf" ] || [ "$hf_readable" != "1" ]; then
      if [ ! -f "$hf" ]; then
        if [ -n "$hf" ]; then
          mode="off (unrecognized: no settings file found at $hf -- this project may not be registered)"
        else
          mode="off (unrecognized: could not resolve a settings file for this project/type)"
        fi
      else
        mode="off (unrecognized: settings file at $hf could not be read as valid JSON)"
      fi
    fi
    AGMSG_DELIVERY_EVAL_MODE="$mode"
    AGMSG_DELIVERY_EVAL_OK=1
    return 0
  fi

  # --- rule-file 系 (存在 + monitor marker が観測源) ---
  # human renderer (rulefile_status / opencode / grok-build) と同一ファイル
  # を直接読む。human text を経由しない。
  if [ ! -f "$hf" ]; then
    AGMSG_DELIVERY_EVAL_MODE="off"
    AGMSG_DELIVERY_EVAL_OK=1
    return 0
  fi
  if grep -q "agmsg-delivery-mode: monitor" "$hf" 2>/dev/null; then
    AGMSG_DELIVERY_EVAL_MODE="monitor"
  else
    AGMSG_DELIVERY_EVAL_MODE="turn"
  fi
  AGMSG_DELIVERY_EVAL_OK=1
  return 0
}

# agmsg_delivery_eval_watchers
#   installation-wide watcher 状態を数える。human renderer
#   (agmsg_delivery_runtime_status_default) と同一 run/*.pid を観測源とし、
#   human text を parse しない。
#   設定: AGMSG_DELIVERY_EVAL_WATCH_ALIVE / _STALE。rc 0 が成功。
agmsg_delivery_eval_watchers() {
  AGMSG_DELIVERY_EVAL_WATCH_ALIVE=0
  AGMSG_DELIVERY_EVAL_WATCH_STALE=0
  local rdir="${RUN_DIR:-}"
  [ -n "$rdir" ] || return 0
  if [ ! -d "$rdir" ]; then
    return 0
  fi
  local alive=0 dead=0 f pid
  for f in "$rdir"/watch.*.pid; do
    [ -f "$f" ] || continue
    pid="$(cat "$f" 2>/dev/null || echo "")"
    if [ -n "$pid" ] && _agmsg_pid_alive_local "$pid" 2>/dev/null; then
      alive=$((alive + 1))
    else
      dead=$((dead + 1))
    fi
  done
  AGMSG_DELIVERY_EVAL_WATCH_ALIVE="$alive"
  AGMSG_DELIVERY_EVAL_WATCH_STALE="$dead"
  return 0
}

# agmsg_delivery_eval_scoped_stale <type> <project>
#   per-(project,type) の stale pidfile 有無を structured に判定する。
#   設定: AGMSG_DELIVERY_EVAL_SCOPED_STALE (0/1)。rc 0 が評価成功、
#   rc 非ゼロは評価失敗 (呼び側は diagnostic_failure へ)。
#   default runtime 系は scoped stale を持たず常に 0 (global が担う)。
#   codex は bridge pidfile 群を直接検査する (human per-role 行と同一条件
#   だが text を経由しない)。
agmsg_delivery_eval_scoped_stale() {
  local type="$1" project="$2"
  AGMSG_DELIVERY_EVAL_SCOPED_STALE=0
  if [ "$type" != "codex" ]; then
    return 0
  fi
  local sdir="${SCRIPT_DIR:-}" rdir="${RUN_DIR:-}"
  [ -n "$sdir" ] && [ -n "$rdir" ] || return 1
  local pairs=""
  pairs="$("$sdir/identities.sh" "$project" "$type" 2>/dev/null)" || return 1
  [ -n "$pairs" ] || return 0
  local team name key pidf pid metafile meta_pid meta_project meta_type meta_ok
  local want_proj have_proj
  while IFS="$(printf '\t')" read -r team name; do
    [ -n "$team" ] || continue
    [ -n "$name" ] || continue
    key="$team.$name"
    pidf="$rdir/codex-bridge.$key.pid"
    [ -f "$pidf" ] || continue
    pid="$(cat "$pidf" 2>/dev/null || true)"
    if [ -z "$pid" ]; then
      AGMSG_DELIVERY_EVAL_SCOPED_STALE=1
      return 0
    fi
    metafile="$rdir/codex-bridge.$key.meta"
    if [ ! -f "$metafile" ]; then
      AGMSG_DELIVERY_EVAL_SCOPED_STALE=1
      return 0
    fi
    meta_ok=1
    meta_pid="$(awk -F= '/^pid=/{sub(/^pid=/, ""); print; exit}' "$metafile" 2>/dev/null || true)"
    meta_project="$(awk -F= '/^project=/{sub(/^project=/, ""); print; exit}' "$metafile" 2>/dev/null || true)"
    meta_type="$(awk -F= '/^type=/{sub(/^type=/, ""); print; exit}' "$metafile" 2>/dev/null || true)"
    [ -n "$meta_pid" ] && [ "$meta_pid" != "$pid" ] && meta_ok=0
    if [ -n "$meta_project" ] && command -v agmsg_canonical_path >/dev/null 2>&1; then
      want_proj="$(agmsg_normalize_project_path "$(agmsg_canonical_path "$project" 2>/dev/null || printf '%s' "$project")" 2>/dev/null || printf '%s' "$project")"
      have_proj="$(agmsg_normalize_project_path "$(agmsg_canonical_path "$meta_project" 2>/dev/null || printf '%s' "$meta_project")" 2>/dev/null || printf '%s' "$meta_project")"
      [ "$have_proj" != "$want_proj" ] && meta_ok=0
    elif [ -n "$meta_project" ] && [ "$meta_project" != "$project" ]; then
      meta_ok=0
    fi
    [ -n "$meta_type" ] && [ "$meta_type" != "$type" ] && meta_ok=0
    if [ "$meta_ok" -ne 1 ]; then
      AGMSG_DELIVERY_EVAL_SCOPED_STALE=1
      return 0
    fi
    if command -v _agmsg_pid_alive >/dev/null 2>&1; then
      if ! _agmsg_pid_alive "$pid" 2>/dev/null; then
        AGMSG_DELIVERY_EVAL_SCOPED_STALE=1
        return 0
      fi
    elif command -v _agmsg_pid_alive_local >/dev/null 2>&1; then
      if ! _agmsg_pid_alive_local "$pid" 2>/dev/null; then
        AGMSG_DELIVERY_EVAL_SCOPED_STALE=1
        return 0
      fi
    fi
  done <<< "$pairs"
  return 0
}
