-- 018_agent_sub_keys_fk_cascade.sql
-- agent_sub_keys.agent_id 外键改 ON DELETE CASCADE。
-- 016 建表时内联 REFERENCES agents(id) 默认 NO ACTION,而 AgentRepo.Delete 是硬删除:
-- 删除发过子密钥的 agent 会触发 FK 违规(500),并阻断 users→agents 的 ON DELETE CASCADE
-- 级联链(删 user 同样被挡)。
-- 约束名 agent_sub_keys_agent_id_fkey 是 016 内联声明时 PG 的默认命名(<表>_<列>_fkey),
-- 已在开发库 pg_constraint 确认。
-- 为什么新增 018 而非改 016:016 已在环境应用,schema_migrations 按 version 记录,
-- 改已应用文件不会重放,已部署实例拿不到修正;增量补丁才是对既有环境的安全通道。
ALTER TABLE agent_sub_keys DROP CONSTRAINT agent_sub_keys_agent_id_fkey;
ALTER TABLE agent_sub_keys
    ADD CONSTRAINT agent_sub_keys_agent_id_fkey
    FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE;

-- 回滚（如需，手执行，不写实体 down 段）：
--   ALTER TABLE agent_sub_keys DROP CONSTRAINT agent_sub_keys_agent_id_fkey;
--   ALTER TABLE agent_sub_keys ADD CONSTRAINT agent_sub_keys_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES agents(id);
