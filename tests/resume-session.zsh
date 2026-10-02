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
task="$(cpt -C "$root" register --mode quick --text 'README.mdに再開検証を記録する' --path README.md)"
cpt -C "$root" dispatch "$task" >/dev/null
cpt -C "$root" run "$task" >/dev/null
wt="$root/.counterpointer/worktrees/$task"
source "${0:A:h}/fixtures/codex-session.zsh"
record_codex_fixture "$root" "$wt"
# A newer conversation in the project root must never win over this worktree.
other=22222222-2222-4222-8222-222222222222
jq -cn --arg id "$other" --arg cwd "$root" '{type:"session_meta",payload:{id:$id,cwd:$cwd}}' > "$CODEX_HOME/other.jsonl"
sqlite3 "$CODEX_HOME/state_5.sqlite" "INSERT INTO threads VALUES ('$other','$root','$CODEX_HOME/other.jsonl',999,0);"
cpt -C "$root" runtime exited "$task" 1 1
cpt -C "$root" run "$task" --resume >/dev/null
launcher="$wt/.counterpointer-task/launch-2.zsh"
grep -Fq "codex resume $CPT_FIXTURE_SESSION " "$launcher"
grep -Fq "cd -- $wt" "$launcher"
if grep -Fq -- '--last' "$launcher"; then exit 1; fi
if grep -Fq "$other" "$launcher"; then exit 1; fi
# The index alone is insufficient: forged/mismatched rollout metadata cannot
# redirect resume to another task, even with a matching cwd in the index.
sqlite3 "$CODEX_HOME/state_5.sqlite" "UPDATE threads SET rollout_path='$CODEX_HOME/other.jsonl' WHERE id='$CPT_FIXTURE_SESSION';"
cpt -C "$root" runtime exited "$task" 2 1
cpt -C "$root" run "$task" --resume >/dev/null
launcher="$wt/.counterpointer-task/launch-3.zsh"
if grep -Fq 'codex resume ' "$launcher"; then exit 1; fi
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT launch_mode||'|'||restart_attempts FROM task_runtimes WHERE task_id='$task' AND generation=3;")" == 'RESTART|1' ]]
# Repeated missing-session recovery stops at the existing bounded limit.
cpt -C "$root" runtime exited "$task" 3 1
if cpt -C "$root" run "$task" --resume >/dev/null 2>&1; then exit 1; fi
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT state FROM tasks WHERE task_id='$task';")" == FAILED ]]
print 'resume-session: passed'
