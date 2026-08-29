package handler

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
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

	// 聚合卡增量:content.data.op 存在 → 按 op 合并增量到原 content(DB 存全量,
	// 广播带增量);data 无 op → 全量替换(旧 plugin / 非聚合)。
	// 语义:silent 是创建时确定的元数据,全量替换 PATCH 只应改 data/status,不该动
	// silent;增量 op 合并进原 content 天然保留 silent(set_silent 显式覆盖)。
	delta := req.Content
	merged, isDelta, err := applyContentOp(msg.Content, req.Content)
	if err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	req.Content = merged

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
	// merged silent=false 只可能来自 caller 显式意图:全量替换显式带 silent=false,
	// 或增量 op set_silent 显式传 false(其余路径保留原值,不会误触发翻转)。
	// 计数放在 UpdateContent 成功之后:若更新失败(500 / 并发撤回 404),
	// content 仍为 silent=true,不发生"内容未翻转却 +1"的假未读;
	// silent 语义由 delivery 重算口径(content->>'silent' IS DISTINCT FROM 'true')
	// 兜底,故计数失败不影响最终展示。
	flipped := false
	if origSilent, ok := contentSilent(msg.Content); ok && origSilent {
		if mergedSilent, ok := contentSilent(req.Content); ok && !mergedSilent {
			flipped = true
			if err := h.participantRepo.IncrUnread(c.Request.Context(), msg.ConversationID, msg.SenderID, msg.SenderType); err != nil {
				ErrMsg(c, http.StatusInternalServerError, "更新消息失败")
				return
			}
		}
	}

	// 广播 MESSAGE_UPDATE 给会话全员(APP 据此重渲染卡片)。
	// 增量 op:广播原始增量结构(APP 应用增量);全量替换:广播合并后全量。
	// 聚合卡回合结束翻转(set_silent→false)时,merged 已写 data.preview
	// (applyContentOp 提取最后 markdown 正文),增量广播本身无 elements,
	// 需把 preview 注入广播 delta,让通知 body / 列表摘要直接可读。
	// 翻转广播还附带会话 type/title(对齐 MESSAGE_CREATE payload),bg-service
	// 据此识别 agent_session → 通知 title=会话标题(否则误走单聊 title=senderName)。
	broadcastContent := merged
	if isDelta {
		broadcastContent = injectAggregatePreview(delta, merged)
	}
	if flipped {
		var convType, convTitle string
		if conv, err := h.convRepo.GetByID(c.Request.Context(), msg.ConversationID); err == nil && conv != nil {
			convType, convTitle = conv.Type, conv.Title
		}
		h.hub.BroadcastMessageUpdateWithConvMeta(msg.ConversationID, id, broadcastContent, convType, convTitle)
	} else {
		h.hub.BroadcastMessageUpdate(msg.ConversationID, id, broadcastContent)
	}

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

// aggregateContentOp 聚合卡增量 op 参数(content.data 内的字段)。
//   - op: append | update | remove | reorder | set_state | set_silent | set_segment
//   - element: append 用,{type, element_id, data}
//   - element_id: update / remove 用
//   - data: update 用,整体替换目标元素 data
//   - order: reorder 用,element_id 数组
//   - state: set_state 用
//   - silent: set_silent 用
//   - segment: set_segment 用,分卡序列三态标记(first/middle/last)
type aggregateContentOp struct {
	Op        string                     `json:"op"`
	Element   map[string]json.RawMessage `json:"element"`
	ElementID string                     `json:"element_id"`
	Data      json.RawMessage            `json:"data"`
	Order     []string                   `json:"order"`
	State     string                     `json:"state"`
	Silent    *bool                      `json:"silent"`
	Segment   string                     `json:"segment"`
}

