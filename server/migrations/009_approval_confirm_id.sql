-- 009: approvals 表加 confirm_id 字段
-- 用于 slash_confirm 类型审批（/new /clear /reset /undo 等破坏性 slash 命令）。
-- hermes tools/slash_confirm.resolve 需要 (session_key, confirm_id, choice) 三元组定位
-- pending confirm，exec_approval（command/tool/file）不用此字段，保持 NULL。
ALTER TABLE approvals ADD COLUMN IF NOT EXISTS confirm_id TEXT;
