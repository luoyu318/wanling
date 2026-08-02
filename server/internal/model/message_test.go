package model

import (
	"encoding/json"
	"testing"
)

func TestQuoteJSONMarshal(t *testing.T) {
	q := Quote{
		MessageID:  "msg_abc",
		SenderType: "user",
		SenderID:   "u_xyz",
		SenderName: "洛羽",
		MsgType:    "text",
		Preview:    "原文预览",
	}
	bytes, err := json.Marshal(q)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(bytes, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got["message_id"] != "msg_abc" {
		t.Fatalf("message_id wrong: %v", got["message_id"])
	}
	if got["sender_name"] != "洛羽" {
		t.Fatalf("sender_name wrong: %v", got["sender_name"])
	}
}

func TestQuoteJSONUnmarshal(t *testing.T) {
	raw := `{"message_id":"m1","sender_type":"agent","sender_id":"a1","sender_name":"小灵","msg_type":"text","preview":"hi"}`
	var q Quote
	if err := json.Unmarshal([]byte(raw), &q); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if q.SenderType != "agent" || q.SenderName != "小灵" {
		t.Fatalf("fields wrong: %+v", q)
	}
}
