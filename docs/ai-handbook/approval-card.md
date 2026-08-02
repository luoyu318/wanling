# 审批卡片

万灵审批卡片设计: agent 执行敏感操作前发卡片让 user 决策。本文件被 server / app / plugin 子 CLAUDE.md 通过 @import 引用。

Agent 执行敏感操作（危险命令 / 工具调用 / 文件操作 / 破坏性 slash 命令）前，发审批卡片到对话让 user 按钮决策，替代纯文本审批。

**两类审批通道**（对应 hermes 两个跨平台契约方法）：

| 通道 | 触发场景 | adapter 方法 | hermes resolve 原语 | action_id |
|---|---|---|---|---|
| exec_approval | 危险命令 / 工具 / 文件 | `send_exec_approval` | `tools.approval.resolve_gateway_approval(session_key, choice)` | allow_once/allow_always/deny |
| slash_confirm | /new /clear /reset /undo | `send_slash_confirm` | `tools.slash_confirm.resolve(session_key, confirm_id, choice)` | once/always/cancel |

**决策回传链路**（agent 不在 send_* 方法内等决策，立即返回 success）：
1. agent 调 send_* → 万灵 server 创建审批卡片（落 messages + approvals）+ 广播 MESSAGE_CREATE
2. APP 渲染卡片 + 按钮 + 倒计时，user 点按钮 → `POST /api/approvals/:id/decide`
3. server service.Decide 推进状态机 + 双写 content + 广播 MESSAGE_UPDATE（双端切终态）+ APPROVAL_DECIDED（仅 agent）
4. hermes plugin `_on_approval_decided` 按 decision 分流：once/always/cancel → `slash_confirm.resolve(session_key, confirm_id, choice)`；allow_once/allow_always/deny → `resolve_gateway_approval(session_key, choice)`，唤醒 hermes 等待队列

**关键设计**：
- **立即返回**：send_exec_approval/send_slash_confirm 发卡片后立即返回 success=True，**不 await user 决策**（hermes gateway 调用有 15s timeout，await 会被杀掉走文本兜底）。决策由 APPROVAL_DECIDED 事件异步唤醒 hermes。
- **state 双写**：approvals.state + messages.content.data.state 双写，IM 列表/聊天渲染只读 messages 不 JOIN。
- **会话级白名单**（仅 exec_approval 的 command + allow_always）：写 `approvals.allow_pattern`，下次同会话同 agent 发同 pattern 命令时 server 命中返 auto_approved 直接放行。`*`→`%`/`?`→`_` LIKE 匹配，大小写敏感（对齐 shell）。
- **slash_confirm 的 always 语义不同**：不是会话白名单，而是 hermes 端持久化 `approvals.destructive_slash_confirm: false`（关掉这类命令的确认），由 hermes 在 `_on_confirm` handler 里处理，**不写 allow_pattern**。
- **超时**：5 分钟，独立 expired 终态。`approval.RunCleanup` 后台 goroutine 每 1 分钟扫 pending + expires_at < now → MarkExpired + 广播 APPROVAL_EXPIRED。hermes 端通过自己的 approval/slash_confirm queue 管理 timeout，APPROVAL_EXPIRED 主要用于本地状态可视化。

**新增组件**：
- server：审批表在 `migrations/001_init.sql`（原 008/009/010 已合并）、`model/approval.go`、`repository/approval_repo.go`、`approval/service.go`、`approval/cleanup.go`、`hub/dispatch.go`、`handler/approval_handler.go`（+ `conversation_agent.go` 的 `CreateAsAgent`）
- app：`models/approval.dart`、`rendering/card_renderer.dart`、`widgets/card_button.dart`/`card_state_badge.dart`/`countdown_timer.dart`、`chat_provider.dart`（处理 MESSAGE_UPDATE）+ `api_service.dart`（decideApproval）+ `websocket_service.dart`（messageUpdates stream）
- plugin：`adapter.py` 的 `send_exec_approval`/`send_slash_confirm` + `_on_approval_decided`/`_on_approval_expired`(conv-id-routing 迁移后已删 `_resolve_conv_id`,所有 WS payload 走 `{conversation_id, content}` 单轨,`chat_id = conversation_id`)。**adapter WS 协议对齐**：握手必须先 Identify（server ws_handler 强制首条 Identify），注册成功后再发 OpResume（`_last_seq>0` 时）补发断线期间 dispatch；`message_id` 用 `uuid.uuid4().hex[:12]`（不用时间戳，防跨客户端冲突）。
