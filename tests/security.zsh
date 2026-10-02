#!/bin/zsh
set -euo pipefail
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1 COUNTERPOINTER_RUNTIME_TEST=1

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print 'base' > "$root/README.md"
git -C "$root" add README.md
git -C "$root" commit -qm base

task="$(cpt -C "$root" register --mode quick --text 'README.md に監査テストの説明を追加する' --path README.md)"
cpt -C "$root" dispatch "$task" >/dev/null
cpt -C "$root" run "$task" >/dev/null
launcher="$(find "$root/.counterpointer/worktrees/$task/.counterpointer-task" -name 'launch-*.zsh' -print -quit)"
[[ -s "$launcher" && "$(<"$launcher")" == *'unset AWS_ACCESS_KEY_ID'* && "$(<"$launcher")" == *'GH_TOKEN'* ]]
[[ "$(stat -f '%Lp' "$root/.counterpointer")" == 700 ]]
cpt -C "$root" audit verify >/dev/null
sqlite3 "$root/.counterpointer/state.sqlite3" 'UPDATE audit_events SET event_hash="tampered" WHERE sequence=(SELECT MAX(sequence) FROM audit_events);'
if cpt -C "$root" audit verify >/dev/null 2>&1; then
  print -u2 '監査改ざんを検知できませんでした'
  exit 1
fi

cpt -C "$root" service install >/dev/null
if cpt -C "$root" service configure-credentials --profile phase2-publish >/dev/null 2>&1; then
  print -u2 'GitHub認証・公開先未確認のpublish profileが有効になりました'
  exit 1
fi

print 'security: passed'
