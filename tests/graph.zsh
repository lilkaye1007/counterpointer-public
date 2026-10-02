#!/bin/zsh
set -euo pipefail
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1

graph_root="$(mktemp -d)"
trap 'rm -rf "$graph_root"' EXIT
git -C "$graph_root" init -q
git -C "$graph_root" config user.name test
git -C "$graph_root" config user.email test@example.com
mkdir -p "$graph_root/src/api" "$graph_root/docs"
print 'schema' > "$graph_root/src/api/schema.ts"
print 'client' > "$graph_root/src/api/client.ts"
print 'guide' > "$graph_root/docs/guide.md"
git -C "$graph_root" add .
git -C "$graph_root" commit -qm fixture

change_set="$(cpt -C "$graph_root" changeset create --title 'API契約更新')"
consumer="$(cpt -C "$graph_root" register --mode quick --text 'APIクライアントを新契約へ対応する' --path src/api/client.ts --change-set "$change_set" --consumes api.v1)"
provider="$(cpt -C "$graph_root" register --mode quick --text 'API契約v1を定義する' --path src/api --change-set "$change_set" --provides api.v1)"
independent="$(cpt -C "$graph_root" register --mode quick --text '利用ガイドへ説明を追加する' --path docs/guide.md)"

cpt -C "$graph_root" graph refresh >/dev/null
db="$graph_root/.counterpointer/state.sqlite3"
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM task_edges WHERE source_task_id='$provider' AND target_task_id='$consumer' AND edge_type='DEPENDENCY' AND reason='contract:api.v1';")" == 1 ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM task_edges WHERE source_task_id='$provider' AND target_task_id='$consumer' AND edge_type='CONFLICT' AND reason LIKE 'path:%';")" == 1 ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM task_edges WHERE source_task_id='$consumer' AND target_task_id='$provider';")" == 0 ]]
first_graph_hash="$(sqlite3 "$db" "SELECT graph_hash FROM execution_graph_snapshots ORDER BY created_at DESC,rowid DESC LIMIT 1;")"
cpt -C "$graph_root" graph refresh >/dev/null
second_graph_hash="$(sqlite3 "$db" "SELECT graph_hash FROM execution_graph_snapshots ORDER BY created_at DESC,rowid DESC LIMIT 1;")"
[[ "$first_graph_hash" == "$second_graph_hash" ]]

cpt -C "$graph_root" config --max-parallel 2
cpt -C "$graph_root" queue --all
cpt -C "$graph_root" dispatch --all
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$provider';")" == RUNNING ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$independent';")" == RUNNING ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$consumer';")" == READY ]]

provider_worktree="$(sqlite3 "$db" "SELECT worktree FROM tasks WHERE task_id='$provider';")"
print 'export const apiVersion = 1;' >> "$provider_worktree/src/api/schema.ts"
cpt -C "$graph_root" selfcheck "$provider" >/dev/null
cpt -C "$graph_root" verify "$provider"
cpt -C "$graph_root" external-verify "$provider" >/dev/null
cpt -C "$graph_root" dispatch --all
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$consumer';")" == RUNNING ]]

consumer_worktree="$(sqlite3 "$db" "SELECT worktree FROM tasks WHERE task_id='$consumer';")"
grep -Fq 'export const apiVersion = 1;' "$consumer_worktree/src/api/schema.ts"
print 'export const clientVersion = 1;' >> "$consumer_worktree/src/api/client.ts"
cpt -C "$graph_root" selfcheck "$consumer" >/dev/null
cpt -C "$graph_root" verify "$consumer"
cpt -C "$graph_root" external-verify "$consumer" >/dev/null
cpt -C "$graph_root" cancel "$independent"

job="$(cpt -C "$graph_root" integrate "$change_set" | tail -1)"
[[ "$(sqlite3 "$db" "SELECT change_set_id FROM integration_jobs WHERE job_id='$job';")" == "$change_set" ]]
[[ "$(sqlite3 "$db" "SELECT state FROM change_sets WHERE change_set_id='$change_set';")" == VERIFIED ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM change_set_tasks WHERE change_set_id='$change_set';")" == 2 ]]
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM change_sets;')" == 2 ]]

cycle_a="$(cpt -C "$graph_root" register --mode quick --text '循環検証用の契約Aを追加する' --path cycle/a --provides cycle.x --consumes cycle.y)"
task_count_before_cycle="$(sqlite3 "$db" 'SELECT COUNT(*) FROM tasks;')"
change_set_count_before_cycle="$(sqlite3 "$db" 'SELECT COUNT(*) FROM change_sets;')"
if cpt -C "$graph_root" register --mode quick --text '循環検証用の契約Bを追加する' --path cycle/b --provides cycle.y --consumes cycle.x >/dev/null 2>"$graph_root/cycle.out"; then
  print -u2 '循環依存を持つTaskが登録されました'
  exit 1
fi
[[ "$(<"$graph_root/cycle.out")" == *'壁打ちが必要'* ]]
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM tasks;')" == "$task_count_before_cycle" ]]
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM change_sets;')" == "$change_set_count_before_cycle" ]]
[[ "$(sqlite3 "$db" "SELECT reason_code FROM registrations WHERE status='NEEDS_DECISION' ORDER BY created_at DESC,rowid DESC LIMIT 1;")" == DEPENDENCY_CYCLE_OR_GRAPH_INVALID ]]
cpt -C "$graph_root" cancel "$cycle_a"

missing="$(cpt -C "$graph_root" register --mode quick --text '未提供契約の利用を検証する' --path missing --consumes missing.contract)"
if cpt -C "$graph_root" dispatch "$missing" >/dev/null 2>&1; then exit 1; fi
cpt -C "$graph_root" cancel "$missing"
late_consumer="$(cpt -C "$graph_root" register --mode quick --text '後発依存検証用の利用側を追加する' --path late/consumer)"
cpt -C "$graph_root" dispatch "$late_consumer" >/dev/null
late_provider="$(cpt -C "$graph_root" register --mode quick --text '後発依存検証用の提供側を追加する' --path late/provider)"
cpt -C "$graph_root" schedule relation "$late_provider" "$late_consumer" DEPENDENCY '後発の依存が判明' >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$late_consumer';")" == RUNNING ]]
[[ -n "$(sqlite3 "$db" "SELECT hold_reason FROM task_schedule WHERE task_id='$late_provider';")" ]]
if cpt -C "$graph_root" dispatch "$late_provider" >/dev/null 2>&1; then exit 1; fi
cpt -C "$graph_root" cancel "$late_consumer"
cpt -C "$graph_root" cancel "$late_provider"

# 依存元がFAILEDになっても依存edgeは消えず、利用側は開始できない。
failed_provider="$(cpt -C "$graph_root" register --mode quick --text '失敗提供元を検証する' --path failed/provider --provides failed.contract)"
failed_consumer="$(cpt -C "$graph_root" register --mode quick --text '失敗提供元の利用側を検証する' --path failed/consumer --consumes failed.contract)"
cpt -C "$graph_root" dispatch "$failed_provider" >/dev/null
sqlite3 "$db" "UPDATE tasks SET state='FAILED' WHERE task_id='$failed_provider';"
if cpt -C "$graph_root" dispatch "$failed_consumer" >/dev/null 2>&1; then exit 1; fi
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM task_edges WHERE source_task_id='$failed_provider' AND target_task_id='$failed_consumer' AND edge_type='DEPENDENCY';")" -gt 0 ]]

print 'graph: passed'
