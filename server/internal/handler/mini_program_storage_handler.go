// 从 templates/go-handler.go.tmpl 复制骨架改写:
// 档位鉴权矩阵(handler 内实现,fail fast:存在性→可见性→档位→配额)、
// 双层配额组装、乐观锁/配额错误映射 409/413。
package handler

import (
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/config"
	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/miniprogram"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// storageKeyRe 云数据 key 白名单(设计 §7):字母/数字/_ . : @ -,1-128 位。
var storageKeyRe = regexp.MustCompile(`^[A-Za-z0-9_.:@-]{1,128}$`)

// mpFanout 云数据变更 fanout 接口(测试 seam):
// 生产传 hub.SendMpDataUpdate,测试传记录闭包;nil 时跳过(未接线场景)。
type mpFanout func(appid, coll, key string, value json.RawMessage, deleted bool, version int64, writerOpenID string)

// MiniProgramStorageHandler 小程序云数据 KV 五端点。
// agent 角色换算 ownerID 同 GetIcon 先例(agent 用其服务用户的槽位)。
type MiniProgramStorageHandler struct {
	dataRepo   *repository.MiniProgramDataRepo
	mpRepo     *repository.MiniProgramRepo
	openidRepo *repository.MiniProgramOpenidRepo // 写路径 fanout 时投影 writer openid
	fanout     mpFanout                          // 落库成功后广播 MP_DATA_UPDATE
	cfg        config.MiniProgramConfig
}

func NewMiniProgramStorageHandler(dataRepo *repository.MiniProgramDataRepo, mpRepo *repository.MiniProgramRepo, openidRepo *repository.MiniProgramOpenidRepo, cfg config.MiniProgramConfig, fanout mpFanout) *MiniProgramStorageHandler {
	return &MiniProgramStorageHandler{dataRepo: dataRepo, mpRepo: mpRepo, openidRepo: openidRepo, fanout: fanout, cfg: cfg}
}

// storageEntryDTO 单行 DTO;value 透传 jsonb 读回的规范化字节
// (Task 3 裁决③:PG jsonb 列读回与提交字节可能不同,语义等价,勿二次 marshal)。
type storageEntryDTO struct {
	Key       string          `json:"key"`
	Coll      string          `json:"coll"`
	Value     json.RawMessage `json:"value"`
	Version   int64           `json:"version"`
	UpdatedAt time.Time       `json:"updated_at"`
}

func toStorageEntryDTO(e *model.MiniProgramData) storageEntryDTO {
	return storageEntryDTO{Key: e.Key, Coll: e.Coll, Value: json.RawMessage(e.Value),
		Version: e.Version, UpdatedAt: e.UpdatedAt}
}

// storageCtx 鉴权后的请求上下文:小程序行 + 换算后请求者 + coll 档位。
type storageCtx struct {
	mp    *model.MiniProgram
	actor string
	coll  string
	mode  string
}

// authStorage 鉴权链公共段(fail fast 顺序):
// 存在性(404) → 可见性(unpublished 非 owner 403) → coll 档位解析(未声明 400)。
// write=true 追加档位写权限(shared_read 仅 owner);keyCheck=true 校验 :key 白名单。
// 通过返 (ctx, true);已写响应返 (nil, false)。
func (h *MiniProgramStorageHandler) authStorage(c *gin.Context, write, keyCheck bool) (*storageCtx, bool) {
	// owner_id 强制取请求者(agent 换算到其服务用户),客户端不可传(私有档天然 IDOR 免疫)
	actor := c.GetString("userID")
	if c.GetString("role") == "agent" {
		if ownerID := c.GetString("ownerID"); ownerID != "" {
			actor = ownerID
		}
	}
	mp, err := h.mpRepo.GetByAppid(c.Request.Context(), c.Param("appid"))
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return nil, false
	}
	if mp == nil {
		Err(c, http.StatusNotFound, "not_found", "小程序不存在")
		return nil, false
	}
	// 共享档「所有人」前提:published;非 owner 对未发布小程序一律 403
	if mp.OwnerID != actor && mp.Status != "published" {
		Err(c, http.StatusForbidden, "forbidden", "无权访问")
		return nil, false
	}
	// coll 二次校验:不在 manifest 声明且 ≠ default → 400(default 恒 private,免声明)
	coll := c.Query("coll")
	if coll == "" {
		coll = "default"
	}
	mode := miniprogram.CollectionModePrivate
	if coll != "default" {
		// manifest 原文出自本服务上传时校验落库,反序列化失败按无声明处理(全部 400)
		var m model.MiniprogramManifest
		_ = json.Unmarshal(mp.ManifestJSON, &m)
		declared := false
		for _, cl := range m.Collections {
			if cl.Name == coll {
				mode, declared = cl.Mode, true
				break
			}
		}
		if !declared {
			Err(c, http.StatusBadRequest, "bad_request", "collection 未在 manifest 声明: "+coll)
			return nil, false
		}
	}
	if write && mode == miniprogram.CollectionModeSharedRead && mp.OwnerID != actor {
		Err(c, http.StatusForbidden, "forbidden", "shared_read 仅小程序 owner 可写")
		return nil, false
	}
	if keyCheck && !storageKeyRe.MatchString(c.Param("key")) {
		Err(c, http.StatusBadRequest, "bad_request", "key 需匹配 ^[A-Za-z0-9_.:@-]{1,128}$")
		return nil, false
	}
	return &storageCtx{mp: mp, actor: actor, coll: coll, mode: mode}, true
}

