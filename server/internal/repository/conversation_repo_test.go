package repository

import (
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/wanling/server/internal/model"
)

// uniqueShortName 把测试函数名压成不超过 32 字符的稳定短串，避免超出 users.username varchar(64) 限制。
// plan 原文用 "testuser_" + t.Name() 会超长（测试函数名本身常 > 50 字符），这里加一层裁剪。
func uniqueShortName(t *testing.T, prefix string) string {
	t.Helper()
	name := strings.ToLower(t.Name())
	// 去掉 Test 前缀和下划线，截短
	name = strings.ReplaceAll(name, "test", "")
	name = strings.ReplaceAll(name, "_", "")
	if len(name) > 20 {
		name = name[:20]
	}
	return prefix + name
}

// TestConversationRepo_FindOrCreate_WithLastMessageContent 验证新建会话时
// last_message_content 应为 NULL（NullJSON.Valid=false）。
// 这是 scan NULL JSONB 的关键回归保护：不能 panic、不能报错。
// 直接用 json.RawMessage 会触发 "unsupported Scan, storing driver.Value type <nil>"。
func TestConversationRepo_FindOrCreate_WithLastMessageContent(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)

	urepo := NewUserRepo(db)
	user, err := urepo.Create(uniqueShortName(t, "u_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	arepo := NewAgentRepo(db)
	// 注意：实际 AgentRepo.Create 签名为 Create(ownerID, name, secretKey)，plan 文档遗漏了 secretKey
	agent, err := arepo.Create(user.ID, "TestAgent", "test-secret-key")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}

	conv, err := repo.FindOrCreate(user.ID, agent.ID)
	if err != nil {
		t.Fatalf("FindOrCreate 失败: %v", err)
	}
	if conv.LastMessageContent.Valid {
		t.Errorf("新会话 last_message_content 应为 NULL（Valid=false），实际 Valid=true, Raw=%s",
			conv.LastMessageContent.RawMessage)
	}
}

// TestConversationRepo_ListByUser_ReadsLastMessageContent 验证：
//  1. 已写入 last_message_content 的会话能正确 scan 出来；
//  2. scan 出的字节切片是合法 JSON，且字段值正确。
// 通过 repo.UpdateLastMessage 写缓存，不再绕过到裸 SQL。
// 排序（last_message_at DESC）的覆盖见 TestConversationRepo_ListWithAgent_OrdersByLastMessageAtDesc。
func TestConversationRepo_ListByUser_ReadsLastMessageContent(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	urepo := NewUserRepo(db)
	user, err := urepo.Create(uniqueShortName(t, "l_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	arepo := NewAgentRepo(db)
	agent, err := arepo.Create(user.ID, "ListAgent", "test-secret-key")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}

	conv, err := repo.FindOrCreate(user.ID, agent.ID)
	if err != nil {
		t.Fatalf("FindOrCreate 失败: %v", err)
	}

	// 写入一条消息（让 last_message_content 有内容可灌）
	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "hello"},
	})
	mrepo := NewMessageRepo(db)
	if _, err := mrepo.Create(conv.ID, "user", user.ID, content); err != nil {
		t.Fatalf("Create message 失败: %v", err)
	}
	// 通过 UpdateLastMessage 写缓存（content 与 last_message_at=NOW()）
	if err := repo.UpdateLastMessage(conv.ID, content); err != nil {
		t.Fatalf("UpdateLastMessage 失败: %v", err)
	}

	list, err := repo.ListByUser(user.ID)
	if err != nil {
		t.Fatalf("ListByUser 失败: %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("列表数量异常: %d (期望 1)", len(list))
	}
	if !list[0].LastMessageContent.Valid {
		t.Fatalf("LastMessageContent 未读出，期望 Valid=true")
	}
	// 反序列化校验：scan 出来的字节切片必须是合法 JSON，且字段值正确
	var got map[string]interface{}
	if err := json.Unmarshal(list[0].LastMessageContent.RawMessage, &got); err != nil {
		t.Fatalf("反序列化 LastMessageContent 失败: %v", err)
	}
	if got["msg_type"] != "text" {
		t.Errorf("msg_type 字段不正确: %v", got["msg_type"])
	}
}

