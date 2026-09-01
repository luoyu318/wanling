---
name: wanling-send-image
description: 当用户要求「发图片、发张图、把图片发给我、在对话里显示图片」或需要在万灵对话中输出图片时使用。适用于要把本地图片文件或远程图片 URL 发到万灵 APP 会话的场景（agent 在 opencode-plugin 环境下运行）。
---

# 万灵发图片

## 核心原理

万灵 APP 端 markdown 渲染只放行 `/api/files/` 前缀的内部 URL（SSRF 防护，网络图/本地路径都不显示）。

发图有三种形态，前两种由 `wanling_send_image` tool 按 agent 回合状态自动选择（无需人工判断），第三种为手动脚本方式：

| 形态 | 触发条件 | 命令 | 展示 | 适用 |
|---|---|---|---|---|
| **进聚合卡**（回合进行中自动） | 主会话有活跃聚合卡 | `wanling_send_image` tool | 图片作为 markdown 元素插入聚合卡内（footer 之前），实时出现在内容流中，**可点击放大**（经 sync 进程 control API，子 session 执行也能进对卡） | Agent 执行中发图，不打断实时内容流 |
| **独立图片消息**（无活跃卡退回） | 无活跃聚合卡 | `wanling_send_image` tool 或 `upload.py <file> <conv_id>` | APP 显示独立图片气泡，**可点击放大**（等价 agent WS `MESSAGE_CREATE` msg_type=image，经 REST `POST /api/conversations/:id/messages` SendAsAgent 实现） | 回合结束后发图 |
| **markdown 内嵌**（手动） | — | `upload.py <file>` | 图片嵌在正文/聚合卡 markdown 元素里，同样**可点击放大**（与独立图片消息同一画廊，Hero tag 同口径） | 图文同气泡的说明性插图 |

**注意**：聚合卡内 markdown 元素已原生支持 `/api/files/` 图片渲染 + 点击放大（从初始版本就有），早期「不可放大」的说法已过时。

## 实现步骤

### 首选：调用 `wanling_send_image` tool（推荐）

opencode 全局 plugin `~/.config/opencode/plugins/wanling-send-image.ts` 注册了 `wanling_send_image` 工具：

- 传入 `path`（本地图片绝对路径，可选 `alt` 说明文字），自动完成「换 JWT → 上传 → 进聚合卡/发独立图片消息」
- **形态自动选择**：上传后先尝试经 sync 进程 control API（`control.json` 发现信息）进主会话活跃聚合卡；无活跃卡或通道不可用自动退回独立图片消息
- **会话定位可靠**：进卡路径卡定位由 sync 进程完成（tool 传的 sessionID 仅日志参考，子 session 执行也能进对卡）；独立消息路径用 opencode 注入的 `sessionID` 反查 `session-maps.json`
- **套隔离精准**：读 serve 进程 env 的 `WANLING_CONFIG_DIR` 定位所属套（dev=`~/.config/opencode-wanling` / prod=`~/.config/opencode-wanling-prod`），不串发到另一套 server
- 调用后回复文字说明即可，**不要**再粘贴 markdown 引用（tool 返回文本里已含此提醒）

### 备用：脚本方式

conv_id 不可用时（如会话未映射）退化为脚本，需手动确定 conv_id：从 `~/.config/opencode-wanling/session-maps.json` 的 `maps` 里取 `lastSyncAt` 最新的 `wanlingConvId`（注意：多会话并发时该方式不可靠，优先用 `wanling_send_image` tool）。

### 1. 准备本地图片
- 支持扩展名白名单：`.jpg .jpeg .png .gif .webp .bmp`（server 校验，其余类型 415 拒绝）
- 大小上限 20MB
- 远程 URL 需先下载到本地（如 `curl -o /tmp/x.png <url>`）再上传

### 2. 运行上传脚本

独立图片消息（推荐，可放大）：
```bash
python3 ~/.opencode/skills/wanling-send-image/upload.py <本地图片路径> <conv_id>
```

markdown 内嵌：
```bash
python3 ~/.opencode/skills/wanling-send-image/upload.py <本地图片路径>
```

脚本从 `WANLING_CONFIG_DIR`（默认 `~/.config/opencode-wanling`）的 `config.json` 读取 agent 凭证，换 JWT 后 `POST /api/upload`，输出末行为 `![image](/api/files/{file_id})`。

### 3. 输出给用户

- **独立图片消息**：图片已直接出现在会话里，回复文字说明即可，**不要再**粘贴 markdown 引用（避免重复显示）
- **markdown 内嵌**：把脚本输出的 `![image](/api/files/{file_id})` 原样粘贴进回复文本，可改 alt 文本

## 凭证安全（强制）

- 脚本只读取、不打印 `secretKey` / `proxyPassword` / JWT
- 禁止把 secret 写进任何文件、提交、或回复内容
- 禁止读取 `.env` / `.yml` 等其他配置文件的密码

## 常见错误

| 症状 | 原因 | 处理 |
|---|---|---|
| 415 unsupported_media_type | 扩展名不在白名单 | 转成 png/jpg 再传 |
| 415 mime_mismatch | 内容与扩展名不符（改名图片） | 用真实格式的扩展名 |
| 413 payload_too_large | 超过 20MB | 压缩或缩放 |
| 上传成功但 APP 看不到图 | markdown 里写的是本地路径或网络 URL | 必须用 `/api/files/` 前缀 |
| 图片没进聚合卡（走了独立消息） | 无活跃聚合卡（回合已结束）/ sync 进程未落盘 `control.json`（旧版本）/ control 请求失败 | 属预期退回行为；若应进卡，确认 sync 进程为本版本并已重启 |
| 上传失败 | server 未启动 / 端口不对 | 确认当前套的端口（dev 18008 / prod 18010），`curl -sf http://localhost:<port>/health` |

## 验证

上传后确认可下载（应返回 200 且 Content-Type 为图片类型）：

```bash
python3 ~/.opencode/skills/wanling-send-image/upload.py --check <file_id>
```

`upload.py` 支持 `--check <file_id>` 子命令：自动换 token 后 `GET /api/files/:id`，打印 status / Content-Type / 字节数，非 200 或非图片类型则退出码非 0。