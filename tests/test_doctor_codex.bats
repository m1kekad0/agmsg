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

# Enforced output assertions. A bare [[ ]] anywhere but a body's last line
# reports `ok` unchecked on macOS bash 3.2 (#670) and the enforced-assertions
# baseline may only shrink, so substring checks go through grep -qF — an
# ordinary pipeline errexit enforces on every bash.
out_has()   { printf '%s\n' "$output" | grep -qF "$1"; }
out_lacks() {
  if printf '%s\n' "$output" | grep -qF "$1"; then
    echo "unexpected output fragment: $1" >&2
    return 1
  fi
}

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
  out_has "Codex app-server: healthy (pid $_pid, ws://127.0.0.1:$_port"
  out_lacks "stale app-server"
  out_lacks "version drift"
  out_has "no warnings."
}

@test "doctor codex: dead pid plus silent port warns independently, and never suggests killing" {
  local _dead
  _dead="$(dead_pid)"
  write_appserver "$PROJ" "$_dead" "64321" "codex-cli 9.9.9-test"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 1 ]
  out_has "stale app-server pidfile (pid $_dead not running)"
  out_has "app-server endpoint is unresponsive (ws://127.0.0.1:64321)"
  # Each signal stands on its own: two independent warnings, no kill language.
  out_lacks "kill"
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
  out_has "pid $_foreign alive but is not a Codex app-server (possible pid reuse)"
  out_lacks "kill"
  # The foreign process survived the diagnosis.
  kill -0 "$_foreign"
}

@test "doctor codex: invalid pid and invalid port records each warn on their own" {
  write_appserver "$PROJ" "not-a-pid" "99999" "codex-cli 9.9.9-test"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 1 ]
  out_has "stale app-server pid record (invalid pid 'not-a-pid')"
  out_has "stale app-server endpoint record (invalid port '99999')"
}

@test "doctor codex: version drift warns with relaunch advice, never a stale/kill verdict" {
  local _port
  _port="$(start_listener "$TEST_SKILL_DIR/port.txt")"
  local _pid
  _pid="$(confirmed_pid)"
  write_appserver "$PROJ" "$_pid" "$_port" "codex-cli 0.145.0"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 1 ]
  out_has "app-server version drift (recorded 'codex-cli 0.145.0', current 'codex-cli 9.9.9-test')"
  out_has "relaunch Codex through the monitor"
  out_lacks "stale app-server pidfile"
  out_lacks "kill"
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
  out_has "endpoint ws://127.0.0.1:$_port answers but no live recorded server owns it"
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
  out_lacks "duplicate"
  out_has "no warnings."
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
  out_has "matches no registered project (unknown — not attributed)"
  # The display line keeps the raw pid for the human; the finding line names
  # the opaque instance instead (global evidence carries no raw host pids).
  out_has "Codex app-server: pid $_dead not running"
  out_has "stale app-server pidfile (pid recorded under global_instance"
  out_has "owning project unknown"
  out_lacks "relaunch Codex through the monitor"
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
  out_has "bridge team.alice is bound to a stale app-server (bound 'ws://127.0.0.1:1', current 'ws://127.0.0.1:$_port')"
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
  out_has "app-server=match, thread=match"
  out_lacks "WARN"
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
  out_has "stale bridge pidfile (team.alice, pid '$_dead' not running)"
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
  out_has "team1/agent1"
  out_lacks "team/alice"
  out_lacks "team.alice"
  # The home-relative project reads as ~/..., never as the raw $HOME path.
  out_lacks "$HOME"
}

