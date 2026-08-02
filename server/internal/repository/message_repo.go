// MessageRepo 操作 messages 表。
//
// participants 模型重构后,本 repo 职责瘦身:
//   - createMessage 不再写 is_read 字段(该字段已 DROP)
//   - per-recipient 投递状态(read_at)由 DeliveryRepo 管,本 repo 只关心消息本身
//   - 首条未读查询走 DeliveryRepo.FirstUnread(JOIN message_deliveries)
package repository

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/lib/pq"
	"github.com/wanling/server/internal/model"
)

type MessageRepo struct {
	queryExecutor
}

func NewMessageRepo(db *sql.DB) *MessageRepo {
	return &MessageRepo{queryExecutor: queryExecutor{db: db}}
}

func (r *MessageRepo) Create(ctx context.Context, convID, senderType, senderID string, content json.RawMessage) (*model.Message, error) {
	return r.createMessage(ctx, r.queryExecutor.db.QueryRowContext, convID, senderType, senderID, content)
}

// CreateTx 在外部事务中创建消息,供 MessageProcessor 与缓存更新原子化提交使用。
// 调用方负责 Begin/Commit/Rollback;本方法只 INSERT + RETURNING。
//
// ctx 用于让 tx 内 query 也响应 cancel(tx.QueryRowContext 会消费此 ctx)。
// 之前的版本误以为 BeginTx 的 ctx 自动透传到 tx 内 query,实际 driver 行为是非 Context 变体
// 内部用 context.Background()(Go 标准库事实),必须显式用 *Context 变体才生效。
func (r *MessageRepo) CreateTx(ctx context.Context, tx *sql.Tx, convID, senderType, senderID string, content json.RawMessage) (*model.Message, error) {
	return r.createMessage(ctx, tx.QueryRowContext, convID, senderType, senderID, content)
}

// createMessage 是 Create / CreateTx 的公共实现,用闭包接收 QueryRowContext 能力。
// *sql.DB 和 *sql.Tx 的 QueryRowContext 方法签名相同,闭包方案比 interface 更轻量。
//
// participants 模型重构后,本方法只 INSERT messages 本身,不写任何 per-recipient 状态。
// deliveries(read_at)由 MessageProcessor 协调 DeliveryRepo.CreateBatchTx 写,
// 未读计数由 ParticipantRepo.IncrUnreadTx 维护。
func (r *MessageRepo) createMessage(
	ctx context.Context,
	queryRow func(ctx context.Context, query string, args ...interface{}) *sql.Row,
	convID, senderType, senderID string, content json.RawMessage,
) (*model.Message, error) {
	m := &model.Message{}
	err := queryRow(ctx,
		`INSERT INTO messages (conversation_id, sender_type, sender_id, content)
		 VALUES ($1, $2, $3, $4)
		 RETURNING id, conversation_id, sender_type, sender_id, content, parent_msg_id, root_msg_id, deleted_at, created_at`,
		convID, senderType, senderID, content,
	).Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.ParentMsgID, &m.RootMsgID, &m.DeletedAt, &m.CreatedAt)
	return m, err
}

