// 小程序云数据五端点 handler 测试(真库 SetupTestDB + httptest+gin)。
// 复用 mini_program_handler_test.go 的模式:身份经闭包变量注入
// (curUser/curRole/curOwner,等价 AuthMiddleware 写入的 gin.Context 字段),
// seed 走真实上传/发布链路(MiniProgramHandler.Upload/UpdateStatus)。
package handler

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/wanling/server/internal/config"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
	"github.com/wanling/server/internal/storage"
)

// stStorageManifest 带 collections 档位声明的 manifest 模板:
// notes=shared_read(公告栏),board=shared_write(白板),default 档隐含 private。
const stStorageManifest = `{"appid":"%s","name":"Store","version":1,"entry":"index.html","permissions":["wanling.storage"],"collections":[{"name":"notes","mode":"shared_read"},{"name":"board","mode":"shared_write"}]}`

// buildStorageZip 构造带 collections 声明的合法小程序 zip 包。
func buildStorageZip(t *testing.T, appid string) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	files := map[string]string{
		"manifest.json": fmt.Sprintf(stStorageManifest, appid),
		"index.html":    "<html><body>store</body></html>",
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

// storageCfg 测试用云数据配置;appBytes 参数注入极小总帽(quota-413 用例)。
func storageCfg(appBytes int64) config.MiniProgramConfig {
	return config.MiniProgramConfig{
		MaxZipBytes:          20 << 20,
		StorageAppBytes:      appBytes,
		StorageAppEntries:    50000,
		StorageMyBytes:       20 << 20,
		StorageMyEntries:     5000,
		StorageMaxValueBytes: 256 << 10,
	}
}

// mpStorageEnv 云数据 handler 测试环境(独立测试库 + 本地临时存储)。
type mpStorageEnv struct {
	sh     *MiniProgramStorageHandler
	mpH    *MiniProgramHandler
	ur     *repository.UserRepo
	mpRepo *repository.MiniProgramRepo
}

func newStorageEnv(t *testing.T, cfg config.MiniProgramConfig) *mpStorageEnv {
	t.Helper()
	db := repository.SetupTestDB(t)
	ur := repository.NewUserRepo(db)
	fr := repository.NewFileRepo(db)
	mpRepo := repository.NewMiniProgramRepo(db)
	skr := repository.NewSigningKeyRepo(db)
	openidRepo := repository.NewMiniProgramOpenidRepo(db)
	dataRepo := repository.NewMiniProgramDataRepo(db)
	st, err := storage.NewLocalStorage(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocalStorage: %v", err)
	}
	return &mpStorageEnv{
		sh:     NewMiniProgramStorageHandler(dataRepo, mpRepo, openidRepo, cfg, nil),
		mpH:    NewMiniProgramHandler(mpRepo, skr, fr, st, cfg.MaxZipBytes, openidRepo),
		ur:     ur,
		mpRepo: mpRepo,
	}
}

func (e *mpStorageEnv) user(t *testing.T, tag string) *model.User {
	t.Helper()
	u, err := e.ur.Create(t.Context(), mpUserName(tag), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	return u
}

// mpStorageSrv 注册云数据五端点 + seed 用的上传/发布路由,
// 身份经闭包变量注入(仿 mpSrv 模式)。
type mpStorageSrv struct {
	t        *testing.T
	r        *gin.Engine
	curUser  string
	curRole  string
	curOwner string
}

func (e *mpStorageEnv) newSrv(t *testing.T) *mpStorageSrv {
	t.Helper()
	s := &mpStorageSrv{t: t, r: gin.New()}
	auth := func(c *gin.Context) {
		c.Set("userID", s.curUser)
		c.Set("role", s.curRole)
		if s.curOwner != "" {
			c.Set("ownerID", s.curOwner)
		}
	}
	// seed 链路:上传 + 发布(复用 MiniProgramHandler)
	s.r.POST("/api/mini-programs", func(c *gin.Context) { auth(c); e.mpH.Upload(c) })
	s.r.PUT("/api/mini-programs/:id/status", func(c *gin.Context) { auth(c); e.mpH.UpdateStatus(c) })
	// 被测五端点(路径与 main.go mpAuth 组逐字一致)
	s.r.GET("/api/mini-program-storage/:appid/entries", func(c *gin.Context) { auth(c); e.sh.ListEntries(c) })
	s.r.GET("/api/mini-program-storage/:appid/entries/:key", func(c *gin.Context) { auth(c); e.sh.GetEntry(c) })
	s.r.GET("/api/mini-program-storage/:appid/quota", func(c *gin.Context) { auth(c); e.sh.GetQuota(c) })
	s.r.PUT("/api/mini-program-storage/:appid/entries/:key", func(c *gin.Context) { auth(c); e.sh.PutEntry(c) })
	s.r.DELETE("/api/mini-program-storage/:appid/entries/:key", func(c *gin.Context) { auth(c); e.sh.DeleteEntry(c) })
	return s
}

// as 切换当前请求身份(等价 AuthMiddleware 写入的 userID/role)。
func (s *mpStorageSrv) as(userID, role string) { s.curUser, s.curRole, s.curOwner = userID, role, "" }

// asAgent 切换为 agent 身份(sub=agent_id,ownerID=其服务的用户)。
func (s *mpStorageSrv) asAgent(agentID, ownerID string) {
	s.curUser, s.curRole, s.curOwner = agentID, "agent", ownerID
}

func (s *mpStorageSrv) do(req *http.Request) *httptest.ResponseRecorder {
	s.t.Helper()
	w := httptest.NewRecorder()
	s.r.ServeHTTP(w, req)
	return w
}

// seedApp 以当前身份上传带 collections 的小程序并按需发布。
func (s *mpStorageSrv) seedApp(t *testing.T, appid string, publish bool) {
	t.Helper()
	w := s.do(mpUploadReq(t, buildStorageZip(t, appid)))
	data := AssertOk(t, w, http.StatusCreated)
	id, _ := data["id"].(string)
	if id == "" {
		t.Fatalf("seed 上传失败: %s", w.Body.String())
	}
	if publish {
		if w := s.do(mpStatusReq(id, "published")); w.Code != http.StatusOK {
			t.Fatalf("seed 发布失败: %d %s", w.Code, w.Body.String())
		}
	}
}

// stEntryURL 拼云数据端点 URL;key 空串为列表端点;kv 为附加 query 参数对。
func stEntryURL(appid, key, coll string, kv ...string) string {
	u := "/api/mini-program-storage/" + appid + "/entries"
	if key != "" {
		u += "/" + url.PathEscape(key)
	}
	q := url.Values{}
	if coll != "" {
		q.Set("coll", coll)
	}
	for i := 0; i+1 < len(kv); i += 2 {
		q.Set(kv[i], kv[i+1])
	}
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	return u
}

// stPut 构造 PUT 写入请求(body 为 {"value":...} JSON)。
func stPut(appid, key, coll, body string) *http.Request {
	req := httptest.NewRequest("PUT", stEntryURL(appid, key, coll), strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	return req
}

// stGet 构造 GET 单键请求。
func stGet(appid, key, coll string) *http.Request {
	return httptest.NewRequest("GET", stEntryURL(appid, key, coll), nil)
}

// stList 构造 GET 列表请求。
func stList(appid, coll string, kv ...string) *http.Request {
	return httptest.NewRequest("GET", stEntryURL(appid, "", coll, kv...), nil)
}

// stAppid 生成唯一测试 appid(appid 正则 ^[a-z0-9][a-z0-9-]{2,31}$)。
func stAppid() string { return "st-" + uuid.NewString()[:8] }

// stValueEqual 断言响应 data.value 与期望 JSON 语义等价(jsonb 读回为规范化字节,
// 不能做字节级比较,双方都走 json 反序列化后比对)。
func stValueEqual(t *testing.T, got any, want string) {
	t.Helper()
	var wantAny any
	if err := json.Unmarshal([]byte(want), &wantAny); err != nil {
		t.Fatalf("期望值非法 JSON: %v", err)
	}
	var gotRaw []byte
	gotRaw, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("序列化实际值失败: %v", err)
	}
	var gotAny any
	if err := json.Unmarshal(gotRaw, &gotAny); err != nil {
		t.Fatalf("实际值非法 JSON: %v", err)
	}
	if fmt.Sprint(gotAny) != fmt.Sprint(wantAny) {
		t.Errorf("value 不一致: got %s want %s", gotRaw, want)
	}
}

// stListPage 断言列表响应并解包 data:{items,next_cursor} 形状
// (集合+游标的形状例外,游标走 body 而非响应头)。
// 返回 items 与 next_cursor 原值:有下页为 string,末页为 nil(null)。
func stListPage(t *testing.T, w *httptest.ResponseRecorder) ([]any, any) {
	t.Helper()
	data := AssertOk(t, w, http.StatusOK)
	items, ok := data["items"].([]any)
	if !ok {
		t.Fatalf("data.items 应为数组: %s", w.Body.String())
	}
	return items, data["next_cursor"]
}

// 用例 1:private 档(default coll)PUT → GET 往返,响应形状齐全。
func TestStorage_PutGet_Roundtrip(t *testing.T) {
	e := newStorageEnv(t, storageCfg(100<<20))
	s := e.newSrv(t)
	owner := e.user(t, "st1")
	s.as(owner.ID, "user")
	appid := stAppid()
	s.seedApp(t, appid, true)

	w := s.do(stPut(appid, "k1", "", `{"value":{"n":1}}`))
	data := AssertOk(t, w, http.StatusOK)
	if data["key"] != "k1" || data["coll"] != "default" {
		t.Errorf("key/coll 应 k1/default: %v", data)
	}
	if v, _ := data["version"].(float64); v != 1 {
		t.Errorf("新写 version 应 1: %v", data)
	}
	if ua, _ := data["updated_at"].(string); ua == "" {
		t.Errorf("updated_at 应非空: %v", data)
	}
	stValueEqual(t, data["value"], `{"n":1}`)

	data2 := AssertOk(t, s.do(stGet(appid, "k1", "")), http.StatusOK)
	stValueEqual(t, data2["value"], `{"n":1}`)
	if v, _ := data2["version"].(float64); v != 1 {
		t.Errorf("回读 version 应 1: %v", data2)
	}
}

// 用例 2:private 档用户隔离——B 读不到 A 的 key(data:null),B 写自己槽位成功,
// A 的行不被 B 的同名 key 覆盖。
func TestStorage_PrivateMode_UserIsolation(t *testing.T) {
	e := newStorageEnv(t, storageCfg(100<<20))
	s := e.newSrv(t)
	a, b := e.user(t, "st2a"), e.user(t, "st2b")
	appid := stAppid()
	s.as(a.ID, "user")
	s.seedApp(t, appid, true)
	AssertOk(t, s.do(stPut(appid, "k1", "", `{"value":{"owner":"a"}}`)), http.StatusOK)

	// B 读 A 的 key → 200 + data:null(行不可见而非 403)
	s.as(b.ID, "user")
	data := AssertOk(t, s.do(stGet(appid, "k1", "")), http.StatusOK)
	if data != nil {
		t.Errorf("B 读 A 的 private key 应 data:null: %v", data)
	}
	// B 写自己的 k1 → 成功(各自成行)
	AssertOk(t, s.do(stPut(appid, "k1", "", `{"value":{"owner":"b"}}`)), http.StatusOK)
	// A 回读仍是自己的值
	s.as(a.ID, "user")
	data2 := AssertOk(t, s.do(stGet(appid, "k1", "")), http.StatusOK)
	stValueEqual(t, data2["value"], `{"owner":"a"}`)
}

// 用例 3:coll 未在 manifest 声明且 ≠ default → 400 bad_request。
func TestStorage_UndeclaredColl_Rejected(t *testing.T) {
	e := newStorageEnv(t, storageCfg(100<<20))
	s := e.newSrv(t)
	owner := e.user(t, "st3")
	s.as(owner.ID, "user")
	appid := stAppid()
	s.seedApp(t, appid, true)

	AssertErr(t, s.do(stPut(appid, "k1", "ghost", `{"value":1}`)), http.StatusBadRequest, "bad_request")
	AssertErr(t, s.do(stGet(appid, "k1", "ghost")), http.StatusBadRequest, "bad_request")
}

// 用例 4:key 含空格不匹配白名单正则 → 400。
func TestStorage_BadKey_Rejected(t *testing.T) {
	e := newStorageEnv(t, storageCfg(100<<20))
	s := e.newSrv(t)
	owner := e.user(t, "st4")
	s.as(owner.ID, "user")
	appid := stAppid()
	s.seedApp(t, appid, true)

	AssertErr(t, s.do(stPut(appid, "bad key", "", `{"value":1}`)), http.StatusBadRequest, "bad_request")
	AssertErr(t, s.do(stGet(appid, "bad key", "")), http.StatusBadRequest, "bad_request")
}

// 用例 5:shared_read 档——owner 写成功,B 可读,B 写 → 403。
func TestStorage_SharedRead_OwnerWrite_PublicRead(t *testing.T) {
	e := newStorageEnv(t, storageCfg(100<<20))
	s := e.newSrv(t)
	owner, b := e.user(t, "st5a"), e.user(t, "st5b")
	appid := stAppid()
	s.as(owner.ID, "user")
	s.seedApp(t, appid, true)

	AssertOk(t, s.do(stPut(appid, "k1", "notes", `{"value":{"msg":"hi"}}`)), http.StatusOK)

	// B 读 owner 的公告 → 命中
	data := AssertOk(t, s.do(stGet(appid, "k1", "notes")), http.StatusOK)
	stValueEqual(t, data["value"], `{"msg":"hi"}`)

	// B 写 shared_read → 403
	s.as(b.ID, "user")
	AssertErr(t, s.do(stPut(appid, "k2", "notes", `{"value":1}`)), http.StatusForbidden, "forbidden")
}

// 用例 6:shared_write 档——A(owner)/B 都能写不同 key,B 能读 A 写的行,
// B 列表同时看到两人行(双槽位合并)。
func TestStorage_SharedWrite_AllWrite(t *testing.T) {
	e := newStorageEnv(t, storageCfg(100<<20))
	s := e.newSrv(t)
	a, b := e.user(t, "st6a"), e.user(t, "st6b")
	appid := stAppid()
	s.as(a.ID, "user")
	s.seedApp(t, appid, true)

	AssertOk(t, s.do(stPut(appid, "a1", "board", `{"value":{"w":"a"}}`)), http.StatusOK)
	s.as(b.ID, "user")
	AssertOk(t, s.do(stPut(appid, "b1", "board", `{"value":{"w":"b"}}`)), http.StatusOK)

	// B 读 A 写的行
	data := AssertOk(t, s.do(stGet(appid, "a1", "board")), http.StatusOK)
	stValueEqual(t, data["value"], `{"w":"a"}`)
	// B 回读自己刚写的行
	data2 := AssertOk(t, s.do(stGet(appid, "b1", "board")), http.StatusOK)
	stValueEqual(t, data2["value"], `{"w":"b"}`)

	// B 列表含两人的行
	items, _ := stListPage(t, s.do(stList(appid, "board")))
	keys := map[string]bool{}
	for _, it := range items {
		keys[it.(map[string]any)["key"].(string)] = true
	}
	if !keys["a1"] || !keys["b1"] {
		t.Errorf("shared_write 列表应含 a1 与 b1: %v", keys)
	}
}

// 用例 7:unpublished(status=private)小程序非 owner 一律 403(读+写)。
func TestStorage_Unpublished_Forbidden(t *testing.T) {
	e := newStorageEnv(t, storageCfg(100<<20))
	s := e.newSrv(t)
	owner, b := e.user(t, "st7a"), e.user(t, "st7b")
	appid := stAppid()
	s.as(owner.ID, "user")
	s.seedApp(t, appid, false) // 不发布,保持 private

	s.as(b.ID, "user")
	AssertErr(t, s.do(stGet(appid, "k1", "")), http.StatusForbidden, "forbidden")
	AssertErr(t, s.do(stPut(appid, "k1", "", `{"value":1}`)), http.StatusForbidden, "forbidden")
	AssertErr(t, s.do(stList(appid, "")), http.StatusForbidden, "forbidden")
	// owner 本人不受影响
	s.as(owner.ID, "user")
	AssertOk(t, s.do(stPut(appid, "k1", "", `{"value":1}`)), http.StatusOK)
}

// 用例 8:PUT expected_version 不符 → 409 invalid_state。
func TestStorage_VersionConflict_409(t *testing.T) {
	e := newStorageEnv(t, storageCfg(100<<20))
	s := e.newSrv(t)
	owner := e.user(t, "st8")
	s.as(owner.ID, "user")
	appid := stAppid()
	s.seedApp(t, appid, true)

	AssertOk(t, s.do(stPut(appid, "k1", "", `{"value":1}`)), http.StatusOK)
	AssertErr(t, s.do(stPut(appid, "k1", "", `{"value":2,"expected_version":999}`)),
		http.StatusConflict, "invalid_state")
}

// 用例 9:config 极小 AppBytes → 第二写 413 payload_too_large。
func TestStorage_Quota_413(t *testing.T) {
	e := newStorageEnv(t, storageCfg(10)) // 总帽 10B
	s := e.newSrv(t)
	owner := e.user(t, "st9")
	s.as(owner.ID, "user")
	appid := stAppid()
	s.seedApp(t, appid, true)

	// {"a":1} 7 字节,首写 7 ≤ 10 通过
	AssertOk(t, s.do(stPut(appid, "k1", "", `{"value":{"a":1}}`)), http.StatusOK)
	// 第二写 7+7=14 > 10 → 413
	AssertErr(t, s.do(stPut(appid, "k2", "", `{"value":{"b":2}}`)),
		http.StatusRequestEntityTooLarge, "payload_too_large")
}

// 用例 10:列表 prefix + cursor 翻页,data:{items,next_cursor} body 断言。
// 游标必须走 body:APP 桥经 proxyRequest 只透 body,响应头到不了 JS 侧;
// 末页 next_cursor 为 null。
func TestStorage_List_PrefixCursor(t *testing.T) {
	e := newStorageEnv(t, storageCfg(100<<20))
	s := e.newSrv(t)
	owner := e.user(t, "st10")
	s.as(owner.ID, "user")
	appid := stAppid()
	s.seedApp(t, appid, true)
	for i := 1; i <= 5; i++ {
		AssertOk(t, s.do(stPut(appid, fmt.Sprintf("k%d", i), "", fmt.Sprintf(`{"value":%d}`, i))), http.StatusOK)
	}

	// 第一页:prefix=k&limit=2 → k1,k2 + next_cursor=k2
	w1 := s.do(stList(appid, "", "prefix", "k", "limit", "2"))
	items1, cur1 := stListPage(t, w1)
	if len(items1) != 2 || items1[0].(map[string]any)["key"] != "k1" || items1[1].(map[string]any)["key"] != "k2" {
		t.Errorf("第一页应 k1,k2: %v", items1)
	}
	if cur, ok := cur1.(string); !ok || cur != "k2" {
		t.Errorf("第一页 next_cursor 应 k2,实际 %v", cur1)
	}
	if h := w1.Header().Get("X-Next-Cursor"); h != "" {
		t.Errorf("不应再设 X-Next-Cursor 头,实际 %q", h)
	}

	// 第二页:cursor=k2 → k3,k4 + next_cursor=k4
	w2 := s.do(stList(appid, "", "prefix", "k", "cursor", "k2", "limit", "2"))
	items2, cur2 := stListPage(t, w2)
	if len(items2) != 2 || items2[0].(map[string]any)["key"] != "k3" || items2[1].(map[string]any)["key"] != "k4" {
		t.Errorf("第二页应 k3,k4: %v", items2)
	}
	if cur, ok := cur2.(string); !ok || cur != "k4" {
		t.Errorf("第二页 next_cursor 应 k4,实际 %v", cur2)
	}

	// 末页:cursor=k4 → 仅 k5,next_cursor 为 null
	w3 := s.do(stList(appid, "", "prefix", "k", "cursor", "k4", "limit", "2"))
	items3, cur3 := stListPage(t, w3)
	if len(items3) != 1 || items3[0].(map[string]any)["key"] != "k5" {
		t.Errorf("末页应仅 k5: %v", items3)
	}
	if cur3 != nil {
		t.Errorf("末页 next_cursor 应 null,实际 %v", cur3)
	}
}

// 用例 11:quota 端点八个数字字段齐全,limit 反映 config,used 反映写入。
func TestStorage_QuotaEndpoint(t *testing.T) {
	e := newStorageEnv(t, storageCfg(100<<20))
	s := e.newSrv(t)
	owner := e.user(t, "st11")
	s.as(owner.ID, "user")
	appid := stAppid()
	s.seedApp(t, appid, true)
	AssertOk(t, s.do(stPut(appid, "k1", "", `{"value":{"a":1}}`)), http.StatusOK)

	data := AssertOk(t, s.do(httptest.NewRequest("GET", "/api/mini-program-storage/"+appid+"/quota", nil)), http.StatusOK)
	for _, f := range []string{"app_used_bytes", "app_limit_bytes", "app_used_entries", "app_limit_entries",
		"my_used_bytes", "my_limit_bytes", "my_used_entries", "my_limit_entries"} {
		if v, ok := data[f].(float64); !ok || v < 0 {
			t.Errorf("quota 字段 %s 应为非负数字: %v", f, data[f])
		}
	}
	if v, _ := data["app_limit_bytes"].(float64); int64(v) != 100<<20 {
		t.Errorf("app_limit_bytes 应为 config 总帽 %d,实际 %v", 100<<20, data["app_limit_bytes"])
	}
	if v, _ := data["app_used_bytes"].(float64); v < 7 {
		t.Errorf("已写一值 app_used_bytes 应 ≥7: %v", data["app_used_bytes"])
	}
	if v, _ := data["app_used_entries"].(float64); v != 1 {
		t.Errorf("app_used_entries 应 1: %v", data["app_used_entries"])
	}
}

// 用例 13: shared_write 第三用户跨读 — 非 owner 用户 A 写的行,
// 第三用户 C(既非 owner 也非写者)GET/List 都可见(共享行全局身份)。
func TestStorage_SharedWrite_ThirdUserReadsOwnerRow(t *testing.T) {
	e := newStorageEnv(t, storageCfg(100<<20))
	s := e.newSrv(t)
	owner, a, c := e.user(t, "st13a"), e.user(t, "st13b"), e.user(t, "st13c")
	appid := stAppid()
	s.as(owner.ID, "user")
	s.seedApp(t, appid, true)

	s.as(a.ID, "user")
	AssertOk(t, s.do(stPut(appid, "a1", "board", `{"value":{"w":"a"}}`)), http.StatusOK)

	// C 读 A 写的行 → 命中
	s.as(c.ID, "user")
	data := AssertOk(t, s.do(stGet(appid, "a1", "board")), http.StatusOK)
	stValueEqual(t, data["value"], `{"w":"a"}`)
	if v, _ := data["version"].(float64); v != 1 {
		t.Errorf("version 应 1: %v", data)
	}
	// C 列表也能看到 A 的行
	items, _ := stListPage(t, s.do(stList(appid, "board")))
	if len(items) != 1 || items[0].(map[string]any)["key"] != "a1" {
		t.Errorf("shared_write 列表 C 应见 a1: %v", items)
	}
}

// 用例 14: shared_write 两人写同 key — B 覆写 A 建的 key 成功(全局行 version 连续),
// C 读到同一行 version=2。
func TestStorage_SharedWrite_TwoUsersSameKey(t *testing.T) {
	e := newStorageEnv(t, storageCfg(100<<20))
	s := e.newSrv(t)
	owner, a, b, c := e.user(t, "st14a"), e.user(t, "st14b"), e.user(t, "st14c"), e.user(t, "st14d")
	appid := stAppid()
	s.as(owner.ID, "user")
	s.seedApp(t, appid, true)

	s.as(a.ID, "user")
	AssertOk(t, s.do(stPut(appid, "k1", "board", `{"value":{"w":"a"}}`)), http.StatusOK)
	s.as(b.ID, "user")
	data := AssertOk(t, s.do(stPut(appid, "k1", "board", `{"value":{"w":"b"}}`)), http.StatusOK)
	if v, _ := data["version"].(float64); v != 2 {
		t.Errorf("B 覆写 A 建的 key version 应 2: %v", data)
	}

	// C 读到同一行 version=2
	s.as(c.ID, "user")
	data2 := AssertOk(t, s.do(stGet(appid, "k1", "board")), http.StatusOK)
	stValueEqual(t, data2["value"], `{"w":"b"}`)
	if v, _ := data2["version"].(float64); v != 2 {
		t.Errorf("C 读应见 version=2: %v", data2)
	}
	// 列表全局唯一行,无双行
	items, _ := stListPage(t, s.do(stList(appid, "board")))
	if len(items) != 1 || items[0].(map[string]any)["key"] != "k1" {
		t.Errorf("同 key 应恰一行: %v", items)
	}
}

// 用例 12:agent 身份换算 ownerID 后以 owner 视角写 shared_read 成功。
func TestStorage_AgentOwnerWrite(t *testing.T) {
	e := newStorageEnv(t, storageCfg(100<<20))
	s := e.newSrv(t)
	owner := e.user(t, "st12")
	appid := stAppid()
	s.as(owner.ID, "user")
	s.seedApp(t, appid, true)

	s.asAgent("agent-"+uuid.NewString()[:8], owner.ID)
	w := s.do(stPut(appid, "k1", "notes", `{"value":{"from":"agent"}}`))
	data := AssertOk(t, w, http.StatusOK)
	if v, _ := data["version"].(float64); v != 1 {
		t.Errorf("agent owner 写 version 应 1: %v", data)
	}
	// owner 本人可回读
	s.as(owner.ID, "user")
	data2 := AssertOk(t, s.do(stGet(appid, "k1", "notes")), http.StatusOK)
	stValueEqual(t, data2["value"], `{"from":"agent"}`)
}

// 用例 15:写路径 fanout — PUT 落库成功广播值事件(deleted=false + 新值 + version),
// DELETE 广播 deleted 事件(value=nil);writer_openid 已投影非空。
// fanout 经注入的记录闭包断言(测试 seam,生产传 hub 实现)。
func TestStorage_PutFansOutMpDataUpdate(t *testing.T) {
	e := newStorageEnv(t, storageCfg(100<<20))
	s := e.newSrv(t)
	owner := e.user(t, "st15")
	s.as(owner.ID, "user")
	appid := stAppid()
	s.seedApp(t, appid, true)

	type fanoutCall struct {
		appid, coll, key string
		value            json.RawMessage
		deleted          bool
		version          int64
		writerOpenID     string
	}
	var calls []fanoutCall
	e.sh.fanout = func(appid, coll, key string, value json.RawMessage, deleted bool, version int64, writerOpenID string) {
		calls = append(calls, fanoutCall{appid: appid, coll: coll, key: key, value: value,
			deleted: deleted, version: version, writerOpenID: writerOpenID})
	}

	// PUT shared_write 档:恰一次值事件 fanout
	AssertOk(t, s.do(stPut(appid, "k1", "board", `{"value":{"w":"a"}}`)), http.StatusOK)
	if len(calls) != 1 {
		t.Fatalf("PUT 后应恰一次 fanout,实际 %d 次", len(calls))
	}
	if c := calls[0]; c.appid != appid || c.coll != "board" || c.key != "k1" || c.deleted {
		t.Errorf("值事件频道/键/deleted 不符: %+v", c)
	} else {
		if c.version != 1 {
			t.Errorf("值事件 version 应 1: %+v", c)
		}
		if c.writerOpenID == "" {
			t.Error("值事件 writer_openid 应已投影非空")
		}
		stValueEqual(t, json.RawMessage(c.value), `{"w":"a"}`)
	}

	// DELETE:恰一次 deleted 事件,value nil,version 为被删行版本
	AssertOk(t, s.do(httptest.NewRequest("DELETE", stEntryURL(appid, "k1", "board"), nil)), http.StatusOK)
	if len(calls) != 2 {
		t.Fatalf("DELETE 后应累计两次 fanout,实际 %d 次", len(calls))
	}
	if d := calls[1]; !d.deleted || d.key != "k1" || d.value != nil {
		t.Errorf("deleted 事件形状不符: %+v", d)
	} else {
		if d.version != 1 {
			t.Errorf("deleted 事件 version 应为被删行版本 1: %+v", d)
		}
		if d.writerOpenID == "" {
			t.Error("deleted 事件 writer_openid 应已投影非空")
		}
	}
}
