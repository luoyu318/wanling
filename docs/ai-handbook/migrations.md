# 数据库 Migration

万灵 PostgreSQL 单一 init 文件设计。本文件主要服务 server,APP 端必要时知道字段位置。被 server/CLAUDE.md @import 引用。

## 连接信息

PostgreSQL 跑在 docker 容器 `agent-postgres`(端口映射 6333:5432),用户/密码 `agent/agent123`。

```bash
# 建库（init_db.sh 只负责 CREATE DATABASE，不跑 migration）
./scripts/init_db.sh [host] [port] [user] [password] wanling

# 跑 migration（cmd/migrate 是唯一执行器，带版本表追踪）
cd server
go build -o /tmp/wanling-migrate ./cmd/migrate
/tmp/wanling-migrate --env=.env          # 应用全部未应用 migration
/tmp/wanling-migrate --env=.env --status # 查看已应用版本
```

## 文件结构

- `001_init.sql` — 完整最终 schema(用户/agent/会话/参与者/消息/投递/隐藏/文件/审批/票据 全部 12 张业务表 + 索引 + CHECK 约束)。历史 21 个 migration(001-021)已合并到本文件。
- `002_drop_agent_status.sql` — 删 agents.status 列(在线状态改走 Redis presence)。
- `003_agent_type_and_agent_session.sql` — agents.type 列 + conversations.type CHECK 增加 agent_session。
- `004_pairing_ticket_type.sql` — pairing_tickets.type 列,扫码配对透传 agent 类型标签。
- `005_session_meta.sql` — conversations 加 `session_meta JSONB`(nullable, schemaless),存 opencode agent_session 元数据。字段含 mode/model_id/provider_id/variant/model_name/provider_name(v1.0.9) + cwd/git_branch(v1.0.10,plugin vcs.get + vcs.branch.updated 同步)。由 plugin `session.updated` + `vcs.branch.updated` 事件驱动同步,APP 读渲染副标题 + 环境信息条。加字段无需 migration(JSONB schemaless)。
- `006_message_parent_root.sql` — messages 加 `parent_msg_id`/`root_msg_id` 列(UUID,FK→messages.id CASCADE),子 agent 事件树链;加 `idx_messages_root`(root_msg_id 非空部分索引)。
- `007_messages_parent_null_index.sql` — `idx_messages_parent_null`(conversation_id, created_at DESC) WHERE parent_msg_id IS NULL 部分索引,加速主列表 6+ 处查询的「仅顶层消息」过滤。
- `008_messages_main_stream.sql` — messages 加 `is_main_stream boolean` STORED 生成列 `(parent_msg_id IS NULL OR content->>'msg_type' IN ('permission_card','question_card'))`,收敛 22+ 处 SQL 的主对话流判据;替换 `idx_messages_parent_null` 为 `idx_messages_main_stream` WHERE is_main_stream。让子 agent 审批卡浮顶(可见+计未读+计入待办),同时保留 parent/root 供 ListByRoot 回溯。
- `009_conversation_directory.sql` — conversations 加 `directory TEXT`(nullable)。OC session 的物理工作目录固化在一级列,不再塞 session_meta JSONB(避免 server 整 JSON 覆盖写时与可变字段 mode/model/git_branch 互相覆盖)。写入时机:APP user 视角 `POST /api/conversations`(type=agent_session)传 directory,server CreateAgentSession 事务内写入。NULL = 用户选「默认」(plugin 用 OC 启动目录)。
- `010_approval_question.sql` — 审批卡 question 类型:approvals.card_type CHECK 放宽加 `question` + `decided_answers JSONB`(多选答案持久化;decisions 落库后 GET /api/approvals/:id 返回)。协议见 [approval-card.md](./approval-card.md)。
- `011_agent_type_registry.sql` — agent type 注册表:`agent_type_registry` 表(type PK / multi_session / label / badge_bg / badge_bg_elevated / badge_fg),server 统一下发类型属性,新类型 INSERT 一行即接入(APP 零发版)。预置 hermes/opencode/dsh 三行。拓扑判断(multi_session)驱动 APP 一级列表路由与会话列表 session 聚合;展示属性(label/badge 配色)供徽标与类型下拉。
- `012_mini_programs.sql` — 小程序注册表:appid 唯一/owner/版本/jsonb manifest/sha256/size/状态机(private→published⇄disabled)。两层模型:用户上传即私有,管理员 publish 上公共库
- `013_miniprogram_signature.sql` — 小程序包签名(M3):mini_programs 加 `signature TEXT`(NULL=未签,publish 时 ed25519 签名)+ `mp_signing_key` 单行表(密钥对,私钥永不出 server)。协议见 [miniprogram.md](./miniprogram.md)
- `014_users_role.sql` — role 一等公民化:users 加 `role varchar(16)`(CHECK ∈ {user, admin},默认 user),DB 为准(env ADMIN_USERNAMES 启动种子)
- `015_mini_program_openids.sql` — 小程序 openid 身份体系:`mini_program_openids` 表((user_id, appid) PK → openid 默认 gen_random_uuid(),UNIQUE(openid)),(用户×appid) 惰性生成永久稳定标识,跨小程序不可关联。协议见 [miniprogram.md](./miniprogram.md)
- `016_agent_sub_keys.sql` — agent 子密钥授权:`agent_sub_keys` 表(id/agent_id/secret_key UNIQUE/last_used_at/revoked_at,详见 [agent-subkeys.md](./agent-subkeys.md))+ `pairing_tickets` 加 `action TEXT NOT NULL DEFAULT 'bind'` 列(扫码配对 bind/authorize 双模式)。
- `017_pairing_ticket_secret_key_text.sql` — `pairing_tickets.secret_key` VARCHAR(64)→TEXT:authorize 模式票据凭据是子密钥(`wlsk_`+64hex=69 字符),原列超长报错。
- `018_agent_sub_keys_fk_cascade.sql` — `agent_sub_keys.agent_id` 外键改 `ON DELETE CASCADE`:016 默认 NO ACTION,硬删发过子密钥的 agent 会 FK 违规并阻断 users 级联链;agent 删除时子密钥行随删。

