#!/bin/zsh
set -euo pipefail
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1

root="$(mktemp -d)"
remote="$(mktemp -d)"
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

task="$(cpt -C "$root" register --mode quick --text 'README.md に公開テストの説明を追加する' --path README.md)"
cpt -C "$root" dispatch "$task" >/dev/null
print 'published change' >> "$root/.counterpointer/worktrees/$task/README.md"
cpt -C "$root" selfcheck "$task" >/dev/null
cpt -C "$root" verify "$task" >/dev/null
cpt -C "$root" external-verify "$task" >/dev/null
job="$(cpt -C "$root" integrate | tail -1)"
prepare_output="$(cpt -C "$root" publish "$job")"
request="$(print -r -- "$prepare_output" | sed -n 's/^公開要求ID: //p')"
[[ -n "$request" ]]
body="$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT body_path FROM pull_requests WHERE request_id='$request';")"
[[ -s "$body" && "$(<"$body")" == *'含まれるタスク'* && "$(<"$body")" == *'統合後の全量検証: 成功'* ]]
[[ "$(cpt -C "$root" publish "$job" | sed -n 's/^公開要求ID: //p')" == "$request" ]]
if CPT_FAKE_GH_STATE="$root/fake-gh.state" COUNTERPOINTER_GH_BIN="$(cd "$(dirname "$0")" && pwd)/fixtures/fake-gh.zsh" cpt -C "$root" publish apply "$request" >/dev/null 2>&1; then
  print -u2 '未承認の公開が適用されました'
  exit 1
fi
cpt -C "$root" publish approve "$request" >/dev/null
CPT_FAKE_GH_STATE="$root/fake-gh.state" COUNTERPOINTER_GH_BIN="$(cd "$(dirname "$0")" && pwd)/fixtures/fake-gh.zsh" cpt -C "$root" publish apply "$request" >/dev/null
branch="$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT branch_name FROM pull_requests WHERE request_id='$request';")"
head_sha="$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT head_sha FROM publish_requests WHERE request_id='$request';")"
[[ "$(git -C "$root" ls-remote --heads origin "refs/heads/$branch" | awk '{print $1}')" == "$head_sha" ]]
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT state FROM publish_requests WHERE request_id='$request';")" == PUBLISHED ]]
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT state FROM change_sets WHERE change_set_id=(SELECT change_set_id FROM integration_jobs WHERE job_id='$job');")" == AWAITING_MERGE ]]
# squash mergeの成果も後続Taskの基準として確認できる。
git -C "$root" merge --squash "$head_sha" >/dev/null
git -C "$root" commit -qm 'squashed publication'
merge_sha="$(git -C "$root" rev-parse HEAD)"
git -C "$root" push -q origin main
print -r -- "17|MERGED|https://example.invalid/pull/17|$merge_sha" > "$root/fake-gh.state"
CPT_FAKE_GH_STATE="$root/fake-gh.state" COUNTERPOINTER_GH_BIN="$(cd "$(dirname "$0")" && pwd)/fixtures/fake-gh.zsh" cpt -C "$root" publish reconcile "$request" >/dev/null
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT state FROM change_sets WHERE change_set_id=(SELECT change_set_id FROM integration_jobs WHERE job_id='$job');")" == MERGED ]]

task2="$(cpt -C "$root" register --mode quick --text 'README.md にremote分岐検知の説明を追加する' --path README.md)"
cpt -C "$root" dispatch "$task2" >/dev/null
print 'divergence candidate' >> "$root/.counterpointer/worktrees/$task2/README.md"
cpt -C "$root" selfcheck "$task2" >/dev/null
cpt -C "$root" verify "$task2" >/dev/null
cpt -C "$root" external-verify "$task2" >/dev/null
job2="$(cpt -C "$root" integrate | tail -1)"
prepare2="$(cpt -C "$root" publish "$job2")"
request2="$(print -r -- "$prepare2" | sed -n 's/^公開要求ID: //p')"
branch2="$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT branch_name FROM pull_requests WHERE request_id='$request2';")"
git -C "$root" push -q origin "HEAD:refs/heads/$branch2"
cpt -C "$root" publish approve "$request2" >/dev/null
if CPT_FAKE_GH_STATE="$root/fake-gh-2.state" COUNTERPOINTER_GH_BIN="$(cd "$(dirname "$0")" && pwd)/fixtures/fake-gh.zsh" cpt -C "$root" publish apply "$request2" >"$root/diverged.out" 2>&1; then
  print -u2 'remote分岐を上書きしました'
  exit 1
fi
[[ "$(<"$root/diverged.out")" == *'remote branchがDB記録と一致しない'* ]]
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT failure_reason FROM publish_requests WHERE request_id='$request2';")" == REMOTE_DIVERGED ]]

print 'publish: passed'