@test "doctor codex: zero registrations plus leftover records still surface globally when unfiltered" {
  # The orphan case: the registration is gone but the run/ records remain.
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  local _dead
  _dead="$(dead_pid)"
  local _uh="abcdef0123456789abcdef0123456789abcdef01"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$_dead" > "$TEST_SKILL_DIR/run/codex-app-server.$_uh.pid"
  printf '%s\n' "64325" > "$TEST_SKILL_DIR/run/codex-app-server.$_uh.port"
  printf '%s\n' "codex-cli 0.145.0" > "$TEST_SKILL_DIR/run/codex-app-server.$_uh.version"

  run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 1 ]
  out_has "0 team(s), 0 registration(s),"
  out_has "matches no registered project (unknown — not attributed)"
  # Orphan finding: raw pid stays on the display line; the finding names the
  # opaque instance instead (no raw host pids in global evidence).
  out_has "Codex app-server: pid $_dead not running"
  out_has "stale app-server pidfile (pid recorded under global_instance"
  out_has "app-server endpoint is unresponsive (ws://127.0.0.1:64325)"
}

@test "doctor codex: port/version records without a pid are an incomplete state, not invisible" {
  # No pidfile at all — only a crash between writes or a partial manual
  # cleanup leaves this shape, so it warns instead of staying silent.
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  local _uh="9999888877776666555544443333222211110000"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "64326" > "$TEST_SKILL_DIR/run/codex-app-server.$_uh.port"
  printf '%s\n' "codex-cli 9.9.9-test" > "$TEST_SKILL_DIR/run/codex-app-server.$_uh.version"

  run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 1 ]
  out_has "matches no registered project (unknown — not attributed)"
  out_has "app-server endpoint record exists but the pid record is missing (incomplete state)"
  # The leftover files are evidence, not trash for the doctor to take out.
  [ -f "$TEST_SKILL_DIR/run/codex-app-server.$_uh.port" ]
  [ -f "$TEST_SKILL_DIR/run/codex-app-server.$_uh.version" ]
}

@test "doctor codex: --type codex with zero registrations keeps the exit 2 contract" {
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  local _dead
  _dead="$(dead_pid)"
  local _uh="abcdef0123456789abcdef0123456789abcdef01"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$_dead" > "$TEST_SKILL_DIR/run/codex-app-server.$_uh.pid"

  # An explicit type filter that matches nothing is a usage error, even when
  # orphan records exist — the unfiltered whole-install scan above is their
  # surface, not a filter that names something absent.
  run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 2 ]
  out_has "no registrations match this scope"
}

@test "doctor codex: version record alone, without pid and port, is incomplete" {
  # pid and port records are managed as a set with the version record, so a
  # version-only leftover is evidence of an incomplete state — warned about,
  # never silently clean.
  local _h
  _h="$(proj_hash "$PROJ")"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "codex-cli 9.9.9-test" > "$TEST_SKILL_DIR/run/codex-app-server.$_h.version"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 1 ]
  out_has "version record exists but the pid and port records are missing (incomplete state)"
  [ -f "$TEST_SKILL_DIR/run/codex-app-server.$_h.version" ]
}

@test "doctor codex: alive pid without a port record warns only when a version record rules out startup" {
  local _pid
  _pid="$(confirmed_pid)"
  local _h
  _h="$(proj_hash "$PROJ")"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$_pid" > "$TEST_SKILL_DIR/run/codex-app-server.$_h.pid"
  # No port record. A version record already existing refutes "still starting
  # up" (the monitor writes pid, then port, then version), so this warns.
  printf '%s\n' "codex-cli 9.9.9-test" > "$TEST_SKILL_DIR/run/codex-app-server.$_h.version"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 1 ]
  out_has "is alive but the port record is missing while a version record exists (incomplete state"
  kill -0 "$_pid"
}

@test "doctor codex: alive pid with neither port nor version record stays silent (startup race)" {
  local _pid
  _pid="$(confirmed_pid)"
  local _h
  _h="$(proj_hash "$PROJ")"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$_pid" > "$TEST_SKILL_DIR/run/codex-app-server.$_h.pid"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 0 ]
  out_has "no port record"
  out_has "no warnings."
  kill -0 "$_pid"
}

# --- Follow-up coverage: locks, canonical-spelling records, untracked
# --- processes, unattributed bridges, orphan seats, shim -------------------

