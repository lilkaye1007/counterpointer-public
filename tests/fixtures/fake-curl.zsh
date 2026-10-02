#!/bin/zsh
set -euo pipefail

for argument in "$@"; do
  [[ "$argument" != *test-secret* ]] || { print -u2 'token leaked to argv'; exit 9; }
done
config="$(/bin/cat)"
[[ "$config" == *'Authorization: Bearer test-secret'* ]] || { print -u2 'authorization missing'; exit 8; }
[[ "${CPT_FAKE_CURL_FAIL:-0}" == 0 ]] || exit 7
print -r -- '{"id":"ntfy-test-1"}'