// isSharedMode 档位是否共享(shared_read/shared_write):
// 共享行全局身份 (appid,coll,key),读写走 repo Shared 方法族(跨 owner 可见);
// private 档继续走槽位隔离方法(本人行)。
func isSharedMode(mode string) bool {
	return mode == miniprogram.CollectionModeSharedRead || mode == miniprogram.CollectionModeSharedWrite
}

// limitsFor 组装写入配额:全局默认 + mini_programs.quota_bytes 覆盖
// (非 NULL 时替换 AppBytes 总帽,其余帽不动)。
func (h *MiniProgramStorageHandler) limitsFor(mp *model.MiniProgram) repository.QuotaLimits {
	q := repository.QuotaLimits{
		AppBytes:      h.cfg.StorageAppBytes,
		AppEntries:    h.cfg.StorageAppEntries,
		MyBytes:       h.cfg.StorageMyBytes,
		MyEntries:     h.cfg.StorageMyEntries,
		MaxValueBytes: h.cfg.StorageMaxValueBytes,
	}
	if mp.QuotaBytes.Valid {
		q.AppBytes = mp.QuotaBytes.Int64
	}
	return q
}

// mapRepoErr repo 哨兵错误 → HTTP 映射:
// ErrVersionConflict → 409 invalid_state;ErrQuotaExceeded → 413(原因透传)。
func (h *MiniProgramStorageHandler) mapRepoErr(c *gin.Context, err error) {
	switch {
	case errors.Is(err, repository.ErrVersionConflict):
		Err(c, http.StatusConflict, "invalid_state", "版本冲突，请重读后重试")
	case errors.Is(err, repository.ErrQuotaExceeded):
		Err(c, http.StatusRequestEntityTooLarge, "payload_too_large", err.Error())
	default:
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
	}
}

// fanoutUpdate 落库成功后的 MP_DATA_UPDATE 广播:writer 投影 openid,
// 失败仅 Warn 不阻断 HTTP 响应(写已成功,推送是增值路径)。
func (h *MiniProgramStorageHandler) fanoutUpdate(c *gin.Context, appid, coll, key string, value json.RawMessage, deleted bool, version int64, writerID string) {
	if h.fanout == nil {
		return
	}
	writerOpenID, err := h.openidRepo.GetOrCreateOpenid(c.Request.Context(), writerID, appid)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).WarnContext(c.Request.Context(),
			"MP_DATA_UPDATE 投影 writer openid 失败,置空继续广播",
			"appid", appid, "writer_id", writerID, "err", err)
		writerOpenID = ""
	}
	h.fanout(appid, coll, key, value, deleted, version, writerOpenID)
}

// getEntryChecked 单键读:shared 档走全局行查询(跨 owner 可见),
// private 档走请求者槽位(仅本人行)。
func (h *MiniProgramStorageHandler) getEntryChecked(c *gin.Context, sc *storageCtx, key string) (*model.MiniProgramData, error) {
	if isSharedMode(sc.mode) {
		return h.dataRepo.GetEntryShared(c.Request.Context(), sc.mp.Appid, sc.coll, key)
	}
	return h.dataRepo.GetEntry(c.Request.Context(), sc.mp.Appid, sc.actor, sc.coll, key)
}

// GetEntry GET /api/mini-program-storage/:appid/entries/:key?coll=
// 不存在 → data:null(私有档行不可见语义,非 404)。
func (h *MiniProgramStorageHandler) GetEntry(c *gin.Context) {
	sc, ok := h.authStorage(c, false, true)
	if !ok {
		return
	}
	e, err := h.getEntryChecked(c, sc, c.Param("key"))
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if e == nil {
		Ok(c, nil)
		return
	}
	Ok(c, toStorageEntryDTO(e))
}

