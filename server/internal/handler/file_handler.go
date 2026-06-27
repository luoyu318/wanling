package handler

import (
	"log"
	"net/http"
	"path/filepath"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/imaging"
	"github.com/wanling/server/internal/repository"
	"github.com/wanling/server/internal/storage"
)

type FileHandler struct {
	fileRepo *repository.FileRepo
	storage  storage.Provider
}

func NewFileHandler(fileRepo *repository.FileRepo, storage storage.Provider) *FileHandler {
	return &FileHandler{fileRepo: fileRepo, storage: storage}
}

// thumbnailExt 缩略图文件扩展名（统一 JPEG）。
// handler 拼 storageName = `{原图fileID去掉扩展名}_thumb.jpg`。
const thumbnailSuffix = "_thumb.jpg"

// 图片扩展名白名单（小写，含点）。与 imaging 包已注册的解码器对齐。
// 同时映射到标准 mime（mime 矫正用，见 resolveImageMime）。
var imageExtensions = map[string]string{
	".jpg": "image/jpeg", ".jpeg": "image/jpeg",
	".png": "image/png", ".webp": "image/webp", ".gif": "image/gif",
}

// isImageUpload 判断上传文件是否值得生成缩略图。
//
// 双重判定（任一命中即视为图片），兼容客户端 Content-Type 缺失的情况：
//  1. Content-Type 为已知图片 mime（dio 标准上传路径会按扩展名正确推断）
//  2. filename 扩展名为图片类型（adapter.py 上传时 _guess_mime 也走扩展名，
//     双保险，即使 Content-Type 回退到 octet-stream 也能识别）
//
// 最终是否真能生成还取决于 imaging 解码成功与否（generateThumbnail 内 fail-soft）。
func isImageUpload(mime, filename string) bool {
	if _, ok := imageExtensions[strings.ToLower(filepath.Ext(filename))]; ok {
		return true
	}
	switch strings.ToLower(strings.TrimSpace(mime)) {
	case "image/jpeg", "image/jpg", "image/png", "image/webp", "image/gif":
		return true
	}
	return false
}

// resolveImageMime 矫正图片 mime。
//
// 客户端（含测试）上传时 Content-Type 可能缺失或为通用 octet-stream，
// 但 filename 带扩展名。这里按扩展名推断正确 mime，保证 Download 返回的
// Content-Type 准确（否则 cached_network_image / 浏览器无法识别格式）。
// 非图片扩展名返回空串，调用方据此保留原 mime。
func resolveImageMime(filename string) string {
	return imageExtensions[strings.ToLower(filepath.Ext(filename))]
}

func (h *FileHandler) Upload(c *gin.Context) {
	file, header, err := c.Request.FormFile("file")
	if err != nil {
		// FormFile 失败常见原因：Content-Type 不是 multipart/form-data、
		// body 为空、nginx client_max_body_size 拦截后 body 已读尽。
		log.Printf("[upload] 解析 multipart 失败: %v | size=%d content_type=%s remote=%s",
			err, c.Request.ContentLength, c.ContentType(), c.ClientIP())
		c.JSON(http.StatusBadRequest, gin.H{"error": "请上传文件"})
		return
	}
	defer file.Close()

	// agent 上传时把 owner_id 落为它真正的 owner（user），让 user 能下载，
	// 同时满足 files.owner_id 外键到 users(id) 的约束（agent_id 不在 users 表，
	// 直接用会 500）。
	userID := c.GetString("userID")
	if c.GetString("role") == "agent" {
		if ownerID := c.GetString("ownerID"); ownerID != "" {
			userID = ownerID
		}
	}
	path, err := h.storage.Save(header.Filename, file)
	if err != nil {
		// Save 失败常见原因：STORAGE_PATH 目录权限不足、磁盘满、路径不可写。
		log.Printf("[upload] 存储失败: %v | filename=%s size=%d remote=%s",
			err, header.Filename, header.Size, c.ClientIP())
		c.JSON(http.StatusInternalServerError, gin.H{"error": "存储失败"})
		return
	}

	mime := header.Header.Get("Content-Type")

	// 图片 mime 矫正：客户端可能传 octet-stream / 缺失，按扩展名补正。
	// 确保后续 isImageUpload 判定 + Download 返回的 Content-Type 都准确。
	// 仅图片扩展名会被改写，非图片文件保留原 mime。
	if corrected := resolveImageMime(header.Filename); corrected != "" {
		mime = corrected
	}

	// 图片类型：同步生成缩略图 + 提取原图宽高（fail-soft，失败不阻断上传）。
	// file multipart reader 已被 Save 消费，需重新读取——重新解析 FormFile
	// 拿一份独立 reader（gin 的 FormFile 每次返回新的 section reader）。
	var thumbPath *string
	var width, height *int
	if isImageUpload(mime, header.Filename) {
		thumbPath, width, height = h.generateThumbnail(c, path, mime)
	}

	f, err := h.fileRepo.Create(repository.CreateFileParams{
		OwnerID:       userID,
		Filename:      header.Filename,
		MimeType:      mime,
		Size:          header.Size,
		StoragePath:   path,
		ThumbnailPath: thumbPath,
		Width:         width,
		Height:        height,
	})
	if err != nil {
		// DB 写失败常见原因：owner_id 为空触发外键约束、DB 连接断、字段超长。
		log.Printf("[upload] DB 写入失败: %v | user_id=%s filename=%s storage_path=%s remote=%s",
			err, userID, header.Filename, path, c.ClientIP())
		c.JSON(http.StatusInternalServerError, gin.H{"error": "记录失败"})
		return
	}

	c.JSON(http.StatusCreated, gin.H{"id": f.ID, "filename": f.Filename})
}

