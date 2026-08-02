# opencode-plugin — Wanling 桥接插件

将 OpenCode CLI/TUI 与万灵 APP 双向实时同步。

## 快速开始

### 1. 扫码配对（推荐）

```bash
./install.sh --pair
```

终端显示二维码，用万灵 APP「扫一扫」授权，自动完成 Agent 注册和配置。

### 2. 启动

```bash
node dist/index.js
```

自动拉起 OpenCode Serve。

### 3. 连 TUI

```bash
opencode attach http://localhost:5096
```

之后所有对话双向同步：TUI ↔ APP。

---

## 快捷命令（install.sh 自动安装到 `~/.local/bin`）

安装（`./install.sh --pair` 或手动安装）会顺带安装三个快捷命令，**等价于上面第 3 步，但自动带 proxy Basic Auth 并注入当前目录**：

| 命令 | 作用 |
|---|---|
| `ocwl` | 连 TUI：等价 `opencode attach http://localhost:<proxyPort>` + `-u opencode -p <proxyPassword> --dir $PWD` |
| `ocwl-restart` | 重启 `opencode-wanling` systemd 服务 |
| `ocwl-logs` | 实时跟踪服务日志（`journalctl --user -u ... -f`） |

```bash
ocwl                  # 连 TUI（自动鉴权 + 当前目录），快速开始第 3 步的等价物
ocwl --dir /path      # 指定工作目录（原样透传给 opencode attach）
ocwl -p myprofile     # 连多实例（install.sh --config-dir 装了多套时，对应 -suffix）
ocwl-restart          # 重启服务
ocwl-logs --since "10 min ago"   # 实时日志，journalctl flags 原样追加

ocwl --help           # 各命令均支持 -h/--help
```

> `ocwl` 依赖 `jq`（解析 config.json 取 proxyPort / proxyPassword）；`-p/--profile <suffix>` 对应 `install.sh --config-dir=~/.config/opencode-wanling-<suffix>` 安装的多实例。

## 手动安装

```bash
# 创建 Agent
TOKEN=$(curl -s http://localhost:18008/api/auth/login \
  -d '{"username":"test","password":"secret123"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['token'])")
AGENT=$(curl -s -X POST http://localhost:18008/api/agents \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"opencode-bridge"}')

# 启动（填入上一步的 id 和 secret_key）
WANLING_AGENT_ID=<id> WANLING_SECRET_KEY=<key> node dist/index.js

# 连 TUI
opencode attach http://localhost:5096
```

## 环境变量

| 变量 | 默认值 |
|---|---|
| `WANLING_SERVER_URL` | `http://localhost:18008` |
| `WANLING_AGENT_ID` | （必填，agent 注册时下发） |
| `WANLING_SECRET_KEY` | （必填，agent 注册时一次性下发） |
| `OPENCODE_PORT` | `4096`（OpenCode Serve 端口） |
| `PROXY_PORT` | `5096` |
| `CONTROL_PORT` | `19780` |
| `WANLING_ALLOW_ALL_USERS` | `true` |
| `WANLING_ALLOWED_USERS` | （空，逗号分隔白名单） |
| `WANLING_OWNER_USER_ID` | （空） |
| `WANLING_DEFAULT_DIRECTORY` | （空，默认工作目录） |

`--pair` 后会写入 `~/.config/opencode-wanling/config.json`，之后启动不再需要环境变量。

## 数据流

```
TUI ──attach:5096──► Adapter ──proxy──► OpenCode Serve ──► AI
                          │
                          └──WS──► 万灵 Server ◄── APP
```

TUI→APP：proxy 拦截 prompt，同步用户消息 + AI 回复到万灵。
APP→TUI：WS 收到消息，注入 OpenCode 会话，AI 回复回流。
