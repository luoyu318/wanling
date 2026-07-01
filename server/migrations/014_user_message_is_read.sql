-- 014_user_message_is_read.sql
-- is_read 语义对齐:user 自己发的消息一律视为已读(不参与未读计数)。
-- 回填存量 user 消息(此前 DB DEFAULT FALSE,语义混淆)。
--
-- 语义说明(2026-07-01):
--   is_read = TRUE  ⇔ 该消息不参与 unread_count 计数
--   is_read = FALSE ⇔ 该消息参与 unread_count 计数(待接收方读)
-- user 自发消息永远不计未读,故统一 TRUE。
--
-- 注:本字段语义为单向 user 视角,participants 模型重构后将废弃/迁移。
--     不加 CHECK 约束,避免把单向假设焊死在 DB 层堵死未来扩展。

UPDATE messages SET is_read = TRUE WHERE sender_type = 'user' AND is_read = FALSE;
