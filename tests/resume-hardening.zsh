#!/bin/zsh
set -euo pipefail
export COUNTERPOINTER_TEST=1 COUNTERPOINTER_RUNTIME_TEST=1
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/harness"
# Only the test copy substitutes process observation; no real host process dies.
python3 - "${0:A:h:h}/bin/cpt" "$root/harness/cpt" "$root/harness/ps" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text().replace('/bin/ps',sys.argv[3])
Path(sys.argv[2]).write_text(s)
PY
cat > "$root/harness/ps" <<'PS'
#!/bin/zsh
case "${CPT_PS_SCENARIO:-denied}" in
 denied) print -u2 'Operation not permitted (fixture)'; exit 1;;
 live) print 42424;;
 gone) print 12345;;
esac
PS
chmod +x "$root/harness/cpt" "$root/harness/ps"
function cpt() { "$root/harness/cpt" "$@"; }
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print base > "$root/README.md"
git -C "$root" add README.md
git -C "$root" commit -qm base
task="$(cpt -C "$root" register --mode quick --text 'README.mdへ再開安全性検証を追加する' --path README.md)"
cpt -C "$root" dispatch "$task" >/dev/null
cpt -C "$root" run "$task" >/dev/null
wt="$root/.counterpointer/worktrees/$task"
db="$root/.counterpointer/state.sqlite3"
source "${0:A:h}/fixtures/codex-session.zsh"
record_codex_fixture "$root" "$wt"
# 1: All launch modes must reject an active generation before adding a pane.
for mode in --resume --restart; do
 if cpt -C "$root" run "$task" "$mode" >"$root/reject.log" 2>&1; then exit 1; fi
 [[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM task_runtimes;')" == 1 ]]
done
print 'PASS: active-generation launch denied'
# 2: Permission denial must preserve state, reservation and retry queue.
sqlite3 "$db" "UPDATE task_runtimes SET state='ACTIVE',process_pid=42424;"
export CPT_PS_SCENARIO=denied
if cpt -C "$root" pause "$task" >"$root/pause.log" 2>&1; then exit 1; fi
[[ "$(sqlite3 "$db" 'SELECT state FROM tasks;')" == RUNNING ]]
[[ "$(sqlite3 "$db" 'SELECT state FROM task_runtimes;')" == ACTIVE ]]
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM task_retry_requests;')" == 0 ]]
print 'PASS: denied stop leaves state unchanged'
# 3: Even a generation marked CANCELLED is not proof of process death.
sqlite3 "$db" "UPDATE task_runtimes SET state='CANCELLED';"
export CPT_PS_SCENARIO=live
if cpt -C "$root" run "$task" --resume >"$root/live.log" 2>&1; then exit 1; fi
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM task_runtimes;')" == 1 ]]
print 'PASS: cancelled but live process blocks resume'
# 4: Unknown process state blocks resume, not just explicit liveness.
export CPT_PS_SCENARIO=denied
if cpt -C "$root" run "$task" --resume >"$root/denied.log" 2>&1; then exit 1; fi
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM task_runtimes;')" == 1 ]]
print 'PASS: unknown process state blocks resume'
# 5: Proven gone permits one resume with current authorization and separate log.
export CPT_PS_SCENARIO=gone
cpt -C "$root" run "$task" --resume >/dev/null
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM task_runtimes;')" == 2 ]]
grep -Fq 'execution-authorization.md' "$wt/.counterpointer-task/launch-2.zsh"
grep -Fq 'events-2.log' "$wt/.counterpointer-task/launch-2.zsh"
grep -Fq 'events-1.log' "$wt/.counterpointer-task/launch-1.zsh"
grep -Fq 'generation=2 state=RUNNING' "$wt/.counterpointer-task/execution-authorization.md"
print 'PASS: authorized resume and per-generation logging'
# 6: Lock display is not projected as successful work progress.
print 'This conversation is open in another app' > "$wt/.counterpointer-task/events-2.log"
cpt -C "$root" status --json | jq -e --arg task "$task" '.[] | select(.task_id==$task) | .display_state=="NEEDS_ATTENTION" and (.waiting_reason|contains("会話ロック"))' >/dev/null
print 'PASS: conversation lock is reported as attention'
# 7: An already exited process can be paused without signaling another process.
sqlite3 "$db" "UPDATE task_runtimes SET state='ACTIVE',process_pid=42424 WHERE generation=2;"
cpt -C "$root" pause "$task" >/dev/null
[[ "$(sqlite3 "$db" 'SELECT state FROM tasks;')" == REGISTERED ]]
[[ "$(sqlite3 "$db" 'SELECT state FROM task_runtimes WHERE generation=2;')" == CANCELLED ]]
[[ "$(sqlite3 "$db" 'SELECT launch_mode FROM task_retry_requests;')" == RESUME ]]
print 'PASS: proven exited process permits pause'
print 'resume-hardening: passed (7 scenarios)' 
