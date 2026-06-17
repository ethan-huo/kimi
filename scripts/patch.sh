#!/usr/bin/env bash
set -euo pipefail

# 对上游 kimi-code 源码施加本地补丁：剥离 Moonshot 的 FetchURL / moonshotFetch
# URL 抓取 provider（不让 kimi 通过 Moonshot 服务代抓 URL）。
#
# 输入：环境变量 REPO_ROOT 指向已 clone 的上游仓库根目录。
# 行为：fail-loud —— 任何"应当命中"的规则未命中即退出非零，提示上游已漂移、
#       需要更新规则。允许失败的规则（上游可能已自行移除）用 `|| true` 放过。
#
# 规则逐条移植自本地 launcher 的 apply_patches，经实测可用。

: "${REPO_ROOT:?REPO_ROOT must point at the cloned upstream repo}"

echo "==> 应用补丁（移除 FetchURL）..."
failed=0

agcore="$REPO_ROOT/packages/agent-core/src"

# 1. core-impl.ts: 删除 localFetcher 变量
ast-grep run --pattern 'const localFetcher = new LocalFetchURLProvider();' \
  --rewrite '' -U "$agcore/rpc/core-impl.ts" >/dev/null 2>&1 \
  || { echo "  ✗ core-impl.ts: localFetcher 变量未匹配"; failed=1; }

# 2. core-impl.ts: 删除 fetchService 变量
ast-grep run --pattern 'const fetchService = input.config.services?.moonshotFetch;' \
  --rewrite '' -U "$agcore/rpc/core-impl.ts" >/dev/null 2>&1 \
  || { echo "  ✗ core-impl.ts: fetchService 变量未匹配"; failed=1; }

# 3. core-impl.ts: 把 urlFetcher 条件表达式整体替换为 undefined
ast-grep run --pattern 'fetchService?.baseUrl === undefined ? localFetcher : $$$REST' \
  --rewrite 'undefined' -U "$agcore/rpc/core-impl.ts" >/dev/null 2>&1 \
  || { echo "  ✗ core-impl.ts: urlFetcher 条件未匹配"; failed=1; }

# 4. core-impl.ts: 删除不再使用的 import（上游可能已移除，允许失败）
ast-grep run --pattern "import { LocalFetchURLProvider } from '#/tools/providers/local-fetch-url';" \
  --rewrite '' -U "$agcore/rpc/core-impl.ts" >/dev/null 2>&1 || true
ast-grep run --pattern "import { MoonshotFetchURLProvider } from '#/tools/providers/moonshot-fetch-url';" \
  --rewrite '' -U "$agcore/rpc/core-impl.ts" >/dev/null 2>&1 || true

# 5. builtin/index.ts: 移除 FetchURL 导出
ast-grep run --pattern "export * from './web/fetch-url';" \
  --rewrite '' -U "$agcore/tools/builtin/index.ts" >/dev/null 2>&1 \
  || { echo "  ✗ builtin/index.ts: 导出未匹配"; failed=1; }

# 6. tool/index.ts: 移除 FetchURLTool 注册
ast-grep run --pattern 'toolServices?.urlFetcher && new b.FetchURLTool(toolServices.urlFetcher)' \
  --rewrite '' -U "$agcore/agent/tool/index.ts" >/dev/null 2>&1 \
  || { echo "  ✗ tool/index.ts: 注册未匹配"; failed=1; }

# 7. services.ts: 修正 import 路径（UrlFetcher 改从 fetch-url 直接引入）
services_fix="import type { UrlFetcher } from '../builtin/web/fetch-url';
import type { WebSearchProvider } from '../builtin';"
ast-grep run --pattern "import type { UrlFetcher, WebSearchProvider } from '../builtin';" \
  --rewrite "$services_fix" -U "$agcore/tools/support/services.ts" >/dev/null 2>&1 \
  || { echo "  ✗ services.ts: import 未匹配"; failed=1; }

# 8-11. 默认 profile YAML: 移除 FetchURL 工具
for yaml in agent.yaml coder.yaml explore.yaml plan.yaml; do
  yaml_path="$agcore/profile/default/$yaml"
  [ -f "$yaml_path" ] || continue
  ast-grep run --pattern "  - FetchURL" --rewrite '' -U "$yaml_path" >/dev/null 2>&1 \
    || { echo "  ✗ profile/default/$yaml: FetchURL 未匹配"; failed=1; }
done

# 12. 默认放行列表移除 FetchURL
ast-grep run --pattern "  'FetchURL'," --rewrite '' -U \
  "$agcore/agent/permission/policies/default-tool-approve.ts" >/dev/null 2>&1 \
  || { echo "  ✗ default-tool-approve.ts: FetchURL 未匹配"; failed=1; }

# 13-15. TUI 渲染逻辑（上游可能已移除，允许失败）
tui="$REPO_ROOT/apps/kimi-code/src/tui/components/messages"
ast-grep run --pattern 'FetchURL: fetchChip,' --rewrite '' -U \
  "$tui/tool-renderers/chip.ts" >/dev/null 2>&1 || true
ast-grep run --pattern $'case '\''FetchURL'\'':\n      return fetchSummary;' --rewrite '' -U \
  "$tui/tool-renderers/registry.ts" >/dev/null 2>&1 || true
ast-grep run --pattern "FetchURL: ['url']," --rewrite '' -U \
  "$tui/tool-call.ts" >/dev/null 2>&1 || true

if [ "$failed" -ne 0 ]; then
  echo ""
  echo "❌ 部分补丁未能应用，上游可能有破坏性变更。请检查源码并更新本脚本的 ast-grep 规则。"
  exit 1
fi
echo "  ✓ 补丁应用完成"
