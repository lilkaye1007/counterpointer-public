#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
root="$(mktemp -d)"
trap '/bin/rm -rf "$root"' EXIT INT TERM
mkdir -p "$root/.counterpointer"

sqlite3 "$root/.counterpointer/state.sqlite3" <<'SQL'
CREATE TABLE integration_jobs (
  job_id TEXT PRIMARY KEY,
  state TEXT NOT NULL CHECK(state IN ('WAITING_TASKS','PREPARING','VERIFYING','VERIFIED','FAILED')),
  worktree TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
INSERT INTO integration_jobs VALUES ('legacy-job','WAITING_TASKS','/tmp/legacy','2026-08-01T00:00:00Z','2026-08-01T00:00:00Z');
SQL
print 'installed_at=2026-08-01T00:00:00Z\nstate=RUNNING\ncredential_generation=1' > "$root/.counterpointer/service.state"
chmod 700 "$root/.counterpointer"
chmod 600 "$root/.counterpointer/state.sqlite3" "$root/.counterpointer/service.state"

COUNTERPOINTER_TEST=1 "$repo_root/bin/cpt" -C "$root" service stop >/dev/null
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" 'SELECT state FROM integration_jobs WHERE job_id="legacy-job";')" == WAITING_TASKS ]]
for column in change_set_id membership_revision candidate_sha failure_reason evidence_path; do
  sqlite3 "$root/.counterpointer/state.sqlite3" 'PRAGMA table_info(integration_jobs);' | cut -d'|' -f2 | grep -qx "$column"
done

print 'migration: passed'
