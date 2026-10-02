#!/bin/zsh
set -euo pipefail
PATH="${0:A:h:h}/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1 COUNTERPOINTER_RUNTIME_TEST=1
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git -C "$root" init -q
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print 'baseline' > "$root/value.txt"
print '#!/bin/zsh
print "incompatible: $(<value.txt)"
exit 1' > "$root/verify.zsh"
git -C "$root" add .
git -C "$root" commit -qm baseline
cpt -C "$root" config --integration-verify verify.zsh >/dev/null
task="$(cpt -C "$root" register --mode quick --text '値の互換性を更新する' --path value.txt)"
db="$root/.counterpointer/state.sqlite3"
cs="$(sqlite3 "$db" "SELECT change_set_id FROM change_set_tasks WHERE task_id='$task';")"

# 原因が毎回異なっても、第三の自動修復は登録しない。
for attempt in 0 1 2; do
  cpt -C "$root" dispatch "$task" >/dev/null
  print "revision-$attempt" > "$root/.counterpointer/worktrees/$task/value.txt"
  cpt -C "$root" selfcheck "$task" >/dev/null
  cpt -C "$root" verify "$task" >/dev/null
  cpt -C "$root" external-verify "$task" >/dev/null
  if cpt -C "$root" integrate "$cs" >"$root/failure.out" 2>&1; then exit 1; fi
  if (( attempt < 2 )); then
    task="$(sqlite3 "$db" "SELECT task_id FROM change_set_tasks WHERE change_set_id='$cs' AND member_kind='integration_fix' ORDER BY rowid DESC LIMIT 1;")"
    [[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$task';")" == READY ]]
  fi
done
[[ "$(<"$root/failure.out")" == *REPAIR_LIMIT* ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM change_set_tasks WHERE change_set_id='$cs' AND member_kind='integration_fix';")" == 2 ]]
[[ "$(sqlite3 "$db" "SELECT state FROM change_sets WHERE change_set_id='$cs';")" == FAILED ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM parent_notices WHERE message LIKE '%REPAIR_LIMIT%';")" == 1 ]]

# 手動で範囲外の修正を追加した場合、それを自動修復許可の拡大に使わない。
scope_cs="$(cpt -C "$root" changeset create --title '範囲拡大の停止')"
original="$(cpt -C "$root" register --mode quick --text '既定値を調整する' --path value.txt --change-set "$scope_cs")"
outside="$(cpt -C "$root" register --mode quick --text '別ファイルを手動で追加する' --path outside.txt --change-set "$scope_cs" --kind integration_fix)"
for task in "$original" "$outside"; do
  cpt -C "$root" dispatch "$task" >/dev/null
  if [[ "$task" == "$original" ]]; then filename=value.txt; else filename=outside.txt; fi
  print "scope-$filename" > "$root/.counterpointer/worktrees/$task/$filename"
  cpt -C "$root" selfcheck "$task" >/dev/null
  cpt -C "$root" verify "$task" >/dev/null
  cpt -C "$root" external-verify "$task" >/dev/null
done
if cpt -C "$root" integrate "$scope_cs" >"$root/scope.out" 2>&1; then exit 1; fi
[[ "$(<"$root/scope.out")" == *SCOPE_EXPANSION* ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM change_set_tasks WHERE change_set_id='$scope_cs' AND member_kind='integration_fix';")" == 1 ]]
print 'repair-bounds: passed'
