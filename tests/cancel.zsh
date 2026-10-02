#!/bin/zsh
set -euo pipefail
PATH="${0:A:h:h}/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print baseline > "$root/README.md"
git -C "$root" add README.md
git -C "$root" commit -qm baseline
db="$root/.counterpointer/state.sqlite3"

verify_task() {
  local task="$1" filename="$2"
  cpt -C "$root" dispatch "$task" >/dev/null
  print "implemented $filename" > "$root/.counterpointer/worktrees/$task/$filename"
  cpt -C "$root" selfcheck "$task" >/dev/null
  cpt -C "$root" verify "$task" >/dev/null
  cpt -C "$root" external-verify "$task" >/dev/null
}

# A verified Task with a local-only publish request can be cancelled safely.
single="$(cpt -C "$root" register --mode quick --text 'single.txtを追加する' --path single.txt)"
single_set="$(sqlite3 "$db" "SELECT change_set_id FROM change_set_tasks WHERE task_id='$single';")"
verify_task "$single" single.txt
single_job="$(cpt -C "$root" integrate "$single_set" | tail -1)"
single_publish="$(cpt -C "$root" publish "$single_job")"
single_request="$(print -r -- "$single_publish" | sed -n 's/^公開要求ID: //p')"
[[ -n "$single_request" ]]
sqlite3 "$db" "UPDATE task_schedule SET hold_reason='取消待ち' WHERE task_id='$single';"
cpt -C "$root" cancel "$single" >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$single';")" == CANCELLED ]]
[[ -z "$(sqlite3 "$db" "SELECT hold_reason FROM task_schedule WHERE task_id='$single';")" ]]
[[ "$(sqlite3 "$db" "SELECT state FROM change_sets WHERE change_set_id='$single_set';")" == CANCELLED ]]
[[ "$(sqlite3 "$db" "SELECT state || '|' || failure_reason FROM integration_jobs WHERE job_id='$single_job';")" == 'FAILED|TASK_CANCELLED' ]]
[[ "$(sqlite3 "$db" "SELECT state || '|' || failure_reason FROM publish_requests WHERE request_id='$single_request';")" == 'FAILED|TASK_CANCELLED' ]]
[[ "$(sqlite3 "$db" "SELECT state FROM integration_index_snapshots WHERE job_id='$single_job';")" == SUPERSEDED ]]
[[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE entity_type='task' AND entity_id='$single' AND event_type='TASK_CANCELLED';")" == 1 ]]
[[ "$(cpt -C "$root" status --json | jq -r ".[] | select(.task_id==\"$single\") | .display_state")" == CANCELLED ]]
[[ "$(cpt -C "$root" schedule context | jq -r --arg id "$single" '[.tasks[] | select(.task_id==$id)] | length')" == 0 ]]
if cpt -C "$root" publish approve "$single_request" >/dev/null 2>&1; then exit 1; fi
[[ "$(cpt -C "$root" cancel "$single")" == *'取消済みです'* ]]

# Cancelling one member invalidates the old candidate and reopens the remainder.
group="$(cpt -C "$root" changeset create --title 'partial cancellation')"
left="$(cpt -C "$root" register --mode quick --text 'left.txtを追加する' --path left.txt --change-set "$group")"
right="$(cpt -C "$root" register --mode quick --text 'right.txtを追加する' --path right.txt --change-set "$group")"
verify_task "$left" left.txt
verify_task "$right" right.txt
group_job="$(cpt -C "$root" integrate "$group" | tail -1)"
group_publish="$(cpt -C "$root" publish "$group_job")"
group_request="$(print -r -- "$group_publish" | sed -n 's/^公開要求ID: //p')"
old_revision="$(sqlite3 "$db" "SELECT membership_revision FROM change_sets WHERE change_set_id='$group';")"
cpt -C "$root" cancel "$left" >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM change_sets WHERE change_set_id='$group';")" == OPEN ]]
[[ "$(sqlite3 "$db" "SELECT membership_revision FROM change_sets WHERE change_set_id='$group';")" == $((old_revision+1)) ]]
[[ "$(sqlite3 "$db" "SELECT state FROM publish_requests WHERE request_id='$group_request';")" == FAILED ]]
replacement_job="$(cpt -C "$root" integrate "$group" | tail -1)"
[[ "$(sqlite3 "$db" "SELECT state FROM integration_jobs WHERE job_id='$replacement_job';")" == VERIFIED ]]
cpt -C "$root" cancel "$right" >/dev/null
[[ "$(sqlite3 "$db" "SELECT state FROM change_sets WHERE change_set_id='$group';")" == CANCELLED ]]

# Once push/PR publication has begun, cancellation fails closed.
published="$(cpt -C "$root" register --mode quick --text 'published.txtを追加する' --path published.txt)"
published_set="$(sqlite3 "$db" "SELECT change_set_id FROM change_set_tasks WHERE task_id='$published';")"
verify_task "$published" published.txt
published_job="$(cpt -C "$root" integrate "$published_set" | tail -1)"
published_output="$(cpt -C "$root" publish "$published_job")"
published_request="$(print -r -- "$published_output" | sed -n 's/^公開要求ID: //p')"
sqlite3 "$db" "UPDATE publish_requests SET state='PUBLISHED' WHERE request_id='$published_request'; UPDATE pull_requests SET pr_state='OPEN',pr_number=99,pr_url='https://example.invalid/pull/99' WHERE request_id='$published_request'; UPDATE integration_jobs SET state='PR_READY' WHERE job_id='$published_job'; UPDATE change_sets SET state='AWAITING_MERGE' WHERE change_set_id='$published_set';"
if cpt -C "$root" cancel "$published" >/dev/null 2>"$root/published-cancel.err"; then exit 1; fi
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$published';")" == VERIFIED ]]
[[ "$(<"$root/published-cancel.err")" == *'PR開始後'* ]]

# Worktree cleanup failure is reported without rolling back logical cancellation.
cleanup="$(cpt -C "$root" register --mode quick --text 'cleanup.txtを追加する' --path cleanup.txt)"
fake_worktree="$root/not-a-worktree"
mkdir "$fake_worktree"
sqlite3 "$db" "UPDATE tasks SET worktree='$fake_worktree' WHERE task_id='$cleanup';"
cpt -C "$root" cancel "$cleanup" >"$root/cleanup.out" 2>"$root/cleanup.err"
[[ "$(sqlite3 "$db" "SELECT state FROM tasks WHERE task_id='$cleanup';")" == CANCELLED ]]
[[ -d "$fake_worktree" && "$(<"$root/cleanup.err")" == *'worktreeを削除できません'* ]]
rmdir "$fake_worktree"
sqlite3 "$db" "UPDATE task_schedule SET hold_reason='古い保留理由' WHERE task_id='$cleanup';"
[[ "$(cpt -C "$root" cancel "$cleanup")" == *'取消済みです'* ]]
[[ -z "$(sqlite3 "$db" "SELECT COALESCE(worktree,'') FROM tasks WHERE task_id='$cleanup';")" ]]
[[ -z "$(sqlite3 "$db" "SELECT hold_reason FROM task_schedule WHERE task_id='$cleanup';")" ]]

cpt -C "$root" audit verify >/dev/null
print 'cancel: passed'
