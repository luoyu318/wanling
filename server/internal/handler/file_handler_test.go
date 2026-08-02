package handler

import (
	"bytes"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
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
	h := NewFileHandler(frepo, store, 32<<20)

	// 准备两个 user，模拟两个不同的已认证身份
	urepo := repository.NewUserRepo(db)
	uploader, err := urepo.Create(t.Context(), shortName(t, "up_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create uploader: %v", err)
	}
	downloader, err := urepo.Create(t.Context(), shortName(t, "dl_"), "$2a$10$hash")
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
	// upload 走 envelope（OkCreated），用 AssertOk 拿 data 后取 id
	data := AssertOk(t, w, http.StatusCreated)
	fileID, _ = data["id"].(string)
	if fileID == "" {
		t.Fatalf("upload resp 缺 id 字段; body=%s", w.Body.String())
	}

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
	w3 := downloadAs("user", downloader.ID, "")
	AssertErr(t, w3, http.StatusForbidden, "forbidden")

	// 3. agent 用 ownerID 下载它服务的 user 的文件 → 200
	//    agent 自己没有文件（agent_id 不在 users 表），ownerID 是它服务的 user。
	w4 := downloadAs("agent", "some-agent-id", uploader.ID)
	if w4.Code != http.StatusOK {
		t.Errorf("agent download owner file: expected 200, got %d body=%s", w4.Code, w4.Body.String())
	} else if !bytes.Equal(w4.Body.Bytes(), []byte("hello world")) {
		t.Errorf("agent download content mismatch: got %q", w4.Body.String())
	}

	// 4. agent 用错误的 ownerID → 403
	w5 := downloadAs("agent", "some-agent-id", downloader.ID)
	AssertErr(t, w5, http.StatusForbidden, "forbidden")
}

