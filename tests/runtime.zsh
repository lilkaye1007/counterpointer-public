#!/bin/zsh
set -euo pipefail
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1 COUNTERPOINTER_RUNTIME_TEST=1

runtime_root="$(mktemp -d)"
trap 'rm -rf "$runtime_root"' EXIT
git -C "$runtime_root" init -q
git -C "$runtime_root" config user.name test
git -C "$runtime_root" config user.email test@example.com
print 'runtime fixture' > "$runtime_root/README.md"
git -C "$runtime_root" add README.md
git -C "$runtime_root" commit -qm fixture

task="$(cpt -C "$runtime_root" register --mode quick --text 'README.mdへsession試験結果を追加する' --path README.md)"
cpt -C "$runtime_root" dispatch "$task" >/dev/null
cpt -C "$runtime_root" run "$task" >/dev/null
source "${0:A:h}/fixtures/codex-session.zsh"
record_codex_fixture "$runtime_root" "$runtime_root/.counterpointer/worktrees/$task"
db="$runtime_root/.counterpointer/state.sqlite3"
zsh -n "$runtime_root/.counterpointer/worktrees/$task/.counterpointer-task/launch-1.zsh"
grep -Fq 'PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin' "$runtime_root/.counterpointer/worktrees/$task/.counterpointer-task/launch-1.zsh"
grep -Fq '"$(/bin/cat ' "$runtime_root/.counterpointer/worktrees/$task/.counterpointer-task/launch-1.zsh"
if grep -Fq '\"$(/bin/cat ' "$runtime_root/.counterpointer/worktrees/$task/.counterpointer-task/launch-1.zsh"; then
  print -u2 '子Codex launcherのprompt引用符が壊れています'
  exit 1
fi
[[ "$(sqlite3 "$db" "SELECT state FROM task_runtimes WHERE task_id='$task' AND generation=1;")" == STARTING ]]
first_session="$(sqlite3 "$db" "SELECT logical_session_id FROM task_runtimes WHERE task_id='$task' AND generation=1;")"

cpt -C "$runtime_root" runtime started "$task" 1 $$
cpt -C "$runtime_root" runtime heartbeat "$task" 1
[[ "$(sqlite3 "$db" "SELECT state FROM task_runtimes WHERE task_id='$task' AND generation=1;")" == ACTIVE ]]
cpt -C "$runtime_root" runtime exited "$task" 1 7
# The recorded $$ belongs to this harness; model the exited child without killing the test.
sqlite3 "$db" "UPDATE task_runtimes SET process_pid=NULL WHERE task_id='$task' AND generation=1;"
cpt -C "$runtime_root" runtime reconcile test 0
[[ "$(sqlite3 "$db" "SELECT state FROM task_runtimes WHERE task_id='$task' AND generation=2;")" == RESUMING ]]
[[ "$(sqlite3 "$db" "SELECT logical_session_id FROM task_runtimes WHERE task_id='$task' AND generation=2;")" == "$first_session" ]]
[[ "$(sqlite3 "$db" "SELECT resume_attempts FROM task_runtimes WHERE task_id='$task' AND generation=2;")" == 1 ]]
grep -Fq "codex resume $CPT_FIXTURE_SESSION" "$runtime_root/.counterpointer/worktrees/$task/.counterpointer-task/launch-2.zsh"
zsh -n "$runtime_root/.counterpointer/worktrees/$task/.counterpointer-task/launch-2.zsh"
if cpt -C "$runtime_root" runtime started "$task" 1 $$ >/dev/null 2>&1; then
  print -u2 '古いgenerationの開始通知が受理されました'
  exit 1
fi

