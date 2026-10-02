#!/bin/zsh
set -euo pipefail
PATH="$(cd "$(dirname "$0")/.." && pwd)/bin:/usr/bin:/bin:$PATH"
export PATH COUNTERPOINTER_TEST=1

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git -C "$root" init -q -b main
git -C "$root" config user.name test
git -C "$root" config user.email test@example.com
mkdir -p "$root/docs/design" "$root/docs/archive/260504" "$root/src"
print '# project' > "$root/README.md"
print '# design' > "$root/docs/design/system.md"
print '# 索引' > "$root/docs/archive/260504/索引.md"
print 'export const value = 1' > "$root/src/index.ts"
git -C "$root" add .
git -C "$root" commit -qm base

init_output="$(cpt -C "$root" init --scan)"
[[ "$init_output" == *'初期準備が完了'* && "$init_output" == *'まだ確定していません'* && "$init_output" == *'次のcpt start'* ]]
proposal1="$(cpt -C "$root" index onboarding --json | jq -r .proposal_id)"
[[ "$(cpt -C "$root" init)" == *'AI分析待ち'* ]]
[[ "$(cpt -C "$root" index onboarding --json | jq -r .proposal_id)" == "$proposal1" ]]
proposal2="$(cpt -C "$root" index refresh | sed -n '1p')"
[[ -n "$proposal1" && "$proposal1" == "$proposal2" ]]
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT COUNT(*) FROM index_entries WHERE proposal_id='$proposal1' AND path='docs/archive/260504/索引.md';")" == 1 ]]
[[ "$(cpt -C "$root" index analysis-template "$proposal1" | jq -r .proposal_id)" == "$proposal1" ]]
if cpt -C "$root" index apply "$proposal1" >/dev/null 2>&1; then
  print -u2 'AI分析前の初回索引が適用されました'
  exit 1
fi
manifest_path="$(cpt -C "$root" index onboarding --json | jq -r .manifest_path)"
draft_dir="${manifest_path:h}/generated-ssot"; mkdir -p "$draft_dir"
print '# 生成設計案' > "$draft_dir/system-v2.md"
jq -n --arg id "$proposal1" --arg draft "$draft_dir/system-v2.md" '{schema_version:1,proposal_id:$id,summary:"既存の設計文書とソース領域を対応付けました。",existing_ssot:[{path:"README.md",role:"プロジェクト概要",quality:"良好"},{path:"docs/design/system.md",role:"システム設計",quality:"要更新"}],areas:[{name:"ドキュメント",root:"docs",coverage:"covered",ssot_paths:["docs/design/system.md"]},{name:"ソース",root:"src",coverage:"partial",ssot_paths:[]}],gaps:[{area:"ソース",reason:"実装詳細の説明が不足"}],inconsistencies:[],replacement_candidates:[{existing_path:"docs/design/system.md",generated_draft:"docs/ssot/system-v2.md",recommendation:"統合候補",reason:"設計意図を残したままソース対応を追加できる"}],generated_drafts:[{target_path:"docs/ssot/system-v2.md",draft_path:$draft,rationale:"不足するソース説明を補う"}]}' > "$root/analysis.json"
analysis_report="$(cpt -C "$root" index submit-analysis "$proposal1" "$root/analysis.json")"
[[ "$analysis_report" == *'既存SSOT 2件'* && "$analysis_report" == *'生成SSOT案: 1件'* && "$analysis_report" == *'比較・移行候補: 1件'* && "$analysis_report" == *'承認すると行うこと'* && "$analysis_report" == *'既存SSOTは変更・削除しない'* ]]
task="$(cpt -C "$root" register --mode quick --text 'src/index.ts の値を2へ変更する' --path src/index.ts)"
if cpt -C "$root" dispatch "$task" >"$root/index-gate.out" 2>&1; then
  print -u2 '未確認索引でdispatchされました'
  exit 1
fi
[[ "$(<"$root/index-gate.out")" == *'索引・SSOT整理が確認待ち'* ]]
cpt -C "$root" index apply "$proposal1" >/dev/null
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" 'SELECT MAX(revision) FROM index_revisions;')" == 1 ]]
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" "SELECT json_valid(readfile('$root/.counterpointer/ssot/index.json')); ")" == 1 ]]

print 'export const value = 3' > "$root/src/index.ts"
git -C "$root" add src/index.ts
git -C "$root" commit -qm 'merged source update'
sync_output="$(cpt -C "$root" index sync)"
[[ "$sync_output" == *'正式索引へ自動反映'* ]]
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" 'SELECT MAX(revision) FROM index_revisions;')" == 2 ]]
cpt -C "$root" dispatch "$task" >/dev/null
[[ -s "$root/.counterpointer/worktrees/$task/.counterpointer-task/project-core.md" ]]
[[ -s "$root/.counterpointer/worktrees/$task/.counterpointer-task/task-context.md" ]]

print '# 検証済み事実
- 索引revision 1

# 未完了
- なし' > "$root/.counterpointer/context/parent-summary.md"
cpt -C "$root" context compact >/dev/null
[[ "$(sqlite3 "$root/.counterpointer/state.sqlite3" 'SELECT COUNT(*) FROM context_checkpoints;')" == 1 ]]

if command -v jq >/dev/null 2>&1; then
  print -r -- '{"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":80},"output_tokens":20}}' > "$root/usage.jsonl"
  cpt -C "$root" usage import "$task" "$root/usage.jsonl" >/dev/null
  usage_summary="$(cpt -C "$root" usage summary)"
  [[ "$usage_summary" == *'実測cache率: 80%'* && "$usage_summary" == *'推定input:'* ]]
fi

print '# updated design' > "$root/docs/design/system.md"
git -C "$root" add docs/design/system.md
git -C "$root" commit -qm 'merged ssot update'
if cpt -C "$root" index sync >"$root/ssot-sync.out" 2>&1; then
  print -u2 'SSOT変更がAI再分析なしで正式索引へ反映されました'
  exit 1
fi
[[ "$(<"$root/ssot-sync.out")" == *'親Codexの再分析が必要'* ]]
[[ "$(cpt -C "$root" index onboarding --json | jq -r .state)" == PENDING_AI_ANALYSIS ]]

print 'context: passed'
