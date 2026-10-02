#!/bin/zsh
set -euo pipefail
setopt no_bg_nice
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1 COUNTERPOINTER_RUNTIME_TEST=1
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print base > "$root/README.md"
git -C "$root" add README.md
git -C "$root" commit -qm base
task="$(cpt -C "$root" register --mode quick --text 'README.mdに画面検証を記録する' --path README.md)"
cpt -C "$root" dispatch "$task" >/dev/null
cpt -C "$root" run "$task" >/dev/null
wt="$root/.counterpointer/worktrees/$task"
jq -n --arg task "$task" '{task_id:$task,surface:"surface:41",generation:"1"}' > "$wt/.counterpointer-task/child-surface.json"
print workspace:44 > "$root/.counterpointer/orchestrator.workspace"
export COUNTERPOINTER_CMUX_BIN="$root/cmux-mock.zsh" CPT_BROWSER_LOG="$root/browser.log" CPT_BROWSER_LOCATION="$root/location"
cat > "$COUNTERPOINTER_CMUX_BIN" <<'MOCK'
#!/bin/zsh
print -r -- "${CMUX_WORKSPACE_ID:-}|$*" >> "$CPT_BROWSER_LOG"
if [[ "${CPT_BROWSER_DENIED:-0}" == 1 ]]; then
  print -u2 'cmux socket access denied'
  exit 19
fi
if [[ "$1" == tree ]]; then
  if [[ -f "$CPT_BROWSER_LOCATION" && "$(<"$CPT_BROWSER_LOCATION")" == same ]]; then
    print '{"panes":[{"ref":"pane:1","surfaces":[{"ref":"surface:11"}]},{"ref":"pane:2","surfaces":[{"ref":"surface:41"},{"ref":"surface:81"}]}]}'
  else
    print '{"panes":[{"ref":"pane:1","surfaces":[{"ref":"surface:11"}]},{"ref":"pane:2","surfaces":[{"ref":"surface:41"}]},{"ref":"pane:3","surfaces":[{"ref":"surface:81"}]}]}'
  fi
elif [[ "$*" == '--json new-surface --type browser --pane pane:2 '* ]]; then
  print same > "$CPT_BROWSER_LOCATION"
  print '{"surface_ref":"surface:81","workspace_ref":"workspace:44"}'
elif [[ "$*" == 'move-surface --surface surface:81 --pane pane:2 --workspace workspace:44 --focus false' ]]; then
  print same > "$CPT_BROWSER_LOCATION"
  print OK
elif [[ "$*" == 'browser --surface surface:81 '* ]]; then
  print '{"ok":true}'
elif [[ "$*" == 'close-surface --workspace workspace:44 --surface surface:81' ]]; then
  if [[ "${CPT_BROWSER_CLOSE_DENIED:-0}" == 1 ]]; then print -u2 'close denied'; exit 19; fi
  print closed > "$CPT_BROWSER_LOCATION"
else
  print -u2 'unexpected browser target'
  exit 4
