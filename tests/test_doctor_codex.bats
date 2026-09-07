#!/usr/bin/env bats

# doctor codex plug (Issue #5 Phase 1, read-only): app-server pid/port/version
# records plus launcher-generation bridge bindings.
#
# Every fixture lives in the isolated TEST_SKILL_DIR (setup_test_env) with a
# sandboxed HOME, so no test touches the developer's real run/ directory or a
# real Codex process. "Live" servers are a python loopback listener plus a
# sleep whose argv names a Codex app-server; "dead" pids use the spawn+wait
# idiom (never a hardcoded number, #595). Destructive contact with real OS
# processes is never needed — the plug under test only reads record files,
# asks ps, and opens loopback TCP connections.

load test_helper

setup() {
  setup_test_env
  . "$SCRIPTS/lib/hash.sh"
  export PROJ="$(mktemp -d)"
  export PROJ2=""
  : > "$TEST_SKILL_DIR/fixpids"
  export FAKE_CODEX="$TEST_SKILL_DIR/fake-codex"
  printf '#!/usr/bin/env bash\necho "codex-cli 9.9.9-test"\n' > "$FAKE_CODEX"
  chmod +x "$FAKE_CODEX"
  export AGMSG_REAL_CODEX="$FAKE_CODEX"
  # Keep delivery.sh's loaded-threads probe (only reached for seatless roles
  # when a port file exists) far below its 1500ms default.
  export AGMSG_CODEX_STATUS_PROBE_TIMEOUT_MS=50
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
}

teardown() {
  # Fixture pids are recorded to a file, not a variable: the helpers run
  # inside command substitutions, where an assignment would die with the
  # subshell (the same trap role-session.sh documents for its memo).
  if [ -f "$TEST_SKILL_DIR/fixpids" ]; then
    while IFS= read -r _p; do
      [ -n "$_p" ] || continue
      kill "$_p" 2>/dev/null || true
    done < "$TEST_SKILL_DIR/fixpids"
  fi
  wait 2>/dev/null || true
  teardown_test_env
  rm -rf "$PROJ" "$PROJ2"
}

track_pid() { printf '%s\n' "$1" >> "$TEST_SKILL_DIR/fixpids"; }

# A pid that is provably dead by construction (spawn, wait, reuse the freed
# pid) rather than a hardcoded guess a CI runner might actually have live.
dead_pid() {
  ( exit 0 ) & local _p=$!
  wait "$_p" 2>/dev/null || true
  printf '%s' "$_p"
}

# A live process whose cmdline cannot be a Codex app-server. Detached from
# the harness fds (the repo's close-fds idiom): a fixture that outlives `run`
# must not hold the capture pipe open, or the test hangs until it exits.
foreign_pid() {
  sleep 60 >/dev/null 2>&1 3>&- 4>&- &
  local _p=$!
  track_pid "$_p"
  printf '%s' "$_p"
}

# A live process whose cmdline IS "*codex*app-server*" (what the monitor's
# reuse check matches on), without running any real Codex binary.
confirmed_pid() {
  bash -c 'exec -a "fakecodex app-server --listen ws://127.0.0.1:0" sleep 60' >/dev/null 2>&1 3>&- 4>&- &
  local _p=$!
  track_pid "$_p"
  printf '%s' "$_p"
}

# A real loopback listener; prints its port. Plain TCP is enough — the plug
# probes "something accepts", never the WebSocket layer.
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

proj_hash() { printf '%s' "$1" | agmsg_sha1; }

write_appserver() { # $1=project $2=pid $3=port $4=version
  local _h
  _h="$(proj_hash "$1")"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$2" > "$TEST_SKILL_DIR/run/codex-app-server.$_h.pid"
  printf '%s\n' "$3" > "$TEST_SKILL_DIR/run/codex-app-server.$_h.port"
  printf '%s\n' "$4" > "$TEST_SKILL_DIR/run/codex-app-server.$_h.version"
}

# What codex-bridge.js writeMeta() records on startup (pid/project/type must
# agree with the pidfile, or delivery.sh's own metadata check warns first).
write_bridge_meta() { # $1=key $2=pid $3=project
  {
    echo "pid=$2"
    echo "project=$3"
    echo "identities=team/alice"
    echo "type=codex"
  } > "$TEST_SKILL_DIR/run/codex-bridge.$1.meta"
}

