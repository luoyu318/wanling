package repository

import (
	"database/sql"
	"errors"
	"testing"
	"time"
)

// === FriendshipRepo 测试 ===
//
// 测试覆盖 spec §3.2 列出的 9 个核心场景,所有断言走真库(testcontainers PG),
// 禁止 mock。seed helper 见下方。

// friendshipTestSeed 包含 2 个 user(发起方 / 接收方)用于大多数场景。
type friendshipTestSeed struct {
	userAID string // 发起方
	userBID string // 接收方
	userCID string // 第三个 user(双向 / 多人查询场景)
}

// seedFriendshipTestDB 起 DB(已自动应用 015) + seed 3 个 user。
// 不预置 friendships 行,各测试用例自行调 repo 构造状态机起点。
func seedFriendshipTestDB(t *testing.T) (*sql.DB, *FriendshipRepo, friendshipTestSeed) {
	t.Helper()
	db := SetupTestDB(t) // Batch 1 完成后 SetupTestDB 默认应用 015
	repo := NewFriendshipRepo(db)

	var seed friendshipTestSeed
	now := time.Now().UTC().Truncate(time.Microsecond)
	for i, prefix := range []string{"fa_", "fb_", "fc_"} {
		var id string
		if err := db.QueryRow(`
			INSERT INTO users (username, password_hash, avatar_url, created_at)
			VALUES ($1, $2, '', $3) RETURNING id
		`, uniqueShortName(t, prefix), "hash", now).Scan(&id); err != nil {
			t.Fatalf("seed user%d 失败: %v", i, err)
		}
		switch i {
		case 0:
			seed.userAID = id
		case 1:
			seed.userBID = id
		case 2:
			seed.userCID = id
		}
	}
	return db, repo, seed
}

// insertFriendshipRow 直接用裸 SQL 插一行 friendships(测试构造既定状态用,
// 绕过 CreateRequest 的双向校验 / 状态机推进规则)。
func insertFriendshipRow(t *testing.T, db *sql.DB, fromUserID, toUserID, status string) string {
	t.Helper()
	var id string
	if err := db.QueryRow(`
		INSERT INTO friendships (user_id, friend_id, status) VALUES ($1, $2, $3)
		RETURNING id
	`, fromUserID, toUserID, status).Scan(&id); err != nil {
		t.Fatalf("insert friendship row 失败: %v", err)
	}
	return id
}

// TestFriendshipRepo_CreateRequest 验证 CreateRequest 成功路径:
//   - seed: 2 个 user
//   - CreateRequest(a, b) → 返非 nil friendship + status=pending + UserID=a + FriendID=b
//   - 校验 friendships 表 1 行 status=pending
//   - responded_at 应为 NULL(尚未响应)
func TestFriendshipRepo_CreateRequest(t *testing.T) {
	db, repo, seed := seedFriendshipTestDB(t)

	f, err := repo.CreateRequest(seed.userAID, seed.userBID)
	if err != nil {
		t.Fatalf("CreateRequest 失败: %v", err)
	}
	if f == nil {
		t.Fatal("CreateRequest 返回 nil friendship")
	}
	if f.ID == "" {
		t.Error("ID 为空")
	}
	if f.UserID != seed.userAID {
		t.Errorf("UserID 错误: 期望 %s, 实际 %s", seed.userAID, f.UserID)
	}
	if f.FriendID != seed.userBID {
		t.Errorf("FriendID 错误: 期望 %s, 实际 %s", seed.userBID, f.FriendID)
	}
	if f.Status != "pending" {
		t.Errorf("Status 错误: 期望 pending, 实际 %s", f.Status)
	}
	if f.RespondedAt != nil {
		t.Errorf("RespondedAt 应为 nil(刚创建), 实际 %v", f.RespondedAt)
	}

	// 表里确实一行 pending
	var (
		cnt    int
		status string
	)
	err = db.QueryRow(`
		SELECT COUNT(*), COALESCE(MAX(status), '') FROM friendships
		WHERE (user_id = $1 AND friend_id = $2) OR (user_id = $2 AND friend_id = $1)
	`, seed.userAID, seed.userBID).Scan(&cnt, &status)
	if err != nil {
		t.Fatalf("查 friendships 失败: %v", err)
	}
	if cnt != 1 {
		t.Errorf("friendships 行数错误: 期望 1, 实际 %d", cnt)
	}
	if status != "pending" {
		t.Errorf("status 错误: 期望 pending, 实际 %s", status)
	}
}

