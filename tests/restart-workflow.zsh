#!/bin/zsh
set -euo pipefail
export COUNTERPOINTER_TEST=1 COUNTERPOINTER_RUNTIME_TEST=1
cli="${0:A:h:h}/bin/cpt"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
function cpt() { "$cli" -C "$root" "$@"; }
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print base > "$root/README.md"
git -C "$root" add .; git -C "$root" commit -qm base
cpt init --scan >/dev/null
mkdir -p "$root/.counterpointer/context"
print '{"id":"restart-test","status":"active","hero_task":"held","steps":{"restart_checked":"pending"}}' > "$root/.counterpointer/context/restart-state.json"
print 'resume order' > "$root/.counterpointer/context/restart-handoff.md"
print 'parent summary' > "$root/.counterpointer/context/parent-summary.md"
cpt context refresh >/dev/null
rg -q restart-state.json "$root/.counterpointer/context/project-context.md"
cpt context compact >/dev/null
rg -q restart-handoff.md "$root/.counterpointer/context/project-context.md"
[[ $(find "$root/.counterpointer/context/checkpoints" -name restart-state.json | wc -l | tr -d ' ') == 1 ]]
proposal="$(cpt index onboarding --json | jq -r .proposal_id)"
cpt index analysis-template "$proposal" > "$root/analysis.json"
python3 - "$root/analysis.json" <<'PY'
import json,sys
p=sys.argv[1];r=json.load(open(p));r.update(summary='test',existing_ssot=[],areas=[dict(name='root',root='.',coverage='partial',ssot_paths=[])],gaps=[],inconsistencies=[],generated_drafts=[],replacement_candidates=[]);json.dump(r,open(p,'w'))
PY
cpt index submit-analysis "$proposal" "$root/analysis.json" >/dev/null
cpt index apply "$proposal" >/dev/null
rg -q restart-state.json "$root/.counterpointer/context/project-core.md"
print 'PASS: restart references survive refresh/compact/index apply'
a="$(cpt register --mode quick --text 'README.mdへ説明を追加する' --path README.md)"
cpt dispatch "$a" >/dev/null
cpt run "$a" >/dev/null
db="$root/.counterpointer/state.sqlite3"
wt="$root/.counterpointer/worktrees/$a"
print '{"kind":"specification","operation":"choose-layout","reason":"clarify","remaining_checks":["browser"]}' > "$root/question.json"
q="$(cpt question "$a" "$root/question.json")"
[[ "$(cpt question "$a" "$root/question.json")" == "$q" ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM parent_notices WHERE notice_id='question:$q';")" == 1 ]]
cpt question status "$q" | jq '. + {decision:"clarify",answer:"Use the approved prototype"}' > "$root/answer.json"
jq '.generation=99' "$root/answer.json" > "$root/stale.json"
if cpt answer "$q" "$root/stale.json" >/dev/null 2>&1; then exit 1; fi
cpt answer "$q" "$root/answer.json" >/dev/null
cpt question wait "$q" | jq -e '.state=="answered" and .stale==false' >/dev/null
if cpt answer "$q" "$root/answer.json" >/dev/null 2>&1; then exit 1; fi
jq '.kind="permission"' "$root/question.json" > "$root/permission.json"
pq="$(cpt question "$a" "$root/permission.json")"
cpt question status "$pq" | jq '. + {decision:"proceed",answer:"grant all OS rights"}' > "$root/permit.json"
if cpt answer "$pq" "$root/permit.json" >/dev/null 2>&1; then exit 1; fi
jq '.decision="unavailable"' "$root/permit.json" > "$root/deny.json"
cpt answer "$pq" "$root/deny.json" >/dev/null
old_plan="$(sqlite3 "$db" "SELECT execution_plan_hash FROM task_artifacts WHERE task_id='$a';")"
sqlite3 "$db" "UPDATE task_artifacts SET execution_plan_hash='changed' WHERE task_id='$a';"
cpt question status "$q" | jq -e '.stale==true' >/dev/null
sqlite3 "$db" "UPDATE task_artifacts SET execution_plan_hash='$old_plan' WHERE task_id='$a';"
print 'PASS: deduplicated parent questions, scoped answers, stale plan, no OS grant' 
print changed > "$wt/README.md"
print 'child checks passed; final integration test remains' > "$wt/.counterpointer-task/completion-report.md"
cpt selfcheck "$a" --implementation-only >/dev/null
cpt verify "$a" >/dev/null
cpt external-verify "$a" >/dev/null
cs="$(sqlite3 "$db" "SELECT change_set_id FROM change_set_tasks WHERE task_id='$a';")"
job="$(cpt integrate "$cs" | tail -1)"
[[ "$(sqlite3 "$db" "SELECT state FROM integration_jobs WHERE job_id='$job';")" == VERIFYING ]]
if cpt publish "$job" >/dev/null 2>&1; then exit 1; fi
jw="$(sqlite3 "$db" "SELECT worktree FROM integration_jobs WHERE job_id='$job';")"
sha="$(git -C "$jw" rev-parse HEAD)"
mkdir -p "$jw/.counterpointer-task"
print 'test passed' > "$jw/.counterpointer-task/result.log"
python3 - "$root/evidence.json" "$job" "$sha" "$jw/.counterpointer-task/result.log" <<'PY'
import json,sys,hashlib,pathlib
out,job,sha,p=sys.argv[1:];json.dump(dict(job_id=job,candidate_sha=sha,status='passed',remaining_checks=[],checks=[dict(command='fixture acceptance',exit_code=0,artifacts=[dict(path=p,sha256=hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest())])]),open(out,'w'))
PY
jq '.candidate_sha="wrong"' "$root/evidence.json" > "$root/bad.json"
if cpt integration-verify "$job" "$root/bad.json" >/dev/null 2>&1; then exit 1; fi
jq '.checks[0].exit_code=1' "$root/evidence.json" > "$root/bad.json"
if cpt integration-verify "$job" "$root/bad.json" >/dev/null 2>&1; then exit 1; fi
cpt integration-verify "$job" "$root/evidence.json" >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM integration_jobs WHERE job_id='$job';")" == VERIFIED ]]
print 'PASS: integration candidate waits; wrong SHA/failure evidence rejected; accepted evidence completes'
git -C "$root" init -q --bare "$root/remote.git"
git -C "$root" remote add origin "$root/remote.git"
request="$(cpt publish "$job" | sed -n 's/^公開要求ID: //p')"
cpt publish approve "$request" >/dev/null
ed="$root/.counterpointer/integration-evidence/$job"
print tampered >> "$ed/acceptance.json"
rm "$ed/acceptance-required.json"
if cpt publish apply "$request" > "$root/publish-rejected.log" 2>&1; then exit 1; fi
grep -q '最終受入証拠' "$root/publish-rejected.log"
[[ -z "$(git -C "$root/remote.git" for-each-ref)" ]]
print 'PASS: tampered/removed acceptance evidence blocks publication before network'
held="$(cpt register --mode quick --text 'held.txtへ説明を追加する' --path held.txt)"
jq --arg hero "$held" '.hero_task=$hero' "$root/.counterpointer/context/restart-state.json" > "$root/restart.json"
cp "$root/restart.json" "$root/.counterpointer/context/restart-state.json"
cpt queue "$held" >/dev/null
if cpt dispatch "$held" > "$root/held.log" 2>&1; then exit 1; fi
grep -q '再起動引継ぎの親照合待ち' "$root/held.log"
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$held';")" == READY ]]
print 'PASS: restart handoff prevents hero launch even without schedule hold'

cpt service install >/dev/null
print 'installed_at=fixture\nstate=STOPPED' > "$root/.counterpointer/service.state"
COUNTERPOINTER_LAUNCHER_TEST=1 cpt service start >/dev/null
rg -q restart-state.json "$root/.counterpointer/orchestrator-prompt.md"
print 'PASS: startup prompt includes active restart handoff'
print 'restart-workflow: passed'
