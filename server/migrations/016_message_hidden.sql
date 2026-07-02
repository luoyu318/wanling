-- 016: per-participant 维度的"对自己隐藏"。
--
-- 背景: 006 引入的 messages.deleted_at 是 per-message 全局软删除,删除后所有
-- participant 都看不到。participants 模型重构(015)后,N 方参与者应当各有独立视图,
-- 但 messages 软删除未同步升级 —— 导致"用户删除本地消息会同步删对方"重大 bug。
--
-- 双轨制修复(本 migration + 配套 handler 改造):
--   - messages.deleted_at 语义改为"撤回(全局软删,双向不可见)"
--   - 新增 message_hidden 表存 per-participant 隐藏(单向不可见)
-- 客户端长按菜单: 自己发的 + 5min 内 → "撤回"(走 deleted_at); 其他 → "删除"(走 hidden)。
--
-- 字段说明:
--   member_id/member_type: 与 conversation_participants 对齐(user|agent),
--     不加 FK 到 participants 表(避免 cascade 复杂度),由应用层保证引用完整。
--   hidden_at: 时间戳风格沿用 004/006。
CREATE TABLE message_hidden (
    message_id   UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    member_id    UUID NOT NULL,
    member_type  VARCHAR(16) NOT NULL CHECK (member_type IN ('user', 'agent')),
    hidden_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (message_id, member_id, member_type)
);

-- 索引: 查"我的隐藏消息列表"用 (例批量清理、未来"我隐藏过的"页)。
CREATE INDEX idx_message_hidden_member ON message_hidden(member_id, member_type);