fi
MOCK
chmod 700 "$COUNTERPOINTER_CMUX_BIN"
# Creating uses only cmux, the project workspace and no focus change.
CMUX_WORKSPACE_ID=workspace:999 cpt -C "$root" browser "$task" open http://127.0.0.1:4319 >/dev/null
grep -Fxq 'workspace:44|--json new-surface --type browser --pane pane:2 --workspace workspace:44 --url http://127.0.0.1:4319 --focus false' "$CPT_BROWSER_LOG"
jq -e --arg task "$task" '.task_id==$task and .surface=="surface:81" and .engine=="cmux" and .layout=="child-tab" and .child_surface=="surface:41"' "$wt/.counterpointer-task/browser-surface.json" >/dev/null
# Re-open navigates the recorded surface; actions retain that same surface.
cpt -C "$root" browser "$task" open http://127.0.0.1:4319/edit >/dev/null
cpt -C "$root" browser "$task" viewport 390 844 >/dev/null
cpt -C "$root" browser "$task" snapshot --interactive >/dev/null
cpt -C "$root" browser "$task" screenshot --out "$wt/proof.png" >/dev/null
cpt -C "$root" browser "$task" eval '({width:innerWidth,height:innerHeight})' >/dev/null
[[ "$(grep -c 'new-surface' "$CPT_BROWSER_LOG")" == 1 ]]
grep -Fxq 'workspace:44|browser --surface surface:81 viewport 390 844' "$CPT_BROWSER_LOG"
grep -Fxq 'workspace:44|browser --surface surface:81 navigate http://127.0.0.1:4319/edit' "$CPT_BROWSER_LOG"
# Existing browser is moved into the child pane without recreating it.
jq 'del(.layout,.child_surface)' "$wt/.counterpointer-task/browser-surface.json" > "$root/legacy.json"
cp "$root/legacy.json" "$wt/.counterpointer-task/browser-surface.json"
print side > "$CPT_BROWSER_LOCATION"
cpt -C "$root" browser "$task" snapshot >/dev/null
grep -Fxq 'workspace:44|move-surface --surface surface:81 --pane pane:2 --workspace workspace:44 --focus false' "$CPT_BROWSER_LOG"
if grep -Fq 'split-off --surface surface:81' "$CPT_BROWSER_LOG"; then exit 1; fi
[[ "$(grep -c 'new-surface' "$CPT_BROWSER_LOG")" == 1 ]]
# The parent pane is never the creation/movement target.
if grep -q -- '--pane pane:1' "$CPT_BROWSER_LOG"; then exit 1; fi
# Failed access returns the error without opening another browser/surface.
calls_before="$(wc -l < "$CPT_BROWSER_LOG" | tr -d ' ')"
if CPT_BROWSER_DENIED=1 cpt -C "$root" browser "$task" snapshot > "$root/denied.log" 2>&1; then exit 1; fi
[[ "$(wc -l < "$CPT_BROWSER_LOG" | tr -d ' ')" == $((calls_before+1)) ]]
grep -Fq 'cmux socket access denied' "$root/denied.log"
# Reject accidental targeting overrides and unsupported external-launch verbs.
for bad_arg in --surface=surface:99 --workspace=workspace:99 --window=window:99; do
  if cpt -C "$root" browser "$task" snapshot "$bad_arg" >/dev/null 2>&1; then exit 1; fi
done
if cpt -C "$root" browser "$task" launch-chrome >/dev/null 2>&1; then exit 1; fi
# A new task can't borrow this surface and failed creation leaves no fake record.
cpt -C "$root" config --max-parallel 2 >/dev/null
task2="$(cpt -C "$root" register --mode quick --text '別の画面検証を記録する' --path second.txt)"
cpt -C "$root" dispatch "$task2" >/dev/null
if cpt -C "$root" browser "$task2" snapshot >/dev/null 2>&1; then exit 1; fi
if CPT_BROWSER_DENIED=1 cpt -C "$root" browser "$task2" open http://127.0.0.1:4319 >/dev/null 2>&1; then exit 1; fi
[[ ! -e "$root/.counterpointer/worktrees/$task2/.counterpointer-task/browser-surface.json" ]]
# A sandboxed caller can request a task-scoped browser action. The supervisor
# executes it without forwarding arbitrary shell commands.
(
  for attempt in {1..100}; do
    if [[ -n "$(print -r -- "$wt"/.counterpointer-task/browser-bridge/*.request.json(N))" ]]; then
      cpt -C "$root" runtime reconcile supervisor 0 >/dev/null
      exit $?
    fi
    sleep 0.1
  done
  exit 1
) &
bridge_worker=$!
CPT_BROWSER_BRIDGE=1 cpt -C "$root" browser "$task" snapshot --interactive > "$root/bridge-result.json"
wait "$bridge_worker"
grep -Fq '"ok":true' "$root/bridge-result.json"
grep -Fq 'workspace:44|browser --surface surface:81 snapshot --interactive' "$CPT_BROWSER_LOG"
[[ -z "$(print -r -- "$wt"/.counterpointer-task/browser-bridge/*.request.json(N))" ]]
if CPT_BROWSER_CLOSE_DENIED=1 cpt -C "$root" browser "$task" close >/dev/null 2>&1; then exit 1; fi
[[ -f "$wt/.counterpointer-task/browser-surface.json" ]]
cpt -C "$root" browser "$task" close >/dev/null
grep -Fxq 'workspace:44|close-surface --workspace workspace:44 --surface surface:81' "$CPT_BROWSER_LOG"
[[ ! -e "$wt/.counterpointer-task/browser-surface.json" ]]
cpt -C "$root" browser "$task" close >/dev/null
print 'browser: passed'