cpt -C "$runtime_root" runtime started "$task" 2 $$
cpt -C "$runtime_root" runtime exited "$task" 2 1
# The recorded $$ belongs to this harness; model the exited child without killing the test.
sqlite3 "$db" "UPDATE task_runtimes SET process_pid=NULL WHERE task_id='$task' AND generation=2;"
cpt -C "$runtime_root" runtime reconcile test 0
[[ "$(sqlite3 "$db" "SELECT state FROM task_runtimes WHERE task_id='$task' AND generation=3;")" == RESTARTING ]]
[[ "$(sqlite3 "$db" "SELECT logical_session_id FROM task_runtimes WHERE task_id='$task' AND generation=3;")" != "$first_session" ]]
[[ "$(sqlite3 "$db" "SELECT restart_attempts FROM task_runtimes WHERE task_id='$task' AND generation=3;")" == 1 ]]
if grep -Fq 'codex resume ' "$runtime_root/.counterpointer/worktrees/$task/.counterpointer-task/launch-3.zsh"; then
  print -u2 '新規session再実行がresumeコマンドを使用しています'
  exit 1
fi
zsh -n "$runtime_root/.counterpointer/worktrees/$task/.counterpointer-task/launch-3.zsh"

cpt -C "$runtime_root" runtime started "$task" 3 $$
cpt -C "$runtime_root" runtime exited "$task" 3 1
# The recorded $$ belongs to this harness; model the exited child without killing the test.
sqlite3 "$db" "UPDATE task_runtimes SET process_pid=NULL WHERE task_id='$task' AND generation=3;"
cpt -C "$runtime_root" runtime reconcile test 0
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$task';")" == FAILED ]]
[[ "$(sqlite3 "$db" "SELECT state FROM task_runtimes WHERE task_id='$task' AND generation=3;")" == FAILED ]]

cpt -C "$runtime_root" config --max-parallel 1 >/dev/null
blocking_task="$(cpt -C "$runtime_root" register --mode quick --text '再試行の並列上限試験を行う' --path blocking.txt)"
cpt -C "$runtime_root" dispatch "$blocking_task" >/dev/null
cpt -C "$runtime_root" retry "$task" --fresh >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$task';")" == READY ]]
[[ "$(sqlite3 "$db" "SELECT launch_mode || '|' || state FROM task_retry_requests WHERE task_id='$task';")" == 'RESTART|QUEUED' ]]
cpt -C "$runtime_root" supervise --once >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$task';")" == READY ]]
[[ -z "$(sqlite3 "$db" "SELECT state FROM task_runtimes WHERE task_id='$task' AND generation=4;")" ]]
cpt -C "$runtime_root" cancel "$blocking_task"
print 'state=RUNNING' > "$runtime_root/.counterpointer/service.state"
cpt -C "$runtime_root" supervise --once >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$task';")" == RUNNING ]]
[[ "$(sqlite3 "$db" "SELECT state FROM task_runtimes WHERE task_id='$task' AND generation=4;")" == RESTARTING ]]
[[ "$(sqlite3 "$db" "SELECT logical_session_id FROM task_runtimes WHERE task_id='$task' AND generation=4;")" != "$first_session" ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM task_retry_requests WHERE task_id='$task';")" == 0 ]]

# 子sandboxが親DBを書けない場合でも、worktree内の完了印を親が回収する。
print 'runtime completion marker' >> "$runtime_root/.counterpointer/worktrees/$task/README.md"
cat > "$runtime_root/.counterpointer/worktrees/$task/.counterpointer-task/selfcheck.txt" <<EOF
task_id=$task
generation=4
checked_at=2026-01-01T00:00:00Z
result=PASSED
EOF
cpt -C "$runtime_root" runtime reconcile supervisor 0 >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$task';")" == CLAIMED_DONE ]]
[[ "$(sqlite3 "$db" "SELECT state FROM task_runtimes WHERE task_id='$task' AND generation=4;")" == COMPLETED ]]
cpt -C "$runtime_root" verify "$task"
cpt -C "$runtime_root" external-verify "$task" >/dev/null

