#!/bin/zsh
set -euo pipefail
setopt no_bg_nice
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1 COUNTERPOINTER_RUNTIME_TEST=1
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print base > "$root/README.md"
git -C "$root" add README.md
git -C "$root" commit -qm base
task="$(cpt -C "$root" register --mode quick --text '定型検証を実行する' --path check.mjs)"
cpt -C "$root" dispatch "$task" >/dev/null
cpt -C "$root" run "$task" >/dev/null
wt="$root/.counterpointer/worktrees/$task"
print 'console.log("permission test passed")' > "$wt/check.mjs"
jq -n '{operation:"Node検証",reason:"sandboxで実行できない定型検証",remaining_checks:["実行結果"],recipe:{mode:"once",argv:["node","check.mjs"]}}' > "$wt/request.json"
id="$(cpt -C "$root" permission request "$task" "$wt/request.json")"
[[ "$id" =~ '^[a-f0-9]{64}$' ]]
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" 'SELECT COUNT(*) FROM permission_requests;')" == 0 ]]
cpt -C "$root" runtime reconcile supervisor 0 >/dev/null
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" 'SELECT COUNT(*) FROM permission_requests;')" == 1 ]]
if cpt -C "$root" permission run "$id" >/dev/null 2>&1; then exit 1; fi
cpt -C "$root" permission approve "$id" --hash "$id" --scope project >/dev/null
(
  for attempt in {1..100}; do
    if [[ -n "$(print -r -- "$wt"/.counterpointer-task/permission-bridge/*.request.json(N))" ]]; then
      cpt -C "$root" runtime reconcile supervisor 0 >/dev/null
      exit $?
    fi
    sleep 0.1
  done
  exit 1
) &
worker=$!
cpt -C "$root" permission run "$id" > "$root/result.txt"
wait "$worker"
grep -Fxq 'permission test passed' "$root/result.txt"
# The owner-selected project scope reuses only identical argv and script bytes.
cpt -C "$root" config --max-parallel 2 >/dev/null
task2="$(cpt -C "$root" register --mode quick --text '同じ検証を別Taskでも実行する' --path second.mjs)"
cpt -C "$root" dispatch "$task2" >/dev/null
cpt -C "$root" run "$task2" >/dev/null
wt2="$root/.counterpointer/worktrees/$task2"
cp "$wt/check.mjs" "$wt2/check.mjs"
cp "$wt/request.json" "$wt2/request.json"
id2="$(cpt -C "$root" permission request "$task2" "$wt2/request.json")"
cpt -C "$root" runtime reconcile supervisor 0 >/dev/null
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT state FROM permission_requests WHERE request_id='$id2';")" == APPROVED ]]
cpt -C "$root" config --max-parallel 3 >/dev/null
task3="$(cpt -C "$root" register --mode quick --text '変更後の検証は再承認する' --path third.mjs)"
cpt -C "$root" dispatch "$task3" >/dev/null
cpt -C "$root" run "$task3" >/dev/null
wt3="$root/.counterpointer/worktrees/$task3"
print 'console.log("different script")' > "$wt3/check.mjs"
cp "$wt/request.json" "$wt3/request.json"
id3="$(cpt -C "$root" permission request "$task3" "$wt3/request.json")"
cpt -C "$root" runtime reconcile supervisor 0 >/dev/null
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT state FROM permission_requests WHERE request_id='$id3';")" == PENDING ]]
print 'console.log("changed")' > "$wt/check.mjs"
(
  for attempt in {1..100}; do
    if [[ "$(find "$wt/.counterpointer-task/permission-bridge" -name '*.request.json' | wc -l | tr -d ' ')" -gt 0 ]]; then
      cpt -C "$root" runtime reconcile supervisor 0 >/dev/null
      exit $?
    fi
    sleep 0.1
  done
  exit 1
) &
worker=$!
if cpt -C "$root" permission run "$id" > "$root/changed.txt" 2>&1; then exit 1; fi
wait "$worker"
grep -Fq '承認後に実行対象ファイルが変わりました' "$root/changed.txt"
print 'console.log("server ready"); setInterval(() => {}, 1000)' > "$wt/server.mjs"
jq -n '{operation:"Node検証サーバー",reason:"localhost listen検証",remaining_checks:["HTTP応答"],recipe:{mode:"server",argv:["node","server.mjs"]}}' > "$wt/server-request.json"
server_id="$(cpt -C "$root" permission request "$task" "$wt/server-request.json")"
cpt -C "$root" runtime reconcile supervisor 0 >/dev/null
cpt -C "$root" permission approve "$server_id" --hash "$server_id" >/dev/null
(
  for attempt in {1..100}; do
    if [[ "$(find "$wt/.counterpointer-task/permission-bridge" -name '*.request.json' | wc -l | tr -d ' ')" -gt 0 ]]; then
      cpt -C "$root" runtime reconcile supervisor 0 >/dev/null
      exit $?
    fi
    sleep 0.1
  done
  exit 1
) &
worker=$!
cpt -C "$root" permission run "$server_id" > "$root/server-result.txt"
wait "$worker"
server_pid="$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT process_pid FROM permission_runs WHERE request_id='$server_id' ORDER BY created_at DESC LIMIT 1;")"
[[ "$server_pid" == <-> ]] && kill -0 "$server_pid"
cpt -C "$root" permission stop "$task" >/dev/null
if kill -0 "$server_pid" 2>/dev/null; then exit 1; fi
print 'permission: passed'
