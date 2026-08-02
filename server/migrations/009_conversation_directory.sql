-- 009: conversations 加 directory 一级列
-- OC session 的物理工作目录(directory)是创建后固化的参数,
-- 不再塞 session_meta JSONB(与可变字段 mode/model/git_branch 混在一起,
-- 会导致 server 整 JSON 覆盖写时互相覆盖)。
-- 写入时机:APP user 视角 POST /api/conversations (type=agent_session) 传 directory,
-- server 在 CreateAgentSession 事务内写入。NULL = 用户选「默认」(plugin 用 OC 启动目录)。
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS directory TEXT;
