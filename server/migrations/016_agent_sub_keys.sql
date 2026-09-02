-- 016_agent_sub_keys.sql
-- agent 子密钥(REST-only 授权,详见 docs/ai-handbook/agent-subkeys.md)
CREATE TABLE agent_sub_keys (
    id UUID PRIMARY KEY,
    agent_id UUID NOT NULL REFERENCES agents(id),
    name TEXT NOT NULL DEFAULT '',
    secret_key TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ
);
CREATE INDEX idx_agent_sub_keys_agent ON agent_sub_keys(agent_id);

-- 配对票据加 action 列(bind=现状接管语义 / authorize=发子密钥授权)
ALTER TABLE pairing_tickets ADD COLUMN action TEXT NOT NULL DEFAULT 'bind';

-- 回滚（如需，手执行，不写实体 down 段）：
--   ALTER TABLE pairing_tickets DROP COLUMN IF EXISTS action;
--   DROP TABLE IF EXISTS agent_sub_keys;
