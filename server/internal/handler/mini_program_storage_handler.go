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
	"github.com/wanling/server/internal/miniprogram"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// storageKeyRe 云数据 key 白名单(设计 §7):字母/数字/_ . : @ -,1-128 位。
var storageKeyRe = regexp.MustCompile(`^[A-Za-z0-9_.:@-]{1,128}$`)

// MiniProgramStorageHandler 小程序云数据 KV 五端点。
// agent 角色换算 ownerID 同 GetIcon 先例(agent 用其服务用户的槽位)。
type MiniProgramStorageHandler struct {
	dataRepo   *repository.MiniProgramDataRepo
	mpRepo     *repository.MiniProgramRepo
	openidRepo *repository.MiniProgramOpenidRepo // Task 5 fanout 用,本 task 注入备用
	cfg        config.MiniProgramConfig
}

func NewMiniProgramStorageHandler(dataRepo *repository.MiniProgramDataRepo, mpRepo *repository.MiniProgramRepo, openidRepo *repository.MiniProgramOpenidRepo, cfg config.MiniProgramConfig) *MiniProgramStorageHandler {
	return &MiniProgramStorageHandler{dataRepo: dataRepo, mpRepo: mpRepo, openidRepo: openidRepo, cfg: cfg}
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

// readSlots 按档位返回读取槽位(owner 维度,前者优先):
//   - private → [请求者](仅本人行);
//   - shared_read → [小程序 owner](公告栏所有行都是 owner 写的,单槽即完整);
//   - shared_write → [请求者, 小程序 owner](本人行优先 + owner 行兜底,
//     repo 查询按 owner 槽位隔离,第三用户行跨读不可达,见任务报告 concerns)。
func (h *MiniProgramStorageHandler) readSlots(sc *storageCtx) []string {
	switch sc.mode {
	case miniprogram.CollectionModeSharedRead:
		return []string{sc.mp.OwnerID}
	case miniprogram.CollectionModeSharedWrite:
		if sc.actor == sc.mp.OwnerID {
			return []string{sc.mp.OwnerID}
		}
		return []string{sc.actor, sc.mp.OwnerID}
	default:
		return []string{sc.actor}
	}
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

// getEntryShared 单键读:依次查读取槽位,首个命中即返回(全 miss → nil)。
func (h *MiniProgramStorageHandler) getEntryShared(c *gin.Context, sc *storageCtx, key string) (*model.MiniProgramData, error) {
	for _, owner := range h.readSlots(sc) {
		e, err := h.dataRepo.GetEntry(c.Request.Context(), sc.mp.Appid, owner, sc.coll, key)
		if err != nil {
			return nil, err
		}
		if e != nil {
			return e, nil
		}
	}
	return nil, nil
}

// GetEntry GET /api/mini-program-storage/:appid/entries/:key?coll=
// 不存在 → data:null(私有档行不可见语义,非 404)。
func (h *MiniProgramStorageHandler) GetEntry(c *gin.Context) {
	sc, ok := h.authStorage(c, false, true)
	if !ok {
		return
	}
	e, err := h.getEntryShared(c, sc, c.Param("key"))
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
// body {"value":any,"expected_version":int?};行归写者(shared_read 归 owner)。
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
	e, err := h.dataRepo.UpsertEntry(c.Request.Context(), sc.mp.Appid, sc.actor, sc.coll,
		c.Param("key"), req.Value, req.ExpectedVersion, h.limitsFor(sc.mp))
	if err != nil {
		h.mapRepoErr(c, err)
		return
	}
	Ok(c, toStorageEntryDTO(e))
}

// DeleteEntry DELETE /api/mini-program-storage/:appid/entries/:key?coll=&expected_version=
// 删请求者槽位的行(行归写者);不存在 → data:null(幂等)。
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
	if _, err := h.dataRepo.DeleteEntry(c.Request.Context(), sc.mp.Appid, sc.actor, sc.coll,
		c.Param("key"), expected); err != nil {
		h.mapRepoErr(c, err)
		return
	}
	Ok(c, nil)
}

// ListEntries GET /api/mini-program-storage/:appid/entries?coll=&prefix=&cursor=&limit=
// data 直接数组;有下一页时带 X-Next-Cursor 头(末页无头)。
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
	rows, next, err := h.listEntriesMerged(c, sc, c.Query("prefix"), c.Query("cursor"), limit)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	items := make([]storageEntryDTO, 0, len(rows))
	for _, e := range rows {
		items = append(items, toStorageEntryDTO(e))
	}
	if next != "" {
		c.Header("X-Next-Cursor", next)
	}
	Ok(c, items)
}

// listEntriesMerged 列表读:单槽位直接查;shared_write 非 owner 双槽位
// 各取一页后按 key 归并去重(请求者槽位优先),再截断 limit。
// hasMore 判定含两侧 repo nextCursor,防单槽恰好取满时误判末页。
func (h *MiniProgramStorageHandler) listEntriesMerged(c *gin.Context, sc *storageCtx, prefix, cursor string, limit int) ([]*model.MiniProgramData, string, error) {
	ctx := c.Request.Context()
	slots := h.readSlots(sc)
	if len(slots) == 1 {
		return h.dataRepo.ListEntries(ctx, sc.mp.Appid, slots[0], sc.coll, prefix, cursor, limit)
	}
	// 与 repo 的 LIMIT 兜底同规则(0→默认 100),截断/hasMore 判定须用生效值
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	a, nextA, err := h.dataRepo.ListEntries(ctx, sc.mp.Appid, slots[0], sc.coll, prefix, cursor, limit)
	if err != nil {
		return nil, "", err
	}
	b, nextB, err := h.dataRepo.ListEntries(ctx, sc.mp.Appid, slots[1], sc.coll, prefix, cursor, limit)
	if err != nil {
		return nil, "", err
	}
	merged := make([]*model.MiniProgramData, 0, len(a)+len(b))
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		switch {
		case j >= len(b) || (i < len(a) && a[i].Key <= b[j].Key):
			if j < len(b) && a[i].Key == b[j].Key {
				j++ // 同 key 去重,前槽位(请求者)行优先
			}
			merged = append(merged, a[i])
			i++
		default:
			merged = append(merged, b[j])
			j++
		}
	}
	hasMore := len(merged) > limit || nextA != "" || nextB != ""
	if len(merged) > limit {
		merged = merged[:limit]
	}
	next := ""
	if hasMore && len(merged) > 0 {
		next = merged[len(merged)-1].Key
	}
	return merged, next, nil
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
