package handler

import (
	"database/sql"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/hub"
	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/repository"
)

// GroupHandler 处理群聊管理 API:邀请 / 踢人 / 退群 / 改群信息。
//
// 路由前缀 POST /api/conversations/:id/participants 等,挂在 userAuth 组(spec §4.1)。
//
// 权限模型(spec §6.2):
//   - 邀请:所有 role(包括 member)
//   - 踢人:owner / admin(且不能踢 owner)
//   - 退群:所有 role(包括 owner,owner 退群 → 销群)
//   - 改群名 / 头像:owner / admin
//
// 所有操作都先调 participantRepo.Exists/Get 校验 caller 是该会话 participant。
type GroupHandler struct {
	db              *sql.DB
	convRepo        *repository.ConversationRepo
	participantRepo *repository.ParticipantRepo
	hub             *hub.Hub
}

// NewGroupHandler 构造 GroupHandler。
func NewGroupHandler(
	db *sql.DB,
	convRepo *repository.ConversationRepo,
	participantRepo *repository.ParticipantRepo,
	hub *hub.Hub,
) *GroupHandler {
	return &GroupHandler{
		db:              db,
		convRepo:        convRepo,
		participantRepo: participantRepo,
		hub:             hub,
	}
}

// InviteMember POST /api/conversations/:id/participants body:{member_id, member_type}
// 权限:所有 participant 都可邀请(spec §6.2)。
// 广播 CONVERSATION_PARTICIPANT_JOIN 让该会话全员(含新成员)刷新。
func (h *GroupHandler) InviteMember(c *gin.Context) {
	userID := c.GetString("userID")
	convID := c.Param("id")

	var req struct {
		MemberID   string `json:"member_id" binding:"required"`
		MemberType string `json:"member_type" binding:"required,oneof=user agent"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	// 校验 caller 是 participant(spec §6.1)
	ok, err := h.participantRepo.Exists(c.Request.Context(), convID, userID, "user")
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "invite Exists caller 失败", "conv_id", convID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if !ok {
		Err(c, http.StatusForbidden, "forbidden", "not a participant")
		return
	}

	tx, err := h.db.BeginTx(c.Request.Context(), nil)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "invite Begin 失败", "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	// defer Rollback: Commit 成功后为 noop（sql.ErrTCDone），出错 return 时保证回滚
	defer tx.Rollback()

	if err := h.participantRepo.AddParticipantsTx(c.Request.Context(), tx, convID, []repository.ParticipantInput{
		{MemberID: req.MemberID, MemberType: req.MemberType, Role: "member"},
	}); err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "invite AddParticipantsTx 失败", "conv_id", convID, "member_id", req.MemberID, "member_type", req.MemberType, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "邀请失败")
		return
	}

	if err := tx.Commit(); err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "invite Commit 失败", "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	// 广播 JOIN(通知该会话全员,包括新成员)
	if h.hub != nil {
		h.hub.BroadcastParticipantJoin(convID, req.MemberID, req.MemberType, "member", userID)
	}
	Ok(c, nil)
}

// KickMember DELETE /api/conversations/:id/participants/:member_id
// 权限:owner / admin 才能踢,且不能踢 owner(spec §6.2)。
//
// target 可能是 user 或 agent,handler 用 type 优先级查(user → agent 兜底)。
// 路由路径里不带 member_type,客户端通过两个查询找到 target。
func (h *GroupHandler) KickMember(c *gin.Context) {
	userID := c.GetString("userID")
	convID := c.Param("id")
	targetID := c.Param("member_id")

	// 校验 caller 是 owner 或 admin
	caller, err := h.participantRepo.Get(c.Request.Context(), convID, userID, "user")
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "kick Get caller 失败", "conv_id", convID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if caller == nil {
		Err(c, http.StatusForbidden, "forbidden", "not a participant")
		return
	}
	if caller.Role != "owner" && caller.Role != "admin" {
		Err(c, http.StatusForbidden, "forbidden", "only owner/admin can kick")
		return
	}

	// 查 target 是不是 owner(不能踢 owner)。target type 未知,先 user 再 agent 兜底
	target, err := h.participantRepo.Get(c.Request.Context(), convID, targetID, "user")
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "kick Get target user 失败", "conv_id", convID, "target_id", targetID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if target == nil {
		target, err = h.participantRepo.Get(c.Request.Context(), convID, targetID, "agent")
		if err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "kick Get target agent 失败", "conv_id", convID, "target_id", targetID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "服务器错误")
			return
		}
	}
	if target == nil {
		Err(c, http.StatusNotFound, "not_found", "target not in conversation")
		return
	}
	if target.Role == "owner" {
		Err(c, http.StatusForbidden, "forbidden", "cannot kick owner")
		return
	}

	tx, err := h.db.BeginTx(c.Request.Context(), nil)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "kick Begin 失败", "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	// defer Rollback: Commit 成功后为 noop（sql.ErrTCDone），出错 return 时保证回滚
	defer tx.Rollback()

	if err := h.participantRepo.RemoveParticipantTx(c.Request.Context(), tx, convID, targetID, target.MemberType); err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "kick RemoveParticipantTx 失败", "conv_id", convID, "target_id", targetID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "踢人失败")
		return
	}

	if err := tx.Commit(); err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "kick Commit 失败", "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	if h.hub != nil {
		h.hub.BroadcastParticipantLeave(convID, targetID, target.MemberType, "kicked")
	}
	Ok(c, nil)
}

// Leave POST /api/conversations/:id/leave
// 权限:所有 role(包括 owner)。
// owner 退群 → 销群(级联删 participants + messages + deliveries);普通成员退群 → 只删自己 participant 行。
// 销群不广播 LEAVE(participants 已级联删,广播无人收);普通退群广播 LEAVE。
func (h *GroupHandler) Leave(c *gin.Context) {
	userID := c.GetString("userID")
	convID := c.Param("id")

	caller, err := h.participantRepo.Get(c.Request.Context(), convID, userID, "user")
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "leave Get caller 失败", "conv_id", convID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if caller == nil {
		Err(c, http.StatusNotFound, "not_found", "not a participant")
		return
	}

	tx, err := h.db.BeginTx(c.Request.Context(), nil)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "leave Begin 失败", "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	// defer Rollback: Commit 成功后为 noop（sql.ErrTCDone），出错 return 时保证回滚
	defer tx.Rollback()

	isOwner := caller.Role == "owner"
	if isOwner {
		// owner 退群 → 销群(conversations ON DELETE CASCADE 级联删 participants + messages + deliveries)
		if err := h.participantRepo.DestroyConversationTx(c.Request.Context(), tx, convID); err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "leave DestroyConversationTx 失败", "conv_id", convID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "销群失败")
			return
		}
	} else {
		// 普通成员退群:只删自己的 participant 行
		if err := h.participantRepo.RemoveParticipantTx(c.Request.Context(), tx, convID, userID, "user"); err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "leave RemoveParticipantTx 失败", "conv_id", convID, "user_id", userID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "退群失败")
			return
		}
	}

	if err := tx.Commit(); err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "leave Commit 失败", "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	// 销群时不广播(全员都已级联删),普通退群广播 LEAVE
	if !isOwner && h.hub != nil {
		h.hub.BroadcastParticipantLeave(convID, userID, "user", "left")
	}
	Ok(c, nil)
}

// Update PATCH /api/conversations/:id body:{title?, avatar_url?}
// 权限:owner / admin(spec §6.2)。
// 用 *string 字段区分「未提供」与「空串」,但 ConversationRepo.UpdateProfile 用 COALESCE(NULLIF)
// 模式空串 = 不动(不支持清空),与现有 AgentRepo.Update 一致。
func (h *GroupHandler) Update(c *gin.Context) {
	userID := c.GetString("userID")
	convID := c.Param("id")

	var req struct {
		Title     *string `json:"title"`
		AvatarURL *string `json:"avatar_url"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	caller, err := h.participantRepo.Get(c.Request.Context(), convID, userID, "user")
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-update Get caller 失败", "conv_id", convID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if caller == nil {
		Err(c, http.StatusForbidden, "forbidden", "not a participant")
		return
	}
	if caller.Role != "owner" && caller.Role != "admin" {
		Err(c, http.StatusForbidden, "forbidden", "only owner/admin can update")
		return
	}

	title := ""
	avatarURL := ""
	if req.Title != nil {
		title = *req.Title
	}
	if req.AvatarURL != nil {
		avatarURL = *req.AvatarURL
	}
	if err := h.convRepo.UpdateProfile(c.Request.Context(), convID, title, avatarURL); err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-update UpdateProfile 失败", "conv_id", convID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "更新失败")
		return
	}

	if h.hub != nil {
		h.hub.BroadcastConversationUpdate(convID, title, avatarURL)
	}
	Ok(c, nil)
}
