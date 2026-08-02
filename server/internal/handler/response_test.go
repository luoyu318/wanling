package handler

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func setupRouter() *gin.Engine {
	gin.SetMode(gin.TestMode)
	return gin.New()
}

func TestOkWithData(t *testing.T) {
	r := setupRouter()
	r.GET("/", func(c *gin.Context) { Ok(c, gin.H{"id": "abc"}) })

	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	r.ServeHTTP(w, req)

	data := AssertOk(t, w, http.StatusOK)
	require.Equal(t, "abc", data["id"])
}

func TestOkWithNilData(t *testing.T) {
	r := setupRouter()
	r.GET("/", func(c *gin.Context) { Ok(c, nil) })

	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	r.ServeHTTP(w, req)

	data := AssertOk(t, w, http.StatusOK)
	require.Nil(t, data)
}

func TestOkCreated(t *testing.T) {
	r := setupRouter()
	r.POST("/", func(c *gin.Context) { OkCreated(c, gin.H{"id": "x"}) })

	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/", nil)
	r.ServeHTTP(w, req)

	data := AssertOk(t, w, http.StatusCreated)
	require.Equal(t, "x", data["id"])
}

func TestErrBasic(t *testing.T) {
	r := setupRouter()
	r.GET("/", func(c *gin.Context) {
		Err(c, http.StatusNotFound, "not_found", "资源不存在")
	})

	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusNotFound, "not_found")
}

func TestErrMsgDefaultsCodeToInternalError(t *testing.T) {
	r := setupRouter()
	r.GET("/", func(c *gin.Context) { ErrMsg(c, http.StatusInternalServerError, "boom") })

	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusInternalServerError, "internal_error")
}

func TestErrWithExtraFields(t *testing.T) {
	r := setupRouter()
	r.GET("/", func(c *gin.Context) {
		Err(c, http.StatusConflict, "invalid_state", "审批已决策",
			gin.H{"state": "approved"})
	})

	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	r.ServeHTTP(w, req)

	body := AssertErrBody(t, w, http.StatusConflict, "invalid_state")
	require.Equal(t, "approved", body["error"].(map[string]any)["state"])
}

// AssertOk 断言 envelope 成功并返回 data（map[string]any）
func AssertOk(t *testing.T, w *httptest.ResponseRecorder, wantStatus int) map[string]any {
	t.Helper()
	require.Equal(t, wantStatus, w.Code, "status mismatch; body=%s", w.Body.String())
	var resp map[string]any
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &resp), "body=%s", w.Body.String())
	okField, okExists := resp["ok"].(bool)
	require.True(t, okExists, "envelope 缺 ok 字段; body=%s", w.Body.String())
	require.True(t, okField, "ok should be true; body=%s", w.Body.String())
	data, ok := resp["data"].(map[string]any)
	if resp["data"] != nil && !ok {
		require.Failf(t, "AssertOk: data 不是 map", "got %T; body=%s", resp["data"], w.Body.String())
	}
	return data
}

// AssertOkList 断言成功 envelope + data 是 list，返回 []any
func AssertOkList(t *testing.T, w *httptest.ResponseRecorder, wantStatus int) []any {
	t.Helper()
	require.Equal(t, wantStatus, w.Code, "status mismatch; body=%s", w.Body.String())
	var resp map[string]any
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &resp), "body=%s", w.Body.String())
	okField, okExists := resp["ok"].(bool)
	require.True(t, okExists, "envelope 缺 ok 字段; body=%s", w.Body.String())
	require.True(t, okField, "ok should be true; body=%s", w.Body.String())
	data, ok := resp["data"].([]any)
	if resp["data"] != nil && !ok {
		require.Failf(t, "AssertOkList: data 不是 list", "got %T; body=%s", resp["data"], w.Body.String())
	}
	return data
}

// AssertErr 断言 envelope 失败 + code
func AssertErr(t *testing.T, w *httptest.ResponseRecorder, wantStatus int, wantCode string) {
	t.Helper()
	AssertErrBody(t, w, wantStatus, wantCode)
}

// AssertErrBody 断言 envelope 失败 + 返回完整 body（含 error 子对象）
func AssertErrBody(t *testing.T, w *httptest.ResponseRecorder, wantStatus int, wantCode string) map[string]any {
	t.Helper()
	require.Equal(t, wantStatus, w.Code, "status mismatch; body=%s", w.Body.String())
	var resp map[string]any
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &resp), "body=%s", w.Body.String())
	okField, okExists := resp["ok"].(bool)
	require.True(t, okExists, "envelope 缺 ok 字段; body=%s", w.Body.String())
	require.False(t, okField, "ok should be false")
	errObj, ok := resp["error"].(map[string]any)
	require.True(t, ok, "error 子对象缺失; body=%s", w.Body.String())
	require.Equal(t, wantCode, errObj["code"], "code mismatch; body=%s", w.Body.String())
	require.NotEmpty(t, errObj["message"], "message 不应为空")
	return resp
}

func TestOkListWithData(t *testing.T) {
	r := setupRouter()
	r.GET("/", func(c *gin.Context) { Ok(c, []string{"a", "b"}) })

	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	r.ServeHTTP(w, req)

	data := AssertOkList(t, w, http.StatusOK)
	require.Equal(t, 2, len(data))
	require.Equal(t, "a", data[0])
}

func TestOkListWithEmpty(t *testing.T) {
	r := setupRouter()
	r.GET("/", func(c *gin.Context) { Ok(c, []string{}) })

	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	r.ServeHTTP(w, req)

	data := AssertOkList(t, w, http.StatusOK)
	require.Equal(t, 0, len(data))
}