// PutEntry PUT /api/mini-program-storage/:appid/entries/:key?coll=
// body {"value":any,"expected_version":int?}。shared 档写全局行
// (owner=最后写者);private 档写请求者槽位行。
func (h *MiniProgramStorageHandler) PutEntry(c *gin.Context) {
	sc, ok := h.authStorage(c, true, true)
	if !ok {
		return
	}
	var req struct {
		Value           json.RawMessage `json:"value" binding:"required"`
		ExpectedVersion *int64          `json:"expected_version"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", "body 需为 {\"value\":any,\"expected_version\":int?}")
		return
	}
	var e *model.MiniProgramData
	var err error
	if isSharedMode(sc.mode) {
		e, err = h.dataRepo.UpsertEntryShared(c.Request.Context(), sc.mp.Appid, sc.actor, sc.coll,
			c.Param("key"), req.Value, req.ExpectedVersion, h.limitsFor(sc.mp))
	} else {
		e, err = h.dataRepo.UpsertEntry(c.Request.Context(), sc.mp.Appid, sc.actor, sc.coll,
			c.Param("key"), req.Value, req.ExpectedVersion, h.limitsFor(sc.mp))
	}
	if err != nil {
		h.mapRepoErr(c, err)
		return
	}
	// 落库成功 → fanout 值事件(同步执行,失败 Warn 不阻断 HTTP 响应)
	h.fanoutUpdate(c, sc.mp.Appid, sc.coll, e.Key, json.RawMessage(e.Value), false, e.Version, sc.actor)
	Ok(c, toStorageEntryDTO(e))
}

// DeleteEntry DELETE /api/mini-program-storage/:appid/entries/:key?coll=&expected_version=
// shared 档删全局行,private 档删请求者槽位行;不存在 → data:null(幂等)。
func (h *MiniProgramStorageHandler) DeleteEntry(c *gin.Context) {
	sc, ok := h.authStorage(c, true, true)
	if !ok {
		return
	}
	var expected *int64
	if s := c.Query("expected_version"); s != "" {
		v, err := strconv.ParseInt(s, 10, 64)
		if err != nil {
			Err(c, http.StatusBadRequest, "bad_request", "expected_version 需为整数")
			return
		}
		expected = &v
	}
	var deleted *model.MiniProgramData
	var err error
	if isSharedMode(sc.mode) {
		deleted, err = h.dataRepo.DeleteEntryShared(c.Request.Context(), sc.mp.Appid, sc.coll,
			c.Param("key"), expected)
	} else {
		deleted, err = h.dataRepo.DeleteEntry(c.Request.Context(), sc.mp.Appid, sc.actor, sc.coll,
			c.Param("key"), expected)
	}
	if err != nil {
		h.mapRepoErr(c, err)
		return
	}
	// 行确实删除(幂等 no-op 删除无变更不广播)→ fanout deleted 事件,value 为 null
	if deleted != nil {
		h.fanoutUpdate(c, sc.mp.Appid, sc.coll, deleted.Key, nil, true, deleted.Version, sc.actor)
	}
	Ok(c, nil)
}

// storageListPageDTO 列表页 DTO:集合+游标的形状例外(data:{items,next_cursor})。
// 游标必须走 body:APP 桥经 ApiService.proxyRequest 只透 body,
// 放响应头则 JS 侧翻页游标永远缺失(末页 next_cursor 为 null)。
type storageListPageDTO struct {
	Items      []storageEntryDTO `json:"items"`
	NextCursor *string           `json:"next_cursor"`
}

// ListEntries GET /api/mini-program-storage/:appid/entries?coll=&prefix=&cursor=&limit=
// data 为 {items:[...],next_cursor:"..."|null}(游标 body 携带,见 DTO 注释)。
func (h *MiniProgramStorageHandler) ListEntries(c *gin.Context) {
	sc, ok := h.authStorage(c, false, false)
	if !ok {
		return
	}
	limit := 0
	if s := c.Query("limit"); s != "" {
		v, err := strconv.Atoi(s)
		if err != nil || v < 1 || v > 500 {
			Err(c, http.StatusBadRequest, "bad_request", "limit 需为 1-500")
			return
		}
		limit = v
	}
	var rows []*model.MiniProgramData
	var next string
	var err error
	if isSharedMode(sc.mode) {
		rows, next, err = h.dataRepo.ListEntriesShared(c.Request.Context(), sc.mp.Appid, sc.coll,
			c.Query("prefix"), c.Query("cursor"), limit)
	} else {
		rows, next, err = h.dataRepo.ListEntries(c.Request.Context(), sc.mp.Appid, sc.actor, sc.coll,
			c.Query("prefix"), c.Query("cursor"), limit)
	}
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	items := make([]storageEntryDTO, 0, len(rows))
	for _, e := range rows {
		items = append(items, toStorageEntryDTO(e))
	}
	var nextCursor *string
	if next != "" {
		nextCursor = &next
	}
	Ok(c, storageListPageDTO{Items: items, NextCursor: nextCursor})
}

// GetQuota GET /api/mini-program-storage/:appid/quota
// 双层用量 + 生效上限(quota_bytes 覆盖后)。
func (h *MiniProgramStorageHandler) GetQuota(c *gin.Context) {
	sc, ok := h.authStorage(c, false, false)
	if !ok {
		return
	}
	stats, err := h.dataRepo.Stats(c.Request.Context(), sc.mp.Appid, sc.actor)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	lim := h.limitsFor(sc.mp)
	Ok(c, gin.H{
		"app_used_bytes":    stats.AppBytes,
		"app_limit_bytes":   lim.AppBytes,
		"app_used_entries":  stats.AppEntries,
		"app_limit_entries": lim.AppEntries,
		"my_used_bytes":     stats.MyBytes,
		"my_limit_bytes":    lim.MyBytes,
		"my_used_entries":   stats.MyEntries,
		"my_limit_entries":  lim.MyEntries,
	})
}
