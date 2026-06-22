package storage

import (
	"crypto/rand"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

type LocalStorage struct {
	baseDir string
}

func NewLocalStorage(baseDir string) (*LocalStorage, error) {
	if err := os.MkdirAll(baseDir, 0755); err != nil {
		return nil, fmt.Errorf("创建存储目录失败: %w", err)
	}
	return &LocalStorage{baseDir: baseDir}, nil
}

func (s *LocalStorage) Save(filename string, reader io.Reader) (string, error) {
	uid := generateFileID()
	ext := filepath.Ext(filename)
	storageName := uid + ext
	fullPath := filepath.Join(s.baseDir, storageName)

	f, err := os.Create(fullPath)
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

func (s *LocalStorage) Read(path string) (io.ReadCloser, error) {
	return os.Open(filepath.Join(s.baseDir, path))
}

func (s *LocalStorage) Delete(path string) error {
	return os.Remove(filepath.Join(s.baseDir, path))
}

func generateFileID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return fmt.Sprintf("%x", b)
}
