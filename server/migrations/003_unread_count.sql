-- 003: 未读消息计数
-- conversations.unread_count 缓存未读数，避免 IM 列表 COUNT(*)；
-- messages.is_read 标记单条消息是否已读，便于未来做"已读回执"扩展。

ALTER TABLE conversations
    ADD COLUMN IF NOT EXISTS unread_count INTEGER NOT NULL DEFAULT 0;

ALTER TABLE messages
    ADD COLUMN IF NOT EXISTS is_read BOOLEAN NOT NULL DEFAULT FALSE;

-- 历史数据：所有已存在的消息视为已读（避免存量数据全显示未读）。
UPDATE messages SET is_read = TRUE WHERE is_read = FALSE;
-- conversations.unread_count 默认 0，存量会话也保持 0（视为已读）。
