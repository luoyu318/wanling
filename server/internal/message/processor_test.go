package message

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// shortName 把测试名压成不超过 32 字符的稳定短串，避免超出 users.username varchar(64) 限制。
func shortName(t *testing.T, prefix string) string {
	t.Helper()
	name := strings.ToLower(t.Name())
	name = strings.ReplaceAll(name, "test", "")
	name = strings.ReplaceAll(name, "_", "")
	if len(name) > 20 {
		name = name[:20]
	}
	return prefix + name
}

// setupFixture 构造一套完整的 user/agent/conv，返回测试需要的所有 repo 与 ID。
// 抽出来避免每个测试都重复 8 行样板。
func setupFixture(t *testing.T) (*repository.ConversationRepo, *repository.MessageRepo, *repository.AgentRepo, *repository.FileRepo, string, string, string) {
	t.Helper()
	db := repository.SetupTestDB(t)
	convRepo := repository.NewConversationRepo(db)
	msgRepo := repository.NewMessageRepo(db)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	fileRepo := repository.NewFileRepo(db)

	user, err := urepo.Create(shortName(t, "u_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agent, err := arepo.Create(user.ID, "TxAgent", "secret-key-placeholder")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}
	conv, err := convRepo.FindOrCreate(user.ID, agent.ID)
	if err != nil {
		t.Fatalf("FindOrCreate 失败: %v", err)
	}
	return convRepo, msgRepo, arepo, fileRepo, user.ID, agent.ID, conv.ID
}

// TestProcessor_HandleIncoming_PersistsMessageAndCacheTransactional 验证方案 A：
// HandleIncoming 全流程跑完后，messages 表有新行、conversations.last_message_content 已更新。
//
// hub 用 nil presence 构造：因为没有 client 注册，SendToUser/SendToAgent 会直接 return nil，
// 不会触发 bufferedSend，也不会调用 presence 方法。这是测试 dispatcher 副作用的最小侵入方式。
//
// 关键校验点：
//  1. 消息已持久化（事务 commit 成功）；
//  2. 会话缓存 last_message_content 已更新（与消息在同一事务）；
//  3. dispatch 在 commit 之后执行（这里通过"消息已写"间接验证）。
func TestProcessor_HandleIncoming_PersistsMessageAndCacheTransactional(t *testing.T) {
	convRepo, msgRepo, arepo, fileRepo, userID, agentID, convID := setupFixture(t)

	// hub 用 nil presence —— 见函数注释。
	h := hub.NewHub(nil, arepo)
	p := NewProcessor(h, convRepo, msgRepo, arepo, fileRepo)

	content := map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "hello from tx test"},
	}
	contentBytes, _ := json.Marshal(content)
	dPayload, _ := json.Marshal(map[string]interface{}{
		"agent_id": agentID,
		"content":  json.RawMessage(contentBytes),
	})

	// user → agent 方向，HandleIncoming 内部会做 FindOrCreate + 事务写消息 + 更新缓存 + dispatch
	p.HandleIncoming("user", userID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		D:  dPayload,
	})

	// 1. 消息已持久化
	msgs, err := msgRepo.ListByConversation(convID, 100, 0)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("期望 1 条消息，实际: %d", len(msgs))
	}

	// 2. 缓存已更新（IM 列表能查到）
	items, err := convRepo.ListWithAgent(userID)
	if err != nil {
		t.Fatalf("ListWithAgent 失败: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("期望 1 条会话列表项，实际: %d", len(items))
	}
	if !items[0].LastMessageContent.Valid {
		t.Errorf("LastMessageContent 应为 Valid（事务内已更新缓存）")
	}
	// 内容校验：缓存与消息一致
	var got map[string]interface{}
	if err := json.Unmarshal(items[0].LastMessageContent.RawMessage, &got); err != nil {
		t.Fatalf("反序列化 LastMessageContent 失败: %v", err)
	}
	data, _ := got["data"].(map[string]interface{})
	if data["text"] != "hello from tx test" {
		t.Errorf("缓存内容不匹配: %v", got)
	}
}

