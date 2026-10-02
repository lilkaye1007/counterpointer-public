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
git -C "$root" add .
git -C "$root" commit -qm base
task="$(cpt -C "$root" register --mode quick --text 'README.mdへ成果を追加する' --path README.md)"
cpt -C "$root" dispatch "$task" >/dev/null
wt="$root/.counterpointer/worktrees/$task"
db="$root/.counterpointer/state.sqlite3"
# Reproduce the legacy empty verification and an unpublished candidate.
cpt -C "$root" complete "$task" >/dev/null
cpt -C "$root" verify "$task" >/dev/null
cpt -C "$root" external-verify "$task" >/dev/null
job="$(cpt -C "$root" integrate | tail -1)"
cpt -C "$root" publish "$job" >/dev/null
request="$(sqlite3 "$db" 'SELECT request_id FROM publish_requests;')"
successor="$(cpt -C "$root" register --mode quick --text '後続の結果を保存する' --path next.txt --depends-on "$task")"
cpt -C "$root" schedule hold "$successor" 'Aの正常完了待ち' >/dev/null
invariants="$(sqlite3 "$db" 'SELECT * FROM task_artifacts; SELECT * FROM task_edges; SELECT * FROM change_set_tasks; SELECT task_id,hold_reason FROM task_schedule;')"
old_commit="$(git -C "$wt" rev-parse HEAD)"
cpt -C "$root" invalidate-verification "$task" --reason 'empty result' >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$task';")" == VERIFIED ]]
# Dirty work, changed plans, begun successors, and publication attempts must fail closed.
print dirty >> "$wt/README.md"
if cpt -C "$root" invalidate-verification "$task" --reason test --apply >/dev/null 2>&1; then exit 1; fi
git -C "$wt" restore README.md
cp "$wt/.counterpointer-task/goal.md" "$root/goal.backup"
print tamper >> "$wt/.counterpointer-task/goal.md"
if cpt -C "$root" invalidate-verification "$task" --reason test --apply >/dev/null 2>&1; then exit 1; fi
cp "$root/goal.backup" "$wt/.counterpointer-task/goal.md"
sqlite3 "$db" "UPDATE tasks SET state='RUNNING' WHERE task_id='$successor';"
if cpt -C "$root" invalidate-verification "$task" --reason test --apply >/dev/null 2>&1; then exit 1; fi
sqlite3 "$db" "UPDATE tasks SET state='REGISTERED' WHERE task_id='$successor'; UPDATE pull_requests SET last_pushed_sha='$old_commit' WHERE request_id='$request';"
if cpt -C "$root" invalidate-verification "$task" --reason test --apply >/dev/null 2>&1; then exit 1; fi
sqlite3 "$db" "UPDATE pull_requests SET last_pushed_sha=NULL WHERE request_id='$request';"
cpt -C "$root" invalidate-verification "$task" --reason 'empty result' --apply >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$task';")" == FAILED ]]
[[ "$(sqlite3 "$db" 'SELECT status FROM verify_results; SELECT state FROM integration_jobs; SELECT state FROM publish_requests;')" == $'FAILED\nFAILED\nFAILED' ]]
[[ "$(sqlite3 "$db" 'SELECT * FROM task_artifacts; SELECT * FROM task_edges; SELECT * FROM change_set_tasks; SELECT task_id,hold_reason FROM task_schedule;')" == "$invariants" ]]
archive="$(sqlite3 "$db" "SELECT value FROM metadata WHERE key='verification_revoked:$task';")"
[[ -s "$archive/before.sqlite3" && -s "$archive/verification-evidence/result.txt" ]]
[[ "$(sqlite3 "$archive/before.sqlite3" "SELECT state FROM tasks WHERE task_id='$task';")" == VERIFIED ]]
cpt -C "$root" invalidate-verification "$task" --reason repeated --apply >/dev/null
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE event_type='VERIFICATION_REVOKED';")" == 1 ]]
for operation in "publish $job" "publish approve $request" "publish apply $request" "retry $task" "verify $task"; do
  if cpt -C "$root" ${=operation} >/dev/null 2>&1; then print -u2 "失効候補を再利用しました: $operation"; exit 1; fi
done
cpt -C "$root" retry "$task" --fresh >/dev/null
cpt -C "$root" dispatch "$task" >/dev/null
if cpt -C "$root" run "$task" --resume >/dev/null 2>&1; then exit 1; fi
cpt -C "$root" run "$task" >/dev/null
launcher="$wt/.counterpointer-task/launch-1.zsh"
if grep -q 'resume --last' "$launcher"; then exit 1; fi
[[ "$(sqlite3 "$db" "SELECT launch_mode FROM task_runtimes WHERE task_id='$task';")" == RESTART ]]
for operation in "selfcheck $task" "complete $task"; do
  if cpt -C "$root" ${=operation} >/dev/null 2>&1; then print -u2 '空の成果が完了申告されました'; exit 1; fi
done
# An old external-verification path cannot revalidate the empty SHA.
sqlite3 "$db" "UPDATE tasks SET state='VERIFIED',commit_sha='$old_commit' WHERE task_id='$task';"
if cpt -C "$root" external-verify "$task" >/dev/null 2>&1; then exit 1; fi
sqlite3 "$db" "UPDATE tasks SET state='CLAIMED_DONE' WHERE task_id='$task';"
if cpt -C "$root" verify "$task" >/dev/null 2>&1; then exit 1; fi
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$task';")" == FAILED ]]
# Real changes pass the normal pipeline, and old evidence stays preserved.
sqlite3 "$db" "UPDATE tasks SET state='RUNNING' WHERE task_id='$task';"
print 'actual implementation' >> "$wt/README.md"
cpt -C "$root" selfcheck "$task" >/dev/null
cpt -C "$root" verify "$task" >/dev/null
cpt -C "$root" external-verify "$task" >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$task';")" == VERIFIED ]]
[[ "$(sqlite3 "$db" 'SELECT state FROM publish_requests;')" == FAILED ]]
[[ "$(sqlite3 "$db" "SELECT hold_reason FROM task_schedule WHERE task_id='$successor';")" == 'Aの正常完了待ち' ]]
cpt -C "$root" audit verify >/dev/null
print 'verification-recovery: passed'
