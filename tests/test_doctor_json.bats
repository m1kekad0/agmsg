#!/usr/bin/env bats

# doctor --json (Issue #8): stable machine-readable diagnostics.
#
# The JSON payload and the human-readable report share one structured
# observation/finding store collected during the scan -- these tests pin the
# JSON contract (schema, codes, targets, components, diagnosability, exit
# codes, stdout purity, redaction) and the human/JSON parity that proves no
# WARN-text parsing sits between them.

load test_helper

setup() {
  setup_test_env
  . "$SCRIPTS/lib/hash.sh"
  export AGMSG_AGENT_PID=""
  export PROJ="$(mktemp -d)"
  : > "$TEST_SKILL_DIR/fixpids"
  export FAKE_CODEX="$TEST_SKILL_DIR/fake-codex"
  printf '#!/usr/bin/env bash\necho "codex-cli 9.9.9-test"\n' > "$FAKE_CODEX"
  chmod +x "$FAKE_CODEX"
  export AGMSG_REAL_CODEX="$FAKE_CODEX"
  export AGMSG_CODEX_STATUS_PROBE_TIMEOUT_MS=50
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
}

teardown() {
  if [ -f "$TEST_SKILL_DIR/fixpids" ]; then
    while IFS= read -r _p; do
      [ -n "$_p" ] || continue
      kill "$_p" 2>/dev/null || true
    done < "$TEST_SKILL_DIR/fixpids"
  fi
  wait 2>/dev/null || true
  teardown_test_env
  rm -rf "$PROJ"
}

track_pid() { printf '%s\n' "$1" >> "$TEST_SKILL_DIR/fixpids"; }

dead_pid() {
  ( exit 0 ) & local _p=$!
  wait "$_p" 2>/dev/null || true
  printf '%s' "$_p"
}

foreign_pid() {
  sleep 60 >/dev/null 2>&1 3>&- 4>&- &
  local _p=$!
  track_pid "$_p"
  printf '%s' "$_p"
}

confirmed_pid() {
  bash -c 'exec -a "fakecodex app-server --listen ws://127.0.0.1:0" sleep 60' >/dev/null 2>&1 3>&- 4>&- &
  local _p=$!
  track_pid "$_p"
  printf '%s' "$_p"
}

start_listener() {
  local _portfile="$1"
  python3 - "$_portfile" <<'EOF' >/dev/null 2>&1 3>&- 4>&- &
import socket, sys, time
portfile = sys.argv[1]
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(16)
open(portfile, "w").write(str(s.getsockname()[1]))
time.sleep(60)
EOF
  track_pid $!
  local _waited=0
  while [ ! -s "$_portfile" ] && [ "$_waited" -lt 100 ]; do
    sleep 0.05
    _waited=$((_waited + 1))
  done
  cat "$_portfile"
}

# Run doctor --json with stdout/stderr separated. Result status in
# JSON_STATUS, payload in $JSON_OUT, diagnostics in $JSON_ERR. Called
# directly (not via `run`) so redirections stay separate.
run_json() {
  JSON_OUT="$TEST_SKILL_DIR/stdout.json"
  JSON_ERR="$TEST_SKILL_DIR/stderr.txt"
  JSON_STATUS=0
  bash "$SCRIPTS/doctor.sh" --json "$@" >"$JSON_OUT" 2>"$JSON_ERR" || JSON_STATUS=$?
}

json_get() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))'"$1"')' "$JSON_OUT"
}

assert_valid_json() {
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$JSON_OUT"
}

# Explicit-failure assertion helpers for the ABI/security tests below: a
# bare failing [[ ... ]] aborts the test under set -e with no message, so
# these name the expectation and the actual value instead.
fail_assert() {
  echo "ASSERT-FAIL: $1" >&2
  return 1
}

assert_json_eq() {
  local actual expected="$2"
  actual="$(json_get "$1")"
  if [ "$actual" != "$expected" ]; then
    fail_assert "json $1: expected [$expected], got [$actual]"
  fi
}

assert_json_python() {
  # $1: python expression over loaded payload `d` (stdout.json); $2: message.
  if ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert ('"$1"'), sys.argv[2]' "$JSON_OUT" "$2"; then
    fail_assert "$2"
  fi
}

assert_absent() {
  # $1: raw value that must not appear anywhere in the payload; $2: label.
  if grep -qF "$1" "$JSON_OUT"; then
    fail_assert "payload leaks $2"
  fi
}

configured_off() {
  mkdir -p "$1/.claude"
  printf '%s\n' '{"hooks":{}}' > "$1/.claude/settings.local.json"
}

# --- core contract ---------------------------------------------------------

@test "doctor --json: healthy scope is rc 0 with empty findings and diagnosable true" {
  configured_off "$PROJ"
  run_json --project "$PROJ" --type claude-code
  [ "$JSON_STATUS" -eq 0 ]
  assert_valid_json
  [ "$(json_get '["schema_version"]')" = "1" ]
  [ "$(json_get '["diagnosable"]')" = "True" ]
  [ "$(json_get '["global_findings"]')" = "[]" ]
  [ "$(json_get '["summary"]["findings"]')" = "0" ]
  [ "$(json_get '["summary"]["registrations"]')" = "1" ]
  [ "$(json_get '["summary"]["scopes"]')" = "1" ]
  [ "$(json_get '["scopes"][0]["diagnosable"]')" = "True" ]
  [ "$(json_get '["scopes"][0]["findings"]')" = "[]" ]
  [ "$(json_get '["scopes"][0]["project"]')" = "$PROJ" ]
  [ "$(json_get '["scope"]["project"]')" = "$PROJ" ]
  [ "$(json_get '["scope"]["type"]')" = "claude-code" ]
}

@test "doctor --json: stale lock is rc 1 with a lock_stale condition on a registration target" {
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "deadtoken.999999" > "$TEST_SKILL_DIR/run/actas.team__alice.session"

  run_json --project "$PROJ" --type claude-code
  [ "$JSON_STATUS" -eq 1 ]
  assert_valid_json
  [ "$(json_get '["diagnosable"]')" = "True" ]
  [ "$(json_get '["summary"]["findings"]')" = "1" ]
  [ "$(json_get '["scopes"][0]["findings"][0]["code"]')" = "lock_stale" ]
  [ "$(json_get '["scopes"][0]["findings"][0]["kind"]')" = "condition" ]
  [ "$(json_get '["scopes"][0]["findings"][0]["category"]')" = "messaging" ]
  [ "$(json_get '["scopes"][0]["findings"][0]["target"]["kind"]')" = "registration" ]
  [ "$(json_get '["scopes"][0]["findings"][0]["target"]["team"]')" = "team" ]
  [ "$(json_get '["scopes"][0]["findings"][0]["target"]["agent"]')" = "alice" ]
  [ "$(json_get '["scopes"][0]["registrations"][0]["lock"]')" = "stale" ]
}

@test "doctor --json: live lock without watcher is lock_no_watcher, not a second stale warning" {
  mkdir -p "$TEST_SKILL_DIR/run"
  local owner="livetoken.$$"
  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/actas.team__alice.session"
  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/cc-instance.$$"

  run_json --project "$PROJ" --type claude-code
  [ "$JSON_STATUS" -eq 1 ]
  [ "$(json_get '["summary"]["findings"]')" = "1" ]
  [ "$(json_get '["scopes"][0]["findings"][0]["code"]')" = "lock_no_watcher" ]
  [ "$(json_get '["scopes"][0]["registrations"][0]["lock"]')" = "alive" ]
  [ "$(json_get '["scopes"][0]["registrations"][0]["watcher"]')" = "none" ]
}

@test "doctor --json: turn-mode multi-registration carries a scope-level (null target) finding" {
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$PROJ" >/dev/null

  run_json --project "$PROJ" --type claude-code
  [ "$JSON_STATUS" -eq 1 ]
  [ "$(json_get '["scopes"][0]["findings"][0]["code"]')" = "turn_mode_multi_registration" ]
  [ "$(json_get '["scopes"][0]["findings"][0]["target"]')" = "None" ]
  [ "$(json_get '["scopes"][0]["delivery"]["mode"]')" = "turn" ]
}

@test "doctor --json: empty installation is rc 0 with empty scopes" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null

  run_json
  [ "$JSON_STATUS" -eq 0 ]
  assert_valid_json
  [ "$(json_get '["diagnosable"]')" = "True" ]
  [ "$(json_get '["scopes"]')" = "[]" ]
  [ "$(json_get '["summary"]["teams"]')" = "0" ]
  [ "$(json_get '["summary"]["registrations"]')" = "0" ]
  [ "$(json_get '["summary"]["scopes"]')" = "0" ]
  [ "$(json_get '["summary"]["findings"]')" = "0" ]
}

@test "doctor --json: explicit filter matching nothing is rc 2 with empty stdout" {
  local rc=0
  bash "$SCRIPTS/doctor.sh" --json --project "$(mktemp -d)" >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  [ "$rc" -eq 2 ]
  [ ! -s "$TEST_SKILL_DIR/out.txt" ]
  grep -q "no registrations match this scope" "$TEST_SKILL_DIR/err.txt"
}

@test "doctor --json: unknown --type is rc 2 with empty stdout" {
  local rc=0
  bash "$SCRIPTS/doctor.sh" --json --type not-a-real-type >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  [ "$rc" -eq 2 ]
  [ ! -s "$TEST_SKILL_DIR/out.txt" ]
  grep -q "unknown agent type" "$TEST_SKILL_DIR/err.txt"
}

