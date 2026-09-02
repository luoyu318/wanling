# wanling-skills — Agent 技能

让支持 Agent Skills（`SKILL.md`）的工具获得万灵小程序开发发布与发图能力：

- **wanling-miniprogram-publish** — 开发万灵小程序并直传上传（自检→打包→agent token→POST /api/mini-programs），无需用户手动操作
- **wanling-send-image** — 在万灵会话中向用户发送本地图片（tool 注册挂件 + upload.py）

## 安装前可审阅

- [install.sh](https://gitee.com/luoyu318/wanling/raw/main/skills/install.sh)（[GitHub 镜像](https://raw.githubusercontent.com/luoyu318/wanling/main/skills/install.sh)）
- [安装包清单 manifest.sha256](https://gitee.com/luoyu318/wanling/raw/main/skills/manifest.sha256)
- [wanling-miniprogram-publish/SKILL.md](https://gitee.com/luoyu318/wanling/raw/main/skills/wanling-miniprogram-publish/SKILL.md)
- [wanling-send-image/SKILL.md](https://gitee.com/luoyu318/wanling/raw/main/skills/wanling-send-image/SKILL.md)

## 手动安装

以下命令适用于 macOS、Linux 与 WSL；Windows 原生环境请让当前 Agent 按本页说明安装，不要把 Bash 命令直接粘贴到 PowerShell。

技能本体统一种在通用目录 `~/.agents/skills/<name>`，默认（`--target opencode`）在 `~/.opencode/skills/` 建软链让 OpenCode 发现，不复制第二份。安装全部技能：

```bash
bash <(curl -fsSL https://gitee.com/luoyu318/wanling/raw/main/skills/install.sh)
```

按名安装单个：

```bash
bash <(curl -fsSL https://gitee.com/luoyu318/wanling/raw/main/skills/install.sh) wanling-miniprogram-publish
```

`--target` 控制哪些 agent 工具通过软链发现技能（逗号分隔）：`agents`（只装通用目录本体）/ `opencode`（默认）/ `claude` / `codex` / `gemini` / `copilot`。例如同时给 Claude Code 与 OpenCode：

```bash
bash <(curl -fsSL https://gitee.com/luoyu318/wanling/raw/main/skills/install.sh) --target claude,opencode
```

落到自定义目录（不建软链）：

```bash
bash <(curl -fsSL https://gitee.com/luoyu318/wanling/raw/main/skills/install.sh) --dir "$HOME/path/to/skills/wanling-send-image" wanling-send-image
```

安装器逐文件从 Gitee raw 下载（失败自动落 GitHub 镜像），对照 `manifest.sha256` 校验后原子替换目标目录。仓库内开发者可 `cd skills && ./install.sh`（本地模式，cp 直装）。`README.md` 与 `manifest.sha256` 不进技能安装目录。

## 扫码授权技能凭据（推荐）

技能的发布/发图需要 agent 凭据。除复用 opencode 插件配置外，可用 APP 扫码授权发放**子密钥**（不动 agent 主密钥，随时可在 APP「我的 → Agent → 授权密钥」吊销）：

```bash
bash <(curl -fsSL https://gitee.com/luoyu318/wanling/raw/main/skills/install.sh) --setup
# 可选: --server=URL 指定服务器(默认 http://localhost:18008);
#       --config-dir=PATH 指定配置目录(默认 ~/.config/wanling-skills)
```

流程：终端打印二维码 → 万灵 APP 扫一扫 → 选已有 Agent → 点「授权技能使用」→ 凭据自动写入 config.json（权限 600，不含明文回显）。

`publish.py` / `upload.py` 按以下顺序探测凭据（第一个存在的文件生效）：

1. `$WANLING_CONFIG_FILE`（显式指定）
2. `$WANLING_CONFIG_DIR/config.json`
3. `~/.config/opencode-wanling/config.json`（opencode 插件，存在则用）
4. `~/.config/wanling-skills/config.json`（技能 setup）

全都不存在时报错列出探测路径并提示运行 `--setup`。`--setup` 可与安装共存：带技能名运行先装技能再授权（如 `./install.sh --setup wanling-miniprogram-publish`）。

## 旧目录迁移

安装器检查以下位置的**真实副本**（软链不算），发现即默认停止，不静默覆盖：

```text
~/.opencode/skills/<name>   ~/.claude/skills/<name>   ~/.codex/skills/<name>
~/.gemini/skills/<name>     ~/.copilot/skills/<name>  ~/.config/opencode/skills/<name>
```

确认可迁移后显式执行（本体收编到 `~/.agents/skills/<name>`，原位置改软链；canonical 已存在时移除重复副本）：

```bash
bash <(curl -fsSL https://gitee.com/luoyu318/wanling/raw/main/skills/install.sh) --migrate-legacy
```

## 安装后验证

1. 重启 Agent 或开启新会话。
2. 让 Agent 列出它发现的 skills，确认 `wanling-*` 各只有一份。
3. 对装了 publish 技能的 Agent 说：`写一个 hello 小程序并发布`——应按 SKILL.md 流程自检、上传并汇报 appid/version。

## 更新

本地技能不会自动更新。重跑同一条安装命令即可（幂等，sha256 校验后原子替换）。改了技能文件的维护者须在仓库内重生成清单：`cd skills && ./install.sh --gen-manifest`。

## 卸载

删除本体与各工具目录内的软链：

```bash
rm -rf ~/.agents/skills/wanling-send-image ~/.opencode/skills/wanling-send-image
```

## Agent 自助安装（agent 可直接执行）

agent 无需克隆仓库，直接执行上方「手动安装」命令即可；仓库内工作时 `cd skills && ./install.sh` 等价。安全约束：安装器仅向 `~/.agents/skills/` 与各 target 软链路径写入仓库内静态文件，逐文件 sha256 校验，无遥测、无用户数据删除；旧位置真实副本未确认前拒绝覆盖。

## 凭据获取

技能调用 server API 需要 agent 凭据。推荐走 `install.sh --setup` 两步完成（无需用户 token）：

1. 填 server URL——`--server=URL` 参数或交互输入，默认 `http://localhost:18008`；
2. 万灵 APP 扫码 → 选已有 Agent → 点「授权技能使用」，子密钥（`wlsk_` 前缀）自动写入配置文件（权限 600，无明文回显），终端轮询到凭据即完成。

技能凭据独立落 `~/.config/wanling-skills/config.json`（`--config-dir` 可覆盖），与 opencode 插件凭据（`~/.config/opencode-wanling/`）互不干扰：`--setup` 的写路径只认 `--config-dir` 或默认目录（忽略 `WANLING_CONFIG_DIR` env，防止运行环境注入误写插件目录）；`publish.py` / `upload.py` 读路径按上节探测顺序自动命中。子密钥不影响 agent 主密钥与现有绑定，可随时在 APP「我的 → Agent → 授权密钥」单独吊销。协议细节见 [agent-subkeys.md](../docs/ai-handbook/agent-subkeys.md)。
