package storage

import (
	"crypto/rand"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

type LocalStorage struct {
	baseDir string
}

func NewLocalStorage(baseDir string) (*LocalStorage, error) {
	if err := os.MkdirAll(baseDir, 0755); err != nil { // #nosec G301 -- 审计确认：目录 0755 允许遍历，文件本身 0600 限制读取
		return nil, fmt.Errorf("创建存储目录失败: %w", err)
	}
	return &LocalStorage{baseDir: baseDir}, nil
}

func (s *LocalStorage) Save(filename string, reader io.Reader) (string, error) {
	uid, err := generateFileID()
	if err != nil {
		return "", err
	}
	ext := filepath.Ext(filename)
	storageName := uid + ext
	fullPath := filepath.Join(s.baseDir, storageName)

	f, err := os.OpenFile(fullPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600) // #nosec G304 -- safePath 已做路径遍历防护；0600 限制只有 owner 可读（审计 G306）
	if err != nil {
		return "", fmt.Errorf("创建文件失败: %w", err)
	}
	defer f.Close()

	if _, err := io.Copy(f, reader); err != nil {
		os.Remove(fullPath)
		return "", fmt.Errorf("写入文件失败: %w", err)
	}

	return storageName, nil
}

// safePath 把 storageName 规范化到 baseDir 内的绝对路径。
// 防路径遍历：前缀 "/" 让 Clean 把所有 ".." 吸收到根，
// 再用 filepath.Join 拼到 baseDir，最后 prefix 校验双重保险。
func (s *LocalStorage) safePath(storageName string) (string, error) {
	cleaned := filepath.Clean("/" + storageName)
	full := filepath.Join(s.baseDir, cleaned)
	absBase, err := filepath.Abs(s.baseDir)
	if err != nil {
		return "", fmt.Errorf("resolve base dir: %w", err)
	}
	if full != absBase && !strings.HasPrefix(full, absBase+string(filepath.Separator)) {
		return "", fmt.Errorf("invalid storage path: %s", storageName)
	}
	return full, nil
}

func (s *LocalStorage) Read(path string) (io.ReadCloser, error) {
	full, err := s.safePath(path)
	if err != nil {
		return nil, err
	}
	return os.Open(full) // #nosec G304 -- safePath 已做路径遍历防护
}

func (s *LocalStorage) Delete(path string) error {
	full, err := s.safePath(path)
	if err != nil {
		return err
	}
	return os.Remove(full)
}

// SaveThumbnail 按 storageName 把字节写入存储目录，支持嵌套子目录 key
// （如 `mp-icon/{appid}/{version}.png`，自动创建父目录）。
// 覆盖写（同名文件以最新为准）。
func (s *LocalStorage) SaveThumbnail(storageName string, data []byte) error {
	fullPath := filepath.Join(s.baseDir, storageName)
	if err := os.MkdirAll(filepath.Dir(fullPath), 0755); err != nil { // #nosec G301 -- 审计确认：目录 0755 允许遍历，文件本身 0600 限制读取
		return fmt.Errorf("创建存储目录失败: %w", err)
	}
	if err := os.WriteFile(fullPath, data, 0600); err != nil {
		return fmt.Errorf("写入缩略图失败: %w", err)
	}
	return nil
}

func generateFileID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("生成文件 ID 失败: %w", err)
	}
	return fmt.Sprintf("%x", b), nil
}
