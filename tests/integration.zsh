#!/bin/zsh
set -euo pipefail
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1

semantic_root="$(mktemp -d)"
text_root="$(mktemp -d)"
trap 'rm -rf "$semantic_root" "$text_root"' EXIT

# cherry-pickは成功するが、組合せの受入条件に失敗する意味的競合。
git -C "$semantic_root" init -q
git -C "$semantic_root" config user.name test
git -C "$semantic_root" config user.email test@example.com
mkdir -p "$semantic_root/tests"
print 'value=0
compatible=false' > "$semantic_root/left.txt"
print 'value=0' > "$semantic_root/right.txt"
print '#!/bin/zsh
set -euo pipefail
grep -q "^value=1$" left.txt
grep -q "^compatible=true$" left.txt
grep -q "^value=1$" right.txt' > "$semantic_root/tests/integration-verify.zsh"
git -C "$semantic_root" add .
git -C "$semantic_root" commit -qm fixture
cpt -C "$semantic_root" config --integration-verify tests/integration-verify.zsh >/dev/null
semantic_change_set="$(cpt -C "$semantic_root" changeset create --title '意味的競合試験')"
left_task="$(cpt -C "$semantic_root" register --mode quick --text '左側の値を1へ更新する' --path left.txt --change-set "$semantic_change_set")"
right_task="$(cpt -C "$semantic_root" register --mode quick --text '右側の値を1へ更新する' --path right.txt --change-set "$semantic_change_set")"
cpt -C "$semantic_root" queue --all
cpt -C "$semantic_root" dispatch --all
semantic_db="$semantic_root/.counterpointer/state.sqlite3"
left_worktree="$(sqlite3 "$semantic_db" "SELECT worktree FROM tasks WHERE task_id='$left_task';")"
right_worktree="$(sqlite3 "$semantic_db" "SELECT worktree FROM tasks WHERE task_id='$right_task';")"
print 'value=1
compatible=false' > "$left_worktree/left.txt"
print 'value=1' > "$right_worktree/right.txt"
for semantic_task in "$left_task" "$right_task"; do
  cpt -C "$semantic_root" selfcheck "$semantic_task" >/dev/null
  cpt -C "$semantic_root" verify "$semantic_task"
  cpt -C "$semantic_root" external-verify "$semantic_task" >/dev/null
done
if cpt -C "$semantic_root" integrate "$semantic_change_set" >"$semantic_root/first-integration.out" 2>&1; then
  print -u2 '意味的競合が統合成功として扱われました'
  exit 1
fi
semantic_job="$(sqlite3 "$semantic_db" "SELECT job_id FROM integration_jobs WHERE change_set_id='$semantic_change_set' ORDER BY created_at DESC,rowid DESC LIMIT 1;")"
[[ "$(sqlite3 "$semantic_db" "SELECT failure_reason FROM integration_jobs WHERE job_id='$semantic_job';")" == SEMANTIC_VERIFY ]]
semantic_fix="$(sqlite3 "$semantic_db" "SELECT m.task_id FROM change_set_tasks m WHERE m.change_set_id='$semantic_change_set' AND m.member_kind='integration_fix' ORDER BY m.created_at DESC LIMIT 1;")"
if [[ -z "$semantic_fix" ]]; then
  print -u2 '意味的競合の修復Taskが作成されませんでした'
  /bin/cat "$semantic_root/first-integration.out" >&2
  sqlite3 -header -column "$semantic_db" 'SELECT * FROM integration_failures;' >&2
  exit 1
fi
[[ "$(sqlite3 "$semantic_db" "SELECT dispatch_base_sha FROM tasks WHERE task_id='$semantic_fix';")" == "$(sqlite3 "$semantic_db" "SELECT candidate_sha FROM integration_jobs WHERE job_id='$semantic_job';")" ]]
cpt -C "$semantic_root" dispatch "$semantic_fix" >/dev/null
semantic_fix_worktree="$(sqlite3 "$semantic_db" "SELECT worktree FROM tasks WHERE task_id='$semantic_fix';")"
print 'value=1
compatible=true' > "$semantic_fix_worktree/left.txt"
cpt -C "$semantic_root" selfcheck "$semantic_fix" >/dev/null
cpt -C "$semantic_root" verify "$semantic_fix"
cpt -C "$semantic_root" external-verify "$semantic_fix" >/dev/null
semantic_success_job="$(cpt -C "$semantic_root" integrate "$semantic_change_set" | tail -1)"
[[ "$(sqlite3 "$semantic_db" "SELECT state FROM integration_jobs WHERE job_id='$semantic_success_job';")" == VERIFIED ]]
[[ -s "$semantic_root/.counterpointer/integration-evidence/$semantic_success_job/result.sha256" ]]