// TestConversationRepo_GetByID_LastMessageContentIsNull 兜底 GetByID：
// 空会话（无消息）的 last_message_content 为 NULL，scan 不能报错。
func TestConversationRepo_GetByID_LastMessageContentIsNull(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	urepo := NewUserRepo(db)
	user, err := urepo.Create(uniqueShortName(t, "g_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	arepo := NewAgentRepo(db)
	agent, err := arepo.Create(user.ID, "GetByIDAgent", "test-secret-key")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}

	conv, err := repo.FindOrCreate(user.ID, agent.ID)
	if err != nil {
		t.Fatalf("FindOrCreate 失败: %v", err)
	}

	got, err := repo.GetByID(conv.ID)
	if err != nil {
		t.Fatalf("GetByID 失败: %v", err)
	}
	if got == nil {
		t.Fatalf("GetByID 返回 nil")
	}
	if got.LastMessageContent.Valid {
		t.Errorf("空会话 last_message_content 应为 NULL，实际 Valid=true, Raw=%s",
			got.LastMessageContent.RawMessage)
	}
}

// TestNullJSON_JSONSerialization 校验 NullJSON 的 JSON 序列化行为符合预期：
//   - NULL → 输出 "null"；
//   - 非 NULL → 透传 JSON 内容。
// 避免 handler 层因 JSON 输出格式变化踩坑。
func TestNullJSON_JSONSerialization(t *testing.T) {
	// Valid=false → null
	n := model.NullJSON{}
	out, err := json.Marshal(struct {
		X model.NullJSON `json:"x"`
	}{X: n})
	if err != nil {
		t.Fatalf("Marshal 失败: %v", err)
	}
	if string(out) != `{"x":null}` {
		t.Errorf("NULL 序列化异常: %s (期望 {\"x\":null})", string(out))
	}

	// Valid=true → 透传
	n.Valid = true
	n.RawMessage = json.RawMessage(`{"a":1}`)
	out, err = json.Marshal(struct {
		X model.NullJSON `json:"x"`
	}{X: n})
	if err != nil {
		t.Fatalf("Marshal 失败: %v", err)
	}
	if string(out) != `{"x":{"a":1}}` {
		t.Errorf("非 NULL 序列化异常: %s", string(out))
	}
}

// TestConversationRepo_ListWithAgent_ReturnsAgentAndLastMessage 验证 ListWithAgent：
//  1. JOIN agents 表，返回的 item.Agent 字段填充正确；
//  2. last_message_content 非 NULL 时正确读出 Valid=true。
// 这是 IM 风格会话列表的数据来源测试。
func TestConversationRepo_ListWithAgent_ReturnsAgentAndLastMessage(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, err := urepo.Create(uniqueShortName(t, "lwauser"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agent, err := arepo.Create(user.ID, "LWAAgent", "secret-key-placeholder")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}

	conv, err := repo.FindOrCreate(user.ID, agent.ID)
	if err != nil {
		t.Fatalf("FindOrCreate 失败: %v", err)
	}
	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "hi"},
	})
	// 通过 UpdateLastMessage 写缓存（content 与 last_message_at=NOW()）
	if err := repo.UpdateLastMessage(conv.ID, content); err != nil {
		t.Fatalf("UpdateLastMessage 失败: %v", err)
	}

	items, err := repo.ListWithAgent(user.ID)
	if err != nil {
		t.Fatalf("ListWithAgent 失败: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("期望 1 条，实际: %d", len(items))
	}
	if items[0].Agent.ID != agent.ID {
		t.Errorf("agent.id 不匹配: got=%s want=%s", items[0].Agent.ID, agent.ID)
	}
	if items[0].Agent.Name != "LWAAgent" {
		t.Errorf("agent.name 不匹配: %s", items[0].Agent.Name)
	}
	if !items[0].LastMessageContent.Valid {
		t.Errorf("last_message_content 不应为 NULL")
	}
}

