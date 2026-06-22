-- 004_pin_hide.sql: 会话软删除 + 置顶
-- hidden_at: 软删除时间戳,非空表示隐藏(列表不显示)。新消息来时置空(自动恢复)。
-- pinned_at: 置顶时间戳,非空表示置顶。列表排序:置顶组在前 + 时间倒序。
ALTER TABLE conversations ADD COLUMN hidden_at TIMESTAMPTZ;
ALTER TABLE conversations ADD COLUMN pinned_at TIMESTAMPTZ;
