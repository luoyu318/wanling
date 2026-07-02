-- 018: 文件与会话的多对多授权关系。
--
-- 背景: 此前 file_handler.Download 用严格 owner 校验(f.OwnerID == userID)防 IDOR,
-- 但 IM 业务本质是「消息传给他人」,接收方必然要能访问:
--   - dm_user_user 私聊图片: user A 发给 user B,B 下载时 owner=A → 403 ❌
--   - group 群聊图片: 群里任何人发图,其他群员下载都 403 ❌
--   - 用户/agent 头像: 任何看资料页的人都应能加载 → 403 ❌(Bug 4 根因)
--
-- 修复方案 D'(贴合主流 IM 模式,共享文件指针):
--   - file 与 conversation 是 N:N 关系(转发场景: 一份文件被多个会话引用,不重传)
--   - file_conv_links 记录授权关系,下载时按「claimer 是任一引用会话的 participant」放行
--   - 头像单独走白名单(users.avatar_url / agents.avatar_url 引用的 file 视为公开)
--
-- 不加 shared_by 字段(职责分离原则):
--   - 授权关系归 file_conv_links(决定下载权限)
--   - 转发链路归 messages.forward_from_msg_id(未来如需审计再加,当前未开放转发)
--
-- 转发功能未来上线时: 仅需 INSERT 一行 (file_id, new_conv_id),不重传文件。
CREATE TABLE file_conv_links (
    file_id    UUID NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    conv_id    UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (file_id, conv_id)  -- 幂等: 同一 file 在同一 conv 只记一次
);

-- 按 conv_id 查「该会话所有可见文件」(未来会话文件列表用)
CREATE INDEX idx_file_conv_links_conv ON file_conv_links(conv_id);
-- 按 file_id 查「该文件被哪些会话引用」(权限校验 + 文件清理用)
CREATE INDEX idx_file_conv_links_file ON file_conv_links(file_id);

-- 数据回填: 从 messages 表 content.data.file_id 提取存量关联。
-- 只回填未撤回的消息(deleted_at IS NULL),撤回的图本就不再展示。
-- ON CONFLICT DO NOTHING 让本 migration 可重复执行(开发环境反复跑安全)。
INSERT INTO file_conv_links (file_id, conv_id)
SELECT DISTINCT
    (m.content -> 'data' ->> 'file_id')::uuid,
    m.conversation_id
FROM messages m
WHERE m.deleted_at IS NULL
  AND m.content ->> 'msg_type' IN ('image', 'file')
  AND m.content -> 'data' ->> 'file_id' IS NOT NULL
  AND m.content -> 'data' ->> 'file_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
ON CONFLICT DO NOTHING;
