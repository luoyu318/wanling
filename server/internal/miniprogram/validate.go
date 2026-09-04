// Package miniprogram 小程序 zip 包的结构校验(纯函数,无 IO 依赖)。
// fail fast:任一规则不满足即返回错误,调用方 handler 直接 400。
package miniprogram

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"path"
	"regexp"
	"strings"

	"github.com/wanling/server/internal/model"
)

// 档位常量(handler/fanout 共用)。
const (
	CollectionModePrivate     = "private"
	CollectionModeSharedRead  = "shared_read"
	CollectionModeSharedWrite = "shared_write"
)

// allowedPermissions manifest.permissions 允许集(M2 起含 chat 类,M2.5 起 nav 跳转,云数据起含 storage)。
var allowedPermissions = map[string]struct{}{
	"wanling.api":        {},
	"wanling.chat.read":  {},
	"wanling.chat.share": {},
	"wanling.nav":        {},
	"wanling.storage":    {},
}

var collectionNameRe = regexp.MustCompile(`^[a-z0-9_-]{1,32}$`)
var allowedCollectionModes = map[string]struct{}{
	CollectionModePrivate: {}, CollectionModeSharedRead: {}, CollectionModeSharedWrite: {},
}

const maxFiles = 2000

// icon 允许的扩展名与大小上限(manifest.icon 语义:包内相对路径,可空)。
var iconExts = map[string]struct{}{".png": {}, ".jpg": {}, ".jpeg": {}, ".webp": {}}

const maxIconBytes = 256 << 10

// SniffImageCT 按魔数嗅探图片 Content-Type;非图片返回空串。
func SniffImageCT(b []byte) string {
	switch {
	case len(b) >= 8 && bytes.Equal(b[:8], []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}):
		return "image/png"
	case len(b) >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF:
		return "image/jpeg"
	case len(b) >= 12 && bytes.Equal(b[:4], []byte("RIFF")) && bytes.Equal(b[8:12], []byte("WEBP")):
		return "image/webp"
	}
	return ""
}

var appidRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{2,31}$`)

// colorRe navigationBar 颜色格式(#RRGGBB)。
var colorRe = regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)

// validateNavigationBar 校验 manifest.navigationBar(可选声明,fail fast):
// style ∈ {default,custom}、颜色 #RRGGBB;缺省 style 视为 default。
func validateNavigationBar(nb *model.NavigationBarSpec) error {
	if nb == nil {
		return nil
	}
	switch nb.Style {
	case "", "default", "custom":
	default:
		return fmt.Errorf("navigation_bar.style 需为 default/custom, got %q", nb.Style)
	}
	for field, v := range map[string]string{"backgroundColor": nb.BackgroundColor, "foregroundColor": nb.ForegroundColor} {
		if v != "" && !colorRe.MatchString(v) {
			return fmt.Errorf("navigation_bar.%s 需为 #RRGGBB, got %q", field, v)
		}
	}
	return nil
}

// ValidatePackage 校验小程序 zip 包,返回解析后的 manifest 与包内 icon 字节。
// 校验项:压缩/解压后总大小上限、manifest.json 根目录存在、必填字段、appid 格式、
// version>0、entry 存在于包内、permissions 白名单、条目名无路径穿越、文件数上限、
// manifest.icon(可选)路径存在/扩展名白名单/≤256KB/魔数为图片。
func ValidatePackage(zipBytes []byte, maxBytes int64) (*model.MiniprogramManifest, []byte, error) {
	if maxBytes <= 0 {
		return nil, nil, fmt.Errorf("maxBytes 需为正数, got %d", maxBytes)
	}
	if int64(len(zipBytes)) > maxBytes {
		return nil, nil, fmt.Errorf("包大小 %d 超上限 %d", len(zipBytes), maxBytes)
	}
	zr, err := zip.NewReader(bytes.NewReader(zipBytes), int64(len(zipBytes)))
	if err != nil {
		return nil, nil, fmt.Errorf("非法 zip: %w", err)
	}
	if len(zr.File) > maxFiles {
		return nil, nil, fmt.Errorf("文件数 %d 超上限 %d", len(zr.File), maxFiles)
	}

	// 第一遍:逐条目做路径穿越校验,累计解压后总大小,同时提取根目录 manifest.json 内容。
	// 全程 uint64 域累加,防恶意声明超大尺寸转 int64 变负绕过检查。
	var manifestRaw []byte
	var totalUncompressed uint64
	limit := uint64(maxBytes)
	for _, f := range zr.File {
		name := f.Name
		// 统一分隔符后做穿越校验(拒绝 ../、绝对路径、盘符)
		clean := path.Clean(strings.ReplaceAll(name, "\\", "/"))
		if strings.HasPrefix(clean, "../") || clean == ".." || strings.HasPrefix(name, "/") || strings.Contains(name, "\\") {
			return nil, nil, fmt.Errorf("非法包内路径: %s", name)
		}
		// 饱和加:单帧超上限或累加会越过上限 → 直接判超上限(fail fast)。
		// 防 uint64 回绕:恶意条目声明超大尺寸时,`totalUncompressed +=` 溢出回绕
		// 变小值绕过检查,饱和加保证任一帧越界即拒。
		if f.UncompressedSize64 > limit || totalUncompressed > limit-f.UncompressedSize64 {
			return nil, nil, fmt.Errorf("解压后总大小超上限 %d", maxBytes)
		}
		totalUncompressed += f.UncompressedSize64
		// clean 后不等于 "manifest.json" 的(如 sub/manifest.json)不会被误认
		if clean == "manifest.json" {
			if f.UncompressedSize64 > 1<<20 {
				return nil, nil, fmt.Errorf("manifest.json 过大")
			}
			rc, err := f.Open()
			if err != nil {
				return nil, nil, fmt.Errorf("读 manifest.json: %w", err)
			}
			manifestRaw, err = io.ReadAll(rc)
			rc.Close()
			if err != nil {
				return nil, nil, fmt.Errorf("读 manifest.json: %w", err)
			}
		}
	}
	if manifestRaw == nil {
		return nil, nil, fmt.Errorf("缺少 manifest.json")
	}

	var m model.MiniprogramManifest
	if err := json.Unmarshal(manifestRaw, &m); err != nil {
		return nil, nil, fmt.Errorf("manifest.json 非法: %w", err)
	}
	if !appidRe.MatchString(m.Appid) {
		return nil, nil, fmt.Errorf("appid 需匹配 ^[a-z0-9][a-z0-9-]{2,31}$")
	}
	if m.Name == "" {
		return nil, nil, fmt.Errorf("name 必填")
	}
	if m.Version <= 0 {
		return nil, nil, fmt.Errorf("version 需为正整数")
	}
	if m.Entry == "" {
		m.Entry = "index.html"
	}
	for _, p := range m.Permissions {
		if _, ok := allowedPermissions[p]; !ok {
			return nil, nil, fmt.Errorf("未知 permission: %s", p)
		}
	}
	seenColl := map[string]struct{}{}
	if len(m.Collections) > 16 {
		return nil, nil, fmt.Errorf("collections 数量超上限(16)")
	}
	for _, c := range m.Collections {
		if !collectionNameRe.MatchString(c.Name) {
			return nil, nil, fmt.Errorf("collection name 非法: %q(须 ^[a-z0-9_-]{1,32}$)", c.Name)
		}
		if c.Name == "default" {
			return nil, nil, fmt.Errorf("collection name 保留: default")
		}
		if _, ok := allowedCollectionModes[c.Mode]; !ok {
			return nil, nil, fmt.Errorf("collection mode 非法: %q(须 private/shared_read/shared_write)", c.Mode)
		}
		if _, dup := seenColl[c.Name]; dup {
			return nil, nil, fmt.Errorf("collection 重名: %s", c.Name)
		}
		seenColl[c.Name] = struct{}{}
	}
	if err := validateNavigationBar(m.NavigationBar); err != nil {
		return nil, nil, err
	}
	// icon 元校验:声明了就必须是白名单扩展名(真实存在性/内容/大小在第二遍提取时查)。
	if m.Icon != "" {
		if _, ok := iconExts[strings.ToLower(path.Ext(m.Icon))]; !ok {
			return nil, nil, fmt.Errorf("icon 扩展名需为 png/jpg/jpeg/webp, got %q", m.Icon)
		}
	}

	// 第二遍:entry 存在性 + icon 提取(manifest 解析前 entry/icon 未知,与第一遍合并不了)。
	entryInZip := false
	var iconBytes []byte
	for _, f := range zr.File {
		clean := path.Clean(strings.ReplaceAll(f.Name, "\\", "/"))
		if clean == path.Clean(m.Entry) {
			entryInZip = true
		}
		if m.Icon != "" && clean == path.Clean(m.Icon) {
			if f.UncompressedSize64 > maxIconBytes {
				return nil, nil, fmt.Errorf("icon %d 超上限 %d 字节", f.UncompressedSize64, maxIconBytes)
			}
			rc, err := f.Open()
			if err != nil {
				return nil, nil, fmt.Errorf("读 icon: %w", err)
			}
			iconBytes, err = io.ReadAll(rc)
			rc.Close()
			if err != nil {
				return nil, nil, fmt.Errorf("读 icon: %w", err)
			}
		}
	}
	if !entryInZip {
		return nil, nil, fmt.Errorf("entry %s 不在包内", m.Entry)
	}
	if m.Icon != "" {
		if iconBytes == nil {
			return nil, nil, fmt.Errorf("icon %s 不在包内", m.Icon)
		}
		if SniffImageCT(iconBytes) == "" {
			return nil, nil, fmt.Errorf("icon 内容非图片(魔数不识别)")
		}
	}
	return &m, iconBytes, nil
}
