#!/bin/zsh
set -euo pipefail
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1 COUNTERPOINTER_RUNTIME_TEST=1
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print base > "$root/README.md"
git -C "$root" add README.md
git -C "$root" commit -qm base
task="$(cpt -C "$root" register --mode quick --text 'README.mdにブラウザ検証結果を記録する' --path README.md)"
cpt -C "$root" dispatch "$task" >/dev/null
cpt -C "$root" run "$task" >/dev/null
source "${0:A:h}/fixtures/codex-session.zsh"
record_codex_fixture "$root" "$root/.counterpointer/worktrees/$task"
db="$root/.counterpointer/state.sqlite3"
wt="$root/.counterpointer/worktrees/$task"
marker="$wt/.counterpointer-task/turn-complete-1.json"
launcher="$wt/.counterpointer-task/launch-1.zsh"
zsh -n "$launcher"
grep -Fq -- '--ask-for-approval never --sandbox workspace-write' "$launcher"
# Parse the actual generated shell arguments, including notify JSON quoting.
script() { print -rl -- "$@" > "$root/launcher-args.txt"; }
eval "$(sed -n '/^script -q /p' "$launcher")"
unfunction script
notify_arg="$(sed -n '/^notify=/p' "$root/launcher-args.txt")"
print -r -- "${notify_arg#notify=}" | jq -e --arg task "$task" '.[3:]==["runtime","turn-complete",$task,"1"]' >/dev/null
grep -Fq -- 'cpt blocked' "$wt/.counterpointer-task/initial-prompt.md"
# An idle-but-live process retains its execution reservation, exposes attention,
# and emits exactly one durable parent notice even under concurrent supervisors.
cpt -C "$root" runtime started "$task" 1 $$
payload="$(jq -cn --arg cwd "$wt" '{type:"agent-turn-complete",cwd:$cwd,"last-assistant-message":"Chrome検証がEPERMで未完了。HTTP検証も残っています。"}')"
cpt -C "$root" runtime turn-complete "$task" 1 "$payload"
[[ -s "$marker" ]]
cpt -C "$root" runtime reconcile test 0 >/dev/null &
p1=$!
cpt -C "$root" runtime reconcile test 0 >/dev/null &
p2=$!
wait "$p1"; wait "$p2"
cpt -C "$root" runtime reconcile test 0 >/dev/null
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM parent_notices WHERE notice_id='child-attention:$task:1' AND state='PENDING';")" == 1 ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$task';")" == RUNNING ]]
[[ "$(sqlite3 "$db" "SELECT state FROM task_runtimes WHERE task_id='$task';")" == ACTIVE ]]
cpt -C "$root" status --json | jq -e --arg task "$task" '.[] | select(.task_id==$task) | .display_state=="NEEDS_ATTENTION" and .completed==false and (.waiting_reason|contains("Chrome"))' >/dev/null
# Reporting doesn't complete the task or discard edits; neither does status.
print changes >> "$wt/README.md"
[[ -n "$(git -C "$wt" diff)" ]]
[[ ! -e "$wt/.counterpointer-task/selfcheck.txt" ]]
# A new generation clears the displayed attention without deleting old evidence.
print '前世代の検証結果を保持' > "$wt/.counterpointer-task/completion-report.md"
cpt -C "$root" runtime exited "$task" 1 1
# This fixture recorded the test harness PID, not a real child. Model actual exit.
sqlite3 "$db" "UPDATE task_runtimes SET process_pid=NULL WHERE task_id='$task' AND generation=1;"
cpt -C "$root" runtime reconcile test 0 >/dev/null
cpt -C "$root" runtime started "$task" 2 $$
cpt -C "$root" status --json | jq -e --arg task "$task" '.[] | select(.task_id==$task) | .display_state=="RUNNING"' >/dev/null
grep -Fq -- '--ask-for-approval never --sandbox workspace-write' "$wt/.counterpointer-task/launch-2.zsh"
grep -Fq -- 'runtime-policy.md' "$wt/.counterpointer-task/launch-2.zsh"
grep -Fq -- '前世代の検証結果を保持' "$wt/.counterpointer-task/initial-prompt.md"
[[ -s "$wt/.counterpointer-task/completion-report-generation-1.md" ]]
[[ ! -e "$wt/.counterpointer-task/completion-report.md" ]]
# Stale generations, unrelated cwd, malformed payloads and non-final events
# cannot report the currently active task as blocked.
/bin/rm "$marker"
cpt -C "$root" runtime turn-complete "$task" 1 "$payload"
[[ ! -e "$marker" ]]
cpt -C "$root" runtime turn-complete "$task" 2 '{}'
cpt -C "$root" runtime turn-complete "$task" 2 'bad JSON'
cpt -C "$root" runtime turn-complete "$task" 2 "$(print -r -- "$payload" | jq '.cwd="/different/task"')"
cpt -C "$root" runtime turn-complete "$task" 2 "$(print -r -- "$payload" | jq '.type="approval-requested"')"
cpt -C "$root" runtime turn-complete "$task" 2 "$(print -r -- "$payload" | jq --arg msg '{"title":"対象ソースを確認する"}' '."last-assistant-message"=$msg')"
[[ ! -e "$wt/.counterpointer-task/turn-complete-2.json" ]]
# Explicit blocked reporting is available when no final-turn hook has fired.
cpt -C "$root" blocked "$task" 'HTTP listen EPERM。承認された環境で再開が必要。' >/dev/null
cpt -C "$root" runtime reconcile test 0 >/dev/null
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM parent_notices WHERE notice_id='child-attention:$task:2';")" == 1 ]]
# A later successful completion wins over a pending final-turn report.
cpt -C "$root" selfcheck "$task" >/dev/null
cpt -C "$root" runtime reconcile test 0 >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$task';")" == CLAIMED_DONE ]]
cpt -C "$root" status --json | jq -e --arg task "$task" '.[] | select(.task_id==$task) | .display_state=="CLAIMED_DONE"' >/dev/null
print 'child-attention: passed'
