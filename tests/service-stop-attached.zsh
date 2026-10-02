#!/bin/zsh
set -euo pipefail
PATH="${0:A:h:h}/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1 COUNTERPOINTER_RUNTIME_TEST=1
root="$(mktemp -d)"
trap '[[ -z "${parent_pid:-}" ]] || kill -KILL "$parent_pid" 2>/dev/null || true; rm -rf "$root"' EXIT
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print base > "$root/README.md"
git -C "$root" add README.md
git -C "$root" commit -qm base
cpt -C "$root" service install >/dev/null
print 'installed_at=fixture\nstate=RUNNING' > "$root/.counterpointer/service.state"
print 'mode=attached' > "$root/.counterpointer/orchestrator.mode"
cat > "$root/codex" <<'CODEX'
#!/bin/zsh
trap '' TERM
sleep 120 &
wait
CODEX
(cd "$root" && /bin/zsh "$root/codex") &
parent_pid=$!
db="$root/.counterpointer/state.sqlite3"
sqlite3 "$db" "INSERT INTO parent_runtimes(generation,state,process_pid,started_at,updated_at) VALUES (1,'ACTIVE',$parent_pid,datetime('now'),datetime('now'));"
cpt -C "$root" service stop >/dev/null
wait "$parent_pid" 2>/dev/null || true
if kill -0 "$parent_pid" 2>/dev/null; then exit 1; fi
[[ "$(sqlite3 "$db" 'SELECT state FROM parent_runtimes WHERE generation=1;')" == STOPPED ]]
print 'service-stop-attached: passed'
