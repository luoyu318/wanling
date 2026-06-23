-- 010: 放宽 approvals.card_type 的 CHECK 约束，新增 slash_confirm 类型
-- 用于 /new /clear /reset /undo 等破坏性 slash 命令的确认卡片。
-- DROP 旧约束后重建（含 slash_confirm），保持 008 新部署与历史库一致。
ALTER TABLE approvals DROP CONSTRAINT IF EXISTS approvals_card_type_check;
ALTER TABLE approvals ADD CONSTRAINT approvals_card_type_check
    CHECK (card_type IN ('command', 'tool', 'file', 'slash_confirm'));
