package hub

import (
	"context"
	"testing"
)

// TestIsParticipant 校验 Hub.IsParticipant 的 IDOR 防护语义:
//   - 真实 participant(user / agent)→ true
//   - 陌生人 / 不存在的 conv → false
//
// 依赖 seedHubParticipantDB 起 testcontainers PG + seed 1 user + 1 agent + 1 conv + 2 participant。
func TestIsParticipant(t *testing.T) {
	h, convID, userID, agentID := seedHubParticipantDB(t)
	ctx := context.Background()

	// user 是 conv 的 participant
	ok, err := h.IsParticipant(ctx, convID, userID, "user")
	if err != nil {
		t.Fatalf("user IsParticipant err: %v", err)
	}
	if !ok {
		t.Fatal("user 应是 participant")
	}

	// agent 是 conv 的 participant
	ok, err = h.IsParticipant(ctx, convID, agentID, "agent")
	if err != nil {
		t.Fatalf("agent IsParticipant err: %v", err)
	}
	if !ok {
		t.Fatal("agent 应是 participant")
	}

	// 陌生人(合法 UUID 但不在 participants 表)不是 participant。
	// member_id 列为 uuid 类型,必须用合法 UUID 格式否则触发 22P02 syntax error。
	ok, err = h.IsParticipant(ctx, convID, "00000000-0000-0000-0000-000000000099", "user")
	if err != nil {
		t.Fatalf("陌生人 IsParticipant err: %v", err)
	}
	if ok {
		t.Fatal("陌生人不应是 participant")
	}

	// 不存在的 conv(合法 UUID 但无记录)→ false(无 participant)
	ok, err = h.IsParticipant(ctx, "00000000-0000-0000-0000-000000000098", userID, "user")
	if err != nil {
		t.Fatalf("不存在 conv IsParticipant err: %v", err)
	}
	if ok {
		t.Fatal("不存在的 conv 不应有 participant")
	}
}

// TestIsParticipant_FailClosedOnNilRepo 验证 participantRepo 未注入时 fail-closed:
// 返 (false, nil) 不 panic。生产 main.go 必注入,此分支仅测试 / 未配置场景兜底。
func TestIsParticipant_FailClosedOnNilRepo(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)
	ok, err := h.IsParticipant(context.Background(), "c-1", "u-1", "user")
	if err != nil {
		t.Fatalf("nil repo 不应有 err: %v", err)
	}
	if ok {
		t.Fatal("nil repo 应 fail-closed 返 false")
	}
}
