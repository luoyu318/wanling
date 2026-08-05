package handler

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/hub"
	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// 默认值常量,NewMessageHandler 用作兜底。main.go 通过 SetMaxBatchDelete /
// SetRecallWindow 用 cfg 覆盖。值与历史 const 一致(向后兼容)。
const (
	defaultMaxBatchDelete = 100

	// defaultRecallWindow 撤回时间窗口(自己发的消息超过此时限不可撤回,只能 hide)。
	// 对齐主流 IM 约定。
	defaultRecallWindow = 5 * time.Minute
)

// MessageHandler 处理消息删除请求(单删 + 批量删)。
//
// 双轨制语义(见 migration 016):
//   - scope=hide (默认):对自己隐藏(per-participant 维度,单向不可见)
//     → 调 msgRepo.HideForUser,单播 MESSAGE_DELETE 给当前请求者
//   - scope=recall:撤回(全局软删,双向不可见),仅自己发的 + recallWindow 内
//     → 调 msgRepo.SoftDeleteTx,广播 MESSAGE_DELETE 给会话全员
//
// 撤回广播 payload 含 scope='recall' + sender_id + sender_name,client 据此显示
// "你撤回了一条消息" / "对方撤回了一条消息" / 群聊场景 "${name} 撤回了一条消息"。
type MessageHandler struct {
	msgRepo         *repository.MessageRepo
	convRepo        *repository.ConversationRepo
	participantRepo *repository.ParticipantRepo
	userRepo        *repository.UserRepo
	agentRepo       *repository.AgentRepo
	hub             *hub.Hub
	maxBatchDelete  int
	recallWindow    time.Duration
}

func NewMessageHandler(
	msgRepo *repository.MessageRepo, convRepo *repository.ConversationRepo,
	participantRepo *repository.ParticipantRepo,
	userRepo *repository.UserRepo, agentRepo *repository.AgentRepo,
	h *hub.Hub,
) *MessageHandler {
	return &MessageHandler{
		msgRepo:         msgRepo,
		convRepo:        convRepo,
		participantRepo: participantRepo,
		userRepo:        userRepo,
		agentRepo:       agentRepo,
		hub:             h,
		maxBatchDelete:  defaultMaxBatchDelete,
		recallWindow:    defaultRecallWindow,
	}
}

// SetMaxBatchDelete 覆盖批量删除上限。main.go 启动时从 cfg 注入。≤0 无效。
func (h *MessageHandler) SetMaxBatchDelete(n int) {
	if n > 0 {
		h.maxBatchDelete = n
	}
}

// SetRecallWindow 覆盖撤回时间窗口。main.go 启动时从 cfg 注入。≤0 无效。
func (h *MessageHandler) SetRecallWindow(d time.Duration) {
	if d > 0 {
		h.recallWindow = d
	}
}

