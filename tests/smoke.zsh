#!/bin/zsh
set -euo pipefail
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH
export COUNTERPOINTER_TEST=1

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git -C "$root" init -q
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print 'fixture' > "$root/README.md"
git -C "$root" add README.md
git -C "$root" commit -qm fixture

for help_cmd in version init start context index register changeset graph dispatch run retry selfcheck verify external-verify integrate retry-integration publish notify notify-resolve backup restore recovery cancel logs status usage reset service doctor audit capacity cleanup config supervise test; do
  cpt -C "$root" "$help_cmd" --help >/dev/null
done
[[ "$(cpt -C "$root" service --help)" == *'--profile <profile>'* ]]
[[ "$(cpt -C "$root" register --help)" == *'--confirm-hash'* && "$(cpt -C "$root" register --help)" == *'--depends-on'* ]]
[[ "$(cpt -C "$root" publish --help)" == *'--confirm-url'* && "$(cpt -C "$root" publish --help)" == *'force push'* ]]
[[ "$(cpt -C "$root" notify --help)" == *'--token-stdin'* && "$(cpt -C "$root" notify --help)" == *'--dry-run'* ]]

task_count_before="$(sqlite3 "$root/.counterpointer/state.sqlite3" 'SELECT COUNT(*) FROM tasks;' 2>/dev/null || print 0)"
if cpt -C "$root" register --mode quick --text '予約機能を作りたい' --path src >/dev/null 2>"$root/ambiguity.out"; then
  print -u2 '曖昧なquick登録がTaskを作成しました'
  exit 1
fi
[[ "$(<"$root/ambiguity.out")" == *'壁打ちが必要'* ]]
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" 'SELECT COUNT(*) FROM tasks;')" == "$task_count_before" ]]
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT reason_code FROM registrations WHERE status='NEEDS_DECISION' ORDER BY created_at DESC LIMIT 1;")" == AMBIGUOUS_REQUIREMENT ]]

print '# 確認済み計画

README.mdにテスト用説明を追加し、内容を確認する。' > "$root/confirmed-plan.md"
plan_hash="$(openssl dgst -sha256 "$root/confirmed-plan.md" | awk '{print $NF}')"
if cpt -C "$root" register --mode detailed --plan "$root/confirmed-plan.md" >/dev/null 2>&1; then
  print -u2 '未確認のdetailed登録がTaskを作成しました'
  exit 1
fi
if cpt -C "$root" register --mode detailed --plan "$root/confirmed-plan.md" --confirm-hash deadbeef >/dev/null 2>&1; then
  print -u2 'hash不一致のdetailed登録がTaskを作成しました'
  exit 1
fi
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" 'SELECT COUNT(*) FROM tasks;')" == "$task_count_before" ]]
detailed_task="$(cpt -C "$root" register --mode detailed --plan "$root/confirmed-plan.md" --confirm-hash "$plan_hash" --path README.md)"
stored_plan="$root/.counterpointer/tasks/$detailed_task/execution-plan.md"
[[ "$(openssl dgst -sha256 "$stored_plan" | awk '{print $NF}')" == "$plan_hash" ]]
cpt -C "$root" cancel "$detailed_task"

tamper_task="$(cpt -C "$root" register --mode quick --text 'README.md に改変検知用の説明を追加する' --path README.md)"
print 'tampered' >> "$root/.counterpointer/tasks/$tamper_task/goal.md"
if cpt -C "$root" dispatch "$tamper_task" >/dev/null 2>&1; then
  print -u2 '登録正本を改変したTaskがdispatchされました'
  exit 1
fi
cpt -C "$root" cancel "$tamper_task"