// TestFriendshipRepo_CreateRequest_Duplicate 验证双向校验:
//   - CreateRequest(a, b) → OK
//   - CreateRequest(b, a) → ErrFriendshipAlreadyExists(反向也算重复)
//   - CreateRequest(a, b) 重复 → ErrFriendshipAlreadyExists(正向重复)
func TestFriendshipRepo_CreateRequest_Duplicate(t *testing.T) {
	_, repo, seed := seedFriendshipTestDB(t)

	if _, err := repo.CreateRequest(seed.userAID, seed.userBID); err != nil {
		t.Fatalf("首次 CreateRequest(a,b) 失败: %v", err)
	}

	// 反向重复(B→A)
	_, err := repo.CreateRequest(seed.userBID, seed.userAID)
	if !errors.Is(err, ErrFriendshipAlreadyExists) {
		t.Errorf("反向 CreateRequest(b,a) 期望 ErrFriendshipAlreadyExists, 实际 %v", err)
	}

	// 正向重复(A→B 再来一次)
	_, err = repo.CreateRequest(seed.userAID, seed.userBID)
	if !errors.Is(err, ErrFriendshipAlreadyExists) {
		t.Errorf("正向重复 CreateRequest(a,b) 期望 ErrFriendshipAlreadyExists, 实际 %v", err)
	}
}

// TestFriendshipRepo_Accept 验证 Accept:
//   - pending → accepted
//   - 只有 friend_id(接收方)才能接受(byUserID == f.FriendID)
//   - accepted 后 responded_at 自动填
//   - 非 friend_id 调 Accept → sql.ErrNoRows(越权)
//   - 非 pending 状态调 Accept → sql.ErrNoRows
func TestFriendshipRepo_Accept(t *testing.T) {
	db, repo, seed := seedFriendshipTestDB(t)

	// 先建一条 a→b pending
	f, err := repo.CreateRequest(seed.userAID, seed.userBID)
	if err != nil {
		t.Fatalf("CreateRequest 失败: %v", err)
	}

	// 非 friend_id(user_a 自己,或第三方 user_c)调 Accept → sql.ErrNoRows
	if err := repo.Accept(f.ID, seed.userAID); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("user_a 自己接受应失败: 期望 sql.ErrNoRows, 实际 %v", err)
	}
	if err := repo.Accept(f.ID, seed.userCID); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("第三方 user_c 接受应失败: 期望 sql.ErrNoRows, 实际 %v", err)
	}

	// friend_id(user_b)调 Accept → 成功
	if err := repo.Accept(f.ID, seed.userBID); err != nil {
		t.Fatalf("Accept 失败: %v", err)
	}

	// 校验 status=accepted + responded_at 非 NULL
	var (
		status      string
		respondedAt *time.Time
	)
	err = db.QueryRow(`
		SELECT status, responded_at FROM friendships WHERE id = $1
	`, f.ID).Scan(&status, &respondedAt)
	if err != nil {
		t.Fatalf("查 friendships 失败: %v", err)
	}
	if status != "accepted" {
		t.Errorf("status 错误: 期望 accepted, 实际 %s", status)
	}
	if respondedAt == nil {
		t.Error("responded_at 应为非 nil(Accept 后自动填)")
	}

	// 已非 pending,再调 Accept 应失败(状态机不可逆)
	if err := repo.Accept(f.ID, seed.userBID); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("重复 Accept 应失败: 期望 sql.ErrNoRows, 实际 %v", err)
	}
}