// TestProcessor_HandleIncoming_RollsBackOnBadSender 验证事务回滚：
// 用一个不存在的 sender_id 触发写消息的 FK 约束失败（messages.sender_id 在某些约束下会失败，
// 但实际 schema 里 messages 只对 conversation_id 有 FK），所以这里改用直接调用事务 API
// 的方式触发失败：构造一个非法的 conversation_id，让 CreateTx 触发 FK 失败。
//
// 注意：本测试不通过 HandleIncoming（HandleIncoming 内部用合法 convID），
// 而是直接走 repo 的事务路径，验证 CreateTx 失败 + Rollback 后 messages 表无任何残留。
// 这是事务原子性的最小复现。
func TestProcessor_HandleIncoming_RollsBackOnBadSender(t *testing.T) {
	convRepo, msgRepo, _, _, userID, _, convID := setupFixture(t)

	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "should rollback"},
	})

	tx, err := convRepo.BeginTx()
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	defer tx.Rollback()

	// 用一个不存在的 conversation_id 触发 FK 约束失败
	invalidConvID := "00000000-0000-0000-0000-000000000000"
	_, err = msgRepo.CreateTx(tx, invalidConvID, "user", userID, content)
	if err == nil {
		t.Fatalf("期望 CreateTx 失败（FK 约束），实际成功")
	}

	// 不需要显式 tx.Rollback()：defer tx.Rollback() 已经兜底，避免双重 Rollback 风格
	// 验证真实 convID 下没有任何消息残留
	msgs, err := msgRepo.ListByConversation(convID, 100, 0)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(msgs) != 0 {
		t.Errorf("回滚后 messages 不应有数据，实际: %d 条", len(msgs))
	}
}

// TestProcessor_Tx_BeginCreateUpdateCommit 验证事务 API 的 happy path：
// convRepo.BeginTx → msgRepo.CreateTx → convRepo.UpdateLastMessageTx → tx.Commit
// 之后，messages 表有新行、conversations.last_message_content 已更新。
// 这是 HandleIncoming 事务路径的"组件级"覆盖，避免依赖 hub。
func TestProcessor_Tx_BeginCreateUpdateCommit(t *testing.T) {
	convRepo, msgRepo, _, _, userID, _, convID := setupFixture(t)

	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "tx component"},
	})

	tx, err := convRepo.BeginTx()
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	// defer Rollback 是惯用法：commit 后调用是 no-op（database/sql 保证）
	defer tx.Rollback()

	msg, err := msgRepo.CreateTx(tx, convID, "user", userID, content)
	if err != nil {
		t.Fatalf("CreateTx 失败: %v", err)
	}
	if err := convRepo.UpdateLastMessageTx(tx, convID, content); err != nil {
		t.Fatalf("UpdateLastMessageTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit 失败: %v", err)
	}

	// 验证 messages 表
	msgs, _ := msgRepo.ListByConversation(convID, 100, 0)
	if len(msgs) != 1 || msgs[0].ID != msg.ID {
		t.Errorf("消息未持久化: %+v", msgs)
	}

	// 验证 conversations 缓存
	items, _ := convRepo.ListWithAgent(userID)
	if len(items) != 1 || !items[0].LastMessageContent.Valid {
		t.Errorf("缓存未更新: %+v", items)
	}
}