// generateThumbnail 为已落盘的原图生成缩略图。
//
// 通过重新打开 multipart 文件读取字节（Save 已消费第一份 reader，无法复用）。
// 返回 (thumbnailPath, width, height)；任一步失败均返回零值（thumbPath=nil），
// 调用方据此把 NULL 写库，前端 ?thumb=1 自动降级原图。
//
// 缩略图 storageName = `{原图storagePath去扩展名}_thumb.jpg`，与原图同目录。
func (h *FileHandler) generateThumbnail(c *gin.Context, origPath, mime string) (thumbPath *string, width, height *int) {
	imgFile, _, err := c.Request.FormFile("file")
	if err != nil {
		log.Printf("[upload] 重新读取原图失败，跳过缩略图: %v | storage_path=%s remote=%s", err, origPath, c.ClientIP())
		return nil, nil, nil
	}
	defer imgFile.Close()

	thumbBytes, w, hh, err := imaging.GenerateThumbnail(imgFile)
	if err != nil {
		// 解码失败（损坏的图片 / 格式头不符）属于正常降级路径，仅 info 级日志。
		log.Printf("[upload] 缩略图生成失败，降级原图: %v | storage_path=%s remote=%s", err, origPath, c.ClientIP())
		return nil, nil, nil
	}

	// 去掉原图扩展名拼缩略图名：abc123.jpg → abc123_thumb.jpg
	base := origPath
	if dot := strings.LastIndex(origPath, "."); dot > 0 {
		base = origPath[:dot]
	}
	thumbName := base + thumbnailSuffix
	if err := h.storage.SaveThumbnail(thumbName, thumbBytes); err != nil {
		log.Printf("[upload] 缩略图落盘失败，降级原图: %v | thumb_name=%s remote=%s", err, thumbName, c.ClientIP())
		return nil, nil, nil
	}

	return &thumbName, &w, &hh
}

func (h *FileHandler) Download(c *gin.Context) {
	id := c.Param("id")

	f, err := h.fileRepo.GetByID(id)
	if err != nil {
		log.Printf("[download] 查询失败: %v | file_id=%s remote=%s", err, id, c.ClientIP())
		c.JSON(http.StatusNotFound, gin.H{"error": "文件不存在"})
		return
	}
	if f == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "文件不存在"})
		return
	}

	// 归属校验（防 IDOR）：只允许文件 owner 下载。
	// - user 角色：owner 就是自己，校验 f.OwnerID == userID
	// - agent 角色：agent 没有自己的文件（owner 落的是它服务的 user），校验 f.OwnerID == ownerID
	// 不校验则任何登录用户可遍历 UUID 下载他人文件。
	claimer := c.GetString("userID")
	if c.GetString("role") == "agent" {
		claimer = c.GetString("ownerID")
	}
	if claimer != f.OwnerID {
		log.Printf("[download] 归属校验失败 | file_id=%s owner=%s claimer=%s role=%s remote=%s",
			id, f.OwnerID, claimer, c.GetString("role"), c.ClientIP())
		c.JSON(http.StatusForbidden, gin.H{"error": "无权访问"})
		return
	}

	// 缩略图分支：?thumb=1 且该文件有缩略图 → 返回缩略图（体积小，消息列表场景用）。
	// 无缩略图（非图片 / 存量数据 / 生成失败）→ 自动降级返回原图，前端无感。
	wantThumb := c.Query("thumb") == "1"
	servePath := f.StoragePath
	serveMime := f.MimeType
	serveSize := f.Size
	isThumb := false
	if wantThumb && f.ThumbnailPath != nil && *f.ThumbnailPath != "" {
		servePath = *f.ThumbnailPath
		serveMime = "image/jpeg" // 缩略图统一 JPEG 编码
		isThumb = true
		// 缩略图 size 未知（未单独存库），用 io 后由 DataFromReader 按 -1 处理；
		// 这里改用实际文件读出来拿长度，见下方 reader。
	}

	reader, err := h.storage.Read(servePath)
	if err != nil {
		log.Printf("[download] 读取失败: %v | file_id=%s storage_path=%s remote=%s",
			err, id, servePath, c.ClientIP())
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取失败"})
		return
	}
	defer reader.Close()

	// 缩略图未单独存 size，DataFromReader 传 -1 时 chunked 传输也能工作，
	// 但带上 Content-Length 更好（客户端进度条 / 缓存校验）。这里不额外 stat
	// 文件（避免多一次 IO），保留原 size 仅对原图分支准确；缩略图用 -1。
	serveContentLength := serveSize
	if isThumb {
		serveContentLength = -1
	}

	// 缓存头：fileId 与内容 1:1 不可变（server 不改、不覆盖同名文件），
	// 故可安全标记 immutable + 长期 max-age。客户端 HTTP 层命中本地缓存即
	// 不再发请求（根治"每次打开重新下载"）。ETag 用 fileId 区分原图/缩略图。
	c.Header("Content-Type", serveMime)
	c.Header("Content-Disposition", "inline; filename="+f.Filename)
	c.Header("Cache-Control", "public, max-age=2592000, immutable")
	if isThumb {
		c.Header("ETag", "\""+id+"-thumb\"")
	} else {
		c.Header("ETag", "\""+id+"\"")
	}
	c.DataFromReader(http.StatusOK, serveContentLength, serveMime, reader, nil)
}
