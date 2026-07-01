-- 015: participants 模型重构
-- 把 user↔agent 1-1 模型抽象为 N 方 participants 通用模型
-- 一次性切换(无 DOWN),执行前请手动 pg_dump 备份
--
-- 回填顺序(不可乱,见 docs/superpowers/specs/2026-07-02-participants-model-refactor-design.md §2):
--   ① 新表 + conversations 加字段
--   ② 老 conversations → participants(下沉 hidden_at/pinned_at 个人维度)
--   ③ 老 messages → deliveries(is_read=TRUE→read_at=created_at, FALSE→read_at=NULL)
--   ④ 回填 participants.unread_count per member
--   ⑤ 最后 DROP 老字段 / 索引(回填完成后,不依赖老字段)
--   ⑥ 重建查询索引

-- === 1. 新表 ===

CREATE TABLE conversation_participants (
    conv_id             UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    member_id           UUID NOT NULL,
    member_type         VARCHAR(16) NOT NULL CHECK (member_type IN ('user', 'agent')),
    role                VARCHAR(16) NOT NULL DEFAULT 'member',
    unread_count        INTEGER NOT NULL DEFAULT 0,
    last_read_message_id UUID,
    joined_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    hidden_at           TIMESTAMPTZ,
    pinned_at           TIMESTAMPTZ,
    PRIMARY KEY (conv_id, member_id, member_type)
);
CREATE INDEX idx_participants_member ON conversation_participants(member_id, member_type);

CREATE TABLE message_deliveries (
    message_id      UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    recipient_id    UUID NOT NULL,
    recipient_type  VARCHAR(16) NOT NULL CHECK (recipient_type IN ('user', 'agent')),
    read_at         TIMESTAMPTZ,
    PRIMARY KEY (message_id, recipient_id, recipient_type)
);
CREATE INDEX idx_deliveries_unread ON message_deliveries(recipient_id, recipient_type) WHERE read_at IS NULL;

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

-- === 2. conversations 表加字段 ===

ALTER TABLE conversations ADD COLUMN title VARCHAR(128);
ALTER TABLE conversations ADD COLUMN avatar_url VARCHAR(256);
ALTER TABLE conversations ADD COLUMN type VARCHAR(32) NOT NULL DEFAULT 'dm_user_agent';

-- === 3. 数据回填(必须在 DROP 老字段前) ===

-- 3.1 老 conversations → participants(下沉 hidden_at/pinned_at 个人维度)
INSERT INTO conversation_participants (conv_id, member_id, member_type, role, hidden_at, pinned_at)
SELECT id, user_id, 'user', 'owner', hidden_at, pinned_at FROM conversations WHERE user_id IS NOT NULL;

INSERT INTO conversation_participants (conv_id, member_id, member_type, role)
SELECT id, agent_id, 'agent', 'member' FROM conversations WHERE agent_id IS NOT NULL;

-- 3.2 老 messages → deliveries
--     旧 is_read=TRUE 的 → recipient 行 read_at=created_at(视为已读)
--     旧 is_read=FALSE 的 → recipient 行 read_at=NULL(未读)
--     recipient = 该会话所有 non-sender participants
--     过滤软删消息(deleted_at IS NOT NULL),避免已删消息污染 unread_count
INSERT INTO message_deliveries (message_id, recipient_id, recipient_type, read_at)
SELECT m.id, p.member_id, p.member_type,
       CASE WHEN m.is_read = TRUE THEN m.created_at ELSE NULL END
FROM messages m
JOIN conversation_participants p ON p.conv_id = m.conversation_id
WHERE NOT (p.member_id = m.sender_id AND p.member_type = m.sender_type)
  AND m.deleted_at IS NULL;

-- 3.3 回填 unread_count per participant
UPDATE conversation_participants p SET unread_count = COALESCE(sub.cnt, 0)
FROM (
  SELECT recipient_id, recipient_type, COUNT(*) AS cnt
  FROM message_deliveries WHERE read_at IS NULL
  GROUP BY recipient_id, recipient_type
) sub
WHERE p.member_id = sub.recipient_id AND p.member_type = sub.recipient_type;

-- === 4. DROP 老字段 / 索引(回填完成后) ===

-- partial index 依赖 is_read,必须先于 DROP COLUMN is_read 删
DROP INDEX IF EXISTS idx_messages_conv_unread;
DROP INDEX IF EXISTS idx_conversations_user_id;
DROP INDEX IF EXISTS idx_conversations_agent_id;

ALTER TABLE conversations DROP CONSTRAINT IF EXISTS conversations_user_id_agent_id_key;
ALTER TABLE conversations DROP COLUMN user_id;
ALTER TABLE conversations DROP COLUMN agent_id;
ALTER TABLE conversations DROP COLUMN unread_count;
ALTER TABLE conversations DROP COLUMN hidden_at;
ALTER TABLE conversations DROP COLUMN pinned_at;

ALTER TABLE messages DROP COLUMN is_read;

-- === 5. 重建查询索引(ListForUser 用) ===

CREATE INDEX idx_conversations_last_msg_at ON conversations(last_message_at DESC);
