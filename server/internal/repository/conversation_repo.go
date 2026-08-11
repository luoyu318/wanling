// ConversationRepo 操作 conversations 表(N 方参与者通用模型)。
//
// participants 模型重构后,本 repo 职责瘦身:
//   - 不再读写 user_id / agent_id / unread_count / hidden_at / pinned_at(全部下沉
//     到 conversation_participants 表,由 ParticipantRepo 管)
//   - 不再管「未读 / 已读 / 置顶 / 隐藏」状态(由 ParticipantRepo / DeliveryRepo 接管)
//   - 新增 FindOrCreateDM(按 type + 双方 member 去重)和 CreateTx(群聊用)
//   - ListForUser JOIN participants 取个人维度 unread_count/pinned_at/hidden_at,
//     并用 subquery 取 dm_user_agent 的对端 agent 摘要
package repository

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/lib/pq"
	"github.com/wanling/server/internal/model"
)

type ConversationRepo struct {
	queryExecutor
}

func NewConversationRepo(db *sql.DB) *ConversationRepo {
	return &ConversationRepo{queryExecutor: queryExecutor{db: db}}
}

// GetByID 返回单个会话(只读 conversations 表本身字段);不存在返 (nil, nil)。
// 个人维度字段(unread_count/pinned_at/hidden_at)在 participants 表,本方法不返回,
// 由调用方按需用 ParticipantRepo.Get 取。
//
// title/avatar_url 是可空字段(1-1 dm 为 NULL,群聊有值),用 sql.NullString scan
// 再转 string(NULL → 空串),保持 model.Conversation 字段类型为 string 不变。
func (r *ConversationRepo) GetByID(ctx context.Context, id string) (*model.Conversation, error) {
	c := &model.Conversation{}
	var title, avatarURL sql.NullString
	err := r.queryRow(ctx,
		`SELECT id, type, title, avatar_url, session_meta, directory, created_at
		 FROM conversations WHERE id = $1`,
		id,
	).Scan(&c.ID, &c.Type, &title, &avatarURL, &c.SessionMeta, &c.Directory, &c.CreatedAt)
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
// last_message_content / last_message_at 不再读 conversations 表(017 已删列),
// 改用相关子查询从 messages 表按用户视角实时算「最新可见消息」:
//   - NOT EXISTS message_hidden(排除该用户隐藏过的消息)
//
// 撤回消息(deleted_at 非空)仍然算 last_message: server 端 SanitizeForClient 把撤回消息
// content 改写为 {msg_type:recalled},client 据此渲染「撤回了一条消息」占位卡片,
// 列表摘要也走 lastMessagePreview 的 recalled 分支。
//
// 多处子查询(SELECT content / SELECT created_at / ORDER BY created_at)
// 共用同一过滤条件,走 idx_messages_conv_created (migration 012) +
// idx_message_hidden_member (migration 016),每会话 LIMIT 1 = O(log N)。
//
// 过滤:p.hidden_at IS NULL(用户维度软删除)且 c.type != 'agent_session'
// (opencode 多 session 只在二级列表展示,不污染一级 IM 列表)。无消息会话也返
// (让新建群/dm 立即在所有 participant 列表出现,而不是等首条消息触发)。
//
// last_message_at / ORDER BY 用 COALESCE((子查询), c.created_at) 兜底:
// 无消息时 fallback 到创建时间,避免 client 拿到 0001-01-01 零值。
// last_message_content / sender_id / sender_type 无消息时返 NULL,
// client 已是 nullable 字段fromJson 不崩。
//
// 排序:置顶在前(pinned_at DESC NULLS LAST),组内按最新可见消息 created_at DESC
// (无消息会话 fallback 到 created_at,排在最后)。
//
// 应用层组装:调用方拿到 items 后,用 BatchLoadParticipantSummaries 一次性批量查
// participants 摘要,group by conv_id 拼装到 ConversationListItem.Participants。
//
// SQL 见 spec §3.5。subquery 取「任一 agent」(LIMIT 1),dm_user_agent 通常只有 1 个。
func (r *ConversationRepo) ListForUser(ctx context.Context, userID string) ([]model.ConversationListItem, error) {
	rows, err := r.query(ctx, `
		SELECT c.id, c.type, c.title, c.avatar_url, c.created_at,
		       p.unread_count, p.pinned_at, p.hidden_at,
		       (
		         -- 撤回消息(deleted_at 非空)的 content 改写为 recalled 占位,
		         -- 对齐 Messages handler 的 SanitizeForClient 行为,避免泄漏原文。
		         SELECT CASE WHEN m.deleted_at IS NOT NULL
		               THEN '{"msg_type":"recalled","data":{}}'::jsonb
		               ELSE m.content END
		         FROM messages m
		         WHERE m.conversation_id = c.id
		           AND m.is_main_stream
		           AND NOT EXISTS (
		             SELECT 1 FROM message_hidden h
		             WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = 'user'
		           )
		         ORDER BY m.created_at DESC LIMIT 1
		       ) AS last_message_content,
		       -- 无消息会话(刚建群 / dm 刚建立)的 last_message_at fallback 到
		       -- conversations.created_at,避免 client 拿到 0001-01-01 零值显示异常
		       -- (buildDetail 已对单查兜底,ListForUser 也对齐)
		       COALESCE((
		         SELECT m.created_at FROM messages m
		         WHERE m.conversation_id = c.id
		           AND m.is_main_stream
		           AND NOT EXISTS (
		             SELECT 1 FROM message_hidden h
		             WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = 'user'
		           )
		         ORDER BY m.created_at DESC LIMIT 1
		       ), c.created_at) AS last_message_at,
		       -- 撤回消息也要返原 sender_id/sender_type,client 据此切「你/对方撤回」文案。
		       (
		         SELECT m.sender_id FROM messages m
		         WHERE m.conversation_id = c.id
		           AND m.is_main_stream
		           AND NOT EXISTS (
		             SELECT 1 FROM message_hidden h
		             WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = 'user'
		           )
		         ORDER BY m.created_at DESC LIMIT 1
		       ) AS last_message_sender_id,
		       (
		         SELECT m.sender_type FROM messages m
		         WHERE m.conversation_id = c.id
		           AND m.is_main_stream
		           AND NOT EXISTS (
		             SELECT 1 FROM message_hidden h
		             WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = 'user'
		           )
		         ORDER BY m.created_at DESC LIMIT 1
		       ) AS last_message_sender_type,
		       -- 撤回消息也要返原 sender_name,群聊列表 preview 拼接「${name} 撤回了一条消息」
		       (
		         SELECT COALESCE(NULLIF(u.nickname, ''), u.username, a.name, '')
		         FROM messages m
		         LEFT JOIN users u ON m.sender_type = 'user' AND m.sender_id = u.id
		         LEFT JOIN agents a ON m.sender_type = 'agent' AND m.sender_id = a.id
		         WHERE m.conversation_id = c.id
		           AND m.is_main_stream
		           AND NOT EXISTS (
		             SELECT 1 FROM message_hidden h
		             WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = 'user'
		           )
		         ORDER BY m.created_at DESC LIMIT 1
		       ) AS last_message_sender_name,
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
		       (SELECT ag.type FROM agents ag
		          JOIN conversation_participants pa
		            ON pa.member_id = ag.id AND pa.member_type = 'agent' AND pa.conv_id = c.id
		          LIMIT 1) AS agent_type,
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
		WHERE p.hidden_at IS NULL
		  AND c.type != 'agent_session'
		ORDER BY p.pinned_at DESC NULLS LAST,
		         COALESCE((
		           SELECT m.created_at FROM messages m
		           WHERE m.conversation_id = c.id
		             AND m.is_main_stream
		             AND NOT EXISTS (
		               SELECT 1 FROM message_hidden h
		               WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = 'user'
		             )
		           ORDER BY m.created_at DESC LIMIT 1
		         ), c.created_at) DESC NULLS LAST`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var items []model.ConversationListItem
	for rows.Next() {
		var (
			item           model.ConversationListItem
			titleNS        sql.NullString
			avatarURLNS    sql.NullString
			senderIDNS     sql.NullString
			senderTypeNS   sql.NullString
			agentID        sql.NullString
			agentName      sql.NullString
			agentAvatar    sql.NullString
			agentTypeNS    sql.NullString
			otherUsername  sql.NullString
			otherNickname  sql.NullString
			otherAvatarURL sql.NullString
			senderNameNS   sql.NullString
		)
		if err := rows.Scan(
			&item.ID, &item.Type, &titleNS, &avatarURLNS, &item.CreatedAt,
			&item.UnreadCount, &item.PinnedAt, &item.HiddenAt,
			&item.LastMessageContent, &item.LastMessageAt,
			&senderIDNS, &senderTypeNS, &senderNameNS,
			&agentID, &agentName, &agentAvatar, &agentTypeNS,
			&otherUsername, &otherNickname, &otherAvatarURL,
		); err != nil {
			return nil, err
		}
		item.Title = titleNS.String
		item.AvatarURL = avatarURLNS.String
		item.LastMessageSenderID = senderIDNS.String
		item.LastMessageSenderType = senderTypeNS.String
		item.LastMessageSenderName = senderNameNS.String
		// dm_user_agent 才填 Agent 摘要;其他 type 留 nil(UI 走 Title/AvatarURL)
		if agentID.Valid {
			item.Agent = &model.AgentSummary{
				ID:        agentID.String,
				Name:      agentName.String,
				AvatarURL: agentAvatar.String,
				Type:      model.AgentType(agentTypeNS.String),
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
func (r *ConversationRepo) BatchLoadParticipantSummaries(ctx context.Context, convIDs []string) (map[string][]model.ParticipantSummary, error) {
	result := map[string][]model.ParticipantSummary{}
	if len(convIDs) == 0 {
		return result, nil
	}
	rows, err := r.query(ctx, `
		SELECT p.conv_id, p.member_id, p.member_type, p.role,
		       COALESCE(CASE WHEN p.member_type = 'user' THEN u.username ELSE a.name END, '') AS username,
		       COALESCE(CASE WHEN p.member_type = 'user' THEN COALESCE(u.nickname, u.username) ELSE a.name END, '') AS nickname,
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

// AgentSessionStats 某 agent 的 agent_session 聚合数据（一级列表入口行用）。
type AgentSessionStats struct {
	SessionCount  int
	UnreadTotal   int
	LastMessageAt time.Time // 零值 = 无消息
	PendingCount  int
}

// BatchLoadAgentSessionStats 批量查多个 agent 的 agent_session 聚合数据。
// 两条 SQL（session 聚合 + pending 聚合），GROUP BY agent_id 避免 N+1。
// 调用方（List handler）据此覆盖入口行的 unread_count / last_message_at + 填新字段。
//
// agentIDs 为空时返空 map 不报错（防御性，避免 ANY 空 array 语义歧义）。
func (r *ConversationRepo) BatchLoadAgentSessionStats(
	ctx context.Context, userID string, agentIDs []string,
) (map[string]AgentSessionStats, error) {
	result := map[string]AgentSessionStats{}
	if len(agentIDs) == 0 {
		return result, nil
	}

	// SQL 1: session_count + unread_total + last_msg_at
	rows, err := r.query(ctx, `
		SELECT
			cpa.member_id AS agent_id,
			COUNT(*) AS session_count,
			COALESCE(SUM(cpu.unread_count), 0) AS unread_total,
			MAX(COALESCE(
				(SELECT MAX(m.created_at) FROM messages m WHERE m.conversation_id = cs.id AND m.is_main_stream),
				cs.created_at
			)) AS last_msg_at
		FROM conversations cs
		JOIN conversation_participants cpu
			ON cpu.conv_id = cs.id AND cpu.member_id = $1 AND cpu.member_type = 'user'
			AND cpu.hidden_at IS NULL
		JOIN conversation_participants cpa
			ON cpa.conv_id = cs.id AND cpa.member_type = 'agent'
			AND cpa.member_id = ANY($2::uuid[])
		WHERE cs.type = 'agent_session'
		GROUP BY cpa.member_id`,
		userID, pq.Array(agentIDs),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			agentID   string
			stats     AgentSessionStats
			lastMsgAt sql.NullTime
		)
		if err := rows.Scan(&agentID, &stats.SessionCount, &stats.UnreadTotal, &lastMsgAt); err != nil {
			return nil, err
		}
		if lastMsgAt.Valid {
			stats.LastMessageAt = lastMsgAt.Time
		}
		result[agentID] = stats
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// SQL 2: pending_count（待处理 permission_card / question_card）
	rows2, err := r.query(ctx, `
		SELECT
			cpa.member_id AS agent_id,
			COUNT(*) AS pending_count
		FROM messages m
		JOIN conversations cs ON cs.id = m.conversation_id AND cs.type = 'agent_session'
		JOIN conversation_participants cpu
			ON cpu.conv_id = cs.id AND cpu.member_id = $1 AND cpu.member_type = 'user'
			AND cpu.hidden_at IS NULL
		JOIN conversation_participants cpa
			ON cpa.conv_id = cs.id AND cpa.member_type = 'agent'
			AND cpa.member_id = ANY($2::uuid[])
		WHERE m.content->>'msg_type' IN ('permission_card', 'question_card')
		  AND m.content->'data'->>'status' = 'pending'
		  AND m.is_main_stream
		  AND m.deleted_at IS NULL
		GROUP BY cpa.member_id`,
		userID, pq.Array(agentIDs),
	)
	if err != nil {
		return nil, err
	}
	defer rows2.Close()
	for rows2.Next() {
		var agentID string
		var pendingCount int
		if err := rows2.Scan(&agentID, &pendingCount); err != nil {
			return nil, err
		}
		if s, ok := result[agentID]; ok {
			s.PendingCount = pendingCount
			result[agentID] = s
		}
	}
	return result, rows2.Err()
}

// BeginTx 启动一个事务,供 MessageProcessor 在事务内同时写消息 + 更新缓存 + 写 deliveries + 更新 participants。
// ctx 控制 BeginTx 的发起与 tx 内 commit/rollback;
// 注意:tx 内的 *Context 变体(QueryRowContext/ExecContext 等)才会消费此 ctx,
// 非 Context 变体内部用 context.Background()(Go 标准库事实),不会响应 cancel。
// 调用方在事务内执行 query 时必须用 *Context 变体并显式传入同一 ctx。
func (r *ConversationRepo) BeginTx(ctx context.Context) (*sql.Tx, error) {
	return r.beginTx(ctx)
}

// GetLastVisibleMessage 取某 user 在某 conv 的「最新可见消息」(017 删缓存字段后新增,
// 跟 ListForUser 内 subquery 同口径):
//   - NOT EXISTS message_hidden(排除该 user 隐藏过的消息)
//   - 撤回消息(deleted_at 非空)仍计入,走 SanitizeForClient 改写后呈现给 client
//   - ORDER BY created_at DESC LIMIT 1
//
// 返回值含 sender_id/sender_type,供 client 切「你/对方撤回」文案。
// 无可见消息时 content.Valid=false 且 senderID/senderType 为空串。
// 走 idx_messages_conv_created (migration 012) + idx_message_hidden_member (migration 016),
// LIMIT 1 = O(log N)。
func (r *ConversationRepo) GetLastVisibleMessage(ctx context.Context, convID, memberID, memberType string) (content model.NullJSON, at time.Time, senderID, senderType string, err error) {
	var atNS sql.NullTime
	var senderIDNS, senderTypeNS sql.NullString
	err = r.queryRow(ctx, `
		-- 撤回消息(deleted_at 非空)的 content 改写为 recalled 占位,
		-- 对齐 Messages handler 的 SanitizeForClient + ListForUser 行为。
		-- sender_id/type 仍取原值,client 据此切「你/对方撤回」文案。
		SELECT CASE WHEN m.deleted_at IS NOT NULL
		       THEN '{"msg_type":"recalled","data":{}}'::jsonb
		       ELSE m.content END AS content, m.created_at,
		       m.sender_id, m.sender_type
		FROM messages m
		WHERE m.conversation_id = $1
		  AND m.is_main_stream
		  AND NOT EXISTS (
		    SELECT 1 FROM message_hidden h
		    WHERE h.message_id = m.id AND h.member_id = $2 AND h.member_type = $3
		  )
		ORDER BY m.created_at DESC LIMIT 1`,
		convID, memberID, memberType,
	).Scan(&content, &atNS, &senderIDNS, &senderTypeNS)
	if errors.Is(err, sql.ErrNoRows) {
		return model.NullJSON{}, time.Time{}, "", "", nil
	}
	if err != nil {
		return model.NullJSON{}, time.Time{}, "", "", err
	}
	if atNS.Valid {
		at = atNS.Time
	}
	senderID = senderIDNS.String
	senderType = senderTypeNS.String
	return content, at, senderID, senderType, nil
}

// CreateTx 在外部事务中创建一个会话(只 INSERT conversations 表,不加 participants)。
// 群聊创建用:handler 调本方法后,接着调 ParticipantRepo.AddParticipantsTx 加成员。
// 1-1 dm 用 FindOrCreateDM(内部会处理 participants)。
//
// 调用方负责 Commit/Rollback。
// typeStr 取值见 spec:dm_user_user / dm_user_agent / group_user / group_mixed。
// title/avatarURL 仅群聊用,1-1 为空串(传入空串 → DB 存 NULL)。
//
// ctx 用于让 tx 内 query 也响应 cancel(tx.QueryRowContext 等会消费此 ctx)。
// 非 Context 变体(tx.QueryRow/Exec)内部用 context.Background()(Go 标准库事实),
// 必须显式用 *Context 变体才生效。
func (r *ConversationRepo) CreateTx(ctx context.Context, tx *sql.Tx, typeStr, title, avatarURL string) (*model.Conversation, error) {
	c := &model.Conversation{}
	var titleNS, avatarURLNS sql.NullString
	err := tx.QueryRowContext(
		ctx,
		`INSERT INTO conversations (type, title, avatar_url)
		 VALUES ($1, NULLIF($2, ''), NULLIF($3, ''))
		 RETURNING id, type, title, avatar_url, created_at`,
		typeStr, title, avatarURL,
	).Scan(&c.ID, &c.Type, &titleNS, &avatarURLNS, &c.CreatedAt)
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
func (r *ConversationRepo) FindOrCreateDM(ctx context.Context, typeStr string, members DMMembers) (*model.Conversation, error) {
	tx, err := r.beginTx(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback() // commit 后 noop

	// 1. 查已存在的 dm(同 type + 同两方 participants)
	var convID string
	err = tx.QueryRowContext(ctx, `
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
		return r.GetByID(ctx, convID)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}

	// 2. 不存在,创建会话
	conv, err := r.CreateTx(ctx, tx, typeStr, "", "")
	if err != nil {
		return nil, err
	}

	// 3. 加 2 行 participants(Initiator=owner, Other=member)
	stmt, err := tx.PrepareContext(ctx, `
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
		if _, err := stmt.ExecContext(ctx, conv.ID, m.input.MemberID, m.input.MemberType, m.role); err != nil {
			return nil, err
		}
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return conv, nil
}

// CreateAgentSessionTx 是 CreateAgentSession 的事务体,接受外部 tx。
// 调用方负责 BeginTx/Commit/Rollback,适用于需要事务外插 RPC 调用的强同步场景。
func (r *ConversationRepo) CreateAgentSessionTx(ctx context.Context, tx *sql.Tx, ownerUserID, agentID, title, directory string) (*model.Conversation, error) {
	conv, err := r.CreateTx(ctx, tx, model.ConvTypeAgentSession, title, "")
	if err != nil {
		return nil, err
	}

	// 写入默认 session_meta,确保 APP 首屏即可渲染 SessionMetaStrip/EnvMetaStrip
	if _, err := tx.ExecContext(ctx,
		`UPDATE conversations SET session_meta = $2::jsonb WHERE id = $1`,
		conv.ID, `{"mode":"build","model_id":"","provider_id":""}`); err != nil {
		return nil, err
	}

	// 写入 directory(空串 = NULL,用户选默认)
	if directory != "" {
		if _, err := tx.ExecContext(ctx,
			`UPDATE conversations SET directory = $2 WHERE id = $1`,
			conv.ID, directory); err != nil {
			return nil, err
		}
	}

	// 加 2 行 participants(owner=user role=owner, agent=member role=member)
	stmt, err := tx.PrepareContext(ctx, `
		INSERT INTO conversation_participants (conv_id, member_id, member_type, role)
		VALUES ($1, $2, $3, $4)
	`)
	if err != nil {
		return nil, err
	}
	defer stmt.Close()
	for _, m := range []struct {
		memberID, memberType, role string
	}{
		{ownerUserID, "user", "owner"},
		{agentID, "agent", "member"},
	} {
		if _, err := stmt.ExecContext(ctx, conv.ID, m.memberID, m.memberType, m.role); err != nil {
			return nil, err
		}
	}

	return conv, nil
}

// CreateAgentSession 新建一个 agent_session 会话(每次新建,不去重)。
// 用于 opencode 多 session:同 (owner, agent) 可有 N 个 agent_session。
// ⚠️ 严禁用 FindOrCreateDM——其 (type+member set) 去重会合成 1 个。
// 事务内部 Begin/Commit,owner=user role=owner,agent=member role=member。
//
// 与 FindOrCreateDM 的关键差异:不做「已存在则复用」的 SELECT,每次都 INSERT 新行,
// 因此同 (ownerUserID, agentID) 调 N 次产生 N 个不同 conv_id(多实例语义)。
//
// directory 为 OC session 工作目录,空串表示用户选「默认」(NULL 入库)。
// 一级列固化后不再随 session_meta 变化(避免 JSONB 覆盖写互相影响)。
func (r *ConversationRepo) CreateAgentSession(ctx context.Context, ownerUserID, agentID, title, directory string) (*model.Conversation, error) {
	tx, err := r.beginTx(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	conv, err := r.CreateAgentSessionTx(ctx, tx, ownerUserID, agentID, title, directory)
	if err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return conv, nil
}

// FindDMByOwnerAgent 按 (owner_user_id, agent_id) 查 dm_user_agent 类型 conv。
// 仅查询不创建。供 agent_handler / pairing_handler 读已建的默认 conv。
// 未找到时返 (nil, nil)(不报错,调用方按需 fallback)。
func (r *ConversationRepo) FindDMByOwnerAgent(ctx context.Context, ownerUserID, agentID string) (*model.Conversation, error) {
	const q = `
		SELECT c.id, c.type, c.title, c.avatar_url, c.created_at
		FROM conversations c
		WHERE c.type = $1
		  AND EXISTS (
		    SELECT 1 FROM conversation_participants p1
		    WHERE p1.conv_id = c.id AND p1.member_id = $2 AND p1.member_type = 'user'
		  )
		  AND EXISTS (
		    SELECT 1 FROM conversation_participants p2
		    WHERE p2.conv_id = c.id AND p2.member_id = $3 AND p2.member_type = 'agent'
		  )
		LIMIT 1`
	c := &model.Conversation{}
	var title, avatarURL sql.NullString
	err := r.queryRow(ctx, q, model.ConvTypeDMUserAgent, ownerUserID, agentID).
		Scan(&c.ID, &c.Type, &title, &avatarURL, &c.CreatedAt)
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

// ListForAgent 列出 agent 参与的所有 conv(供 GET /api/agents/me/conversations 用)。
// 不做隐藏过滤(agent 视角看全部),按 created_at 倒序。
// typeFilter 空串 = 不过滤返全部;非空 = 只返该 type(如 "agent_session")。
func (r *ConversationRepo) ListForAgent(ctx context.Context, agentID, typeFilter string) ([]model.Conversation, error) {
	const q = `
		SELECT c.id, c.type, c.title, c.avatar_url, c.directory, c.created_at
		FROM conversations c
		JOIN conversation_participants p
		  ON p.conv_id = c.id AND p.member_id = $1 AND p.member_type = 'agent'
		WHERE ($2 = '' OR c.type = $2)
		ORDER BY c.created_at DESC`
	rows, err := r.query(ctx, q, agentID, typeFilter)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var convs []model.Conversation
	for rows.Next() {
		var c model.Conversation
		var title, avatarURL sql.NullString
		if err := rows.Scan(&c.ID, &c.Type, &title, &avatarURL, &c.Directory, &c.CreatedAt); err != nil {
			return nil, err
		}
		c.Title = title.String
		c.AvatarURL = avatarURL.String
		convs = append(convs, c)
	}
	return convs, rows.Err()
}

// ListAgentSessionsForUser 列出某 user 与某 agent 的所有 agent_session 群(user 视角)。
// 供 APP 二级列表页:点 opencode agent 入口 → 列出该 agent 下所有 session 群。
//
// 双 JOIN conversation_participants:同一 conv 同时含该 user(member_type='user')
// 和该 agent(member_type='agent'),且 c.type='agent_session'。
// 排除 dm_user_agent(一级列表用)+ 其他 agent 的 session(隔离)。
// 不做 hidden 过滤(二级列表展示全部实例,隐藏语义留给一级列表)。
// 按 created_at DESC(最新 session 排前)。
func (r *ConversationRepo) ListAgentSessionsForUser(ctx context.Context, userID, agentID string) ([]model.ConversationListItem, error) {
	rows, err := r.query(ctx, `
		SELECT c.id, c.type, c.title, c.avatar_url, c.directory, c.created_at,
		       pu.unread_count, pu.pinned_at, pu.hidden_at,
		       (
		         SELECT CASE WHEN m.deleted_at IS NOT NULL
		               THEN '{"msg_type":"recalled","data":{}}'::jsonb
		               ELSE m.content END
		         FROM messages m
		         WHERE m.conversation_id = c.id
		           AND m.is_main_stream
		           AND NOT EXISTS (
		             SELECT 1 FROM message_hidden h
		             WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = 'user'
		           )
		         ORDER BY m.created_at DESC LIMIT 1
		       ) AS last_message_content,
		       COALESCE((
		         SELECT m.created_at FROM messages m
		         WHERE m.conversation_id = c.id
		           AND m.is_main_stream
		           AND NOT EXISTS (
		             SELECT 1 FROM message_hidden h
		             WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = 'user'
		           )
		         ORDER BY m.created_at DESC LIMIT 1
		       ), c.created_at) AS last_message_at,
		       (
		         SELECT m.sender_id FROM messages m
		         WHERE m.conversation_id = c.id
		           AND m.is_main_stream
		           AND NOT EXISTS (
		             SELECT 1 FROM message_hidden h
		             WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = 'user'
		           )
		         ORDER BY m.created_at DESC LIMIT 1
		       ) AS last_message_sender_id,
		       (
		         SELECT m.sender_type FROM messages m
		         WHERE m.conversation_id = c.id
		           AND m.is_main_stream
		           AND NOT EXISTS (
		             SELECT 1 FROM message_hidden h
		             WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = 'user'
		           )
		         ORDER BY m.created_at DESC LIMIT 1
		       ) AS last_message_sender_type,
		       (
		         SELECT COALESCE(NULLIF(u.nickname, ''), u.username, a.name, '')
		         FROM messages m
		         LEFT JOIN users u ON m.sender_type = 'user' AND m.sender_id = u.id
		         LEFT JOIN agents a ON m.sender_type = 'agent' AND m.sender_id = a.id
		         WHERE m.conversation_id = c.id
		           AND m.is_main_stream
		           AND NOT EXISTS (
		             SELECT 1 FROM message_hidden h
		             WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = 'user'
		           )
		         ORDER BY m.created_at DESC LIMIT 1
		       ) AS last_message_sender_name,
		       (
		         SELECT COUNT(*) FROM messages m
		         WHERE m.conversation_id = c.id
		           AND m.content->>'msg_type' IN ('permission_card', 'question_card')
		           AND m.content->'data'->>'status' = 'pending'
		           AND m.is_main_stream
		           AND m.deleted_at IS NULL
		       ) AS pending_count,
		       (
		         SELECT CASE
		           WHEN m.content->>'msg_type' = 'aggregate_card'
		             THEN m.content->'data'->>'preview'
		           ELSE m.content->'data'->>'text'
		         END
		         FROM messages m
		         WHERE m.conversation_id = c.id
		           AND m.is_main_stream
		           AND m.sender_type = 'agent'
		           AND m.sender_id = $2
		           AND m.content->>'silent' IS DISTINCT FROM 'true'
		           AND (
		             m.content->>'msg_type' IN ('text', 'markdown')
		             OR (m.content->>'msg_type' = 'aggregate_card'
		                 AND m.content->'data'->>'preview' IS NOT NULL
		                 AND m.content->'data'->>'preview' != '')
		           )
		           AND m.deleted_at IS NULL
		           AND NOT EXISTS (
		             SELECT 1 FROM message_hidden h
		             WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = 'user'
		           )
		         ORDER BY m.created_at DESC LIMIT 1
		       ) AS last_agent_reply_content
		FROM conversations c
		JOIN conversation_participants pu
		  ON pu.conv_id = c.id AND pu.member_id = $1 AND pu.member_type = 'user'
		JOIN conversation_participants pa
		  ON pa.conv_id = c.id AND pa.member_id = $2 AND pa.member_type = 'agent'
		WHERE c.type = 'agent_session'
		  AND pu.hidden_at IS NULL
		ORDER BY pu.pinned_at DESC NULLS LAST,
		         COALESCE((
		           SELECT m.created_at FROM messages m
		           WHERE m.conversation_id = c.id
		             AND m.is_main_stream
		             AND NOT EXISTS (
		               SELECT 1 FROM message_hidden h
		               WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = 'user'
		             )
		           ORDER BY m.created_at DESC LIMIT 1
		         ), c.created_at) DESC NULLS LAST`,
		userID, agentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var items []model.ConversationListItem
	for rows.Next() {
		var (
			item         model.ConversationListItem
			titleNS      sql.NullString
			avatarNS     sql.NullString
			senderIDNS   sql.NullString
			senderTypeNS sql.NullString
			senderNameNS sql.NullString
			userMsgNS    sql.NullString
		)
		if err := rows.Scan(
			&item.ID, &item.Type, &titleNS, &avatarNS, &item.Directory, &item.CreatedAt,
			&item.UnreadCount, &item.PinnedAt, &item.HiddenAt,
			&item.LastMessageContent, &item.LastMessageAt,
			&senderIDNS, &senderTypeNS, &senderNameNS,
			&item.PendingCount, &userMsgNS,
		); err != nil {
			return nil, err
		}
		item.Title = titleNS.String
		item.AvatarURL = avatarNS.String
		item.LastMessageSenderID = senderIDNS.String
		item.LastMessageSenderType = senderTypeNS.String
		item.LastMessageSenderName = senderNameNS.String
		item.LastAgentReplyContent = userMsgNS.String
		items = append(items, item)
	}
	return items, rows.Err()
}

// UpdateProfile 更新会话自身的 title / avatar_url(群聊用)。
// 用 COALESCE(NULLIF) 模式:空串=不动(不支持清空,语义同 AgentRepo.Update)。
// 越权防护(仅 owner/admin 可改)由 handler 层做,本方法只做字段更新。
func (r *ConversationRepo) UpdateProfile(ctx context.Context, convID, title, avatarURL string) error {
	_, err := r.exec(ctx,
		`UPDATE conversations
		 SET title = COALESCE(NULLIF($2, ''), title),
		     avatar_url = COALESCE(NULLIF($3, ''), avatar_url)
		 WHERE id = $1`,
		convID, title, avatarURL,
	)
	return err
}

// UpdateSessionMeta 更新 agent_session 的元数据（mode/model/variant）。
// plugin session.updated 事件触发，覆盖写入 session_meta JSONB 列。
func (r *ConversationRepo) UpdateSessionMeta(ctx context.Context, convID string, meta []byte) error {
	_, err := r.exec(ctx,
		`UPDATE conversations SET session_meta = $2 WHERE id = $1`,
		convID, meta,
	)
	return err
}
