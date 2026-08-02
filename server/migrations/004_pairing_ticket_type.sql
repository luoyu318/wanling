-- 004: pairing_tickets 增加 type 列,透传 agent 类型标签
-- 背景:扫码配对创建的 agent 永远是 default type,APP 无法识别 opencode agent。
-- hermes 在 CreateTicket 时声明自己 type(默认空串=普通 agent,opencode=OpenCode agent),
-- CompleteTicket 读 ticket.type 建 agent,避免硬编码空串。
-- 配合 003 的 agents.type 列,实现 type 全链路透传。

ALTER TABLE pairing_tickets ADD COLUMN IF NOT EXISTS type VARCHAR(32) NOT NULL DEFAULT '';
