#!/bin/zsh
set -euo pipefail
PATH="${0:A:h:h}/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1 COUNTERPOINTER_RUNTIME_TEST=1 COUNTERPOINTER_SCHEDULER_REVIEW_TEST=1
root="$(mktemp -d)"
remote="$(mktemp -d)"
trap 'rm -rf "$root" "$remote"' EXIT
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print 'baseline' > "$root/README.md"
git -C "$root" add README.md
git -C "$root" commit -qm baseline
git -C "$remote" init --bare -q
git -C "$root" remote add origin "$remote"
git -C "$root" push -qu origin main
db="$root/.counterpointer/state.sqlite3"
assess_all() {
  local context_hash task
  context_hash="$(cpt -C "$root" schedule context | jq -r .context_hash)"
  while IFS= read -r task; do
    cpt -C "$root" schedule assess "$task" "$context_hash" '計画を比較。明示契約以外は独立したファイルを変更する' >/dev/null
  done < <(sqlite3 "$db" "SELECT task_id FROM tasks WHERE state IN ('REGISTERED','READY');")
}
finish() {
  local task="$1" filename="$2"
  print "implemented $filename" > "$root/.counterpointer/worktrees/$task/$filename"
  cpt -C "$root" selfcheck "$task" >/dev/null
}

# A/B/Cは別PRのDを必要とする。オーナーによるグループ指定は不要。
a="$(cpt -C "$root" register --mode quick --text 'Aの機能を追加する' --path a.txt --consumes foundation.v1)"
b="$(cpt -C "$root" register --mode quick --text 'Bの機能を追加する' --path b.txt --consumes foundation.v1)"
c="$(cpt -C "$root" register --mode quick --text 'Cの機能を追加する' --path c.txt --consumes foundation.v1)"
cpt -C "$root" queue --all >/dev/null
d="$(cpt -C "$root" register --mode quick --text 'Dの共通基盤を追加する' --path d.txt --provides foundation.v1 --urgency critical --due-at 2026-09-12T00:00:00Z)"
cpt -C "$root" supervise --once >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$d';")" == REGISTERED ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE state='RUNNING';")" == 0 ]]
cpt -C "$root" queue "$d" >/dev/null
# queueは実行許可だが、未分析のままでは開始しない。
cpt -C "$root" dispatch --automatic >/dev/null
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE state='RUNNING';")" == 0 ]]
if cpt -C "$root" schedule assess "$d" stale '古い分析' >/dev/null 2>&1; then exit 1; fi
assess_all
# 非重複pathでも新規Taskと意味的に関係し得る。比較前の旧分析では起動しない。
extra="$(cpt -C "$root" register --mode quick --text '補足資料を追加する' --path extra.txt)"
cpt -C "$root" dispatch --automatic >/dev/null
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE state='RUNNING';")" == 0 ]]
cpt -C "$root" cancel "$extra" >/dev/null
assess_all
cpt -C "$root" supervise --once >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$d';")" == RUNNING ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE state='READY';")" == 3 ]]
finish "$d" d.txt
cpt -C "$root" supervise --once >/dev/null
dset="$(sqlite3 "$db" "SELECT change_set_id FROM change_set_tasks WHERE task_id='$d';")"
[[ "$(sqlite3 "$db" "SELECT state FROM change_sets WHERE change_set_id='$dset';")" == VERIFIED ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE state='RUNNING';")" == 0 ]]

# 模擬PRのowner mergeを監視で検知し、手動公開modeでも後続を開始。
request="$(sqlite3 "$db" 'SELECT request_id FROM publish_requests ORDER BY rowid DESC LIMIT 1;')"
cpt -C "$root" publish approve "$request" >/dev/null
export CPT_FAKE_GH_STATE="$root/fake-gh.state" COUNTERPOINTER_GH_BIN="${0:A:h}/fixtures/fake-gh.zsh"
cpt -C "$root" publish apply "$request" >/dev/null
candidate="$(sqlite3 "$db" "SELECT head_sha FROM publish_requests WHERE request_id='$request';")"
git -C "$remote" update-ref refs/heads/main "$candidate"
print -r -- "17|MERGED|https://example.invalid/pull/17|$candidate" > "$CPT_FAKE_GH_STATE"
cpt -C "$root" supervise --once >/dev/null
[[ "$(git -C "$root" rev-parse HEAD)" == "$candidate" ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE state='RUNNING';")" == 2 ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$c';")" == READY ]]
[[ "$(<"$root/.counterpointer/worktrees/$a/d.txt")" == 'implemented d.txt' ]]
finish "$b" b.txt
cpt -C "$root" supervise --once >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$a';")" == RUNNING ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$c';")" == RUNNING ]]
cpt -C "$root" cancel "$a" >/dev/null
cpt -C "$root" cancel "$c" >/dev/null

