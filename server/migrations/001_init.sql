-- 万灵数据库 init
--
-- 创建顺序: EXTENSION → TABLE → INDEX
-- 测试见 internal/repository/testdb.go 的 SetupTestDB

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ========== 用户 / Agent ==========

CREATE TABLE users (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username      VARCHAR(64) NOT NULL UNIQUE,
    password_hash VARCHAR(256) NOT NULL,
    avatar_url    VARCHAR(256) DEFAULT '',
    nickname      VARCHAR(64) DEFAULT NULL,              -- 005:展示昵称,空时回退 username
    bio           VARCHAR(200) DEFAULT NULL,             -- 005:个人简介
    created_at    TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE agents (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name       VARCHAR(128) NOT NULL,
    avatar_url VARCHAR(256) DEFAULT '',
    secret_key VARCHAR(64) NOT NULL,
    bio        VARCHAR(200) DEFAULT NULL,                -- 005:agent 简介
    status     VARCHAR(16) DEFAULT 'offline'
               CHECK (status IN ('online', 'offline', 'busy')),  -- 020 CHECK
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 015: friendships(N 方参与者模型的好友关系,独立于 participants 表)
CREATE TABLE friendships (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    friend_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status       VARCHAR(16) NOT NULL CHECK (status IN ('pending', 'accepted', 'rejected', 'canceled')),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    responded_at TIMESTAMPTZ,
    UNIQUE(user_id, friend_id)
);
CREATE INDEX idx_friendships_friend_status ON friendships(friend_id, status);
CREATE INDEX idx_friendships_user_status   ON friendships(user_id, status);

-- ========== 会话 ==========

-- 015/017 后:conversations 不再持有 user_id/agent_id/last_message_at/last_message_content/hidden_at/pinned_at
-- 改由 conversation_participants 表持有个人维度(unread/pin/hide),last_message 走子查询实时算
CREATE TABLE conversations (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    type       VARCHAR(32) NOT NULL DEFAULT 'dm_user_agent'
               CHECK (type IN ('dm_user_agent', 'dm_user_user', 'group_user', 'group_mixed')),  -- 015 + 020 CHECK
    title      VARCHAR(128),                            -- 015:群聊用
    avatar_url VARCHAR(256),                            -- 015:群聊用
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 015: N 方参与者通用模型。每行 = 一个 member(user/agent) 在一个会话里的个人维度状态
CREATE TABLE conversation_participants (
    conv_id              UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    member_id            UUID NOT NULL,
    member_type          VARCHAR(16) NOT NULL CHECK (member_type IN ('user', 'agent')),
    role                 VARCHAR(16) NOT NULL DEFAULT 'member'
                         CONSTRAINT conv_participants_role_check CHECK (role IN ('owner', 'admin', 'member')),  -- 020 CHECK
    unread_count         INTEGER NOT NULL DEFAULT 0,
    last_read_message_id UUID,
    joined_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    hidden_at            TIMESTAMPTZ,
    pinned_at            TIMESTAMPTZ,
    PRIMARY KEY (conv_id, member_id, member_type)
);
CREATE INDEX idx_participants_member ON conversation_participants(member_id, member_type);

-- ========== 消息 ==========

CREATE TABLE messages (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    sender_type    VARCHAR(16) NOT NULL CHECK (sender_type IN ('user', 'agent')),
    sender_id      UUID NOT NULL,
    content        JSONB NOT NULL,
    deleted_at     TIMESTAMPTZ,                          -- 006:非空=撤回(全局软删,双向不可见)
    created_at     TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
-- 012:游标分页(ListBefore/ListAfter)专用复合索引
CREATE INDEX idx_messages_conv_created ON messages(conversation_id, created_at DESC);
-- 006 partial:会话消息列表查询过滤软删消息
CREATE INDEX idx_messages_conv_not_deleted
    ON messages(conversation_id, created_at)
    WHERE deleted_at IS NULL;

-- 015: per-recipient 投递状态(read_at IS NULL = 未读)
CREATE TABLE message_deliveries (
    message_id     UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    recipient_id   UUID NOT NULL,
    recipient_type VARCHAR(16) NOT NULL CHECK (recipient_type IN ('user', 'agent')),
    read_at        TIMESTAMPTZ,
    PRIMARY KEY (message_id, recipient_id, recipient_type)
);
CREATE INDEX idx_deliveries_unread
    ON message_deliveries(recipient_id, recipient_type)
    WHERE read_at IS NULL;

-- 016: per-participant 单向隐藏(对自己隐藏,不影响他人)
CREATE TABLE message_hidden (
    message_id  UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    member_id   UUID NOT NULL,
    member_type VARCHAR(16) NOT NULL CHECK (member_type IN ('user', 'agent')),
    hidden_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (message_id, member_id, member_type)
);
CREATE INDEX idx_message_hidden_member ON message_hidden(member_id, member_type);

-- ========== 文件 ==========

CREATE TABLE files (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    filename       VARCHAR(256) NOT NULL,
    mime_type      VARCHAR(128) NOT NULL,
    size           BIGINT NOT NULL,
    storage_path   VARCHAR(512) NOT NULL,
    thumbnail_path VARCHAR(512),                         -- 011:缩略图路径,可空
    width          INT,                                  -- 011:原图宽度
    height         INT,                                  -- 011:原图高度
    created_at     TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 018: 文件↔会话 N:N 授权(下载走四档放行:owner / 头像白名单 / file_conv_links+participant)
CREATE TABLE file_conv_links (
    file_id    UUID NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    conv_id    UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (file_id, conv_id)
);
CREATE INDEX idx_file_conv_links_conv ON file_conv_links(conv_id);
CREATE INDEX idx_file_conv_links_file ON file_conv_links(file_id);

-- ========== 审批 ==========

-- 008/009/010/021 合并:审批卡片表(participants 化,initiator/decider 通用字段)
CREATE TABLE approvals (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id      UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,

    -- 021: participants 化(替代旧 agent_id/user_id 二元字段,支持群聊场景)
    initiator_type  VARCHAR(16)
                    CHECK (initiator_type IN ('user', 'agent')),     -- 021 CHECK
    initiator_id    UUID,                                           -- 卡片发起方(当前仅 agent)
    decider_type    VARCHAR(16)
                    CHECK (decider_type IS NULL OR decider_type IN ('user', 'agent')),  -- 021 CHECK
    decider_id      UUID,                                           -- 决策方(pending 时 NULL)

    -- 008 卡片基础字段
    card_type       TEXT NOT NULL CHECK (card_type IN ('command', 'tool', 'file', 'slash_confirm')),
    state           TEXT NOT NULL DEFAULT 'pending'
                    CHECK (state IN ('pending', 'approved', 'denied', 'expired')),
    actions         JSONB NOT NULL,
    decided_action  TEXT,
    decided_by      UUID REFERENCES users(id),
    decided_reason  TEXT,
    decided_at      TIMESTAMPTZ,
    expires_at      TIMESTAMPTZ NOT NULL,
    session_key     TEXT NOT NULL,
    allow_pattern   TEXT,
    confirm_id      TEXT,                                            -- 009:slash_confirm 类型用
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_approvals_pending_expires
    ON approvals(expires_at) WHERE state = 'pending';
CREATE INDEX idx_approvals_message
    ON approvals(message_id);
-- 021: initiator 维度索引(替代旧 conv_agent_pattern,因为 agent_id 已 DROP)
CREATE INDEX idx_approvals_pending_initiator
    ON approvals(initiator_id, initiator_type) WHERE state = 'pending';
CREATE INDEX idx_approvals_conv_initiator_pattern
    ON approvals(conversation_id, initiator_id, allow_pattern)
    WHERE state = 'approved' AND allow_pattern IS NOT NULL;

-- ========== 配对票据 ==========

-- 007: 扫码配对票据表(非业务表,仅握手用,5min TTL,secret_key 领完即焚)
CREATE TABLE pairing_tickets (
    id           VARCHAR(64) PRIMARY KEY,                              -- 256-bit hex
    status       VARCHAR(16) NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'scanned', 'completed', 'expired')),  -- 020 CHECK
    user_id      UUID,                                                 -- scanned 后写入扫码用户
    agent_id     UUID,                                                 -- completed 后写入被绑定 agent
    secret_key   VARCHAR(64),                                          -- completed 后短暂存凭据
    created_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    scanned_at   TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE
);
CREATE INDEX idx_pairing_tickets_created_at ON pairing_tickets(created_at);