automatic_task="$(cpt -C "$runtime_root" register --mode quick --text '明示起動試験用ファイルを追加する' --path automatic.txt)"
cpt -C "$runtime_root" supervise --once >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$automatic_task';")" == REGISTERED ]]
cpt -C "$runtime_root" queue "${automatic_task[1,12]}" >/dev/null
cpt -C "$runtime_root" supervise --once >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$automatic_task';")" == RUNNING ]]
# PID-less STARTING is deliberately not stoppable; first prove a fixture exited.
if [[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM task_runtimes WHERE task_id='$automatic_task';")" == 0 ]]; then cpt -C "$runtime_root" run "$automatic_task" >/dev/null; fi
if cpt -C "$runtime_root" pause "${automatic_task[1,12]}" >/dev/null 2>&1; then exit 1; fi
/bin/sleep 0.01 &
fixture_exit_pid=$!
wait "$fixture_exit_pid"
sqlite3 "$db" "UPDATE task_runtimes SET state='ACTIVE',process_pid=$fixture_exit_pid WHERE task_id='$automatic_task';"
cpt -C "$runtime_root" pause "${automatic_task[1,12]}" >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$automatic_task';")" == REGISTERED ]]
[[ "$(sqlite3 "$db" "SELECT launch_mode || '|' || state FROM task_retry_requests WHERE task_id='$automatic_task';")" == 'RESUME|QUEUED' ]]
cpt -C "$runtime_root" supervise --once >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$automatic_task';")" == REGISTERED ]]
cpt -C "$runtime_root" queue "$automatic_task" >/dev/null
cpt -C "$runtime_root" supervise --once >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$automatic_task';")" == RUNNING ]]
cpt -C "$runtime_root" cancel "$automatic_task"

# 親は左側に固定し、最初の子を右、以降の子を右領域の下へ追加する。
export COUNTERPOINTER_RUNTIME_TEST=0
export COUNTERPOINTER_CMUX_BIN="$runtime_root/mock-cmux.zsh"
export COUNTERPOINTER_CMUX_LOG="$runtime_root/cmux.log"
cat > "$COUNTERPOINTER_CMUX_BIN" <<'MOCK'
#!/bin/zsh
print -r -- "$*" >> "$COUNTERPOINTER_CMUX_LOG"
case "$1" in
  tree)
    if [[ "${CPT_MOCK_COMPLETED_CHILD:-0}" == 1 ]]; then
      print -r -- '{"panes":[{"ref":"pane:21","surfaces":[{"ref":"surface:31"}]}]}'
    elif [[ "${CPT_MOCK_THREE_PANES:-0}" == 1 ]]; then
      print -r -- '{"panes":[{"ref":"pane:1","surfaces":[{"ref":"surface:11"}]},{"ref":"pane:21","surfaces":[{"ref":"surface:31"}]},{"ref":"pane:22","surfaces":[{"ref":"surface:32"}]}]}'
    elif [[ -f "${COUNTERPOINTER_CMUX_LOG}.split" ]]; then
      print -r -- '{"panes":[{"ref":"pane:1","surfaces":[{"id":"9D46458B-21E3-4A7F-A2B3-20844964DE75"}]},{"ref":"pane:21","surfaces":[{"ref":"surface:31"}]}]}'
    else
      print -r -- '{"panes":[{"ref":"pane:1","surfaces":[{"id":"9D46458B-21E3-4A7F-A2B3-20844964DE75"}]}]}'
    fi
    ;;
  --json)
    if [[ "$2" == list-panes ]]; then
      print '{"container_frame":{"width":1200},"panes":[{"ref":"pane:1","pixel_frame":{"width":600}}]}'
    else
      print '{"surface_ref":"surface:33"}'
    fi
    ;;
  new-split)
    if [[ "${COUNTERPOINTER_CMUX_FAIL_SPLIT:-0}" == 1 ]]; then
      print -u2 'mock: cmux connection denied'
      exit 17
    fi
    if [[ "$2" == right ]]; then
      print right > "${COUNTERPOINTER_CMUX_LOG}.split"
      print 'OK pane:21'
    else print 'OK surface:32'; fi
    ;;
  list-pane-surfaces)
    if [[ "$*" == *'pane:21'* ]]; then print 'surface:31'; else print 'surface:32'; fi
    ;;
  new-workspace) print 'OK workspace:77' ;;
  close-surface|send|send-key|log|notify|resize-pane)
    [[ "$1" != notify || "${CPT_MOCK_NOTIFY_FAIL:-0}" != 1 ]] || exit 17
    [[ "$1" != log || "${CPT_MOCK_LOG_FAIL:-0}" != 1 ]] || exit 18
    print -r -- "$*" >> "$COUNTERPOINTER_CMUX_LOG"
    print 'OK'
    ;;
  *) exit 2 ;;