@test "doctor --json: missing python3 is rc 2 with empty stdout" {
  # A PATH holding no python3 at all: only dirname (needed for the script's
  # own startup path resolution) is provided. The serializer dependency
  # check must fire before anything touches sqlite or run/.
  local empty_bin="$TEST_SKILL_DIR/min-bin"
  mkdir -p "$empty_bin"
  ln -s "$(command -v dirname)" "$empty_bin/dirname"
  local rc=0 bash_bin
  bash_bin="$(command -v bash)"
  PATH="$empty_bin" "$bash_bin" "$SCRIPTS/doctor.sh" --json --project "$PROJ" >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  [ "$rc" -eq 2 ]
  [ ! -s "$TEST_SKILL_DIR/out.txt" ]
  grep -q "requires python3" "$TEST_SKILL_DIR/err.txt"
}

@test "doctor --json: failing delivery.sh status is a diagnostic_failure with scope diagnosable false" {
  mv "$SCRIPTS/delivery.sh" "$SCRIPTS/delivery.sh.hidden"

  run_json --project "$PROJ" --type claude-code
  local rc="$JSON_STATUS"
  mv "$SCRIPTS/delivery.sh.hidden" "$SCRIPTS/delivery.sh"
  [ "$rc" -eq 1 ]
  assert_valid_json
  [ "$(json_get '["scopes"][0]["findings"][0]["code"]')" = "delivery_status_failed" ]
  [ "$(json_get '["scopes"][0]["findings"][0]["kind"]')" = "diagnostic_failure" ]
  [ "$(json_get '["scopes"][0]["diagnosable"]')" = "False" ]
  [ "$(json_get '["diagnosable"]')" = "False" ]
  [ "$(json_get '["scopes"][0]["delivery"]["status"]')" = "failed" ]
}

@test "doctor --json: stale global watcher pidfile is a global condition finding" {
  mkdir -p "$TEST_SKILL_DIR/run"
  local dead
  dead="$(dead_pid)"
  printf '%s\n' "$dead" > "$TEST_SKILL_DIR/run/watch.faketoken.pid"

  run_json --project "$PROJ" --type claude-code
  [ "$JSON_STATUS" -eq 1 ]
  [ "$(json_get '["global_findings"][0]["code"]')" = "watcher_stale_pidfile_global" ]
  [ "$(json_get '["global_findings"][0]["kind"]')" = "condition" ]
  [ "$(json_get '["global_findings"][0]["target"]')" = "None" ]
  [ "$(json_get '["global_findings"][0]["scope"]')" = "{'project': None, 'type': None}" ]
  [ "$(json_get '["diagnosable"]')" = "True" ]
}

@test "doctor --json: multiple scopes are all represented with correct summary counts" {
  configured_off "$PROJ"
  local other_proj
  other_proj="$(mktemp -d)"
  bash "$SCRIPTS/join.sh" other bob claude-code "$other_proj" >/dev/null
  configured_off "$other_proj"

  run_json
  [ "$JSON_STATUS" -eq 0 ]
  [ "$(json_get '["summary"]["scopes"]')" = "2" ]
  [ "$(json_get '["summary"]["registrations"]')" = "2" ]
  [ "$(json_get '["summary"]["teams"]')" = "2" ]
  rm -rf "$other_proj"
}

@test "doctor --json: stdout on rc 0/1 is a single pure JSON payload" {
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "deadtoken.999999" > "$TEST_SKILL_DIR/run/actas.team__alice.session"

  local rc=0
  bash "$SCRIPTS/doctor.sh" --json --project "$PROJ" --type claude-code >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  [ "$rc" -eq 1 ]
  # Exactly one line, parses as JSON, and the whole file round-trips.
  [ "$(wc -l < "$TEST_SKILL_DIR/out.txt" | tr -d ' ')" = "1" ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["schema_version"] == 1' "$TEST_SKILL_DIR/out.txt"
  python3 -c 'import json,sys; raw=open(sys.argv[1]).read(); assert raw.endswith("\n") and raw.count("\n") == 1' "$TEST_SKILL_DIR/out.txt"
}

# --- codex plug: structured findings, components, signals -------------------

proj_hash() { printf '%s' "$1" | agmsg_sha1; }

write_appserver() {
  local _h
  _h="$(proj_hash "$1")"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$2" > "$TEST_SKILL_DIR/run/codex-app-server.$_h.pid"
  printf '%s\n' "$3" > "$TEST_SKILL_DIR/run/codex-app-server.$_h.port"
  printf '%s\n' "$4" > "$TEST_SKILL_DIR/run/codex-app-server.$_h.version"
}

@test "doctor --json: codex dead pid plus silent port are stable findings with component target" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  local dead
  dead="$(dead_pid)"
  write_appserver "$PROJ" "$dead" "64321" "codex-cli 9.9.9-test"

  run_json --project "$PROJ" --type codex
  [ "$JSON_STATUS" -eq 1 ]
  [ "$(json_get '["scopes"][0]["findings"][0]["code"]')" = "codex_pid_stale" ]
  [ "$(json_get '["scopes"][0]["findings"][1]["code"]')" = "codex_endpoint_unresponsive" ]
  [ "$(json_get '["scopes"][0]["findings"][0]["target"]["kind"]')" = "component" ]
  [ "$(json_get '["scopes"][0]["findings"][0]["target"]["component_id"]')" = "codex_app_server" ]
  [ "$(json_get '["scopes"][0]["findings"][0]["target"]["instance"]')" = "None" ]
  [ "$(json_get '["scopes"][0]["components"][0]["id"]')" = "codex_app_server" ]
  [ "$(json_get '["scopes"][0]["components"][0]["instance"]')" = "None" ]
  [ "$(json_get '["scopes"][0]["components"][0]["signals"][0]')" = "{'code': 'process', 'status': 'dead'}" ]
  [ "$(json_get '["scopes"][0]["components"][0]["signals"][1]')" = "{'code': 'endpoint', 'status': 'silent'}" ]
}

@test "doctor --json: codex invalid pid and port records each have their own code" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  write_appserver "$PROJ" "not-a-pid" "99999" "codex-cli 9.9.9-test"

  run_json --project "$PROJ" --type codex
  [ "$JSON_STATUS" -eq 1 ]
  [ "$(json_get '["scopes"][0]["findings"][0]["code"]')" = "codex_pid_invalid" ]
  [ "$(json_get '["scopes"][0]["findings"][1]["code"]')" = "codex_endpoint_invalid" ]
}

@test "doctor --json: codex version drift warns with a stable code, never a kill verdict" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  local port pid
  port="$(start_listener "$TEST_SKILL_DIR/port.txt")"
  pid="$(confirmed_pid)"
  write_appserver "$PROJ" "$pid" "$port" "codex-cli 0.145.0"

  run_json --project "$PROJ" --type codex
  [ "$JSON_STATUS" -eq 1 ]
  python3 -c 'import json,sys; fs=json.load(open(sys.argv[1]))["scopes"][0]["findings"]; assert any(f["code"]=="codex_version_drift" for f in fs)' "$JSON_OUT"
  python3 -c 'import json,sys; raw=open(sys.argv[1]).read().lower(); assert "kill" not in raw' "$JSON_OUT"
  kill -0 "$pid"
}

@test "doctor --json: codex bridge stale binding carries a registration-scoped component instance" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  local port pid bpid
  port="$(start_listener "$TEST_SKILL_DIR/port.txt")"
  pid="$(confirmed_pid)"
  write_appserver "$PROJ" "$pid" "$port" "codex-cli 9.9.9-test"
  bpid="$(foreign_pid)"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$bpid" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  {
    echo "pid=$bpid"
    echo "project=$PROJ"
    echo "identities=team/alice"
    echo "type=codex"
  } > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.meta"
  printf '%s' "ws://127.0.0.1:1" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.appserver"
  printf '%s' "thread-old" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.thread"

  run_json --project "$PROJ" --type codex
  [ "$JSON_STATUS" -eq 1 ]
  python3 -c 'import json,sys; fs=json.load(open(sys.argv[1]))["scopes"][0]["findings"]; assert any(f["code"]=="codex_bridge_stale_binding" for f in fs)' "$JSON_OUT"
  [ "$(python3 -c 'import json,sys; fs=json.load(open(sys.argv[1]))["scopes"][0]["findings"]; t=[f["target"] for f in fs if f["code"]=="codex_bridge_stale_binding"][0]; print(t["kind"], t["component_id"], t["instance"]["kind"], t["instance"]["team"], t["instance"]["agent"])' "$JSON_OUT")" = "component codex_bridge registration team alice" ]
  [ "$(python3 -c 'import json,sys; cs=json.load(open(sys.argv[1]))["scopes"][0]["components"]; i=[c for c in cs if c["id"]=="codex_bridge"][0]["instance"]; print(i["kind"], i["team"], i["agent"])' "$JSON_OUT")" = "registration team alice" ]
  kill -0 "$bpid"
}

@test "doctor --json: two bridge instances do not collide; signals carry no health verdict" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
  local dead1 dead2
  dead1="$(dead_pid)"
  dead2="$(dead_pid)"
  mkdir -p "$TEST_SKILL_DIR/run"
  for pair in "alice:$dead1" "bob:$dead2"; do
    local name="${pair%%:*}" dpid="${pair##*:}"
    printf '%s\n' "$dpid" > "$TEST_SKILL_DIR/run/codex-bridge.team.$name.pid"
    printf '%s' "ws://127.0.0.1:1" > "$TEST_SKILL_DIR/run/codex-bridge.team.$name.appserver"
    printf '%s' "thread-$name" > "$TEST_SKILL_DIR/run/codex-bridge.team.$name.thread"
  done

  run_json --project "$PROJ" --type codex
  [ "$JSON_STATUS" -eq 1 ]
  [ "$(python3 -c 'import json,sys; cs=json.load(open(sys.argv[1]))["scopes"][0]["components"]; print(len([c for c in cs if c["id"]=="codex_bridge"]))' "$JSON_OUT")" = "2" ]
  # No health verdict anywhere in components; signals are code/status observations only.
  python3 -c 'import json,sys; raw=open(sys.argv[1]).read(); d=json.load(open(sys.argv[1]));
