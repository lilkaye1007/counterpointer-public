#!/bin/zsh
set -euo pipefail
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1

root="$(mktemp -d)"
config_root="$(mktemp -d)"
trap 'rm -rf "$root" "$config_root"' EXIT
export COUNTERPOINTER_CONFIG_ROOT="$config_root" CPT_NOTIFICATION_TOKEN=test-secret
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print 'base' > "$root/README.md"
git -C "$root" add README.md
git -C "$root" commit -qm base

cpt -C "$root" notify configure --provider ntfy --server https://ntfy.example.invalid --topic counterpointer-test --token-stdin --enable >/dev/null
notification_status="$(cpt -C "$root" notify status)"
[[ "$notification_status" == *'token: 設定済み'* && "$notification_status" != *test-secret* ]]
emission_output="$(cpt -C "$root" notify sample '運用テスト通知')"
emission_id="${emission_output##*: }"
[[ "$(cpt -C "$root" notify deliver "$emission_id" --dry-run)" == *'通知dry-run'* ]]
COUNTERPOINTER_CURL_BIN="$(cd "$(dirname "$0")" && pwd)/fixtures/fake-curl.zsh" cpt -C "$root" notify deliver "$emission_id" --apply >/dev/null
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT state FROM notifications WHERE emission_id='$emission_id';")" == CONFIRMED ]]

failed_output="$(cpt -C "$root" notify sample '失敗通知')"; failed_id="${failed_output##*: }"
for attempt in 1 2 3 4 5; do
  CPT_FAKE_CURL_FAIL=1 COUNTERPOINTER_CURL_BIN="$(cd "$(dirname "$0")" && pwd)/fixtures/fake-curl.zsh" cpt -C "$root" notify deliver "$failed_id" --apply >/dev/null 2>&1 || true
done
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT state FROM notifications WHERE emission_id='$failed_id';")" == DEAD_LETTER ]]

backup="$(cpt -C "$root" backup)"
[[ -s "$backup" && "$(sqlite3 "$root/.counterpointer/state.sqlite3" 'SELECT COUNT(*) FROM backups WHERE state="VERIFIED";')" == 1 ]]
cpt -C "$root" recovery drill >/dev/null

task="$(cpt -C "$root" register --mode quick --text 'README.md に清掃テストを追加する' --path README.md)"
cpt -C "$root" dispatch "$task" >/dev/null
print 'cleanup' >> "$root/.counterpointer/worktrees/$task/README.md"
cpt -C "$root" selfcheck "$task" >/dev/null
cpt -C "$root" verify "$task" >/dev/null
cpt -C "$root" external-verify "$task" >/dev/null
change_set="$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT change_set_id FROM change_set_tasks WHERE task_id='$task';")"
sqlite3 "$root/.counterpointer/state.sqlite3" "UPDATE change_sets SET state='MERGED' WHERE change_set_id='$change_set';"
cpt -C "$root" cleanup --dry-run >/dev/null
[[ -d "$root/.counterpointer/worktrees/$task" ]]
cpt -C "$root" cleanup --apply >/dev/null
[[ ! -d "$root/.counterpointer/worktrees/$task" ]]

cpt -C "$root" config --capacity 999999998 999999999 >/dev/null
blocked="$(cpt -C "$root" register --mode quick --text 'README.md に容量停止テストを追加する' --path README.md)"
if cpt -C "$root" dispatch "$blocked" >"$root/capacity.out" 2>&1; then
  print -u2 '容量critical時にdispatchされました'
  exit 1
fi
[[ "$(<"$root/capacity.out")" == *'安全下限未満'* ]]

print 'operations: passed'
