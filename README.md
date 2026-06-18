# kimi (personal macOS build)

自托管的 [kimi-code](https://github.com/MoonshotAI/kimi-code) macOS 构建。补丁做两件事：
(1) 从 agent 的可见工具集里**隐藏 `WebSearch` + `FetchURL`**（单点 filter `setActiveTools`，
模型收不到这两个工具的 schema，彻底无感知——官方 config 的 `disabledTools` 只对 MCP 生效，
管不了 builtin)；(2) 把 `FetchURL` / `moonshotFetch` 服务从源码整个**拔掉**(不让 kimi 通过
Moonshot 服务代抓 URL)。产物跑在 **bun** 上（~10-20MB,对比官方 native SEA ~100MB），
通过 `kimi upgrade` 走本仓库 Release 自更新。

## 为什么不直接用官方包

- 官方 native 二进制是 Node SEA（嵌完整 Node 运行时）→ ~100MB。本机有 bun,不需要嵌运行时。
- 需要剥掉 FetchURL（不让 kimi 通过 Moonshot 服务代抓 URL),官方 npm dist 里它是焊死的,
  只能从 patched 源码构建。

## 工作原理

```
CI (macOS arm64, 每 6h)
  ├─ poll npm: @moonshot-ai/kimi-code 最新版
  ├─ 已发过该版本 → 跳过
  └─ 否则:
       clone 上游对应 tag
       → ast-grep 剥 FetchURL (scripts/patch.sh)
       → pnpm build (tsdown)          # 注: 不用 bun build,它解析不了 monorepo 的 #/ subpath imports
       → 安装上游 optionalDependencies 到产物 node_modules  # 0.17.0+ tsdown 不再内联这些依赖
       → 裁剪 koffi 非目标平台 triplet
       → tar + 自托管 launcher
       → 发 GitHub Release  v<upstream>.<本仓库 commit 数>   # 补丁/构建改动产生新 commit 即新版本
```

运行时:`kimi` launcher 快路径 `exec bun dist/main.mjs`,并置 `KIMI_CODE_NO_AUTO_UPDATE=1`
关掉官方更新检查;`kimi upgrade` 从本仓库 Release 拉新包原地替换。

## 安装

```bash
VER=$(curl -fsSL https://api.github.com/repos/ethan-huo/kimi/releases/latest | grep -m1 tag_name | sed -E 's/.*"v?([^"]+)".*/\1/')
mkdir -p ~/.kimi && curl -fsSL "https://github.com/ethan-huo/kimi/releases/download/v$VER/kimi-darwin-arm64.tar.gz" | tar -xz -C ~/.kimi
ln -sf ~/.kimi/kimi ~/.local/bin/kimi   # 确保 ~/.local/bin 在 PATH
kimi --version
```

## 本地构建（调试）

```bash
bash scripts/build.sh 0.16.0 darwin-arm64
# → dist/kimi-darwin-arm64.tar.gz
```

需要本机有:git / pnpm / node>=24.15 / npm / bun / ast-grep。

## 手动触发一次 release

```bash
gh workflow run "Build & Release"                 # 用 npm latest
gh workflow run "Build & Release" -f version=0.16.0
```