for c in d["scopes"][0]["components"]:
    assert set(c.keys()) == {"id", "instance", "signals"}, c
    for s in c["signals"]:
        assert set(s.keys()) == {"code", "status"}, s
assert "\"healthy\"" not in raw and "\"warning\"" not in raw' "$JSON_OUT"
  [ "$(python3 -c 'import json,sys; fs=json.load(open(sys.argv[1]))["scopes"][0]["findings"]; print(len([f for f in fs if f["code"]=="codex_bridge_stale_pidfile"]))' "$JSON_OUT")" = "2" ]
}

@test "doctor --json: components expose no raw pid, socket, or endpoint URL fields" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  local port pid
  port="$(start_listener "$TEST_SKILL_DIR/port.txt")"
  pid="$(confirmed_pid)"
  write_appserver "$PROJ" "$pid" "$port" "codex-cli 9.9.9-test"

  run_json --project "$PROJ" --type codex
  [ "$JSON_STATUS" -eq 0 ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1]));
comp_keys = set()
for c in d["scopes"][0]["components"]:
    comp_keys.update(c.keys())
    for s in c["signals"]:
        comp_keys.update(s.keys())
banned = {"pid", "port", "url", "endpoint", "socket", "handle", "path"}
assert not (comp_keys & banned), comp_keys' "$JSON_OUT"
  refute grep -q "\"pid\"" "$JSON_OUT"
}

@test "doctor --json: human warnings and JSON findings come from the same source (count parity)" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  local dead
  dead="$(dead_pid)"
  write_appserver "$PROJ" "$dead" "64321" "codex-cli 9.9.9-test"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "deadtoken.999999" > "$TEST_SKILL_DIR/run/actas.team__alice.session"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 1 ] # human run
  local human_warnings
  human_warnings="$(printf '%s\n' "$output" | grep -c '^  - ')"
  run_json --project "$PROJ" --type codex
  [ "$JSON_STATUS" -eq 1 ]
  [ "$(json_get '["summary"]["findings"]')" = "$human_warnings" ]
}

# --- legacy-only plug: JSON fail-closed, human compatible -------------------

install_legacy_plug() {
  # A legacy-only plug for claude-code: legacy WARN protocol, no structured
  # collectors. exercising the JSON fail-closed path.
  cat > "$TYPES/claude-code/_doctor.sh" <<'EOF'
[ -n "${_AGMSG_LEGACY_FIXTURE_SH:-}" ] && return 0
_AGMSG_LEGACY_FIXTURE_SH=1
agmsg_doctor_extra_status() {
  echo "Codex legacy line for display"
  echo "WARN: legacy fixture warning (unstructured)"
  return 0
}
agmsg_doctor_extra_global() {
  echo "WARN: legacy fixture global warning (unstructured)"
  return 0
}
EOF
}

@test "doctor --json: legacy-only plug is fail-closed with diagnostic_failure, human keeps legacy text" {
  install_legacy_plug
  configured_off "$PROJ"

  run_json --project "$PROJ" --type claude-code
  [ "$JSON_STATUS" -eq 1 ]
  [ "$(json_get '["scopes"][0]["diagnosable"]')" = "False" ]
  [ "$(json_get '["diagnosable"]')" = "False" ]
  [ "$(json_get '["scopes"][0]["findings"][0]["code"]')" = "legacy_plug_unstructured" ]
  [ "$(json_get '["scopes"][0]["findings"][0]["kind"]')" = "diagnostic_failure" ]
  # The legacy WARN wording is never parsed into the payload.
  refute grep -q "legacy fixture warning" "$JSON_OUT"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code
  [ "$status" -eq 1 ] # human run
  if ! printf '%s\n' "$output" | grep -qF "legacy fixture warning (unstructured)"; then
    fail_assert "human mode missing legacy warning text"
  fi
  if ! printf '%s\n' "$output" | grep -qF "Codex legacy line for display"; then
    fail_assert "human mode missing legacy display line"
  fi
}

@test "doctor --json: one undiagnosable scope does not discard the healthy scope" {
  install_legacy_plug
  configured_off "$PROJ"
  local other_proj
  other_proj="$(mktemp -d)"
  bash "$SCRIPTS/join.sh" other bob codex "$other_proj" >/dev/null

  run_json
  [ "$JSON_STATUS" -eq 1 ]
  [ "$(json_get '["diagnosable"]')" = "False" ]
  [ "$(python3 -c 'import json,sys; ds={ (s["project"],s["type"]): s["diagnosable"] for s in json.load(open(sys.argv[1]))["scopes"] }; print(ds[("'"$PROJ"'","claude-code")])' "$JSON_OUT")" = "False" ]
  [ "$(python3 -c 'import json,sys; ds={ (s["project"],s["type"]): s["diagnosable"] for s in json.load(open(sys.argv[1]))["scopes"] }; print(ds[("'"$other_proj"'","codex")])' "$JSON_OUT")" = "True" ]
  # Every undiagnosable scope carries its diagnostic_failure.
  [ "$(python3 -c 'import json,sys; ss=json.load(open(sys.argv[1]))["scopes"]; print(all(any(f["kind"]=="diagnostic_failure" for f in s["findings"]) for s in ss if not s["diagnosable"]))' "$JSON_OUT")" = "True" ]
  rm -rf "$other_proj"
}

# --- diagnosability rollup ---------------------------------------------------

@test "doctor --json: all scopes diagnosable implies top-level diagnosable" {
  configured_off "$PROJ"
  run_json
  [ "$JSON_STATUS" -eq 0 ]
  [ "$(json_get '["diagnosable"]')" = "True" ]
  [ "$(python3 -c 'import json,sys; print(all(s["diagnosable"] for s in json.load(open(sys.argv[1]))["scopes"]))' "$JSON_OUT")" = "True" ]
}

# --- redaction ---------------------------------------------------------------

@test "doctor --json --redacted: payload is paste-safe and shares pseudonyms with human output" {
  local home_proj="$HOME/redact-me"
  mkdir -p "$home_proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$home_proj" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  local owner="deadtoken.999999"
  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/actas.team__alice.session"

  run_json --project "$home_proj" --type claude-code --redacted
  [ "$JSON_STATUS" -eq 1 ]
  # Pseudonyms, not raw values, in structured fields ...
  [ "$(json_get '["scopes"][0]["project"]')" = "~/redact-me" ]
  [ "$(json_get '["scopes"][0]["registrations"][0]["team"]')" = "team1" ]
  [ "$(json_get '["scopes"][0]["registrations"][0]["agent"]')" = "agent1" ]
  # ... and nowhere else in the payload either.
  refute grep -qF "$owner" "$JSON_OUT"
  refute grep -qF "team/alice" "$JSON_OUT"
  refute grep -qF "$HOME" "$JSON_OUT"
  # Human output agrees on the same mapping.
  run bash "$SCRIPTS/doctor.sh" --project "$home_proj" --type claude-code --redacted
  if ! printf '%s\n' "$output" | grep -qF "team1/agent1"; then
    fail_assert "human report disagrees on pseudonyms"
  fi
}

@test "doctor --json --redacted: session-like identifiers are masked in evidence" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  local port pid bpid seat
  port="$(start_listener "$TEST_SKILL_DIR/port.txt")"
  pid="$(confirmed_pid)"
  write_appserver "$PROJ" "$pid" "$port" "codex-cli 9.9.9-test"
  bpid="$(foreign_pid)"
  seat="9f8e7d6c-5b4a-4f3e-8d2c-1a2b3c4d5e6f"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$bpid" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  printf '%s' "ws://127.0.0.1:1" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.appserver"
  printf '%s' "$seat-bound-old" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.thread"
  {
    echo "session=$seat-recorded-now"
    echo "name=team-alice"
    echo "team=team"
    echo "agent=alice"
    echo "type=codex"
    echo "project=$PROJ"
  } > "$TEST_SKILL_DIR/run/role-session.team__alice"

  run_json --project "$PROJ" --type codex --redacted
  [ "$JSON_STATUS" -eq 1 ]
  refute grep -qF "$seat" "$JSON_OUT"
  refute grep -qF "team.alice" "$JSON_OUT"
  refute grep -qF "$PROJ" "$JSON_OUT"
  kill -0 "$bpid"
}

@test "doctor --json --redacted: outside-HOME project is a numbered pseudonym everywhere" {
  case "$PROJ" in
    "$HOME"*) skip "fixture \$PROJ landed under \$HOME this run; this test needs it outside" ;;
  esac
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "deadtoken.999999" > "$TEST_SKILL_DIR/run/actas.team__alice.session"

  run_json --project "$PROJ" --type claude-code --redacted
  [ "$JSON_STATUS" -eq 1 ]
  [ "$(json_get '["scopes"][0]["project"]')" = "<project1>" ]
  [ "$(json_get '["scope"]["project"]')" = "<project1>" ]
  refute grep -qF "$PROJ" "$JSON_OUT"
}

# --- escaping / special characters ------------------------------------------

@test "doctor --json: quote/backslash in evidence still yields valid JSON" {
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' 'dead"token\\with.quotes.$$' > "$TEST_SKILL_DIR/run/actas.team__alice.session"

  run_json --project "$PROJ" --type claude-code
  [ "$JSON_STATUS" -eq 1 ]
  assert_valid_json
  [ "$(json_get '["scopes"][0]["findings"][0]["code"]')" = "lock_stale" ]
  python3 -c 'import json,sys; fs=json.load(open(sys.argv[1]))["scopes"][0]["findings"]; assert "dead\"token" in fs[0]["evidence"]' "$JSON_OUT"
}

@test "doctor --json: project path with spaces round-trips" {
  local spaced="$TEST_SKILL_DIR/my spaced proj"
  mkdir -p "$spaced"
  bash "$SCRIPTS/join.sh" team alice claude-code "$spaced" >/dev/null
  configured_off "$spaced"

  run_json --project "$spaced" --type claude-code
  [ "$JSON_STATUS" -eq 0 ]
  assert_valid_json
  [ "$(json_get '["scopes"][0]["project"]')" = "$spaced" ]
}