# Acquire a runtime-lock row in the test store. Runs in a subshell so the
# test shell keeps no storage.sh state; SKILL_DIR points at the isolated
# install. Owner liveness is NOT checked by acquire — a dead owner_pid is
# exactly the stale state under test.
acquire_lock() { # $1=resource $2=owner_pid
  ( export SKILL_DIR="$TEST_SKILL_DIR"
    . "$SCRIPTS/lib/storage.sh"
    agmsg_runtime_lock_acquire "$1" "$2" >/dev/null 2>&1 )
}

# A snapshot entry the process scan will match (args contain codex app-server).
snapshot_codex_process() { # $1=pid
  printf '%s %s\n' "$1" "fakecodex app-server --listen ws://127.0.0.1:0" >> "$AGMSG_DOCTOR_PS_SNAPSHOT"
}

@test "doctor codex: live app-server process no record tracks warns as ambiguous" {
  local _pid
  _pid="$(confirmed_pid)"
  snapshot_codex_process "$_pid"

  run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 1 ]
  out_has "pid $_pid is live but no record tracks it"
  out_has "ambiguous"
  out_lacks "kill"
  # Read-only proof: the untracked process survived the diagnosis.
  kill -0 "$_pid"
}

@test "doctor codex: a tracked app-server process is not flagged as untracked" {
  local _port
  _port="$(start_listener "$TEST_SKILL_DIR/port.txt")"
  local _pid
  _pid="$(confirmed_pid)"
  write_appserver "$PROJ" "$_pid" "$_port" "codex-cli 9.9.9-test"
  snapshot_codex_process "$_pid"

  run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 0 ]
  out_lacks "no record tracks it"
  out_has "no warnings."
}

@test "doctor codex: an unavailable process scan degrades to a note, not a verdict" {
  AGMSG_DOCTOR_PS_SNAPSHOT="$TEST_SKILL_DIR/no-such-snapshot" \
    run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 0 ]
  out_has "process scan unavailable"
  out_has "no warnings."
}

@test "doctor codex: stale dispatcher runtime lock warns; live lock reports held" {
  local _h
  _h="$(proj_hash "$PROJ")"
  local _dead
  _dead="$(dead_pid)"
  acquire_lock "codex-dispatcher:$_h" "$_dead"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 1 ]
  out_has "Codex dispatcher lock: held by dead pid $_dead"
  out_has "stale dispatcher lock (owner pid $_dead not running)"
  out_has "reclaimed automatically"
}

@test "doctor codex: live dispatcher and child locks report held without warnings" {
  local _h
  _h="$(proj_hash "$PROJ")"
  acquire_lock "codex-dispatcher:$_h" "$$"
  local _ch
  _ch="$(printf '%s' "team	alice" | agmsg_sha1)"
  acquire_lock "codex-child:$_h:$_ch" "$$"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 0 ]
  out_has "Codex dispatcher lock: held by live pid $$"
  out_has "Codex bridge-launcher child lock: held by live pid $$"
  out_has "no warnings."
}

@test "doctor codex: stale role-child runtime lock names the role" {
  local _h
  _h="$(proj_hash "$PROJ")"
  local _dead
  _dead="$(dead_pid)"
  local _ch
  _ch="$(printf '%s' "team	alice" | agmsg_sha1)"
  acquire_lock "codex-child:$_h:$_ch" "$_dead"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 1 ]
  out_has "Codex bridge-launcher child lock: held by dead pid $_dead"
  out_has "stale bridge-launcher child lock"
}

@test "doctor codex: a codex client argv containing 'app-server' is not an app-server" {
  # `codex exec "investigate app-server"` reaches ps as bare words — a
  # substring match would flag the Codex client itself as an app-server.
  local _pid
  _pid="$(foreign_pid)"
  printf '%s %s\n' "$_pid" "fakecodex exec investigate app-server" >> "$AGMSG_DOCTOR_PS_SNAPSHOT"

  run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 0 ]
  out_lacks "no record tracks it"
  out_has "no warnings."
}

