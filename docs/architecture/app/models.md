# APP Models

lib/models/ 数据模型。

## models 总览

`User`、`Agent`(含 `type` 字段 + **`multiSession bool?`**(server 按 type 注册表注入,011 起;null=老 server 缺字段,`isMultiSession` getter fallback `type=='opencode'` 旧口径)——一级列表点击路由依据:多 session → 二级 sessions 页,否则直进聊天窗)、`AgentSummary`(同口径 `multiSession`/`isMultiSession`,IM 列表行路由用)、`Conversation`(含 `lastMessagePreview({currentUserId, isGroup, senderDisplayName})` 方法,撤回分支按 sender_id == currentUserId 切「你/对方撤回了一条消息」+ 群聊场景预留 `xxx 撤回了一条消息` 扩展;老 server 不返 sender_id 时 fallback 无称谓)、`displayAvatarUrl` getter(**群聊场景只读会话级 `avatarUrl`**,无则空串走色块;**不读 otherUser.avatarUrl** —— server 群聊返的 otherUser 是「随机一个其他 participant」SQL `WHERE u.id != $1 LIMIT 1`,每个 user 看到不同,作群头像会乱;单聊保留 agent.avatarUrl ?? otherUser.avatarUrl ?? '' 优先级)、`sessionMeta` 字段(`SessionMeta?`,仅 agent_session 有值,server 从 `conversations.session_meta` JSONB 反序列化)、`Message`(`ChatMessage.fromJson` 识别 `content.msg_type=recalled` 自动置 `isRecalled=true`,单一真相源;含 `status` 字段 sending/sent/failed 三态,HTTP 同步发送链路用)、`WSMessage`、`Approval`、`Pairing`、`SavedLogin`、`AccountMark`、`UnreadInfo`(GET `/api/conversations/:id/unread` 响应模型,含 unread_count + first_unread_id + first_unread_created_at)、**`AgentTypeInfo`**(GET `/api/agent-types` 响应模型,type/multi_session/label/badge_bg/badge_bg_elevated/badge_fg;`fallbackTypes` 本地预置三类兜老 server)。**`SessionMeta`**(v1.0.9,agent_session 副标题数据源): `mode`(build/plan/general/explore) + `modelId` + `providerId` + `variant?` + `modelName?` + `providerName?` + `cwd?` + `gitBranch?`(后三个 v1.0.10 加,modelName/providerName 可读名由 plugin streamer.loadProviderNames 缓存后随 session-meta 一起写入,cwd/gitBranch 由 plugin vcs.get + vcs.branch.updated 同步;空串归一为 null;APP 副标题优先显示可读名,modelName/providerName 空时 fallback modelId/providerId)。v1.0.12 加 `tokensTotal`/`contextUsed`/`contextLimit`(int?,plugin 拉 OC `Session.tokens` 累计 + 本次 step_finish input+cache.read + `model.limit.context`),EnvMetaStrip 末尾渲染 `· {contextUsed} · {pct}%`(主数字为当前上下文占用,非累计 token;tokensTotal 字段保留传输供后续成本视图使用,不渲染),pct = contextUsed / contextLimit。旧 session_meta 缺三字段时为 null,token 段不渲染(向后兼容)

`MsgType` 枚举(`msg_type.dart`)— 集中定义所有 msg_type 枚举值 + `MsgTypeX` 扩展(`value` getter 序列化 + `fromString` 反序列化 + **`preview(type, data)` 统一消息预览纯函数**)。基础类型: text/markdown/image/file/mixed/card/recalled(隐式)。Agent 过程类型(v1.0.7): tuiUser/reasoning/toolCall/toolResult/toolError/subagent/question/stepFinish/fileDiff;后续新增 toolCard(v1.0.10,工具调用统一卡片)/permissionCard/permissionReply/questionCard/questionReply(v1.0.8)/slashEcho/compactDivider/unknown。`lastMessagePreview` 和 `ChatPage.isMe` 均通过 `MsgTypeX.fromString` 判断类型分流。**`MsgTypeX.preview`**(统一预览单一真相源,覆盖 23 种 msgType):text/markdown 截断 50 字符、image→`[图片]`、file→`[文件] {filename}`、card/mixed/agent 过程类型各有文案;**聚合卡预览**(`_aggregateCardPreview`):优先 server 写的 `data.preview`,无则扫描元素——pending 交互元素(permission_card/question_card,status 非终态)→ `⚡ 权限审批`/`❓ 选择题`,否则最后 markdown 正文,再无 fallback `[聚合回复]`;recalled **不在此处理**(msg_type='recalled' 不在枚举内,调用方独立判断撤回文案)。`notification_payload` 通知 body + `conversation.lastMessagePreview` 列表预览均切到此函数,避免两处文案漂移(返回 null 时前者 fallback「[新消息]」、后者 fallback 空串)

## RPC / 文件浏览 / 会话变更 model

- `RpcMethod`(`rpc_method.dart`)— plugin 上报的 RPC method 清单条目(`name` + `timeout_hint_ms`),`GET /api/agents/:id/rpc-methods` 响应用
- `FileEntry`(`file_entry.dart`)— RPC `file.list` 返回的目录条目(`name`/`type` dir|file/`size`/`binary?`),字母序目录优先
- `FileContent`(`file_content.dart`)— RPC `file.read` 返回值,按 `type` text|image|binary 分流(text 含 `content` 字符串,image 含 `content_base64`,binary 仅元信息)
- `SessionDiff`(`session_diff.dart`)— RPC `session.diff` 返回的文件变更条目(`file`/`patch`/`additions`/`deletions`/`status`),`SessionDiffStatus` 枚举 added/modified/deleted

## 好友 / 用户 / 会话参与 model

- `Participant`(`participant.dart`)— 会话参与者(`userId`/`memberType` user|agent/`role` owner|admin|member/`nickname`/`avatarUrl`),ConversationDetailPage 群成员列表用
- `Quote`(`quote.dart`)— 引用消息块(`messageId`/`preview`/`senderName`/`senderType`),嵌入 Message.content.data.quote
- `LoginResult` / `RegisterResult`(`login_result.dart` / `register_result.dart`)— 登录 / 注册响应封装(user + token pair)
- `SlashCommand`(`slash_command.dart`)— OC 命令 / 技能清单条目(`name`/`template`/`description?`/`source` command|skill/`hasArgs`),`GET /api/agents/:id/slash-catalog` 响应 + SlashCommandSheet 渲染用
- `Friendship` / `UserSummary`（`friendship.dart` / `user_summary.dart`）— **好友/用户搜索 model，UI 未开放代码保留**：好友关系 + 请求记录（`FriendshipStatus` 枚举）/ 用户摘要（id/username/nickname/avatarUrl）。待好友系统重新开放时启用

## 小程序 model

- `MiniProgramInfo`（`mini_program_info.dart`，wanling_core）— `GET /api/mini-programs` 响应条目（id/appid/ownerId/name/version/entry/icon/permissions/status/sha256/size），列表页分组（published=公共库）与容器页安装/校验用