task="$(cpt -C "$root" register --mode quick --text 'README.md に検証用の説明を追加する' --path README.md)"
[[ "$(cpt -C "$root" dispatch "$task" | tail -1)" == */".counterpointer/worktrees/$task" ]]
[[ -s "$root/.counterpointer/worktrees/$task/.counterpointer-task/execution-contract.md" ]]
print 'Counterpointer smoke追記' >> "$root/.counterpointer/worktrees/$task/README.md"
cpt -C "$root" selfcheck "$task" >/dev/null
[[ -s "$root/.counterpointer/worktrees/$task/.counterpointer-task/completion-report.md" ]]
[[ "$(cpt -C "$root" logs "$task")" == *CHILD_COMPLETED* ]]
cpt -C "$root" verify "$task"
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT COUNT(*) FROM task_index_deltas WHERE task_id='$task' AND path='README.md' AND change_state='PRESENT';")" == 1 ]]
cpt -C "$root" external-verify "$task" >/dev/null
job="$(cpt -C "$root" integrate | tail -1)"
[[ -n "$job" ]]
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT COUNT(*) FROM integration_index_snapshots WHERE job_id='$job' AND state='CANDIDATE';")" == 1 ]]
publish_output="$(cpt -C "$root" publish "$job")"
[[ "$publish_output" == *"確認モード"* ]]
publish_request="$(print -r -- "$publish_output" | sed -n 's/^公開要求ID: //p')"
if cpt -C "$root" publish apply "$publish_request" >"$root/publish-gate.out" 2>&1; then
  print -u2 'publish approval gate did not block apply'
  exit 1
fi
[[ "$(< "$root/publish-gate.out")" == *"オーナー承認がありません"* ]]
status_output="$(cpt -C "$root" status)"
[[ "$status_output" == *'タスク 3件  実行中 0  待機 0  失敗 0  検証済み 1  完了 0'* ]]
[[ "$status_output" == *'現在のタスク'* ]]
[[ "$status_output" == *'PR準備待ち'* ]]
[[ "$status_output" == *'詳細表示: cpt status --details'* ]]
[[ "$(NO_COLOR=1 CPT_COLOR=always cpt -C "$root" status)" != *$'\e['* ]]
[[ "$(env -u NO_COLOR CPT_COLOR=always cpt -C "$root" status)" == *$'\e[32m'* ]]
[[ "$(cpt -C "$root" status --json)" == *'"state":"VERIFIED"'* ]]
[[ "$(cpt -C "$root" logs "$task")" == *REGISTERED* ]]
cpt -C "$root" notify "$task" 'smoke notification' >/dev/null
[[ "$(cpt -C "$root" logs "$task")" == *NOTIFICATION* ]]
cpt -C "$root" service install >/dev/null
[[ "$(cpt -C "$root" service status)" == *CREDENTIALS_PENDING* ]]
cpt -C "$root" service configure-credentials --profile local >/dev/null
cpt -C "$root" service start >/dev/null
[[ "$(cpt -C "$root" service status)" == *RUNNING* ]]
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" 'SELECT state FROM parent_runtimes ORDER BY generation DESC LIMIT 1;')" == ACTIVE ]]
# test modeでは親Codexを起動しないためlauncherは生成対象外。
if rg -n 'script -q .*parent_events.*\\"\\\$\(' "$(cd "$(dirname "$0")/.." && pwd)/bin/cpt" >/dev/null; then
  print -u2 '親Codex launcherのprompt引用符が壊れています'
  exit 1
fi
cpt -C "$root" service stop >/dev/null
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" 'SELECT state FROM parent_runtimes ORDER BY generation DESC LIMIT 1;')" == STOPPED ]]
parent_launcher="$(COUNTERPOINTER_LAUNCHER_TEST=1 cpt -C "$root" service start)"
[[ "$parent_launcher" == "$root/.counterpointer/parent-launch.zsh" ]]
zsh -n "$parent_launcher"
grep -Fq '"$(/bin/cat ' "$parent_launcher"
if grep -Fq '\"$(/bin/cat ' "$parent_launcher"; then
  print -u2 '親Codex launcherのprompt引用符が壊れています'
  exit 1
fi
backup="$(cpt -C "$root" backup)"
cpt -C "$root" restore "$backup" >/dev/null
print 'smoke: passed'