esac
MOCK
chmod 700 "$COUNTERPOINTER_CMUX_BIN"
export COUNTERPOINTER_NOTICE_AGENT_BIN="$runtime_root/mock-notice-agent.zsh"
cat > "$COUNTERPOINTER_NOTICE_AGENT_BIN" <<'MOCK_AGENT'
#!/bin/zsh
notice_prompt="$(cat)"
print -r -- "$*" >> "$COUNTERPOINTER_CMUX_LOG"
while (( $# )); do
  if [[ "$1" == --output-last-message ]]; then
    if [[ "$notice_prompt" == *'notice-owner'* ]]; then
      print -r -- '{"status":"owner_required","summary":"公開の承認が必要です"}' > "$2"
    else
      print -r -- '{"status":"handled","summary":"自動処理済み"}' > "$2"
    fi
    break
  fi
  shift
done
MOCK_AGENT
chmod 700 "$COUNTERPOINTER_NOTICE_AGENT_BIN"
# 旧版が保存した不正な `workspace:<UUID>`／`surface:<UUID>` も読取時に修復する。
print -r -- 'workspace:44F9EAFD-4BF4-4D8B-98B7-797ABA408978' > "$runtime_root/.counterpointer/orchestrator.workspace"
print -r -- 'surface:9D46458B-21E3-4A7F-A2B3-20844964DE75' > "$runtime_root/.counterpointer/orchestrator.parent-surface"
/bin/rm -f "$runtime_root/.counterpointer/orchestrator.last-child-surface"

# 親不在中の通知は永続化し、親復旧後に再配送する。
sqlite3 "$db" "INSERT INTO parent_runtimes(generation,state,workspace_ref,pane_ref,process_pid,started_at,last_heartbeat_at,updated_at) VALUES (1,'ACTIVE','workspace:44F9EAFD-4BF4-4D8B-98B7-797ABA408978','surface:9D46458B-21E3-4A7F-A2B3-20844964DE75',$$,'2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');"
sqlite3 "$db" "INSERT INTO parent_notices(notice_id,message,state,attempts,created_at) VALUES ('notice-test','子タスク完了','PENDING',0,'2026-01-01T00:00:00Z');"
COUNTERPOINTER_TEST=0 COUNTERPOINTER_RUNTIME_TEST=1 cpt -C "$runtime_root" parent-runtime reconcile 0 >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM parent_notices WHERE notice_id='notice-test';")" == DELIVERED ]]
grep -Fq 'exec --ephemeral -c approval_policy="never" --sandbox workspace-write' "$COUNTERPOINTER_CMUX_LOG"
if grep -Fq 'send --workspace 44F9EAFD-4BF4-4D8B-98B7-797ABA408978 --surface 9D46458B-21E3-4A7F-A2B3-20844964DE75 子タスク完了' "$COUNTERPOINTER_CMUX_LOG"; then exit 1; fi
sqlite3 "$db" "INSERT INTO parent_notices(notice_id,message,state,attempts,created_at) VALUES ('notice-owner','公開判断を確認','PENDING',0,'2026-01-01T00:00:00Z');"
COUNTERPOINTER_TEST=0 COUNTERPOINTER_RUNTIME_TEST=1 cpt -C "$runtime_root" parent-runtime reconcile 0 >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM parent_notices WHERE notice_id='notice-owner';")" == DELIVERED ]]
grep -Fq 'notify --title CPT判断待ち --body 判断待ち notice-owner: 公開の承認が必要です --workspace 44F9EAFD-4BF4-4D8B-98B7-797ABA408978 --surface 9D46458B-21E3-4A7F-A2B3-20844964DE75 --json' "$COUNTERPOINTER_CMUX_LOG"
sqlite3 "$db" "INSERT INTO parent_notices(notice_id,message,state,attempts,created_at) VALUES ('permission:fixture','検証承認の確認','PENDING',0,'2026-01-01T00:00:01Z');"
COUNTERPOINTER_TEST=0 COUNTERPOINTER_RUNTIME_TEST=1 cpt -C "$runtime_root" parent-runtime reconcile 0 >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM parent_notices WHERE notice_id='permission:fixture';")" == DELIVERED ]]
grep -Fq 'notify --title CPT検証承認待ち --body 検証承認待ち fixture。cpt permission status fixture で内容を確認 --workspace 44F9EAFD-4BF4-4D8B-98B7-797ABA408978 --surface 9D46458B-21E3-4A7F-A2B3-20844964DE75 --json' "$COUNTERPOINTER_CMUX_LOG"
sidebar_test_id="$(cpt -C "$runtime_root" sidebar-test)"
[[ "$sidebar_test_id" == sidebar-test:* ]]
[[ "$(sqlite3 "$db" "SELECT state FROM parent_notices WHERE notice_id='$sidebar_test_id';")" == PENDING ]]
COUNTERPOINTER_TEST=0 COUNTERPOINTER_RUNTIME_TEST=1 cpt -C "$runtime_root" parent-runtime reconcile 0 >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM parent_notices WHERE notice_id='$sidebar_test_id';")" == DELIVERED ]]
grep -Fq 'notify --title CPT通知テスト --body CPTサイドバー通知テスト: 表示確認です。承認や操作は不要です。 --workspace 44F9EAFD-4BF4-4D8B-98B7-797ABA408978 --surface 9D46458B-21E3-4A7F-A2B3-20844964DE75 --json' "$COUNTERPOINTER_CMUX_LOG"
if grep -Fq 'send --workspace 44F9EAFD-4BF4-4D8B-98B7-797ABA408978 --surface 9D46458B-21E3-4A7F-A2B3-20844964DE75 検証承認の確認' "$COUNTERPOINTER_CMUX_LOG"; then exit 1; fi