// TestConversationRepo_ListWithAgent_ExcludesNoMessageConversations 验证：
// 无消息会话（last_message_content IS NULL）不应进入 IM 列表。
// 这是 IM 列表的核心语义：列表里只展示已经发生过对话的会话。
func TestConversationRepo_ListWithAgent_ExcludesNoMessageConversations(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, err := urepo.Create(uniqueShortName(t, "excluser"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agent, err := arepo.Create(user.ID, "ExclAgent", "secret-key-placeholder")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}
	if _, err := repo.FindOrCreate(user.ID, agent.ID); err != nil {
		t.Fatalf("FindOrCreate 失败: %v", err)
	}

	items, err := repo.ListWithAgent(user.ID)
	if err != nil {
		t.Fatalf("ListWithAgent 失败: %v", err)
	}
	if len(items) != 0 {
		t.Errorf("无消息会话不应进列表，实际: %d 条", len(items))
	}
}

// TestConversationRepo_ListWithAgent_OrdersByLastMessageAtDesc 验证排序：
// 插入 2 条会话（A 早 B 晚），期望首条为 B。
// ListByUser 测试没覆盖排序，这里补齐 IM 列表的排序语义。
func TestConversationRepo_ListWithAgent_OrdersByLastMessageAtDesc(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, err := urepo.Create(uniqueShortName(t, "orduser"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agentA, err := arepo.Create(user.ID, "AgentA", "key-a")
	if err != nil {
		t.Fatalf("Create agentA 失败: %v", err)
	}
	agentB, err := arepo.Create(user.ID, "AgentB", "key-b")
	if err != nil {
		t.Fatalf("Create agentB 失败: %v", err)
	}

	convA, err := repo.FindOrCreate(user.ID, agentA.ID)
	if err != nil {
		t.Fatalf("FindOrCreate A 失败: %v", err)
	}
	convB, err := repo.FindOrCreate(user.ID, agentB.ID)
	if err != nil {
		t.Fatalf("FindOrCreate B 失败: %v", err)
	}

	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "hi"},
	})
	// 注意：这里不能用 repo.UpdateLastMessage。
	// UpdateLastMessage 总是用 NOW() 写 last_message_at，无法手动设置过去时间，
	// 而本测试要构造 A 早 1 小时、B 当前的对比场景来验证 DESC 排序，
	// 所以只能用裸 SQL 直接控制 last_message_at。
	// A 早 1 小时
	if _, err := db.Exec(
		`UPDATE conversations SET last_message_content = $1, last_message_at = NOW() - INTERVAL '1 hour' WHERE id = $2`,
		content, convA.ID,
	); err != nil {
		t.Fatalf("UPDATE A 失败: %v", err)
	}
	// B 当前
	if _, err := db.Exec(
		`UPDATE conversations SET last_message_content = $1, last_message_at = NOW() WHERE id = $2`,
		content, convB.ID,
	); err != nil {
		t.Fatalf("UPDATE B 失败: %v", err)
	}

	items, err := repo.ListWithAgent(user.ID)
	if err != nil {
		t.Fatalf("ListWithAgent 失败: %v", err)
	}
	if len(items) != 2 {
		t.Fatalf("期望 2 条，实际: %d", len(items))
	}
	if items[0].Agent.Name != "AgentB" {
		t.Errorf("期望首条为 AgentB（最新），实际: %s", items[0].Agent.Name)
	}
}

