package model

import (
	"encoding/json"
	"time"
)

// CardType 审批卡片类型。
type CardType string

const (
	CardTypeCommand      CardType = "command"
	CardTypeTool         CardType = "tool"
	CardTypeFile         CardType = "file"
	CardTypeSlashConfirm CardType = "slash_confirm"
	CardTypeQuestion     CardType = "question"
)

// ApprovalState 审批状态机：pending → approved/denied/expired（终态不可逆）。
type ApprovalState string

const (
	ApprovalStatePending  ApprovalState = "pending"
	ApprovalStateApproved ApprovalState = "approved"
	ApprovalStateDenied   ApprovalState = "denied"
	ApprovalStateExpired  ApprovalState = "expired"
)

// IsTerminal 终态判断（不可再推进）。
func (s ApprovalState) IsTerminal() bool {
	return s == ApprovalStateApproved || s == ApprovalStateDenied || s == ApprovalStateExpired
}

// ApprovalAction 卡片按钮定义。actions JSONB 反序列化用。
type ApprovalAction struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Icon  string `json:"icon"`  // check / shield / x
	Style string `json:"style"` // primary / info / danger
}

// ApprovalOption question 类型的选项定义。
type ApprovalOption struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}

// Approval 审批记录。
//
// participants 模型(migration 021):
//   - InitiatorType/InitiatorID: 卡片发起方(当前固定 agent,未来群聊可扩展为 user)
//   - DeciderType/DeciderID:     实际决策方(可空;pending 时为 NULL,MarkDecided 后回填)
//     兼容老 schema 决策人记录在 decided_by(保留 *string 不变,服务「卡片显示决策人 ID」语义)
type Approval struct {
	ID             string  `json:"id" db:"id"`
	MessageID      string  `json:"message_id" db:"message_id"`
	ConversationID string  `json:"conversation_id" db:"conversation_id"`
	InitiatorType  string  `json:"initiator_type" db:"initiator_type"`
	InitiatorID    string  `json:"initiator_id" db:"initiator_id"`
	DeciderType    *string `json:"decider_type,omitempty" db:"decider_type"`
	DeciderID      *string `json:"decider_id,omitempty" db:"decider_id"`

	CardType      CardType         `json:"card_type" db:"card_type"`
	State         ApprovalState    `json:"state" db:"state"`
	Actions       []ApprovalAction `json:"actions" db:"actions"`
	DecidedAction *string          `json:"decided_action,omitempty" db:"decided_action"`
	DecidedBy     *string          `json:"decided_by,omitempty" db:"decided_by"`
	DecidedReason *string          `json:"decided_reason,omitempty" db:"decided_reason"`
	DecidedAt     *time.Time       `json:"decided_at,omitempty" db:"decided_at"`

	ExpiresAt    time.Time `json:"expires_at" db:"expires_at"`
	SessionKey   string    `json:"session_key" db:"session_key"`
	AllowPattern *string   `json:"allow_pattern,omitempty" db:"allow_pattern"`

	// DecidedAnswers 仅 question 类型用：多选决策的 option id 列表。
	// 单选卡沿用 DecidedAction（"answered"/"rejected"）。
	DecidedAnswers []string `json:"decided_answers,omitempty" db:"decided_answers"`

	// ConfirmID 仅 slash_confirm 类型用。hermes tools/slash_confirm.resolve
	// 需要 (session_key, confirm_id, choice) 三元组定位 pending confirm。
	// exec_approval（command/tool/file）不用此字段，保持 NULL。
	ConfirmID *string `json:"confirm_id,omitempty" db:"confirm_id"`

	CreatedAt time.Time `json:"created_at" db:"created_at"`
}

// CardContent messages.content.data 部分的 Go 镜像，用于双写。
// 字段对应 spec 4.2 节 schema。
type CardContent struct {
	ApprovalID    string           `json:"approval_id"`
	CardType      CardType         `json:"card_type"`
	Title         string           `json:"title"`
	Preview       string           `json:"preview,omitempty"`
	PreviewLang   string           `json:"preview_language,omitempty"`
	ToolName      string           `json:"tool_name,omitempty"`
	File          *FileRef         `json:"file,omitempty"`
	Meta          []CardMeta       `json:"meta,omitempty"`
	Actions       []ApprovalAction `json:"actions"`
	State         ApprovalState    `json:"state"`
	DecidedAction *string          `json:"decided_action,omitempty"`
	DecidedReason *string          `json:"decided_reason,omitempty"`
	DecidedBy     *string          `json:"decided_by,omitempty"`
	DecidedAt     *time.Time       `json:"decided_at,omitempty"`
	ExpiresAt     time.Time        `json:"expires_at"`
	// question 类型字段：选项列表 + 是否多选 + 决策结果。
	Options     []ApprovalOption `json:"options,omitempty"`
	MultiSelect bool             `json:"multi_select,omitempty"`
	Answers     []string         `json:"answers,omitempty"`
	// ConfirmID 仅 slash_confirm 类型用（双写到 content，APP 不直接消费）。
	ConfirmID *string `json:"confirm_id,omitempty"`
}

// CardMeta 卡片元信息行（如 📁 工作目录 / ⚠ 风险提示）。
type CardMeta struct {
	Icon string `json:"icon"`
	Text string `json:"text"`
	Warn bool   `json:"warn,omitempty"`
}

// FileRef 文件引用（卡片 file 类型用）。
// 注意：与 message.go 的 FileRefData 区分 ——
// FileRefData 仅含 file_id（用于 image/mixed 消息引用 files 表），
// FileRef 额外带 name/size，供卡片预览直接展示，避免再查表。
type FileRef struct {
	Name   string `json:"name"`
	Size   int64  `json:"size"`
	FileID string `json:"file_id,omitempty"`
}

// MarshalActions 把 []ApprovalAction 序列化为 json.RawMessage（供 DB 写入）。
func MarshalActions(actions []ApprovalAction) (json.RawMessage, error) {
	return json.Marshal(actions)
}

// UnmarshalActions 反序列化 DB 读出的 actions JSONB。
func UnmarshalActions(raw json.RawMessage) ([]ApprovalAction, error) {
	var a []ApprovalAction
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, err
	}
	return a, nil
}