# 同一行を別Taskが変更するテキスト競合。
git -C "$text_root" init -q
git -C "$text_root" config user.name test
git -C "$text_root" config user.email test@example.com
mkdir -p "$text_root/tests"
print 'base' > "$text_root/conflict.txt"
print '#!/bin/zsh
set -euo pipefail
grep -q "^resolved$" conflict.txt' > "$text_root/tests/integration-verify.zsh"
git -C "$text_root" add .
git -C "$text_root" commit -qm fixture
cpt -C "$text_root" config --integration-verify tests/integration-verify.zsh >/dev/null
text_change_set="$(cpt -C "$text_root" changeset create --title 'テキスト競合試験')"
first_task="$(cpt -C "$text_root" register --mode quick --text '競合ファイルをfirstへ変更する' --path conflict.txt --change-set "$text_change_set")"
second_task="$(cpt -C "$text_root" register --mode quick --text '競合ファイルをsecondへ変更する' --path conflict.txt --change-set "$text_change_set")"
cpt -C "$text_root" dispatch "$first_task" >/dev/null
text_db="$text_root/.counterpointer/state.sqlite3"
first_worktree="$(sqlite3 "$text_db" "SELECT worktree FROM tasks WHERE task_id='$first_task';")"
print 'first' > "$first_worktree/conflict.txt"
cpt -C "$text_root" selfcheck "$first_task" >/dev/null
cpt -C "$text_root" verify "$first_task"
cpt -C "$text_root" external-verify "$first_task" >/dev/null
cpt -C "$text_root" dispatch "$second_task" >/dev/null
second_worktree="$(sqlite3 "$text_db" "SELECT worktree FROM tasks WHERE task_id='$second_task';")"
print 'second' > "$second_worktree/conflict.txt"
cpt -C "$text_root" selfcheck "$second_task" >/dev/null
cpt -C "$text_root" verify "$second_task"
cpt -C "$text_root" external-verify "$second_task" >/dev/null
if cpt -C "$text_root" integrate "$text_change_set" >"$text_root/first-integration.out" 2>&1; then
  print -u2 'テキスト競合が統合成功として扱われました'
  exit 1
fi
text_job="$(sqlite3 "$text_db" "SELECT job_id FROM integration_jobs WHERE change_set_id='$text_change_set' ORDER BY created_at DESC,rowid DESC LIMIT 1;")"
[[ "$(sqlite3 "$text_db" "SELECT failure_reason FROM integration_jobs WHERE job_id='$text_job';")" == TEXT_CONFLICT ]]
text_fix="$(sqlite3 "$text_db" "SELECT m.task_id FROM change_set_tasks m WHERE m.change_set_id='$text_change_set' AND m.member_kind='integration_fix' ORDER BY m.created_at DESC LIMIT 1;")"
[[ "$(sqlite3 "$text_db" "SELECT superseded_task_id FROM task_supersessions WHERE replacement_task_id='$text_fix';")" == "$second_task" ]]
cpt -C "$text_root" dispatch "$text_fix" >/dev/null
[[ "$(sqlite3 "$text_db" "SELECT preparation_state FROM task_preparations WHERE task_id='$text_fix';")" == CONFLICT_READY ]]
text_fix_worktree="$(sqlite3 "$text_db" "SELECT worktree FROM tasks WHERE task_id='$text_fix';")"
[[ -n "$(git -C "$text_fix_worktree" diff --name-only --diff-filter=U)" ]]
print 'resolved' > "$text_fix_worktree/conflict.txt"
git -C "$text_fix_worktree" add conflict.txt
cpt -C "$text_root" selfcheck "$text_fix" >/dev/null
cpt -C "$text_root" verify "$text_fix"
cpt -C "$text_root" external-verify "$text_fix" >/dev/null
text_success_job="$(cpt -C "$text_root" integrate "$text_change_set" | tail -1)"
[[ "$(sqlite3 "$text_db" "SELECT state FROM integration_jobs WHERE job_id='$text_success_job';")" == VERIFIED ]]
[[ "$(git -C "$text_root/.counterpointer/integration/$text_success_job" show HEAD:conflict.txt)" == resolved ]]

print 'integration: passed'