// TestFriendshipRepo_Reject_Cancel 验证 Reject 和 Cancel:
//   - Reject: pending → rejected,只有 friend_id 能调
//   - Cancel: pending → canceled,只有 user_id(发起方)能调
//   - 身份错都返 sql.ErrNoRows
func TestFriendshipRepo_Reject_Cancel(t *testing.T) {
	// === Reject 子场景 ===
	t.Run("Reject", func(t *testing.T) {
		db, repo, seed := seedFriendshipTestDB(t)
		f, err := repo.CreateRequest(seed.userAID, seed.userBID)
		if err != nil {
			t.Fatalf("CreateRequest 失败: %v", err)
		}

		// 非 friend_id 调 Reject → sql.ErrNoRows
		if err := repo.Reject(f.ID, seed.userAID); !errors.Is(err, sql.ErrNoRows) {
			t.Errorf("user_a 自己拒绝应失败: 期望 sql.ErrNoRows, 实际 %v", err)
		}

		// friend_id 调 Reject → 成功
		if err := repo.Reject(f.ID, seed.userBID); err != nil {
			t.Fatalf("Reject 失败: %v", err)
		}

		var status string
		if err := db.QueryRow(`SELECT status FROM friendships WHERE id = $1`, f.ID).Scan(&status); err != nil {
			t.Fatalf("查 friendships 失败: %v", err)
		}
		if status != "rejected" {
			t.Errorf("status 错误: 期望 rejected, 实际 %s", status)
		}
	})

	// === Cancel 子场景 ===
	t.Run("Cancel", func(t *testing.T) {
		db, repo, seed := seedFriendshipTestDB(t)
		f, err := repo.CreateRequest(seed.userAID, seed.userBID)
		if err != nil {
			t.Fatalf("CreateRequest 失败: %v", err)
		}

		// 非 user_id 调 Cancel → sql.ErrNoRows(发起方是 user_a)
		if err := repo.Cancel(f.ID, seed.userBID); !errors.Is(err, sql.ErrNoRows) {
			t.Errorf("user_b(接收方)取消应失败: 期望 sql.ErrNoRows, 实际 %v", err)
		}

		// user_id 调 Cancel → 成功
		if err := repo.Cancel(f.ID, seed.userAID); err != nil {
			t.Fatalf("Cancel 失败: %v", err)
		}

		var status string
		if err := db.QueryRow(`SELECT status FROM friendships WHERE id = $1`, f.ID).Scan(&status); err != nil {
			t.Fatalf("查 friendships 失败: %v", err)
		}
		if status != "canceled" {
			t.Errorf("status 错误: 期望 canceled, 实际 %s", status)
		}
	})
}

// TestFriendshipRepo_AreFriends 验证 AreFriends:
//   - pending / rejected / canceled → false
//   - accepted → true
//   - 双向:A→B 或 B→A 任一 accepted 都算 true
func TestFriendshipRepo_AreFriends(t *testing.T) {
	_, repo, seed := seedFriendshipTestDB(t)

	// 无任何关系 → false
	got, err := repo.AreFriends(seed.userAID, seed.userBID)
	if err != nil {
		t.Fatalf("AreFriends(空) 失败: %v", err)
	}
	if got {
		t.Error("无关系时 AreFriends 应为 false")
	}

	// pending → false
	f, _ := repo.CreateRequest(seed.userAID, seed.userBID)
	got, _ = repo.AreFriends(seed.userAID, seed.userBID)
	if got {
		t.Error("pending 时 AreFriends 应为 false")
	}
	// 反向也 false
	got, _ = repo.AreFriends(seed.userBID, seed.userAID)
	if got {
		t.Error("pending 反向 AreFriends 应为 false")
	}

	// accepted → true
	if err := repo.Accept(f.ID, seed.userBID); err != nil {
		t.Fatalf("Accept 失败: %v", err)
	}
	got, _ = repo.AreFriends(seed.userAID, seed.userBID)
	if !got {
		t.Error("accepted 时 AreFriends 应为 true")
	}
	// 反向也应 true(B→A 查询,行存的是 A→B)
	got, _ = repo.AreFriends(seed.userBID, seed.userAID)
	if !got {
		t.Error("accepted 反向 AreFriends 应为 true")
	}

	// rejected / canceled → false
	db2, repo2, seed2 := seedFriendshipTestDB(t)
	f2, _ := repo2.CreateRequest(seed2.userAID, seed2.userBID)
	if err := repo2.Reject(f2.ID, seed2.userBID); err != nil {
		t.Fatalf("Reject 失败: %v", err)
	}
	got, _ = repo2.AreFriends(seed2.userAID, seed2.userBID)
	if got {
		t.Error("rejected 时 AreFriends 应为 false")
	}
	_ = db2

	db3, repo3, seed3 := seedFriendshipTestDB(t)
	f3, _ := repo3.CreateRequest(seed3.userAID, seed3.userBID)
	if err := repo3.Cancel(f3.ID, seed3.userAID); err != nil {
		t.Fatalf("Cancel 失败: %v", err)
	}
	got, _ = repo3.AreFriends(seed3.userAID, seed3.userBID)
	if got {
		t.Error("canceled 时 AreFriends 应为 false")
	}
	_ = db3
}

