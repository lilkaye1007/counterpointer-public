#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git -C "$root" init -q
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print 'concurrency fixture' > "$root/README.md"
git -C "$root" add README.md
git -C "$root" commit -qm fixture

pids=()
for number in {1..12}; do
  cpt -C "$root" status >"$root/status-$number.out" 2>"$root/status-$number.err" &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "$pid"
done

for error_file in "$root"/status-*.err; do
  [[ ! -s "$error_file" ]] || { print -u2 -- "並行初期化でエラーが発生しました: $(<"$error_file")"; exit 1; }
done
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT value FROM metadata WHERE key='schema_version';")" == 6 ]]
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" 'PRAGMA integrity_check;')" == ok ]]

# 複数の監視周期が競合しても、許可と並列上限を排他的に確認する。
for number in {1..4}; do
  cpt -C "$root" register --mode quick --text "並列割当${number}を検証する" --path "task-${number}.txt" >/dev/null
done
cpt -C "$root" queue --all >/dev/null
pids=()
for number in {1..3}; do
  cpt -C "$root" dispatch --automatic >"$root/dispatch-$number.out" 2>"$root/dispatch-$number.err" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid"; done
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT COUNT(*) FROM tasks WHERE state='RUNNING';")" == 2 ]]
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT COUNT(*) FROM tasks WHERE state='READY';")" == 2 ]]

print 'concurrency: passed'
