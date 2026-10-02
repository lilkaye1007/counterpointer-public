#!/bin/zsh
set -euo pipefail
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
git -C "$fixture" init -q
git -C "$fixture" config user.name test
git -C "$fixture" config user.email test@example.com
mkdir -p "$fixture/docs/ssot" "$fixture/app/[[...pagePath]]"
print 'legal baseline' > "$fixture/docs/ssot/legal.md"
print 'route baseline' > "$fixture/app/[[...pagePath]]/page.test.ts"
git -C "$fixture" add .
git -C "$fixture" commit -qm fixture

a="$(cpt -C "$fixture" register --mode quick --text '法務文書を更新する' --path docs/ssot --path 'app/[[...pagePath]]/page.test.ts' --provides legal.v1)"
b="$(cpt -C "$fixture" register --mode quick --text '法務文書に同意記録を追加する' --path docs/ssot --depends-on "$a" --consumes legal.v1)"
db="$fixture/.counterpointer/state.sqlite3"
cs="$(sqlite3 "$db" "SELECT change_set_id FROM change_set_tasks WHERE task_id='$a';")"
cpt -C "$fixture" queue --all >/dev/null
cpt -C "$fixture" dispatch "$a" >/dev/null
aw="$fixture/.counterpointer/worktrees/$a"
print 'legal updated  ' > "$aw/docs/ssot/legal.md"
print 'route updated' > "$aw/app/[[...pagePath]]/page.test.ts"
cpt -C "$fixture" selfcheck "$a" >/dev/null
cpt -C "$fixture" verify "$a" >/dev/null
cpt -C "$fixture" external-verify "$a" >/dev/null

# Task単体の完了では別Change Setの利用側を解放しない。
if cpt -C "$fixture" dispatch "$b" >"$fixture/blocked.out" 2>&1; then
  print -u2 '未統合の成果に依存するBが開始されました'; exit 1
fi
[[ "$(<"$fixture/blocked.out")" == *'マージ待ち'* ]]
if cpt -C "$fixture" integrate "$cs" >"$fixture/integrate.out" 2>&1; then
  print -u2 '行末空白の統合が成功しました'; exit 1
fi
fix="$(sqlite3 "$db" "SELECT task_id FROM change_set_tasks WHERE change_set_id='$cs' AND member_kind='integration_fix';")"
[[ -n "$fix" ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM task_paths WHERE task_id='$fix' AND path='app/[[...pagePath]]/page.test.ts';")" == 1 ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM task_edges WHERE source_task_id='$b' AND target_task_id='$fix';")" == 0 ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM task_edges WHERE source_task_id='$fix' AND target_task_id='$b';")" -gt 0 ]]
cpt -C "$fixture" dispatch "$fix" >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$b';")" == READY ]]

# 不完全な修正後の同一失敗は停止し、監視周期で統合を増殖させない。
fw="$fixture/.counterpointer/worktrees/$fix"
print 'route revised' > "$fw/app/[[...pagePath]]/page.test.ts"
cpt -C "$fixture" selfcheck "$fix" >/dev/null
cpt -C "$fixture" verify "$fix" >/dev/null
cpt -C "$fixture" external-verify "$fix" >/dev/null
if cpt -C "$fixture" integrate "$cs" >"$fixture/repeat.out" 2>&1; then exit 1; fi
[[ "$(<"$fixture/repeat.out")" == *'同じ統合後verify失敗が再発'* ]]
[[ "$(sqlite3 "$db" "SELECT state FROM change_sets WHERE change_set_id='$cs';")" == FAILED ]]
job_count="$(sqlite3 "$db" 'SELECT COUNT(*) FROM integration_jobs;')"
cpt -C "$fixture" supervise --once >/dev/null
cpt -C "$fixture" supervise --once >/dev/null
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM integration_jobs;')" == "$job_count" ]]
[[ "$(cpt -C "$fixture" status)" == *'統合失敗 1件'* ]]

# 再修正もBを取り消さずに先行できる。
base="$(sqlite3 "$db" 'SELECT candidate_sha FROM integration_jobs ORDER BY rowid DESC LIMIT 1;')"
fix2="$(cpt -C "$fixture" register --mode quick --text '法務文書の行末空白を除去する' --path docs/ssot/legal.md --change-set "$cs" --kind integration_fix --base-sha "$base")"
cpt -C "$fixture" dispatch "$fix2" >/dev/null
print 'legal updated' > "$fixture/.counterpointer/worktrees/$fix2/docs/ssot/legal.md"
cpt -C "$fixture" selfcheck "$fix2" >/dev/null
cpt -C "$fixture" verify "$fix2" >/dev/null
cpt -C "$fixture" external-verify "$fix2" >/dev/null
job="$(cpt -C "$fixture" integrate "$cs" | tail -1)"
candidate="$(sqlite3 "$db" "SELECT candidate_sha FROM integration_jobs WHERE job_id='$job';")"
sqlite3 "$db" "UPDATE change_sets SET state='MERGED' WHERE change_set_id='$cs';"
if cpt -C "$fixture" dispatch "$b" >"$fixture/base-wait.out" 2>&1; then exit 1; fi
[[ "$(<"$fixture/base-wait.out")" == *'基準HEADへ反映待ち'* ]]
git -C "$fixture" merge --ff-only "$candidate" >/dev/null
cpt -C "$fixture" dispatch "$b" >/dev/null
[[ "$(<"$fixture/.counterpointer/worktrees/$b/docs/ssot/legal.md")" == 'legal updated' ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE task_id='$b';")" == 1 ]]

# 親ディレクトリ参照は引き続き拒否する。
for unsafe_path in ../escape docs/../escape docs/..; do
  if cpt -C "$fixture" register --mode quick --text '拒否試験を実施する' --path "$unsafe_path" >/dev/null 2>&1; then
    print -u2 "親ディレクトリ参照を受理しました: $unsafe_path"; exit 1
  fi
done
print 'integration-order: passed'
