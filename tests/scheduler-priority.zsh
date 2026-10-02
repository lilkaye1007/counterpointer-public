#!/bin/zsh
set -euo pipefail
PATH="${0:A:h:h}/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1 COUNTERPOINTER_RUNTIME_TEST=1
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git -C "$root" init -q
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print 'baseline' > "$root/shared.txt"
git -C "$root" add .
git -C "$root" commit -qm baseline
db="$root/.counterpointer/state.sqlite3"

# 同じ緊急度なら期限が先。単なるpath競合は別PRのマージ待ちにはしない。
a="$(cpt -C "$root" register --mode quick --text '共有文書Aを変更する' --path shared.txt --due-at 2026-09-15T00:00:00Z)"
b="$(cpt -C "$root" register --mode quick --text '共有文書Bを変更する' --path shared.txt --due-at 2026-09-12T00:00:00Z)"
cpt -C "$root" schedule priority "$b" normal >/dev/null
[[ "$(sqlite3 "$db" "SELECT due_at FROM task_schedule WHERE task_id='$b';")" == 2026-09-12T00:00:00Z ]]
if cpt -C "$root" schedule priority "$a" urgent >/dev/null 2>&1; then exit 1; fi
if cpt -C "$root" schedule priority "$a" normal 2026-02-30T00:00:00Z >/dev/null 2>&1; then exit 1; fi
cpt -C "$root" queue --all >/dev/null
cpt -C "$root" dispatch --automatic >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$b';")" == RUNNING ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$a';")" == READY ]]
print 'B implementation' > "$root/.counterpointer/worktrees/$b/shared.txt"
cpt -C "$root" selfcheck "$b" >/dev/null
cpt -C "$root" verify "$b" >/dev/null
cpt -C "$root" external-verify "$b" >/dev/null
cpt -C "$root" dispatch --automatic >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$a';")" == RUNNING ]]
cpt -C "$root" cancel "$a" >/dev/null

# 同緊急度・期限なしなら、後続を解放するTaskを登録順より優先する。
cs="$(cpt -C "$root" changeset create --title '後続解放の順位')"
older="$(cpt -C "$root" register --mode quick --text '先に登録した共有変更を実施する' --path shared.txt --change-set "$cs")"
provider="$(cpt -C "$root" register --mode quick --text '共通契約を準備する' --path shared.txt --change-set "$cs" --provides priority.contract)"
consumer="$(cpt -C "$root" register --mode quick --text '共通契約を利用する' --path client.txt --change-set "$cs" --consumes priority.contract)"
cpt -C "$root" queue --all >/dev/null
cpt -C "$root" dispatch --automatic >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$provider';")" == RUNNING ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$older';")" == READY ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$consumer';")" == READY ]]
cpt -C "$root" schedule pause >/dev/null
if cpt -C "$root" dispatch "$older" >/dev/null 2>&1; then exit 1; fi
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$provider';")" == RUNNING ]]
print 'scheduler-priority: passed'