@test "doctor codex: healthy app-server (live pid, answering port, matching version) is quiet" {
  local _port
  _port="$(start_listener "$TEST_SKILL_DIR/port.txt")"
  local _pid
  _pid="$(confirmed_pid)"
  write_appserver "$PROJ" "$_pid" "$_port" "codex-cli 9.9.9-test"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex app-server: healthy (pid $_pid, ws://127.0.0.1:$_port"* ]]
  [[ "$output" != *"stale app-server"* ]]
  [[ "$output" != *"version drift"* ]]
  [[ "$output" == *"no warnings."* ]]
}

@test "doctor codex: dead pid plus silent port warns independently, and never suggests killing" {
  local _dead
  _dead="$(dead_pid)"
  write_appserver "$PROJ" "$_dead" "64321" "codex-cli 9.9.9-test"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale app-server pidfile (pid $_dead not running)"* ]]
  [[ "$output" == *"app-server endpoint is unresponsive (ws://127.0.0.1:64321)"* ]]
  # Each signal stands on its own: two independent warnings, no kill language.
  [[ "$output" != *"kill"* ]]
  # Read-only proof: the records are still there, byte for byte.
  [ "$(cat "$TEST_SKILL_DIR/run/codex-app-server.$(proj_hash "$PROJ").pid")" = "$_dead" ]
  [ -f "$TEST_SKILL_DIR/run/codex-app-server.$(proj_hash "$PROJ").port" ]
  [ -f "$TEST_SKILL_DIR/run/codex-app-server.$(proj_hash "$PROJ").version" ]
}

@test "doctor codex: live pid with a foreign cmdline is pid-reuse evidence, not a kill target" {
  local _foreign
  _foreign="$(foreign_pid)"
  write_appserver "$PROJ" "$_foreign" "64322" "codex-cli 9.9.9-test"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 1 ]
  [[ "$output" == *"pid $_foreign alive but is not a Codex app-server (possible pid reuse)"* ]]
  [[ "$output" != *"kill"* ]]
  # The foreign process survived the diagnosis.
  kill -0 "$_foreign"
}

@test "doctor codex: invalid pid and invalid port records each warn on their own" {
  write_appserver "$PROJ" "not-a-pid" "99999" "codex-cli 9.9.9-test"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale app-server pid record (invalid pid 'not-a-pid')"* ]]
  [[ "$output" == *"stale app-server endpoint record (invalid port '99999')"* ]]
}

@test "doctor codex: version drift warns with relaunch advice, never a stale/kill verdict" {
  local _port
  _port="$(start_listener "$TEST_SKILL_DIR/port.txt")"
  local _pid
  _pid="$(confirmed_pid)"
  write_appserver "$PROJ" "$_pid" "$_port" "codex-cli 0.145.0"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 1 ]
  [[ "$output" == *"app-server version drift (recorded 'codex-cli 0.145.0', current 'codex-cli 9.9.9-test')"* ]]
  [[ "$output" == *"relaunch Codex through the monitor"* ]]
  [[ "$output" != *"stale app-server pidfile"* ]]
  [[ "$output" != *"kill"* ]]
  # The drifted server itself is untouched.
  kill -0 "$_pid"
}

@test "doctor codex: answering port with a dead pid names a possible foreign listener" {
  local _port
  _port="$(start_listener "$TEST_SKILL_DIR/port.txt")"
  local _dead
  _dead="$(dead_pid)"
  write_appserver "$PROJ" "$_dead" "$_port" "codex-cli 9.9.9-test"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 1 ]
  [[ "$output" == *"endpoint ws://127.0.0.1:$_port answers but no live recorded server owns it"* ]]
}

@test "doctor codex: two healthy app-servers for different projects are not duplicates" {
  PROJ2="$(mktemp -d)"
  bash "$SCRIPTS/join.sh" other bob codex "$PROJ2" >/dev/null
  local _port1 _port2
  _port1="$(start_listener "$TEST_SKILL_DIR/port1.txt")"
  _port2="$(start_listener "$TEST_SKILL_DIR/port2.txt")"
  local _pid1 _pid2
  _pid1="$(confirmed_pid)"
  _pid2="$(confirmed_pid)"
  write_appserver "$PROJ" "$_pid1" "$_port1" "codex-cli 9.9.9-test"
  write_appserver "$PROJ2" "$_pid2" "$_port2" "codex-cli 9.9.9-test"

  run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 0 ]
  [[ "$output" != *"duplicate"* ]]
  [[ "$output" == *"no warnings."* ]]
}

