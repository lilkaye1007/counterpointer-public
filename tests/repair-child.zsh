#!/bin/zsh
set -euo pipefail
PATH="${0:A:h:h}/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1 COUNTERPOINTER_RUNTIME_TEST=1
root="$(mktemp -d)"
trap '[[ -z "${worker_pid:-}" ]] || kill -KILL "$worker_pid" 2>/dev/null || true; rm -rf "$root"' EXIT
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print base > "$root/README.md"
git -C "$root" add README.md
git -C "$root" commit -qm base
task="$(cpt -C "$root" register --mode quick --text 'README.mdに記録する' --path README.md)"
cpt -C "$root" dispatch "$task" >/dev/null
cpt -C "$root" run "$task" >/dev/null
wt="$root/.counterpointer/worktrees/$task"
db="$root/.counterpointer/state.sqlite3"
print unfinished >> "$wt/README.md"
launcher="$wt/.counterpointer-task/launch-1.zsh"
cat > "$launcher" <<'WORKER'
#!/bin/zsh
trap '' TERM
sleep 120 &
wait
WORKER
/bin/zsh "$launcher" &
worker_pid=$!
cpt -C "$root" runtime started "$task" 1 "$worker_pid" >/dev/null
# A mismatched PID cannot trigger state changes.
sqlite3 "$db" "UPDATE task_runtimes SET process_pid=$$ WHERE task_id='$task';"
if cpt -C "$root" repair-child "$task" '停止検証' >/dev/null 2>&1; then exit 1; fi
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$task';")" == RUNNING ]]
sqlite3 "$db" "UPDATE task_runtimes SET process_pid=$worker_pid WHERE task_id='$task';"
cpt -C "$root" repair-child "$task" '応答停止を親が確認' >/dev/null
wait "$worker_pid" 2>/dev/null || true
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$task';")" == READY ]]
[[ "$(sqlite3 "$db" "SELECT state FROM task_runtimes WHERE task_id='$task';")" == CANCELLED ]]
[[ "$(sqlite3 "$db" "SELECT launch_mode FROM task_retry_requests WHERE task_id='$task';")" == RESTART ]]
[[ -n "$(git -C "$wt" diff)" ]]
print 'repair-child: passed'