# --- installation-wide (global) records --------------------------------------
#
# Classification is by project presence only: empty-project records are
# global, keep their type, and never synthesize a fake "" scope.

write_orphan_appserver() {
  # An app-server triple whose hash matches no registered project.
  local _uh="abcdef0123456789abcdef0123456789abcdef01" dead
  dead="$(dead_pid)"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$dead" > "$TEST_SKILL_DIR/run/codex-app-server.$_uh.pid"
  printf '%s\n' "64331" > "$TEST_SKILL_DIR/run/codex-app-server.$_uh.port"
  printf '%s\n' "codex-cli 9.9.9-test" > "$TEST_SKILL_DIR/run/codex-app-server.$_uh.version"
}

@test "doctor --json: orphan app-server is a global finding, never a fake empty scope" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  configured_off "$PROJ"
  write_orphan_appserver

  run_json --type codex
  if [ "$JSON_STATUS" -ne 1 ]; then
    fail_assert "expected rc 1 for orphan records, got $JSON_STATUS"
  fi
  assert_valid_json
  assert_json_eq '["global_findings"][0]["code"]' "codex_pid_stale"
  assert_json_eq '["global_findings"][0]["kind"]' "condition"
  assert_json_eq '["global_findings"][0]["scope"]["project"]' "None"
  assert_json_eq '["global_findings"][0]["scope"]["type"]' "codex"
  assert_json_eq '["global_findings"][0]["target"]["kind"]' "component"
  assert_json_eq '["global_findings"][0]["target"]["component_id"]' "codex_app_server"
  # P1-6: global orphan は opaque instance を持ち、null へ group されない。
  assert_json_python 'd["global_findings"][0]["target"]["instance"] is not None and d["global_findings"][0]["target"]["instance"]["kind"]=="opaque"' 'global orphan finding target must carry an opaque instance'
  # The registered scope keeps its own (empty) findings; summary.scopes is
  # not inflated by the global record.
  assert_json_eq '["summary"]["scopes"]' "1"
  assert_json_eq '["scopes"][0]["project"]' "$PROJ"
  assert_json_python 'all(s["project"] for s in d["scopes"])' 'scopes[] contains an empty project'
  assert_json_python '"global_components" in d' 'global_components field missing'
}

@test "doctor --json: unattributed bridge is a global finding with a global component" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  local dead
  dead="$(dead_pid)"
  mkdir -p "$TEST_SKILL_DIR/run"
  # A launcher-generation key no per-pair call attributes (not team.alice).
  printf '%s\n' "$dead" > "$TEST_SKILL_DIR/run/codex-bridge.ghost.role.pid"
  printf '%s' "ws://127.0.0.1:1" > "$TEST_SKILL_DIR/run/codex-bridge.ghost.role.appserver"
  printf '%s' "thread-ghost" > "$TEST_SKILL_DIR/run/codex-bridge.ghost.role.thread"

  run_json --type codex
  if [ "$JSON_STATUS" -ne 1 ]; then
    fail_assert "expected rc 1 for unattributed bridge, got $JSON_STATUS"
  fi
  assert_valid_json
  assert_json_python 'any(f["code"]=="codex_bridge_stale_pidfile" and f["scope"]=={"project": None, "type": "codex"} for f in d["global_findings"])' 'missing global codex_bridge_stale_pidfile finding'
  # P1-6: global bridge は opaque instance を持ち、null へ group されない。
  assert_json_python 'any(c["id"]=="codex_bridge" and c["type"]=="codex" and c["instance"] is not None and c["instance"].get("kind")=="opaque" and any(s=={"code": "process", "status": "not-running"} for s in c["signals"]) for c in d["global_components"])' 'missing global codex_bridge component signal'
  assert_json_python 'all(s["project"] for s in d["scopes"])' 'scopes[] contains an empty project'
  assert_json_eq '["summary"]["scopes"]' "1"
}

@test "doctor --json: orphan app-server triple also surfaces a global component" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  write_orphan_appserver

  run_json --type codex
  if [ "$JSON_STATUS" -ne 1 ]; then
    fail_assert "expected rc 1 for orphan triple, got $JSON_STATUS"
  fi
  assert_valid_json
  # P1-6: global orphan は opaque instance を持つ。
  assert_json_python 'any(c["id"]=="codex_app_server" and c["type"]=="codex" and c["instance"] is not None and c["instance"].get("kind")=="opaque" for c in d["global_components"])' 'missing global codex_app_server component'
}

@test "doctor --json: codex untracked live app-server is a global opaque finding" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  configured_off "$PROJ"
  local _pid
  _pid="$(confirmed_pid)"
  # The process-table seam (see test_helper): one "pid args" line the scan
  # matches, while no record file anywhere claims the pid.
  printf '%s %s\n' "$_pid" "fakecodex app-server --listen ws://127.0.0.1:0" >> "$AGMSG_DOCTOR_PS_SNAPSHOT"

  run_json --type codex
  if [ "$JSON_STATUS" -ne 1 ]; then
    fail_assert "expected rc 1 for untracked process, got $JSON_STATUS"
  fi
  assert_valid_json
  assert_json_python 'any(f["code"]=="codex_process_untracked" and f["scope"]=={"project": None, "type": "codex"} and f["target"]["kind"]=="component" and f["target"]["component_id"]=="codex_app_server" for f in d["global_findings"])' 'missing global codex_process_untracked finding'
  assert_json_python 'any(c["id"]=="codex_app_server" and c["type"]=="codex" and c["instance"] is not None and c["instance"].get("kind")=="opaque" and any(s=={"code": "process", "status": "untracked-live"} for s in c["signals"]) for c in d["global_components"])' 'missing untracked-live component signal'
}

@test "doctor --json: codex stale dispatcher lock is a scoped component finding" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  configured_off "$PROJ"
  local _h _dead
  _h="$(proj_hash "$PROJ")"
  _dead="$(dead_pid)"
  ( export SKILL_DIR="$TEST_SKILL_DIR"
    . "$SCRIPTS/lib/storage.sh"
    agmsg_runtime_lock_acquire "codex-dispatcher:$_h" "$_dead" >/dev/null 2>&1 )

  run_json --project "$PROJ" --type codex
  if [ "$JSON_STATUS" -ne 1 ]; then
    fail_assert "expected rc 1 for stale dispatcher lock, got $JSON_STATUS"
  fi
  assert_valid_json
  assert_json_python 'any(f["code"]=="codex_dispatcher_lock_stale" and f["target"]["kind"]=="component" and f["target"]["component_id"]=="codex_dispatcher" for f in d["scopes"][0]["findings"])' 'missing codex_dispatcher_lock_stale finding'
  assert_json_python 'any(c["id"]=="codex_dispatcher" and any(s=={"code": "lock", "status": "held-stale"} for s in c["signals"]) for c in d["scopes"][0]["components"])' 'missing codex_dispatcher lock=held-stale signal'
}

@test "doctor --json: codex lock under the canonical spelling is one aggregated signal" {
  # A symlinked registration: the lock resource lives under the physical
  # path's hash while the scope hash is the link spelling. Both spellings
  # name one logical lock, so the component must carry exactly one lock
  # signal — lock=none next to lock=held-stale would be undecidable.
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  local _real="$TEST_SKILL_DIR/real-proj" _link="$TEST_SKILL_DIR/link-proj"
  mkdir -p "$_real"
  ln -s "$_real" "$_link"
  bash "$SCRIPTS/join.sh" team alice codex "$_link" >/dev/null
  configured_off "$_link"
  local _phys _dead
  _phys="$(cd "$_link" && pwd -P)"
  _dead="$(dead_pid)"
  ( export SKILL_DIR="$TEST_SKILL_DIR"
    . "$SCRIPTS/lib/storage.sh"
    agmsg_runtime_lock_acquire "codex-dispatcher:$(proj_hash "$_phys")" "$_dead" >/dev/null 2>&1 )

  run_json --project "$_link" --type codex
  if [ "$JSON_STATUS" -ne 1 ]; then
    fail_assert "expected rc 1 for stale dispatcher lock, got $JSON_STATUS"
  fi
  assert_valid_json
  assert_json_python 'sum(1 for c in d["scopes"][0]["components"] if c["id"]=="codex_dispatcher" for s in c["signals"] if s["code"]=="lock") == 1' 'expected exactly one aggregated lock signal'
  assert_json_python 'any(c["id"]=="codex_dispatcher" and any(s=={"code": "lock", "status": "held-stale"} for s in c["signals"]) for c in d["scopes"][0]["components"])' 'missing aggregated held-stale signal'
  assert_json_python 'sum(1 for f in d["scopes"][0]["findings"] if f["code"]=="codex_dispatcher_lock_stale") == 1' 'expected exactly one stale-lock finding'
}

@test "doctor --json: codex orphan seat is a scoped-nameless global component, never a warning" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  configured_off "$PROJ"
  mkdir -p "$TEST_SKILL_DIR/run"
  {
    echo "session=thread-gone"
    echo "name=gone-role"
    echo "team=gone"
    echo "agent=role"
    echo "type=codex"
    echo "project=$PROJ"
  } > "$TEST_SKILL_DIR/run/role-session.gone__role"

  run_json --type codex
  if [ "$JSON_STATUS" -ne 0 ]; then
    fail_assert "orphan seat must not warn, got $JSON_STATUS"
  fi
  assert_valid_json
  assert_json_eq '["global_findings"]' "[]"
  assert_json_python 'any(c["id"]=="codex_role_session" and c["instance"]=={"kind": "registration", "team": "gone", "agent": "role"} and any(s=={"code": "seat", "status": "orphan"} for s in c["signals"]) for c in d["global_components"])' 'missing orphan seat component'
}

# --- collector failure: diagnostic_failure, never empty-stdout rc 1 ---------

