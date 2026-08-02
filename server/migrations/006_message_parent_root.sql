-- 006: 子 agent 内容透传 — messages 表加 parent_msg_id + root_msg_id
-- parent_msg_id: 直接父 task 卡片（NULL = 主对话流消息）
-- root_msg_id:   最外层 task 卡片（NULL = 主对话流消息；1 层嵌套时与 parent 相同）
-- 向后兼容：两字段 NULLABLE，旧客户端零感知
-- 回滚（如需，手执行）：
--   DROP INDEX IF EXISTS idx_messages_root;
--   ALTER TABLE messages
--     DROP COLUMN IF EXISTS root_msg_id,
--     DROP COLUMN IF EXISTS parent_msg_id;

ALTER TABLE messages
  ADD COLUMN parent_msg_id UUID REFERENCES messages(id) ON DELETE CASCADE,
  ADD COLUMN root_msg_id   UUID REFERENCES messages(id) ON DELETE CASCADE;

CREATE INDEX idx_messages_root ON messages(root_msg_id)
  WHERE root_msg_id IS NOT NULL;
