package model

// AgentTypeInfo agent type 注册表条目(server 统一下发的类型属性)。
// 拓扑属性 multi_session 决定 APP 路由;其余为展示属性(徽标文案/配色),
// 空串=APP 走默认配色。新 agent 类型只需注册表 INSERT 一行,APP 零发版。
type AgentTypeInfo struct {
	Type            string `json:"type"`
	MultiSession    bool   `json:"multi_session"`
	Label           string `json:"label"`
	BadgeBg         string `json:"badge_bg"`
	BadgeBgElevated string `json:"badge_bg_elevated"`
	BadgeFg         string `json:"badge_fg"`
}
