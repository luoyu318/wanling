package repository

import (
	"testing"
	"time"

	"github.com/google/uuid"
)

// TestAgentSubKeyRepo_CreateAndGetByKey 往返:Create 后 GetByKey 原样取回(含凭据)。
func TestAgentSubKeyRepo_CreateAndGetByKey(t *testing.T) {
	db := SetupTestDB(t)
	ur := NewUserRepo(db)
	ar := NewAgentRepo(db)
	repo := NewAgentSubKeyRepo(db)

	u, err := ur.Create(t.Context(), uniqueShortName(t, "ask1"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user: %v", err)
	}
	a, err := ar.Create(t.Context(), u.ID, "subkey-agent", "agent-secret", "")
	if err != nil {
		t.Fatalf("Create agent: %v", err)
	}

	// Create:返回的模型各字段就位
	sk, err := repo.Create(t.Context(), a.ID, "CI 密钥", "wlsk_test_secret_1")
	if err != nil {
		t.Fatalf("Create sub key: %v", err)
	}
	if _, err := uuid.Parse(sk.ID); err != nil {
		t.Fatalf("id 应为合法 UUID,实际 %q", sk.ID)
	}
	if sk.AgentID != a.ID || sk.Name != "CI 密钥" || sk.SecretKey != "wlsk_test_secret_1" {
		t.Fatalf("Create 返回字段不匹配: %+v", sk)
	}
	if sk.RevokedAt != nil || sk.LastUsedAt != nil {
		t.Fatalf("新建密钥 revoked_at/last_used_at 应为空: %+v", sk)
	}

	// GetByKey:按凭据原样取回
	got, err := repo.GetByKey(t.Context(), "wlsk_test_secret_1")
	if err != nil {
		t.Fatalf("GetByKey: %v", err)
	}
	if got == nil {
		t.Fatal("GetByKey 应命中,实际 nil")
	}
	if got.ID != sk.ID || got.AgentID != a.ID || got.Name != sk.Name || got.SecretKey != sk.SecretKey {
		t.Fatalf("GetByKey 往返不一致: create=%+v get=%+v", sk, got)
	}

	// GetByKey 不存在的 key:不报错,返回 nil
	missing, err := repo.GetByKey(t.Context(), "wlsk_not_exist")
	if err != nil {
		t.Fatalf("GetByKey 不存在 key 不应报错: %v", err)
	}
	if missing != nil {
		t.Fatalf("不存在的 key 应返回 nil,实际 %+v", missing)
	}

	// TouchLastUsed:置 last_used_at
	if err := repo.TouchLastUsed(t.Context(), sk.ID); err != nil {
		t.Fatalf("TouchLastUsed: %v", err)
	}
	touched, err := repo.GetByKey(t.Context(), sk.SecretKey)
	if err != nil {
		t.Fatalf("GetByKey after touch: %v", err)
	}
	if touched.LastUsedAt == nil {
		t.Fatal("TouchLastUsed 后 last_used_at 应非空")
	}
}

// TestAgentSubKeyRepo_CountActive 只数未吊销:吊销一个少一个,全吊为 0,跨 agent 隔离。
func TestAgentSubKeyRepo_CountActive(t *testing.T) {
	db := SetupTestDB(t)
	ur := NewUserRepo(db)
	ar := NewAgentRepo(db)
	repo := NewAgentSubKeyRepo(db)

	u, err := ur.Create(t.Context(), uniqueShortName(t, "ask2"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user: %v", err)
	}
	agentA, err := ar.Create(t.Context(), u.ID, "agent-a", "secret-a", "")
	if err != nil {
		t.Fatalf("Create agent a: %v", err)
	}
	agentB, err := ar.Create(t.Context(), u.ID, "agent-b", "secret-b", "")
	if err != nil {
		t.Fatalf("Create agent b: %v", err)
	}

	for _, s := range []string{"wlsk_a_1", "wlsk_a_2"} {
		if _, err := repo.Create(t.Context(), agentA.ID, s, s); err != nil {
			t.Fatalf("Create %s: %v", s, err)
		}
	}
	if _, err := repo.Create(t.Context(), agentB.ID, "wlsk_b_1", "wlsk_b_1"); err != nil {
		t.Fatalf("Create b_1: %v", err)
	}

	// 吊销前:agent A 2 个活跃
	n, err := repo.CountActive(t.Context(), agentA.ID)
	if err != nil {
		t.Fatalf("CountActive: %v", err)
	}
	if n != 2 {
		t.Fatalf("吊销前应 2 个活跃,实际 %d", n)
	}

	// 吊销其中一个:只剩 1 个
	keys, err := repo.ListByAgent(t.Context(), agentA.ID)
	if err != nil {
		t.Fatalf("ListByAgent: %v", err)
	}
	if err := repo.Revoke(t.Context(), keys[0].ID); err != nil {
		t.Fatalf("Revoke: %v", err)
	}
	n, err = repo.CountActive(t.Context(), agentA.ID)
	if err != nil {
		t.Fatalf("CountActive after revoke: %v", err)
	}
	if n != 1 {
		t.Fatalf("吊销一个后应 1 个活跃,实际 %d", n)
	}

	// RevokeAllForAgent:agent A 全吊为 0,agent B 不受影响(隔离)
	if err := repo.RevokeAllForAgent(t.Context(), agentA.ID); err != nil {
		t.Fatalf("RevokeAllForAgent: %v", err)
	}
	n, err = repo.CountActive(t.Context(), agentA.ID)
	if err != nil {
		t.Fatalf("CountActive after revoke all: %v", err)
	}
	if n != 0 {
		t.Fatalf("RevokeAllForAgent 后应 0 个活跃,实际 %d", n)
	}
	n, err = repo.CountActive(t.Context(), agentB.ID)
	if err != nil {
		t.Fatalf("CountActive agent b: %v", err)
	}
	if n != 1 {
		t.Fatalf("agent B 不应被 A 的全吊影响,活跃应 1,实际 %d", n)
	}
}

// TestAgentSubKeyRepo_RevokeIdempotent 二次 Revoke 不报错且 revoked_at 不被覆盖。
func TestAgentSubKeyRepo_RevokeIdempotent(t *testing.T) {
	db := SetupTestDB(t)
	ur := NewUserRepo(db)
	ar := NewAgentRepo(db)
	repo := NewAgentSubKeyRepo(db)

	u, err := ur.Create(t.Context(), uniqueShortName(t, "ask3"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user: %v", err)
	}
	a, err := ar.Create(t.Context(), u.ID, "agent-idem", "secret-idem", "")
	if err != nil {
		t.Fatalf("Create agent: %v", err)
	}
	sk, err := repo.Create(t.Context(), a.ID, "idem", "wlsk_idem_1")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	// 首次吊销
	if err := repo.Revoke(t.Context(), sk.ID); err != nil {
		t.Fatalf("首次 Revoke: %v", err)
	}
	first, err := repo.GetByKey(t.Context(), "wlsk_idem_1")
	if err != nil {
		t.Fatalf("GetByKey after revoke: %v", err)
	}
	if first.RevokedAt == nil {
		t.Fatal("吊销后 revoked_at 应非空")
	}

	// 等一拍,确保二次吊销若误写 now() 会产生可见的时间差
	time.Sleep(10 * time.Millisecond)

	// 二次吊销:不报错
	if err := repo.Revoke(t.Context(), sk.ID); err != nil {
		t.Fatalf("二次 Revoke 不应报错: %v", err)
	}
	again, err := repo.GetByKey(t.Context(), "wlsk_idem_1")
	if err != nil {
		t.Fatalf("GetByKey after 2nd revoke: %v", err)
	}
	if !again.RevokedAt.Equal(*first.RevokedAt) {
		t.Fatalf("二次吊销不应覆盖 revoked_at: 首次 %v 二次 %v", *first.RevokedAt, *again.RevokedAt)
	}
}

// TestAgentSubKeyRepo_RevokeAllForAgent 按 agent 全吊,含未吊销的才被更新,跨 agent 隔离。
func TestAgentSubKeyRepo_RevokeAllForAgent(t *testing.T) {
	db := SetupTestDB(t)
	ur := NewUserRepo(db)
	ar := NewAgentRepo(db)
	repo := NewAgentSubKeyRepo(db)

	u, err := ur.Create(t.Context(), uniqueShortName(t, "ask4"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user: %v", err)
	}
	agentA, err := ar.Create(t.Context(), u.ID, "agent-ra", "secret-ra", "")
	if err != nil {
		t.Fatalf("Create agent a: %v", err)
	}
	agentB, err := ar.Create(t.Context(), u.ID, "agent-rb", "secret-rb", "")
	if err != nil {
		t.Fatalf("Create agent b: %v", err)
	}

	for _, s := range []string{"wlsk_ra_1", "wlsk_ra_2"} {
		if _, err := repo.Create(t.Context(), agentA.ID, s, s); err != nil {
			t.Fatalf("Create %s: %v", s, err)
		}
	}
	if _, err := repo.Create(t.Context(), agentB.ID, "wlsk_rb_1", "wlsk_rb_1"); err != nil {
		t.Fatalf("Create rb_1: %v", err)
	}

	if err := repo.RevokeAllForAgent(t.Context(), agentA.ID); err != nil {
		t.Fatalf("RevokeAllForAgent: %v", err)
	}

	// agent A 全部已吊销,agent B 不受影响
	for _, s := range []string{"wlsk_ra_1", "wlsk_ra_2"} {
		got, err := repo.GetByKey(t.Context(), s)
		if err != nil {
			t.Fatalf("GetByKey %s: %v", s, err)
		}
		if got.RevokedAt == nil {
			t.Fatalf("%s 应已吊销", s)
		}
	}
	gotB, err := repo.GetByKey(t.Context(), "wlsk_rb_1")
	if err != nil {
		t.Fatalf("GetByKey rb_1: %v", err)
	}
	if gotB.RevokedAt != nil {
		t.Fatalf("agent B 密钥不应被 A 的全吊波及: %+v", gotB)
	}

	// 空 agent(无密钥)全吊不报错:用不存在的 agent(0 条密钥)验证
	if err := repo.RevokeAllForAgent(t.Context(), uuid.NewString()); err != nil {
		t.Fatalf("对无密钥 agent 全吊不应报错: %v", err)
	}

	// 有密钥的 agent B 全吊:报错为 nil,活跃归零,列表里 revoked_at 非空
	if err := repo.RevokeAllForAgent(t.Context(), agentB.ID); err != nil {
		t.Fatalf("对 agent B 全吊不应报错: %v", err)
	}
	nB, err := repo.CountActive(t.Context(), agentB.ID)
	if err != nil {
		t.Fatalf("CountActive agent b after revoke all: %v", err)
	}
	if nB != 0 {
		t.Fatalf("agent B 全吊后活跃应 0,实际 %d", nB)
	}
	listB, err := repo.ListByAgent(t.Context(), agentB.ID)
	if err != nil {
		t.Fatalf("ListByAgent agent b after revoke all: %v", err)
	}
	if len(listB) != 1 || listB[0].RevokedAt == nil {
		t.Fatalf("agent B 全吊后唯一密钥 revoked_at 应非空: %+v", listB)
	}
}

// TestAgentSubKeyRepo_ListByAgent 排序:created_at DESC,新创建的在前,只含本 agent。
func TestAgentSubKeyRepo_ListByAgent(t *testing.T) {
	db := SetupTestDB(t)
	ur := NewUserRepo(db)
	ar := NewAgentRepo(db)
	repo := NewAgentSubKeyRepo(db)

	u, err := ur.Create(t.Context(), uniqueShortName(t, "ask5"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user: %v", err)
	}
	agentA, err := ar.Create(t.Context(), u.ID, "agent-list", "secret-list", "")
	if err != nil {
		t.Fatalf("Create agent a: %v", err)
	}
	agentB, err := ar.Create(t.Context(), u.ID, "agent-list-b", "secret-list-b", "")
	if err != nil {
		t.Fatalf("Create agent b: %v", err)
	}

	// 先建 wlsk_l_1,隔一拍再建 wlsk_l_2,保证 created_at 严格递增
	sk1, err := repo.Create(t.Context(), agentA.ID, "first", "wlsk_l_1")
	if err != nil {
		t.Fatalf("Create l_1: %v", err)
	}
	time.Sleep(10 * time.Millisecond)
	sk2, err := repo.Create(t.Context(), agentA.ID, "second", "wlsk_l_2")
	if err != nil {
		t.Fatalf("Create l_2: %v", err)
	}
	if _, err := repo.Create(t.Context(), agentB.ID, "other", "wlsk_lb_1"); err != nil {
		t.Fatalf("Create lb_1: %v", err)
	}

	list, err := repo.ListByAgent(t.Context(), agentA.ID)
	if err != nil {
		t.Fatalf("ListByAgent: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("agent A 应 2 条,实际 %d", len(list))
	}
	if list[0].ID != sk2.ID || list[1].ID != sk1.ID {
		t.Fatalf("应按 created_at DESC 排列(新的在前): [0]=%s [1]=%s", list[0].ID, list[1].ID)
	}
	if list[0].SecretKey != "wlsk_l_2" || list[1].SecretKey != "wlsk_l_1" {
		t.Fatalf("列表应含凭据: %+v", list)
	}

	// 空列表:不存在的 agent(0 条密钥)返回空切片,不报错
	none, err := repo.ListByAgent(t.Context(), uuid.NewString())
	if err != nil {
		t.Fatalf("ListByAgent 无密钥 agent 不应报错: %v", err)
	}
	if len(none) != 0 {
		t.Fatalf("无密钥 agent 应空列表,实际 %d 条", len(none))
	}
}

// TestAgentSubKeyRepo_AgentDeleteCascade 守护 FK 级联语义(migration 018):
// agent_sub_keys.agent_id → agents(id) ON DELETE CASCADE。016 原为 NO ACTION,
// AgentRepo.Delete 硬删 agent 会触发 FK 违规并阻断 users→agents 级联链。
// 本测试断言:硬删 agent 不报错,且 ListByAgent 返回空、GetByKey 不再命中——
// 行随级联物理删除,而非逻辑过滤。
func TestAgentSubKeyRepo_AgentDeleteCascade(t *testing.T) {
	db := SetupTestDB(t)
	ur := NewUserRepo(db)
	ar := NewAgentRepo(db)
	repo := NewAgentSubKeyRepo(db)

	u, err := ur.Create(t.Context(), uniqueShortName(t, "ask6"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user: %v", err)
	}
	a, err := ar.Create(t.Context(), u.ID, "agent-cascade", "secret-cascade", "")
	if err != nil {
		t.Fatalf("Create agent: %v", err)
	}
	sk, err := repo.Create(t.Context(), a.ID, "cascade", "wlsk_cascade_1")
	if err != nil {
		t.Fatalf("Create sub key: %v", err)
	}
	if sk.ID == "" {
		t.Fatal("Create sub key 应返回 id")
	}

	// 硬删 agent:ON DELETE CASCADE 下应成功,而非 FK 违规报错
	if err := ar.Delete(t.Context(), a.ID); err != nil {
		t.Fatalf("硬删发过子密钥的 agent 不应报 FK 违规(migration 018 级联): %v", err)
	}

	// ListByAgent 返回空:子密钥行已随级联物理删除
	list, err := repo.ListByAgent(t.Context(), a.ID)
	if err != nil {
		t.Fatalf("ListByAgent after agent delete: %v", err)
	}
	if len(list) != 0 {
		t.Fatalf("agent 删除后子密钥应级联物理删除,实际残留 %d 条: %+v", len(list), list)
	}

	// GetByKey 不再命中:物理删除,非仅吊销(吊销场景 GetByKey 仍返回记录)
	got, err := repo.GetByKey(t.Context(), "wlsk_cascade_1")
	if err != nil {
		t.Fatalf("GetByKey after agent delete: %v", err)
	}
	if got != nil {
		t.Fatalf("agent 删除后凭据不应再命中(行已级联删除): %+v", got)
	}
}