install_failing_plug() {
  # $1: per-pair exit, $2: global exit. A structured plug whose collector
  # fails without recording anything.
  cat > "$TYPES/claude-code/_doctor.sh" <<EOF
[ -n "\${_AGMSG_FAILFIX_SH:-}" ] && return 0
_AGMSG_FAILFIX_SH=1
agmsg_doctor_extra_collect() { return $1; }
agmsg_doctor_extra_global_collect() { return $2; }
EOF
}

@test "doctor --json: failing per-pair collector is plug_collector_failed with rc 1 JSON" {
  install_failing_plug 1 0
  configured_off "$PROJ"

  run_json --project "$PROJ" --type claude-code
  if [ "$JSON_STATUS" -ne 1 ]; then
    fail_assert "expected rc 1 for failing collector, got $JSON_STATUS"
  fi
  if [ ! -s "$JSON_OUT" ]; then
    fail_assert "rc 1 with empty stdout (JSON missing)"
  fi
  assert_valid_json
  assert_json_eq '["scopes"][0]["diagnosable"]' "False"
  assert_json_eq '["diagnosable"]' "False"
  assert_json_eq '["scopes"][0]["findings"][0]["code"]' "plug_collector_failed"
  assert_json_eq '["scopes"][0]["findings"][0]["kind"]' "diagnostic_failure"
  # Machine judgment needs no evidence parsing, but the rc is kept as context.
  assert_json_python '"1" in d["scopes"][0]["findings"][0]["evidence"]' 'collector rc missing from evidence'

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code
  if [ "$status" -ne 1 ]; then
    fail_assert "human mode should also warn (rc 1), got $status"
  fi
  if ! printf '%s\n' "$output" | grep -q "plug collector"; then
    fail_assert "human mode missing collector failure warning"
  fi
}

@test "doctor --json: failing global collector fails only the global diagnosis" {
  install_failing_plug 0 1
  configured_off "$PROJ"

  run_json --type claude-code
  if [ "$JSON_STATUS" -ne 1 ]; then
    fail_assert "expected rc 1 for failing global collector, got $JSON_STATUS"
  fi
  if [ ! -s "$JSON_OUT" ]; then
    fail_assert "rc 1 with empty stdout (JSON missing)"
  fi
  assert_valid_json
  assert_json_eq '["scopes"][0]["diagnosable"]' "True"
  assert_json_eq '["diagnosable"]' "False"
  assert_json_python 'any(f["code"]=="plug_collector_failed" and f["kind"]=="diagnostic_failure" and f["scope"]=={"project": None, "type": "claude-code"} for f in d["global_findings"])' 'missing global plug_collector_failed finding'
}

# --- serializer failure: always rc 2 ----------------------------------------

@test "doctor --json serializer: invalid store bytes are rc 2 with empty stdout" {
  local store="$TEST_SKILL_DIR/badstore"
  mkdir -p "$store"
  : > "$store/regs.tsv"; : > "$store/comps.tsv"; : > "$store/findings.tsv"
  printf 'x\037codex\037mode\037ok\xff\xfe\n' > "$store/scopes.tsv"
  local rc=0
  python3 "$SCRIPTS/internal/doctor-json.py" \
    --scopes "$store/scopes.tsv" \
    --registrations "$store/regs.tsv" \
    --components "$store/comps.tsv" \
    --findings "$store/findings.tsv" \
    --teams 0 >"$store/out.json" 2>"$store/err.txt" || rc=$?
  if [ "$rc" -ne 2 ]; then
    fail_assert "expected rc 2 for serializer failure, got $rc"
  fi
  if [ -s "$store/out.json" ]; then
    fail_assert "rc 2 must leave stdout empty"
  fi
  if [ ! -s "$store/err.txt" ]; then
    fail_assert "rc 2 must explain on stderr"
  fi
  if grep -q "Traceback" "$store/err.txt"; then
    fail_assert "stderr must stay concise (no traceback)"
  fi
}

@test "doctor --json serializer: malformed scopes record with empty project is rc 2, never skipped" {
  # scopes.tsv rows must always carry a project. An empty-project row is an
  # internal inconsistency: it must fail closed (rc 2) instead of being
  # skipped into a false-healthy rc 0 / diagnosable:true payload.
  local store="$TEST_SKILL_DIR/badscope"
  mkdir -p "$store"
  : > "$store/regs.tsv"; : > "$store/comps.tsv"; : > "$store/findings.tsv"
  printf '\037codex\037turn\037ok\n' > "$store/scopes.tsv"
  local rc=0
  python3 "$SCRIPTS/internal/doctor-json.py" \
    --scopes "$store/scopes.tsv" \
    --registrations "$store/regs.tsv" \
    --components "$store/comps.tsv" \
    --findings "$store/findings.tsv" \
    --teams 0 >"$store/out.json" 2>"$store/err.txt" || rc=$?
  if [ "$rc" -ne 2 ]; then
    fail_assert "expected rc 2 for malformed scopes record, got $rc"
  fi
  if [ -s "$store/out.json" ]; then
    fail_assert "rc 2 must leave stdout empty"
  fi
  if [ ! -s "$store/err.txt" ]; then
    fail_assert "rc 2 must explain on stderr"
  fi
  if grep -q "Traceback" "$store/err.txt"; then
    fail_assert "stderr must stay concise (no traceback)"
  fi
  if ! grep -q "scoped record has no project" "$store/err.txt"; then
    fail_assert "stderr must name the scoped-record inconsistency"
  fi
}

@test "doctor --json serializer: malformed registration record with empty project is rc 2, never skipped" {
  # registrations.tsv rows must always carry a project; empty-project rows
  # fail closed the same way as scopes.tsv rows.
  local store="$TEST_SKILL_DIR/badreg"
  mkdir -p "$store"
  : > "$store/scopes.tsv"; : > "$store/comps.tsv"; : > "$store/findings.tsv"
  printf '\037codex\037team\037alice\037alive\037none\n' > "$store/regs.tsv"
  local rc=0
  python3 "$SCRIPTS/internal/doctor-json.py" \
    --scopes "$store/scopes.tsv" \
    --registrations "$store/regs.tsv" \
    --components "$store/comps.tsv" \
    --findings "$store/findings.tsv" \
    --teams 0 >"$store/out.json" 2>"$store/err.txt" || rc=$?
  if [ "$rc" -ne 2 ]; then
    fail_assert "expected rc 2 for malformed registration record, got $rc"
  fi
  if [ -s "$store/out.json" ]; then
    fail_assert "rc 2 must leave stdout empty"
  fi
  if [ ! -s "$store/err.txt" ]; then
    fail_assert "rc 2 must explain on stderr"
  fi
  if grep -q "Traceback" "$store/err.txt"; then
    fail_assert "stderr must stay concise (no traceback)"
  fi
  if ! grep -q "scoped record has no project" "$store/err.txt"; then
    fail_assert "stderr must name the scoped-record inconsistency"
  fi
}

# --- P1-3: strict store validation (fail-closed) ------------------------------

run_serializer() {
  # $1: store dir. Sets SER_RC, leaves stdout in $store/out.json.
  local store="$1" rc=0
  python3 "$SCRIPTS/internal/doctor-json.py" \
    --scopes "$store/scopes.tsv" \
    --registrations "$store/regs.tsv" \
    --components "$store/comps.tsv" \
    --findings "$store/findings.tsv" \
    --teams 0 >"$store/out.json" 2>"$store/err.txt" || rc=$?
  SER_RC="$rc"
}

assert_serializer_rc2() {
  # $1: store dir, $2: label. rc2, stdout empty, stderr concise.
  local store="$1" label="$2"
  if [ "$SER_RC" -ne 2 ]; then
    fail_assert "expected rc 2 for $label, got $SER_RC"
  fi
  if [ -s "$store/out.json" ]; then
    fail_assert "rc 2 must leave stdout empty ($label)"
  fi
  if [ ! -s "$store/err.txt" ]; then
    fail_assert "rc 2 must explain on stderr ($label)"
  fi
  if grep -q "Traceback" "$store/err.txt"; then
    fail_assert "stderr must stay concise, no traceback ($label)"
  fi
}

@test "doctor --json serializer: short scope row is rc 2, never padded" {
  local store="$TEST_SKILL_DIR/shortrow"
  mkdir -p "$store"
  : > "$store/regs.tsv"; : > "$store/comps.tsv"; : > "$store/findings.tsv"
  printf 'proj\037codex\037turn\n' > "$store/scopes.tsv"
  run_serializer "$store"
  assert_serializer_rc2 "$store" "short scope row"
}

@test "doctor --json serializer: long scope row is rc 2, never truncated" {
  local store="$TEST_SKILL_DIR/longrow"
  mkdir -p "$store"
  : > "$store/regs.tsv"; : > "$store/comps.tsv"; : > "$store/findings.tsv"
  printf 'proj\037codex\037turn\037ok\037extra\n' > "$store/scopes.tsv"
  run_serializer "$store"
  assert_serializer_rc2 "$store" "long scope row"
}

@test "doctor --json serializer: registration without scope is rc 2" {
  local store="$TEST_SKILL_DIR/orphanreg"
  mkdir -p "$store"
  printf 'proj\037codex\037turn\037ok\n' > "$store/scopes.tsv"
  printf 'elsewhere\037codex\037team\037alice\037alive\037none\n' > "$store/regs.tsv"
  : > "$store/comps.tsv"; : > "$store/findings.tsv"
  run_serializer "$store"
  assert_serializer_rc2 "$store" "registration without scope"
  if ! grep -q "without scope" "$store/err.txt"; then
    fail_assert "stderr must name orphan child"
  fi
}

@test "doctor --json serializer: component without scope is rc 2" {
  local store="$TEST_SKILL_DIR/orphancomp"
  mkdir -p "$store"
  printf 'proj\037codex\037turn\037ok\n' > "$store/scopes.tsv"
  : > "$store/regs.tsv"; : > "$store/findings.tsv"
  printf 'elsewhere\037codex\037codex_app_server\037\037\037process\037dead\037\n' > "$store/comps.tsv"
  run_serializer "$store"
  assert_serializer_rc2 "$store" "component without scope"
}

