package handler

import (
	"archive/zip"
	"bytes"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
	"github.com/wanling/server/internal/storage"
)

// mpTestManifest 小程序包内 manifest.json 模板(appid/version 由测试注入)。
const mpTestManifest = `{"appid":"%s","name":"Hello","version":%d,"entry":"index.html","permissions":["wanling.api"],"minHostVersion":"1.6.3"}`

// buildTestZip 构造合法小程序 zip 包(manifest.json + index.html)。
func buildTestZip(t *testing.T, appid string, version int) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	files := map[string]string{
		"manifest.json": fmt.Sprintf(mpTestManifest, appid, version),
		"index.html":    "<html><body>hello</body></html>",
	}
	for name, content := range files {
		fw, err := zw.Create(name)
		if err != nil {
			t.Fatalf("zip create %s: %v", name, err)
		}
		if _, err := fw.Write([]byte(content)); err != nil {
			t.Fatalf("zip write %s: %v", name, err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("zip close: %v", err)
	}
	return buf.Bytes()
}

// mpUserName 测试用户名:tag + uuid 片段(同测试内多用户不冲突,≤64 字符)。
func mpUserName(tag string) string {
	return tag + "_" + uuid.NewString()[:8]
}

// mpEnv 小程序 handler 测试环境(独立测试库 + 本地临时存储)。
type mpEnv struct {
	h    *MiniProgramHandler
	repo *repository.MiniProgramRepo
	ur   *repository.UserRepo
}

func newMPEnv(t *testing.T) *mpEnv {
	t.Helper()
	db := repository.SetupTestDB(t)
	ur := repository.NewUserRepo(db)
	fr := repository.NewFileRepo(db)
	repo := repository.NewMiniProgramRepo(db)
	st, err := storage.NewLocalStorage(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocalStorage: %v", err)
	}
	return &mpEnv{h: NewMiniProgramHandler(repo, fr, st, 20<<20), repo: repo, ur: ur}
}

func (e *mpEnv) user(t *testing.T, tag string) *model.User {
	t.Helper()
	u, err := e.ur.Create(t.Context(), mpUserName(tag), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	return u
}

// mpSrv 注册全部小程序路由,身份经闭包变量注入(规避 gin 重复注册 panic,
// 仿 file_handler_test.go 的 curUser/curRole 模式)。
type mpSrv struct {
	t       *testing.T
	r       *gin.Engine
	curUser string
	curRole string
}

func (e *mpEnv) newSrv(t *testing.T) *mpSrv {
	t.Helper()
	s := &mpSrv{t: t, r: gin.New()}
	auth := func(c *gin.Context) {
		c.Set("userID", s.curUser)
		c.Set("role", s.curRole)
	}
	s.r.POST("/api/mini-programs", func(c *gin.Context) { auth(c); e.h.Upload(c) })
	s.r.GET("/api/mini-programs", func(c *gin.Context) { auth(c); e.h.List(c) })
	s.r.GET("/api/mini-programs/:id/package", func(c *gin.Context) { auth(c); e.h.DownloadPackage(c) })
	s.r.DELETE("/api/mini-programs/:id", func(c *gin.Context) { auth(c); e.h.Delete(c) })
	s.r.PUT("/api/mini-programs/:id/status", func(c *gin.Context) { auth(c); e.h.UpdateStatus(c) })
	return s
}

// as 切换当前请求身份(等价 AuthMiddleware 写入的 userID/role)。
func (s *mpSrv) as(userID, role string) { s.curUser, s.curRole = userID, role }

func (s *mpSrv) do(req *http.Request) *httptest.ResponseRecorder {
	s.t.Helper()
	w := httptest.NewRecorder()
	s.r.ServeHTTP(w, req)
	return w
}

// mpUploadReq 构造 multipart 上传请求,字段名 file(与 Upload 的 FormFile("file") 对齐)。
func mpUploadReq(t *testing.T, zipBytes []byte) *http.Request {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, err := mw.CreateFormFile("file", "hello.zip")
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	if _, err := fw.Write(zipBytes); err != nil {
		t.Fatalf("write form file: %v", err)
	}
	if err := mw.Close(); err != nil {
		t.Fatalf("close multipart: %v", err)
	}
	req := httptest.NewRequest("POST", "/api/mini-programs", &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	return req
}

// mpStatusReq 构造状态流转 JSON 请求。
func mpStatusReq(id, status string) *http.Request {
	body := fmt.Sprintf(`{"status":%q}`, status)
	req := httptest.NewRequest("PUT", "/api/mini-programs/"+id+"/status", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	return req
}

// TestMiniProgramHandler_Upload_ThenVisibleToOwnerOnly 验证上传即建私有,
// owner 列表可见(published 全量 + 自己的,含 private)。
func TestMiniProgramHandler_Upload_ThenVisibleToOwnerOnly(t *testing.T) {
	e := newMPEnv(t)
	s := e.newSrv(t)
	u := e.user(t, "mua")
	s.as(u.ID, "user")
	appid := "mp-" + uuid.NewString()[:8]

	w := s.do(mpUploadReq(t, buildTestZip(t, appid, 1)))
	data := AssertOk(t, w, http.StatusCreated)
	if id, _ := data["id"].(string); id == "" {
		t.Fatalf("upload 响应缺 id 字段: %s", w.Body.String())
	}

	// owner 可见且状态 private
	items := AssertOkList(t, s.do(httptest.NewRequest("GET", "/api/mini-programs", nil)), http.StatusOK)
	found := false
	for _, it := range items {
		m := it.(map[string]any)
		if m["appid"] == appid && m["status"] == "private" {
			found = true
		}
	}
	if !found {
		t.Errorf("owner 列表应含 private 小程序 %s: %v", appid, items)
	}
}

// TestMiniProgramHandler_Upload_DuplicateAppidByOther_403 验证 appid 归属判定:
// 他人上传同 appid → 403,不得覆盖他人小程序。
func TestMiniProgramHandler_Upload_DuplicateAppidByOther_403(t *testing.T) {
	e := newMPEnv(t)
	s := e.newSrv(t)
	u1, u2 := e.user(t, "mub"), e.user(t, "muc")
	appid := "mp-" + uuid.NewString()[:8]

	s.as(u1.ID, "user")
	if w := s.do(mpUploadReq(t, buildTestZip(t, appid, 1))); w.Code != http.StatusCreated {
		t.Fatalf("首次上传应 201: %d %s", w.Code, w.Body.String())
	}
	s.as(u2.ID, "user")
	AssertErr(t, s.do(mpUploadReq(t, buildTestZip(t, appid, 1))), http.StatusForbidden, "forbidden")
}

// TestMiniProgramHandler_Upload_InvalidZip_400 验证非法包内容 fail fast → 400。
func TestMiniProgramHandler_Upload_InvalidZip_400(t *testing.T) {
	e := newMPEnv(t)
	s := e.newSrv(t)
	u := e.user(t, "mud")
	s.as(u.ID, "user")
	AssertErr(t, s.do(mpUploadReq(t, []byte("not a zip"))), http.StatusBadRequest, "invalid_package")
}

// TestMiniProgramHandler_StatusTransition_InvalidTransition409_ThenPublish200
// 验证状态流转白名单(handler 不自检 admin,鉴权由路由组中间件保证):
//   - private→disabled 非法流转 → 409
//   - private→published 合法流转 → 200,落库生效
func TestMiniProgramHandler_StatusTransition_InvalidTransition409_ThenPublish200(t *testing.T) {
	e := newMPEnv(t)
	s := e.newSrv(t)
	u := e.user(t, "mue")
	s.as(u.ID, "user")
	appid := "mp-" + uuid.NewString()[:8]

	wu := s.do(mpUploadReq(t, buildTestZip(t, appid, 1)))
	id, _ := AssertOk(t, wu, http.StatusCreated)["id"].(string)
	if id == "" {
		t.Fatalf("upload 响应缺 id: %s", wu.Body.String())
	}

	// 非法流转 private→disabled → 409
	AssertErr(t, s.do(mpStatusReq(id, "disabled")), http.StatusConflict, "invalid_transition")

	// 合法流转 private→published → 200
	if w := s.do(mpStatusReq(id, "published")); w.Code != http.StatusOK {
		t.Fatalf("publish 应 200: %d %s", w.Code, w.Body.String())
	}

	mp, err := e.repo.GetByID(t.Context(), id)
	if err != nil || mp == nil {
		t.Fatalf("GetByID: err=%v mp=%v", err, mp)
	}
	if mp.Status != "published" {
		t.Errorf("状态应 published,实际 %s", mp.Status)
	}
}

// TestMiniProgramHandler_DownloadPackage_And_Delete_Permissions 验证:
//   - 包下载:owner 私有可下,published 全员可下,他人私有 403
//   - 删除:仅 owner 自己的 private 可删,其余 409
func TestMiniProgramHandler_DownloadPackage_And_Delete_Permissions(t *testing.T) {
	e := newMPEnv(t)
	s := e.newSrv(t)
	u1, u2 := e.user(t, "muf"), e.user(t, "mug")
	appid := "mp-" + uuid.NewString()[:8]
	zipBytes := buildTestZip(t, appid, 1)

	s.as(u1.ID, "user")
	wu := s.do(mpUploadReq(t, zipBytes))
	id, _ := AssertOk(t, wu, http.StatusCreated)["id"].(string)

	// owner 下载私有包 → 200 且字节一致
	if w := s.do(httptest.NewRequest("GET", "/api/mini-programs/"+id+"/package", nil)); w.Code != http.StatusOK {
		t.Fatalf("owner 下载私有包应 200: %d %s", w.Code, w.Body.String())
	} else if !bytes.Equal(w.Body.Bytes(), zipBytes) {
		t.Errorf("下载内容与上传不一致: got %d bytes, want %d bytes", w.Body.Len(), len(zipBytes))
	}

	// 他人下载私有包 → 403
	s.as(u2.ID, "user")
	AssertErr(t, s.do(httptest.NewRequest("GET", "/api/mini-programs/"+id+"/package", nil)),
		http.StatusForbidden, "forbidden")

	// 他人删除 → 409(非 owner)
	AssertErr(t, s.do(httptest.NewRequest("DELETE", "/api/mini-programs/"+id, nil)),
		http.StatusConflict, "invalid_state")

	// 发布后他人下载 → 200
	s.as(u1.ID, "user")
	if w := s.do(mpStatusReq(id, "published")); w.Code != http.StatusOK {
		t.Fatalf("publish 应 200: %d %s", w.Code, w.Body.String())
	}
	s.as(u2.ID, "user")
	if w := s.do(httptest.NewRequest("GET", "/api/mini-programs/"+id+"/package", nil)); w.Code != http.StatusOK {
		t.Fatalf("他人下载 published 包应 200: %d %s", w.Code, w.Body.String())
	}

	// owner 删 published(非 private)→ 409
	s.as(u1.ID, "user")
	AssertErr(t, s.do(httptest.NewRequest("DELETE", "/api/mini-programs/"+id, nil)),
		http.StatusConflict, "invalid_state")
}
