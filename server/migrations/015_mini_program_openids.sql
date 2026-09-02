-- 015_mini_program_openids.sql
-- 小程序 openid 身份体系:(用户×appid) 二元组惰性生成永久稳定标识,
-- 同一小程序对不同用户、同一用户对不同小程序互不相通(主流小程序平台惯例)。
CREATE TABLE mini_program_openids (
    user_id uuid NOT NULL REFERENCES users(id),
    appid text NOT NULL,
    openid uuid NOT NULL DEFAULT gen_random_uuid(),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, appid)
);
CREATE UNIQUE INDEX mini_program_openids_openid_idx ON mini_program_openids(openid);

-- 回滚(如需,手执行):
--   DROP TABLE IF EXISTS mini_program_openids;
