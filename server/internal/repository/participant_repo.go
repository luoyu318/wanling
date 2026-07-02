package repository

import (
	"database/sql"
	"errors"
	"time"

	"github.com/lib/pq"
	"github.com/wanling/server/internal/model"
)

// ParticipantRepo 操作 conversation_participants 表(N 方参与者通用模型)。
// 接管原 conversations.user_id/agent_id/unread_count/hidden_at/pinned_at 的全部读写,
// 把"会话-成员关系 + 个人维度状态"统一沉到本表。
//
// 设计见 docs/superpowers/specs/2026-07-02-participants-model-refactor-design.md §3.2。
type ParticipantRepo struct {
	db *sql.DB
}

func NewParticipantRepo(db *sql.DB) *ParticipantRepo {
	return &ParticipantRepo{db: db}
}

// ParticipantInput 是 AddParticipantsTx 的入参(创建会话 / 邀请成员用)。
type ParticipantInput struct {
	MemberID   string
	MemberType string // user / agent
	Role       string // owner / admin / member
}

// AddParticipantsTx 批量加参与者(创建会话 / 邀请成员用)。
// 用 ON CONFLICT DO NOTHING 保证幂等:同 member 重复加不报错(邀请已存在成员 / 重发)。
// 调用方必须在外层事务里调,失败时整批回滚。
func (r *ParticipantRepo) AddParticipantsTx(tx *sql.Tx, convID string, participants []ParticipantInput) error {
	if len(participants) == 0 {
		return nil
	}
	stmt, err := tx.Prepare(`
		INSERT INTO conversation_participants (conv_id, member_id, member_type, role)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (conv_id, member_id, member_type) DO NOTHING
	`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, p := range participants {
		if _, err := stmt.Exec(convID, p.MemberID, p.MemberType, p.Role); err != nil {
			return err
		}
	}
	return nil
}

// rowsQueryer 抽象 *sql.DB 和 *sql.Tx 共有的 Query 方法,
// 让 ListByConversation / ListByConversationTx 共享同一份 SQL 实现。
type rowsQueryer interface {
	Query(query string, args ...any) (*sql.Rows, error)
}

// listParticipantsByConv 是 ListByConversation / ListByConversationTx 的共享实现。
// 同事务读避免并发写消息时的脏读(读到旧 participants 漏算新成员未读)。
func listParticipantsByConv(q rowsQueryer, convID string) ([]model.ConversationParticipant, error) {
	rows, err := q.Query(`
		SELECT conv_id, member_id, member_type, role, unread_count, last_read_message_id, joined_at, hidden_at, pinned_at
		FROM conversation_participants WHERE conv_id = $1
	`, convID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanParticipants(rows)
}

// ListByConversation 返回会话所有参与者(发消息 / 推送 / 详情页用)。
func (r *ParticipantRepo) ListByConversation(convID string) ([]model.ConversationParticipant, error) {
	return listParticipantsByConv(r.db, convID)
}

// ListByConversationTx 事务版本(MessageProcessor 同事务查 participants 用)。
func (r *ParticipantRepo) ListByConversationTx(tx *sql.Tx, convID string) ([]model.ConversationParticipant, error) {
	return listParticipantsByConv(tx, convID)
}

// ListByMember 返回某 user/agent 参与的所有会话(IM 列表用)。
// 注意返回的是该 member 在每个会话的参与者行(含 conv_id),不是会话列表本身。
// 上层(IM 列表)需要 JOIN conversations 取会话摘要。
func (r *ParticipantRepo) ListByMember(memberID, memberType string) ([]model.ConversationParticipant, error) {
	rows, err := r.db.Query(`
		SELECT conv_id, member_id, member_type, role, unread_count, last_read_message_id, joined_at, hidden_at, pinned_at
		FROM conversation_participants WHERE member_id = $1 AND member_type = $2
	`, memberID, memberType)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanParticipants(rows)
}

// Exists 校验某 member 是否在某会话(权限中间件用)。
// 命中走 INDEX (conv_id, member_id, member_type) PRIMARY KEY,纯存在性查询比 Get 轻量。
func (r *ParticipantRepo) Exists(convID, memberID, memberType string) (bool, error) {
	var exists bool
	err := r.db.QueryRow(`
		SELECT EXISTS(SELECT 1 FROM conversation_participants
		               WHERE conv_id = $1 AND member_id = $2 AND member_type = $3)
	`, convID, memberID, memberType).Scan(&exists)
	return exists, err
}

// Get 单查(权限 / 状态校验用)。不存在返 (nil, nil),不返 error,让调用方用 nil 判断分支。
func (r *ParticipantRepo) Get(convID, memberID, memberType string) (*model.ConversationParticipant, error) {
	p := &model.ConversationParticipant{}
	var lastReadID *string
	var hiddenAt, pinnedAt *time.Time
	err := r.db.QueryRow(`
		SELECT conv_id, member_id, member_type, role, unread_count, last_read_message_id, joined_at, hidden_at, pinned_at
		FROM conversation_participants WHERE conv_id = $1 AND member_id = $2 AND member_type = $3
	`, convID, memberID, memberType).Scan(
		&p.ConvID, &p.MemberID, &p.MemberType, &p.Role, &p.UnreadCount,
		&lastReadID, &p.JoinedAt, &hiddenAt, &pinnedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	p.LastReadMessageID = lastReadID
	p.HiddenAt = hiddenAt
	p.PinnedAt = pinnedAt
	return p, nil
}

// IncrUnreadTx 发消息时给非 sender 全员 +1 unread_count。
// exceptMember 是 (sender_id, sender_type) 元组。
// 调用方必须在外层事务里调,确保 unread_count 自增与消息落库原子性。
//
// 调用方责任:必须先校验 sender 是该会话 participant(用 Exists 方法),
// 否则 UPDATE 会给该会话所有成员 +1 unread(包括 sender 不在的"幽灵消息"场景),
// 这是 fail-open 行为,MessageProcessor 在消息落库前需加 Exists 守卫。
func (r *ParticipantRepo) IncrUnreadTx(tx *sql.Tx, convID, exceptMemberID, exceptMemberType string) error {
	_, err := tx.Exec(`
		UPDATE conversation_participants
		SET unread_count = unread_count + 1
		WHERE conv_id = $1
		  AND NOT (member_id = $2 AND member_type = $3)
	`, convID, exceptMemberID, exceptMemberType)
	return err
}

// MarkMessagesReadTx 批量标已读:UPDATE deliveries + 重算 unread_count + 更新 last_read_message_id。
// 返回新的 unread_count(供 WS 推送 / IM 列表 refresh 用)。
//
// 事务所有权归调用方:本方法只接收 tx,不做 BeginTx/Commit/Rollback。
// 调用方负责 Commit(成功路径)或 Rollback(err 路径)。
// 不存在该 (conv, member) 时返 sql.ErrNoRows,调用方据此转 404。
//
// unread_count 必须按 conv 维度重算(不能按 member 全局),因为同一 member 可能参与多个会话,
// 只把"本会话内未读 delivery"计入。
//
// last_read_message_id 取已读 deliveries 中最大 created_at 对应的 message_id,
// 用于 APP 端"已读分隔条"定位。
func (r *ParticipantRepo) MarkMessagesReadTx(tx *sql.Tx, convID, memberID, memberType string, messageIDs []string) (int, error) {
	// 1. 标 deliveries 已读(只更新未读的,避免重复刷 read_at 时间戳)
	if len(messageIDs) > 0 {
		_, err := tx.Exec(`
			UPDATE message_deliveries SET read_at = NOW()
			WHERE recipient_id = $1 AND recipient_type = $2
			  AND message_id = ANY($3::uuid[])
			  AND read_at IS NULL
		`, memberID, memberType, pq.Array(messageIDs))
		if err != nil {
			return 0, err
		}
	}

	// 2. 重算 unread_count(只算该 conv 内的未读,不是全局)
	//    过滤软删 + 该 member 隐藏过的消息(hidden 消息不计未读,徽章数字才准)
	var newUnread int
	err := tx.QueryRow(`
		SELECT COUNT(*) FROM message_deliveries d
		JOIN messages m ON m.id = d.message_id
		WHERE d.recipient_id = $1 AND d.recipient_type = $2 AND d.read_at IS NULL
		  AND m.conversation_id = $3 AND m.deleted_at IS NULL
		  AND NOT EXISTS (
		    SELECT 1 FROM message_hidden h
		    WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = $2
		  )
	`, memberID, memberType, convID).Scan(&newUnread)
	if err != nil {
		return 0, err
	}

	// 3. 更新 unread_count + last_read_message_id
	//    WHERE 必须加 conv_id 限定,避免 member 参与多个 conv 时一次性改所有行的 unread_count。
	//    last_read_message_id 取该 conv 内已读 deliveries 中最新消息(m.created_at DESC LIMIT 1)
	//    子查询若返 NULL(无已读 delivery)不影响 unread_count 更新。
	//    hidden 消息不参与 last_read(已隐藏的不应作"已读进度"锚点)。
	//    RowsAffected=0 表示该 member 不在此 conv(越权 / 未邀请),返 sentinel 让 handler 转 404。
	res, err := tx.Exec(`
		UPDATE conversation_participants p
		SET unread_count = $3,
		    last_read_message_id = (
		      SELECT d.message_id FROM message_deliveries d
		      JOIN messages m ON m.id = d.message_id
		      WHERE d.recipient_id = $1 AND d.recipient_type = $2 AND d.read_at IS NOT NULL
		        AND m.conversation_id = $4 AND m.deleted_at IS NULL
		        AND NOT EXISTS (
		          SELECT 1 FROM message_hidden h
		          WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = $2
		        )
		      ORDER BY m.created_at DESC LIMIT 1
		    )
		WHERE p.conv_id = $4 AND p.member_id = $1 AND p.member_type = $2
	`, memberID, memberType, newUnread, convID)
	if err != nil {
		return 0, err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return 0, err
	}
	if rows == 0 {
		return 0, sql.ErrNoRows // 越权 / 该 member 不在此 conv
	}
	return newUnread, nil
}

// SetPinned 个人维度置顶(true=置顶 / false=取消)。
// 与原 conversations.pinned_at 不同,本字段在 participant 行上,每个 member 各自独立。
func (r *ParticipantRepo) SetPinned(convID, memberID, memberType string, pinned bool) error {
	var t *time.Time
	if pinned {
		now := time.Now()
		t = &now
	}
	_, err := r.db.Exec(`
		UPDATE conversation_participants SET pinned_at = $4
		WHERE conv_id = $1 AND member_id = $2 AND member_type = $3
	`, convID, memberID, memberType, t)
	return err
}

// SetHidden 个人维度隐藏(true=隐藏 / false=取消)。
// 与原 conversations.hidden_at 不同,本字段在 participant 行上,每个 member 各自独立。
// 上层业务规则(发消息自动取消隐藏)由调用方实现,本方法只做字段更新。
func (r *ParticipantRepo) SetHidden(convID, memberID, memberType string, hidden bool) error {
	var t *time.Time
	if hidden {
		now := time.Now()
		t = &now
	}
	_, err := r.db.Exec(`
		UPDATE conversation_participants SET hidden_at = $4
		WHERE conv_id = $1 AND member_id = $2 AND member_type = $3
	`, convID, memberID, memberType, t)
	return err
}

// RemoveParticipantTx 删除单个 participant(踢人 / 普通成员退群)。
// 不级联删会话(只删 member 行)。owner 退群用 DestroyConversationTx。
// 调用方必须在外层事务里调,确保与权限校验原子性。
func (r *ParticipantRepo) RemoveParticipantTx(tx *sql.Tx, convID, memberID, memberType string) error {
	_, err := tx.Exec(`
		DELETE FROM conversation_participants
		WHERE conv_id = $1 AND member_id = $2 AND member_type = $3
	`, convID, memberID, memberType)
	return err
}

// DestroyConversationTx owner 退群 → 删整个会话(走 conversations ON DELETE CASCADE 级联删 participants + messages + deliveries)。
//
// 安全约束:本方法不做 owner 身份校验,调用方必须在 handler 层先校验
// caller 是该会话 owner(spec §6.2),否则任何 member 都能销群。
// 调用方(Leave / Disband handler)必须查 participant.role='owner' 才调本方法。
func (r *ParticipantRepo) DestroyConversationTx(tx *sql.Tx, convID string) error {
	_, err := tx.Exec(`DELETE FROM conversations WHERE id = $1`, convID)
	return err
}

// scanParticipants 把 *sql.Rows 扫成 ConversationParticipant 切片。
// ListByConversation / ListByConversationTx / ListByMember 共用。
// last_read_message_id / hidden_at / pinned_at 都是可空字段,扫到 *string / *time.Time。
func scanParticipants(rows *sql.Rows) ([]model.ConversationParticipant, error) {
	var result []model.ConversationParticipant
	for rows.Next() {
		var p model.ConversationParticipant
		var lastReadID *string
		var hiddenAt, pinnedAt *time.Time
		if err := rows.Scan(
			&p.ConvID, &p.MemberID, &p.MemberType, &p.Role, &p.UnreadCount,
			&lastReadID, &p.JoinedAt, &hiddenAt, &pinnedAt,
		); err != nil {
			return nil, err
		}
		p.LastReadMessageID = lastReadID
		p.HiddenAt = hiddenAt
		p.PinnedAt = pinnedAt
		result = append(result, p)
	}
	return result, rows.Err()
}