@test "doctor codex: a record matching no registered project is unknown, never attributed" {
  local _dead
  _dead="$(dead_pid)"
  local _uh="abcdef0123456789abcdef0123456789abcdef01"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$_dead" > "$TEST_SKILL_DIR/run/codex-app-server.$_uh.pid"
  printf '%s\n' "64323" > "$TEST_SKILL_DIR/run/codex-app-server.$_uh.port"
  printf '%s\n' "codex-cli 0.145.0" > "$TEST_SKILL_DIR/run/codex-app-server.$_uh.version"

  run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 1 ]
  [[ "$output" == *"matches no registered project (unknown — not attributed)"* ]]
  [[ "$output" == *"stale app-server pidfile (pid $_dead not running)"* ]]
  [[ "$output" == *"owning project unknown"* ]]
  [[ "$output" != *"relaunch Codex through the monitor"* ]]
}

@test "doctor codex: bridge bound to a stale app-server warns with both endpoints" {
  local _port
  _port="$(start_listener "$TEST_SKILL_DIR/port.txt")"
  local _pid
  _pid="$(confirmed_pid)"
  write_appserver "$PROJ" "$_pid" "$_port" "codex-cli 9.9.9-test"
  local _bpid
  _bpid="$(foreign_pid)"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$_bpid" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  write_bridge_meta "team.alice" "$_bpid" "$PROJ"
  printf '%s' "ws://127.0.0.1:1" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.appserver"
  printf '%s' "thread-old" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.thread"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 1 ]
  [[ "$output" == *"bridge team.alice is bound to a stale app-server (bound 'ws://127.0.0.1:1', current 'ws://127.0.0.1:$_port')"* ]]
  kill -0 "$_bpid"
}

@test "doctor codex: bridge matching the current endpoint and seat is quiet" {
  local _port
  _port="$(start_listener "$TEST_SKILL_DIR/port.txt")"
  local _pid
  _pid="$(confirmed_pid)"
  write_appserver "$PROJ" "$_pid" "$_port" "codex-cli 9.9.9-test"
  local _bpid
  _bpid="$(foreign_pid)"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$_bpid" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  write_bridge_meta "team.alice" "$_bpid" "$PROJ"
  printf '%s' "ws://127.0.0.1:$_port" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.appserver"
  printf '%s' "thread-live" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.thread"
  {
    echo "session=thread-live"
    echo "name=team-alice"
    echo "team=team"
    echo "agent=alice"
    echo "type=codex"
    echo "project=$PROJ"
  } > "$TEST_SKILL_DIR/run/role-session.team__alice"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"app-server=match, thread=match"* ]]
  [[ "$output" != *"WARN"* ]]
}

@test "doctor codex: stale launcher-generation bridge pidfile warns once" {
  local _dead
  _dead="$(dead_pid)"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$_dead" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  write_bridge_meta "team.alice" "$_dead" "$PROJ"
  printf '%s' "ws://127.0.0.1:1" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.appserver"
  printf '%s' "thread-old" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.thread"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale bridge pidfile (team.alice, pid '$_dead' not running)"* ]]
  local _count
  _count="$(printf '%s\n' "$output" | grep -c "stale bridge pidfile (team.alice")"
  [ "$_count" -eq 1 ]
}

@test "doctor codex: --redacted masks team, agent, and project in the new lines" {
  local _home_proj="$HOME/redact-codex"
  mkdir -p "$_home_proj"
  bash "$SCRIPTS/join.sh" team alice codex "$_home_proj" >/dev/null
  local _dead
  _dead="$(dead_pid)"
  write_appserver "$_home_proj" "$_dead" "64324" "codex-cli 9.9.9-test"
  printf '%s\n' "$_dead" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"

  run bash "$SCRIPTS/doctor.sh" --project "$_home_proj" --type codex --redacted
  [ "$status" -eq 1 ]
  [[ "$output" == *"team1/agent1"* ]]
  [[ "$output" != *"team/alice"* ]]
  [[ "$output" != *"team.alice"* ]]
  # The home-relative project reads as ~/..., never as the raw $HOME path.
  [[ "$output" != *"$HOME"* ]]
}
