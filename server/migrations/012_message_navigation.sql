-- 012_message_navigation.sql
-- 为游标分页（ListBefore）提供索引支持。
-- unread_count 和 is_read 列已在 003_unread_count.sql 中创建，此处不重复。

-- 游标分页查询索引：WHERE conversation_id = $1 AND created_at < $2
CREATE INDEX IF NOT EXISTS idx_messages_conv_created
    ON messages (conversation_id, created_at DESC);
