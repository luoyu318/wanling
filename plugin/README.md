# Wanling 插件

万灵（Wanling）IM 平台的插件集合。每个子目录是一个独立插件。

当前插件：
- [`hermes-plugin/`](./hermes-plugin/) — hermes agent 接入插件（WebSocket 协议）

## 一键安装

```bash
curl -fsSL https://gitee.com/luoyu318/wanling-plugin/raw/main/install-remote.sh | \
  bash -s -- --server=https://your.server.com --agent-id=YOUR_AGENT_ID --secret-key=YOUR_SECRET_KEY
```

多插件场景指定插件名（默认 `hermes-plugin`）：

```bash
curl -fsSL https://gitee.com/luoyu318/wanling-plugin/raw/main/install-remote.sh | \
  bash -s -- --plugin=openclaw-plugin --server=... --agent-id=... --secret-key=...
```

参数说明（全部透传给插件的 install.sh）：
- `--plugin=NAME`：插件名，默认 `hermes-plugin`
- `--server=URL`：wanling server 地址（必填）
- `--agent-id=UUID`：agent ID（必填）
- `--secret-key=KEY`：agent 密钥（必填）
- `--home-user=UID`：可选，cron 投递目标用户
- `--profile=NAME`：可选，装到指定 hermes profile
- `--register`：可选，自动在 server 注册新 agent（需 `--user-token`）

交互式安装（不带参数，会逐个问）：

```bash
curl -fsSL https://gitee.com/luoyu318/wanling-plugin/raw/main/install-remote.sh | bash
```

装完后重启 hermes gateway：

```bash
hermes gateway restart
```

## 扫码配对（推荐，无需 user token）

用万灵 app 扫码授权，hermes 终端自动拿凭据完成配置。相比上面的"一键安装"，扫码配对**不需要提前在 app 里复制 agent_id/secret_key**，也**不需要粘 user token**。

### 本地已 clone 镜像 repo

```bash
./install.sh --pair
./install.sh --pair --server=https://your.server.com --profile=heiyu
```

### 远程一键（curl | bash）

```bash
curl -fsSL https://gitee.com/luoyu318/wanling-plugin/raw/main/install-remote.sh | \
  bash -s -- --pair --server=https://your.server.com
```

> ⚠️ 远程方式**必须显式传 `--server=`**：`curl | bash` 下 stdin 是管道不是终端，install.sh 无法交互式询问 server URL。其他参数（`--profile=` 等）可按需追加。

### 流程

1. 脚本让你输入 server URL（或用 `--server=` 传参；远程方式必须传）
2. 终端打印二维码（需 `qrencode` 或 `python3+qrcode`，缺失时打印纯文本配对码）
3. 用万灵 app：「万灵」tab 右上角 `+` → 扫一扫，扫描终端二维码
4. 在 app 内选已有 Agent（会重置密钥使旧 hermes 失效）或新建
5. hermes 终端自动轮询拿凭据并完成配置（含 `home_user` 自动同步）

凭据仅在配对时短暂落盘，hermes 端领取后立即清空（领完即焚）；5 分钟内未完成自动过期。

## 更新插件

```bash
# 同步最新代码到所有已装位置（不动配置）
curl -fsSL https://gitee.com/luoyu318/wanling-plugin/raw/main/install-remote.sh | \
  bash -s -- --update
```

## 前置要求

- 已安装 hermes-agent
- 已在 wanling server 注册 agent（拿到 agent_id + secret_key）

## 更多用法

```bash
curl -fsSL https://gitee.com/luoyu318/wanling-plugin/raw/main/install-remote.sh | \
  bash -s -- --help
```
