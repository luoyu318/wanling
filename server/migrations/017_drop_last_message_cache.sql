-- 017_drop_last_message_cache.sql
-- 删除 conversations.last_message_content / last_message_at 缓存字段。
-- 会话列表查询改用子查询实时算个人维度最新可见消息(spec §3)。
-- 原因:全局缓存在 hide(per-participant)场景下无法精确表达「A 看到的最新 vs B 看到的最新」,
-- 维护成本(写消息 + 删除/撤回时重算)高于子查询 LIMIT 1(走 idx_messages_conv_created)。

ALTER TABLE conversations
  DROP COLUMN last_message_content,
  DROP COLUMN last_message_at;
