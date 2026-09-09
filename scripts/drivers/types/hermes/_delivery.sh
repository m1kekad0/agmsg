#!/usr/bin/env bash
# hermes delivery plug — manual inbox checks only.
#
# Hermes has no agmsg automatic delivery hook: there is no SessionStart / Stop
# equivalent to write, so the only valid mode is `off` (enforced by
# delivery_modes=off in the manifest, which the central gate in delivery.sh
# checks). These overrides keep apply / status / teardown from touching a hook
# file or another agent type's watchers. Sourced into delivery.sh's context.

# Nothing to write — manual-only, so no hooks_file is resolved or created.
agmsg_delivery_apply() { :; }

# No hook file to read; the mode is always off (evaluator が SSOT, P1-4)。
agmsg_delivery_status() {
  if command -v agmsg_delivery_eval_mode >/dev/null 2>&1; then
    agmsg_delivery_eval_mode "$1" "$2" || return 1
    echo "mode: $AGMSG_DELIVERY_EVAL_MODE"
  else
    echo "mode: off"
  fi
}

# No watcher or bridge of our own. Do NOT fall through to the default teardown
# (which stops this project's watch.sh) — another agent type may hold a live
# watcher on the same project, and a hermes `set off` must not disturb it.
agmsg_delivery_on_disable() {
  echo "Hermes has no agmsg automatic delivery hook; manual inbox checks only."
}
