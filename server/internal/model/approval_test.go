package model

import (
	"encoding/json"
	"testing"
)

func TestCardContentQuestionSerialization(t *testing.T) {
	cc := CardContent{
		ApprovalID: "a1", CardType: CardTypeQuestion, Title: "部署到哪个环境？",
		Options:     []ApprovalOption{{ID: "dev", Label: "测试"}, {ID: "staging", Label: "预发"}},
		MultiSelect: false, State: ApprovalStatePending,
	}
	raw, err := json.Marshal(cc)
	if err != nil {
		t.Fatal(err)
	}
	var back CardContent
	if err := json.Unmarshal(raw, &back); err != nil {
		t.Fatal(err)
	}
	if back.CardType != CardTypeQuestion || len(back.Options) != 2 || back.Options[0].ID != "dev" {
		t.Fatalf("roundtrip 丢失 question 字段: %+v", back)
	}
}
