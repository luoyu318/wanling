package handler

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/model"
)

// AbortGeneration POST /api/conversations/:id/abort (userAuth)
// user 点击停止生成按钮 → server 校验 participant → dispatch GENERATION_ABORT 给会话内的 agent(plugin)。
// plugin 收到后调 OpenCode SDK abort API 中止当前生成。
//
// 幂等:无生成在跑时 plugin 侧优雅忽略(OpenCode abort 对 idle session 无副作用)。
// agent 离线时仍返 200(请求已接收,agent 重连后不会补发;此时生成在 OC 侧继续跑,
// 用户可重新进入会话或等 OC 侧自然结束)。
//
// 越权 / 非 participant:返 403(与其他会话接口一致)。
func (h *ConversationHandler) AbortGeneration(c *gin.Context) {
	convID := c.Param("id")
	userID := c.GetString("userID")

	ok, err := h.participantRepo.Exists(c.Request.Context(), convID, userID, "user")
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "abort-generation Exists 失败",
			"conv_id", convID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if !ok {
		Err(c, http.StatusForbidden, "forbidden", "not a participant")
		return
	}

	// dispatch GENERATION_ABORT 给会话所有 participants(agent/plugin 会接收处理)。
	// 复用 SendToConv 遍历 participants 路由,user 端忽略此事件(无对应 UI)。
	if h.hub != nil {
		payload, _ := json.Marshal(map[string]string{
			"conversation_id": convID,
		})
		msg := &model.WSMessage{
			Op: model.OpDispatch,
			T:  model.EventGenerationAbort,
			S:  h.hub.NextSeq(),
			D:  payload,
		}
		h.hub.SendToConv(convID, msg)
	}

	Ok(c, nil)
}

// Pin 置顶会话(个人维度)。越权 / 非 participant → 403。
func (h *ConversationHandler) Pin(c *gin.Context) {
	if err := h.setPinnedFor(c, true); err != nil {
		return
	}
	Ok(c, nil)
}

// Unpin 取消置顶。越权 / 非 participant → 403。
func (h *ConversationHandler) Unpin(c *gin.Context) {
	if err := h.setPinnedFor(c, false); err != nil {
		return
	}
	Ok(c, nil)
}

// setPinnedFor 是 Pin/Unpin 共享实现。
// SetPinned/SetHidden 是 UPDATE 操作,空命中(非 participant)不返 sql.ErrNoRows,
// 故必须显式 Exists 校验(spec §6.1)。
func (h *ConversationHandler) setPinnedFor(c *gin.Context, pinned bool) error {
	convID := c.Param("id")
	userID := c.GetString("userID")

	ok, err := h.participantRepo.Exists(c.Request.Context(), convID, userID, "user")
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "set-pinned Exists 失败", "conv_id", convID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return err
	}
	if !ok {
		Err(c, http.StatusForbidden, "forbidden", "not a participant")
		return errors.New("forbidden")
	}

	if err := h.participantRepo.SetPinned(c.Request.Context(), convID, userID, "user", pinned); err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "set-pinned SetPinned 失败", "conv_id", convID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return err
	}
	return nil
}

// Hide 个人维度软删除会话(列表不显示,聊天记录保留,新消息自动恢复)。
// 越权 / 非 participant → 403。
func (h *ConversationHandler) Hide(c *gin.Context) {
	convID := c.Param("id")
	userID := c.GetString("userID")

	ok, err := h.participantRepo.Exists(c.Request.Context(), convID, userID, "user")
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "hide Exists 失败", "conv_id", convID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if !ok {
		Err(c, http.StatusForbidden, "forbidden", "not a participant")
		return
	}

	if err := h.participantRepo.SetHidden(c.Request.Context(), convID, userID, "user", true); err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "hide SetHidden 失败", "conv_id", convID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	Ok(c, nil)
}