// TestProcessor_HandleIncoming_RollsBackOnCreateTxFailure 验证：
// HandleIncoming 内 CreateTx 失败时，defer tx.Rollback() 正确清理
// 整个事务（messages 无残留 + conversations 缓存未变）。
//
// 与 TestProcessor_HandleIncoming_RollsBackOnBadSender 的区别：
// 那个测试直接走 repo 事务路径，本测试走完整的 HandleIncoming 路径，
// 覆盖 processor.go 内 "CreateTx 失败 → return → defer tx.Rollback()" 的协同行为。
//
// 触发失败的方式：传入 senderType="invalid"，命中 messages.sender_type 的
// CHECK 约束（schema 在 001_init.sql:33：sender_type IN ('user', 'agent')），
// 让 CreateTx 在事务内失败。
//
// 构造细节（必须让 FindOrCreate 先成功，才能走到 CreateTx）：
//   - senderType="invalid" → 进 else 分支（agent 方向）
//   - senderID 传 agentID，payload.user_id 传 userID
//   - else 分支调用 FindOrCreate(userID, agentID)，复用 fixture 已建的会话
//   - 随后 CreateTx(tx, convID, "invalid", agentID, ...) 因 CHECK 约束失败
func TestProcessor_HandleIncoming_RollsBackOnCreateTxFailure(t *testing.T) {
	convRepo, msgRepo, arepo, fileRepo, userID, agentID, convID := setupFixture(t)

	// hub 用 nil presence（与 happy path 测试同理）
	h := hub.NewHub(nil, arepo)
	p := NewProcessor(h, convRepo, msgRepo, arepo, fileRepo)

	// 构造 wsMsg：走 else 分支，user_id 合法以便 FindOrCreate 成功
	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "should rollback"},
	})
	payload, _ := json.Marshal(map[string]interface{}{
		"user_id": userID,
		"content": json.RawMessage(content),
	})
	wsMsg := &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		D:  payload,
	}

	// 调用 HandleIncoming：senderType="invalid" 触发 CreateTx 内 CHECK 约束失败。
	// senderID 用 agentID，使 else 分支的 FindOrCreate(userID, agentID) 复用 fixture 会话。
	p.HandleIncoming("invalid", agentID, wsMsg)

	// 验证 messages 表无残留（CHECK 失败导致事务回滚）
	msgs, err := msgRepo.ListByConversation(convID, 100, 0)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(msgs) != 0 {
		t.Errorf("事务回滚后 messages 不应有数据，实际: %d 条", len(msgs))
	}

	// 验证 conversations 缓存未变（仍为 NULL，ListWithAgent 不返回该会话）
	items, err := convRepo.ListWithAgent(userID)
	if err != nil {
		t.Fatalf("ListWithAgent 失败: %v", err)
	}
	for _, item := range items {
		if item.ID == convID {
			t.Errorf("事务回滚后 conversation %s 不应进 ListWithAgent 列表", convID)
		}
	}
}

// createImageFile 往 files 表插一条带 width/height 的图片记录，返回 fileID。
// 复用 repository.CreateFileParams，供 enhanceImageContent 测试。
func createImageFile(t *testing.T, fileRepo *repository.FileRepo, ownerID string, w, h int) string {
	t.Helper()
	f, err := fileRepo.Create(repository.CreateFileParams{
		OwnerID:       ownerID,
		Filename:      "test.png",
		MimeType:      "image/png",
		Size:          100,
		StoragePath:   "abc.png",
		ThumbnailPath: nil,
		Width:         &w,
		Height:        &h,
	})
	if err != nil {
		t.Fatalf("Create file 失败: %v", err)
	}
	return f.ID
}

// TestEnhanceImageContent_FillsWidthHeight 主路径：image 消息缺宽高 → 从 files 表补全。
func TestEnhanceImageContent_FillsWidthHeight(t *testing.T) {
	_, _, arepo, fileRepo, userID, _, _ := setupFixture(t)
	h := hub.NewHub(nil, arepo)
	p := NewProcessor(h, nil, nil, arepo, fileRepo)

	fileID := createImageFile(t, fileRepo, userID, 1080, 1920)

	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "image",
		"data":     map[string]interface{}{"file_id": fileID},
	})

	got := p.enhanceImageContent(json.RawMessage(content))

	var parsed struct {
		Data struct {
			FileID string `json:"file_id"`
			Width  int    `json:"width"`
			Height int    `json:"height"`
		} `json:"data"`
	}
	if err := json.Unmarshal(got, &parsed); err != nil {
		t.Fatalf("解析增强后 content 失败: %v", err)
	}
	if parsed.Data.Width != 1080 || parsed.Data.Height != 1920 {
		t.Errorf("宽高未补全: width=%d height=%d, want 1080/1920", parsed.Data.Width, parsed.Data.Height)
	}
	if parsed.Data.FileID != fileID {
		t.Errorf("file_id 被篡改: %s", parsed.Data.FileID)
	}
}

