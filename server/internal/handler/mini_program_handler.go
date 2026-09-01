package handler

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"path"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/wanling/server/internal/miniprogram"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
	"github.com/wanling/server/internal/storage"
)

// MiniProgramHandler 小程序容器(两层模型)。
// 上传=任意用户建私有或同 owner 换版本;publish/disable 与删除外的管理动作
// 的鉴权由路由组中间件保证(handler 不自检 role)。
type MiniProgramHandler struct {
	repo           *repository.MiniProgramRepo
	signingKeyRepo *repository.SigningKeyRepo
	fileRepo       *repository.FileRepo
	storage        storage.Provider
	maxZipBytes    int64
}

func NewMiniProgramHandler(repo *repository.MiniProgramRepo, signingKeyRepo *repository.SigningKeyRepo, fileRepo *repository.FileRepo, st storage.Provider, maxZipBytes int64) *MiniProgramHandler {
	return &MiniProgramHandler{repo: repo, signingKeyRepo: signingKeyRepo, fileRepo: fileRepo, storage: st, maxZipBytes: maxZipBytes}
}

// mpItem 列表 DTO(扇出 manifest 字段,APP 免二次解析 jsonb)。
type mpItem struct {
	ID             string                   `json:"id"`
	Appid          string                   `json:"appid"`
	OwnerID        string                   `json:"owner_id"`
	Name           string                   `json:"name"`
	Version        int                      `json:"version"`
	Entry          string                   `json:"entry"`
	Icon           string                   `json:"icon"`
	Permissions    []string                 `json:"permissions"`
	NavigationBar  *model.NavigationBarSpec `json:"navigation_bar"`
	Status         string                   `json:"status"`
	SHA256         string                   `json:"sha256"`
	Size           int64                    `json:"size"`
	Signature      string                   `json:"signature"`
}

func toMPItem(mp *model.MiniProgram) mpItem {
	// manifest 原文出自本服务上传时 json.Marshal,反序列化失败仅降级为空扇出字段
	var m model.MiniprogramManifest
	_ = json.Unmarshal(mp.ManifestJSON, &m)
	entry := m.Entry
	if entry == "" {
		entry = "index.html"
	}
	return mpItem{ID: mp.ID, Appid: mp.Appid, OwnerID: mp.OwnerID, Name: mp.Name,
		Version: mp.Version, Entry: entry, Icon: m.Icon, Permissions: m.Permissions,
		NavigationBar: m.NavigationBar,
		Status:        mp.Status, SHA256: mp.SHA256, Size: mp.Size, Signature: mp.Signature}
}

