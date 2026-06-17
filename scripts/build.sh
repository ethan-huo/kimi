#!/usr/bin/env bash
set -euo pipefail

# 构建一个 patched kimi 的 macOS 可执行包。
#
#   build.sh <upstream-version> [target]
#   target: darwin-arm64 (默认) | darwin-x64
#
# 产物：dist/kimi-<target>.tar.gz (+ .sha256)
# 解包后布局：
#   kimi            launcher (bun 运行 + 自托管 upgrade)
#   VERSION         上游版本号
#   dist/           patched bundle (main.mjs + chunks)  ← tsdown 产物
#   node_modules/   裁剪后的 native 依赖 (单平台)
#
# 前置工具：git, pnpm, node(>=24.15), npm, bun, ast-grep。CI 里由 workflow 装好；
# 本机直接跑也行（你这些工具都有）。
#
# 设计要点：
#   - 用 pnpm/tsdown 构建，不用 bun build —— bun bundler 解析不了 kimi monorepo
#     的 `#/` subpath imports（实测报错），tsdown/rolldown 原生支持。bun 只做运行时。
#   - native 依赖单独 clean-install 再裁剪，避免从 pnpm 嵌套 store 里捞文件。

VERSION="${1:?usage: build.sh <upstream-version> [target]}"
TARGET="${2:-darwin-arm64}"

case "$TARGET" in
  darwin-arm64) KOFFI_TRIPLET=darwin_arm64; CLIP_PKG="@mariozechner/clipboard-darwin-arm64" ;;
  darwin-x64)   KOFFI_TRIPLET=darwin_x64;   CLIP_PKG="@mariozechner/clipboard-darwin-x64" ;;
  *) echo "unsupported target: $TARGET (only darwin-arm64 / darwin-x64)"; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo 根目录
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
UPSTREAM="$WORK/kimi-code"
TAG="@moonshot-ai/kimi-code@$VERSION"

echo "==> clone 上游 $TAG"
git clone --quiet --depth 1 --branch "$TAG" \
  https://github.com/MoonshotAI/kimi-code "$UPSTREAM"

echo "==> pnpm install"
( cd "$UPSTREAM" && pnpm install --frozen-lockfile )

echo "==> 施加补丁"
REPO_ROOT="$UPSTREAM" bash "$HERE/scripts/patch.sh"

# 生成 built-in catalog，与官方发布产物对齐（缺失会降级内置 agents/plugins）
echo "==> 生成 built-in catalog"
CATALOG="$WORK/catalog.json"
( cd "$UPSTREAM" && node apps/kimi-code/scripts/update-catalog.mjs --out "$CATALOG" )
export KIMI_CODE_BUILT_IN_CATALOG_FILE="$CATALOG"

echo "==> 构建 (tsdown)"
# agent-core 被 patch 过；kimi-code 的 tsdown 会内联 agent-core 源码。先单独 build
# agent-core 以防有任何子路径解析到其 dist（与本地 launcher 行为一致）。
( cd "$UPSTREAM" \
    && pnpm --filter @moonshot-ai/agent-core run build \
    && pnpm --filter @moonshot-ai/kimi-code run build )

echo "==> 准备 native 依赖 ($TARGET)"
NM="$WORK/native"
mkdir -p "$NM"
KOFFI_VER="$(node -p "require('$UPSTREAM/apps/kimi-code/package.json').optionalDependencies.koffi")"
CLIP_VER="$(node -p "require('$UPSTREAM/apps/kimi-code/package.json').optionalDependencies['@mariozechner/clipboard']")"
( cd "$NM" && npm init -y >/dev/null \
    && npm i --no-audit --no-fund --loglevel=error "koffi@$KOFFI_VER" "@mariozechner/clipboard@$CLIP_VER" )

echo "==> 组装"
STAGE="$WORK/stage"
mkdir -p "$STAGE/node_modules/@mariozechner"
cp -R "$UPSTREAM/apps/kimi-code/dist" "$STAGE/dist"

# koffi：整包拷入后删掉非目标平台的 triplet（每个 ~1.5MB，全平台 ~30MB）
cp -R "$NM/node_modules/koffi" "$STAGE/node_modules/koffi"
find "$STAGE/node_modules/koffi/build/koffi" -mindepth 1 -maxdepth 1 -type d \
  ! -name "$KOFFI_TRIPLET" -exec rm -rf {} +

# clipboard：host 包 + 单个平台子包
cp -R "$NM/node_modules/@mariozechner/clipboard" "$STAGE/node_modules/@mariozechner/clipboard"
cp -R "$NM/node_modules/$CLIP_PKG" "$STAGE/node_modules/$CLIP_PKG"

cp "$HERE/launcher/kimi" "$STAGE/kimi"
chmod +x "$STAGE/kimi"
printf '%s\n' "$VERSION" > "$STAGE/VERSION"

# kimi 的 getVersion() 在没有 __KIMI_CODE_VERSION__ define 时(npm build 即如此)，
# 会从 dist/main.mjs 往上找 package.json 读 version。放一个最小 package.json 满足它，
# 同时让 getHostPackageRoot()/detectInstallSource() 有据可依(会判为 unsupported，正合意)。
node -e "const p=require('$UPSTREAM/apps/kimi-code/package.json'); process.stdout.write(JSON.stringify({name:p.name,version:p.version,type:'module'},null,2)+'\n')" \
  > "$STAGE/package.json"

echo "==> 打包"
OUT="$HERE/dist"
mkdir -p "$OUT"
TARBALL="$OUT/kimi-$TARGET.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" .
shasum -a 256 "$TARBALL" | awk '{print $1}' > "$TARBALL.sha256"

echo ""
echo "✓ $TARBALL"
echo "  size: $(du -h "$TARBALL" | cut -f1)   sha256: $(cat "$TARBALL.sha256")"
