#!/bin/zsh
set -euo pipefail
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1 COUNTERPOINTER_RUNTIME_TEST=1

root="$(mktemp -d)"; remote="$(mktemp -d)"
trap '/bin/rm -rf "$root" "$remote"' EXIT INT TERM
git -C "$remote" init --bare -q
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
mkdir -p "$root/src"
print '# project' > "$root/README.md"
print 'v1' > "$root/src/app.txt"
git -C "$root" add .; git -C "$root" commit -qm base
git -C "$root" remote add origin "$remote"; git -C "$root" push -q -u origin main

cpt -C "$root" init >/dev/null
[[ "$(cpt -C "$root" status --json)" == '[]' ]]
proposal="$(cpt -C "$root" index onboarding --json | jq -r .proposal_id)"
jq -n --arg id "$proposal" '{schema_version:1,proposal_id:$id,summary:"初期索引",existing_ssot:[{path:"README.md",role:"概要",quality:"良好"}],areas:[{name:"ソース",root:"src",coverage:"partial",ssot_paths:[]}],gaps:[],inconsistencies:[],replacement_candidates:[],generated_drafts:[]}' > "$root/analysis.json"
cpt -C "$root" index submit-analysis "$proposal" "$root/analysis.json" >/dev/null
cpt -C "$root" index apply "$proposal" >/dev/null

task="$(cpt -C "$root" register --mode quick --text 'src/app.txt をv2へ更新する' --path src/app.txt)"
cpt -C "$root" dispatch "$task" >/dev/null
print 'v2' > "$root/.counterpointer/worktrees/$task/src/app.txt"
cpt -C "$root" selfcheck "$task" >/dev/null
cpt -C "$root" verify "$task" >/dev/null
view="$(cpt -C "$root" status --json)"
[[ "$(print -r -- "$view" | jq -r '.[0].display_state')" == EXTERNAL_VERIFY_PENDING ]]
[[ "$(print -r -- "$view" | jq -r '.[0].completed')" == false ]]
cpt -C "$root" external-verify "$task" >/dev/null
job="$(cpt -C "$root" integrate | tail -1)"
prepared="$(cpt -C "$root" publish "$job")"; request="$(print -r -- "$prepared" | sed -n 's/^公開要求ID: //p')"
[[ "$(cpt -C "$root" status --json | jq -r '.[0].display_state')" == PUBLISH_PENDING ]]
[[ "$(cpt -C "$root" status)" == *'PR準備待ち'* ]]
cpt -C "$root" publish approve "$request" >/dev/null
fake_gh="$(cd "$(dirname "$0")" && pwd)/fixtures/fake-gh.zsh"
CPT_FAKE_GH_STATE="$root/fake-gh.state" COUNTERPOINTER_GH_BIN="$fake_gh" cpt -C "$root" publish apply "$request" >/dev/null

db="$root/.counterpointer/state.sqlite3"
base_sha="$(git -C "$root" rev-parse HEAD)"
head_sha="$(sqlite3 "$db" "SELECT head_sha FROM publish_requests WHERE request_id='$request';")"
b="$(cpt -C "$root" register --mode quick --text 'src/b.txtへ後続の成果を追加する' --path src/b.txt --depends-on "$task")"
cpt -C "$root" queue "$b" >/dev/null
# The PR is merged into a stacked branch, while main still lacks the result.
git --git-dir="$remote" update-ref refs/heads/stack "$head_sha"
print -r -- "17|MERGED|https://example.invalid/pull/17|$head_sha|stack" > "$root/fake-gh.state"
export CPT_FAKE_GH_STATE="$root/fake-gh.state" COUNTERPOINTER_GH_BIN="$fake_gh" CPT_FAKE_GH_EXPECT_ROOT="$root"
# Parent-side reconciliation records the merge without fetching or updating HEAD.
cpt -C "$root" publish reconcile "$request" >/dev/null
[[ "$(git -C "$root" rev-parse HEAD)" == "$base_sha" ]]
[[ ! -f "$root/.git/FETCH_HEAD" ]]
[[ "$(cpt -C "$root" status --json | jq -r --arg id "$task" '.[]|select(.task_id==$id)|.target_branch')" == main ]]
# A worker fetch failure is recorded and retried, keeping B READY.
git -C "$root" remote set-url origin "$remote/unavailable"
cpt -C "$root" supervise --once > "$root/cycle.out" 2>&1
[[ "$(sqlite3 "$db" "SELECT value FROM metadata WHERE key='publish_sync_state:$request';")" == FETCH_FAILED ]]
[[ -s "$root/.counterpointer/publish/$request/sync/fetch.log" ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$b';")" == READY ]]
git -C "$root" remote set-url origin "$remote"
cpt -C "$root" supervise --once > "$root/cycle.out" 2>&1
[[ "$(sqlite3 "$db" "SELECT value FROM metadata WHERE key='publish_sync_state:$request';")" == TARGET_PENDING ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$b';")" == READY ]]
# A later merge brings A into main; dirty local files must not be overwritten.
git --git-dir="$remote" update-ref refs/heads/main "$head_sha"
print 'local unfinished edit' > "$root/src/app.txt"
cpt -C "$root" supervise --once > "$root/cycle.out" 2>&1
[[ "$(sqlite3 "$db" "SELECT value FROM metadata WHERE key='publish_sync_state:$request';")" == LOCAL_UNSAFE ]]
[[ "$(<"$root/src/app.txt")" == 'local unfinished edit' ]]
print 'v1' > "$root/src/app.txt"
# Preserve a divergent local commit rather than forcing main to the remote.
local_sha="$(print 'local branch commit' | git -C "$root" commit-tree "$base_sha^{tree}" -p "$base_sha")"
git -C "$root" update-ref refs/heads/main "$local_sha" "$base_sha"
cpt -C "$root" publish sync "$request" > "$root/cycle.out" 2>&1 || true
[[ "$(sqlite3 "$db" "SELECT value FROM metadata WHERE key='publish_sync_state:$request';")" == LOCAL_DIVERGED ]]
[[ "$(git -C "$root" rev-parse HEAD)" == "$local_sha" ]]
git -C "$root" update-ref refs/heads/main "$base_sha" "$local_sha"
# Old supervisors invoke reconcile directly. Preserve their process/permissions.
print $$ > "$root/.counterpointer/supervisor.pid"
cpt -C "$root" publish reconcile "$request" >/dev/null
[[ "$(git -C "$root" rev-parse HEAD)" == "$head_sha" ]]
# Retry a recorded merge even if the GitHub API is temporarily unavailable.
CPT_FAKE_GH_FAIL=1 cpt -C "$root" supervise --once > "$root/cycle.out" 2>&1
[[ "$(git -C "$root" rev-parse HEAD)" == "$head_sha" ]]
[[ "$(sqlite3 "$db" "SELECT value FROM metadata WHERE key='publish_sync_state:$request';")" == SYNCED ]]
[[ "$(sqlite3 "$db" 'SELECT source_sha FROM index_revisions ORDER BY revision DESC LIMIT 1;')" == "$head_sha" ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$b';")" == RUNNING ]]
[[ "$(sqlite3 "$db" "SELECT dispatch_base_sha FROM tasks WHERE task_id='$b';")" == "$head_sha" ]]
[[ "$(cpt -C "$root" status --json | jq -r --arg id "$task" '.[]|select(.task_id==$id)|.completed')" == true ]]
print 'worker merge sync: passed'