// Delete 软删/隐藏单条消息。DELETE /api/messages/:id?scope=hide|recall
//
// scope=hide (默认):对自己隐藏。
//   - 权限:必须是 participant
//   - 副作用:无(会话列表子查询按个人维度实时算)
//   - 广播:单播 MESSAGE_DELETE 给当前请求者(只对我消失)
//
// scope=recall:撤回(对自己 + 对方都不可见)。
//   - 权限:必须是 sender 本身
//   - 时限:created_at + recallWindow > now
//   - 副作用:无(会话列表子查询自动反映)
//   - 广播:广播 MESSAGE_DELETE 给会话全员,payload 含 scope=recall + sender 信息
func (h *MessageHandler) Delete(c *gin.Context) {
	id := c.Param("id")
	actorID := c.GetString("userID")
	role := c.GetString("role") // user|agent
	scope := c.DefaultQuery("scope", "hide")

	msg, err := h.msgRepo.Get(c.Request.Context(), id)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "查询消息失败")
		return
	}
	if msg == nil {
		Err(c, http.StatusNotFound, "not_found", "消息不存在")
		return
	}

	if !h.canAccess(c.Request.Context(), msg.ConversationID, actorID, role) {
		Err(c, http.StatusForbidden, "forbidden", "无权操作该消息")
		return
	}

	switch scope {
	case "recall":
		// 撤回权限:必须是 sender 本身
		if msg.SenderID != actorID || msg.SenderType != role {
			Err(c, http.StatusForbidden, "forbidden", "只能撤回自己发的消息")
			return
		}
		// 撤回时限
		if time.Since(msg.CreatedAt) > h.recallWindow {
			Err(c, http.StatusConflict, "invalid_state", "超过 5 分钟不可撤回")
			return
		}
		// 事务:SoftDelete + 重算 conv 全员 unread_count 原子提交。
		// 撤回后该消息从未读计数剔除(对未读该消息的成员 -1),
		// 避免对方列表徽章永久偏高(Bug D)。
		tx, err := h.convRepo.BeginTx(c.Request.Context())
		if err != nil {
			ErrMsg(c, http.StatusInternalServerError, "撤回失败")
			return
		}
		defer tx.Rollback() // commit 后 noop
		if err := h.msgRepo.SoftDeleteTx(c.Request.Context(), tx, id); err != nil {
			ErrMsg(c, http.StatusInternalServerError, "撤回失败")
			return
		}
		if err := h.participantRepo.RecomputeUnreadForConvTx(c.Request.Context(), tx, msg.ConversationID); err != nil {
			ErrMsg(c, http.StatusInternalServerError, "撤回失败")
			return
		}
		if err := tx.Commit(); err != nil {
			ErrMsg(c, http.StatusInternalServerError, "撤回失败")
			return
		}
		// 撤回零成本:不再维护全局 last_message_content 缓存(spec §3),
		// 会话列表查询时子查询实时反映 hide / recall 的最新可见消息。
		hubMsg := h.buildDeleteMsg(c.Request.Context(), msg.ConversationID, []string{msg.ID}, "recall", msg.SenderID, msg.SenderType)
		h.hub.SendToConv(msg.ConversationID, hubMsg)

	case "hide", "":
		if err := h.msgRepo.HideForUser(c.Request.Context(), id, actorID, role); err != nil {
			ErrMsg(c, http.StatusInternalServerError, "删除失败")
			return
		}
		// hide 不需要重算(会话列表子查询按个人维度实时算)
		h.unicastHide(c.Request.Context(), actorID, role, msg.ConversationID, []string{id})

	default:
		Err(c, http.StatusBadRequest, "bad_request", "scope 参数非法,应为 hide|recall")
	}

	c.Status(http.StatusNoContent)
}