@test "doctor codex: recorded pid running a codex client subcommand is foreign" {
  # The pidfile's pid is alive but its argv is `codex exec ... app-server`,
  # not `codex app-server` — pid reuse, not a live server.
  local _pid
  bash -c 'exec -a "fakecodex exec investigate app-server" sleep 60' >/dev/null 2>&1 3>&- 4>&- &
  _pid=$!
  track_pid "$_pid"
  write_appserver "$PROJ" "$_pid" "1" "codex-cli 9.9.9-test"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 1 ]
  out_has "pid $_pid alive but is not a Codex app-server"
}

@test "doctor codex: dispatcher lock under the canonical spelling is still found" {
  local _real="$TEST_SKILL_DIR/real-proj" _link="$TEST_SKILL_DIR/link-proj"
  mkdir -p "$_real"
  ln -s "$_real" "$_link"
  bash "$SCRIPTS/join.sh" team bob codex "$_link" >/dev/null
  local _phys _dead
  _phys="$(cd "$_link" && pwd -P)"
  _dead="$(dead_pid)"
  acquire_lock "codex-dispatcher:$(proj_hash "$_phys")" "$_dead"

  run bash "$SCRIPTS/doctor.sh" --project "$_link" --type codex
  [ "$status" -eq 1 ]
  out_has "Codex dispatcher lock: held by dead pid $_dead"
  out_has "stale dispatcher lock (owner pid $_dead not running)"
}

@test "doctor codex: locks under both spellings aggregate into one verdict" {
  # A live owner under one spelling and a dead row under the other are one
  # logical lock: the line reports both owners, the verdict is a single
  # held-alive, and the stale row still warns.
  local _real="$TEST_SKILL_DIR/real-proj" _link="$TEST_SKILL_DIR/link-proj"
  mkdir -p "$_real"
  ln -s "$_real" "$_link"
  bash "$SCRIPTS/join.sh" team bob codex "$_link" >/dev/null
  local _phys _dead
  _phys="$(cd "$_link" && pwd -P)"
  _dead="$(dead_pid)"
  acquire_lock "codex-dispatcher:$(proj_hash "$_link")" "$$"
  acquire_lock "codex-dispatcher:$(proj_hash "$_phys")" "$_dead"

  run bash "$SCRIPTS/doctor.sh" --project "$_link" --type codex
  [ "$status" -eq 1 ]
  out_has "Codex dispatcher lock: held by live pid $$; held by dead pid $_dead"
  out_has "stale dispatcher lock (owner pid $_dead not running)"
}

@test "doctor codex: --team filters other teams' child locks and bridge bindings" {
  # A project shared by two teams: team ops's leftovers must not leak into a
  # --team team report via this plug's per-role loops (the identities list
  # honours FILTER_TEAM). Delivery's own project-level stale-pidfile line is
  # out of this plug's reach and stays.
  bash "$SCRIPTS/join.sh" ops bob codex "$PROJ" >/dev/null
  local _h _dead
  _h="$(proj_hash "$PROJ")"
  _dead="$(dead_pid)"
  acquire_lock "codex-child:$_h:$(printf '%s' "ops	bob" | agmsg_sha1)" "$_dead"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$_dead" > "$TEST_SKILL_DIR/run/codex-bridge.ops.bob.pid"
  printf '%s' "ws://127.0.0.1:1" > "$TEST_SKILL_DIR/run/codex-bridge.ops.bob.appserver"
  printf '%s' "thread-b" > "$TEST_SKILL_DIR/run/codex-bridge.ops.bob.thread"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex --team team
  [ "$status" -eq 1 ]
  out_lacks "stale bridge-launcher child lock"
  out_lacks "(ops.bob,"

  # Unfiltered control: both leftovers still surface.
  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [ "$status" -eq 1 ]
  out_has "stale bridge-launcher child lock"
  out_has "stale bridge pidfile (ops.bob"
}

