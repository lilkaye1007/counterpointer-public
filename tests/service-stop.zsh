#!/bin/zsh
set -euo pipefail
PATH="${0:A:h:h}/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1 COUNTERPOINTER_RUNTIME_TEST=1
root="$(mktemp -d)"
trap '[[ -z "${worker_pid:-}" ]] || kill -KILL "$worker_pid" 2>/dev/null || true; [[ -z "${monitor_pid:-}" ]] || kill -KILL "$monitor_pid" 2>/dev/null || true; [[ -z "${parent_pid:-}" ]] || kill -KILL "$parent_pid" 2>/dev/null || true; [[ ! -f "$root/stop.log" ]] || cat "$root/stop.log"; rm -rf "$root"' EXIT
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print base > "$root/README.md"
git -C "$root" add .; git -C "$root" commit -qm base
a="$(cpt -C "$root" register --mode quick --text 'a.txtを追加する' --path a.txt)"
cpt -C "$root" dispatch "$a" >/dev/null
cpt -C "$root" run "$a" >/dev/null
db="$root/.counterpointer/state.sqlite3"
wt="$root/.counterpointer/worktrees/$a"
print 'unfinished work' > "$wt/a.txt"
launcher="$wt/.counterpointer-task/launch-1.zsh"
cat > "$launcher" <<'WORKER'
#!/bin/zsh
trap '' TERM
sleep 120 &
wait
WORKER
/bin/zsh "$launcher" &
worker_pid=$!
cpt -C "$root" runtime started "$a" 1 "$worker_pid" >/dev/null
# A queued launch without a PID must also be invalidated.
b="$(cpt -C "$root" register --mode quick --text 'b.txtを追加する' --path b.txt)"
cpt -C "$root" dispatch "$b" >/dev/null
cpt -C "$root" run "$b" >/dev/null
pending_launcher="$root/.counterpointer/worktrees/$b/.counterpointer-task/launch-1.zsh"
cpt -C "$root" service install >/dev/null
print 'installed_at=fixture\nstate=RUNNING' > "$root/.counterpointer/service.state"
# A monitor fixture with the same identity shape; no actual service is launched.
cat > "$root/monitor.zsh" <<'MONITOR'
#!/bin/zsh
sleep 120 &
wait
MONITOR
/bin/zsh "$root/monitor.zsh" -C "$root" supervise --watch &
monitor_pid=$!
print "$monitor_pid" > "$root/.counterpointer/supervisor.pid"
parent_launcher="$root/.counterpointer/parent-launch.zsh"
cat > "$parent_launcher" <<'PARENT'
#!/bin/zsh
trap '' TERM
sleep 120 &
wait
PARENT
/bin/zsh "$parent_launcher" &
parent_pid=$!
sqlite3 "$db" "INSERT INTO parent_runtimes(generation,state,process_pid,started_at,updated_at) VALUES (1,'ACTIVE',$parent_pid,datetime('now'),datetime('now'));"
# A wrong PID must fail safely, preserve work, and block restart.
print $$ > "$root/.counterpointer/watchdog.pid"
if cpt -C "$root" service stop > "$root/stop.log" 2>&1; then exit 1; fi
[[ "$(sed -n 's/^state=//p' "$root/.counterpointer/service.state")" == STOPPING ]]
[[ ! -e "$root/.counterpointer/parent-close-requested" ]]
kill -0 "$parent_pid"
if cpt -C "$root" service start >/dev/null 2>&1; then exit 1; fi
/bin/rm "$root/.counterpointer/watchdog.pid"
cpt -C "$root" service stop > "$root/stop.log" 2>&1
wait "$worker_pid" 2>/dev/null || true
wait "$monitor_pid" 2>/dev/null || true
if kill -0 "$worker_pid" 2>/dev/null; then exit 1; fi
if kill -0 "$monitor_pid" 2>/dev/null; then exit 1; fi
wait "$parent_pid" 2>/dev/null || true
if kill -0 "$parent_pid" 2>/dev/null; then exit 1; fi
[[ "$(sqlite3 "$db" 'SELECT state FROM parent_runtimes WHERE generation=1;')" == STOPPED ]]
[[ "$(<"$wt/a.txt")" == 'unfinished work' ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$a';")" == READY ]]
[[ "$(sqlite3 "$db" "SELECT state FROM task_runtimes WHERE task_id='$a';")" == CANCELLED ]]
[[ "$(sqlite3 "$db" "SELECT launch_mode FROM task_retry_requests WHERE task_id='$a';")" == RESTART ]]
# Late queued pane launches, late heartbeats, and scheduler calls cannot revive it.
if /bin/zsh "$launcher"; then exit 1; fi
if /bin/zsh "$pending_launcher"; then exit 1; fi
if cpt -C "$root" runtime started "$a" 1 $$ >/dev/null 2>&1; then exit 1; fi
if cpt -C "$root" dispatch --automatic >/dev/null 2>&1; then exit 1; fi
if cpt -C "$root" run "$a" >/dev/null 2>&1; then exit 1; fi
cpt -C "$root" service stop >/dev/null
cpt -C "$root" service start >/dev/null
cpt -C "$root" dispatch --automatic >/dev/null
[[ "$(<"$wt/a.txt")" == 'unfinished work' ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$a';")" == RUNNING ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM task_runtimes WHERE task_id='$a' AND state='RESTARTING';")" == 1 ]]
[[ "$(sqlite3 "$db" "SELECT MAX(generation) FROM task_runtimes WHERE task_id='$a';")" == 2 ]]
cpt -C "$root" dispatch --automatic >/dev/null
[[ "$(sqlite3 "$db" "SELECT MAX(generation) FROM task_runtimes WHERE task_id='$a';")" == 2 ]]
print 'service stop: passed'