# 同じくくり・同じpathでも、新規Dを待機中A/B/Cの前へ置ける。
unset COUNTERPOINTER_SCHEDULER_REVIEW_TEST
group="$(cpt -C "$root" changeset create --title '同一成果の優先順位試験')"
waiting=()
for label in A B C; do
  waiting+=("$(cpt -C "$root" register --mode quick --text "$label の共有文書を修正する" --path shared.txt --change-set "$group")")
done
cpt -C "$root" queue --all >/dev/null
urgent="$(cpt -C "$root" register --mode quick --text 'Dの共有文書を修正する' --path shared.txt --change-set "$group" --urgency critical)"
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$urgent';")" == REGISTERED ]]
cpt -C "$root" queue "$urgent" >/dev/null
cpt -C "$root" dispatch --automatic >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$urgent';")" == RUNNING ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM tasks WHERE task_id IN ('${waiting[1]}','${waiting[2]}','${waiting[3]}') AND state='READY';")" == 3 ]]
later="$(cpt -C "$root" register --mode quick --text '期限の早い追加変更を実施する' --path shared.txt --change-set "$group" --urgency critical --due-at 2026-09-11T00:00:00Z)"
cpt -C "$root" queue "$later" >/dev/null
cpt -C "$root" dispatch --automatic >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$urgent';")" == RUNNING ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$later';")" == READY ]]
for task in "$urgent" "$later" "${waiting[@]}"; do cpt -C "$root" cancel "$task" >/dev/null; done

# 不確かな関係は対象だけ保留し、独立Taskは進める。
x="$(cpt -C "$root" register --mode quick --text 'Xを追加する' --path x.txt)"
y="$(cpt -C "$root" register --mode quick --text 'Yを追加する' --path y.txt)"
z="$(cpt -C "$root" register --mode quick --text 'Zを追加する' --path z.txt)"
cpt -C "$root" schedule relation "$x" "$y" UNCERTAIN '仕様の境界が未確定' >/dev/null
cpt -C "$root" queue --all >/dev/null
cpt -C "$root" dispatch --automatic >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$x';")" == READY ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$y';")" == READY ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$z';")" == RUNNING ]]
cpt -C "$root" cancel "$z" >/dev/null
cpt -C "$root" schedule withdraw "$y" >/dev/null
cpt -C "$root" schedule forget "$x" "$y" '独立していることを仕様で確認' >/dev/null

# 期限変更では許可を維持。計画変更では許可を撤回し、確認だけでも再開しない。
cpt -C "$root" schedule priority "$x" high 2026-09-13T00:00:00Z >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$x';")" == READY ]]
print 'Xの受入条件を改訂する' > "$root/new-plan.md"
cpt -C "$root" schedule replan "$x" "$root/new-plan.md" >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$x';")" == REGISTERED ]]
if cpt -C "$root" queue "$x" >/dev/null 2>&1; then exit 1; fi
hash="$(openssl dgst -sha256 "$root/new-plan.md" | awk '{print $NF}')"
cpt -C "$root" schedule confirm "$x" "$hash" >/dev/null
cpt -C "$root" dispatch --automatic >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$x';")" == REGISTERED ]]
cpt -C "$root" schedule pause >/dev/null
cpt -C "$root" queue "$x" >/dev/null
cpt -C "$root" dispatch --automatic >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$x';")" == READY ]]
cpt -C "$root" schedule resume >/dev/null
cpt -C "$root" dispatch --automatic >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$x';")" == RUNNING ]]
print 'scheduling: passed'