// applyContentOp 应用 PATCH content 到原消息 content,返回写库用全量 merged:
//
//   - data 无 op(或 data 非 object)→ 全量替换,保留原 silent(兼容旧 plugin / 非聚合卡)
//   - data 有 op → 聚合卡增量合并:在原 content 上应用 op,产出合并后全量
//
// 返回值:
//   - merged: 写库 content(增量路径为合并后全量;无 op 路径为 mergePreservedSilent 结果)
//   - isDelta: 是否为增量 op(为 true 时广播应带原始增量 reqContent 而非 merged)
//   - err: 增量 op 参数缺失 / 目标元素不存在 / 结构解析失败(400 语义)
//
// 增量 op 语义:
//   - append → elements 末尾追加 element
//   - update → 按 element_id 整体替换元素 data(元素不存在 → 报错)
//   - remove → 按 element_id 删除元素(不存在 → 幂等跳过,便于网络重试)
//   - reorder → 按 order 数组重排 elements(order 含未知 id → 报错;未列出的元素保序追加尾部)
//   - set_state → 改 data.state
//   - set_segment → 改 data.segment(分卡序列三态标记 first/middle/last)
//   - set_silent → 改顶层 content.silent(翻转 true→false 触达 IncrUnread 由调用方处理)
//
// 解析用 map[string]json.RawMessage 保留原 content 未知字段与未改动部分的原始字节。
func applyContentOp(origContent, reqContent json.RawMessage) (merged json.RawMessage, isDelta bool, err error) {
	// 解析入站增量:content.data 非 object / 无 op → 全量替换兼容路径
	var delta aggregateContentOp
	{
		var top map[string]json.RawMessage
		if e := json.Unmarshal(reqContent, &top); e != nil || top == nil {
			return mergePreservedSilent(origContent, reqContent), false, nil
		}
		rawData, hasData := top["data"]
		if !hasData {
			return mergePreservedSilent(origContent, reqContent), false, nil
		}
		var dataHead struct {
			Op string `json:"op"`
		}
		if e := json.Unmarshal(rawData, &dataHead); e != nil || dataHead.Op == "" {
			return mergePreservedSilent(origContent, reqContent), false, nil
		}
		if e := json.Unmarshal(rawData, &delta); e != nil {
			return nil, false, fmt.Errorf("解析 data.op 失败: %w", e)
		}
	}

	// 解析原 content 为可修改 map(保留未知字段与原始字节)
	var orig map[string]json.RawMessage
	if e := json.Unmarshal(origContent, &orig); e != nil || orig == nil {
		return nil, true, errors.New("原消息 content 解析失败")
	}

	var data map[string]json.RawMessage
	if rawData, has := orig["data"]; has {
		_ = json.Unmarshal(rawData, &data)
	}
	if data == nil {
		data = map[string]json.RawMessage{}
	}

	switch delta.Op {
	case "append":
		if delta.Element == nil {
			return nil, true, errors.New("append 需要 element")
		}
		elems, e := contentElements(data)
		if e != nil {
			return nil, true, e
		}
		elems = append(elems, delta.Element)
		if e := setContentElements(data, elems); e != nil {
			return nil, true, e
		}
	case "update":
		if delta.ElementID == "" {
			return nil, true, errors.New("update 需要 element_id")
		}
		if len(delta.Data) == 0 {
			return nil, true, errors.New("update 需要 data")
		}
		elems, e := contentElements(data)
		if e != nil {
			return nil, true, e
		}
		found := false
		for i := range elems {
			if elementID(elems[i]) == delta.ElementID {
				elems[i]["data"] = delta.Data
				found = true
				break
			}
		}
		if !found {
			return nil, true, fmt.Errorf("update: 元素 %s 不存在", delta.ElementID)
		}
		if e := setContentElements(data, elems); e != nil {
			return nil, true, e
		}
	case "remove":
		if delta.ElementID == "" {
			return nil, true, errors.New("remove 需要 element_id")
		}
		elems, e := contentElements(data)
		if e != nil {
			return nil, true, e
		}
		kept := make([]map[string]json.RawMessage, 0, len(elems))
		for _, el := range elems {
			if elementID(el) != delta.ElementID {
				kept = append(kept, el)
			}
		}
		if e := setContentElements(data, kept); e != nil {
			return nil, true, e
		}
	case "reorder":
		if len(delta.Order) == 0 {
			return nil, true, errors.New("reorder 需要 order 数组")
		}
		elems, e := contentElements(data)
		if e != nil {
			return nil, true, e
		}
		byID := make(map[string]map[string]json.RawMessage, len(elems))
		for _, el := range elems {
			byID[elementID(el)] = el
		}
		seen := make(map[string]bool, len(delta.Order))
		ordered := make([]map[string]json.RawMessage, 0, len(elems))
		for _, id := range delta.Order {
			el, ok := byID[id]
			if !ok {
				return nil, true, fmt.Errorf("reorder: order 中元素 %s 不存在", id)
			}
			if seen[id] {
				continue // order 重复 id 幂等跳过
			}
			seen[id] = true
			ordered = append(ordered, el)
		}
		// 未在 order 中列出的元素保序追加尾部(不丢数据)
		for _, el := range elems {
			if !seen[elementID(el)] {
				ordered = append(ordered, el)
			}
		}
		if e := setContentElements(data, ordered); e != nil {
			return nil, true, e
		}
	case "set_state":
		if delta.State == "" {
			return nil, true, errors.New("set_state 需要 state")
		}
		rawState, e := json.Marshal(delta.State)
		if e != nil {
			return nil, true, e
		}
		data["state"] = rawState
	case "set_segment":
		if delta.Segment == "" {
			return nil, true, errors.New("set_segment 需要 segment")
		}
		if delta.Segment != "first" && delta.Segment != "middle" && delta.Segment != "last" {
			return nil, true, fmt.Errorf("set_segment 非法值: %s", delta.Segment)
		}
		rawSegment, e := json.Marshal(delta.Segment)
		if e != nil {
			return nil, true, e
		}
		data["segment"] = rawSegment
	case "set_silent":
		if delta.Silent == nil {
			return nil, true, errors.New("set_silent 需要 silent")
		}
		rawSilent, e := json.Marshal(*delta.Silent)
		if e != nil {
			return nil, true, e
		}
		orig["silent"] = rawSilent
		// 回合结束翻转(silent→false):写 data.preview。增量广播无 elements,
		// 通知 body / 会话列表摘要直接读 preview(单一真相源在 server 落库 merged,
		// 广播 delta 由调用方注入)。预览取交互感知文案:仍待用户介入的
		// permission_card / question_card 优先(提示"需要处理"),否则最后 markdown 正文。
		if !*delta.Silent {
			if p, err := aggregatePreviewText(data); err == nil && p != "" {
				rawPreview, merr := json.Marshal(p)
				if merr != nil {
					return nil, true, merr
				}
				data["preview"] = rawPreview
			}
		}
	default:
		return nil, true, fmt.Errorf("未知 op: %s", delta.Op)
	}

	rawData, e := json.Marshal(data)
	if e != nil {
		return nil, true, e
	}
	orig["data"] = rawData
	merged, e = json.Marshal(orig)
	if e != nil {
		return nil, true, e
	}
	return merged, true, nil
}

