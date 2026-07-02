// ConversationRepo 操作 conversations 表(N 方参与者通用模型)。
//
// participants 模型重构后,本 repo 职责瘦身:
//   - 不再读写 user_id / agent_id / unread_count / hidden_at / pinned_at(全部下沉
//     到 conversation_participants 表,由 ParticipantRepo 管)
//   - 不再管「未读 / 已读 / 置顶 / 隐藏」状态(由 ParticipantRepo / DeliveryRepo 接管)
//   - 新增 FindOrCreateDM(按 type + 双方 member 去重)和 CreateTx(群聊用)
//   - ListForUser JOIN participants 取个人维度 unread_count/pinned_at/hidden_at,
//     并用 subquery 取 dm_user_agent 的对端 agent 摘要
//
// 设计见 docs/superpowers/specs/2026-07-02-participants-model-refactor-design.md §3.5。
package repository

import (
	"database/sql"
	"encoding/json"
	"errors"

	"github.com/lib/pq"
	"github.com/wanling/server/internal/model"
)

type ConversationRepo struct {
	db *sql.DB
}

func NewConversationRepo(db *sql.DB) *ConversationRepo {
	return &ConversationRepo{db: db}
}

// GetByID 返回单个会话(只读 conversations 表本身字段);不存在返 (nil, nil)。
// 个人维度字段(unread_count/pinned_at/hidden_at)在 participants 表,本方法不返回,
// 由调用方按需用 ParticipantRepo.Get 取。
//
// title/avatar_url 是可空字段(1-1 dm 为 NULL,群聊有值),用 sql.NullString scan
// 再转 string(NULL → 空串),保持 model.Conversation 字段类型为 string 不变。
func (r *ConversationRepo) GetByID(id string) (*model.Conversation, error) {
	c := &model.Conversation{}
	var title, avatarURL sql.NullString
	err := r.db.QueryRow(
		`SELECT id, type, title, avatar_url, last_message_content, last_message_at, created_at
		 FROM conversations WHERE id = $1`,
		id,
	).Scan(&c.ID, &c.Type, &title, &avatarURL, &c.LastMessageContent, &c.LastMessageAt, &c.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	c.Title = title.String
	c.AvatarURL = avatarURL.String
	return c, nil
}

// ListForUser 列出某 user 参与的所有有消息且未隐藏的会话(IM 风格列表)。
//
// JOIN conversation_participants 取个人维度 unread_count / pinned_at / hidden_at;
// 用 subquery 取 dm_user_agent 场景的对端 agent 摘要(group_* 场景由应用层组装
// Participants 字段,Agent 留 nil)。
//
// 过滤:p.hidden_at IS NULL(用户维度软删除) + c.last_message_content IS NOT NULL(无消息不进列表)。
// 排序:置顶在前(pinned_at DESC NULLS LAST),组内按 last_message_at DESC。
//
// 应用层组装:调用方拿到 items 后,用 BatchLoadParticipantSummaries 一次性批量查
// participants 摘要,group by conv_id 拼装到 ConversationListItem.Participants。
//
// SQL 见 spec §3.5。subquery 取「任一 agent」(LIMIT 1),dm_user_agent 通常只有 1 个。
func (r *ConversationRepo) ListForUser(userID string) ([]model.ConversationListItem, error) {
	rows, err := r.db.Query(`
		SELECT c.id, c.type, c.title, c.avatar_url,
		       c.last_message_content, c.last_message_at, c.created_at,
		       p.unread_count, p.pinned_at, p.hidden_at,
		       (SELECT ag.id FROM agents ag
		          JOIN conversation_participants pa
		            ON pa.member_id = ag.id AND pa.member_type = 'agent' AND pa.conv_id = c.id
		          LIMIT 1) AS agent_id,
		       (SELECT ag.name FROM agents ag
		          JOIN conversation_participants pa
		            ON pa.member_id = ag.id AND pa.member_type = 'agent' AND pa.conv_id = c.id
		          LIMIT 1) AS agent_name,
		       (SELECT ag.avatar_url FROM agents ag
		          JOIN conversation_participants pa
		            ON pa.member_id = ag.id AND pa.member_type = 'agent' AND pa.conv_id = c.id
		          LIMIT 1) AS agent_avatar,
		       (SELECT u.username FROM users u
		          JOIN conversation_participants pa
		            ON pa.member_id = u.id AND pa.member_type = 'user' AND pa.conv_id = c.id
		          WHERE u.id != $1
		          LIMIT 1) AS other_username,
		       (SELECT u.nickname FROM users u
		          JOIN conversation_participants pa
		            ON pa.member_id = u.id AND pa.member_type = 'user' AND pa.conv_id = c.id
		          WHERE u.id != $1
		          LIMIT 1) AS other_nickname,
		       (SELECT u.avatar_url FROM users u
		          JOIN conversation_participants pa
		            ON pa.member_id = u.id AND pa.member_type = 'user' AND pa.conv_id = c.id
		          WHERE u.id != $1
		          LIMIT 1) AS other_avatar
		FROM conversations c
		JOIN conversation_participants p
		  ON p.conv_id = c.id AND p.member_id = $1 AND p.member_type = 'user'
		WHERE p.hidden_at IS NULL AND c.last_message_content IS NOT NULL
		ORDER BY p.pinned_at DESC NULLS LAST, c.last_message_at DESC`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var items []model.ConversationListItem
	for rows.Next() {
		var (
			item             model.ConversationListItem
			titleNS          sql.NullString
			avatarURLNS      sql.NullString
			agentID          sql.NullString
			agentName        sql.NullString
			agentAvatar      sql.NullString
			otherUsername    sql.NullString
			otherNickname    sql.NullString
			otherAvatarURL   sql.NullString
		)
		if err := rows.Scan(
			&item.ID, &item.Type, &titleNS, &avatarURLNS,
			&item.LastMessageContent, &item.LastMessageAt, &item.CreatedAt,
			&item.UnreadCount, &item.PinnedAt, &item.HiddenAt,
			&agentID, &agentName, &agentAvatar,
			&otherUsername, &otherNickname, &otherAvatarURL,
		); err != nil {
			return nil, err
		}
		item.Title = titleNS.String
		item.AvatarURL = avatarURLNS.String
		// dm_user_agent 才填 Agent 摘要;其他 type 留 nil(UI 走 Title/AvatarURL)
		if agentID.Valid {
			item.Agent = &model.AgentSummary{
				ID:        agentID.String,
				Name:      agentName.String,
				AvatarURL: agentAvatar.String,
			}
		}
		// dm_user_user 才填 OtherUser 摘要(对方 user);其他 type 留 nil。
		// 排除自己(WHERE u.id != $1)确保拿到的是对方 user。
		if otherUsername.Valid {
			var nickname *string
			if otherNickname.Valid && otherNickname.String != "" {
				s := otherNickname.String
				nickname = &s
			}
			item.OtherUser = &model.UserSummary{
				Username:  otherUsername.String,
				Nickname:  nickname,
				AvatarURL: otherAvatarURL.String,
			}
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return items, nil
}

// BatchLoadParticipantSummaries 批量查多个会话的 participant 摘要,group by conv_id 拼装。
// 用一条 SQL(LEFT JOIN users + LEFT JOIN agents 按 member_type CASE 取摘要)避免 N+1。
// 调用方(ListForUser 的上层 handler)把结果按 conv_id 分配到每个 ConversationListItem.Participants。
//
// convIDs 为空时返空 map 不报错(防御性,避免 ANY($1::uuid[]) 空 array 语义歧义)。
func (r *ConversationRepo) BatchLoadParticipantSummaries(convIDs []string) (map[string][]model.ParticipantSummary, error) {
	result := map[string][]model.ParticipantSummary{}
	if len(convIDs) == 0 {
		return result, nil
	}
	rows, err := r.db.Query(`
		SELECT p.conv_id, p.member_id, p.member_type, p.role,
		       CASE WHEN p.member_type = 'user' THEN u.username ELSE a.name END AS username,
		       CASE WHEN p.member_type = 'user' THEN COALESCE(u.nickname, u.username) ELSE a.name END AS nickname,
		       CASE WHEN p.member_type = 'user' THEN COALESCE(u.avatar_url, '') ELSE COALESCE(a.avatar_url, '') END AS avatar_url
		FROM conversation_participants p
		LEFT JOIN users u ON p.member_type = 'user' AND u.id = p.member_id
		LEFT JOIN agents a ON p.member_type = 'agent' AND a.id = p.member_id
		WHERE p.conv_id = ANY($1::uuid[])`,
		pq.Array(convIDs),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			convID string
			ps     model.ParticipantSummary
		)
		if err := rows.Scan(
			&convID, &ps.MemberID, &ps.MemberType, &ps.Role,
			&ps.Username, &ps.Nickname, &ps.AvatarURL,
		); err != nil {
			return nil, err
		}
		result[convID] = append(result[convID], ps)
	}
	return result, rows.Err()
}

// UpdateLastMessage 在消息持久化后调用,更新会话的 last_message_content 与 last_message_at。
// 写入时间用 NOW()(数据库时间),避免应用服务器时钟不一致。
// content 是消息的完整 JSON(含 msg_type/data 字段)。
func (r *ConversationRepo) UpdateLastMessage(convID string, content json.RawMessage) error {
	_, err := r.db.Exec(
		`UPDATE conversations SET last_message_content = $1, last_message_at = NOW() WHERE id = $2`,
		[]byte(content), convID,
	)
	return err
}

// ClearLastMessage 把会话的 last_message_content 置 NULL。
// 用于消息全删完后清空缓存(避免 IM 列表显示已不存在的最后一条消息)。
// 不更新 last_message_at(保留原时间戳,语义上该会话仍存在,只是无消息)。
func (r *ConversationRepo) ClearLastMessage(convID string) error {
	_, err := r.db.Exec(
		`UPDATE conversations SET last_message_content = NULL WHERE id = $1`,
		convID,
	)
	return err
}

// BeginTx 启动一个事务,供 MessageProcessor 在事务内同时写消息 + 更新缓存 + 写 deliveries + 更新 participants。
func (r *ConversationRepo) BeginTx() (*sql.Tx, error) {
	return r.db.Begin()
}

// UpdateLastMessageTx 与 UpdateLastMessage 行为一致,但在外部事务中执行。
// 调用方负责 Commit/Rollback。用于保证"写消息 + 写 deliveries + 更新 participants + 更新缓存"的原子性。
func (r *ConversationRepo) UpdateLastMessageTx(tx *sql.Tx, convID string, content json.RawMessage) error {
	_, err := tx.Exec(
		`UPDATE conversations SET last_message_content = $1, last_message_at = NOW() WHERE id = $2`,
		[]byte(content), convID,
	)
	return err
}

// CreateTx 在外部事务中创建一个会话(只 INSERT conversations 表,不加 participants)。
// 群聊创建用:handler 调本方法后,接着调 ParticipantRepo.AddParticipantsTx 加成员。
// 1-1 dm 用 FindOrCreateDM(内部会处理 participants)。
//
// 调用方负责 Commit/Rollback。
// typeStr 取值见 spec:dm_user_user / dm_user_agent / group_user / group_mixed。
// title/avatarURL 仅群聊用,1-1 为空串(传入空串 → DB 存 NULL)。
func (r *ConversationRepo) CreateTx(tx *sql.Tx, typeStr, title, avatarURL string) (*model.Conversation, error) {
	c := &model.Conversation{}
	var titleNS, avatarURLNS sql.NullString
	err := tx.QueryRow(
		`INSERT INTO conversations (type, title, avatar_url)
		 VALUES ($1, NULLIF($2, ''), NULLIF($3, ''))
		 RETURNING id, type, title, avatar_url, last_message_content, last_message_at, created_at`,
		typeStr, title, avatarURL,
	).Scan(&c.ID, &c.Type, &titleNS, &avatarURLNS, &c.LastMessageContent, &c.LastMessageAt, &c.CreatedAt)
	if err != nil {
		return nil, err
	}
	c.Title = titleNS.String
	c.AvatarURL = avatarURLNS.String
	return c, nil
}

// DMMembers 是 FindOrCreateDM 的入参。
// Initiator 是发起方(role=owner),Other 是对方(role=member)。
// 显式区分 Initiator/Other 是为了让 owner 角色不依赖参数顺序。
type DMMembers struct {
	Initiator ParticipantInput // 发起方(user 通常是 owner)
	Other     ParticipantInput // 对方
}

// FindOrCreateDM 1-1 单聊按 (type + 两方 member set) 去重:
//   - 已存在 → 返回已有会话(只读不改,不加新 participants 行)
//   - 不存在 → CreateTx 新建 + 在同事务内 INSERT 2 行 participants
//
// 内部直接 SQL INSERT participants(不调 ParticipantRepo),原因:
//  1. 只有 2 行固定 INSERT,代码量小;
//  2. 避免 repo 间循环依赖(ConversationRepo 持有 ParticipantRepo 实例);
//  3. 同事务保证「会话 + 成员」原子性。
//
// role 约定:Initiator=owner,Other=member。dm_user_user / dm_user_agent 都适用
// (发起方 user 是 owner,对端 user 或 agent 是 member)。
//
// 事务所有权归 FindOrCreateDM 内部:不接收外部 tx,内部 Begin/Commit/Rollback。
// 因为本方法的语义是「得到一个可用的 dm 会话」,调用方(handler)拿到结果后
// 直接用,不需要把会话创建和后续操作(发消息等)绑在同一事务里。
//
// race window:并发 FindOrCreateDM 同 (type, members) 时,可能两方都进入「不存在」
// 分支,第二个 INSERT conversations 会因无 UNIQUE 约束成功(产生重复会话)。
// 这是已知限制,本期用应用层 mutex 或后续加 UNIQUE(type, canonical_member_set) 修复。
// 不在事务内加 SELECT FOR UPDATE,因为 conversations 表无相关唯一键可锁。
func (r *ConversationRepo) FindOrCreateDM(typeStr string, members DMMembers) (*model.Conversation, error) {
	tx, err := r.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback() // commit 后 noop

	// 1. 查已存在的 dm(同 type + 同两方 participants)
	var convID string
	err = tx.QueryRow(`
		SELECT c.id FROM conversations c
		WHERE c.type = $1
		  AND EXISTS(SELECT 1 FROM conversation_participants p
		             WHERE p.conv_id = c.id AND p.member_id = $2 AND p.member_type = $3)
		  AND EXISTS(SELECT 1 FROM conversation_participants p
		             WHERE p.conv_id = c.id AND p.member_id = $4 AND p.member_type = $5)
		LIMIT 1`,
		typeStr,
		members.Initiator.MemberID, members.Initiator.MemberType,
		members.Other.MemberID, members.Other.MemberType,
	).Scan(&convID)

	if err == nil {
		// 已存在,提交只读事务并返回会话
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		return r.GetByID(convID)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}

	// 2. 不存在,创建会话
	conv, err := r.CreateTx(tx, typeStr, "", "")
	if err != nil {
		return nil, err
	}

	// 3. 加 2 行 participants(Initiator=owner, Other=member)
	stmt, err := tx.Prepare(`
		INSERT INTO conversation_participants (conv_id, member_id, member_type, role)
		VALUES ($1, $2, $3, $4)
	`)
	if err != nil {
		return nil, err
	}
	defer stmt.Close()
	for _, m := range []struct {
		input ParticipantInput
		role  string
	}{
		{members.Initiator, "owner"},
		{members.Other, "member"},
	} {
		if _, err := stmt.Exec(conv.ID, m.input.MemberID, m.input.MemberType, m.role); err != nil {
			return nil, err
		}
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return conv, nil
}

// UpdateProfile 更新会话自身的 title / avatar_url(群聊用)。
// 用 COALESCE(NULLIF) 模式:空串=不动(不支持清空,语义同 AgentRepo.Update)。
// 越权防护(仅 owner/admin 可改)由 handler 层做,本方法只做字段更新。
func (r *ConversationRepo) UpdateProfile(convID, title, avatarURL string) error {
	_, err := r.db.Exec(
		`UPDATE conversations
		 SET title = COALESCE(NULLIF($2, ''), title),
		     avatar_url = COALESCE(NULLIF($3, ''), avatar_url)
		 WHERE id = $1`,
		convID, title, avatarURL,
	)
	return err
}
