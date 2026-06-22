-- 007_pairing_tickets.sql
-- 扫码配对票据表。仅用于 hermes 终端 ↔ 万灵 app 的握手会话，
-- 5 分钟 TTL（查询时 created_at < NOW() - INTERVAL '5 minutes' 判定过期），
-- 不是业务表，不与 agents/conversations 关联外键（避免删 agent 时级联破坏票据状态）。
CREATE TABLE pairing_tickets (
    id           VARCHAR(64) PRIMARY KEY,                       -- 256-bit hex (32 字节)
    status       VARCHAR(16) NOT NULL DEFAULT 'pending',        -- pending|scanned|completed|expired
    user_id      UUID,                                           -- scanned 后写入扫码用户
    agent_id     UUID,                                           -- completed 后写入被绑定的 agent
    secret_key   VARCHAR(64),                                    -- completed 后短暂存凭据，领走即清空
    created_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    scanned_at   TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE
);
CREATE INDEX idx_pairing_tickets_created_at ON pairing_tickets(created_at);