// contentElements 取聚合卡 data.elements 数组(缺失 → 空数组)。
func contentElements(data map[string]json.RawMessage) ([]map[string]json.RawMessage, error) {
	raw, has := data["elements"]
	if !has {
		return nil, nil
	}
	var elems []map[string]json.RawMessage
	if err := json.Unmarshal(raw, &elems); err != nil {
		return nil, fmt.Errorf("解析 data.elements 失败: %w", err)
	}
	return elems, nil
}

// lastMarkdownText 取聚合卡 elements 中最后一个 markdown 元素的 text(用于
// 回合结束翻转时写 data.preview)。与 APP _aggregateCardPreview 同口径:
// 倒序遍历找最后一个 type=markdown 元素;无则返回空串。
func lastMarkdownText(data map[string]json.RawMessage) (string, error) {
	elems, err := contentElements(data)
	if err != nil {
		return "", err
	}
	for i := len(elems) - 1; i >= 0; i-- {
		raw, err := json.Marshal(elems[i])
		if err != nil {
			continue
		}
		var elem struct {
			Type string                     `json:"type"`
			Data map[string]json.RawMessage `json:"data"`
		}
		if err := json.Unmarshal(raw, &elem); err != nil {
			continue
		}
		if elem.Type != "markdown" {
			continue
		}
		var text string
		if err := json.Unmarshal(elem.Data["text"], &text); err != nil {
			continue
		}
		if text == "" {
			continue
		}
		return text, nil
	}
	return "", nil
}

