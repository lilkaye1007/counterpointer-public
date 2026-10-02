#!/bin/zsh
set -euo pipefail
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1

root="$(mktemp -d)"
remote="$(mktemp -d)"
trap 'rm -rf "$root" "$remote"' EXIT
git -C "$remote" init --bare -q
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print 'base' > "$root/README.md"
git -C "$root" add README.md
git -C "$root" commit -qm base
git -C "$root" remote add origin "$remote"
git -C "$root" push -q -u origin main

task="$(cpt -C "$root" register --mode quick --text 'README.md に公開テストの説明を追加する' --path README.md)"
cpt -C "$root" dispatch "$task" >/dev/null
print 'published change' >> "$root/.counterpointer/worktrees/$task/README.md"
cpt -C "$root" selfcheck "$task" >/dev/null
cpt -C "$root" verify "$task" >/dev/null
cpt -C "$root" external-verify "$task" >/dev/null
job="$(cpt -C "$root" integrate | tail -1)"
prepare_output="$(cpt -C "$root" publish "$job")"
request="$(print -r -- "$prepare_output" | sed -n 's/^公開要求ID: //p')"
[[ -n "$request" ]]
body="$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT body_path FROM pull_requests WHERE request_id='$request';")"
[[ -s "$body" && "$(<"$body")" == *'含まれるタスク'* && "$(<"$body")" == *'統合後の全量検証: 成功'* ]]
[[ "$(cpt -C "$root" publish "$job" | sed -n 's/^公開要求ID: //p')" == "$request" ]]
if CPT_FAKE_GH_STATE="$root/fake-gh.state" COUNTERPOINTER_GH_BIN="$(cd "$(dirname "$0")" && pwd)/fixtures/fake-gh.zsh" cpt -C "$root" publish apply "$request" >/dev/null 2>&1; then
  print -u2 '未承認の公開が適用されました'
  exit 1
fi

db="$root/.counterpointer/state.sqlite3"
export COUNTERPOINTER_GH_BIN="${0:A:h}/fixtures/fake-gh.zsh" CPT_FAKE_GH_STATE="$root/fake-gh.state"
cpt -C "$root" supervise --once > "$root/cycle.log" 2>&1
[[ "$(sqlite3 "$db" "SELECT state FROM publish_requests WHERE request_id='$request';")" == PREPARED ]]
[[ ! -e "$CPT_FAKE_GH_STATE" ]]
# An approval for another SHA must not authorize this candidate.
sqlite3 "$db" "INSERT INTO publish_approvals VALUES ('$request','stale','owner','2026-01-01');"
cpt -C "$root" supervise --once > "$root/cycle.log" 2>&1
[[ ! -e "$CPT_FAKE_GH_STATE" ]]
cpt -C "$root" publish approve "$request" >/dev/null
# Already-running supervisors also execute a newly approved request.
print $$ > "$root/.counterpointer/supervisor.pid"
CPT_FAKE_GH_FAIL=1 cpt -C "$root" parent-runtime reconcile 0 > "$root/cycle.log" 2>&1
[[ "$(sqlite3 "$db" "SELECT state FROM publish_requests WHERE request_id='$request';")" == PREPARED ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE event_type='WORKER_PUBLISH_DEFERRED' AND entity_id='$request';")" == 1 ]]
[[ -s "$root/.counterpointer/publish/$request/worker.log" ]]
# Same approval is reused after the network recovers, without manual apply.
cpt -C "$root" supervise --once > "$root/cycle.log" 2>&1
[[ "$(sqlite3 "$db" "SELECT state FROM publish_requests WHERE request_id='$request';")" == PUBLISHED ]]
[[ "$(sqlite3 "$db" "SELECT pr_state FROM pull_requests WHERE request_id='$request';")" == OPEN ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE event_type='OWNER_APPROVED' AND entity_id='$request';")" == 1 ]]
branch="$(sqlite3 "$db" "SELECT branch_name FROM pull_requests WHERE request_id='$request';")"
head_sha="$(sqlite3 "$db" "SELECT head_sha FROM publish_requests WHERE request_id='$request';")"
[[ "$(git -C "$root" ls-remote --heads origin "refs/heads/$branch" | awk 'NR==1 {print $1}')" == "$head_sha" ]]
cpt -C "$root" supervise --once > "$root/cycle.log" 2>&1
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE event_type='PR_CREATE_INTENT' AND entity_id='$request';")" == 1 ]]
[[ "$(sqlite3 "$db" "SELECT COALESCE((SELECT value FROM metadata WHERE key='publish_mode'),'manual');")" == manual ]]
print 'approved worker publish: passed'
