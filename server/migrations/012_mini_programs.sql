-- 小程序容器:两层模型(私有/公共库)。
-- owner 上传即 private(自己可见可运行);管理员 publish 上公共库;
-- 仅 published 可分享聊天卡片(M2)。管理上传走 POST /api/mini-programs。
CREATE TABLE mini_programs (
    id              UUID PRIMARY KEY,
    appid           VARCHAR(32) NOT NULL UNIQUE,
    owner_id        UUID NOT NULL REFERENCES users(id),
    name            VARCHAR(64) NOT NULL,
    version         INTEGER NOT NULL CHECK (version > 0),
    manifest        JSONB NOT NULL,
    package_file_id UUID NOT NULL REFERENCES files(id),
    sha256          VARCHAR(64) NOT NULL,
    size            BIGINT NOT NULL CHECK (size > 0),
    status          VARCHAR(16) NOT NULL DEFAULT 'private'
                    CHECK (status IN ('private', 'published', 'disabled')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_mini_programs_owner ON mini_programs(owner_id);

-- 回滚(如需,手执行):
--   DROP TABLE IF EXISTS mini_programs;
