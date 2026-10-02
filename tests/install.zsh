#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
test_root="$(mktemp -d)"
trap '/bin/rm -rf "$test_root"' EXIT INT TERM
target="$test_root/bin/cpt"
state="$test_root/install-state"

CPT_INSTALL_STATE_ROOT="$state" "$repo_root/bin/install" --target "$target" --dry-run >/dev/null
[[ ! -e "$target" && ! -L "$target" ]]

CPT_INSTALL_STATE_ROOT="$state" "$repo_root/bin/install" --target "$target" >/dev/null
[[ -f "$target" && ! -L "$target" ]]
[[ "$($target version --json | jq -r .version)" == 0.3.0 ]]
[[ "$(stat -f '%Lp' "$state/manifest.json")" == 600 ]]
[[ "$(jq -r .target "$state/manifest.json")" == "$target" ]]

# 再導入時に旧版を退避し、rollback可能であることを確認する。
/bin/rm "$target"
print '#!/bin/zsh\nprint old-version' > "$target"
chmod 755 "$target"
CPT_INSTALL_STATE_ROOT="$state" "$repo_root/bin/install" --target "$target" >/dev/null
[[ -f "$target" && ! -L "$target" ]]
backups=("$target".backup.*(N))
(( ${#backups[@]} == 1 ))
CPT_INSTALL_STATE_ROOT="$state" "$repo_root/bin/install" --target "$target" --rollback >/dev/null
[[ "$($target)" == old-version ]]

CPT_INSTALL_STATE_ROOT="$state" "$repo_root/bin/install" --target "$target" >/dev/null
"$repo_root/bin/uninstall" --target "$target" --dry-run >/dev/null
[[ -f "$target" && ! -L "$target" ]]
"$repo_root/bin/uninstall" --target "$target" >/dev/null
[[ ! -e "$target" && ! -L "$target" ]]
removed=("$target".removed.*(N))
(( ${#removed[@]} == 1 ))
[[ -f "$state/manifest.json" ]]

print 'install: passed'
