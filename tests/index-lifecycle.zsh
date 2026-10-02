#!/bin/zsh
set -euo pipefail
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1

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
[[ "$(cpt -C "$root" status --json | jq -r '.[0].display_state')" == AWAITING_MERGE ]]
head_sha="$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT head_sha FROM publish_requests WHERE request_id='$request';")"
git --git-dir="$remote" update-ref refs/heads/main "$head_sha"
print -r -- '17|MERGED|https://example.invalid/pull/17' > "$root/fake-gh.state"
# A retargeted PR must use GitHub's current base, not the original stacked base.
db="$root/.counterpointer/state.sqlite3"
sqlite3 "$db" "UPDATE pull_requests SET base_branch='old-stacked-base' WHERE request_id='$request';"
# A dirty local checkout is a recoverable incorporation wait, not completion.
print 'local unfinished edit' > "$root/src/app.txt"
CPT_FAKE_GH_STATE="$root/fake-gh.state" COUNTERPOINTER_GH_BIN="$fake_gh" cpt -C "$root" publish reconcile "$request" >/dev/null
cpt -C "$root" publish sync "$request" >/dev/null || true
[[ "$(sqlite3 "$db" "SELECT base_branch FROM pull_requests WHERE request_id='$request';")" == main ]]
[[ "$(cpt -C "$root" status --json | jq -r '.[0].display_state')" == INCORPORATION_PENDING ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE event_type='MERGED_INDEX_REFRESHED';")" == 0 ]]
print 'v1' > "$root/src/app.txt"
CPT_FAKE_GH_STATE="$root/fake-gh.state" COUNTERPOINTER_GH_BIN="$fake_gh" cpt -C "$root" publish reconcile "$request" >/dev/null
cpt -C "$root" publish sync "$request" >/dev/null || true

db="$root/.counterpointer/state.sqlite3"
[[ "$(git -C "$root" rev-parse HEAD)" == "$head_sha" ]]
[[ "$(sqlite3 "$db" 'SELECT MAX(revision) FROM index_revisions;')" == 2 ]]
[[ "$(sqlite3 "$db" 'SELECT source_sha FROM index_revisions ORDER BY revision DESC LIMIT 1;')" == "$head_sha" ]]
[[ "$(sqlite3 "$db" "SELECT state FROM integration_index_snapshots WHERE job_id='$job';")" == PROMOTED ]]

[[ "$(cpt -C "$root" status --json | jq -r '.[0].completed')" == true ]]
[[ "$(cpt -C "$root" status)" == *'完了 1'* ]]
# A stale verification record must not complete the current task commit.
task_sha="$(sqlite3 "$db" "SELECT commit_sha FROM tasks WHERE task_id='$task';")"
sqlite3 "$db" "UPDATE verify_results SET commit_sha='stale' WHERE task_id='$task';"
[[ "$(cpt -C "$root" status --json | jq -r '.[0].display_state')" == EXTERNAL_VERIFY_PENDING ]]
sqlite3 "$db" "UPDATE verify_results SET commit_sha='$task_sha' WHERE task_id='$task';"

# Repeated reconciliation is idempotent; reading status does not write events.
event_count="$(sqlite3 "$db" 'SELECT COUNT(*) FROM events;')"
cpt -C "$root" status --json >/dev/null
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM events;')" == "$event_count" ]]
CPT_FAKE_GH_STATE="$root/fake-gh.state" COUNTERPOINTER_GH_BIN="$fake_gh" cpt -C "$root" publish reconcile "$request" >/dev/null
cpt -C "$root" publish sync "$request" >/dev/null || true
[[ "$(sqlite3 "$db" "SELECT value FROM metadata WHERE key='index_refresh_required';")" == 0 ]]
# A later SSOT change requires analysis. Do not record a successful refresh.
print 'changed project requirements' >> "$root/README.md"
git -C "$root" add README.md; git -C "$root" commit -qm 'update SSOT'
git -C "$root" push -q origin main
refresh_count="$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE event_type='MERGED_INDEX_REFRESHED';")"
cpt -C "$root" publish sync "$request" > "$root/pending.out" || true
[[ "$(sqlite3 "$db" "SELECT value FROM metadata WHERE key='publish_sync_state:$request';")" == INDEX_PENDING ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE event_type='MERGED_INDEX_REFRESHED';")" == "$refresh_count" ]]
[[ "$(cpt -C "$root" status --json | jq -r '.[0].display_state')" == INDEX_PENDING ]]
[[ "$(cpt -C "$root" status --json | jq -r '.[0].completed')" == false ]]
proposal_count="$(sqlite3 "$db" 'SELECT COUNT(*) FROM index_proposals;')"
cpt -C "$root" publish sync "$request" >/dev/null || true
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM index_proposals;')" == "$proposal_count" ]]
print 'index lifecycle: passed'
