package handler

import (
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/model"
)

// Messages 分页返回指定会话的历史消息。
// 支持三种分页方式(优先级:after > before > offset):
//   - offset 分页(旧):?limit=20&offset=0 — 向后兼容
//   - before 游标分页:?limit=20&before=<RFC3339> — 上滑加载历史(更老方向)
//   - after 游标分页:?limit=20&after=<RFC3339> — 定位第一条未读(更新方向)
//
// 越权防护:participantRepo.Exists 校验,非 participant 返 403(spec §6.1)。
// 过滤:软删(deleted_at) + 该 member 隐藏过的消息(message_hidden)。
func (h *ConversationHandler) Messages(c *gin.Context) {
	id := c.Param("id")
	userID := c.GetString("userID")
	// role 取值与 participant.member_type 对齐;旧测试 / 中间件未设 role 时按 "user" 兜底。
	memberType := c.GetString("role")
	if memberType == "" {
		memberType = "user"
	}

	ok, err := h.participantRepo.Exists(c.Request.Context(), id, userID, memberType)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "messages Exists 失败", "conv_id", id, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if !ok {
		Err(c, http.StatusForbidden, "forbidden", "not a participant")
		return
	}

	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))
	// limit 边界:防恶意 client 传 0/-1/负数/超大值拖垮 DB。
	if limit <= 0 || limit > 200 {
		limit = 50
	}

	// root_msg_id 分支(子 agent 详情页查子树):优先级最高。
	// ?root_msg_id=X 调 ListByRoot 返 root 下所有子事件(不含根本身),
	// 用于 APP 子 agent 详情页渲染 tool_card / reasoning 子树。
	// 主对话流(无 root_msg_id)继续走下面 before/after/offset 逻辑。
	if rootMsgID := c.Query("root_msg_id"); rootMsgID != "" {
		// UUID 格式校验:非法值会让 PG 报 invalid input syntax for type uuid → 500,
		// 此处 fail-fast 返 400(对称 after/before 参数的 RFC3339 校验)。
		if _, err := uuid.Parse(rootMsgID); err != nil {
			Err(c, http.StatusBadRequest, "bad_request", "root_msg_id 不是合法 UUID")
			return
		}
		msgs, err := h.messageRepo.ListByRoot(c.Request.Context(), id, rootMsgID, limit)
		if err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "messages ListByRoot 失败", "conv_id", id, "root_msg_id", rootMsgID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "查询失败")
			return
		}
		if msgs == nil {
			msgs = []model.Message{}
		}
		for i := range msgs {
			msgs[i].SanitizeForClient()
		}
		Ok(c, msgs)
		return
	}

	// after 游标分页(更新方向,定位第一条未读场景):优先级最高
	afterStr := c.Query("after")
	if afterStr != "" {
		after, err := time.Parse(time.RFC3339Nano, afterStr)
		if err != nil {
			Err(c, http.StatusBadRequest, "bad_request", "after 参数格式错误")
			return
		}
		msgs, err := h.messageRepo.ListAfter(c.Request.Context(), id, userID, memberType, after, limit)
		if err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "messages ListAfter 失败", "conv_id", id, "user_id", userID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "查询失败")
			return
		}
		if msgs == nil {
			msgs = []model.Message{}
		}
		for i := range msgs {
			msgs[i].SanitizeForClient()
		}
		Ok(c, msgs)
		return
	}

	beforeStr := c.Query("before")
	if beforeStr != "" {
		before, err := time.Parse(time.RFC3339Nano, beforeStr)
		if err != nil {
			Err(c, http.StatusBadRequest, "bad_request", "before 参数格式错误")
			return
		}
		msgs, err := h.messageRepo.ListBefore(c.Request.Context(), id, userID, memberType, before, limit)
		if err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "messages ListBefore 失败", "conv_id", id, "user_id", userID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "查询失败")
			return
		}
		if msgs == nil {
			msgs = []model.Message{}
		}
		for i := range msgs {
			msgs[i].SanitizeForClient()
		}
		Ok(c, msgs)
		return
	}

	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))
	msgs, err := h.messageRepo.ListByConversation(c.Request.Context(), id, userID, memberType, limit, offset)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "messages ListByConversation 失败", "conv_id", id, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "查询失败")
		return
	}
	if msgs == nil {
		msgs = []model.Message{}
	}
	for i := range msgs {
		msgs[i].SanitizeForClient()
	}
	Ok(c, msgs)
}
