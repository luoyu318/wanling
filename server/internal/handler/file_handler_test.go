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

// TestFileHandler_Download_Ownership 验证文件下载的归属校验（防 IDOR）：
//   - owner 自己能下载（200）
//   - 其他 user 被拒（403）
//   - agent 用 ownerID 能下载它服务的 user 的文件（200）
//
// UUID 不可枚举只是抬高攻击成本，不能替代归属校验——任意登录用户
// 拿到 file UUID（如分享、日志泄露）即可下载他人文件，故必须比对 owner_id。
func TestFileHandler_Download_Ownership(t *testing.T) {
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

	// 通用下载：路由只注册一次，身份通过闭包变量注入。
	// 反复 r.GET 会触发 gin 路由重复注册 panic，故用闭包传递身份。
	var curRole, curUser, curOwner string
	r.GET("/api/files/:id", func(c *gin.Context) {
		c.Set("userID", curUser)
		c.Set("role", curRole)
		if curOwner != "" {
			c.Set("ownerID", curOwner)
		}
		h.Download(c)
	})
	downloadAs := func(role, userID, ownerID string) *httptest.ResponseRecorder {
		curRole, curUser, curOwner = role, userID, ownerID
		greq := httptest.NewRequest("GET", "/api/files/"+fileID, nil)
		gw := httptest.NewRecorder()
		r.ServeHTTP(gw, greq)
		return gw
	}

	// 1. owner 自己下载 → 200
	if w2 := downloadAs("user", uploader.ID, ""); w2.Code != http.StatusOK {
		t.Errorf("owner download: expected 200, got %d body=%s", w2.Code, w2.Body.String())
	} else if !bytes.Equal(w2.Body.Bytes(), []byte("hello world")) {
		t.Errorf("owner download content mismatch: got %q", w2.Body.String())
	}

	// 2. 其他 user 下载 → 403（IDOR 已修复）
	if w3 := downloadAs("user", downloader.ID, ""); w3.Code != http.StatusForbidden {
		t.Errorf("non-owner user download: expected 403, got %d body=%s", w3.Code, w3.Body.String())
	}

	// 3. agent 用 ownerID 下载它服务的 user 的文件 → 200
	//    agent 自己没有文件（agent_id 不在 users 表），ownerID 是它服务的 user。
	if w4 := downloadAs("agent", "some-agent-id", uploader.ID); w4.Code != http.StatusOK {
		t.Errorf("agent download owner file: expected 200, got %d body=%s", w4.Code, w4.Body.String())
	}

	// 4. agent 用错误的 ownerID → 403
	if w5 := downloadAs("agent", "some-agent-id", downloader.ID); w5.Code != http.StatusForbidden {
		t.Errorf("agent download non-owner file: expected 403, got %d body=%s", w5.Code, w5.Body.String())
	}
}