// ListByConversation 返回会话消息分页列表(newest first)。
// 撤回的消息(deleted_at IS NOT NULL)也返,靠 SanitizeForClient 在 handler 出口
// 把 content 改写为占位,客户端据此渲染"该消息已被撤回"占位卡片。
// 仅过滤该 member 主动隐藏过的消息(per-participant 隐藏,与全局撤回语义区分)。
// 子 agent 事件(is_main_stream=false)被排除:主聊天列表只展示主对话流消息,
// 子树(如 tool_card / reasoning)由 ListByRoot 单独查。审批卡豁免(is_main_stream=true)浮顶。
func (r *MessageRepo) ListByConversation(ctx context.Context, convID, memberID, memberType string, limit, offset int) ([]model.Message, error) {
	rows, err := r.query(ctx,
		`SELECT m.id, m.conversation_id, m.sender_type, m.sender_id, m.content, m.parent_msg_id, m.root_msg_id, m.deleted_at, m.created_at,
		        COALESCE(NULLIF(u.nickname, ''), u.username, a.name, '') AS sender_name,
		        COALESCE(NULLIF(u.avatar_url, ''), NULLIF(a.avatar_url, ''), '') AS sender_avatar_url
		 FROM messages m
		 LEFT JOIN users u ON m.sender_type = 'user' AND m.sender_id = u.id
		 LEFT JOIN agents a ON m.sender_type = 'agent' AND m.sender_id = a.id
		 WHERE m.conversation_id = $1
		   AND m.is_main_stream
		   AND NOT EXISTS (
		     SELECT 1 FROM message_hidden h
		     WHERE h.message_id = m.id AND h.member_id = $2 AND h.member_type = $3
		   )
		 ORDER BY m.created_at DESC LIMIT $4 OFFSET $5`,
		convID, memberID, memberType, limit, offset,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var msgs []model.Message
	for rows.Next() {
		var m model.Message
		if err := rows.Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.ParentMsgID, &m.RootMsgID, &m.DeletedAt, &m.CreatedAt, &m.SenderName, &m.SenderAvatarURL); err != nil {
			return nil, err
		}
		msgs = append(msgs, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return msgs, nil
}

// Get 按 id 查单条消息(不过滤 deleted_at,权限校验需要知道消息是否存在)。
// 不存在返回 (nil, nil)。
func (r *MessageRepo) Get(ctx context.Context, id string) (*model.Message, error) {
	m := &model.Message{}
	err := r.queryRow(ctx,
		`SELECT id, conversation_id, sender_type, sender_id, content, parent_msg_id, root_msg_id, deleted_at, created_at
		 FROM messages WHERE id = $1`,
		id,
	).Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.ParentMsgID, &m.RootMsgID, &m.DeletedAt, &m.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return m, nil
}

// GetByIDs 批量查询消息(不过滤 deleted_at)。供 BatchDelete 权限校验用。
func (r *MessageRepo) GetByIDs(ctx context.Context, ids []string) ([]model.Message, error) {
	rows, err := r.query(ctx,
		`SELECT id, conversation_id, sender_type, sender_id, content, parent_msg_id, root_msg_id, deleted_at, created_at
		 FROM messages WHERE id = ANY($1)`,
		pq.Array(ids),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var msgs []model.Message
	for rows.Next() {
		var m model.Message
		if err := rows.Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.ParentMsgID, &m.RootMsgID, &m.DeletedAt, &m.CreatedAt); err != nil {
			return nil, err
		}
		msgs = append(msgs, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return msgs, nil
}

// SoftDeleteTx 事务版本:撤回 handler 把 SoftDelete + RecomputeUnreadForConvTx
// 绑同一事务,确保 deleted_at 与 unread_count 原子一致性。
// 调用方负责 Commit/Rollback。
//
// ctx 用于让 tx 内 query 也响应 cancel(tx.ExecContext 会消费此 ctx)。
func (r *MessageRepo) SoftDeleteTx(ctx context.Context, tx *sql.Tx, id string) error {
	_, err := tx.ExecContext(
		ctx,
		`UPDATE messages SET deleted_at = NOW() WHERE id = $1`,
		id,
	)
	return err
}

// UpdateContent 原地替换消息 content。sender_id 写进 WHERE 做越权兜底:
// 只允许 sender 本人改自己发的消息(handler 层已做 role+id 校验,这里 SQL 层再防一道)。
//
// 用于交互卡片状态变更:plugin PATCH 原 card 消息的 status 字段
// (permission_card / question_card 从 pending → 终态),触发 MESSAGE_UPDATE 广播
// 让 APP 重渲染卡片。
//
// deleted_at IS NULL 排除已撤回消息(撤回后改 content 无意义)。
// 返回 sql.ErrNoRows 表示 msgID 不存在 / 已软删 / senderID 不匹配
// (三者不区分,既防枚举又对齐项目既有 sql.ErrNoRows 约定)。
func (r *MessageRepo) UpdateContent(ctx context.Context, msgID, senderID string, content json.RawMessage) error {
	result, err := r.exec(ctx,
		`UPDATE messages SET content = $1 WHERE id = $2 AND sender_id = $3 AND deleted_at IS NULL`,
		content, msgID, senderID,
	)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// GetMessageContextTx 取 target 消息 + 前后 N 条,用于跨页跳转场景
// (用户点击引用块,客户端拉一段上下文单独渲染)。
//
// 与 ListBefore/ListAfter 的关键差异:before/after **过滤软删除消息**(撤回的消息
// 在跳转视图里无意义,不需要「已被撤回」占位)。target 自身按 Get 语义不过滤
// deleted_at(handler 层若需要禁止跳转到已撤回消息,自行判断)。
//
// 返回:
//   - target: 不存在时返回 (nil, nil, nil, nil),与 Get 的 not-found 约定一致
//   - before: target 之前的 N 条,按 created_at DESC(最近在前)
//   - after:  target 之后的 N 条,按 created_at ASC(最老在前)
//
// tx 参数让调用方把「读取上下文」与其他操作绑同一事务;传 nil 则走 r.db。
// ctx 用于让 tx 内 query 也响应 cancel(tx.QueryRowContext/QueryContext 会消费此 ctx)。
func (r *MessageRepo) GetMessageContextTx(
	ctx context.Context,
	tx *sql.Tx,
	targetID string,
	before, after int,
) (target *model.Message, beforeMsgs, afterMsgs []model.Message, err error) {
	// 1. 取 target(沿用 Get 的 not-found=返 nil 语义,tx 优先)
	target, err = r.getMessageContextTarget(ctx, tx, targetID)
	if err != nil {
		return nil, nil, nil, err
	}
	if target == nil {
		return nil, nil, nil, nil
	}

	// 2. before/after 用同 conv + deleted_at IS NULL 过滤,严格 < / > target.CreatedAt
	if before > 0 {
		beforeMsgs, err = r.listMessageContextRange(ctx, tx, target.ConversationID, target.CreatedAt, before, true /* desc */)
		if err != nil {
			return nil, nil, nil, err
		}
	}
	if after > 0 {
		afterMsgs, err = r.listMessageContextRange(ctx, tx, target.ConversationID, target.CreatedAt, after, false /* asc */)
		if err != nil {
			return nil, nil, nil, err
		}
	}
	return target, beforeMsgs, afterMsgs, nil
}

// getMessageContextTarget 是 GetMessageContextTx 内部用的 Get 变体,支持 tx。
// tx=nil 时走 r.queryRow,r.db 查;tx!=nil 时走 tx.QueryRowContext,绑外部事务。
// 不存在时返回 (nil, nil),与 Get 的约定一致。
func (r *MessageRepo) getMessageContextTarget(ctx context.Context, tx *sql.Tx, id string) (*model.Message, error) {
	const query = `SELECT id, conversation_id, sender_type, sender_id, content, parent_msg_id, root_msg_id, deleted_at, created_at
	               FROM messages WHERE id = $1`
	m := &model.Message{}
	var err error
	if tx != nil {
		err = tx.QueryRowContext(ctx, query, id).Scan(
			&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.ParentMsgID, &m.RootMsgID, &m.DeletedAt, &m.CreatedAt,
		)
	} else {
		err = r.queryRow(ctx, query, id).Scan(
			&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.ParentMsgID, &m.RootMsgID, &m.DeletedAt, &m.CreatedAt,
		)
	}
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return m, nil
}

// listMessageContextRange 是 GetMessageContextTx 内部用的 before/after 查询。
// desc=true → created_at < pivot,ORDER BY created_at DESC(before 区,最近在前);
// desc=false → created_at > pivot,ORDER BY created_at ASC(after 区,最老在前)。
// 软删除消息(deleted_at IS NOT NULL)被过滤,不参与跳转上下文渲染。
// tx=nil 时走 r.query,tx!=nil 时走 tx.QueryContext(绑外部事务)。
func (r *MessageRepo) listMessageContextRange(
	ctx context.Context,
	tx *sql.Tx,
	convID string,
	pivot time.Time,
	limit int,
	desc bool,
) ([]model.Message, error) {
	// 防御性 limit 检查:负数 fail fast(handler 层已 clamp,这里兜底防其他调用方
	// 直接传负数到 Postgres LIMIT,某些 PG 版本对 LIMIT -1 解释为「无上限」)。
	if limit < 0 {
		return nil, fmt.Errorf("listMessageContextRange: limit must not be negative")
	}
	if limit == 0 {
		return nil, nil
	}
	const selectCols = `SELECT id, conversation_id, sender_type, sender_id, content, parent_msg_id, root_msg_id, deleted_at, created_at
	                    FROM messages
	                    WHERE conversation_id = $1 AND deleted_at IS NULL AND is_main_stream`
	var query string
	if desc {
		query = selectCols + ` AND created_at < $2 ORDER BY created_at DESC LIMIT $3`
	} else {
		query = selectCols + ` AND created_at > $2 ORDER BY created_at ASC LIMIT $3`
	}

	var rows *sql.Rows
	var err error
	if tx != nil {
		rows, err = tx.QueryContext(ctx, query, convID, pivot, limit)
	} else {
		rows, err = r.query(ctx, query, convID, pivot, limit)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var msgs []model.Message
	for rows.Next() {
		var m model.Message
		if err := rows.Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.ParentMsgID, &m.RootMsgID, &m.DeletedAt, &m.CreatedAt); err != nil {
			return nil, err
		}
		msgs = append(msgs, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return msgs, nil
}

// HideForUser 把单条消息对某 participant 隐藏(per-participant 维度)。
// 重复 hide 幂等(ON CONFLICT DO NOTHING)。语义见 016 migration 注释。
func (r *MessageRepo) HideForUser(ctx context.Context, messageID, memberID, memberType string) error {
	_, err := r.exec(ctx, `
		INSERT INTO message_hidden (message_id, member_id, member_type)
		VALUES ($1, $2, $3)
		ON CONFLICT (message_id, member_id, member_type) DO NOTHING
	`, messageID, memberID, memberType)
	return err
}

// IsHidden 查某条消息是否被某 participant 隐藏(per-participant 单向)。
// 供 GetMessageContext handler 拒绝「跳转到已隐藏消息」用:
// 用户长按消息选「删除」(scope=hide) 后,该消息对自己不可见,
// 通过引用块跳转应返 404,符合 hide 意图(别人 hide 不影响本判断)。
func (r *MessageRepo) IsHidden(ctx context.Context, messageID, memberID, memberType string) (bool, error) {
	var exists bool
	err := r.queryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM message_hidden
		  WHERE message_id = $1 AND member_id = $2 AND member_type = $3)`,
		messageID, memberID, memberType,
	).Scan(&exists)
	if err != nil {
		return false, err
	}
	return exists, nil
}

// HideForUsers 批量隐藏,返回受影响行数(新增插入数,已隐藏的不计)。
// 用于 batch-delete 的 scope=hide 路径。
func (r *MessageRepo) HideForUsers(ctx context.Context, messageIDs []string, memberID, memberType string) (int64, error) {
	if len(messageIDs) == 0 {
		return 0, nil
	}
	res, err := r.exec(ctx, `
		INSERT INTO message_hidden (message_id, member_id, member_type)
		SELECT unnest($1::uuid[]), $2, $3
		ON CONFLICT (message_id, member_id, member_type) DO NOTHING
	`, pq.Array(messageIDs), memberID, memberType)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// ListBefore 返回 created_at < before 的消息(游标分页),newest first。
// before 为零值时返回最新 limit 条(等价 ListByConversation 第一页)。
// 用于消息导航的游标分页加载历史("更老方向",上滑加载)。
// 撤回的消息(deleted_at IS NOT NULL)也返,client 端 SanitizeForClient 渲染占位。
// 仅过滤该 member 主动隐藏过的消息。子 agent 事件(is_main_stream=false)
// 被排除:主聊天列表只展示主对话流消息,子树由 ListByRoot 单独查。审批卡豁免浮顶。
//
// 为什么用 created_at 作 cursor:messages.id 是 UUID v4(随机无序),不能作 cursor
// (id < $2 比较无意义),created_at 是本项目唯一可用的时间序字段。同 created_at
// 边界的消息(生产环境同毫秒概率极低)用 `<` 严格小于规避。
func (r *MessageRepo) ListBefore(ctx context.Context, convID, memberID, memberType string, before time.Time, limit int) ([]model.Message, error) {
	var rows *sql.Rows
	var err error
	if before.IsZero() {
		rows, err = r.query(ctx,
			`SELECT m.id, m.conversation_id, m.sender_type, m.sender_id, m.content, m.parent_msg_id, m.root_msg_id, m.deleted_at, m.created_at,
			        COALESCE(NULLIF(u.nickname, ''), u.username, a.name, '') AS sender_name,
			        COALESCE(NULLIF(u.avatar_url, ''), NULLIF(a.avatar_url, ''), '') AS sender_avatar_url
			 FROM messages m
			 LEFT JOIN users u ON m.sender_type = 'user' AND m.sender_id = u.id
			 LEFT JOIN agents a ON m.sender_type = 'agent' AND m.sender_id = a.id
			 WHERE m.conversation_id = $1
			   AND m.is_main_stream
			   AND NOT EXISTS (
			     SELECT 1 FROM message_hidden h
			     WHERE h.message_id = m.id AND h.member_id = $2 AND h.member_type = $3
			   )
			 ORDER BY m.created_at DESC LIMIT $4`,
			convID, memberID, memberType, limit,
		)
	} else {
		rows, err = r.query(ctx,
			`SELECT m.id, m.conversation_id, m.sender_type, m.sender_id, m.content, m.parent_msg_id, m.root_msg_id, m.deleted_at, m.created_at,
			        COALESCE(NULLIF(u.nickname, ''), u.username, a.name, '') AS sender_name,
			        COALESCE(NULLIF(u.avatar_url, ''), NULLIF(a.avatar_url, ''), '') AS sender_avatar_url
			 FROM messages m
			 LEFT JOIN users u ON m.sender_type = 'user' AND m.sender_id = u.id
			 LEFT JOIN agents a ON m.sender_type = 'agent' AND m.sender_id = a.id
			 WHERE m.conversation_id = $1
			   AND m.is_main_stream
			   AND NOT EXISTS (
			     SELECT 1 FROM message_hidden h
			     WHERE h.message_id = m.id AND h.member_id = $2 AND h.member_type = $3
			   )
			   AND m.created_at < $4
			 ORDER BY m.created_at DESC LIMIT $5`,
			convID, memberID, memberType, before, limit,
		)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var msgs []model.Message
	for rows.Next() {
		var m model.Message
		if err := rows.Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.ParentMsgID, &m.RootMsgID, &m.DeletedAt, &m.CreatedAt, &m.SenderName, &m.SenderAvatarURL); err != nil {
			return nil, err
		}
		msgs = append(msgs, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return msgs, nil
}

// CountBefore 返回 created_at < before 的未删 + 未隐藏消息数。
// 用于 APP 进入有未读会话时判断 firstUnread 之前是否还有已读历史,
// 决定 hasMore(是否允许上滑加载历史)。
//
// 与 ListBefore 保持一致:子 agent 事件(is_main_stream=false)被排除,
// 避免 hasMoreBeforeFirstUnread 因子事件误判为 true → APP 显示"上方加载更多"
// 但 ListBefore 实际过滤后返回空,造成 UX 不一致。审批卡豁免浮顶。
func (r *MessageRepo) CountBefore(ctx context.Context, convID, memberID, memberType string, before time.Time) (int, error) {
	var count int
	err := r.queryRow(ctx,
		`SELECT COUNT(*) FROM messages m
		 WHERE m.conversation_id = $1 AND m.is_main_stream AND m.deleted_at IS NULL AND m.created_at < $2
		   AND NOT EXISTS (
		     SELECT 1 FROM message_hidden h
		     WHERE h.message_id = m.id AND h.member_id = $3 AND h.member_type = $4
		   )`,
		convID, before, memberID, memberType,
	).Scan(&count)
	if err != nil {
		return 0, err
	}
	return count, nil
}

// ListAfter 返回 created_at > after 的消息("未读方向"游标分页),ASC(最老在前)。
// 与 ListBefore(DESC,更老方向)对称,供"进入会话定位第一条未读"场景使用:
// firstUnread + 之后的 N-1 条,让 firstUnread 落在 loaded 开头;APP 端 reverse 后
// 变成 newest first(firstUnread 在末尾=视觉顶部,跳到它,下方是更新的未读)。
//
// 撤回的消息(deleted_at IS NOT NULL)也返,client 端 SanitizeForClient 渲染占位。
// 仅过滤该 member 主动隐藏过的消息。ASC 排序:与 ListBefore 的 DESC 反向,调用方按需 reverse。
// 子 agent 事件(is_main_stream=false)被排除:未读统计只关心主对话流。审批卡豁免浮顶。
func (r *MessageRepo) ListAfter(ctx context.Context, convID, memberID, memberType string, after time.Time, limit int) ([]model.Message, error) {
	rows, err := r.query(ctx,
		`SELECT m.id, m.conversation_id, m.sender_type, m.sender_id, m.content, m.parent_msg_id, m.root_msg_id, m.deleted_at, m.created_at,
		        COALESCE(NULLIF(u.nickname, ''), u.username, a.name, '') AS sender_name,
		        COALESCE(NULLIF(u.avatar_url, ''), NULLIF(a.avatar_url, ''), '') AS sender_avatar_url
		 FROM messages m
		 LEFT JOIN users u ON m.sender_type = 'user' AND m.sender_id = u.id
		 LEFT JOIN agents a ON m.sender_type = 'agent' AND m.sender_id = a.id
		 WHERE m.conversation_id = $1
		   AND m.is_main_stream
		   AND NOT EXISTS (
		     SELECT 1 FROM message_hidden h
		     WHERE h.message_id = m.id AND h.member_id = $2 AND h.member_type = $3
		   )
		   AND m.created_at > $4
		 ORDER BY m.created_at ASC LIMIT $5`,
		convID, memberID, memberType, after, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var msgs []model.Message
	for rows.Next() {
		var m model.Message
		if err := rows.Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.ParentMsgID, &m.RootMsgID, &m.DeletedAt, &m.CreatedAt, &m.SenderName, &m.SenderAvatarURL); err != nil {
			return nil, err
		}
		msgs = append(msgs, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return msgs, nil
}

// CreateWithParent 创建带 parent_msg_id + root_msg_id 的消息(子 agent 事件用)。
// 与 Create 的差异仅在多写两个外键字段;调用方据此区分主对话流消息 vs 子 agent 子树事件。
func (r *MessageRepo) CreateWithParent(ctx context.Context, convID, senderType, senderID string, content json.RawMessage, parentMsgID, rootMsgID string) (*model.Message, error) {
	var msg model.Message
	err := r.queryRow(ctx, `
		INSERT INTO messages (conversation_id, sender_type, sender_id, content, parent_msg_id, root_msg_id)
		VALUES ($1, $2, $3, $4, $5, $6)
		RETURNING id, conversation_id, sender_type, sender_id, content, parent_msg_id, root_msg_id, deleted_at, created_at`,
		convID, senderType, senderID, content, parentMsgID, rootMsgID,
	).Scan(
		&msg.ID, &msg.ConversationID, &msg.SenderType, &msg.SenderID, &msg.Content,
		&msg.ParentMsgID, &msg.RootMsgID, &msg.DeletedAt, &msg.CreatedAt,
	)
	if err != nil {
		return nil, err
	}
	return &msg, nil
}

// CreateWithParentTx 是 CreateWithParent 的事务版本,供 Processor.PersistAndDispatch
// 在事务内与 message_deliveries / unread_count 一起原子提交。
// ctx 用于让 tx 内 query 也响应 cancel(tx.QueryRowContext 显式消费此 ctx)。
func (r *MessageRepo) CreateWithParentTx(ctx context.Context, tx *sql.Tx, convID, senderType, senderID string, content json.RawMessage, parentMsgID, rootMsgID string) (*model.Message, error) {
	var msg model.Message
	err := tx.QueryRowContext(ctx, `
		INSERT INTO messages (conversation_id, sender_type, sender_id, content, parent_msg_id, root_msg_id)
		VALUES ($1, $2, $3, $4, $5, $6)
		RETURNING id, conversation_id, sender_type, sender_id, content, parent_msg_id, root_msg_id, deleted_at, created_at`,
		convID, senderType, senderID, content, parentMsgID, rootMsgID,
	).Scan(
		&msg.ID, &msg.ConversationID, &msg.SenderType, &msg.SenderID, &msg.Content,
		&msg.ParentMsgID, &msg.RootMsgID, &msg.DeletedAt, &msg.CreatedAt,
	)
	if err != nil {
		return nil, err
	}
	return &msg, nil
}

// ListByRoot 按 root_msg_id 拉子树(详情页查询用),不含根本身。
// 根消息自身的 root_msg_id 为 NULL,WHERE root_msg_id = $1 自然排除根,无需额外 NOT IN。
// deleted_at IS NULL 过滤软删子事件;limit 在 [1,200] 之外兜底为 50(防 0/超大 LIMIT)。
func (r *MessageRepo) ListByRoot(ctx context.Context, convID, rootMsgID string, limit int) ([]model.Message, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	rows, err := r.query(ctx, `
		SELECT m.id, m.conversation_id, m.sender_type, m.sender_id, m.content, m.parent_msg_id, m.root_msg_id, m.deleted_at, m.created_at,
		        COALESCE(NULLIF(u.nickname, ''), u.username, a.name, '') AS sender_name,
		        COALESCE(NULLIF(u.avatar_url, ''), NULLIF(a.avatar_url, ''), '') AS sender_avatar_url
		FROM messages m
		LEFT JOIN users u ON m.sender_type = 'user' AND m.sender_id = u.id
		LEFT JOIN agents a ON m.sender_type = 'agent' AND m.sender_id = a.id
		WHERE m.root_msg_id = $1 AND m.conversation_id = $2 AND m.deleted_at IS NULL
		ORDER BY m.created_at ASC
		LIMIT $3`,
		rootMsgID, convID, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var msgs []model.Message
	for rows.Next() {
		var msg model.Message
		if err := rows.Scan(&msg.ID, &msg.ConversationID, &msg.SenderType, &msg.SenderID, &msg.Content, &msg.ParentMsgID, &msg.RootMsgID, &msg.DeletedAt, &msg.CreatedAt, &msg.SenderName, &msg.SenderAvatarURL); err != nil {
			return nil, err
		}
		msgs = append(msgs, msg)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return msgs, nil
}
