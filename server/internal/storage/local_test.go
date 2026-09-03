package storage

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSafePath_NormalFile(t *testing.T) {
	s := &LocalStorage{baseDir: "/tmp/wanling-test"}
	got, err := s.safePath("abc123.jpg")
	if err != nil {
		t.Fatalf("正常文件名不应报错: %v", err)
	}
	want := filepath.Join("/tmp/wanling-test", "abc123.jpg")
	if got != want {
		t.Errorf("期望 %s, 实际 %s", want, got)
	}
}

func TestSafePath_DirectoryTraversal(t *testing.T) {
	s := &LocalStorage{baseDir: "/tmp/wanling-test"}
	// "../../etc/passwd" 不能逃逸出 baseDir
	got, err := s.safePath("../../etc/passwd")
	if err != nil {
		t.Fatalf("safePath 不应报错（Clean 会规范化）: %v", err)
	}
	// 必须在 baseDir 内
	absBase, _ := filepath.Abs("/tmp/wanling-test")
	if got != absBase && !strings.HasPrefix(got, absBase+string(filepath.Separator)) {
		t.Errorf("路径逃逸了 baseDir: got=%s baseDir=%s", got, absBase)
	}
	// 应该映射成 baseDir/etc/passwd（被 Clean 吸到根再 Join）
	if filepath.Base(got) != "passwd" {
		t.Errorf("期望 basename=passwd, 实际 %s", filepath.Base(got))
	}
}

func TestSafePath_AbsolutePath(t *testing.T) {
	s := &LocalStorage{baseDir: "/tmp/wanling-test"}
	got, err := s.safePath("/etc/passwd")
	if err != nil {
		t.Fatalf("safePath 不应报错: %v", err)
	}
	absBase, _ := filepath.Abs("/tmp/wanling-test")
	if got != absBase && !strings.HasPrefix(got, absBase+string(filepath.Separator)) {
		t.Errorf("绝对路径应被限制在 baseDir 内: got=%s", got)
	}
}

func TestSafePath_EmptyString(t *testing.T) {
	s := &LocalStorage{baseDir: "/tmp/wanling-test"}
	got, err := s.safePath("")
	if err != nil {
		t.Fatalf("空字符串不应报错: %v", err)
	}
	absBase, _ := filepath.Abs("/tmp/wanling-test")
	if got != absBase {
		t.Errorf("空字符串应解析为 baseDir 本身: got=%s want=%s", got, absBase)
	}
}

func TestRead_DirectoryTraversal_ReturnsWithinBaseDir(t *testing.T) {
	// 用真实临时目录验证：构造 baseDir/sub/passwd，然后 Read("../sub/passwd")
	// 能读到自己（证明没逃逸也没挡正常相对路径）
	dir := t.TempDir()
	subDir := filepath.Join(dir, "sub")
	if err := os.MkdirAll(subDir, 0755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(subDir, "passwd")
	if err := os.WriteFile(target, []byte("fake"), 0644); err != nil {
		t.Fatal(err)
	}
	s := &LocalStorage{baseDir: dir}
	// "../sub/passwd" 从 baseDir 视角看是 baseDir/../sub/passwd — 会逃逸
	// safePath 应把它映射到 baseDir/sub/passwd（不逃逸），但那不是我们写的文件
	// 所以这里验证 Read("../../<absolute>/passwd") 返回错误（文件不存在于 baseDir 内）
	_, err := s.Read("../../etc/passwd")
	if err == nil {
		t.Fatal("路径遍历攻击应失败（文件不在 baseDir 内）")
	}
}

func TestSaveThumbnail_NestedKey(t *testing.T) {
	// 嵌套子目录 key（小程序 icon 场景）：自动创建父目录、可读回、同名覆盖
	dir := t.TempDir()
	s := &LocalStorage{baseDir: dir}
	key := "mp-icon/mp-abc123/1.png"

	if err := s.SaveThumbnail(key, []byte("first")); err != nil {
		t.Fatalf("嵌套 key 保存应成功: %v", err)
	}
	r, err := s.Read(key)
	if err != nil {
		t.Fatalf("保存后应可读回: %v", err)
	}
	got, err := io.ReadAll(r)
	r.Close()
	if err != nil {
		t.Fatalf("读回失败: %v", err)
	}
	if string(got) != "first" {
		t.Errorf("内容应一致, got %q", got)
	}

	if err := s.SaveThumbnail(key, []byte("second")); err != nil {
		t.Fatalf("覆盖写应成功: %v", err)
	}
	r, err = s.Read(key)
	if err != nil {
		t.Fatalf("覆盖后应可读回: %v", err)
	}
	got, err = io.ReadAll(r)
	r.Close()
	if err != nil {
		t.Fatalf("读回失败: %v", err)
	}
	if string(got) != "second" {
		t.Errorf("覆盖后内容应为最新, got %q", got)
	}
}
