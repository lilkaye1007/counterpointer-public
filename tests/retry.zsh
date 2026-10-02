#!/bin/zsh
set -euo pipefail
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1 COUNTERPOINTER_RUNTIME_TEST=1

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git -C "$root" init -q
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print 'retry fixture' > "$root/README.md"
git -C "$root" add README.md
git -C "$root" commit -qm fixture

tasks=()
cpt -C "$root" config --max-parallel 3 >/dev/null
for number in 1 2 3; do
  task="$(cpt -C "$root" register --mode quick --text "再試行試験${number}を実施する" --path "retry-${number}.txt")"
  cpt -C "$root" dispatch "$task" >/dev/null
  tasks+=("$task")
done
db="$root/.counterpointer/state.sqlite3"
sqlite3 "$db" "UPDATE tasks SET state='FAILED';"

if cpt -C "$root" retry --all --refresh >/dev/null 2>&1; then
  print -u2 '--refreshが誤って受理されました'
  exit 1
fi
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE state='FAILED';")" == 3 ]]

cpt -C "$root" config --max-parallel 2 >/dev/null
cpt -C "$root" retry --all --fresh >/dev/null
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE state='READY';")" == 3 ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM task_retry_requests WHERE launch_mode='RESTART' AND state='QUEUED';")" == 3 ]]

# 全体停止は許可済み再試行も止め、再開後は空き枠まで自動起動する。
print 'state=RUNNING' > "$root/.counterpointer/service.state"
cpt -C "$root" schedule pause >/dev/null
cpt -C "$root" supervise --once >/dev/null
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE state='READY';")" == 3 ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM task_runtimes;")" == 0 ]]

cpt -C "$root" schedule resume >/dev/null
cpt -C "$root" supervise --once >/dev/null
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE state='RUNNING';")" == 2 ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE state='READY';")" == 1 ]]
first_running="$(sqlite3 "$db" "SELECT task_id FROM tasks WHERE state='RUNNING' ORDER BY created_at LIMIT 1;")"
[[ "$(sqlite3 "$db" "SELECT state FROM task_runtimes WHERE task_id='$first_running' ORDER BY generation DESC LIMIT 1;")" == RESTARTING ]]

print 'retry: passed'
