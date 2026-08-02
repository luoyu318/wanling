-- 005: conversations 加 session_meta JSONB 列
-- 存储 opencode agent_session 的 mode/model/variant 元数据，
-- 由 plugin session.updated 事件同步，APP 读取渲染副标题。
-- nullable：仅 agent_session 有值，其他 type 为 null。
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS session_meta JSONB;
