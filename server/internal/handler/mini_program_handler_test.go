package handler

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/hex"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/wanling/server/internal/miniprogram"
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
	skr  *repository.SigningKeyRepo
	fr   *repository.FileRepo
	st   storage.Provider
	ur   *repository.UserRepo
}

func newMPEnv(t *testing.T) *mpEnv {
	t.Helper()
	db := repository.SetupTestDB(t)
	ur := repository.NewUserRepo(db)
	fr := repository.NewFileRepo(db)
	repo := repository.NewMiniProgramRepo(db)
	skr := repository.NewSigningKeyRepo(db)
	st, err := storage.NewLocalStorage(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocalStorage: %v", err)
	}
	return &mpEnv{h: NewMiniProgramHandler(repo, skr, fr, st, 20<<20), repo: repo, skr: skr, fr: fr, st: st, ur: ur}
}

// readPackage 经 fileRepo + storage 读包文件全部字节(验签断言用)。
func (e *mpEnv) readPackage(ctx context.Context, packageFileID string) ([]byte, error) {
	f, err := e.fr.GetByID(ctx, packageFileID)
	if err != nil || f == nil {
		return nil, fmt.Errorf("包文件缺失: %w", err)
	}
	r, err := e.st.Read(f.StoragePath)
	if err != nil {
		return nil, fmt.Errorf("读包失败: %w", err)
	}
	defer r.Close()
	return io.ReadAll(r)
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
// 仿 file_handler_test.go 的 curUser/curRole/curOwner 模式)。
type mpSrv struct {
	t        *testing.T
	r        *gin.Engine
	curUser  string
	curRole  string
	curOwner string
}

func (e *mpEnv) newSrv(t *testing.T) *mpSrv {
	t.Helper()
	s := &mpSrv{t: t, r: gin.New()}
	auth := func(c *gin.Context) {
		c.Set("userID", s.curUser)
		c.Set("role", s.curRole)
		if s.curOwner != "" {
			c.Set("ownerID", s.curOwner)
		}
	}
	s.r.POST("/api/mini-programs", func(c *gin.Context) { auth(c); e.h.Upload(c) })
	s.r.GET("/api/mini-programs", func(c *gin.Context) { auth(c); e.h.List(c) })
	s.r.GET("/api/mini-programs/signing-key", func(c *gin.Context) { auth(c); e.h.GetSigningKey(c) })
	s.r.GET("/api/mini-programs/:id/package", func(c *gin.Context) { auth(c); e.h.DownloadPackage(c) })
	s.r.GET("/api/mini-programs/:id/icon", func(c *gin.Context) { auth(c); e.h.GetIcon(c) })
	s.r.DELETE("/api/mini-programs/:id", func(c *gin.Context) { auth(c); e.h.Delete(c) })
	s.r.PUT("/api/mini-programs/:id/status", func(c *gin.Context) { auth(c); e.h.UpdateStatus(c) })
	return s
}

// as 切换当前请求身份(等价 AuthMiddleware 写入的 userID/role)。
func (s *mpSrv) as(userID, role string) { s.curUser, s.curRole, s.curOwner = userID, role, "" }

// asAgent 切换为 agent 身份(agent token 的 sub 是 agent_id,ownerID 是其服务的 user,
// 等价 AuthMiddleware 对 agent 角色写入的 userID/role/ownerID)。
func (s *mpSrv) asAgent(agentID, ownerID string) {
	s.curUser, s.curRole, s.curOwner = agentID, "agent", ownerID
}

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

// TestMiniProgramHandler_Upload_ByAgent_OwnerIsUser 验证 agent 直传(M2):
// 包 owner 落库为 agent 服务的真实用户(而非 agent_id——不在 users 表,直接落会
// 触发 users FK 约束)。
func TestMiniProgramHandler_Upload_ByAgent_OwnerIsUser(t *testing.T) {
	e := newMPEnv(t)
	s := e.newSrv(t)
	owner := e.user(t, "muh")
	appid := "mp-" + uuid.NewString()[:8]

	s.asAgent("agent-"+uuid.NewString()[:8], owner.ID)
	w := s.do(mpUploadReq(t, buildTestZip(t, appid, 1)))
	id, _ := AssertOk(t, w, http.StatusCreated)["id"].(string)
	if id == "" {
		t.Fatalf("upload 响应缺 id: %s", w.Body.String())
	}

	mp, err := e.repo.GetByID(t.Context(), id)
	if err != nil || mp == nil {
		t.Fatalf("GetByID: err=%v mp=%v", err, mp)
	}
	if mp.OwnerID != owner.ID {
		t.Errorf("owner 应为用户 %s,实际 %s", owner.ID, mp.OwnerID)
	}
}

// TestMiniProgramHandler_Download_ByAgent_OwnersPrivate_OK 验证 agent(M2):
// 可下载其 owner 的私有包(200 + X-Mini-Program-Sha256 头 + 字节一致)。
func TestMiniProgramHandler_Download_ByAgent_OwnersPrivate_OK(t *testing.T) {
	e := newMPEnv(t)
	s := e.newSrv(t)
	owner := e.user(t, "mui")
	appid := "mp-" + uuid.NewString()[:8]
	zipBytes := buildTestZip(t, appid, 1)

	s.as(owner.ID, "user")
	wu := s.do(mpUploadReq(t, zipBytes))
	id, _ := AssertOk(t, wu, http.StatusCreated)["id"].(string)

	s.asAgent("agent-"+uuid.NewString()[:8], owner.ID)
	w := s.do(httptest.NewRequest("GET", "/api/mini-programs/"+id+"/package", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("agent 下载 owner 私有包应 200,实际 %d %s", w.Code, w.Body.String())
	}
	if w.Header().Get("X-Mini-Program-Sha256") == "" {
		t.Errorf("下载响应应带 X-Mini-Program-Sha256 头")
	}
	if !bytes.Equal(w.Body.Bytes(), zipBytes) {
		t.Errorf("下载内容与上传不一致: got %d bytes, want %d bytes", w.Body.Len(), len(zipBytes))
	}
}

// TestMiniProgramHandler_Download_ByAgent_OthersPrivate_403 验证 agent(M2):
// ownerID 指向无关用户时,不能下载他人私有包(归属校验按换算后的 owner 判定)。
func TestMiniProgramHandler_Download_ByAgent_OthersPrivate_403(t *testing.T) {
	e := newMPEnv(t)
	s := e.newSrv(t)
	u1, u2 := e.user(t, "muj"), e.user(t, "muk")
	appid := "mp-" + uuid.NewString()[:8]

	s.as(u1.ID, "user")
	wu := s.do(mpUploadReq(t, buildTestZip(t, appid, 1)))
	id, _ := AssertOk(t, wu, http.StatusCreated)["id"].(string)

	s.asAgent("agent-"+uuid.NewString()[:8], u2.ID)
	AssertErr(t, s.do(httptest.NewRequest("GET", "/api/mini-programs/"+id+"/package", nil)),
		http.StatusForbidden, "forbidden")
}

// mpPublish 上传 + 发布,返回小程序 ID(签名链路测试的公共前置)。
func mpPublish(t *testing.T, e *mpEnv, s *mpSrv, appid string, zipBytes []byte) string {
	t.Helper()
	id, _ := AssertOk(t, s.do(mpUploadReq(t, zipBytes)), http.StatusCreated)["id"].(string)
	if id == "" {
		t.Fatalf("upload 响应缺 id")
	}
	if w := s.do(mpStatusReq(id, "published")); w.Code != http.StatusOK {
		t.Fatalf("publish 应 200: %d %s", w.Code, w.Body.String())
	}
	return id
}

// TestMiniProgramHandler_Publish_SignsPackage 验证 M3:publish 后 signature 非空,
// 列表 DTO 带签名,且签名可用公钥对包字节验签通过。
func TestMiniProgramHandler_Publish_SignsPackage(t *testing.T) {
	e := newMPEnv(t)
	s := e.newSrv(t)
	u := e.user(t, "mu1")
	s.as(u.ID, "user")
	appid := "mp-" + uuid.NewString()[:8]
	zipBytes := buildTestZip(t, appid, 1)

	id := mpPublish(t, e, s, appid, zipBytes)

	mp, err := e.repo.GetByID(t.Context(), id)
	if err != nil || mp == nil {
		t.Fatalf("GetByID: err=%v mp=%v", err, mp)
	}
	if mp.Signature == "" {
		t.Fatalf("publish 后 signature 应非空")
	}

	// 列表 DTO 带 signature
	items := AssertOkList(t, s.do(httptest.NewRequest("GET", "/api/mini-programs", nil)), http.StatusOK)
	found := false
	for _, it := range items {
		m := it.(map[string]any)
		if m["appid"] == appid {
			found = true
			if sig, _ := m["signature"].(string); sig == "" {
				t.Errorf("列表 DTO 应带 signature: %v", m)
			}
		}
	}
	if !found {
		t.Fatalf("列表应含已发布小程序 %s: %v", appid, items)
	}

	// 公钥对包字节验签:Verify 通过;tamper 后必须失败
	key, err := e.skr.Ensure(t.Context())
	if err != nil {
		t.Fatalf("Ensure: %v", err)
	}
	data, err := e.readPackage(t.Context(), mp.PackageFileID)
	if err != nil {
		t.Fatalf("读包: %v", err)
	}
	if err := miniprogram.Verify(key.PublicKey, data, mp.Signature); err != nil {
		t.Errorf("验签应通过: %v", err)
	}
	if err := miniprogram.Verify(key.PublicKey, append(data, 'x'), mp.Signature); err == nil {
		t.Errorf("篡改字节后验签应失败")
	}
}

// TestMiniProgramHandler_SigningKey_Endpoint 验证 GET /signing-key 返回
// ok:true + public_key(hex 64 字符,ed25519 公钥 32 字节)。
func TestMiniProgramHandler_SigningKey_Endpoint(t *testing.T) {
	e := newMPEnv(t)
	s := e.newSrv(t)
	u := e.user(t, "mu2")
	s.as(u.ID, "user")

	data := AssertOk(t, s.do(httptest.NewRequest("GET", "/api/mini-programs/signing-key", nil)), http.StatusOK)
	pub, _ := data["public_key"].(string)
	if len(pub) != 64 {
		t.Fatalf("public_key 应为 hex 64 字符,实际 %d: %q", len(pub), pub)
	}
	if _, err := hex.DecodeString(pub); err != nil {
		t.Errorf("public_key 应为合法 hex: %v", err)
	}

	// 幂等:二次请求返回同一把公钥
	data2 := AssertOk(t, s.do(httptest.NewRequest("GET", "/api/mini-programs/signing-key", nil)), http.StatusOK)
	if data2["public_key"] != pub {
		t.Errorf("signing-key 应幂等: %v != %v", data2["public_key"], pub)
	}
}

// TestMiniProgramHandler_Disable_KeepsSignature 验证 published→disabled
// 状态流转不重签不擦除:signature 原样保留且仍可对包字节验签通过。
func TestMiniProgramHandler_Disable_KeepsSignature(t *testing.T) {
	e := newMPEnv(t)
	s := e.newSrv(t)
	u := e.user(t, "mu3")
	s.as(u.ID, "user")
	appid := "mp-" + uuid.NewString()[:8]

	id := mpPublish(t, e, s, appid, buildTestZip(t, appid, 1))
	before, err := e.repo.GetByID(t.Context(), id)
	if err != nil || before == nil || before.Signature == "" {
		t.Fatalf("publish 后应已签名: err=%v mp=%v", err, before)
	}

	if w := s.do(mpStatusReq(id, "disabled")); w.Code != http.StatusOK {
		t.Fatalf("disable 应 200: %d %s", w.Code, w.Body.String())
	}
	after, err := e.repo.GetByID(t.Context(), id)
	if err != nil || after == nil {
		t.Fatalf("GetByID: err=%v mp=%v", err, after)
	}
	if after.Status != "disabled" {
		t.Errorf("状态应 disabled,实际 %s", after.Status)
	}
	if after.Signature != before.Signature {
		t.Errorf("disable 不应动 signature: before=%q after=%q", before.Signature, after.Signature)
	}

	// 签名仍可对包字节验签(包字节未变)
	key, err := e.skr.Ensure(t.Context())
	if err != nil {
		t.Fatalf("Ensure: %v", err)
	}
	data, err := e.readPackage(t.Context(), after.PackageFileID)
	if err != nil {
		t.Fatalf("读包: %v", err)
	}
	if err := miniprogram.Verify(key.PublicKey, data, after.Signature); err != nil {
		t.Errorf("disable 后签名仍应可验: %v", err)
	}
}

// testPngBytes 与 miniprogram/validate_test.go 保持同步(合法 8x8 PNG 头尾齐全)。
var testPngBytes = []byte{
	0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
	'I', 'H', 'D', 'R', 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x08,
	0x08, 0x06, 0x00, 0x00, 0x00, 0xC3, 0x0F, 0x9A, 0x62,
}

// buildTestZipWithIcon 构造带 icon.png 的测试包(manifest.icon 指向包内路径)。
func buildTestZipWithIcon(t *testing.T, appid string, version int, iconBytes []byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	files := map[string][]byte{
		"manifest.json": []byte(fmt.Sprintf(`{"appid":%q,"name":"图标包","version":%d,"entry":"index.html","icon":"icon.png"}`, appid, version)),
		"index.html":    []byte("<html><body>hello</body></html>"),
		"icon.png":      iconBytes,
	}
	for name, content := range files {
		fw, err := zw.Create(name)
		if err != nil {
			t.Fatalf("zip create %s: %v", name, err)
		}
		if _, err := fw.Write(content); err != nil {
			t.Fatalf("zip write %s: %v", name, err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("zip close: %v", err)
	}
	return buf.Bytes()
}

func TestMiniProgramHandler_Icon_UploadDownload(t *testing.T) {
	e := newMPEnv(t)
	s := e.newSrv(t)
	u := e.user(t, "mpu")
	s.as(u.ID, "user")
	appid := "mp-" + uuid.NewString()[:8]

	w := s.do(mpUploadReq(t, buildTestZipWithIcon(t, appid, 1, testPngBytes)))
	data := AssertOk(t, w, http.StatusCreated)
	id, _ := data["id"].(string)
	if id == "" {
		t.Fatalf("upload 响应缺 id: %s", w.Body.String())
	}

	// 列表 icon 字段应为相对 URL(带版本快照参数)
	items := AssertOkList(t, s.do(httptest.NewRequest("GET", "/api/mini-programs", nil)), http.StatusOK)
	var gotURL string
	for _, it := range items {
		m := it.(map[string]any)
		if m["appid"] == appid {
			gotURL, _ = m["icon"].(string)
		}
	}
	if want := "/api/mini-programs/" + id + "/icon?v=1"; gotURL != want {
		t.Fatalf("列表 icon 应为 %q, got %q", want, gotURL)
	}

	// icon 端点:200 + Content-Type + 字节一致
	w = s.do(httptest.NewRequest("GET", "/api/mini-programs/"+id+"/icon", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("icon 端点应 200, got %d: %s", w.Code, w.Body.String())
	}
	if ct := w.Header().Get("Content-Type"); ct != "image/png" {
		t.Fatalf("Content-Type 应 image/png, got %q", ct)
	}
	if cc := w.Header().Get("Cache-Control"); cc != "public, max-age=86400" {
		t.Fatalf("Cache-Control 应 public, max-age=86400, got %q", cc)
	}
	if !bytes.Equal(w.Body.Bytes(), testPngBytes) {
		t.Fatalf("icon 字节应与包内一致")
	}
}

func TestMiniProgramHandler_Icon_无icon包404(t *testing.T) {
	e := newMPEnv(t)
	s := e.newSrv(t)
	u := e.user(t, "mpn")
	s.as(u.ID, "user")
	appid := "mp-" + uuid.NewString()[:8]
	w := s.do(mpUploadReq(t, buildTestZip(t, appid, 1)))
	data := AssertOk(t, w, http.StatusCreated)
	id, _ := data["id"].(string)

	if code := s.do(httptest.NewRequest("GET", "/api/mini-programs/"+id+"/icon", nil)).Code; code != http.StatusNotFound {
		t.Fatalf("无 icon 包 icon 端点应 404, got %d", code)
	}
	// 列表 icon 字段应为空串
	items := AssertOkList(t, s.do(httptest.NewRequest("GET", "/api/mini-programs", nil)), http.StatusOK)
	for _, it := range items {
		m := it.(map[string]any)
		if m["appid"] == appid && m["icon"] != "" {
			t.Fatalf("无 icon 包列表 icon 应空串, got %q", m["icon"])
		}
	}
}

func TestMiniProgramHandler_Icon_他人private包403(t *testing.T) {
	e := newMPEnv(t)
	s := e.newSrv(t)
	owner := e.user(t, "mpo")
	other := e.user(t, "mpp")
	s.as(owner.ID, "user")
	appid := "mp-" + uuid.NewString()[:8]
	w := s.do(mpUploadReq(t, buildTestZipWithIcon(t, appid, 1, testPngBytes)))
	data := AssertOk(t, w, http.StatusCreated)
	id, _ := data["id"].(string)

	s.as(other.ID, "user")
	if code := s.do(httptest.NewRequest("GET", "/api/mini-programs/"+id+"/icon", nil)).Code; code != http.StatusForbidden {
		t.Fatalf("他人 private icon 应 403, got %d", code)
	}
}