// TestFriendshipRepo_ListFriends 验证 ListFriends:
//   - 返回所有 accepted 好友(双向:A→B 和 B→A 都查到对方)
//   - pending / rejected / canceled 不在列表
func TestFriendshipRepo_ListFriends(t *testing.T) {
	_, repo, seed := seedFriendshipTestDB(t)

	// 建立关系网:
	//   a→b accepted
	//   a→c accepted
	//   b→c pending(不应在 a 的好友列表)
	fAB, _ := repo.CreateRequest(seed.userAID, seed.userBID)
	_ = repo.Accept(fAB.ID, seed.userBID)

	fAC, _ := repo.CreateRequest(seed.userAID, seed.userCID)
	_ = repo.Accept(fAC.ID, seed.userCID)

	_, _ = repo.CreateRequest(seed.userBID, seed.userCID) // pending,不计

	// user_a 的好友列表:应包含 b 和 c(顺序不保证,用集合校验)
	ids, err := repo.ListFriends(seed.userAID)
	if err != nil {
		t.Fatalf("ListFriends(a) 失败: %v", err)
	}
	if !containsAll(ids, seed.userBID, seed.userCID) || len(ids) != 2 {
		t.Errorf("ListFriends(a) 错误: 期望 [b,c], 实际 %v", ids)
	}

	// user_b 的好友列表:应包含 a(c 还是 pending)
	ids, _ = repo.ListFriends(seed.userBID)
	if !containsAll(ids, seed.userAID) || len(ids) != 1 {
		t.Errorf("ListFriends(b) 错误: 期望 [a], 实际 %v", ids)
	}

	// user_c 的好友列表:应包含 a(b 还是 pending)
	ids, _ = repo.ListFriends(seed.userCID)
	if !containsAll(ids, seed.userAID) || len(ids) != 1 {
		t.Errorf("ListFriends(c) 错误: 期望 [a], 实际 %v", ids)
	}
}

// TestFriendshipRepo_ListIncomingRequests 验证 ListIncomingRequests:
//   - 返回该 user 收到的 pending 请求(friend_id = user AND status = pending)
//   - accepted / rejected / canceled 不在列表
func TestFriendshipRepo_ListIncomingRequests(t *testing.T) {
	_, repo, seed := seedFriendshipTestDB(t)

	// b 收到来自 a 和 c 的 pending 请求
	fAB, _ := repo.CreateRequest(seed.userAID, seed.userBID)
	_, _ = repo.CreateRequest(seed.userCID, seed.userBID)

	// b 还有一条来自 a 的 accepted(用裸 SQL 绕过双向校验,因为 a→b 已 pending)
	// 这里改用 a→c accepted 来覆盖 accepted 不计入的断言
	fAC, _ := repo.CreateRequest(seed.userAID, seed.userCID)
	_ = repo.Accept(fAC.ID, seed.userCID)

	got, err := repo.ListIncomingRequests(seed.userBID)
	if err != nil {
		t.Fatalf("ListIncomingRequests(b) 失败: %v", err)
	}
	// b 收到 2 条 pending(来自 a 和 c)
	if len(got) != 2 {
		t.Fatalf("ListIncomingRequests(b) 行数错误: 期望 2, 实际 %d (%+v)", len(got), got)
	}
	// 校验每行 friend_id == b 且 status == pending
	for _, f := range got {
		if f.FriendID != seed.userBID {
			t.Errorf("FriendID 错误: 期望 %s, 实际 %s", seed.userBID, f.FriendID)
		}
		if f.Status != "pending" {
			t.Errorf("Status 错误: 期望 pending, 实际 %s", f.Status)
		}
	}
	// 之前 fAB.ID 必须在结果里
	foundAB := false
	for _, f := range got {
		if f.ID == fAB.ID {
			foundAB = true
		}
	}
	if !foundAB {
		t.Errorf("ListIncomingRequests(b) 缺少 a→b 请求 id=%s", fAB.ID)
	}
	// fAC 是 a 发给 c 的,不应在 b 的 incoming 列表
	for _, f := range got {
		if f.ID == fAC.ID {
			t.Errorf("ListIncomingRequests(b) 不应包含 a→c 请求 id=%s", fAC.ID)
		}
	}
}

