// 小程序云数据订阅频道表单测:订阅 fanout 路由 / 幂等 / 退订 / 断连清理 / deleted 帧。
// 复用 hub_test.go 的 newTestClient 与 dispatch_test.go 的 recvOne/recvNone,
// 不经 hub.Run 注册(SubscribeMp 是独立于 clients map 的平行索引)。
package hub

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/wanling/server/internal/model"
)

// mpChannelCount 返回当前频道表条目数(断连清理闭环断言用:
// client.Send 已被 Close,无法用 recvNone 判定,直接查内部表)。
func mpChannelCount(h *Hub) int {
	h.mpMu.Lock()
	defer h.mpMu.Unlock()
	return len(h.mpChannels)
}

// 用例 1:同频道两订阅者各收一帧 MP_DATA_UPDATE 且 d 字段齐全;
// 别的频道订阅者与未订阅者收不到。
func TestMpChannels_SubscribeFanout(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	sub1 := newTestClient("u1", "user")
	sub2 := newTestClient("u2", "user")
	otherChan := newTestClient("u3", "user")
	bystander := newTestClient("u4", "user")

	h.SubscribeMp(sub1, "app-1", []string{"board"})
	h.SubscribeMp(sub2, "app-1", []string{"board"})
	h.SubscribeMp(otherChan, "app-1", []string{"notes"})

	h.SendMpDataUpdate("app-1", "board", "k1", json.RawMessage(`{"n":1}`), false, 3, "op-w1")

	for _, c := range []*Client{sub1, sub2} {
		got := recvOne(t, c)
		if got.Op != model.OpDispatch {
			t.Fatalf("期望 op=%d(DISPATCH), 实际 %d", model.OpDispatch, got.Op)
		}
		if got.T != model.EventMpDataUpdate {
			t.Fatalf("期望 MP_DATA_UPDATE, 实际 %s", got.T)
		}
		if got.S == 0 {
			t.Fatal("seq 应已分配(>0)")
		}
		var p map[string]any
		if err := json.Unmarshal(got.D, &p); err != nil {
			t.Fatalf("unmarshal payload: %v", err)
		}
		if p["appid"] != "app-1" || p["coll"] != "board" || p["key"] != "k1" {
			t.Fatalf("appid/coll/key 不符: %v", p)
		}
		if p["deleted"] != false {
			t.Fatalf("deleted 应 false: %v", p["deleted"])
		}
		if v, _ := p["version"].(float64); int64(v) != 3 {
			t.Fatalf("version 应 3: %v", p["version"])
		}
		if p["writer_openid"] != "op-w1" {
			t.Fatalf("writer_openid 应 op-w1: %v", p["writer_openid"])
		}
		val, ok := p["value"].(map[string]any)
		if !ok {
			t.Fatalf("value 应为对象: %v", p["value"])
		}
		if v, _ := val["n"].(float64); v != 1 {
			t.Fatalf("value 应 {\"n\":1}: %v", p["value"])
		}
	}

	recvNone(t, otherChan, "别的频道订阅者")
	recvNone(t, bystander, "未订阅者")
}

// 用例 2:重复订阅同频道幂等合并,fanout 只投一帧。
func TestMpChannels_ReSubscribeIdempotent(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	c := newTestClient("u1", "user")
	h.SubscribeMp(c, "app-1", []string{"board"})
	h.SubscribeMp(c, "app-1", []string{"board"})

	h.SendMpDataUpdate("app-1", "board", "k1", json.RawMessage(`1`), false, 1, "op")

	recvOne(t, c)              // 恰一帧
	recvNone(t, c, "重复订阅后第二帧") // 不应有第二帧
}

// 用例 3:UnsubscribeMp 后不再收帧(OpMpUnsubscribe 帧语义)。
func TestMpChannels_UnsubscribeStopsDelivery(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	c := newTestClient("u1", "user")
	h.SubscribeMp(c, "app-1", []string{"board"})

	h.SendMpDataUpdate("app-1", "board", "k1", json.RawMessage(`1`), false, 1, "op")
	recvOne(t, c)

	h.UnsubscribeMp(c)
	h.SendMpDataUpdate("app-1", "board", "k2", json.RawMessage(`2`), false, 2, "op")
	recvNone(t, c, "退订后")
}

// 用例 4:hub.Run Unregister 路径(断连)全清订阅——驱动真实 Unregister channel,
// 断言频道表清空(断连清理闭环)。
func TestMpChannels_UnregisterCleansUp(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)
	go h.Run(context.Background())

	c := newTestClient("u1", "user")
	h.Register <- c
	time.Sleep(10 * time.Millisecond)

	h.SubscribeMp(c, "app-1", []string{"board", "notes"})
	if n := mpChannelCount(h); n != 2 {
		t.Fatalf("订阅后应有 2 个频道,实际 %d", n)
	}

	h.Unregister <- c
	time.Sleep(10 * time.Millisecond)

	if n := mpChannelCount(h); n != 0 {
		t.Fatalf("Unregister 后频道表应清空,剩 %d 个频道", n)
	}
}

// 用例 5:deleted=true 事件 value 序列化为 JSON null,其余字段齐全。
func TestMpChannels_DeletedEvent(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	c := newTestClient("u1", "user")
	h.SubscribeMp(c, "app-1", []string{"default"})

	h.SendMpDataUpdate("app-1", "default", "k1", nil, true, 5, "op-w2")

	got := recvOne(t, c)
	if got.T != model.EventMpDataUpdate {
		t.Fatalf("期望 MP_DATA_UPDATE, 实际 %s", got.T)
	}
	var p map[string]any
	if err := json.Unmarshal(got.D, &p); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}
	if p["deleted"] != true {
		t.Fatalf("deleted 应 true: %v", p["deleted"])
	}
	if p["value"] != nil {
		t.Fatalf("deleted 事件 value 应为 null: %v", p["value"])
	}
	if v, _ := p["version"].(float64); int64(v) != 5 {
		t.Fatalf("version 应 5: %v", p["version"])
	}
}
