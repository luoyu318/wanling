-- 002: 删除 agents.status 列。
--
-- 该列从 001 schema 创建后从未被 server UPDATE,实际状态走 Redis presence key
-- (hub.Register 时 SET,心跳 RefreshTTL 续期,60s TTL)。
-- agent_handler List/Get 时虽然 SELECT 出 status,但立刻用 presence.IsOnline
-- 算的结果覆盖,DB 列永远是 default 'offline',纯死字段。
--
-- 删除后:
--   - agent_repo SELECT/RETURNING 去掉 status 列
--   - model.Agent.Status db tag 改 -
--   - 客户端响应里 status 由 handler 用 presence 算后赋值给 model 字段输出

ALTER TABLE agents DROP COLUMN status;