// UpdateContent PATCH /api/messages/:id  body: {"content": <json>}
//
// 更新自己发的消息 content(原地替换)。仅 sender 本人可操作。用于交互卡片状态变更:
// plugin 更新 permission_card / question_card 的 status 字段,触发 MESSAGE_UPDATE 广播
// 让 APP 重渲染卡片(pending → 终态)。
//
// 鉴权: msgAuth 组(user + agent 都可调)。
// 响应:
//   - 200 → {"ok": true}
//   - 400 → body 非法 / content 非 JSON object / content.msg_type 缺失
//   - 403 → 非 sender 本人(role + id 双校验)
//   - 404 → 消息不存在 / 已撤回
//
// content 必须含 msg_type 字段(防误传残缺卡片导致 APP 渲染异常)。
func (h *MessageHandler) UpdateContent(c *gin.Context) {
	id := c.Param("id")
	actorID := c.GetString("userID")
	role := c.GetString("role")

	var req struct {
		Content json.RawMessage `json:"content" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	// 校验 content 是 JSON object 且含 msg_type(卡片渲染必需字段)
	var check map[string]interface{}
	if err := json.Unmarshal(req.Content, &check); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", "content 必须是 JSON object")
		return
	}
	if _, ok := check["msg_type"]; !ok {
		Err(c, http.StatusBadRequest, "bad_request", "content.msg_type 必填")
		return
	}

	// 查原消息拿 conversation_id(用于 broadcast) + sender 做权限校验
	msg, err := h.msgRepo.Get(c.Request.Context(), id)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "查询消息失败")
		return
	}
	if msg == nil {
		Err(c, http.StatusNotFound, "not_found", "消息不存在")
		return
	}

	// 仅 sender 可更新(role + id 双校验,与 Delete recall 分支一致)
	if msg.SenderID != actorID || msg.SenderType != role {
		Err(c, http.StatusForbidden, "forbidden", "只能更新自己发的消息")
		return
	}

	// 保留原消息的 silent 字段:plugin 更新卡片 status 时 content 只带
	// {msg_type,data,status},若直接整体替换会抹掉创建时的 silent=true,
	// 导致 tool_card 等过程消息被后续未读重算误当"非 silent"计入(未读残留)。
	// 语义:silent 是创建时确定的元数据,PATCH 只应改 data/status,不该动 silent。
	// 新 content 显式带 silent 时以新值为准(尊重 caller 的显式意图)。
	req.Content = mergePreservedSilent(msg.Content, req.Content)

	// 更新(repo WHERE 带 sender_id 兜底防 IDOR,handler 校验与 SQL 校验双保险)
	if err := h.msgRepo.UpdateContent(c.Request.Context(), id, actorID, req.Content); err != nil {
		// Get 已确认存在,此处 ErrNoRows 说明 Get 与 UPDATE 之间被并发撤回 → 404
		if errors.Is(err, sql.ErrNoRows) {
			Err(c, http.StatusNotFound, "not_found", "消息不存在")
			return
		}
		ErrMsg(c, http.StatusInternalServerError, "更新消息失败")
		return
	}

	// 聚合卡回合结束:原消息 silent=true 且 PATCH 后 silent 翻转为 false 时,
	// 该消息从"不计数"翻转为"计数",应对非 sender 全员 +1 unread。
	// 与发消息时 IncrUnreadTx 的自增口径一致(silent=false 正常计数)。
	// mergePreservedSilent 保证:新 content 未显式带 silent 会保留原值,
	// 因此此处 merged silent=false 只可能来自新 content 显式传 false。
	// 计数放在 UpdateContent 成功之后:若更新失败(500 / 并发撤回 404),
	// content 仍为 silent=true,不发生"内容未翻转却 +1"的假未读;
	// silent 语义由 delivery 重算口径(content->>'silent' IS DISTINCT FROM 'true')
	// 兜底,故计数失败不影响最终展示。
	if origSilent, ok := contentSilent(msg.Content); ok && origSilent {
		if mergedSilent, ok := contentSilent(req.Content); ok && !mergedSilent {
			if err := h.participantRepo.IncrUnread(c.Request.Context(), msg.ConversationID, msg.SenderID, msg.SenderType); err != nil {
				ErrMsg(c, http.StatusInternalServerError, "更新消息失败")
				return
			}
		}
	}

	// 广播 MESSAGE_UPDATE 给会话全员(APP 据此重渲染卡片)
	h.hub.BroadcastMessageUpdate(msg.ConversationID, id, req.Content)

	Ok(c, gin.H{"ok": true})
}

// BatchDeleteRequest 批量删除请求体。
type BatchDeleteRequest struct {
	IDs []string `json:"ids" binding:"required"`
}

// BatchDelete 批量隐藏消息。POST /api/messages/batch-delete  body: {"ids":[...]}
//
// 仅支持 scope=hide(批量撤回歧义太大,本期不开)。
// 限制:单次最多 maxBatchDelete 条;所有消息必须属于同一会话(防跨会话越权)。
//
// 副作用:无(会话列表子查询按个人维度实时算)。单播 MESSAGE_DELETE 给当前请求者。
func (h *MessageHandler) BatchDelete(c *gin.Context) {
	var req BatchDeleteRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if len(req.IDs) == 0 {
		Err(c, http.StatusBadRequest, "bad_request", "ids 不能为空")
		return
	}
	if len(req.IDs) > h.maxBatchDelete {
		Err(c, http.StatusBadRequest, "bad_request", "单次最多删除 100 条")
		return
	}

	actorID := c.GetString("userID")
	role := c.GetString("role")

	msgs, err := h.msgRepo.GetByIDs(c.Request.Context(), req.IDs)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "查询消息失败")
		return
	}
	if len(msgs) == 0 {
		Err(c, http.StatusNotFound, "not_found", "消息不存在")
		return
	}

	// 所有消息必须同一会话(取第一条的 conversation_id 校验)
	convID := msgs[0].ConversationID
	for _, m := range msgs {
		if m.ConversationID != convID {
			Err(c, http.StatusBadRequest, "bad_request", "批量删除的消息必须属于同一会话")
			return
		}
	}

	if !h.canAccess(c.Request.Context(), convID, actorID, role) {
		Err(c, http.StatusForbidden, "forbidden", "无权操作该会话消息")
		return
	}

	n, err := h.msgRepo.HideForUsers(c.Request.Context(), req.IDs, actorID, role)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "删除失败")
		return
	}

	h.unicastHide(c.Request.Context(), actorID, role, convID, req.IDs)
	Ok(c, gin.H{"deleted": n})
}

// GetMessageContext GET /api/messages/:id/context?before=10&after=10
// 取 target 消息 + 前后 N 条上下文,用于客户端点击引用块后的跨页跳转渲染。
//
// 权限:user 必须是 target 所在 conv 的 participant(否则 403)。
// 404 场景:
//   - target_id 不存在(GetMessageContextTx 返 target=nil)
//   - target 已撤回(DeletedAt.Valid):撤回语义下跳转无意义
//   - target 被当前 user 隐藏(IsHidden):hide 是对自己不可见,
//     跳转应该 404 符合 hide 意图(别人 hide 不影响本判断)
//
// before/after 上限 50 防滥用,负数归零,默认 10。before/after 内部已过滤软删除消息
// (撤回消息不参与跳转上下文渲染,见 repo 注释),target 自身仍按 Get 语义不过滤
// deleted_at(此处 handler 显式判断 DeletedAt.Valid 返 404)。返回前对 target +
// before + after 全部调 SanitizeForClient(与 ConversationHandler.Messages 出口
// 处理一致,撤回消息 Content 改写为占位 {"msg_type":"recalled"})。
func (h *MessageHandler) GetMessageContext(c *gin.Context) {
	targetID := c.Param("id")
	actorID := c.GetString("userID")
	role := c.GetString("role")

	before, _ := strconv.Atoi(c.DefaultQuery("before", "10"))
	after, _ := strconv.Atoi(c.DefaultQuery("after", "10"))
	if before < 0 {
		before = 0
	}
	if before > 50 {
		before = 50
	}
	if after < 0 {
		after = 0
	}
	if after > 50 {
		after = 50
	}

	target, beforeMsgs, afterMsgs, err := h.msgRepo.GetMessageContextTx(c.Request.Context(), nil, targetID, before, after)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "GetMessageContext GetMessageContextTx 失败", "target_id", targetID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "查询失败")
		return
	}
	if target == nil {
		Err(c, http.StatusNotFound, "not_found", "消息不存在")
		return
	}
	// 撤回语义:跳转到已撤回消息无意义,返 404
	if target.DeletedAt.Valid {
		Err(c, http.StatusNotFound, "not_found", "消息不存在")
		return
	}
	// 隐藏语义:target 被当前 user hide 后对自己不可见,跳转应 404。
	// (用户长按「删除」选 scope=hide 写 message_hidden,
	// 通过引用块跳转拉回会违背 hide 意图,客户端收到 404 显示「原消息已删除」)
	hidden, err := h.msgRepo.IsHidden(c.Request.Context(), target.ID, actorID, role)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "GetMessageContext IsHidden 失败", "target_id", targetID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "查询失败")
		return
	}
	if hidden {
		Err(c, http.StatusNotFound, "not_found", "消息不存在")
		return
	}

	// participant 权限:用 canAccess(与 Delete/BatchDelete 一致)
	if !h.canAccess(c.Request.Context(), target.ConversationID, actorID, role) {
		Err(c, http.StatusForbidden, "forbidden", "无权操作该会话消息")
		return
	}

	// 出口处理:撤回消息 Content 改写为占位(虽然 before/after 已过滤软删,
	// target 也已 404 拦截,这里保留调用与 Messages handler 一致,防御性)
	target.SanitizeForClient()
	for i := range beforeMsgs {
		beforeMsgs[i].SanitizeForClient()
	}
	for i := range afterMsgs {
		afterMsgs[i].SanitizeForClient()
	}
	if beforeMsgs == nil {
		beforeMsgs = []model.Message{}
	}
	if afterMsgs == nil {
		afterMsgs = []model.Message{}
	}

	Ok(c, gin.H{
		"target": target,
		"before": beforeMsgs,
		"after":  afterMsgs,
	})
}

// canAccess 校验 actor 是否为该会话 participant。
// 会话/参与者不存在都返 false(防越权)。
func (h *MessageHandler) canAccess(ctx context.Context, convID, actorID, role string) bool {
	ok, err := h.participantRepo.Exists(ctx, convID, actorID, role)
	if err != nil {
		return false
	}
	return ok
}

// senderDisplay 查 sender 昵称:user 走 userRepo (nickname||username),agent 走 agentRepo (name)。
// 查询失败返空串(client 端会用 sender_id fallback 占位),不阻塞撤回流程。
func (h *MessageHandler) senderDisplay(ctx context.Context, senderID, senderType string) string {
	if senderType == "agent" {
		a, err := h.agentRepo.GetByID(ctx, senderID)
		if err != nil || a == nil {
			return ""
		}
		return a.Name
	}
	u, err := h.userRepo.GetByID(ctx, senderID)
	if err != nil || u == nil {
		return ""
	}
	if u.Nickname != nil && *u.Nickname != "" {
		return *u.Nickname
	}
	return u.Username
}

// unicastHide 把 hide scope 的 MESSAGE_DELETE 单播给当前请求者(只对我消失)。
// payload 不含 sender 信息(hide 不需要撤回占位文案)。
func (h *MessageHandler) unicastHide(ctx context.Context, memberID, memberType, convID string, ids []string) {
	hubMsg := h.buildDeleteMsg(ctx, convID, ids, "hide", "", "")
	h.hub.SendToMember(memberID, memberType, hubMsg)
}

// buildDeleteMsg 构造 MESSAGE_DELETE 广播 payload。
// scope=recall 时填 sender_id/sender_type/sender_name;scope=hide 时这三字段为空。
func (h *MessageHandler) buildDeleteMsg(ctx context.Context, convID string, ids []string, scope, senderID, senderType string) *model.WSMessage {
	payload := map[string]interface{}{
		"ids":             ids,
		"conversation_id": convID,
		"scope":           scope,
	}
	if scope == "recall" {
		payload["sender_id"] = senderID
		payload["sender_type"] = senderType
		payload["sender_name"] = h.senderDisplay(ctx, senderID, senderType)
	}
	data, _ := json.Marshal(payload)
	return &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageDelete,
		D:  data,
	}
}

// mergePreservedSilent 把原 content 的 silent 字段并入新 content(若新 content 未显式带)。
//
// 场景:plugin PATCH 卡片 status 时 content 只带 {msg_type,data,status},不含 silent。
// 直接整体替换会抹掉创建时的 silent=true(tool_card 等过程消息创建时 silent=true,
// server 据此跳过 IncrUnread;PATCH 后丢失会被未读重算误当"非 silent"计入 → 残留)。
//
// 规则:
//   - 新 content 显式带 silent → 用新值(caller 显式意图优先)
//   - 新 content 未带 silent 且原 content 有 → 并入原值(保留创建时元数据)
//   - 解析失败(非 object / 缺字段)→ 原样返回新 content(不破坏 PATCH 语义)
func mergePreservedSilent(origContent, newContent json.RawMessage) json.RawMessage {
	var orig map[string]json.RawMessage
	if err := json.Unmarshal(origContent, &orig); err != nil || orig == nil {
		return newContent
	}
	origSilent, hasOrigSilent := orig["silent"]
	if !hasOrigSilent {
		return newContent
	}

	var neu map[string]json.RawMessage
	if err := json.Unmarshal(newContent, &neu); err != nil || neu == nil {
		return newContent
	}
	if _, hasNewSilent := neu["silent"]; hasNewSilent {
		return newContent
	}

	neu["silent"] = origSilent
	merged, err := json.Marshal(neu)
	if err != nil {
		return newContent
	}
	return merged
}

// contentSilent 解析 content JSON 的 silent 字段值。
// 非 object / 无 silent 字段 / 解析失败 → (false, false),调用方据此跳过翻转判断。
// 与 mergePreservedSilent 共用解析口径(silent 是 content 顶层的 bool)。
func contentSilent(content json.RawMessage) (silent, ok bool) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(content, &m); err != nil || m == nil {
		return false, false
	}
	raw, has := m["silent"]
	if !has {
		return false, false
	}
	if err := json.Unmarshal(raw, &silent); err != nil {
		return false, false
	}
	return silent, true
}
