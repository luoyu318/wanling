package handler

import (
	"bytes"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
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

// makePNG 构造一张 srcW×srcH 的纯色 PNG bytes（测试用，避免依赖外部图片文件）。
func makePNG(t *testing.T, srcW, srcH int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, srcW, srcH))
	// 填充一个非白非黑的固定色，便于区分原图与白底缩略图
	for y := 0; y < srcH; y++ {
		for x := 0; x < srcW; x++ {
			img.Set(x, y, color.RGBA{R: 200, G: 100, B: 50, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("png encode: %v", err)
	}
	return buf.Bytes()
}

// uploadMultipartFile 辅助：以 uploader 身份上传给定字节，返回 fileID。
func uploadMultipartFile(t *testing.T, r *gin.Engine, uploaderID, filename, contentType string, content []byte) string {
	t.Helper()
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	part, err := writer.CreateFormFile("file", filename)
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	part.Write(content)
	writer.Close()
	req := httptest.NewRequest("POST", "/api/upload", body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusCreated {
		t.Fatalf("upload failed: %d body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		ID       string `json:"id"`
		Filename string `json:"filename"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("upload resp unmarshal failed: %v body=%s", err, w.Body.String())
	}
	return resp.ID
}

// TestFileHandler_Upload_ImageThumbnail 验证图片上传的缩略图全链路：
//   - 上传 PNG → files.thumbnail_path 非空、width/height 正确
//   - ?thumb=1 下载返回缩略图（JPEG 格式 + 缓存头 + ETag）
//   - 普通下载（无 ?thumb）返回原图（PNG）
func TestFileHandler_Upload_ImageThumbnail(t *testing.T) {
	db := repository.SetupTestDB(t)
	frepo := repository.NewFileRepo(db)
	store, err := storage.NewLocalStorage(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocalStorage: %v", err)
	}
	h := NewFileHandler(frepo, store)

	urepo := repository.NewUserRepo(db)
	uploader, err := urepo.Create(shortName(t, "up_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create uploader: %v", err)
	}

	r := gin.New()
	var curUser string
	r.POST("/api/upload", func(c *gin.Context) {
		c.Set("userID", curUser)
		c.Set("role", "user")
		h.Upload(c)
	})
	r.GET("/api/files/:id", func(c *gin.Context) {
		c.Set("userID", curUser)
		c.Set("role", "user")
		h.Download(c)
	})
	curUser = uploader.ID

	// 上传一张 1200×800 的 PNG
	pngBytes := makePNG(t, 1200, 800)
	fileID := uploadMultipartFile(t, r, uploader.ID, "test.png", "image/png", pngBytes)

	// 1. 校验 DB 落库字段
	f, err := frepo.GetByID(fileID)
	if err != nil || f == nil {
		t.Fatalf("GetByID: err=%v f=%v", err, f)
	}
	if f.ThumbnailPath == nil || *f.ThumbnailPath == "" {
		t.Fatal("图片上传后 thumbnail_path 应非空")
	}
	if !bytes.HasSuffix([]byte(*f.ThumbnailPath), []byte("_thumb.jpg")) {
		t.Errorf("thumbnail_path 命名 = %s, 应以 _thumb.jpg 结尾", *f.ThumbnailPath)
	}
	if f.Width == nil || *f.Width != 1200 || f.Height == nil || *f.Height != 800 {
		t.Errorf("原图尺寸 = (w:%v,h:%v), want (1200,800)", f.Width, f.Height)
	}

	// 2. ?thumb=1 下载 → 缩略图（JPEG）
	req := httptest.NewRequest("GET", "/api/files/"+fileID+"?thumb=1", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("thumb download: expected 200, got %d body=%s", w.Code, w.Body.String())
	}
	if ct := w.Header().Get("Content-Type"); ct != "image/jpeg" {
		t.Errorf("缩略图 Content-Type = %q, want image/jpeg", ct)
	}
	if cc := w.Header().Get("Cache-Control"); !bytes.Contains([]byte(cc), []byte("immutable")) {
		t.Errorf("Cache-Control = %q, 应含 immutable", cc)
	}
	if etag := w.Header().Get("ETag"); !bytes.Contains([]byte(etag), []byte("thumb")) {
		t.Errorf("缩略图 ETag = %q, 应含 thumb 标识", etag)
	}
	// 应能被 jpeg 解码
	if _, err := jpeg.Decode(bytes.NewReader(w.Body.Bytes())); err != nil {
		t.Errorf("缩略图 body 非 JPEG: %v", err)
	}

	// 3. 普通下载（无 ?thumb）→ 原图 PNG
	req2 := httptest.NewRequest("GET", "/api/files/"+fileID, nil)
	w2 := httptest.NewRecorder()
	r.ServeHTTP(w2, req2)
	if w2.Code != http.StatusOK {
		t.Fatalf("origin download: expected 200, got %d", w2.Code)
	}
	if ct := w2.Header().Get("Content-Type"); ct != "image/png" {
		t.Errorf("原图 Content-Type = %q, want image/png", ct)
	}
	if etag := w2.Header().Get("ETag"); bytes.Contains([]byte(etag), []byte("thumb")) {
		t.Errorf("原图 ETag = %q, 不应含 thumb 标识", etag)
	}
}

// TestFileHandler_Upload_NonImageNoThumbnail 验证非图片文件不生成缩略图，
// 且 ?thumb=1 自动降级返回原文件（前端无感）。
func TestFileHandler_Upload_NonImageNoThumbnail(t *testing.T) {
	db := repository.SetupTestDB(t)
	frepo := repository.NewFileRepo(db)
	store, err := storage.NewLocalStorage(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocalStorage: %v", err)
	}
	h := NewFileHandler(frepo, store)

	urepo := repository.NewUserRepo(db)
	uploader, err := urepo.Create(shortName(t, "up_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create uploader: %v", err)
	}

	r := gin.New()
	var curUser string
	r.POST("/api/upload", func(c *gin.Context) {
		c.Set("userID", curUser)
		c.Set("role", "user")
		h.Upload(c)
	})
	r.GET("/api/files/:id", func(c *gin.Context) {
		c.Set("userID", curUser)
		c.Set("role", "user")
		h.Download(c)
	})
	curUser = uploader.ID

	// 上传一个文本文件
	fileID := uploadMultipartFile(t, r, uploader.ID, "note.txt", "text/plain", []byte("hello world"))

	// 非图片 → thumbnail_path 应为 NULL
	f, err := frepo.GetByID(fileID)
	if err != nil || f == nil {
		t.Fatalf("GetByID: err=%v f=%v", err, f)
	}
	if f.ThumbnailPath != nil {
		t.Errorf("非图片 thumbnail_path = %v, 应为 nil", f.ThumbnailPath)
	}
	if f.Width != nil || f.Height != nil {
		t.Errorf("非图片 width/height = (%v,%v), 应为 nil", f.Width, f.Height)
	}

	// ?thumb=1 → 无缩略图，降级返回原文
	req := httptest.NewRequest("GET", "/api/files/"+fileID+"?thumb=1", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("降级下载: expected 200, got %d", w.Code)
	}
	if !bytes.Equal(w.Body.Bytes(), []byte("hello world")) {
		t.Errorf("降级内容 = %q, want 'hello world'", w.Body.String())
	}
}
