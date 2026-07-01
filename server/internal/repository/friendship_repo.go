package repository

import (
	"database/sql"
	"errors"

	"github.com/wanling/server/internal/model"
)

// ErrFriendshipAlreadyExists 表示两人之间已存在好友关系(任意状态)。
// CreateRequest 双向校验命中时返回,handler 据此转 409 Conflict。
var ErrFriendshipAlreadyExists = errors.New("friendship already exists")

// FriendshipRepo 操作 friendships 表(user → user 好友关系)。
// 接管单聊会话建立前的"加好友"流程:发起请求 → 接受/拒绝/取消 → 双向 accepted。
//
// 设计:
//   - 单向存储(只建一行 A→B),双向查询靠 OR 子句覆盖。
//   - 状态机 pending → accepted/rejected/canceled(终态不可逆)。
//   - 身份校验:Accept/Reject 只 friend_id 能调,Cancel 只 user_id 能调。
//     身份错与"不存在"都返 sql.ErrNoRows(不泄露请求存在性)。
//   - CreateRequest 双向校验:先 SELECT 再 INSERT,UNIQUE(user_id, friend_id)
//     只能防 A→A 自环和重复 A→B,不能防 A→B + B→A 并发(已知 race window)。
//
// 设计见 docs/superpowers/specs/2026-07-02-participants-model-refactor-design.md §3.2。
type FriendshipRepo struct {
	db *sql.DB
}

// NewFriendshipRepo 构造 FriendshipRepo。
func NewFriendshipRepo(db *sql.DB) *FriendshipRepo {
	return &FriendshipRepo{db: db}
}

// CreateRequest 发起好友请求。
// 双向校验:A→B 或 B→A 任一已存在(任意状态) → ErrFriendshipAlreadyExists。
// 命中走 fast path 直接拒绝, race window 内并发请求靠 UNIQUE 兜底返普通 error。
//
// 注意:身份校验(fromUserID != toUserID)由 handler 负责,本方法不拦,
// 让 UNIQUE(user_id, friend_id) 兜底自环场景。
func (r *FriendshipRepo) CreateRequest(fromUserID, toUserID string) (*model.Friendship, error) {
	// 1. 双向查重:任意方向、任意状态都算存在
	var existingStatus string
	err := r.db.QueryRow(`
		SELECT status FROM friendships
		WHERE (user_id = $1 AND friend_id = $2)
		   OR (user_id = $2 AND friend_id = $1)
	`, fromUserID, toUserID).Scan(&existingStatus)
	if err == nil {
		return nil, ErrFriendshipAlreadyExists
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}

	// 2. INSERT 新行(status=pending, responded_at=NULL)
	f := &model.Friendship{}
	err = r.db.QueryRow(`
		INSERT INTO friendships (user_id, friend_id, status)
		VALUES ($1, $2, 'pending')
		RETURNING id, user_id, friend_id, status, created_at, responded_at
	`, fromUserID, toUserID).Scan(
		&f.ID, &f.UserID, &f.FriendID, &f.Status, &f.CreatedAt, &f.RespondedAt,
	)
	if err != nil {
		return nil, err
	}
	return f, nil
}

// Accept 接受好友请求。只有 friend_id(接收方)才能接受。
// 状态机约束:仅 pending 可推进;否则 / 越权 / 不存在 → sql.ErrNoRows。
func (r *FriendshipRepo) Accept(requestID, byUserID string) error {
	return r.advanceState(requestID, byUserID, "accepted", "friend_id")
}

// Reject 拒绝好友请求。只有 friend_id(接收方)才能拒绝。
func (r *FriendshipRepo) Reject(requestID, byUserID string) error {
	return r.advanceState(requestID, byUserID, "rejected", "friend_id")
}

// Cancel 取消好友请求(发起方主动撤回)。只有 user_id(发起方)才能取消。
func (r *FriendshipRepo) Cancel(requestID, byUserID string) error {
	return r.advanceState(requestID, byUserID, "canceled", "user_id")
}

