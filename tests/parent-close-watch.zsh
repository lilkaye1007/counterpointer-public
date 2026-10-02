#!/bin/zsh
set -euo pipefail
root="$(mktemp -d)"
trap '[[ -z "${watch_pid:-}" ]] || kill "$watch_pid" 2>/dev/null || true; rm -rf "$root"' EXIT
mkdir -p "$root/fakebin"
cat > "$root/fakebin/cmux" <<'CMUX'
#!/bin/zsh
print -rl -- "$@" >> "$CPT_FAKE_CMUX_LOG"
[[ "$1" == close-surface ]]
CMUX
chmod +x "$root/fakebin/cmux"
PATH="$root/fakebin:${0:A:h:h}/bin:/usr/bin:/bin"
export PATH COUNTERPOINTER_TEST=1 COUNTERPOINTER_RUNTIME_TEST=1 CPT_FAKE_CMUX_LOG="$root/cmux.log" COUNTERPOINTER_CMUX_BIN="$root/fakebin/cmux"
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
print base > "$root/README.md"
git -C "$root" add README.md
git -C "$root" commit -qm base
cpt -C "$root" version >/dev/null
db="$root/.counterpointer/state.sqlite3"
sqlite3 "$db" "INSERT INTO parent_runtimes(generation,state,process_pid,workspace_ref,pane_ref,started_at,updated_at) VALUES (1,'ACTIVE',1234,'workspace:8','surface:9',datetime('now'),datetime('now'));"
cpt -C "$root" parent-close-watch 1 &
watch_pid=$!
sleep 0.3
[[ ! -e "$root/cmux.log" ]]
: > "$root/.counterpointer/parent-close-requested"
wait "$watch_pid"
[[ "$(<"$root/.counterpointer/parent-close-ack")" == '1|workspace:8|surface:9' ]]
grep -Fq -- 'close-surface' "$root/cmux.log"
grep -Fq -- 'surface:9' "$root/cmux.log"
print 'parent-close-watch: passed'