@test "doctor --json serializer: finding without scope is rc 2" {
  local store="$TEST_SKILL_DIR/orphanfinding"
  mkdir -p "$store"
  printf 'proj\037codex\037turn\037ok\n' > "$store/scopes.tsv"
  : > "$store/regs.tsv"; : > "$store/comps.tsv"
  printf 'codex_pid_stale\037condition\037runtime\037elsewhere\037codex\037component\037\037\037codex_app_server\037ev\037\n' > "$store/findings.tsv"
  run_serializer "$store"
  assert_serializer_rc2 "$store" "finding without scope"
}

@test "doctor --json serializer: duplicate conflicting scope is rc 2" {
  local store="$TEST_SKILL_DIR/dupscope"
  mkdir -p "$store"
  printf 'proj\037codex\037turn\037ok\nproj\037codex\037monitor\037ok\n' > "$store/scopes.tsv"
  : > "$store/regs.tsv"; : > "$store/comps.tsv"; : > "$store/findings.tsv"
  run_serializer "$store"
  assert_serializer_rc2 "$store" "duplicate scope"
  if ! grep -q "duplicate scope" "$store/err.txt"; then
    fail_assert "stderr must name duplicate scope"
  fi
}

# --- P1-1: global delivery failure is fail-closed, never false healthy ------

@test "doctor --json: global delivery failure is rc 1 with global diagnostic_failure" {
  # Global `delivery.sh status` (no args) exits 7, scoped calls succeed.
  # rc must be 1 with parseable JSON, top-level diagnosable:false, and a
  # global delivery_status_failed -- never rc 0 false healthy.
  configured_off "$PROJ"
  mv "$SCRIPTS/delivery.sh" "$SCRIPTS/delivery.sh.real"
  cat > "$SCRIPTS/delivery.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "status" ] && [ "$#" -eq 1 ]; then
  echo "mock global delivery failure" >&2
  exit 7
fi
exec bash "$(dirname "$0")/delivery.sh.real" "$@"
EOF
  chmod +x "$SCRIPTS/delivery.sh"
  run_json --project "$PROJ" --type claude-code
  local rc="$JSON_STATUS"
  mv "$SCRIPTS/delivery.sh.real" "$SCRIPTS/delivery.sh"
  if [ "$rc" -ne 1 ]; then
    fail_assert "expected rc 1 for global delivery failure, got $rc"
  fi
  assert_valid_json
  assert_json_eq '["diagnosable"]' "False"
  assert_json_python 'any(f["code"]=="delivery_status_failed" and f["kind"]=="diagnostic_failure" and f["scope"]=={"project": None, "type": None} for f in d["global_findings"])' 'missing global delivery_status_failed'
  if [ "$(json_get '["global_findings"]')" = "[]" ]; then
    fail_assert "global findings must not be empty on global delivery failure"
  fi
}

# --- P1-6: global components carry distinct opaque instances ------------------

write_two_orphan_appservers() {
  # Two orphan triples with distinct hashes.
  local h1="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" h2="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" dead
  dead="$(dead_pid)"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$dead" > "$TEST_SKILL_DIR/run/codex-app-server.$h1.pid"
  printf '%s\n' "64341" > "$TEST_SKILL_DIR/run/codex-app-server.$h1.port"
  printf '%s\n' "codex-cli 9.9.9-test" > "$TEST_SKILL_DIR/run/codex-app-server.$h1.version"
  printf '%s\n' "$dead" > "$TEST_SKILL_DIR/run/codex-app-server.$h2.pid"
  printf '%s\n' "64342" > "$TEST_SKILL_DIR/run/codex-app-server.$h2.port"
  printf '%s\n' "codex-cli 9.9.9-test" > "$TEST_SKILL_DIR/run/codex-app-server.$h2.version"
}

@test "doctor --json: two orphan app-servers are two global components with distinct opaque instances" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  configured_off "$PROJ"
  write_two_orphan_appservers

  run_json --type codex
  if [ "$JSON_STATUS" -ne 1 ]; then
    fail_assert "expected rc 1 for two orphans, got $JSON_STATUS"
  fi
  assert_valid_json
  assert_json_python 'len([c for c in d["global_components"] if c["id"]=="codex_app_server"]) == 2' 'expected 2 global codex_app_server components'
  assert_json_python 'len({c["instance"]["id"] for c in d["global_components"] if c["id"]=="codex_app_server"}) == 2' 'opaque instance IDs must be distinct'
  assert_json_python 'all(c["instance"] is not None and c["instance"].get("kind")=="opaque" for c in d["global_components"] if c["id"]=="codex_app_server")' 'global components must carry opaque instances'
  # Each finding target references its own instance; no evidence parsing needed.
  assert_json_python 'all(f["target"] is not None and f["target"].get("instance") is not None and f["target"]["instance"].get("kind")=="opaque" for f in d["global_findings"] if f["target"] is not None and f["target"].get("component_id")=="codex_app_server")' 'finding targets must reference opaque instances'
  # Raw hashes never appear as structured data.
  if grep -q "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$JSON_OUT"; then
    fail_assert "raw orphan hash leaked into payload"
  fi
  if grep -q "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$JSON_OUT"; then
    fail_assert "raw orphan hash leaked into payload"
  fi
}

@test "doctor --json: two unattributed bridges are two global components with distinct opaque instances" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  local dead
  dead="$(dead_pid)"
  mkdir -p "$TEST_SKILL_DIR/run"
  for k in "ghost.one" "ghost.two"; do
    printf '%s\n' "$dead" > "$TEST_SKILL_DIR/run/codex-bridge.$k.pid"
    printf '%s' "ws://127.0.0.1:1" > "$TEST_SKILL_DIR/run/codex-bridge.$k.appserver"
    printf '%s' "thread-$k" > "$TEST_SKILL_DIR/run/codex-bridge.$k.thread"
  done

  run_json --type codex
  if [ "$JSON_STATUS" -ne 1 ]; then
    fail_assert "expected rc 1 for two bridges, got $JSON_STATUS"
  fi
  assert_valid_json
  assert_json_python 'len([c for c in d["global_components"] if c["id"]=="codex_bridge"]) == 2' 'expected 2 global codex_bridge components'
  assert_json_python 'len({c["instance"]["id"] for c in d["global_components"] if c["id"]=="codex_bridge"}) == 2' 'bridge opaque instances must be distinct'
  if grep -qF "ghost.one" "$JSON_OUT"; then
    fail_assert "raw bridge key ghost.one leaked"
  fi
  if grep -qF "ghost.two" "$JSON_OUT"; then
    fail_assert "raw bridge key ghost.two leaked"
  fi
}

# --- P1-5: global redaction never leaks raw orphan keys -----------------------

@test "doctor --json --redacted: raw orphan key, deleted team/agent, thread never leak" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  local dead rawkey rawthread
  dead="$(dead_pid)"
  rawkey="ghostteam.ghostagent"
  rawthread="thread-secret-9f8e7d6c-1234"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$dead" > "$TEST_SKILL_DIR/run/codex-bridge.$rawkey.pid"
  printf '%s' "ws://127.0.0.1:1" > "$TEST_SKILL_DIR/run/codex-bridge.$rawkey.appserver"
  printf '%s' "$rawthread" > "$TEST_SKILL_DIR/run/codex-bridge.$rawkey.thread"

  run_json --type codex --redacted
  if [ "$JSON_STATUS" -ne 1 ]; then
    fail_assert "expected rc 1 for orphan bridge, got $JSON_STATUS"
  fi
  assert_valid_json
  assert_absent "$rawkey" "raw orphan key"
  assert_absent "ghostteam" "raw deleted team"
  assert_absent "ghostagent" "raw deleted agent"
  assert_absent "$rawthread" "raw thread"
  # Opaque pseudonym is present and shared with human redacted output.
  assert_json_python 'any(c["instance"] is not None and c["instance"].get("kind")=="opaque" for c in d["global_components"])' 'opaque instance missing'
  run bash "$SCRIPTS/doctor.sh" --type codex --redacted
  if printf '%s\n' "$output" | grep -qF "$rawkey"; then
    fail_assert "human redacted output leaked raw orphan key"
  fi
  if printf '%s\n' "$output" | grep -qF "$rawthread"; then
    fail_assert "human redacted output leaked raw thread"
  fi
}

# --- P1-2: fatal-error boundary and stdout purity ------------------------------

@test "doctor --json: mktemp failure is rc 2 with empty stdout" {
  configured_off "$PROJ"
  local fakebin="$TEST_SKILL_DIR/fakebin-mktemp"
  mkdir -p "$fakebin"
  cat > "$fakebin/mktemp" <<'EOF'
#!/usr/bin/env bash
echo "mock mktemp failure" >&2
exit 1
EOF
  chmod +x "$fakebin/mktemp"
  local rc=0
  PATH="$fakebin:$PATH" bash "$SCRIPTS/doctor.sh" --json --project "$PROJ" --type claude-code >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  if [ "$rc" -ne 2 ]; then
    fail_assert "expected rc 2 for mktemp failure, got $rc"
  fi
  if [ -s "$TEST_SKILL_DIR/out.txt" ]; then
    fail_assert "rc 2 must leave stdout empty (mktemp failure)"
  fi
  if [ ! -s "$TEST_SKILL_DIR/err.txt" ]; then
    fail_assert "rc 2 must explain on stderr"
  fi
}