// advanceState 是 Accept/Reject/Cancel 的共享实现。
//   - newState: 目标状态(accepted/rejected/canceled)
//   - roleCol: "friend_id"(接收方操作:accept/reject)或 "user_id"(发起方操作:cancel)
//
// RowsAffected=0 表示身份错 / 非 pending / 不存在三种情况之一,
// 统一返 sql.ErrNoRows 让 handler 转 404,不泄露请求存在性。
func (r *FriendshipRepo) advanceState(requestID, byUserID, newState, roleCol string) error {
	res, err := r.db.Exec(`
		UPDATE friendships
		SET status = $3, responded_at = NOW()
		WHERE id = $1 AND `+roleCol+` = $2 AND status = 'pending'
	`, requestID, byUserID, newState)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// AreFriends 校验两人是否已成为好友。
// 双向:A→B 或 B→A 任一 accepted 即 true;其他状态或无关系均 false。
func (r *FriendshipRepo) AreFriends(userA, userB string) (bool, error) {
	var exists bool
	err := r.db.QueryRow(`
		SELECT EXISTS(
		  SELECT 1 FROM friendships
		  WHERE status = 'accepted'
		    AND ((user_id = $1 AND friend_id = $2)
		         OR (user_id = $2 AND friend_id = $1))
		)
	`, userA, userB).Scan(&exists)
	return exists, err
}

// ListFriends 返回某 user 的所有 accepted 好友 user_id(双向:对方可能在 user_id 或 friend_id 位)。
// 上层(handler)再 JOIN users 取摘要(昵称/头像)。
func (r *FriendshipRepo) ListFriends(userID string) ([]string, error) {
	rows, err := r.db.Query(`
		SELECT CASE WHEN user_id = $1 THEN friend_id ELSE user_id END AS friend_id
		FROM friendships
		WHERE status = 'accepted' AND (user_id = $1 OR friend_id = $1)
	`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// ListIncomingRequests 返回该 user 收到的 pending 请求(friend_id = user AND status = pending)。
// 按 created_at DESC 排序,最新请求在前。
func (r *FriendshipRepo) ListIncomingRequests(userID string) ([]model.Friendship, error) {
	return r.listRequests(userID, "friend_id")
}

// ListOutgoingRequests 返回该 user 发出的 pending 请求(user_id = user AND status = pending)。
func (r *FriendshipRepo) ListOutgoingRequests(userID string) ([]model.Friendship, error) {
	return r.listRequests(userID, "user_id")
}

// listRequests 是 ListIncoming/OutgoingRequests 的共享实现。
// roleCol: "friend_id"(incoming)或 "user_id"(outgoing)。
func (r *FriendshipRepo) listRequests(userID, roleCol string) ([]model.Friendship, error) {
	rows, err := r.db.Query(`
		SELECT id, user_id, friend_id, status, created_at, responded_at
		FROM friendships
		WHERE `+roleCol+` = $1 AND status = 'pending'
		ORDER BY created_at DESC
	`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var result []model.Friendship
	for rows.Next() {
		var f model.Friendship
		if err := rows.Scan(
			&f.ID, &f.UserID, &f.FriendID, &f.Status, &f.CreatedAt, &f.RespondedAt,
		); err != nil {
			return nil, err
		}
		result = append(result, f)
	}
	return result, rows.Err()
}

// GetByID 按 request id 查 Friendship 详情。供 handler 在 Accept/Reject/Cancel 后
// 查请求信息以广播通知发起方。不存在返 (nil, nil)。
func (r *FriendshipRepo) GetByID(requestID string) (*model.Friendship, error) {
	f := &model.Friendship{}
	err := r.db.QueryRow(`
		SELECT id, user_id, friend_id, status, created_at, responded_at
		FROM friendships WHERE id = $1
	`, requestID).Scan(
		&f.ID, &f.UserID, &f.FriendID, &f.Status, &f.CreatedAt, &f.RespondedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return f, nil
}

// RemoveFriend 删除好友关系(双向:A→B 或 B→A 任一 accepted 都删)。
// 非 accepted(pending / rejected / canceled / 无关系)→ sql.ErrNoRows。
func (r *FriendshipRepo) RemoveFriend(userID, friendID string) error {
	res, err := r.db.Exec(`
		DELETE FROM friendships
		WHERE status = 'accepted'
		  AND ((user_id = $1 AND friend_id = $2)
		       OR (user_id = $2 AND friend_id = $1))
	`, userID, friendID)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return sql.ErrNoRows
	}
	return nil
}
