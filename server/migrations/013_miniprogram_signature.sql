-- 小程序包签名(M3):publish 时 server 用 ed25519 私钥对包字节签名,
-- APP 下载后验签(缺失放行过渡,存在必验)。私钥仅存 server,公钥经端点下发。
ALTER TABLE mini_programs ADD COLUMN signature TEXT;

CREATE TABLE mp_signing_key (
    id          BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
    private_key TEXT NOT NULL,
    public_key  TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 回滚(如需,手执行):
--   ALTER TABLE mini_programs DROP COLUMN IF EXISTS signature;
--   DROP TABLE IF EXISTS mp_signing_key;
