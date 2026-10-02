# Fixture-only Codex index and rollout metadata; never reads real conversations.
record_codex_fixture() {
  local fixture_root="$1" fixture_worktree="$2"
  export CODEX_HOME="$fixture_root/codex-state"
  mkdir -p "$CODEX_HOME"
  export CPT_FIXTURE_SESSION=11111111-1111-4111-8111-111111111111
  sqlite3 "$CODEX_HOME/state_5.sqlite" 'CREATE TABLE IF NOT EXISTS threads (id TEXT PRIMARY KEY,cwd TEXT,rollout_path TEXT,created_at INTEGER,archived INTEGER);'
  jq -cn --arg id "$CPT_FIXTURE_SESSION" --arg cwd "$fixture_worktree" '{type:"session_meta",payload:{id:$id,cwd:$cwd}}' > "$CODEX_HOME/fixture.jsonl"
  sqlite3 "$CODEX_HOME/state_5.sqlite" "INSERT OR REPLACE INTO threads VALUES ('$CPT_FIXTURE_SESSION','$fixture_worktree','$CODEX_HOME/fixture.jsonl',1,0);"
}