// TestConversationRepo_FindOrCreate_DoesNotUpdateLastMessageAtOnConflict 回归保护：
// 再次对已存在会话调用 FindOrCreate 不应污染 last_message_at。
// 之前的实现用 DO UPDATE SET last_message_at = NOW()，会让"重新打开空会话"也更新时间戳，
// 干扰 ListWithAgent 按 last_message_at DESC 的排序。
// 改造为 ON CONFLICT DO NOTHING + 二次 SELECT 后，必须保证时间戳保持原值。
func TestConversationRepo_FindOrCreate_DoesNotUpdateLastMessageAtOnConflict(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, err := urepo.Create(uniqueShortName(t, "dupuser"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agent, err := arepo.Create(user.ID, "DupAgent", "secret-key-placeholder")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}

	// 首次创建
	conv1, err := repo.FindOrCreate(user.ID, agent.ID)
	if err != nil {
		t.Fatalf("首次 FindOrCreate 失败: %v", err)
	}

	// 用裸 SQL 写入一个"过去"的 last_message_at（与新建时 NOW() 区分开）
	// 仅在 last_message_content 也写入的情况下才有意义；否则字段会保持 NULL/默认。
	pastContent := []byte(`{"msg_type":"text","data":{"text":"past"}}`)
	if _, err := db.Exec(
		`UPDATE conversations SET last_message_content = $1, last_message_at = NOW() - INTERVAL '2 hours' WHERE id = $2`,
		pastContent, conv1.ID,
	); err != nil {
		t.Fatalf("写过去时间戳失败: %v", err)
	}

	// 再次 FindOrCreate（命中 ON CONFLICT 路径）
	conv2, err := repo.FindOrCreate(user.ID, agent.ID)
	if err != nil {
		t.Fatalf("二次 FindOrCreate 失败: %v", err)
	}
	if conv2.ID != conv1.ID {
		t.Fatalf("二次返回的会话 ID 不一致: %s vs %s", conv1.ID, conv2.ID)
	}

	// 取出真实存储的 last_message_at，验证没有被 NOW() 覆盖
	var storedAt time.Time
	if err := db.QueryRow(
		`SELECT last_message_at FROM conversations WHERE id = $1`, conv1.ID,
	).Scan(&storedAt); err != nil {
		t.Fatalf("SELECT last_message_at 失败: %v", err)
	}
	// 期望仍然在 1 小时之前（即 2 小时 - 1 小时容差），证明没有被 NOW() 改成"现在"
	if time.Since(storedAt) < time.Hour {
		t.Errorf("二次 FindOrCreate 污染了 last_message_at: storedAt=%v, 距现在=%v",
			storedAt, time.Since(storedAt))
	}
}

// TestConversationRepo_UpdateLastMessage_WritesCache 验证 UpdateLastMessage：
// 写入后 GetByID 应能读出 LastMessageContent.Valid=true 且内容正确。
// 这是写消息路径的缓存更新点（消息 processor 在持久化消息后调用）。
func TestConversationRepo_UpdateLastMessage_WritesCache(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, err := urepo.Create(uniqueShortName(t, "ulmuser"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agent, err := arepo.Create(user.ID, "ULMAgent", "secret-key-placeholder")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}
	conv, err := repo.FindOrCreate(user.ID, agent.ID)
	if err != nil {
		t.Fatalf("FindOrCreate 失败: %v", err)
	}

	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "cached"},
	})
	if err := repo.UpdateLastMessage(conv.ID, content); err != nil {
		t.Fatalf("UpdateLastMessage 失败: %v", err)
	}

	got, err := repo.GetByID(conv.ID)
	if err != nil {
		t.Fatalf("GetByID 失败: %v", err)
	}
	if got == nil {
		t.Fatalf("GetByID 返回 nil")
	}
	if !got.LastMessageContent.Valid {
		t.Fatalf("UpdateLastMessage 后 LastMessageContent 应为 Valid")
	}
	// 反序列化校验：内容正确写入
	var m map[string]interface{}
	if err := json.Unmarshal(got.LastMessageContent.RawMessage, &m); err != nil {
		t.Fatalf("反序列化失败: %v", err)
	}
	data, _ := m["data"].(map[string]interface{})
	if data["text"] != "cached" {
		t.Errorf("内容不匹配: %v", m)
	}
}