@test "doctor --json: store write failure is rc 2 with empty stdout" {
  # Fake mktemp succeeds but returns a read-only dir, so `: > file`
  # creation inside the store fails. Same ERR boundary as mktemp failure,
  # but a distinct injection point (create/write vs mktemp itself).
  configured_off "$PROJ"
  local fakebin="$TEST_SKILL_DIR/fakebin-write"
  mkdir -p "$fakebin"
  cat > "$fakebin/mktemp" <<'EOF'
#!/usr/bin/env bash
real="$(command -v -p mktemp 2>/dev/null || printf '/usr/bin/mktemp')"
if [ ! -x "$real" ]; then real="/bin/mktemp"; fi
d="$("$real" -d "${TMPDIR:-/tmp}/agmsg-doctor.XXXXXX")"
chmod 500 "$d"
printf '%s\n' "$d"
EOF
  chmod +x "$fakebin/mktemp"
  local rc=0
  PATH="$fakebin:$PATH" bash "$SCRIPTS/doctor.sh" --json --project "$PROJ" --type claude-code >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  # Cleanup read-only dirs left by the fake mktemp.
  chmod -R u+w "${TMPDIR:-/tmp}"/agmsg-doctor.* 2>/dev/null || true
  if [ "$rc" -ne 2 ]; then
    fail_assert "expected rc 2 for store write failure, got $rc"
  fi
  if [ -s "$TEST_SKILL_DIR/out.txt" ]; then
    fail_assert "rc 2 must leave stdout empty (store write failure)"
  fi
  if [ ! -s "$TEST_SKILL_DIR/err.txt" ]; then
    fail_assert "rc 2 must explain on stderr"
  fi
}

install_noisy_plug() {
  # Structured plug whose *source* prints to stdout. JSON stdout must stay
  # pure (noise goes to stderr, never to the payload).
  cat > "$TYPES/claude-code/_doctor.sh" <<'EOF'
echo "SOURCE_NOISE"
[ -n "${_AGMSG_NOISY_SH:-}" ] && return 0
_AGMSG_NOISY_SH=1
agmsg_doctor_extra_collect() { return 0; }
agmsg_doctor_extra_global_collect() { return 0; }
EOF
}

@test "doctor --json: plug source noise never pollutes stdout" {
  install_noisy_plug
  configured_off "$PROJ"

  local rc=0
  bash "$SCRIPTS/doctor.sh" --json --project "$PROJ" --type claude-code >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail_assert "expected rc 0 for noisy-but-successful plug, got $rc"
  fi
  if grep -q "SOURCE_NOISE" "$TEST_SKILL_DIR/out.txt"; then
    fail_assert "plug source noise polluted JSON stdout"
  fi
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TEST_SKILL_DIR/out.txt"
  if [ "$(wc -l < "$TEST_SKILL_DIR/out.txt" | tr -d ' ')" != "1" ]; then
    fail_assert "JSON stdout must stay a single line"
  fi
}

install_source_failing_plug() {
  # Structured plug file whose source itself exits nonzero. The file still
  # contains the collector entry points (so the pre-source grep marks it as
  # structured), but `return 42` fires before they are defined.
  cat > "$TYPES/claude-code/_doctor.sh" <<'EOF'
[ -n "${_AGMSG_SRCSH:-}" ] && return 0
_AGMSG_SRCSH=1
return 42
agmsg_doctor_extra_collect() { return 0; }
agmsg_doctor_extra_global_collect() { return 0; }
EOF
}

@test "doctor --json: plug source failure is plug_collector_failed with rc 1 JSON" {
  install_source_failing_plug
  configured_off "$PROJ"

  run_json --project "$PROJ" --type claude-code
  if [ "$JSON_STATUS" -ne 1 ]; then
    fail_assert "expected rc 1 for plug source failure, got $JSON_STATUS"
  fi
  if [ ! -s "$JSON_OUT" ]; then
    fail_assert "rc 1 must carry JSON (source failure)"
  fi
  assert_valid_json
  assert_json_eq '["scopes"][0]["diagnosable"]' "False"
  assert_json_eq '["scopes"][0]["findings"][0]["code"]' "plug_collector_failed"
}

@test "doctor --json: identities failure is scan_failed with rc 1 JSON, never empty stdout" {
  # --type (not --project) so SCOPE building via registered_projects succeeds
  # and the per-pair identities lookup fails as partial (scan_failed), not
  # fatal SCOPE resolution (rc 2).
  configured_off "$PROJ"
  mv "$SCRIPTS/identities.sh" "$SCRIPTS/identities.sh.real"
  cat > "$SCRIPTS/identities.sh" <<'EOF'
#!/usr/bin/env bash
echo "mock identities failure" >&2
exit 3
EOF
  chmod +x "$SCRIPTS/identities.sh"
  run_json --type claude-code
  local rc="$JSON_STATUS"
  mv "$SCRIPTS/identities.sh.real" "$SCRIPTS/identities.sh"
  if [ "$rc" -ne 1 ]; then
    # Fatal rc 2 with empty stdout is also contract-compliant, but this
    # path is specified as partial (rc 1 + JSON) so the scope survives.
    fail_assert "expected rc 1 for identities failure, got $rc"
  fi
  if [ ! -s "$JSON_OUT" ]; then
    fail_assert "rc 1 must carry JSON (identities failure)"
  fi
  assert_valid_json
  assert_json_python 'any(f["code"]=="scan_failed" and f["kind"]=="diagnostic_failure" for s in d["scopes"] for f in s["findings"])' 'missing scan_failed diagnostic_failure'
}

# --- P1-4: no human-text parsing; wording change keeps machine JSON ---------

@test "doctor --json: delivery human wording change keeps machine JSON intact" {
  # Change only the human wording of delivery.sh status (mode line stays
  # "mode: ..." for display, but stale phrasing and watch line are altered).
  # Machine fields (delivery.mode, watcher_stale_pidfile) come from the
  # shared evaluator, not from grep/sed of this text, so JSON is unchanged.
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  local dead
  dead="$(dead_pid)"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$dead" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  printf '%s' "ws://127.0.0.1:1" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.appserver"
  printf '%s' "thread-w" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.thread"
  {
    echo "pid=$dead"
    echo "project=$PROJ"
    echo "identities=team/alice"
    echo "type=codex"
  } > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.meta"

  # Baseline JSON with real wording.
  run_json --project "$PROJ" --type codex
  local base_rc="$JSON_STATUS"
  cp "$JSON_OUT" "$TEST_SKILL_DIR/base.json"

  # Wording-only wrapper: same exit codes, same underlying files, but the
  # human phrases doctor used to grep for are gone.
  mv "$SCRIPTS/delivery.sh" "$SCRIPTS/delivery.sh.real"
  cat > "$SCRIPTS/delivery.sh" <<'EOF'
#!/usr/bin/env bash
out="$(bash "$(dirname "$0")/delivery.sh.real" "$@" 2>&1)"
rc=$?
printf '%s\n' "$out" | sed -e 's/stale pidfile (/STALE-RENAMED (/' -e 's/^watch processes: /watch PROCS: /'
exit "$rc"
EOF
  chmod +x "$SCRIPTS/delivery.sh"
  run_json --project "$PROJ" --type codex
  local rc2="$JSON_STATUS"
  cp "$JSON_OUT" "$TEST_SKILL_DIR/wording.json"
  mv "$SCRIPTS/delivery.sh.real" "$SCRIPTS/delivery.sh"

  if [ "$base_rc" -ne "$rc2" ]; then
    fail_assert "wording change altered rc ($base_rc vs $rc2)"
  fi
  # Machine codes/scopes/targets identical; only human evidence wording may
  # differ (it quotes the human block). Compare the machine subset.
  if ! python3 - "$TEST_SKILL_DIR/base.json" "$TEST_SKILL_DIR/wording.json" <<'EOF'; then
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
def machine(d):
    return (d["diagnosable"],
            [(s["project"],s["type"],s["diagnosable"],s["delivery"],
              [(f["code"],f["kind"],f["category"],f["scope"],f["target"]) for f in s["findings"]],
              [(c["id"],c["instance"],c["signals"]) for c in s["components"]]) for s in d["scopes"]],
            [(f["code"],f["kind"],f["category"],f["scope"],f["target"]) for f in d["global_findings"]])
assert machine(a)==machine(b), "machine JSON changed on wording-only edit"
EOF
    fail_assert "machine JSON changed on wording-only edit"
  fi
}

@test "doctor --json: shared delivery evaluator agrees with human first line" {
  # Fixture/helper boundary directly: evaluator mode equals the human
  # "mode: ..." first line for a configured project, without parsing.
  configured_off "$PROJ"
  local human_first mode_eval
  human_first="$(bash "$SCRIPTS/delivery.sh" status claude-code "$PROJ" 2>/dev/null | head -1)"
  mode_eval="$(bash -c '. "$1/lib/delivery-eval.sh"; agmsg_delivery_eval_mode claude-code "$2" && printf "%s" "$AGMSG_DELIVERY_EVAL_MODE"' bash "$SCRIPTS" "$PROJ")"
  if [ "mode: $mode_eval" != "$human_first" ]; then
    fail_assert "evaluator mode [$mode_eval] disagrees with human [$human_first]"
  fi
}

# --- P2: control characters are rejected, never lossily flattened ------------

@test "doctor --json: project with TAB is rc 2 fail-closed" {
  local tabproj="$TEST_SKILL_DIR/$(printf 'tab\tproj')"
  mkdir -p "$tabproj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$tabproj" >/dev/null
  local rc=0
  bash "$SCRIPTS/doctor.sh" --json --project "$tabproj" --type claude-code >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  if [ "$rc" -ne 2 ]; then
    fail_assert "expected rc 2 for TAB project, got $rc"
  fi
  if [ -s "$TEST_SKILL_DIR/out.txt" ]; then
    fail_assert "rc 2 must leave stdout empty (TAB project)"
  fi
}

