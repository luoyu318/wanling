-- 007: 主列表查询性能 — parent_msg_id IS NULL 部分索引
-- ListByConversation / ListBefore / ListAfter / CountBefore / listMessageContextRange /
-- BatchLoadAgentSessionStats / ListForUser 子查询均带 m.parent_msg_id IS NULL 过滤,
-- 子事件(reasoning/tool_card/子 session 输出)持续累积时,无此索引只能扫全会话再滤 NULL。
-- 部分索引仅含顶层消息,体量小且与查询谓词精确对齐。
--
-- 回滚(如需,手执行,不写实体 down 段):
--   DROP INDEX IF EXISTS idx_messages_parent_null;

CREATE INDEX idx_messages_parent_null
  ON messages(conversation_id, created_at DESC)
  WHERE parent_msg_id IS NULL;
