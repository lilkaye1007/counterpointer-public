#!/bin/zsh
set -euo pipefail

state_file="${CPT_FAKE_GH_STATE:?CPT_FAKE_GH_STATEが必要です}"
[[ "${1:-}" == pr ]] || exit 2
action="${2:-}"
case "$action" in
  list)
    if [[ "${CPT_FAKE_GH_HANG:-0}" == 1 ]]; then sleep 120; fi
    [[ "${CPT_FAKE_GH_FAIL:-0}" != 1 ]] || exit 1
    [[ -z "${CPT_FAKE_GH_EXPECT_ROOT:-}" || "$PWD" == "$CPT_FAKE_GH_EXPECT_ROOT" ]] || exit 2
    if [[ ! -f "$state_file" ]]; then
      # Mirror gh's actual jq result for an empty list, including null fields.
      if [[ "$*" != *'// empty'* ]]; then printf '\t\t\n'; fi
      exit 0
    fi
    IFS='|' read -r number state url merge_sha base_branch < "$state_file"
    if [[ "$*" == *mergeCommit* ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$number" "$state" "$url" "${merge_sha:--}" "${base_branch:-main}"
    else
      printf '%s\t%s\t%s\n' "$number" "$state" "$url"
    fi
    ;;
  create)
    print -r -- '17|OPEN|https://example.invalid/pull/17' > "$state_file"
    print -r -- 'https://example.invalid/pull/17'
    ;;
  *) exit 2;;
esac
