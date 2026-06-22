-- 006_message_soft_delete.sql
-- messages 软删除字段：deleted_at 非空表示已软删除。
-- 沿用项目现有软删除风格（migration 004 的 hidden_at/pinned_at 时间戳模式）。
-- 所有查询 messages 的 SQL 须加 WHERE deleted_at IS NULL。
ALTER TABLE messages ADD COLUMN deleted_at TIMESTAMPTZ;

-- 部分索引：会话消息列表查询（按 conversation_id + created_at 排序）只扫未删行。
-- 没这个索引，删消息多了后 ListByConversation 会全表扫。
CREATE INDEX idx_messages_conv_not_deleted
  ON messages (conversation_id, created_at)
  WHERE deleted_at IS NULL;
