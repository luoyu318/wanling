package model

// NavigationBarSpec 小程序导航栏声明(manifest.navigation_bar,可选)。
// Style=default(缺省)宿主原生 AppBar 承担返回+标题;custom 宿主隐藏 AppBar 全屏。
type NavigationBarSpec struct {
	Style           string `json:"style"`
	BackgroundColor string `json:"backgroundColor"`
	ForegroundColor string `json:"foregroundColor"`
}

// MiniprogramManifest 小程序包内 manifest.json 的服务端视图。
// 校验见 internal/miniprogram(sha256/entry 存在性),此处仅承载字段。
type MiniprogramManifest struct {
	Appid          string             `json:"appid"`
	Name           string             `json:"name"`
	Version        int                `json:"version"`
	Entry          string             `json:"entry"`
	Icon           string             `json:"icon"`
	Permissions    []string           `json:"permissions"`
	NavigationBar  *NavigationBarSpec `json:"navigationBar"`
	MinHostVersion string             `json:"minHostVersion"`
}

// MiniProgram 小程序注册记录(两层模型:private/published/disabled)。
type MiniProgram struct {
	ID            string
	Appid         string
	OwnerID       string
	Name          string
	Version       int
	ManifestJSON  []byte // JSONB 原文(lib/pq 直接 scan 为 []byte)
	PackageFileID string
	SHA256        string
	Size          int64
	Status        string
	Signature     string // 包签名 hex;空串=未签(DB NULL 中转)
}

// SigningKey 小程序包签名密钥对(server 单行表,私钥永不下发)。
type SigningKey struct {
	PrivateKey string // hex
	PublicKey  string // hex
}