# Delivery requires notify success; the optional log must not decide delivery.
# This is isolated to the temporary repository and mock cmux transport.
retry_notice="$(cpt -C "$runtime_root" sidebar-test)"
COUNTERPOINTER_TEST=0 COUNTERPOINTER_RUNTIME_TEST=1 CPT_MOCK_NOTIFY_FAIL=1 cpt -C "$runtime_root" parent-runtime reconcile 0 >/dev/null
[[ "$(sqlite3 "$db" "SELECT state || '|' || attempts || '|' || COALESCE(delivered_at,'') FROM parent_notices WHERE notice_id='$retry_notice';")" == 'PENDING|1|' ]]
COUNTERPOINTER_TEST=0 COUNTERPOINTER_RUNTIME_TEST=1 CPT_MOCK_LOG_FAIL=1 cpt -C "$runtime_root" parent-runtime reconcile 0 >/dev/null
[[ "$(sqlite3 "$db" "SELECT state || '|' || attempts FROM parent_notices WHERE notice_id='$retry_notice' AND delivered_at IS NOT NULL;")" == 'DELIVERED|2' ]]
COUNTERPOINTER_TEST=0 COUNTERPOINTER_RUNTIME_TEST=1 cpt -C "$runtime_root" parent-runtime reconcile 0 >/dev/null
[[ "$(sqlite3 "$db" "SELECT attempts FROM parent_notices WHERE notice_id='$retry_notice';")" == 2 ]]

