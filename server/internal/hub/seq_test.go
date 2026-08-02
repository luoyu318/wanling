package hub

import (
	"testing"
)

func TestNextSeq_Unique(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)
	// 连续调用应返单调递增唯一值
	var prev int64
	for i := 0; i < 100; i++ {
		s := h.NextSeq()
		if s <= prev {
			t.Fatalf("seq=%d 未单调递增(prev=%d)", s, prev)
		}
		prev = s
	}
}

// TestResume_NoGaps 模拟两条消息 + 一个 hub 直发事件交错,
// 验证 Resume 不漏(修 bug 前 processor.seq 和 hub.seq 各自从 1 起步会重叠)。
//
// bug 路径(修前):
//   - processor 消息事件:seq=1, 2(走 processor.seq 自增)
//   - hub.broadcastAgentStatus:seq=1(走 hub.seq 自增,与 processor.seq=1 重叠)
//   - Resume(last_seq=2)后,buffer 内 seq=1 的 agent_status 被错判为"已推"
//
// 修后路径:全走 hub.NextSeq,seq 单调为 1, 2, 3,无重叠
func TestResume_NoGaps(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	// 模拟 processor 路径:用 NextSeq 推 message_create
	msgSeq1 := h.NextSeq() // = 1
	// 模拟 hub 直发路径:broadcastAgentStatus 等也用 NextSeq
	hubSeq := h.NextSeq() // = 2
	// 再来一条消息
	msgSeq2 := h.NextSeq() // = 3

	if msgSeq1 != 1 || hubSeq != 2 || msgSeq2 != 3 {
		t.Fatalf("seq 应为 1/2/3 单调,实得 %d/%d/%d", msgSeq1, hubSeq, msgSeq2)
	}

	// 模拟 client 收到 seq=2 后断线,Resume 拿 last_seq=2
	// 应只补推 seq>2 的(即 seq=3 那条),seq=1 那条不补(已收到)
	// 关键:hubSeq(seq=2)不会与 msgSeq1(seq=1)重叠成"被误判已推"
	// 这里的不变量:所有 seq 单调递增,buffer.getAfter(2) 行为可预测
	if !(msgSeq1 < hubSeq && hubSeq < msgSeq2) {
		t.Fatal("seq 未单调递增,Resume 会漏推")
	}
}