// TestConversationRepo_IncrUnreadTx_AndMarkRead 验证事务内未读++，
// 以及 MarkRead 重置为 0（含 user_id 校验）。
func TestConversationRepo_IncrUnreadTx_AndMarkRead(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)

	user, _ := NewUserRepo(db).Create(uniqueShortName(t, "ur_"), "$2a$10$hash")
	agent, _ := NewAgentRepo(db).Create(user.ID, "Agent", "secret-key-placeholder")
	conv, err := repo.FindOrCreate(user.ID, agent.ID)
	if err != nil {
		t.Fatalf("FindOrCreate: %v", err)
	}

	// 2 次 IncrUnreadTx
	for i := 0; i < 2; i++ {
		tx, err := repo.BeginTx()
		if err != nil {
			t.Fatalf("BeginTx: %v", err)
		}
		if err := repo.IncrUnreadTx(tx, conv.ID); err != nil {
			t.Fatalf("IncrUnreadTx: %v", err)
		}
		if err := tx.Commit(); err != nil {
			t.Fatalf("Commit: %v", err)
		}
	}

	// 验证 unread_count = 2（直接 raw query，因为 GetByID 不返回该字段）
	var n int
	if err := db.QueryRow(`SELECT unread_count FROM conversations WHERE id = $1`, conv.ID).Scan(&n); err != nil {
		t.Fatalf("query unread_count: %v", err)
	}
	if n != 2 {
		t.Errorf("unread_count = %d, want 2", n)
	}

	// MarkRead 清零
	if err := repo.MarkRead(conv.ID, user.ID); err != nil {
		t.Fatalf("MarkRead: %v", err)
	}
	if err := db.QueryRow(`SELECT unread_count FROM conversations WHERE id = $1`, conv.ID).Scan(&n); err != nil {
		t.Fatalf("query after MarkRead: %v", err)
	}
	if n != 0 {
		t.Errorf("after MarkRead unread_count = %d, want 0", n)
	}
}

// TestConversationRepo_MarkRead_RejectsWrongUser 验证 user_id 校验：
// 其他用户调 MarkRead 返回 sql.ErrNoRows。
func TestConversationRepo_MarkRead_RejectsWrongUser(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)

	owner, _ := NewUserRepo(db).Create(uniqueShortName(t, "own_"), "$2a$10$hash")
	other, _ := NewUserRepo(db).Create(uniqueShortName(t, "oth_"), "$2a$10$hash")
	agent, _ := NewAgentRepo(db).Create(owner.ID, "Agent", "secret-key-placeholder")
	conv, _ := repo.FindOrCreate(owner.ID, agent.ID)

	err := repo.MarkRead(conv.ID, other.ID)
	if err == nil {
		t.Errorf("期望 err（其他用户），实际 nil")
	}
}

// TestConversationRepo_GetUnreadCount 校验 GetUnreadCount：
//   - 正常返回 unread_count；
//   - user_id 不匹配（越权）返回 sql.ErrNoRows。
func TestConversationRepo_GetUnreadCount(t *testing.T) {
	db := SetupTestDB(t)
	userRepo := NewUserRepo(db)
	agentRepo := NewAgentRepo(db)
	convRepo := NewConversationRepo(db)
	msgRepo := NewMessageRepo(db)

	user, err := userRepo.Create(uniqueShortName(t, "uc_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	other, err := userRepo.Create(uniqueShortName(t, "uc2_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create other 失败: %v", err)
	}
	agent, err := agentRepo.Create(user.ID, "UC-Agent", "secret")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}
	conv, err := convRepo.FindOrCreate(user.ID, agent.ID)
	if err != nil {
		t.Fatalf("FindOrCreate 失败: %v", err)
	}

	// 制造 2 条未读消息
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)
	if _, err := msgRepo.Create(conv.ID, "agent", agent.ID, content); err != nil {
		t.Fatalf("Create m1 失败: %v", err)
	}
	if _, err := msgRepo.Create(conv.ID, "agent", agent.ID, content); err != nil {
		t.Fatalf("Create m2 失败: %v", err)
	}
	// IncrUnreadTx 需要事务
	tx, err := convRepo.BeginTx()
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	if err := convRepo.IncrUnreadTx(tx, conv.ID); err != nil {
		t.Fatalf("IncrUnreadTx 失败: %v", err)
	}
	if err := convRepo.IncrUnreadTx(tx, conv.ID); err != nil {
		t.Fatalf("IncrUnreadTx 2 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit 失败: %v", err)
	}

	// 正常调用：返回 2
	count, err := convRepo.GetUnreadCount(conv.ID, user.ID)
	if err != nil {
		t.Fatalf("GetUnreadCount 失败: %v", err)
	}
	if count != 2 {
		t.Errorf("期望未读 2，实际 %d", count)
	}

	// 越权：用别的 user_id 查，应返回 sql.ErrNoRows
	_, err = convRepo.GetUnreadCount(conv.ID, other.ID)
	if !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("越权应返回 sql.ErrNoRows，实际 %v", err)
	}
}