layout_task_1="$(cpt -C "$runtime_root" register --mode quick --text '右側レイアウト試験1を追加する' --path layout-1.txt)"
cpt -C "$runtime_root" config --max-parallel 2 >/dev/null
cpt -C "$runtime_root" dispatch "$layout_task_1" >/dev/null
cpt -C "$runtime_root" run "$layout_task_1" >/dev/null
grep -Fq 'new-split right --workspace 44F9EAFD-4BF4-4D8B-98B7-797ABA408978 --surface 9D46458B-21E3-4A7F-A2B3-20844964DE75' "$COUNTERPOINTER_CMUX_LOG"
grep -Fq 'resize-pane --pane pane:1 --workspace 44F9EAFD-4BF4-4D8B-98B7-797ABA408978 -R --amount 200' "$COUNTERPOINTER_CMUX_LOG"
grep -Fq 'send --workspace 44F9EAFD-4BF4-4D8B-98B7-797ABA408978 --surface surface:31 exec /bin/zsh ' "$COUNTERPOINTER_CMUX_LOG"
grep -Fq 'send-key --workspace 44F9EAFD-4BF4-4D8B-98B7-797ABA408978 --surface surface:31 enter' "$COUNTERPOINTER_CMUX_LOG"

layout_task_2="$(cpt -C "$runtime_root" register --mode quick --text '右側レイアウト試験2を追加する' --path layout-2.txt)"
cpt -C "$runtime_root" dispatch "$layout_task_2" >/dev/null
cpt -C "$runtime_root" run "$layout_task_2" >/dev/null
grep -Fq 'new-split down --workspace 44F9EAFD-4BF4-4D8B-98B7-797ABA408978 --surface surface:31' "$COUNTERPOINTER_CMUX_LOG"
[[ "$(<"$runtime_root/.counterpointer/orchestrator.last-child-surface")" == surface:32 ]]