// TestFileHandler_Download_ConvAvatarWhitelist 验证 conversations.avatar_url
// 命中头像白名单(让群成员能下载群头像,即使不是 file owner / 没 file_conv_links)。
//
// 场景:user A 上传文件并被设为某群头像 → user B(非 owner,跟 A 无关)
// 是该群 participant → 下载应 200(命中 IsConvAvatar 白名单)。
func TestFileHandler_Download_ConvAvatarWhitelist(t *testing.T) {
	db := repository.SetupTestDB(t)
	frepo := repository.NewFileRepo(db)
	store, err := storage.NewLocalStorage(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocalStorage: %v", err)
	}
	h := NewFileHandler(frepo, store, 32<<20)

	urepo := repository.NewUserRepo(db)
	owner, _ := urepo.Create(t.Context(), shortName(t, "own_"), "$2a$10$hash")
	member, _ := urepo.Create(t.Context(), shortName(t, "mem_"), "$2a$10$hash")

	// owner 上传一个文件
	r := gin.New()
	r.POST("/api/upload", func(c *gin.Context) {
		c.Set("userID", owner.ID)
		c.Set("role", "user")
		h.Upload(c)
	})
	fileID := uploadMultipartFile(t, r, owner.ID, "test.txt", "text/plain", []byte("group avatar"))

	// 直接 SQL 起一个 group_user 会话,把 file 设为该群头像
	var convID string
	err = db.QueryRow(`
		INSERT INTO conversations (type, title, avatar_url)
		VALUES ('group_user', 'test group', '/api/files/' || $1)
		RETURNING id`,
		fileID,
	).Scan(&convID)
	if err != nil {
		t.Fatalf("创建会话失败: %v", err)
	}

	// 加 owner 和 member 为 participant
	_, err = db.Exec(`
		INSERT INTO conversation_participants (conv_id, member_id, member_type, role)
		VALUES ($1, $2, 'user', 'owner'), ($1, $3, 'user', 'member')`,
		convID, owner.ID, member.ID,
	)
	if err != nil {
		t.Fatalf("加 participant 失败: %v", err)
	}

	// member 下载该 file → 应 200(命中 IsConvAvatar 白名单)
	var curUser string
	r.GET("/api/files/:id", func(c *gin.Context) {
		c.Set("userID", curUser)
		c.Set("role", "user")
		h.Download(c)
	})
	curUser = member.ID
	greq := httptest.NewRequest("GET", "/api/files/"+fileID, nil)
	gw := httptest.NewRecorder()
	r.ServeHTTP(gw, greq)
	if gw.Code != http.StatusOK {
		t.Errorf("群成员下载群头像: 期望 200, 实际 %d body=%s", gw.Code, gw.Body.String())
	}

	// 清掉群头像后再下载 → 应 403(白名单不命中,file_conv_links 也无记录)
	if _, err := db.Exec(`UPDATE conversations SET avatar_url = NULL WHERE id = $1`, convID); err != nil {
		t.Fatalf("清群头像失败: %v", err)
	}
	greq2 := httptest.NewRequest("GET", "/api/files/"+fileID, nil)
	gw2 := httptest.NewRecorder()
	r.ServeHTTP(gw2, greq2)
	AssertErr(t, gw2, http.StatusForbidden, "forbidden")
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

// makeJPEG 构造一张 srcW×srcH 的纯色 JPEG bytes（测试用）。
// JPEG 的 magic bytes（FF D8 FF）能被 http.DetectContentType 正确识别为 image/jpeg。
func makeJPEG(t *testing.T, srcW, srcH int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, srcW, srcH))
	for y := 0; y < srcH; y++ {
		for x := 0; x < srcW; x++ {
			img.Set(x, y, color.RGBA{R: 200, G: 100, B: 50, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, nil); err != nil {
		t.Fatalf("jpeg encode: %v", err)
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
	data := AssertOk(t, w, http.StatusCreated)
	id, _ := data["id"].(string)
	if id == "" {
		t.Fatalf("upload resp 缺 id 字段; body=%s", w.Body.String())
	}
	return id
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
	h := NewFileHandler(frepo, store, 32<<20)

	urepo := repository.NewUserRepo(db)
	uploader, err := urepo.Create(t.Context(), shortName(t, "up_"), "$2a$10$hash")
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
	f, err := frepo.GetByID(t.Context(), fileID)
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
	h := NewFileHandler(frepo, store, 32<<20)

	urepo := repository.NewUserRepo(db)
	uploader, err := urepo.Create(t.Context(), shortName(t, "up_"), "$2a$10$hash")
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
	f, err := frepo.GetByID(t.Context(), fileID)
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

// TestFileHandler_Upload_OversizedRejected 验证上传超限被 413 拒绝。
//
// MaxBytesReader 在读取请求体时逐字节拦截，超限返回 MaxBytesError，
// handler 应转为 413（Request Entity Too Large）而非 400。
func TestFileHandler_Upload_OversizedRejected(t *testing.T) {
	db := repository.SetupTestDB(t)
	frepo := repository.NewFileRepo(db)
	store, err := storage.NewLocalStorage(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocalStorage: %v", err)
	}
	// 上限设为 100 字节，便于构造超限场景
	h := NewFileHandler(frepo, store, 100)

	urepo := repository.NewUserRepo(db)
	uploader, err := urepo.Create(t.Context(), shortName(t, "up_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create uploader: %v", err)
	}

	r := gin.New()
	r.POST("/api/upload", func(c *gin.Context) {
		c.Set("userID", uploader.ID)
		c.Set("role", "user")
		h.Upload(c)
	})

	// 构造 200 字节的文件（超 100 上限）
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	part, err := writer.CreateFormFile("file", "big.bin")
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	part.Write(make([]byte, 200))
	writer.Close()

	req := httptest.NewRequest("POST", "/api/upload", body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusRequestEntityTooLarge, "payload_too_large")
}

// TestUpload_RejectsHtml 验证 M5 扩展名白名单：上传 .html 文件应被拒（415），
// 防 .html/.exe 等可执行/可渲染类型上传导致存储型 XSS 或客户端被利用。
func TestUpload_RejectsHtml(t *testing.T) {
	db := repository.SetupTestDB(t)
	frepo := repository.NewFileRepo(db)
	store, err := storage.NewLocalStorage(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocalStorage: %v", err)
	}
	h := NewFileHandler(frepo, store, 32<<20)

	urepo := repository.NewUserRepo(db)
	uploader, err := urepo.Create(t.Context(), shortName(t, "up_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create uploader: %v", err)
	}

	r := gin.New()
	r.POST("/api/upload", func(c *gin.Context) {
		c.Set("userID", uploader.ID)
		c.Set("role", "user")
		h.Upload(c)
	})

	// 构造一个 .html 文件（XSS payload），应被白名单拒绝
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	part, err := writer.CreateFormFile("file", "evil.html")
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	part.Write([]byte("<script>alert('xss')</script>"))
	writer.Close()

	req := httptest.NewRequest("POST", "/api/upload", body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusUnsupportedMediaType, "unsupported_media_type")
}

// TestUpload_AcceptsJpg 验证 M5 扩展名白名单放行 jpg（白名单覆盖图片类型）。
func TestUpload_AcceptsJpg(t *testing.T) {
	db := repository.SetupTestDB(t)
	frepo := repository.NewFileRepo(db)
	store, err := storage.NewLocalStorage(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocalStorage: %v", err)
	}
	h := NewFileHandler(frepo, store, 32<<20)

	urepo := repository.NewUserRepo(db)
	uploader, err := urepo.Create(t.Context(), shortName(t, "up_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create uploader: %v", err)
	}

	r := gin.New()
	r.POST("/api/upload", func(c *gin.Context) {
		c.Set("userID", uploader.ID)
		c.Set("role", "user")
		h.Upload(c)
	})

	// 上传一张真实 JPEG（magic bytes FF D8 FF，M3 嗅探需内容与扩展名匹配）→ 应 201
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	part, err := writer.CreateFormFile("file", "photo.jpg")
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	part.Write(makeJPEG(t, 10, 10))
	writer.Close()

	req := httptest.NewRequest("POST", "/api/upload", body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertOk(t, w, http.StatusCreated)
}

// TestUpload_MIMEMismatch_Rejected 验证 M3 MIME 嗅探防改名攻击：
// 内容是 PE 可执行文件（MZ magic bytes）但扩展名是 .jpg，企图绕过扩展名白名单 → 应返 415 mime_mismatch。
func TestUpload_MIMEMismatch_Rejected(t *testing.T) {
	db := repository.SetupTestDB(t)
	frepo := repository.NewFileRepo(db)
	store, err := storage.NewLocalStorage(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocalStorage: %v", err)
	}
	h := NewFileHandler(frepo, store, 32<<20)

	urepo := repository.NewUserRepo(db)
	uploader, err := urepo.Create(t.Context(), shortName(t, "up_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create uploader: %v", err)
	}

	r := gin.New()
	r.POST("/api/upload", func(c *gin.Context) {
		c.Set("userID", uploader.ID)
		c.Set("role", "user")
		h.Upload(c)
	})

	// PE 可执行文件 magic bytes（MZ...），改名成 .jpg 企图绕过扩展名白名单
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	part, err := writer.CreateFormFile("file", "malicious.jpg")
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	part.Write([]byte{0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00,
		0x04, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00,
		0xB8, 0x00, 0x00, 0x00})
	part.Write(make([]byte, 100)) // padding 凑足嗅探区
	writer.Close()

	req := httptest.NewRequest("POST", "/api/upload", body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusUnsupportedMediaType, "mime_mismatch")
}

// TestUpload_ValidPNG_Accepted 验证 M3 真实图片（内容与扩展名一致）正常通过嗅探。
func TestUpload_ValidPNG_Accepted(t *testing.T) {
	db := repository.SetupTestDB(t)
	frepo := repository.NewFileRepo(db)
	store, err := storage.NewLocalStorage(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocalStorage: %v", err)
	}
	h := NewFileHandler(frepo, store, 32<<20)

	urepo := repository.NewUserRepo(db)
	uploader, err := urepo.Create(t.Context(), shortName(t, "up_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create uploader: %v", err)
	}

	r := gin.New()
	r.POST("/api/upload", func(c *gin.Context) {
		c.Set("userID", uploader.ID)
		c.Set("role", "user")
		h.Upload(c)
	})

	// 真实 PNG magic bytes（89 50 4E 47）+ .png 扩展名 → 嗅探通过
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	part, err := writer.CreateFormFile("file", "test.png")
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	part.Write(makePNG(t, 10, 10))
	writer.Close()

	req := httptest.NewRequest("POST", "/api/upload", body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertOk(t, w, http.StatusCreated)
}

// TestDownload_HeadersContainAttachmentAndNosniff 验证 M5 Download 头加固：
//   - Content-Disposition 含 "attachment"（防浏览器 inline 渲染存储型 XSS）
//   - 存在 X-Content-Type-Options: nosniff（防 IE MIME sniffing）
func TestDownload_HeadersContainAttachmentAndNosniff(t *testing.T) {
	db := repository.SetupTestDB(t)
	frepo := repository.NewFileRepo(db)
	store, err := storage.NewLocalStorage(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocalStorage: %v", err)
	}
	h := NewFileHandler(frepo, store, 32<<20)

	urepo := repository.NewUserRepo(db)
	uploader, err := urepo.Create(t.Context(), shortName(t, "up_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create uploader: %v", err)
	}

	r := gin.New()
	r.POST("/api/upload", func(c *gin.Context) {
		c.Set("userID", uploader.ID)
		c.Set("role", "user")
		h.Upload(c)
	})
	r.GET("/api/files/:id", func(c *gin.Context) {
		c.Set("userID", uploader.ID)
		c.Set("role", "user")
		h.Download(c)
	})

	// 上传一个 txt 文件
	fileID := uploadMultipartFile(t, r, uploader.ID, "note.txt", "text/plain", []byte("hello world"))

	// 下载并校验头
	req := httptest.NewRequest("GET", "/api/files/"+fileID, nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("download: expected 200, got %d body=%s", w.Code, w.Body.String())
	}

	cd := w.Header().Get("Content-Disposition")
	if !strings.Contains(cd, "attachment") {
		t.Errorf("Content-Disposition = %q, 应含 'attachment'（防 inline 渲染 XSS）", cd)
	}
	if nosniff := w.Header().Get("X-Content-Type-Options"); nosniff != "nosniff" {
		t.Errorf("X-Content-Type-Options = %q, want 'nosniff'（防 MIME sniffing）", nosniff)
	}
}
