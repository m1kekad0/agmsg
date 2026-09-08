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
  [[ "$output" == *"legacy fixture warning (unstructured)"* ]]
  [[ "$output" == *"Codex legacy line for display"* ]]
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
  [[ "$output" == *"team1/agent1"* ]]
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
  assert_json_eq '["global_findings"][0]["target"]["instance"]' "None"
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
  assert_json_python 'any(c["id"]=="codex_bridge" and c["type"]=="codex" and c["instance"] is None and any(s=={"code": "process", "status": "not-running"} for s in c["signals"]) for c in d["global_components"])' 'missing global codex_bridge component signal'
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
  assert_json_python 'any(c["id"]=="codex_app_server" and c["type"]=="codex" and c["instance"] is None for c in d["global_components"])' 'missing global codex_app_server component'
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
