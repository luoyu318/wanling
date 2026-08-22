-- server/migrations/010_approval_question.sql
-- 审批卡 question 类型（多选问题语义）+ 多选决策持久化。
-- card_type CHECK 放宽 + decided_answers JSONB。

-- PG 的 CHECK 约束名在 001 内联定义时自动生成（approvals_card_type_check），
-- 幂等处理：先查是否存在再 DROP 不适用于纯 SQL 文件，这里用 DO 块兜底。
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'approvals_card_type_check'
          AND conrelid = 'public.approvals'::regclass
    ) THEN
        ALTER TABLE approvals DROP CONSTRAINT approvals_card_type_check;
    END IF;
END $$;

ALTER TABLE approvals
    ADD CONSTRAINT approvals_card_type_check
    CHECK (card_type IN ('command', 'tool', 'file', 'slash_confirm', 'question'));

ALTER TABLE approvals ADD COLUMN IF NOT EXISTS decided_answers JSONB;
