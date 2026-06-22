-- 005_profile_fields.sql
-- 用户展示昵称（可空，回退 username）+ 个人简介（可空）
ALTER TABLE users ADD COLUMN IF NOT EXISTS nickname VARCHAR(64) DEFAULT NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS bio       VARCHAR(200) DEFAULT NULL;

-- Agent 简介（可空）。avatar_url 已存在，不动。
ALTER TABLE agents ADD COLUMN IF NOT EXISTS bio VARCHAR(200) DEFAULT NULL;
