-- 003: agent.type 列 + conversations.type 增加 agent_session
-- 背景:opencode 多 session,每个 opencode session 用独立 agent_session 群承载。
-- spec: docs/superpowers/specs/2026-07-09-opencode-multi-session-design.md

-- agents.type:agent 类型标签,默认空串(普通 agent);opencode agent = 'opencode'
ALTER TABLE agents ADD COLUMN IF NOT EXISTS type VARCHAR(32) NOT NULL DEFAULT '';

-- conversations.type 的 CHECK(001 限定 4 种)增加 agent_session
-- agent_session:一个 agent 的一个会话实例,1 user + 1 agent,可多实例(走 CreateTx 不去重)
ALTER TABLE conversations DROP CONSTRAINT IF EXISTS conversations_type_check;
ALTER TABLE conversations ADD CONSTRAINT conversations_type_check
  CHECK (type IN ('dm_user_agent','dm_user_user','group_user','group_mixed','agent_session'));