// Upload POST /api/mini-programs:zip 上传 → 新建私有或同 owner 换版本。
func (h *MiniProgramHandler) Upload(c *gin.Context) {
	userID := c.GetString("userID")
	// agent 直传(M2):owner 换算到 agent 服务的真实用户(照抄 file_handler 先例,
	// agent_id 不在 users 表,直接落库会触发 FK 约束)。
	if c.GetString("role") == "agent" {
		if ownerID := c.GetString("ownerID"); ownerID != "" {
			userID = ownerID
		}
	}

	// 限制请求体大小,超限 413(与 FileHandler.Upload 同策略)
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, h.maxZipBytes)
	file, header, err := c.Request.FormFile("file")
	if err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			Err(c, http.StatusRequestEntityTooLarge, "payload_too_large", "包过大")
			return
		}
		Err(c, http.StatusBadRequest, "bad_request", "请上传文件")
		return
	}
	defer file.Close()

	if !strings.EqualFold(path.Ext(header.Filename), ".zip") {
		Err(c, http.StatusUnsupportedMediaType, "unsupported_media_type", "仅支持 .zip 包")
		return
	}
	data, err := io.ReadAll(file)
	if err != nil {
		ErrMsg(c, http.StatusBadRequest, "读取上传内容失败")
		return
	}
	manifest, err := miniprogram.ValidatePackage(data, h.maxZipBytes)
	if err != nil {
		Err(c, http.StatusBadRequest, "invalid_package", err.Error())
		return
	}

	// appid 归属判定:他人占用 → 403;自己占用 → 换版本;否则新建
	existing, err := h.repo.GetByAppid(c.Request.Context(), manifest.Appid)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if existing != nil && existing.OwnerID != userID {
		Err(c, http.StatusForbidden, "forbidden", "appid 已被占用")
		return
	}

	sum := sha256.Sum256(data)
	shaHex := hex.EncodeToString(sum[:])
	storePath, err := h.storage.Save(header.Filename, bytes.NewReader(data))
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "存储失败")
		return
	}
	f, err := h.fileRepo.Create(c.Request.Context(), repository.CreateFileParams{
		OwnerID:     userID,
		Filename:    header.Filename,
		MimeType:    "application/zip",
		Size:        int64(len(data)),
		StoragePath: storePath,
	})
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	manifestJSON, err := json.Marshal(manifest)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if existing != nil {
		err = h.repo.ReplaceVersion(c.Request.Context(), existing.ID, repository.ReplaceVersionParams{
			Name: manifest.Name, Version: manifest.Version, ManifestJSON: manifestJSON,
			PackageFileID: f.ID, SHA256: shaHex, Size: int64(len(data)),
		})
		if err != nil {
			ErrMsg(c, http.StatusInternalServerError, "服务器错误")
			return
		}
		OkCreated(c, gin.H{"id": existing.ID, "appid": manifest.Appid, "version": manifest.Version})
		return
	}
	mp := &model.MiniProgram{
		ID: uuid.NewString(), Appid: manifest.Appid, OwnerID: userID,
		Name: manifest.Name, Version: manifest.Version, ManifestJSON: manifestJSON,
		PackageFileID: f.ID, SHA256: shaHex, Size: int64(len(data)),
	}
	if err := h.repo.Create(c.Request.Context(), mp); err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	OkCreated(c, gin.H{"id": mp.ID, "appid": manifest.Appid, "version": manifest.Version})
}

// List GET /api/mini-programs:published 全量 + 自己的。
func (h *MiniProgramHandler) List(c *gin.Context) {
	userID := c.GetString("userID")
	list, err := h.repo.ListVisibleTo(c.Request.Context(), userID)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "查询失败")
		return
	}
	items := make([]mpItem, 0, len(list))
	for _, mp := range list {
		items = append(items, toMPItem(mp))
	}
	Ok(c, items)
}

// DownloadPackage GET /api/mini-programs/:id/package:owner 或 published 可下载。
func (h *MiniProgramHandler) DownloadPackage(c *gin.Context) {
	userID := c.GetString("userID")
	// agent 下载(M2):owner 换算到 agent 服务的真实用户(照抄 file_handler 先例)。
	if c.GetString("role") == "agent" {
		if ownerID := c.GetString("ownerID"); ownerID != "" {
			userID = ownerID
		}
	}
	mp, err := h.repo.GetByID(c.Request.Context(), c.Param("id"))
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if mp == nil {
		Err(c, http.StatusNotFound, "not_found", "小程序不存在")
		return
	}
	// 归属校验防 IDOR:非 owner 仅 published 放行(appid 受正则约束,
	// 仅含 [a-z0-9-],拼入 Content-Disposition 无注入风险)
	if mp.OwnerID != userID && mp.Status != "published" {
		Err(c, http.StatusForbidden, "forbidden", "无权访问")
		return
	}
	f, err := h.fileRepo.GetByID(c.Request.Context(), mp.PackageFileID)
	if err != nil || f == nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	reader, err := h.storage.Read(f.StoragePath)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "读取失败")
		return
	}
	defer reader.Close()
	c.Header("Content-Type", "application/zip")
	c.Header("Content-Disposition", "attachment; filename*=UTF-8''"+mp.Appid+"-"+strconv.Itoa(mp.Version)+".zip")
	c.Header("X-Mini-Program-Sha256", mp.SHA256)
	c.Header("X-Content-Type-Options", "nosniff")
	c.DataFromReader(http.StatusOK, f.Size, "application/zip", reader, nil)
}

// Delete DELETE /api/mini-programs/:id:owner 删自己的 private,其余一律 409。
func (h *MiniProgramHandler) Delete(c *gin.Context) {
	userID := c.GetString("userID")
	n, err := h.repo.DeletePrivate(c.Request.Context(), c.Param("id"), userID)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if n == 0 {
		Err(c, http.StatusConflict, "invalid_state", "仅能删除自己的私有小程序")
		return
	}
	Ok(c, nil)
}

