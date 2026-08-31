package model

// MiniprogramManifest 小程序包内 manifest.json 的服务端视图。
// 校验见 internal/miniprogram(sha256/entry 存在性),此处仅承载字段。
type MiniprogramManifest struct {
	Appid          string   `json:"appid"`
	Name           string   `json:"name"`
	Version        int      `json:"version"`
	Entry          string   `json:"entry"`
	Icon           string   `json:"icon"`
	Permissions    []string `json:"permissions"`
	MinHostVersion string   `json:"minHostVersion"`
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
}
