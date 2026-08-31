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

// allowedPermissions manifest.permissions 允许集(M2 起含 chat 类)。
var allowedPermissions = map[string]struct{}{
	"wanling.api":        {},
	"wanling.chat.read":  {},
	"wanling.chat.share": {},
}

const maxFiles = 2000

var appidRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{2,31}$`)

// ValidatePackage 校验小程序 zip 包,返回解析后的 manifest。
// 校验项:压缩/解压后总大小上限、manifest.json 根目录存在、必填字段、appid 格式、
// version>0、entry 存在于包内、permissions 白名单、条目名无路径穿越、文件数上限。
func ValidatePackage(zipBytes []byte, maxBytes int64) (*model.MiniprogramManifest, error) {
	if maxBytes <= 0 {
		return nil, fmt.Errorf("maxBytes 需为正数, got %d", maxBytes)
	}
	if int64(len(zipBytes)) > maxBytes {
		return nil, fmt.Errorf("包大小 %d 超上限 %d", len(zipBytes), maxBytes)
	}
	zr, err := zip.NewReader(bytes.NewReader(zipBytes), int64(len(zipBytes)))
	if err != nil {
		return nil, fmt.Errorf("非法 zip: %w", err)
	}
	if len(zr.File) > maxFiles {
		return nil, fmt.Errorf("文件数 %d 超上限 %d", len(zr.File), maxFiles)
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
			return nil, fmt.Errorf("非法包内路径: %s", name)
		}
		// 饱和加:单帧超上限或累加会越过上限 → 直接判超上限(fail fast)。
		// 防 uint64 回绕:恶意条目声明超大尺寸时,`totalUncompressed +=` 溢出回绕
		// 变小值绕过检查,饱和加保证任一帧越界即拒。
		if f.UncompressedSize64 > limit || totalUncompressed > limit-f.UncompressedSize64 {
			return nil, fmt.Errorf("解压后总大小超上限 %d", maxBytes)
		}
		totalUncompressed += f.UncompressedSize64
		// clean 后不等于 "manifest.json" 的(如 sub/manifest.json)不会被误认
		if clean == "manifest.json" {
			if f.UncompressedSize64 > 1<<20 {
				return nil, fmt.Errorf("manifest.json 过大")
			}
			rc, err := f.Open()
			if err != nil {
				return nil, fmt.Errorf("读 manifest.json: %w", err)
			}
			manifestRaw, err = io.ReadAll(rc)
			rc.Close()
			if err != nil {
				return nil, fmt.Errorf("读 manifest.json: %w", err)
			}
		}
	}
	if manifestRaw == nil {
		return nil, fmt.Errorf("缺少 manifest.json")
	}

	var m model.MiniprogramManifest
	if err := json.Unmarshal(manifestRaw, &m); err != nil {
		return nil, fmt.Errorf("manifest.json 非法: %w", err)
	}
	if !appidRe.MatchString(m.Appid) {
		return nil, fmt.Errorf("appid 需匹配 ^[a-z0-9][a-z0-9-]{2,31}$")
	}
	if m.Name == "" {
		return nil, fmt.Errorf("name 必填")
	}
	if m.Version <= 0 {
		return nil, fmt.Errorf("version 需为正整数")
	}
	if m.Entry == "" {
		m.Entry = "index.html"
	}
	for _, p := range m.Permissions {
		if _, ok := allowedPermissions[p]; !ok {
			return nil, fmt.Errorf("未知 permission: %s", p)
		}
	}

	// 第二遍:entry 存在性(manifest 解析前 entry 未知,与第一遍合并不了)。
	entryInZip := false
	for _, f := range zr.File {
		if path.Clean(strings.ReplaceAll(f.Name, "\\", "/")) == path.Clean(m.Entry) {
			entryInZip = true
			break
		}
	}
	if !entryInZip {
		return nil, fmt.Errorf("entry %s 不在包内", m.Entry)
	}
	return &m, nil
}
