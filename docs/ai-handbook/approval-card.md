# 审批卡片

万灵审批卡片设计: agent 执行敏感操作前发卡片让 user 决策。本文件被 server / app / plugin 子 CLAUDE.md 通过 @import 引用。

Agent 执行敏感操作（危险命令 / 工具调用 / 文件操作 / 破坏性 slash 命令）前，发审批卡片到对话让 user 按钮决策，替代纯文本审批。

**两类审批通道**（对应 hermes 两个跨平台契约方法）：

| 通道 | 触发场景 | adapter 方法 | hermes resolve 原语 | action_id |
|---|---|---|---|---|
| exec_approval | 危险命令 / 工具 / 文件 | `send_exec_approval` | `tools.approval.resolve_gateway_approval(session_key, choice)` | allow_once/allow_always/deny |
| slash_confirm | /new /clear /reset /undo | `send_slash_confirm` | `tools.slash_confirm.resolve(session_key, confirm_id, choice)` | once/always/cancel |
| question | agent 向 user 提选择题 | `POST /api/conversations/:id/approvals`(card_type=question) | —（走 APPROVAL_DECIDED 事件） | answer/reject |

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
- server：审批表在 `migrations/001_init.sql`（历史 migration 已合并）+ `010_approval_question.sql`（question 类型）、`model/approval.go`、`repository/approval_repo.go`、`approval/service.go`、`approval/cleanup.go`、`hub/dispatch.go`、`handler/approval_handler.go`（+ `conversation_agent.go` 的 `CreateAsAgent`）
- app：`models/approval.dart`、`rendering/card_renderer.dart`、`widgets/card_button.dart`/`card_state_badge.dart`/`countdown_timer.dart`、`chat_provider.dart`（处理 MESSAGE_UPDATE）+ `api_service.dart`（decideApproval）+ `websocket_service.dart`（messageUpdates stream）
- plugin：`adapter.py` 的 `send_exec_approval`/`send_slash_confirm` + `_on_approval_decided`/`_on_approval_expired`(conv-id-routing 迁移后已删 `_resolve_conv_id`,所有 WS payload 走 `{conversation_id, content}` 单轨,`chat_id = conversation_id`)。**adapter WS 协议对齐**：握手必须先 Identify（server ws_handler 强制首条 Identify），注册成功后再发 OpResume（`_last_seq>0` 时）补发断线期间 dispatch；`message_id` 用 `uuid.uuid4().hex[:12]`（不用时间戳，防跨客户端冲突）。

## question 类型（选择题卡片）

agent 需要用户在给定选项中做选择时使用（如部署环境二选一），复用 approvals 状态机通道，migration `010_approval_question.sql`（card_type CHECK 放宽 + `decided_answers JSONB`）。

**建卡**：`POST /api/conversations/:id/approvals` 带 `card_type:"question"` + `options:[{id,label}]`（非空、id 唯一非空，handler 校验 400）+ `multi_select:bool`；options/multi_select 双写进 messages.content.data（APP 渲染单选/多选）。可选 `preview`/`preview_language`/`meta:[{icon,text,warn}]`（meta 行随卡下发展示，如权限决策说明）。

**决策**：`POST /api/approvals/:id/decide` body `{action_id:"answer"|"reject", reason?, answers?:[option_id...]}`。answer 时 answers 逐项 ∈ options（越界 400 invalid_action）、单选限 1 项（空/多选超限 400）；reject 不需要 answers。answers 落 `approvals.decided_answers` + 双写 content.data.answers（APP 终态回显所选选项）。乐观窗口：APP 点提交先本地渲染终态，MESSAGE_UPDATE 到达校验不一致则回退本地已选。

**事件/查询**：APPROVAL_DECIDED payload 带 `answers`（question 为选项 id 数组，其余类型 null）；`GET /api/approvals/:id` 返回 `decided_answers`（agent 断线重连兜底查询用）。

**终态映射**：deny（exec）/ cancel（slash_confirm）/ reject（question）统一映射 `denied`——cancel 由 repo MarkDecided 映射（缺陷修复 A），APPROVAL_DECIDED 的 decision 字段保留原始 action_id。

## 三存量缺陷修复（2026-08-22）

- **cancel 映射**：repo MarkDecided 补 cancel→denied 映射（此前 cancel 决策落库 state 错误）
- **白名单收窄**：非 allow_always 决策显式清 `allow_pattern`（repo 层 NULLIF 防残留污染）+ `MatchAllowPattern` 加 `decided_action='allow_always'` 条件（历史 deny 但 pattern 残留行不再命中 auto_approved）
- **expired 双写**：`MarkExpired` 复用 Decide 终态路径——双写 messages.content（state=expired）+ 广播 MESSAGE_UPDATE（APP 卡片不再停留 pending）；APPROVAL_EXPIRED 仍由 cleanup goroutine 发

## SDK 高层封装

`Approvals.ask(convId, opts)`（TS/Python 对称，`client.approvals`）：createApproval 建卡 → 监听 APPROVAL_DECIDED/EXPIRED 按 approval_id 匹配 → Promise 决议 `{state: approved|denied|expired, decision, answers?}`；超时本地兜底（server 超时 + 5s 余量）、断线重连后 `resync()` 对未决项逐个 GET 兜底。见 `sdk/CLAUDE.md`。
