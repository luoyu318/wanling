package miniprogram

import (
	"archive/zip"
	"bytes"
	"strings"
	"testing"
)

func buildZip(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	w := zip.NewWriter(&buf)
	for name, content := range files {
		fw, err := w.Create(name)
		if err != nil {
			t.Fatalf("zip create %s: %v", name, err)
		}
		if _, err := fw.Write([]byte(content)); err != nil {
			t.Fatalf("zip write %s: %v", name, err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatalf("zip close: %v", err)
	}
	return buf.Bytes()
}

const goodManifest = `{"appid":"hello","name":"Hello","version":1,"entry":"index.html","permissions":["wanling.api"],"minHostVersion":"1.6.3"}`

func TestValidatePackage_OK(t *testing.T) {
	data := buildZip(t, map[string]string{
		"manifest.json": goodManifest,
		"index.html":    "<html></html>",
		"js/app.js":     "console.log(1)",
	})
	m, _, err := ValidatePackage(data, 20<<20)
	if err != nil {
		t.Fatalf("ValidatePackage: %v", err)
	}
	if m.Appid != "hello" || m.Version != 1 || m.Entry != "index.html" {
		t.Errorf("manifest 解析不符: %+v", m)
	}
}

func TestValidatePackage_MissingManifest(t *testing.T) {
	data := buildZip(t, map[string]string{"index.html": "<html></html>"})
	if _, _, err := ValidatePackage(data, 20<<20); err == nil {
		t.Errorf("缺 manifest.json 应报错")
	}
}

func TestValidatePackage_EntryMissing(t *testing.T) {
	data := buildZip(t, map[string]string{
		"manifest.json": goodManifest,
		"other.html":    "x",
	})
	if _, _, err := ValidatePackage(data, 20<<20); err == nil {
		t.Errorf("entry 不存在应报错")
	}
}

func TestValidatePackage_BadAppid(t *testing.T) {
	bad := strings.Replace(goodManifest, `"appid":"hello"`, `"appid":"Hello!"`, 1)
	data := buildZip(t, map[string]string{"manifest.json": bad, "index.html": "x"})
	if _, _, err := ValidatePackage(data, 20<<20); err == nil {
		t.Errorf("非法 appid 应报错")
	}
}

func TestValidatePackage_BadPermission(t *testing.T) {
	bad := strings.Replace(goodManifest, `["wanling.api"]`, `["wanling.api","wanling.root"]`, 1)
	data := buildZip(t, map[string]string{"manifest.json": bad, "index.html": "x"})
	if _, _, err := ValidatePackage(data, 20<<20); err == nil {
		t.Errorf("未知 permission 应报错")
	}
}

func TestValidatePackage_PathTraversalEntry(t *testing.T) {
	data := buildZip(t, map[string]string{
		"manifest.json": goodManifest,
		"index.html":    "x",
		"../evil.js":    "x",
	})
	if _, _, err := ValidatePackage(data, 20<<20); err == nil {
		t.Errorf("路径穿越条目应报错")
	}
}

func TestValidatePackage_NavigationBar(t *testing.T) {
	cases := []struct {
		name      string
		nb        string
		wantErr   bool
		wantStyle string
	}{
		{name: "缺省通过", nb: ""},
		{name: "default 合法", nb: `,"navigationBar":{"style":"default"}`, wantStyle: "default"},
		{name: "custom 合法", nb: `,"navigationBar":{"style":"custom"}`, wantStyle: "custom"},
		{name: "颜色合法", nb: `,"navigationBar":{"style":"default","backgroundColor":"#1E6FFF","foregroundColor":"#FFFFFF"}`, wantStyle: "default"},
		{name: "style 非法", nb: `,"navigationBar":{"style":"hide"}`, wantErr: true},
		{name: "颜色非法", nb: `,"navigationBar":{"backgroundColor":"red"}`, wantErr: true},
		{name: "颜色缺#非法", nb: `,"navigationBar":{"backgroundColor":"1E6FFF"}`, wantErr: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			data := buildZip(t, map[string]string{
				"manifest.json": `{"appid":"hello","name":"Hello","version":1,"entry":"index.html"` + tc.nb + `}`,
				"index.html":    "<html></html>",
			})
			m, _, err := ValidatePackage(data, 20<<20)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("期望报错, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("ValidatePackage: %v", err)
			}
			gotStyle := ""
			if m.NavigationBar != nil {
				gotStyle = m.NavigationBar.Style
			}
			if gotStyle != tc.wantStyle {
				t.Errorf("style = %q, want %q", gotStyle, tc.wantStyle)
			}
		})
	}
}

func TestValidatePackage_Oversize(t *testing.T) {
	data := buildZip(t, map[string]string{"manifest.json": goodManifest, "index.html": strings.Repeat("a", 4096)})
	if _, _, err := ValidatePackage(data, 1024); err == nil {
		t.Errorf("超上限应报错")
	}
}

// 补充边界:子目录里的 manifest.json 不是根 manifest,应按缺失拒绝。
func TestValidatePackage_ManifestInSubdir(t *testing.T) {
	data := buildZip(t, map[string]string{
		"sub/manifest.json": goodManifest,
		"index.html":        "x",
	})
	if _, _, err := ValidatePackage(data, 20<<20); err == nil {
		t.Errorf("子目录 manifest.json 不应被识别为根 manifest")
	}
}

// 补充边界:反斜杠形式的路径穿越条目应被拒绝。
func TestValidatePackage_BackslashTraversalEntry(t *testing.T) {
	data := buildZip(t, map[string]string{
		"manifest.json": goodManifest,
		"index.html":    "x",
		"..\\evil.js":   "x",
	})
	if _, _, err := ValidatePackage(data, 20<<20); err == nil {
		t.Errorf("反斜杠路径穿越条目应报错")
	}
}

// 合法 8x8 PNG(1x1 透明像素放大版头尾齐全,魔数嗅探可通过即可)。
var testPngBytes = []byte{
	0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
	'I', 'H', 'D', 'R', 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x08,
	0x08, 0x06, 0x00, 0x00, 0x00, 0xC3, 0x0F, 0x9A, 0x62,
}

func TestValidatePackage_Icon提取(t *testing.T) {
	zipBytes := buildZip(t, map[string]string{
		"manifest.json": `{"appid":"icon-demo","name":"图标","version":1,"entry":"index.html","icon":"icon.png"}`,
		"index.html":    "<html></html>",
		"icon.png":      string(testPngBytes),
	})
	m, icon, err := ValidatePackage(zipBytes, 1<<20)
	if err != nil {
		t.Fatalf("合法包不应报错: %v", err)
	}
	if len(icon) != len(testPngBytes) {
		t.Fatalf("icon 字节应完整提取, got %d bytes", len(icon))
	}
	if m.Icon != "icon.png" {
		t.Fatalf("manifest.Icon 应保持包内路径原样, got %q", m.Icon)
	}
}

func TestValidatePackage_无icon返回nil(t *testing.T) {
	zipBytes := buildZip(t, map[string]string{
		"manifest.json": `{"appid":"icon-demo","name":"无图","version":1,"entry":"index.html"}`,
		"index.html":    "<html></html>",
	})
	_, icon, err := ValidatePackage(zipBytes, 1<<20)
	if err != nil || icon != nil {
		t.Fatalf("无 icon 应 err=nil icon=nil, got %v %v", err, icon)
	}
}

func TestValidatePackage_Icon声明但文件缺失(t *testing.T) {
	zipBytes := buildZip(t, map[string]string{
		"manifest.json": `{"appid":"icon-demo","name":"缺图","version":1,"entry":"index.html","icon":"icon.png"}`,
		"index.html":    "<html></html>",
	})
	_, _, err := ValidatePackage(zipBytes, 1<<20)
	if err == nil || !strings.Contains(err.Error(), "icon") {
		t.Fatalf("icon 声明但缺失应报错, got %v", err)
	}
}

func TestValidatePackage_Icon非法扩展名(t *testing.T) {
	zipBytes := buildZip(t, map[string]string{
		"manifest.json": `{"appid":"icon-demo","name":"扩展名","version":1,"entry":"index.html","icon":"icon.gif"}`,
		"index.html":    "<html></html>",
		"icon.gif":      "GIF89a",
	})
	_, _, err := ValidatePackage(zipBytes, 1<<20)
	if err == nil || !strings.Contains(err.Error(), "扩展名") {
		t.Fatalf("非法扩展名应报错, got %v", err)
	}
}

func TestValidatePackage_Icon内容非图片(t *testing.T) {
	zipBytes := buildZip(t, map[string]string{
		"manifest.json": `{"appid":"icon-demo","name":"伪图","version":1,"entry":"index.html","icon":"icon.png"}`,
		"index.html":    "<html></html>",
		"icon.png":      "definitely not an image",
	})
	_, _, err := ValidatePackage(zipBytes, 1<<20)
	if err == nil || !strings.Contains(err.Error(), "图片") {
		t.Fatalf("非图片内容应报错, got %v", err)
	}
}

func TestValidatePackage_Icon超大小上限(t *testing.T) {
	big := append([]byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}, make([]byte, 300<<10)...)
	zipBytes := buildZip(t, map[string]string{
		"manifest.json": `{"appid":"icon-demo","name":"大图","version":1,"entry":"index.html","icon":"icon.png"}`,
		"index.html":    "<html></html>",
		"icon.png":      string(big),
	})
	_, _, err := ValidatePackage(zipBytes, 4<<20)
	if err == nil || !strings.Contains(err.Error(), "icon") {
		t.Fatalf("icon 超 256KB 应报错, got %v", err)
	}
}