// UpdateStatus PUT /api/mini-programs/:id/status(admin 路由组):
// 流转白名单 private→published;published⇄disabled;其余拒绝。
func (h *MiniProgramHandler) UpdateStatus(c *gin.Context) {
	var req struct {
		Status string `json:"status" binding:"required,oneof=published disabled"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	mp, err := h.repo.GetByID(c.Request.Context(), c.Param("id"))
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if mp == nil {
		Err(c, http.StatusNotFound, "not_found", "小程序不存在")
		return
	}
	allowed := map[string]map[string]bool{
		"private":   {"published": true},
		"published": {"disabled": true},
		"disabled":  {"published": true},
	}
	if !allowed[mp.Status][req.Status] {
		Err(c, http.StatusConflict, "invalid_transition", "不允许的状态流转 "+mp.Status+"→"+req.Status)
		return
	}
	if err := h.repo.UpdateStatus(c.Request.Context(), mp.ID, req.Status); err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	// 流转到 published 时自动签名(兼容策略:签名失败不阻断 publish,
	// signature 缺失 APP 端放行,由启动补签/下次流转兜底)。
	if req.Status == "published" {
		if err := h.signPackage(c.Request.Context(), mp); err != nil {
			log.Printf("[mini_program] publish 签名失败 appid=%s: %v", mp.Appid, err)
		}
	}
	Ok(c, gin.H{"id": mp.ID, "status": req.Status})
}

// signPackage 对 published 包做 ed25519 签名并落库(失败由调用方记日志,不阻断)。
func (h *MiniProgramHandler) signPackage(ctx context.Context, mp *model.MiniProgram) error {
	f, err := h.fileRepo.GetByID(ctx, mp.PackageFileID)
	if err != nil {
		return fmt.Errorf("查包文件: %w", err)
	}
	if f == nil {
		return fmt.Errorf("包文件缺失")
	}
	reader, err := h.storage.Read(f.StoragePath)
	if err != nil {
		return fmt.Errorf("读包失败: %w", err)
	}
	defer reader.Close()
	data, err := io.ReadAll(reader)
	if err != nil {
		return fmt.Errorf("读包字节: %w", err)
	}
	key, err := h.signingKeyRepo.Ensure(ctx)
	if err != nil {
		return fmt.Errorf("取签名密钥: %w", err)
	}
	sig, err := miniprogram.Sign(key.PrivateKey, data)
	if err != nil {
		return fmt.Errorf("签名: %w", err)
	}
	return h.repo.UpdateSignature(ctx, mp.ID, sig)
}

// BackfillSignatures 启动补签:历史 published 缺 signature 的包逐个补上。
// ListPublishedMissingSignature 单次 LIMIT 256,循环消费直到返空;
// 单包失败记日志继续,整轮零进展则终止(残留项留待下次启动重试)。
func (h *MiniProgramHandler) BackfillSignatures(ctx context.Context) error {
	if _, err := h.signingKeyRepo.Ensure(ctx); err != nil {
		return fmt.Errorf("取签名密钥: %w", err)
	}
	for {
		missing, err := h.repo.ListPublishedMissingSignature(ctx)
		if err != nil {
			return fmt.Errorf("查缺签列表: %w", err)
		}
		if len(missing) == 0 {
			return nil
		}
		progress := false
		for _, mp := range missing {
			if err := h.signPackage(ctx, mp); err != nil {
				log.Printf("[mini_program] 补签失败 appid=%s: %v", mp.Appid, err)
				continue
			}
			progress = true
			log.Printf("[mini_program] 补签完成 appid=%s", mp.Appid)
		}
		if !progress {
			log.Printf("[mini_program] 本轮补签零进展,终止(残留 %d 个待下次启动重试)", len(missing))
			return nil
		}
	}
}

// GetSigningKey GET /api/mini-programs/signing-key:下发公钥(私钥永不出 server)。
func (h *MiniProgramHandler) GetSigningKey(c *gin.Context) {
	key, err := h.signingKeyRepo.Ensure(c.Request.Context())
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	Ok(c, gin.H{"public_key": key.PublicKey})
}