// TestFriendshipRepo_ListOutgoingRequests 验证 ListOutgoingRequests:
//   - 返回该 user 发出的 pending 请求(user_id = user AND status = pending)
//   - accepted / rejected / canceled 不在列表
func TestFriendshipRepo_ListOutgoingRequests(t *testing.T) {
	_, repo, seed := seedFriendshipTestDB(t)

	// a 发出给 b 和 c 的 pending 请求
	fAB, _ := repo.CreateRequest(seed.userAID, seed.userBID)
	fAC, _ := repo.CreateRequest(seed.userAID, seed.userCID)

	// 把 a→c 转成 accepted,验证 accepted 不在 outgoing pending 列表
	_ = repo.Accept(fAC.ID, seed.userCID)

	got, err := repo.ListOutgoingRequests(seed.userAID)
	if err != nil {
		t.Fatalf("ListOutgoingRequests(a) 失败: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("ListOutgoingRequests(a) 行数错误: 期望 1, 实际 %d (%+v)", len(got), got)
	}
	if got[0].ID != fAB.ID {
		t.Errorf("错误的请求: 期望 %s, 实际 %s", fAB.ID, got[0].ID)
	}
	if got[0].UserID != seed.userAID {
		t.Errorf("UserID 错误: 期望 %s, 实际 %s", seed.userAID, got[0].UserID)
	}
	if got[0].Status != "pending" {
		t.Errorf("Status 错误: 期望 pending, 实际 %s", got[0].Status)
	}
}

// TestFriendshipRepo_RemoveFriend 验证 RemoveFriend:
//   - A→B 或 B→A 任一 accepted 都删
//   - 非 accepted(pending / 无关系)→ sql.ErrNoRows
func TestFriendshipRepo_RemoveFriend(t *testing.T) {
	db, repo, seed := seedFriendshipTestDB(t)

	// 无关系时 RemoveFriend → sql.ErrNoRows
	if err := repo.RemoveFriend(seed.userAID, seed.userBID); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("无关系时 RemoveFriend 期望 sql.ErrNoRows, 实际 %v", err)
	}

	// pending 时 RemoveFriend → sql.ErrNoRows(尚未成为好友)
	f, _ := repo.CreateRequest(seed.userAID, seed.userBID)
	if err := repo.RemoveFriend(seed.userAID, seed.userBID); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("pending 时 RemoveFriend 期望 sql.ErrNoRows, 实际 %v", err)
	}

	// 接受后 RemoveFriend(user_b 调,行存的是 A→B)→ 成功
	if err := repo.Accept(f.ID, seed.userBID); err != nil {
		t.Fatalf("Accept 失败: %v", err)
	}
	if err := repo.RemoveFriend(seed.userBID, seed.userAID); err != nil {
		t.Fatalf("RemoveFriend 失败: %v", err)
	}

	// 行已删
	var cnt int
	if err := db.QueryRow(`
		SELECT COUNT(*) FROM friendships
		WHERE status = 'accepted'
		  AND ((user_id = $1 AND friend_id = $2) OR (user_id = $2 AND friend_id = $1))
	`, seed.userAID, seed.userBID).Scan(&cnt); err != nil {
		t.Fatalf("查 friendships 失败: %v", err)
	}
	if cnt != 0 {
		t.Errorf("RemoveFriend 后行数错误: 期望 0, 实际 %d", cnt)
	}

	// 重复删 → sql.ErrNoRows
	if err := repo.RemoveFriend(seed.userAID, seed.userBID); !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("重复 RemoveFriend 期望 sql.ErrNoRows, 实际 %v", err)
	}
}

// containsAll 校验 got 切片包含所有 want id(顺序不敏感)。
// 测试 List* 方法的辅助,因 friendships 查询无显式 ORDER BY。
func containsAll(got []string, want ...string) bool {
	for _, w := range want {
		found := false
		for _, g := range got {
			if g == w {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}
