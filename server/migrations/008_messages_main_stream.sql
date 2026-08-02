-- 008: 主对话流判据收敛为生成列 is_main_stream
-- permission_card / question_card 是「需用户立即操作的交互卡」,
-- 即使由子 agent 发出(parent_msg_id != nil)也必须浮到主对话流
-- (可见 + 计未读 + 计入待办角标),同时保留 parent/root_msg_id 供
-- 子 agent 详情页(ListByRoot by root_msg_id)回溯。
--
-- 生成列让 22+ 处 SQL 的「主对话流消息」过滤(parent_msg_id IS NULL)
-- 统一收敛为 is_main_stream,避免逐处 OR content->>'msg_type' 解析(DRY + 可索引)。
-- 未来新增其他需浮顶的交互卡类型,只需改本生成列定义。
--
-- 锁说明:STORED 生成列 ADD COLUMN 会重写 messages 表。测试(testcontainers
-- 空表)无影响;生产请在低峰期执行。
--
-- 回滚(如需,手执行,不写实体 down 段):
--   DROP INDEX IF EXISTS idx_messages_main_stream;
--   ALTER TABLE messages DROP COLUMN IF EXISTS is_main_stream;
--   CREATE INDEX idx_messages_parent_null ON messages(conversation_id, created_at DESC) WHERE parent_msg_id IS NULL;

ALTER TABLE messages
  ADD COLUMN is_main_stream boolean GENERATED ALWAYS AS
    (parent_msg_id IS NULL OR content->>'msg_type' IN ('permission_card', 'question_card')) STORED;

CREATE INDEX idx_messages_main_stream
  ON messages(conversation_id, created_at DESC)
  WHERE is_main_stream;

DROP INDEX IF EXISTS idx_messages_parent_null;