@test "doctor codex: live owners under both spellings is a lock conflict" {
  # Per-spelling lock resources are distinct database keys — two live
  # owners means two launchers actually run, not one healthy lock.
  local _real="$TEST_SKILL_DIR/real-proj" _link="$TEST_SKILL_DIR/link-proj"
  mkdir -p "$_real"
  ln -s "$_real" "$_link"
  bash "$SCRIPTS/join.sh" team bob codex "$_link" >/dev/null
  local _phys _other
  _phys="$(cd "$_link" && pwd -P)"
  _other="$(foreign_pid)"
  acquire_lock "codex-dispatcher:$(proj_hash "$_link")" "$$"
  acquire_lock "codex-dispatcher:$(proj_hash "$_phys")" "$_other"

  run bash "$SCRIPTS/doctor.sh" --project "$_link" --type codex
  [ "$status" -eq 1 ]
  out_has "Codex dispatcher lock: held by live pids $$ $_other"
  out_has "multiple live processes"
  out_has "duplicate launchers"
}

@test "doctor codex: bridge binding compares against the live spelling's endpoint" {
  # Registered spelling holds a stale record while the canonical spelling
  # holds the live server — a bridge bound to the live endpoint must not
  # read as stale.
  local _real="$TEST_SKILL_DIR/real-proj" _link="$TEST_SKILL_DIR/link-proj"
  mkdir -p "$_real"
  ln -s "$_real" "$_link"
  bash "$SCRIPTS/join.sh" team bob codex "$_link" >/dev/null
  local _phys _live_port _live_pid _dead _bpid
  _phys="$(cd "$_link" && pwd -P)"
  _live_port="$(start_listener "$TEST_SKILL_DIR/port.txt")"
  _live_pid="$(confirmed_pid)"
  _dead="$(dead_pid)"
  write_appserver "$_link" "$_dead" "1" "codex-cli 9.9.9-test"
  write_appserver "$_phys" "$_live_pid" "$_live_port" "codex-cli 9.9.9-test"
  _bpid="$(foreign_pid)"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$_bpid" > "$TEST_SKILL_DIR/run/codex-bridge.team.bob.pid"
  {
    echo "pid=$_bpid"
    echo "project=$_link"
    echo "identities=team/bob"
    echo "type=codex"
  } > "$TEST_SKILL_DIR/run/codex-bridge.team.bob.meta"
  printf '%s' "ws://127.0.0.1:$_live_port" > "$TEST_SKILL_DIR/run/codex-bridge.team.bob.appserver"
  printf '%s' "thread-x" > "$TEST_SKILL_DIR/run/codex-bridge.team.bob.thread"

  run bash "$SCRIPTS/doctor.sh" --project "$_link" --type codex
  # The stale raw-spelling record still warns; the binding must not.
  [ "$status" -eq 1 ]
  out_has "app-server=match"
  out_lacks "bound to a stale app-server"
}

@test "doctor codex: bridge pidfile for a dropped role warns when dead, notes when alive" {
  local _dead
  _dead="$(dead_pid)"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$_dead" > "$TEST_SKILL_DIR/run/codex-bridge.gone.role.pid"

  run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 1 ]
  out_has "not running (pid '$_dead')"
  out_has "stale bridge pidfile"

  local _live
  _live="$(foreign_pid)"
  printf '%s\n' "$_live" > "$TEST_SKILL_DIR/run/codex-bridge.gone.role.pid"
  run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 0 ]
  out_has "alive (pid $_live) but no registered role claims its key"
  out_has "ambiguous"
  kill -0 "$_live"
}

@test "doctor codex: a dotted team name still claims its bridge key" {
  # team "foo.bar" + agent "alice" is the bridge key "foo.bar.alice" —
  # splitting the filename at a dot would misread it as foo/bar.alice and
  # orphan a live registered bridge (claim is by forward construction).
  bash "$SCRIPTS/join.sh" foo.bar alice codex "$PROJ" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'ws://127.0.0.1:64001\n' > "$TEST_SKILL_DIR/run/codex-bridge.foo.bar.alice.appserver"

  local _dead
  _dead="$(dead_pid)"
  printf '%s\n' "$_dead" > "$TEST_SKILL_DIR/run/codex-bridge.foo.bar.alice.pid"
  write_bridge_meta "foo.bar.alice" "$_dead" "$PROJ"
  run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 1 ]
  # Claimed: the scoped per-pair verdict names the real key exactly once —
  # the unattributed global branch never fires a second, opaque stale line.
  out_has "stale bridge pidfile (foo.bar.alice"
  [ "$(printf '%s\n' "$output" | grep -cF 'stale bridge pidfile')" -eq 1 ]

  local _live
  _live="$(foreign_pid)"
  printf '%s\n' "$_live" > "$TEST_SKILL_DIR/run/codex-bridge.foo.bar.alice.pid"
  write_bridge_meta "foo.bar.alice" "$_live" "$PROJ"
  run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 0 ]
  out_lacks "no registered role claims its key"
  kill -0 "$_live"
}

