#!/bin/zsh
set -euo pipefail
PATH="${0:A:h:h}/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1 COUNTERPOINTER_RUNTIME_TEST=1
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print base > "$root/README.md"
git -C "$root" add README.md
git -C "$root" commit -qm base
task="$(cpt -C "$root" register --mode quick --text 'README.mdに記録する' --path README.md)"
cpt -C "$root" model "$task" luna '限定された記録編集' >/dev/null
cpt -C "$root" dispatch "$task" >/dev/null
cpt -C "$root" run "$task" >/dev/null
launcher="$root/.counterpointer/worktrees/$task/.counterpointer-task/launch-1.zsh"
grep -Fq -- 'codex --model gpt-6-luna --ask-for-approval never --sandbox workspace-write' "$launcher"
if grep -Fq 'require_escalated' "$root/.counterpointer/worktrees/$task/.counterpointer-task/runtime-policy.md"; then exit 1; fi
cpt -C "$root" model "$task" sol '受入条件の判断が必要' >/dev/null
if cpt -C "$root" model "$task" astra '再び上位へ' >/dev/null 2>&1; then exit 1; fi
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT COUNT(*) FROM events WHERE entity_id='$task' AND event_type='CHILD_MODEL_ESCALATED';")" == 1 ]]
print 'model-policy: passed'
