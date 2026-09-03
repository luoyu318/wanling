-- 017: pairing_tickets.secret_key 扩容为 TEXT
-- 背景:authorize 授权模式的票据凭据是子密钥(wlsk_ 前缀 + 64 hex = 69 字符),
-- 原列 VARCHAR(64) 只够存 bind 的 64 hex 主密钥,子密钥落库超长报错。

ALTER TABLE pairing_tickets ALTER COLUMN secret_key TYPE TEXT;

-- 回滚（如需，手执行，不写实体 down 段）：
--   仅当表内无超 64 字符凭据时才可回滚:
--   ALTER TABLE pairing_tickets ALTER COLUMN secret_key TYPE VARCHAR(64);