@test "doctor --json: project with newline is rc 2 fail-closed" {
  local nlproj="$TEST_SKILL_DIR/$(printf 'nl\nproj')"
  mkdir -p "$nlproj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$nlproj" >/dev/null
  local rc=0
  bash "$SCRIPTS/doctor.sh" --json --project "$nlproj" --type claude-code >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  if [ "$rc" -ne 2 ]; then
    fail_assert "expected rc 2 for newline project, got $rc"
  fi
  if [ -s "$TEST_SKILL_DIR/out.txt" ]; then
    fail_assert "rc 2 must leave stdout empty (newline project)"
  fi
}

install_newline_evidence_plug() {
  cat > "$TYPES/claude-code/_doctor.sh" <<'EOF'
[ -n "${_AGMSG_NLEVID_SH:-}" ] && return 0
_AGMSG_NLEVID_SH=1
agmsg_doctor_extra_collect() {
  agmsg_doctor_finding_add ev_nl condition runtime "" "claude-code" "" "" "" "" "$(printf 'line1\nline2')" ""
  return 0
}
agmsg_doctor_extra_global_collect() { return 0; }
EOF
}

@test "doctor --json: evidence newline is rc 2, never flattened" {
  install_newline_evidence_plug
  configured_off "$PROJ"
  local rc=0
  bash "$SCRIPTS/doctor.sh" --json --project "$PROJ" --type claude-code >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  if [ "$rc" -ne 2 ]; then
    fail_assert "expected rc 2 for newline evidence, got $rc"
  fi
  if [ -s "$TEST_SKILL_DIR/out.txt" ]; then
    fail_assert "rc 2 must leave stdout empty (newline evidence)"
  fi
}

install_us_evidence_plug() {
  cat > "$TYPES/claude-code/_doctor.sh" <<'EOF'
[ -n "${_AGMSG_USEVID_SH:-}" ] && return 0
_AGMSG_USEVID_SH=1
agmsg_doctor_extra_collect() {
  agmsg_doctor_finding_add ev_us condition runtime "" "claude-code" "" "" "" "" "$(printf 'a\037b')" ""
  return 0
}
agmsg_doctor_extra_global_collect() { return 0; }
EOF
}

@test "doctor --json: evidence unit separator is rc 2, never flattened" {
  install_us_evidence_plug
  configured_off "$PROJ"
  local rc=0
  bash "$SCRIPTS/doctor.sh" --json --project "$PROJ" --type claude-code >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  if [ "$rc" -ne 2 ]; then
    fail_assert "expected rc 2 for unit-separator evidence, got $rc"
  fi
  if [ -s "$TEST_SKILL_DIR/out.txt" ]; then
    fail_assert "rc 2 must leave stdout empty (unit separator)"
  fi
}

# --- Astra P1: serializer publish boundary + evaluator stdout isolation -----

@test "doctor --json: serializer startup failure is rc 2 with empty stdout" {
  # Broken stdio codec breaks the serializer process itself (rc 1, empty
  # stdout from Python). The publish boundary must normalize this to rc 2,
  # never pass through rc 1 with an empty stdout.
  configured_off "$PROJ"
  local rc=0
  PYTHONIOENCODING=review_nonexistent_codec bash "$SCRIPTS/doctor.sh" --json --project "$PROJ" --type claude-code >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  if [ "$rc" -ne 2 ]; then
    fail_assert "expected rc 2 for serializer startup failure, got $rc"
  fi
  if [ -s "$TEST_SKILL_DIR/out.txt" ]; then
    fail_assert "rc 2 must leave stdout empty (serializer startup failure)"
  fi
  if [ ! -s "$TEST_SKILL_DIR/err.txt" ]; then
    fail_assert "rc 2 must explain on stderr"
  fi
}

@test "doctor --json: evaluator stdout noise never pollutes stdout" {
  # Machine evaluators must not contract stdout: stray prints stay on
  # stderr while the JSON payload stays a single pure line.
  configured_off "$PROJ"
  cp "$SCRIPTS/lib/delivery-eval.sh" "$TEST_SKILL_DIR/delivery-eval.sh.real"
  python3 - "$SCRIPTS/lib/delivery-eval.sh" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "agmsg_delivery_eval_watchers() {\n  AGMSG_DELIVERY_EVAL_WATCH_ALIVE=0"
new = "agmsg_delivery_eval_watchers() {\n  echo EVALUATOR_NOISE\n  AGMSG_DELIVERY_EVAL_WATCH_ALIVE=0"
assert s.count(old) == 1, "evaluator injection point not found"
open(p, "w").write(s.replace(old, new))
EOF
  local rc=0
  bash "$SCRIPTS/doctor.sh" --json --project "$PROJ" --type claude-code >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  cp "$TEST_SKILL_DIR/delivery-eval.sh.real" "$SCRIPTS/lib/delivery-eval.sh"
  if [ "$rc" -ne 0 ]; then
    fail_assert "expected rc 0 with noisy evaluator, got $rc"
  fi
  if grep -q "EVALUATOR_NOISE" "$TEST_SKILL_DIR/out.txt"; then
    fail_assert "evaluator noise polluted JSON stdout"
  fi
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TEST_SKILL_DIR/out.txt"
  if [ "$(wc -l < "$TEST_SKILL_DIR/out.txt" | tr -d ' ')" != "1" ]; then
    fail_assert "JSON stdout must stay a single line"
  fi
}

# --- Astra P1: store append failures are fatal, never false healthy ----------

install_chmod_plug() {
  # $1: comps|findings — chmod 400 that store, then write to it. The write
  # must fatalize (rc 2) instead of degrading to a healthy-looking report
  # with the record missing.
  local which="$1"
  cat > "$TYPES/claude-code/_doctor.sh" <<EOF
[ -n "\${_AGMSG_CHMOD_SH:-}" ] && return 0
_AGMSG_CHMOD_SH=1
agmsg_doctor_extra_collect() {
  if [ "$which" = "comps" ]; then
    chmod 400 "\$_DOCTOR_COMPS_FILE"
    agmsg_doctor_component_signal "\$2" "\$1" fixture "" "" process running
  else
    chmod 400 "\$_DOCTOR_FINDINGS_FILE"
    agmsg_doctor_finding_add fixture_fail condition runtime "\$2" "\$1" "" "" "" "" "fixture" ""
  fi
  return 0
}
agmsg_doctor_extra_global_collect() { return 0; }
EOF
}

@test "doctor --json: components store append failure is rc 2 with empty stdout" {
  install_chmod_plug comps
  configured_off "$PROJ"
  local rc=0
  bash "$SCRIPTS/doctor.sh" --json --project "$PROJ" --type claude-code >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  if [ "$rc" -ne 2 ]; then
    fail_assert "expected rc 2 for components append failure, got $rc"
  fi
  if [ -s "$TEST_SKILL_DIR/out.txt" ]; then
    fail_assert "rc 2 must leave stdout empty (components append failure)"
  fi
}

@test "doctor --json: findings store append failure is rc 2 with empty stdout" {
  install_chmod_plug findings
  configured_off "$PROJ"
  local rc=0
  bash "$SCRIPTS/doctor.sh" --json --project "$PROJ" --type claude-code >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  if [ "$rc" -ne 2 ]; then
    fail_assert "expected rc 2 for findings append failure, got $rc"
  fi
  if [ -s "$TEST_SKILL_DIR/out.txt" ]; then
    fail_assert "rc 2 must leave stdout empty (findings append failure)"
  fi
}

# --- Astra P2: raw validation happens before conversion -----------------------

install_trailing_nl_plug() {
  # NOTE: the trailing newline is built with $'\n' concatenation, never via
  # $(...) which would strip it before the code under test even runs.
  cat > "$TYPES/claude-code/_doctor.sh" <<'EOF'
[ -n "${_AGMSG_TRAILNL_SH:-}" ] && return 0
_AGMSG_TRAILNL_SH=1
agmsg_doctor_extra_collect() {
  local nl=$'\n'
  agmsg_doctor_finding_add ev_trail condition runtime "" "claude-code" "" "" "" "" "line1$nl" ""
  return 0
}
agmsg_doctor_extra_global_collect() { return 0; }
EOF
}

@test "doctor --json: evidence trailing newline is rc 2, never stripped" {
  install_trailing_nl_plug
  configured_off "$PROJ"
  local rc=0
  bash "$SCRIPTS/doctor.sh" --json --project "$PROJ" --type claude-code >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  if [ "$rc" -ne 2 ]; then
    fail_assert "expected rc 2 for trailing-newline evidence, got $rc"
  fi
  if [ -s "$TEST_SKILL_DIR/out.txt" ]; then
    fail_assert "rc 2 must leave stdout empty (trailing newline)"
  fi
}

@test "doctor --json --redacted: project with CR is rc 2 fail-closed" {
  local crproj="$TEST_SKILL_DIR/$(printf 'cr\rproj')"
  mkdir -p "$crproj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$crproj" >/dev/null
  local rc=0
  bash "$SCRIPTS/doctor.sh" --json --project "$crproj" --type claude-code --redacted >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  if [ "$rc" -ne 2 ]; then
    fail_assert "expected rc 2 for CR project with --redacted, got $rc"
  fi
  if [ -s "$TEST_SKILL_DIR/out.txt" ]; then
    fail_assert "rc 2 must leave stdout empty (CR project)"
  fi
}

@test "doctor --json --redacted: project with unit separator is rc 2 fail-closed" {
  local usproj="$TEST_SKILL_DIR/$(printf 'us\037proj')"
  mkdir -p "$usproj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$usproj" >/dev/null
  local rc=0
  bash "$SCRIPTS/doctor.sh" --json --project "$usproj" --type claude-code --redacted >"$TEST_SKILL_DIR/out.txt" 2>"$TEST_SKILL_DIR/err.txt" || rc=$?
  if [ "$rc" -ne 2 ]; then
    fail_assert "expected rc 2 for unit-separator project with --redacted, got $rc"
  fi
  if [ -s "$TEST_SKILL_DIR/out.txt" ]; then
    fail_assert "rc 2 must leave stdout empty (unit separator project)"
  fi
}
