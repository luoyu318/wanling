-- 014_users_role.sql
-- role 一等公民化:users 表落 role 列,DB 为准(env ADMIN_USERNAMES 启动种子)。
ALTER TABLE users ADD COLUMN role varchar(16) NOT NULL DEFAULT 'user';
ALTER TABLE users ADD CONSTRAINT users_role_check CHECK (role IN ('user', 'admin'));
