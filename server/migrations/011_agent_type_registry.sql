-- agent type 注册表:type → 拓扑属性 + 展示属性,server 统一下发,
-- 新类型只需 INSERT 一行(无需 APP 发版,无需 server 发版)。
--   multi_session:APP 一级列表点击路由(二级 sessions 页 vs 直进聊天窗)
--   label/badge_*:展示属性;badge 色为 16 进制(#RRGGBB),空值=APP 用默认配色
-- 预置三类;''(legacy 普通)不入库,server 侧以 multi_session=false 兜底。
CREATE TABLE agent_type_registry (
    type             VARCHAR(32) PRIMARY KEY,
    multi_session    BOOLEAN NOT NULL DEFAULT FALSE,
    label            VARCHAR(32) NOT NULL,
    badge_bg         VARCHAR(16) NOT NULL DEFAULT '',
    badge_bg_elevated VARCHAR(16) NOT NULL DEFAULT '',
    badge_fg         VARCHAR(16) NOT NULL DEFAULT '',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO agent_type_registry (type, multi_session, label, badge_bg, badge_bg_elevated, badge_fg) VALUES
    ('hermes',   FALSE, 'Hermes',   '#FEF3C7', '#FDE68A', '#78350F'),
    ('opencode', TRUE,  'OpenCode', '#D1FAE5', '#A7F3D0', '#047857'),
    ('dsh',      TRUE,  'DSH',      '#E0F2FE', '#BAE6FD', '#075985');

-- 回滚(如需,手执行):
--   DROP TABLE IF EXISTS agent_type_registry;
