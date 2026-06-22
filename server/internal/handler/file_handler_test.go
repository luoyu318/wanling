package handler

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/repository"
	"github.com/wanling/server/internal/storage"
)

// TestFileHandler_Download_AllowsAnyAuthenticatedUser 验证去 owner 校验后：
//   - user A 上传的文件，user B 也能下载（200，非 403）
//
// 这是 markdown-image-platformhint spec Task 1 的核心验证点：依赖 UUID 不可枚举
// + JWT 强制登录来保证安全，而不是 owner_id 比对。
func TestFileHandler_Download_AllowsAnyAuthenticatedUser(t *testing.T) {
	db := repository.SetupTestDB(t)
	frepo := repository.NewFileRepo(db)
	store, err := storage.NewLocalStorage(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocalStorage: %v", err)
	}
	h := NewFileHandler(frepo, store)

	// 准备两个 user，模拟两个不同的已认证身份
	urepo := repository.NewUserRepo(db)
	uploader, err := urepo.Create(shortName(t, "up_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create uploader: %v", err)
	}
	downloader, err := urepo.Create(shortName(t, "dl_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create downloader: %v", err)
	}

	// 用 uploader 身份上传一个文件
	r := gin.New()
	var fileID string
	r.POST("/api/upload", func(c *gin.Context) {
		c.Set("userID", uploader.ID)
		c.Set("role", "user")
		h.Upload(c)
	})
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	part, err := writer.CreateFormFile("file", "test.txt")
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	part.Write([]byte("hello world"))
	writer.Close()
	req := httptest.NewRequest("POST", "/api/upload", body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusCreated {
		t.Fatalf("upload failed: %d body=%s", w.Code, w.Body.String())
	}
	// 结构化解析 upload 响应，提取 file_id（形如 {"id":"...","filename":"..."}）
	var resp struct {
		ID       string `json:"id"`
		Filename string `json:"filename"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("upload resp unmarshal failed: %v body=%s", err, w.Body.String())
	}
	fileID = resp.ID

	// 用 downloader 身份下载 — 应该 200（去 owner 校验后）
	r.GET("/api/files/:id", func(c *gin.Context) {
		c.Set("userID", downloader.ID)
		c.Set("role", "user")
		h.Download(c)
	})
	req2 := httptest.NewRequest("GET", "/api/files/"+fileID, nil)
	w2 := httptest.NewRecorder()
	r.ServeHTTP(w2, req2)

	if w2.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", w2.Code, w2.Body.String())
	}
	if !bytes.Equal(w2.Body.Bytes(), []byte("hello world")) {
		t.Errorf("content mismatch: got %q", w2.Body.String())
	}
}