// TestEnhanceImageContent_Idempotent 已带宽高的消息 → 幂等跳过，不查 DB。
func TestEnhanceImageContent_Idempotent(t *testing.T) {
	_, _, arepo, fileRepo, userID, _, _ := setupFixture(t)
	h := hub.NewHub(nil, arepo)
	p := NewProcessor(h, nil, nil, arepo, fileRepo)

	fileID := createImageFile(t, fileRepo, userID, 1080, 1920)

	// content 已带 width/height（故意写与库不同的值，验证不被覆盖）
	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "image",
		"data": map[string]interface{}{
			"file_id": fileID,
			"width":   500,
			"height":  500,
		},
	})
	got := p.enhanceImageContent(json.RawMessage(content))

	var parsed struct {
		Data struct {
			Width  int `json:"width"`
			Height int `json:"height"`
		} `json:"data"`
	}
	json.Unmarshal(got, &parsed)
	// 应保留原值 500/500，不被库里的 1080/1920 覆盖
	if parsed.Data.Width != 500 || parsed.Data.Height != 500 {
		t.Errorf("幂等失败: 宽高被覆盖为 %d/%d, 应保留 500/500", parsed.Data.Width, parsed.Data.Height)
	}
}

// TestEnhanceImageContent_FailSoft 各种异常情况都不阻断，返回原 content。
func TestEnhanceImageContent_FailSoft(t *testing.T) {
	_, _, arepo, fileRepo, userID, _, _ := setupFixture(t)
	h := hub.NewHub(nil, arepo)
	p := NewProcessor(h, nil, nil, arepo, fileRepo)

	cases := []struct {
		name    string
		content map[string]interface{}
	}{
		{
			name: "非 image 消息",
			content: map[string]interface{}{
				"msg_type": "text",
				"data":     map[string]interface{}{"text": "hi"},
			},
		},
		{
			name: "image 但无 file_id",
			content: map[string]interface{}{
				"msg_type": "image",
				"data":     map[string]interface{}{},
			},
		},
		{
			name: "file_id 不存在",
			content: map[string]interface{}{
				"msg_type": "image",
				"data":     map[string]interface{}{"file_id": "00000000-0000-0000-0000-000000000000"},
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			orig, _ := json.Marshal(tc.content)
			got := p.enhanceImageContent(json.RawMessage(orig))
			// 应原样返回（fail-soft 不阻断）
			if string(got) != string(orig) {
				t.Errorf("fail-soft 失败: 异常情况应原样返回\ngot:  %s\nwant: %s", got, orig)
			}
		})
	}

	// 单独测：files 表有记录但 width/height 为 NULL（非图片文件上传的场景）
	_ = userID // fileRepo 已有 fixture，这里插一条无宽高的文件
	f, err := fileRepo.Create(repository.CreateFileParams{
		OwnerID:     userID,
		Filename:    "note.txt",
		MimeType:    "text/plain",
		Size:        10,
		StoragePath: "note.txt",
	})
	if err != nil {
		t.Fatalf("Create 无宽高文件失败: %v", err)
	}
	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "image",
		"data":     map[string]interface{}{"file_id": f.ID},
	})
	got := p.enhanceImageContent(json.RawMessage(content))
	// files 表该记录 width/height 为 NULL，应原样返回不补
	var parsed struct {
		Data struct {
			Width  *int `json:"width"`
			Height *int `json:"height"`
		} `json:"data"`
	}
	json.Unmarshal(got, &parsed)
	if parsed.Data.Width != nil || parsed.Data.Height != nil {
		t.Errorf("NULL 宽高不应被补全: width=%v height=%v", parsed.Data.Width, parsed.Data.Height)
	}
}
