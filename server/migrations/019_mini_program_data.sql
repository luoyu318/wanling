-- 019_mini_program_data.sql
-- 小程序云数据:档位化文档 KV(private/shared_read/shared_write),
-- appid 双层配额(appid 总帽 + 单用户子帽),version 乐观锁。
-- 共享档每行记写者 owner_id(审计 + 用户子帽归属),展示层投影 openid。
CREATE TABLE mini_program_data (
    id BIGSERIAL PRIMARY KEY,
    appid text NOT NULL,
    owner_id uuid NOT NULL REFERENCES users(id),
    coll text NOT NULL DEFAULT 'default',
    key text NOT NULL,
    value jsonb NOT NULL,
    size_bytes int NOT NULL,
    version int NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (appid, owner_id, coll, key)
);
CREATE INDEX idx_mp_data_appid ON mini_program_data (appid, coll, key);
CREATE INDEX idx_mp_data_quota ON mini_program_data (appid, owner_id);

-- 小程序存储配额覆盖(NULL = 用全局默认,管理员可调)。
ALTER TABLE mini_programs ADD COLUMN quota_bytes bigint;

-- 回滚(如需,手执行):
--   DROP TABLE IF EXISTS mini_program_data;
--   ALTER TABLE mini_programs DROP COLUMN IF EXISTS quota_bytes;