@test "doctor codex: orphan role-session seat is advisory, not a warning" {
  mkdir -p "$TEST_SKILL_DIR/run"
  {
    echo "session=thread-gone"
    echo "name=gone-role"
    echo "team=gone"
    echo "agent=role"
    echo "type=codex"
    echo "project=$PROJ"
  } > "$TEST_SKILL_DIR/run/role-session.gone__role"

  run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 0 ]
  out_has "gone/role holds a seat record but no registration"
  out_has "advisory"
  out_has "no warnings."
}

@test "doctor codex: --redacted masks an orphan seat's unregistered names" {
  mkdir -p "$TEST_SKILL_DIR/run"
  {
    echo "session=thread-gone"
    echo "name=secrethandle-role"
    echo "team=secrethandle"
    echo "agent=role"
    echo "type=codex"
    echo "project=$PROJ"
  } > "$TEST_SKILL_DIR/run/role-session.secrethandle__role"

  run bash "$SCRIPTS/doctor.sh" --type codex --redacted
  [ "$status" -eq 0 ]
  out_lacks "secrethandle"
  out_has "seat record but no registration"
}

@test "doctor codex: app-server record under the canonical project spelling is diagnosed" {
  # A symlinked registration and a monitor launched through the physical
  # spelling hash the same directory differently; the record must still be
  # found, not silently skipped by both scans.
  local _real="$TEST_SKILL_DIR/real-proj" _link="$TEST_SKILL_DIR/link-proj"
  mkdir -p "$_real"
  ln -s "$_real" "$_link"
  bash "$SCRIPTS/join.sh" team bob codex "$_link" >/dev/null
  local _phys _pid _port
  _phys="$(cd "$_link" && pwd -P)"
  _port="$(start_listener "$TEST_SKILL_DIR/port.txt")"
  _pid="$(confirmed_pid)"
  write_appserver "$_phys" "$_pid" "$_port" "codex-cli 9.9.9-test"

  run bash "$SCRIPTS/doctor.sh" --project "$_link" --type codex
  [ "$status" -eq 0 ]
  out_has "canonical spelling"
  out_has "healthy (pid $_pid"
  out_has "no warnings."
}

@test "doctor codex: live records under both spellings of one project are a duplicate" {
  local _real="$TEST_SKILL_DIR/real-proj" _link="$TEST_SKILL_DIR/link-proj"
  mkdir -p "$_real"
  ln -s "$_real" "$_link"
  bash "$SCRIPTS/join.sh" team bob codex "$_link" >/dev/null
  local _phys _port1 _port2 _pid1 _pid2
  _phys="$(cd "$_link" && pwd -P)"
  _port1="$(start_listener "$TEST_SKILL_DIR/port1.txt")"
  _port2="$(start_listener "$TEST_SKILL_DIR/port2.txt")"
  _pid1="$(confirmed_pid)"
  _pid2="$(confirmed_pid)"
  write_appserver "$_link" "$_pid1" "$_port1" "codex-cli 9.9.9-test"
  write_appserver "$_phys" "$_pid2" "$_port2" "codex-cli 9.9.9-test"

  run bash "$SCRIPTS/doctor.sh" --project "$_link" --type codex
  [ "$status" -eq 1 ]
  out_has "duplicate server pair"
  # Both servers are evidence, not targets.
  kill -0 "$_pid1"
  kill -0 "$_pid2"
}