// 聚合卡预览交互文案(纯文字:系统通知 / 会话摘要用系统字体渲染,
// iconfont 自定义字形会豆腐块,故不嵌入字形,卡片内图标由 APP 渲染层提供)。
const (
	permissionPreviewText = "权限审批"
	questionPreviewText   = "选择题"
)

// aggregatePreviewText 聚合卡 silent 翻转(false)时的预览正文(通知 body /
// agent_session 摘要单一真相源)。优先级:
//  1. 仍待用户介入的交互元素(permission_card / question_card 且 status 非终态)
//     → 返回交互类型文案,提示"需要处理"而非正文文本;
//  2. 否则最后 markdown 正文(正常回复摘要,复用 lastMarkdownText)。
//
// 与 APP MsgTypeX.preview 的聚合卡预览同口径(server 落库 merged 为权威,
// 广播 delta 由 injectAggregatePreview 注入)。
func aggregatePreviewText(data map[string]json.RawMessage) (string, error) {
	elems, err := contentElements(data)
	if err != nil {
		return "", err
	}
	// 1. pending 交互元素:倒序取最新一个(任何位置都优先于 markdown,需要用户行动)。
	for i := len(elems) - 1; i >= 0; i-- {
		raw, err := json.Marshal(elems[i])
		if err != nil {
			continue
		}
		var elem struct {
			Type string                     `json:"type"`
			Data map[string]json.RawMessage `json:"data"`
		}
		if err := json.Unmarshal(raw, &elem); err != nil {
			continue
		}
		switch elem.Type {
		case "permission_card":
			if isPendingInteraction(elem.Data) {
				return permissionPreviewText, nil
			}
		case "question_card":
			if isPendingInteraction(elem.Data) {
				return questionPreviewText, nil
			}
		}
	}
	return lastMarkdownText(data)
}

// isPendingInteraction 聚合卡交互元素是否仍需用户介入:
// data.status 缺失或为 "pending" → pending(建卡默认);终态
// (approved/denied/answered/rejected/expired)不算。与 plugin 建元素
// status:"pending"、反向流切终态对齐。
func isPendingInteraction(data map[string]json.RawMessage) bool {
	var status string
	if err := json.Unmarshal(data["status"], &status); err != nil {
		return true // status 缺失 → 视为 pending
	}
	return status == "" || status == "pending"
}

// injectAggregatePreview 把 merged(合并后全量)的 data.preview 注入广播 delta 的
// data.preview。聚合卡回合结束翻转时,增量广播无 elements,通知/摘要直接读
// preview。merged 无 preview(非翻转 / 无 markdown)→ 原样返回 delta。
func injectAggregatePreview(delta, merged json.RawMessage) json.RawMessage {
	var mm map[string]json.RawMessage
	if err := json.Unmarshal(merged, &mm); err != nil {
		return delta
	}
	var mdata map[string]json.RawMessage
	if raw, ok := mm["data"]; ok {
		_ = json.Unmarshal(raw, &mdata)
	}
	preview, has := mdata["preview"]
	if !has {
		return delta
	}

	var dtop map[string]json.RawMessage
	if err := json.Unmarshal(delta, &dtop); err != nil {
		return delta
	}
	var ddata map[string]json.RawMessage
	if raw, ok := dtop["data"]; ok {
		_ = json.Unmarshal(raw, &ddata)
	}
	if ddata == nil {
		ddata = map[string]json.RawMessage{}
	}
	ddata["preview"] = preview
	rawData, err := json.Marshal(ddata)
	if err != nil {
		return delta
	}
	dtop["data"] = rawData
	out, err := json.Marshal(dtop)
	if err != nil {
		return delta
	}
	return out
}

// setContentElements 回写聚合卡 data.elements。
func setContentElements(data map[string]json.RawMessage, elems []map[string]json.RawMessage) error {
	raw, err := json.Marshal(elems)
	if err != nil {
		return err
	}
	data["elements"] = raw
	return nil
}

// elementID 取元素 element_id(缺失 / 解析失败 → 空串)。
func elementID(elem map[string]json.RawMessage) string {
	var id string
	_ = json.Unmarshal(elem["element_id"], &id)
	return id
}
