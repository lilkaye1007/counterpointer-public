#!/bin/zsh
set -euo pipefail
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print base > "$root/README.md"
git -C "$root" add .
git -C "$root" commit -qm base
cs="$(cpt -C "$root" changeset create --title $'# 055_A 法務\r\n\n## ExampleApp\n複数行の計画')"
task="$(cpt -C "$root" register --mode quick --text 'README.mdへ公開試験を追加する' --path README.md --change-set "$cs")"
cpt -C "$root" dispatch "$task" >/dev/null
print implemented >> "$root/.counterpointer/worktrees/$task/README.md"
cpt -C "$root" selfcheck "$task" >/dev/null
cpt -C "$root" verify "$task" >/dev/null
cpt -C "$root" external-verify "$task" >/dev/null
job="$(cpt -C "$root" integrate | tail -1)"
cpt -C "$root" publish "$job" >/dev/null
db="$root/.counterpointer/state.sqlite3"
request="$(sqlite3 "$db" 'SELECT request_id FROM publish_requests;')"
branch="$(sqlite3 "$db" 'SELECT branch_name FROM pull_requests;')"
[[ "$branch" == "counterpointer/change/$cs-055-a-exampleapp" ]]
git check-ref-format --branch "$branch" >/dev/null
cpt -C "$root" publish approve "$request" >/dev/null
head_sha="$(sqlite3 "$db" 'SELECT head_sha FROM publish_requests;')"
# Reproduce an old malformed request, preserving its identity and fixed SHA.
sqlite3 "$db" "UPDATE pull_requests SET branch_name=branch_name || char(10) || 'exampleapp';"
cp "$root/.counterpointer/publish/$request/manifest.txt" "$root/manifest.before"
if cpt -C "$root" publish apply "$request" >"$root/apply.log" 2>&1; then exit 1; fi
grep -q '公開branchが不正' "$root/apply.log"
cpt -C "$root" publish repair-branch "$request" >/dev/null
[[ "$(sqlite3 "$db" 'SELECT instr(branch_name,char(10))>0 FROM pull_requests;')" == 1 ]]
sqlite3 "$db" "UPDATE pull_requests SET last_pushed_sha='$head_sha';"
if cpt -C "$root" publish repair-branch "$request" --apply >/dev/null 2>&1; then exit 1; fi
sqlite3 "$db" "UPDATE pull_requests SET last_pushed_sha=NULL;"
cpt -C "$root" publish repair-branch "$request" --apply >/dev/null
[[ "$(sqlite3 "$db" 'SELECT branch_name FROM pull_requests;')" == "$branch" ]]
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM publish_approvals;')" == 0 ]]
[[ "$(sqlite3 "$db" 'SELECT state || char(124) || head_sha FROM publish_requests;')" == "PREPARED|$head_sha" ]]
[[ "$(grep -c '^branch=' "$root/.counterpointer/publish/$request/manifest.txt")" == 1 ]]
[[ -s "$root/.counterpointer/diagnostics/publish-branch/$request/before.sqlite3" ]]
cpt -C "$root" publish repair-branch "$request" --apply >/dev/null
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE event_type='BRANCH_REPAIRED';")" == 1 ]]
# The PR title also comes from a multiline plan; publish only its first heading.
git init --bare -q "$root/remote.git"
git -C "$root" remote add origin "$root/remote.git"
export CPT_FAKE_GH_STATE="$root/gh.state"
export CPT_BRANCH_GH="$(cd "$(dirname "$0")" && pwd)/fixtures/fake-gh.zsh"
export CPT_BRANCH_TITLE="$root/title.txt"
cat > "$root/gh.zsh" <<'MOCK'
#!/bin/zsh
args=("$@")
if [[ "$1 $2" == 'pr create' ]]; then
  while (( $# )); do
    if [[ "$1" == --title ]]; then print -r -- "$2" > "$CPT_BRANCH_TITLE"; break; fi
    shift
  done
fi
exec "$CPT_BRANCH_GH" "${args[@]}"
MOCK
chmod 700 "$root/gh.zsh"
base_sha="$(git -C "$root" rev-parse HEAD)"
git -C "$root" push -q origin "${base_sha}:refs/heads/review/migration"
cpt -C "$root" publish set-base "$request" review/migration "$base_sha" >/dev/null
[[ "$(sqlite3 "$db" 'SELECT base_branch FROM pull_requests;')" == main ]]
if cpt -C "$root" publish set-base "$request" review/migration "$head_sha" --apply >/dev/null 2>&1; then exit 1; fi
cpt -C "$root" publish set-base "$request" review/migration "$base_sha" --apply >/dev/null
[[ "$(sqlite3 "$db" 'SELECT base_branch FROM pull_requests;')" == review/migration ]]
[[ "$(sqlite3 "$db" 'SELECT COUNT(*) FROM publish_approvals;')" == 0 ]]
cpt -C "$root" publish approve "$request" >/dev/null
# A moved remote base must block publication before the candidate is pushed.
git -C "$root" push -q origin "${head_sha}:refs/heads/test/candidate"
git --git-dir="$root/remote.git" update-ref refs/heads/review/migration "$head_sha"
if COUNTERPOINTER_GH_BIN="$root/gh.zsh" cpt -C "$root" publish apply "$request" >/dev/null 2>&1; then exit 1; fi
git --git-dir="$root/remote.git" update-ref refs/heads/review/migration "$base_sha"
# Recover the historical failure: pushed exact SHA, but PR creation was skipped.
git -C "$root" push -q origin "${head_sha}:refs/heads/$branch"
sqlite3 "$db" "UPDATE publish_requests SET state='FAILED',failure_reason='PR_RESULT_INVALID'; UPDATE pull_requests SET last_pushed_sha='$head_sha';"
# An older supervisor may have prepared a duplicate after the failure.
sqlite3 "$db" "INSERT INTO publish_requests SELECT 'duplicate',job_id,'PREPARED',head_sha,created_at,updated_at,NULL FROM publish_requests WHERE request_id='$request'; INSERT INTO pull_requests SELECT 'duplicate',change_set_id,branch_name,'main',remote_name,NULL,NULL,'NOT_CREATED',NULL,body_path,draft,NULL,created_at,updated_at FROM pull_requests WHERE request_id='$request';"
COUNTERPOINTER_GH_BIN="$root/gh.zsh" cpt -C "$root" publish apply "$request" >/dev/null
[[ "$(sqlite3 "$db" "SELECT state || char(124) || failure_reason FROM publish_requests WHERE request_id='duplicate';")" == 'FAILED|SUPERSEDED_BY_PUBLISHED_REQUEST' ]]
[[ "$(cat "$CPT_BRANCH_TITLE")" == '055_A 法務' ]]
[[ "$(wc -l < "$CPT_BRANCH_TITLE" | tr -d ' ')" == 1 ]]
cpt -C "$root" audit verify >/dev/null
print 'publish-branch: passed'
