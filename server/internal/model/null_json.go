package model

import (
	"bytes"
	"database/sql/driver"
	"encoding/json"
	"errors"
)

// nullLiteral 是 "null" 字面量的字节切片，避免在热路径上反复分配。
var nullLiteral = []byte("null")

// NullJSON 是一个可空 JSONB 包装类型，对应数据库中允许为 NULL 的 JSONB 列。
// 设计权衡：
//   - 直接用 json.RawMessage 时，sql 层 Scan NULL 会报错 "unsupported Scan, storing driver.Value type <nil>"。
//     原因是 json.RawMessage 的 Scan 实现只处理 []byte/string，对 NULL 直接抛错。
//   - 本类型实现 sql.Scanner + driver.Valuer，遇到 NULL 时保持空切片（nil）+ Valid=false。
//   - 嵌入 json.RawMessage 保留原有的 JSON 序列化行为（输出为 JSON 对象而非 base64 字符串）。
//
// JSON 契约：NULL 时输出 JSON null（字段总是出现在结果里）；非 NULL 时透传 JSON 内容。
// 注意：本类型实现了 MarshalJSON，结构体字段的 omitempty tag 对它是死代码（Go encoding/json
// 对实现了 MarshalJSON 的类型不评估 omitempty），因此使用 NullJSON 时不要加 omitempty。
//
// 用法：在 struct 里用 NullJSON 替代 json.RawMessage，例如 LastMessageContent。
// 业务代码访问时通过 .Raw 取出 json.RawMessage 进行解析。
type NullJSON struct {
	json.RawMessage
	// Valid 标记数据库值是否非 NULL。NULL 时 Valid=false，Raw 为 nil。
	Valid bool
}

// Scan 实现 sql.Scanner。支持 NULL（nil, []byte(nil)）和 []byte / string。
func (n *NullJSON) Scan(value interface{}) error {
	if value == nil {
		n.RawMessage = nil
		n.Valid = false
		return nil
	}
	switch v := value.(type) {
	case []byte:
		// pq 对 JSONB 列返回 []byte（已解码的 JSON 文本），直接拷贝避免底层缓冲复用问题
		cp := make([]byte, len(v))
		copy(cp, v)
		n.RawMessage = cp
		n.Valid = true
		return nil
	case string:
		// string 转 []byte 会触发新底层数组分配（string 不可变），无需手动 copy
		n.RawMessage = json.RawMessage(v)
		n.Valid = true
		return nil
	default:
		return errors.New("NullJSON.Scan: 不支持的类型")
	}
}

// Value 实现 driver.Valuer。Valid=false 表示 NULL，返回 nil。
// 注意：不把空 RawMessage（Valid=true 但 len=0）当 NULL，由调用方保证写入合法 JSON。
// 这样 Valid=true 即可区分"显式合法（含 {} 或 null 字面量）"与"NULL"两种语义。
func (n NullJSON) Value() (driver.Value, error) {
	if !n.Valid {
		return nil, nil
	}
	return []byte(n.RawMessage), nil
}

// MarshalJSON 让 NullJSON 在 JSON 输出时按内嵌 RawMessage 序列化。
// Valid=false 时输出 "null"；Valid=true 时透传 RawMessage 内容。
func (n NullJSON) MarshalJSON() ([]byte, error) {
	if !n.Valid {
		return []byte("null"), nil
	}
	return n.RawMessage.MarshalJSON()
}

// UnmarshalJSON 让 NullJSON 从 JSON 反序列化时直接吃下原始字节。
func (n *NullJSON) UnmarshalJSON(data []byte) error {
	if bytes.Equal(data, nullLiteral) {
		n.RawMessage = nil
		n.Valid = false
		return nil
	}
	n.RawMessage = append(n.RawMessage[:0], data...)
	n.Valid = true
	return nil
}