新 migration 文件命名:`NNN_<feature>.sql`(NNN 递增,如 `005_add_xxx.sql`),不要修改 001_init.sql(会让已部署实例无法重跑 init)。

## 表清单

| 表 | 用途 |
|---|---|
| users | 用户(name/password_hash/avatar_url/nickname/bio/role,014) |
| agents | Agent(owner_id/name/avatar_url/secret_key/bio/type) |
| friendships | 好友关系(user_id+friend_id 双向) |
| conversations | 会话(type/title/avatar_url/session_meta/directory;无 user_id/agent_id/last_message_*) |
| conversation_participants | N 方参与者模型(per-member 维度:unread_count/pin/hide/role) |
| messages | 消息(content JSONB;deleted_at 撤回) |
| message_deliveries | per-recipient 投递状态(read_at) |
| message_hidden | per-participant 单向隐藏 |
| files | 文件(owner_id/path/thumbnail_*) |
| file_conv_links | 文件↔会话 N:N 授权(四档放行用) |
| approvals | 审批卡片(initiator/decider 通用字段) |
| pairing_tickets | 扫码配对票据(5min TTL,非业务表;action bind/authorize,016) |
| agent_type_registry | agent type 注册表(type → multi_session/label/badge 配色,011) |
| agent_sub_keys | agent 子密钥(wlsk_ 前缀,REST-only 授权,last_used_at/revoked_at,016) |
| mini_programs | 小程序注册表(appid 唯一 → owner/版本/manifest/sha256/状态/signature,012/013) |
| mp_signing_key | 小程序包签名密钥单行表(ed25519 私钥+公钥,013) |
| mini_program_openids | 小程序 openid((user_id, appid) PK → 永久稳定 openid,015) |

## 关键设计

- **participants 模型**:conversations 表只持有会话维度字段(type/title/avatar),per-member 维度(unread_count/pin/hide/role)下沉到 conversation_participants 表
- **双轨制删除**:messages.deleted_at 是全局软删(撤回,双向不可见);message_hidden 表存 per-participant 单向隐藏(对自己隐藏)
- **未读计数**:基于 message_deliveries 表(read_at IS NULL)实时算,不维护缓存字段
- **文件四档放行**:`FileRepo.CheckAccess` (1) owner 校验 (2) 头像白名单 (3) file_conv_links JOIN participants (4) 拒绝
- **审批 participants 化**:approvals 表用 initiator_*/decider_* 通用字段,支持群聊场景

## CHECK 约束

枚举字段在 DB 层强制(防 future 误写,fail-fast):

- `agents.type` ∈ VARCHAR(32) DEFAULT ''（无 DB CHECK，业务层约束；空串=普通 agent，`opencode`=OpenCode agent）
- `pairing_tickets.action` ∈ TEXT DEFAULT 'bind'（无 DB CHECK，业务层白名单 `bind`/`authorize`，未知值 400，016）
- `conversations.type` ∈ {dm_user_agent, dm_user_user, group_user, group_mixed, agent_session}
- `conversation_participants.role` ∈ {owner, admin, member}
- `conversation_participants.member_type` ∈ {user, agent}
- `messages.sender_type` ∈ {user, agent}
- `message_deliveries.recipient_type` ∈ {user, agent}
- `message_hidden.member_type` ∈ {user, agent}
- `friendships.status` ∈ {pending, accepted, rejected, canceled}
- `approvals.card_type` ∈ {command, tool, file, slash_confirm}
- `approvals.state` ∈ {pending, approved, denied, expired}
- `approvals.initiator_type` ∈ {user, agent}
- `approvals.decider_type` ∈ NULL ∪ {user, agent}
- `pairing_tickets.status` ∈ {pending, scanned, completed, expired}

## 后续 schema 变更

如果未来需要修改 schema,**新增 NNN_xxx.sql**(不要修改 001_init.sql,会让已部署实例无法重跑 init)。

测试:`internal/repository/testdb.go` 的 `SetupTestDB` 自动按文件名序跑全部 migration,无需调整。

## 已删字段(供后续 reference)

如需 reference 历史 schema 演进,见 git log 中已删除的 migration 文件(001-021)。本文件不再列出已删字段细节。
