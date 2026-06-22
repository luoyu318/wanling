-- 002: 为 conversations 加 last_message_content 缓存字段，避免列表查询 JOIN messages
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS last_message_content JSONB;

-- 回填历史数据：每条 conversation 取 messages 中最后一条的 content
-- DISTINCT ON 取每个 conversation_id 在 ORDER BY 排序下的第一行（最新的）
-- created_at 相同时按 id DESC 作为 tiebreaker，保证回填顺序确定。
UPDATE conversations c
SET last_message_content = sub.content
FROM (
    SELECT DISTINCT ON (conversation_id) conversation_id, content
    FROM messages
    ORDER BY conversation_id, created_at DESC, id DESC
) sub
WHERE c.id = sub.conversation_id AND c.last_message_content IS NULL;