@test "doctor codex: shim absent is a note; foreign-owned and broken shims warn" {
  run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 0 ]
  out_has "Codex shim: not installed"
  out_has "no warnings."

  # A shim owned by another install: launches through it dispatch into the
  # wrong storage — a real misconfiguration, so it warns.
  mkdir -p "$HOME/.agents/bin"
  {
    echo "#!/usr/bin/env bash"
    echo "# Optional Codex entrypoint shim for agmsg monitor mode"
    echo "# agmsg-shim-owner: /other/install"
    echo "exit 0"
  } > "$HOME/.agents/bin/codex"
  chmod +x "$HOME/.agents/bin/codex"
  run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 1 ]
  out_has "owned by a different agmsg install"
  out_has "dispatches into that install"
}

@test "doctor codex: shim owned by this install resolves through PATH quietly" {
  mkdir -p "$HOME/.agents/bin"
  local _owner
  _owner="$(printf '%q' "$SCRIPTS/drivers/types/codex")"
  {
    echo "#!/usr/bin/env bash"
    echo "# Optional Codex entrypoint shim for agmsg monitor mode"
    echo "# agmsg-shim-owner: $_owner"
    echo "exec $(printf '%q' "$SCRIPTS/drivers/types/codex/codex-shim.sh") \"\$@\""
  } > "$HOME/.agents/bin/codex"
  chmod +x "$HOME/.agents/bin/codex"

  PATH="$HOME/.agents/bin:$PATH" run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 0 ]
  out_has "owned by this install"
  out_has "dispatch target intact"
  out_has "PATH-effective"
  out_has "no warnings."
}

@test "doctor codex: self-owned shim that never execs codex-shim.sh warns" {
  # Marker + owner stamp survive a truncated/repointed body — attribution
  # alone is not dispatch health.
  mkdir -p "$HOME/.agents/bin"
  local _owner
  _owner="$(printf '%q' "$SCRIPTS/drivers/types/codex")"
  {
    echo "#!/usr/bin/env bash"
    echo "# Optional Codex entrypoint shim for agmsg monitor mode"
    echo "# agmsg-shim-owner: $_owner"
    echo "exit 0"
  } > "$HOME/.agents/bin/codex"
  chmod +x "$HOME/.agents/bin/codex"

  run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 1 ]
  out_has "owned by this install, but its body never execs this install's codex-shim.sh"
  out_has "truncated or repointed body"
  out_lacks "dispatch target intact"
}

@test "doctor codex: legacy shim that dispatches nowhere warns too" {
  mkdir -p "$HOME/.agents/bin"
  {
    echo "#!/usr/bin/env bash"
    echo "# Optional Codex entrypoint shim for agmsg monitor mode"
    echo "exit 0"
  } > "$HOME/.agents/bin/codex"
  chmod +x "$HOME/.agents/bin/codex"

  run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 1 ]
  out_has "owner unknown, and its body never execs a codex-shim.sh"
  out_has "predates ownership tracking and never execs a codex-shim.sh"
}

@test "doctor codex: shim shadowed by another codex is a note, never a warning" {
  mkdir -p "$HOME/.agents/bin"
  local _owner
  _owner="$(printf '%q' "$SCRIPTS/drivers/types/codex")"
  {
    echo "#!/usr/bin/env bash"
    echo "# Optional Codex entrypoint shim for agmsg monitor mode"
    echo "# agmsg-shim-owner: $_owner"
    echo "exec $(printf '%q' "$SCRIPTS/drivers/types/codex/codex-shim.sh") \"\$@\""
  } > "$HOME/.agents/bin/codex"
  chmod +x "$HOME/.agents/bin/codex"
  # A non-shim codex earlier on PATH: the PATH shim is bypassed, but a shell
  # function may still route launches — note only.
  local _stubdir="$TEST_SKILL_DIR/codex-stub"
  mkdir -p "$_stubdir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$_stubdir/codex"
  chmod +x "$_stubdir/codex"

  PATH="$_stubdir:$PATH" run bash "$SCRIPTS/doctor.sh" --type codex
  [ "$status" -eq 0 ]
  out_has "not the shim"
  out_lacks "codex_shim_"
  out_has "no warnings."
}
