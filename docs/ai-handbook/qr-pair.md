# 扫码配对

万灵扫码配对: hermes 终端扫码授权链路。本文件被 server / app / plugin 子 CLAUDE.md 通过 @import 引用。

hermes 终端 `./install.sh --pair` 生成授权二维码 → 万灵 app「万灵」tab 右上角 `+` → 扫一扫 → 选/建 Agent → hermes 终端自动拿到凭据完成配置。**无需 user token**，是 `--register` 的扫码升级版（`--register` 仍保留给自动化脚本）。

**三方握手**（hermes 终端 / 万灵 server / 万灵 app）：
1. hermes 端 `install.sh --pair` 输入 server URL → `POST /api/pair/tickets`(body 可选 `{type}` 声明 agent 类型,如 `opencode`,默认空串=普通 agent)→ 生成 ticket（256-bit hex，TTL 5min）→ 终端打印 ASCII 二维码（内容 `WLPAIR:<ticket_id>`，qrencode → python3+qrcode → 纯文本三级兜底）
2. 万灵 app 扫码（`mobile_scanner`，`ScanPairPage`）→ `POST /api/pair/tickets/:id/scan`（user JWT）回显该 user 名下 agent 列表
3. app 在 `PairSelectAgentPage` 选已有 agent（三选弹窗：**授权**=发子密钥不碰主密钥 / **接管**=重置密钥红字警示 / 取消）或新建 → `POST /api/pair/tickets/:id/complete`。complete 请求体可选 `action`（缺省 `bind`=接管现状语义;`authorize`=给已有 agent 发子密钥）+ `note`（子密钥备注,缺省「技能授权」）。新建分支读 `ticket.type` 建 agent,实现 agent 类型标签全链路透传(opencode agent 扫码配对后 APP 可识别)。
4. hermes 端 2s 短轮询 `GET /api/pair/tickets/:id`，completed 时拿凭据(`agent_id` / `secret_key` / `owner_user_id` / `owner_conv_id`,响应统一带 `action` 字段),**领完即焚**（secret_key 领走后清空）。`owner_conv_id` 写入 `.env` `WANLING_HOME_CONV`,adapter 启动直接读,无需手动 find_or_create。

**关键设计**：
- **覆盖语义无状态**：选任意已有 agent 都重置 secret_key 使旧 hermes 失效，**不存绑定表**（`agents` 表不加字段）。票据表 `pairing_tickets` 仅握手用，非业务表。
- **authorize 授权模式（子密钥）**：complete 带 `action:"authorize"` 时**不重置主密钥**，给已有 agent 发 `wlsk_` 子密钥（仅 REST、可单独吊销），原绑定不受影响——技能等纯 REST 消费方用此模式避免踢掉宿主适配器。authorize 分支轮询响应无 `owner_conv_id`。协议细节、错误码与 WS 拦截见 **[agent-subkeys.md](./agent-subkeys.md)**。
- **鉴权**：hermes 端只凭 ticket_id（不可猜），app 端走 user JWT。scan 与 complete 校验同一 user，防 A 扫码 B complete。
- **限流**：`GET /tickets/:id` 按 IP 60/min（防枚举），`complete` 按 user 10/min。Redis 可用时走 Redis，否则内存降级。
- **票据清理**：`pair.RunCleanup` 后台 goroutine 每 10 分钟删 1 小时前的票据。

**新增组件**：
- server：配对票据表在 `migrations/001_init.sql`（原 `007_pairing_tickets.sql` 已合并）、`model/pairing_ticket.go`、`repository/pairing_repo.go`、`handler/pairing_handler.go`、`ratelimit/middleware.go`、`pair/cleanup.go`
- app：`pages/scan_pair_page.dart`、`pages/pair_select_agent_page.dart`、`models/pairing.dart`
