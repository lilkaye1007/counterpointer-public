#!/bin/zsh
set -euo pipefail
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1

root="$(mktemp -d)"; remote="$(mktemp -d)"
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
cpt -C "$root" publish enable --remote origin --confirm-url "$remote" >/dev/null

task="$(cpt -C "$root" register --mode quick --text 'README.md にE2E説明を追加する' --path README.md)"
cpt -C "$root" dispatch "$task" >/dev/null
print 'end to end' >> "$root/.counterpointer/worktrees/$task/README.md"
cpt -C "$root" selfcheck "$task" >/dev/null
CPT_FAKE_GH_STATE="$root/fake-gh.state" COUNTERPOINTER_GH_BIN="$(cd "$(dirname "$0")" && pwd)/fixtures/fake-gh.zsh" cpt -C "$root" supervise --once >/dev/null

db="$root/.counterpointer/state.sqlite3"
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$task';")" == VERIFIED ]]
[[ "$(sqlite3 "$db" 'SELECT state FROM integration_jobs ORDER BY rowid DESC LIMIT 1;')" == PR_READY ]]
[[ "$(sqlite3 "$db" 'SELECT state FROM change_sets ORDER BY rowid DESC LIMIT 1;')" == AWAITING_MERGE ]]
[[ "$(sqlite3 "$db" 'SELECT state FROM publish_requests ORDER BY rowid DESC LIMIT 1;')" == PUBLISHED ]]
[[ "$(sqlite3 "$db" 'SELECT pr_state FROM pull_requests ORDER BY rowid DESC LIMIT 1;')" == OPEN ]]
[[ -f "$root/fake-gh.state" ]]

print 'e2e: passed'