# 分割失敗の原因・終了コードを保存し、別workspaceで起動しない。
cpt -C "$runtime_root" config --max-parallel 3 >/dev/null
layout_failed="$(cpt -C "$runtime_root" register --mode quick --text '分割失敗の記録を確認する' --path layout-failed.txt)"
cpt -C "$runtime_root" dispatch "$layout_failed" >/dev/null
layout_exit=0
COUNTERPOINTER_CMUX_FAIL_SPLIT=1 cpt -C "$runtime_root" run "$layout_failed" >/dev/null 2>&1 || layout_exit=$?
[[ "$layout_exit" == 3 ]]
layout_error="$runtime_root/.counterpointer/tasks/$layout_failed/cmux-layout-generation-1.stderr"
grep -Fxq 'mock: cmux connection denied' "$layout_error"
[[ "$(stat -f '%Lp' "$layout_error")" == 600 ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$layout_failed';")" == FAILED ]]

# 右側に2行あるとき、3つ目の子は最後の子ペイン内のタブに置く。
layout_tab="$(cpt -C "$runtime_root" register --mode quick --text '追加の子をタブに置く' --path layout-tab.txt)"
cpt -C "$runtime_root" dispatch "$layout_tab" >/dev/null
print -r -- surface:32 > "$runtime_root/.counterpointer/orchestrator.last-child-surface"
CPT_MOCK_THREE_PANES=1 cpt -C "$runtime_root" run "$layout_tab" >/dev/null
grep -Fq -- '--json new-surface --type terminal --pane pane:22 --workspace 44F9EAFD-4BF4-4D8B-98B7-797ABA408978 --focus false' "$COUNTERPOINTER_CMUX_LOG"
[[ "$(<"$runtime_root/.counterpointer/orchestrator.last-child-surface")" == surface:33 ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE entity_id='$layout_failed' AND event_type='CHILD_LAYOUT_COMMAND_FAILED' AND detail='exit=17 stderr=$layout_error';")" == 1 ]]
if grep -q '^new-workspace' "$COUNTERPOINTER_CMUX_LOG"; then
  print -u2 '分割失敗後に別workspaceを作成しました'
  exit 1
fi

# 親の自動復旧はservice startごとに1回だけで、二つの監視処理が同時に
# reconcileしても新しい親を一つしか作らない。statusは一切状態を変えない。
print '#!/bin/zsh' > "$runtime_root/.counterpointer/parent-launch.zsh"
chmod 700 "$runtime_root/.counterpointer/parent-launch.zsh"
sqlite3 "$db" "UPDATE parent_runtimes SET state='STOPPED';
  INSERT INTO parent_runtimes(generation,state,started_at,last_heartbeat_at,updated_at)
    VALUES (2,'LOST','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
  INSERT INTO metadata(key,value) VALUES('parent_recovery_remaining','1')
    ON CONFLICT(key) DO UPDATE SET value='1';"
cpt -C "$runtime_root" parent-runtime reconcile 0 >/dev/null &
reconcile_pid_1=$!
cpt -C "$runtime_root" parent-runtime reconcile 0 >/dev/null &
reconcile_pid_2=$!
wait "$reconcile_pid_1"
wait "$reconcile_pid_2"
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM parent_runtimes WHERE generation=3;')" == 1 ]]
[[ "$(sqlite3 "$db" "SELECT value FROM metadata WHERE key='parent_recovery_remaining';")" == 0 ]]
sqlite3 "$db" "UPDATE parent_runtimes SET state='LOST',workspace_ref=NULL,process_pid=NULL WHERE generation=3;"
cpt -C "$runtime_root" parent-runtime reconcile 0 >/dev/null
cpt -C "$runtime_root" parent-runtime reconcile 0 >/dev/null
[[ "$(sqlite3 "$db" 'SELECT MAX(generation) FROM parent_runtimes;')" == 3 ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE event_type='PARENT_RECOVERY_EXHAUSTED' AND entity_id='3';")" == 1 ]]
parent_rows_before="$(sqlite3 "$db" 'SELECT COUNT(*) FROM parent_runtimes;')"
cmux_calls_before="$(wc -l < "$COUNTERPOINTER_CMUX_LOG" | tr -d ' ')"
cpt -C "$runtime_root" status >/dev/null
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM parent_runtimes;')" == "$parent_rows_before" ]]
[[ "$(wc -l < "$COUNTERPOINTER_CMUX_LOG" | tr -d ' ')" == "$cmux_calls_before" ]]

# Accepted child completion closes only its own terminal surface and removes
# the stale layout pointer. The task report and runtime history remain intact.
child_surface_record="$runtime_root/.counterpointer/worktrees/$task/.counterpointer-task/child-surface.json"
jq -n --arg task "$task" --arg generation 4 --arg surface surface:31 --arg workspace 44F9EAFD-4BF4-4D8B-98B7-797ABA408978 \
  '{task_id:$task,generation:$generation,surface:$surface,workspace:$workspace}' > "$child_surface_record"
print -r -- surface:31 > "$runtime_root/.counterpointer/orchestrator.last-child-surface"
CPT_MOCK_COMPLETED_CHILD=1 cpt -C "$runtime_root" runtime reconcile test 0 >/dev/null
grep -Fq 'close-surface --workspace 44F9EAFD-4BF4-4D8B-98B7-797ABA408978 --surface surface:31' "$COUNTERPOINTER_CMUX_LOG"
[[ ! -e "$child_surface_record" ]]
[[ ! -e "$runtime_root/.counterpointer/orchestrator.last-child-surface" ]]
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$task';")" == VERIFIED ]]
[[ -s "$runtime_root/.counterpointer/worktrees/$task/.counterpointer-task/completion-report.md" ]]

print 'runtime: passed'
