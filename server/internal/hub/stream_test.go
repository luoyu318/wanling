package hub

import (
	"encoding/json"
	"testing"

	"github.com/wanling/server/internal/model"
)

// TestSendStreamToConvViewers_ActiveConvFilter 验证 SendStreamToConvViewers 只推
// "正在看该会话"的 user 连接(activeConvID 过滤),agent participant 一律跳过。
// 同 user 多端场景:clientA 看 conv、clientB 看别的会话 → 只有 clientA 收到。
func TestSendStreamToConvViewers_ActiveConvFilter(t *testing.T) {
	h, convID, userID, agentID := seedHubParticipantDB(t)

	// user 连接 A:正在看 conv
	clientA := newTestClient(userID, "user")
	clientA.SetActiveConv(convID)
	h.RegisterClient(clientA)
	// user 连接 B:同 user 多端,正在看别的会话(不应收到)
	clientB := newTestClient(userID, "user")
	clientB.SetActiveConv("other-conv")
	h.RegisterClient(clientB)
	// agent 连接:不应收到流式
	agentClient := newTestClient(agentID, "agent")
	h.RegisterClient(agentClient)

	data, _ := json.Marshal(map[string]any{
		"conversation_id": convID,
		"stream_id":       "s-1",
		"msg_type":        "reasoning",
		"text":            "思考中",
	})
	h.SendStreamToConvViewers(convID, data)

	// clientA(看 conv)应收到 1 条 STREAM
	got := recvOne(t, clientA)
	if got.Op != model.OpStream {
		t.Fatalf("期望 op=%d, 实际 op=%d", model.OpStream, got.Op)
	}

	// clientB(看别的会话)不应收到
	recvNone(t, clientB, "clientB")
	// agent 不应收到流式
	recvNone(t, agentClient, "agent")
}
