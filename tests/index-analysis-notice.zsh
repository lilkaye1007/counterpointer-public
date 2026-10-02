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


db="$root/.counterpointer/state.sqlite3"
b="$(cpt -C "$root" register --mode quick --text 'src/b.txtを追加する' --path src/b.txt)"
cpt -C "$root" queue "$b" >/dev/null
print 'new requirements' >> "$root/README.md"
git -C "$root" add README.md; git -C "$root" commit -qm 'SSOT changed'
cpt -C "$root" index sync >/dev/null || true
proposal="$(sqlite3 "$db" "SELECT value FROM metadata WHERE key='index_onboarding_proposal';")"
notice="index-analysis:$proposal"
[[ "$(sqlite3 "$db" "SELECT state FROM parent_notices WHERE notice_id='$notice';")" == PENDING ]]
cpt -C "$root" index sync >/dev/null || true
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM parent_notices WHERE notice_id='$notice';")" == 1 ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE event_type='INDEX_ANALYSIS_REQUESTED';")" == 1 ]]
# Simulate an upgrade finding a pre-existing unnotified pending proposal.
sqlite3 "$db" "DELETE FROM parent_notices WHERE notice_id='$notice';"
cpt -C "$root" parent-runtime reconcile 0 >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM parent_notices WHERE notice_id='$notice';")" == PENDING ]]
# All delivery is confined to a fake transport in this temporary repository.
export COUNTERPOINTER_CMUX_BIN="$root/fake-cmux.zsh" CPT_NOTICE_LOG="$root/delivery.log"
cat > "$COUNTERPOINTER_CMUX_BIN" <<'MOCK'
#!/bin/zsh
print -r -- "$*" >> "$CPT_NOTICE_LOG"
[[ "${CPT_NOTICE_FAIL:-0}" != 1 ]]
MOCK
chmod 700 "$COUNTERPOINTER_CMUX_BIN"
sqlite3 "$db" "INSERT INTO parent_runtimes(generation,state,workspace_ref,pane_ref,process_pid,started_at,last_heartbeat_at,updated_at) VALUES (1,'ACTIVE','workspace:1','surface:1',$$,'2026-01-01','2026-01-01','2026-01-01');"
COUNTERPOINTER_TEST=0 CPT_NOTICE_FAIL=1 cpt -C "$root" index sync >/dev/null || true
[[ "$(sqlite3 "$db" "SELECT state FROM parent_notices WHERE notice_id='$notice';")" == PENDING ]]
COUNTERPOINTER_TEST=0 cpt -C "$root" index sync >/dev/null || true
[[ "$(sqlite3 "$db" "SELECT state FROM parent_notices WHERE notice_id='$notice';")" == DELIVERED ]]
[[ "$(sqlite3 "$db" "SELECT attempts FROM parent_notices WHERE notice_id='$notice';")" == 2 ]]
count="$(wc -l < "$CPT_NOTICE_LOG")"
COUNTERPOINTER_TEST=0 cpt -C "$root" index sync >/dev/null || true
[[ "$(wc -l < "$CPT_NOTICE_LOG")" == "$count" ]]
# A superseded proposal must not be sent; the current proposal gets its own notice.
print 'second requirements' >> "$root/README.md"
git -C "$root" add README.md; git -C "$root" commit -qm 'second SSOT change'
cpt -C "$root" index sync >/dev/null || true
second="$(sqlite3 "$db" "SELECT value FROM metadata WHERE key='index_onboarding_proposal';")"
print 'third requirements' >> "$root/README.md"
git -C "$root" add README.md; git -C "$root" commit -qm 'third SSOT change'
cpt -C "$root" index sync >/dev/null || true
third="$(sqlite3 "$db" "SELECT value FROM metadata WHERE key='index_onboarding_proposal';")"
# Analysis already submitted: do not tell the parent to analyze it again.
jq --arg id "$third" '.proposal_id=$id' "$root/analysis.json" > "$root/third-analysis.json"
cpt -C "$root" index submit-analysis "$third" "$root/third-analysis.json" >/dev/null
COUNTERPOINTER_TEST=0 cpt -C "$root" index sync >/dev/null || true
[[ "$(wc -l < "$CPT_NOTICE_LOG")" == "$count" ]]
[[ "$(sqlite3 "$db" "SELECT attempts FROM parent_notices WHERE notice_id='index-analysis:$second';")" == 0 ]]
[[ "$(sqlite3 "$db" "SELECT attempts FROM parent_notices WHERE notice_id='index-analysis:$third';")" == 0 ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$b';")" == READY ]]
print 'index analysis notice: passed'
