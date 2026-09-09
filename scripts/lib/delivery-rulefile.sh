#!/usr/bin/env bash
# Shared "rule-file" delivery behavior.
#
# Some agent types integrate by writing a small markdown rules file that tells
# the agent to poll the agmsg inbox after each tool call (gemini, antigravity,
# opencode). Their per-type plug (scripts/drivers/types/<name>/_delivery.sh) is then a one-line
# delegation to rulefile_apply.
#
# Runs in delivery.sh's sourced context: resolve_hooks_file and SKILL_DIR are
# provided by the caller (delivery.sh sources this lib and the type plug).
rulefile_apply() {
  local type="$1" project="$2" mode="$3"
  local rule_file
  rule_file="$(resolve_hooks_file "$type" "$project")"

  # Always start clean; each mode rewrites (or leaves absent) the rule file.
  rm -f "$rule_file"

  case "$mode" in
    turn|both)
      mkdir -p "$(dirname "$rule_file")"
      cat > "$rule_file" <<EOF
# agmsg Integration Rule

## PostToolUse
After each tool call, automatically check the agmsg inbox for unread messages.
- Command: '$SKILL_DIR/scripts/check-inbox.sh' '$type' '$project'
EOF
      ;;
    monitor)
      echo "Warning: 'monitor' mode is not fully supported for $type yet. Using turn-based hook." >&2
      rulefile_apply "$type" "$project" turn
      ;;
    off)
      : # rule file already removed
      ;;
  esac
}

# Status for rule-file types: mode 判定は共有 evaluator が SSOT であり、
# human renderer は描画のみを行う (P1-4)。doctor も同一 evaluator を直接
# 呼ぶため wording 変更では machine JSON は壊れない。
rulefile_status() {
  local type="$1" project="$2"
  # evaluator が delivery-eval.sh 未 load の古い sourcing 順でも動くよう
  # 最低限の fallback を残すが、通常は evaluator が mode を返す。
  if command -v agmsg_delivery_eval_mode >/dev/null 2>&1; then
    local mode=""
    agmsg_delivery_eval_mode "$type" "$project" || return 1
    mode="$AGMSG_DELIVERY_EVAL_MODE"
    echo "mode: $mode"
  else
    local rule_file
    rule_file="$(resolve_hooks_file "$type" "$project")"
    if [ -f "$rule_file" ]; then echo "mode: turn"; else echo "mode: off"; fi
  fi
}
