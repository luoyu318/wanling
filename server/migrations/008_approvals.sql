-- migration 008: 审批卡片表
-- 关联 messages 表，记录卡片审批的完整生命周期。
-- 与 messages.content.data.state 双写，避免列表渲染时 JOIN。

CREATE TABLE IF NOT EXISTS approvals (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id      UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    agent_id        UUID NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    card_type       TEXT NOT NULL CHECK (card_type IN ('command', 'tool', 'file')),
    state           TEXT NOT NULL DEFAULT 'pending'
                    CHECK (state IN ('pending', 'approved', 'denied', 'expired')),
    actions         JSONB NOT NULL,
    decided_action  TEXT,
    decided_by      UUID REFERENCES users(id),
    decided_reason  TEXT,
    decided_at      TIMESTAMPTZ,

    expires_at      TIMESTAMPTZ NOT NULL,
    session_key     TEXT NOT NULL,
    allow_pattern   TEXT,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_approvals_pending_expires
    ON approvals(expires_at) WHERE state = 'pending';
CREATE INDEX IF NOT EXISTS idx_approvals_message
    ON approvals(message_id);
CREATE INDEX IF NOT EXISTS idx_approvals_conv_agent_pattern
    ON approvals(conversation_id, agent_id, allow_pattern)
    WHERE state = 'approved' AND allow_pattern IS NOT NULL;
