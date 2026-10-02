#!/bin/zsh
set -euo pipefail
cli="${0:A:h:h}/bin/cpt"
root="$(mktemp -d)"
worker_pid=''
trap '[[ -z "$worker_pid" ]] || kill -TERM "$worker_pid" 2>/dev/null || true; rm -rf "$root"' EXIT
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print base > "$root/README.md"
git -C "$root" add .; git -C "$root" commit -qm base
COUNTERPOINTER_TEST=1 "$cli" -C "$root" service install >/dev/null
print 'installed_at=test\nstate=STOPPED' > "$root/.counterpointer/service.state"
mkdir -p "$root/bin"
cat > "$root/bin/cpt" <<'MONITOR'
#!/bin/zsh
sleep 120 &
wait
MONITOR
/bin/zsh "$root/bin/cpt" -C "$root" supervise --watch &
worker_pid=$!
# No pidfile: this reproduces the actual leftover supervisor failure.
if "$cli" -C "$root" service start > "$root/start.log" 2>&1; then exit 1; fi
grep -q '旧監視が残っています' "$root/start.log"
COUNTERPOINTER_TEST=1 "$cli" -C "$root" service stop >/dev/null
wait "$worker_pid" 2>/dev/null || true
if kill -0 "$worker_pid" 2>/dev/null; then exit 1; fi
worker_pid=''
[[ "$(sed -n 's/^state=//p' "$root/.counterpointer/service.state")" == STOPPED ]]
print 'orphan-monitor: passed (unrecorded monitor blocks start and is stopped)'
cat > "$root/.counterpointer/parent-launch.zsh" <<'PARENT'
#!/bin/zsh
sleep 120 &
child=$!
trap 'kill -TERM "$child" 2>/dev/null; exit 0' TERM
wait
PARENT
/bin/zsh "$root/.counterpointer/parent-launch.zsh" 1 &
worker_pid=$!
sqlite3 "$root/.counterpointer/state.sqlite3" "INSERT INTO parent_runtimes(generation,state,process_pid,started_at,last_heartbeat_at,updated_at) VALUES(1,'LOST',$worker_pid,'2026-01-01','2026-01-01','2026-01-01');"
if "$cli" -C "$root" service start > "$root/parent-start.log" 2>&1; then exit 1; fi
grep -q '旧親が生存しています' "$root/parent-start.log"
kill -TERM "$worker_pid"
wait "$worker_pid"
worker_pid=''
print 'old-parent: passed (LOST state cannot hide a living parent)'
