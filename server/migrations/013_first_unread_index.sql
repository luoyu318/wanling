-- 013_first_unread_index.sql
-- 为 FirstUnread（定位会话第一条未读）提供 partial index。
-- 查询模式：WHERE conversation_id = $1 AND is_read = FALSE AND deleted_at IS NULL
--           ORDER BY created_at ASC LIMIT 1
--
-- 006 的 partial index (conversation_id, created_at) WHERE deleted_at IS NULL
-- 已能服务此查询，但需逐行 filter is_read=FALSE。本 partial 进一步收窄到
-- 「未读 + 未删」子集，命中后 LIMIT 1 直接拿到，O(log N + 1)。
-- 业务影响：长期活跃会话可能积累数千条消息，但未读通常个位数，partial 显著降低扫描量。
CREATE INDEX IF NOT EXISTS idx_messages_conv_unread
    ON messages (conversation_id, created_at)
    WHERE is_read = FALSE AND deleted_at IS NULL;
