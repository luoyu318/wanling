package handler

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/imaging"
	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/repository"
	"github.com/wanling/server/internal/storage"
)

type FileHandler struct {
	fileRepo       *repository.FileRepo
	storage        storage.Provider
	maxUploadBytes int64
}

func NewFileHandler(fileRepo *repository.FileRepo, storage storage.Provider, maxUploadBytes int64) *FileHandler {
	return &FileHandler{fileRepo: fileRepo, storage: storage, maxUploadBytes: maxUploadBytes}
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

// allowedExtensions 文件上传扩展名白名单（M5 防 .html/.exe 等可执行/可渲染类型上传）。
// 同时映射到标准 mime（Content-Type 矫正用，但矫正仍只对图片做）。
var allowedExtensions = map[string]string{
	".jpg": "image/jpeg", ".jpeg": "image/jpeg",
	".png": "image/png", ".webp": "image/webp", ".gif": "image/gif",
	".pdf": "application/pdf",
	".txt": "text/plain",
	".md":  "text/markdown", ".markdown": "text/markdown",
	".csv":  "text/csv",
	".doc":  "application/msword",
	".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
	".xls":  "application/vnd.ms-excel",
	".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
	".ppt":  "application/vnd.ms-powerpoint",
	".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
	".zip":  "application/zip",
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

// extToExpectedMIME 扩展名 → http.DetectContentType 可能返回的 MIME 集合（M3 防 MIME 改名攻击）。
// 用于扩展名与实际内容交叉校验：exe 改名 jpg 时 detected=octet-stream，不在 .jpg 预期集合 → 415。
//
// 含 application/octet-stream 兜底的扩展名：DetectContentType 对部分格式（doc/旧 Office）
// 只能识别为通用二进制，需放行。Office Open XML（docx/xlsx/pptx）本质是 zip，允许 application/zip。
var extToExpectedMIME = map[string][]string{
	".jpg":      {"image/jpeg"},
	".jpeg":     {"image/jpeg"},
	".png":      {"image/png"},
	".gif":      {"image/gif"},
	".webp":     {"image/webp", "application/octet-stream"},
	".pdf":      {"application/pdf"},
	".doc":      {"application/msword", "application/octet-stream"},
	".docx":     {"application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/zip", "application/octet-stream"},
	".xls":      {"application/vnd.ms-excel", "application/octet-stream"},
	".xlsx":     {"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "application/zip", "application/octet-stream"},
	".ppt":      {"application/vnd.ms-powerpoint", "application/octet-stream"},
	".pptx":     {"application/vnd.openxmlformats-officedocument.presentationml.presentation", "application/zip", "application/octet-stream"},
	".zip":      {"application/zip", "application/x-zip-compressed", "application/octet-stream"},
	".txt":      {"text/plain", "text/html", "application/octet-stream"},
	".md":       {"text/plain", "text/markdown", "application/octet-stream"},
	".markdown": {"text/plain", "text/markdown", "application/octet-stream"},
	".csv":      {"text/plain", "text/csv", "application/octet-stream"},
}

// isAllowedMIME 校验嗅探到的真实 MIME 是否与扩展名相符。
// detected 形如 "image/png" 或 "text/plain; charset=utf-8"，先剥 charset 再比对。
// 扩展名未在映射里（理论上不会发生，因扩展名白名单已先行拦截）→ 放行。
func isAllowedMIME(detected, ext string) bool {
	expected, ok := extToExpectedMIME[ext]
	if !ok {
		return true
	}
	detected = strings.TrimSpace(strings.SplitN(detected, ";", 2)[0])
	for _, exp := range expected {
		if detected == exp {
			return true
		}
	}
	return false
}

func (h *FileHandler) Upload(c *gin.Context) {
	// 限制请求体大小，防超大文件上传耗尽内存/磁盘。
	// MaxBytesReader 对 chunked 流式上传也能逐字节拦截（仅校验 Content-Length 会被绕过）。
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, h.maxUploadBytes)

	file, header, err := c.Request.FormFile("file")
	if err != nil {
		// 区分超限（413）与其他解析错误（400）
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			Err(c, http.StatusRequestEntityTooLarge, "payload_too_large", "文件过大")
			return
		}
		// FormFile 失败常见原因：Content-Type 不是 multipart/form-data、
		// body 为空、nginx client_max_body_size 拦截后 body 已读尽。
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "upload 解析 multipart 失败",
			"err", err,
			"size", c.Request.ContentLength,
			"content_type", c.ContentType(),
			"remote", c.ClientIP())
		Err(c, http.StatusBadRequest, "bad_request", "请上传文件")
		return
	}
	defer file.Close()

	// M5: 扩展名白名单校验，防 .html/.exe 等可执行/可渲染类型上传。
	// 仅判扩展名（不依赖客户端 Content-Type，可被伪造）：非白名单 → 415。
	ext := strings.ToLower(filepath.Ext(header.Filename))
	if _, ok := allowedExtensions[ext]; !ok {
		Err(c, http.StatusUnsupportedMediaType, "unsupported_media_type", "不支持的文件类型")
		return
	}

	// M3: MIME 嗅探防改名攻击（exe 改名 jpg）。
	// http.DetectContentType 读前 512 字节判真实类型，与扩展名交叉校验。
	// 嗅探消费的 bytes 用 MultiReader 拼回，保证后续 Save 拿到完整内容。
	sniffBuf := make([]byte, 512)
	n, err := io.ReadFull(file, sniffBuf)
	if err != nil && err != io.ErrUnexpectedEOF && err != io.EOF {
		ErrMsg(c, http.StatusBadRequest, "读取文件失败")
		return
	}
	detectedType := http.DetectContentType(sniffBuf[:n])
	if !isAllowedMIME(detectedType, ext) {
		logpkg.FromCtx(c.Request.Context()).WarnContext(c.Request.Context(), "上传 MIME 不匹配",
			"ext", ext, "detected", detectedType, "filename", header.Filename, "remote", c.ClientIP())
		Err(c, http.StatusUnsupportedMediaType, "mime_mismatch", "文件内容与扩展名不匹配，请上传真实的文件")
		return
	}
	// 嗅探到的真实 MIME（剥 charset 后缀）覆盖客户端 Content-Type——后者可由客户端伪造。
	detectedMIME := strings.TrimSpace(strings.SplitN(detectedType, ";", 2)[0])
	// 拼回已读的 sniff bytes，恢复完整 reader 供 Save 消费。
	fullReader := io.MultiReader(bytes.NewReader(sniffBuf[:n]), file)

	// agent 上传时把 owner_id 落为它真正的 owner（user），让 user 能下载，
	// 同时满足 files.owner_id 外键到 users(id) 的约束（agent_id 不在 users 表，
	// 直接用会 500）。
	userID := c.GetString("userID")
	if c.GetString("role") == "agent" {
		if ownerID := c.GetString("ownerID"); ownerID != "" {
			userID = ownerID
		}
	}
	path, err := h.storage.Save(header.Filename, fullReader)
	if err != nil {
		// Save 失败常见原因：STORAGE_PATH 目录权限不足、磁盘满、路径不可写。
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "upload 存储失败",
			"err", err,
			"filename", header.Filename,
			"size", header.Size,
			"remote", c.ClientIP())
		ErrMsg(c, http.StatusInternalServerError, "存储失败")
		return
	}

	// M3: 用嗅探到的真实 MIME 替代客户端 Content-Type（可伪造）。
	mime := detectedMIME
	// 图片 mime 矫正：客户端可能传 octet-stream / 缺失，按扩展名补正。
	// 确保后续 isImageUpload 判定 + Download 返回的 Content-Type 都准确。
	// 仅图片扩展名会被改写，非图片文件保留嗅探到的 mime。
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

	f, err := h.fileRepo.Create(c.Request.Context(), repository.CreateFileParams{
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
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "upload DB 写入失败",
			"err", err,
			"user_id", userID,
			"filename", header.Filename,
			"storage_path", path,
			"remote", c.ClientIP())
		ErrMsg(c, http.StatusInternalServerError, "记录失败")
		return
	}

	// 上传时附带 conversation_id (可选,消息附件场景用):
	// 有值 → 写 file_conv_links,该会话所有 participant 都能下载此文件。
	// 头像上传不传(走 CheckAccess 的头像白名单)。转发功能未来也走此接口加 link。
	// 加 link 失败不阻断上传(文件已落库),仅记日志让 client 端走 owner 兜底也能下载。
	if convID := c.Query("conversation_id"); convID != "" {
		if err := h.fileRepo.AddConvLink(c.Request.Context(), f.ID, convID); err != nil {
			logpkg.FromCtx(c.Request.Context()).WarnContext(c.Request.Context(), "upload 加 file_conv_link 失败",
				"conv_id", convID,
				"file_id", f.ID,
				"err", err,
				"remote", c.ClientIP())
		}
	}

	OkCreated(c, gin.H{"id": f.ID, "filename": f.Filename})
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
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "upload 重新读取原图失败,跳过缩略图",
			"err", err, "storage_path", origPath, "remote", c.ClientIP())
		return nil, nil, nil
	}
	defer imgFile.Close()

	thumbBytes, w, hh, err := imaging.GenerateThumbnail(imgFile)
	if err != nil {
		// 解码失败（损坏的图片 / 格式头不符）属于正常降级路径，仅 warn 级日志。
		logpkg.FromCtx(c.Request.Context()).WarnContext(c.Request.Context(), "upload 缩略图生成失败,降级原图",
			"err", err, "storage_path", origPath, "remote", c.ClientIP())
		return nil, nil, nil
	}

	// 去掉原图扩展名拼缩略图名：abc123.jpg → abc123_thumb.jpg
	base := origPath
	if dot := strings.LastIndex(origPath, "."); dot > 0 {
		base = origPath[:dot]
	}
	thumbName := base + thumbnailSuffix
	if err := h.storage.SaveThumbnail(thumbName, thumbBytes); err != nil {
		logpkg.FromCtx(c.Request.Context()).WarnContext(c.Request.Context(), "upload 缩略图落盘失败,降级原图",
			"err", err, "thumb_name", thumbName, "remote", c.ClientIP())
		return nil, nil, nil
	}

	return &thumbName, &w, &hh
}

func (h *FileHandler) Download(c *gin.Context) {
	id := c.Param("id")

	f, err := h.fileRepo.GetByID(c.Request.Context(), id)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "download 查询失败",
			"err", err, "file_id", id, "remote", c.ClientIP())
		Err(c, http.StatusNotFound, "not_found", "文件不存在")
		return
	}
	if f == nil {
		Err(c, http.StatusNotFound, "not_found", "文件不存在")
		return
	}

	// 权限校验(三档放行,对齐 migration 018 + 主流 IM 授权模型):
	//   1. 头像白名单: file_id 出现在 users.avatar_url / agents.avatar_url 中 → 公开
	//      (社交属性,会话列表加载对方头像、点开资料页都能看)
	//   2. 会话 participant: claimer 是该 file 被引用(经 file_conv_links)的任一 conv 的 participant
	//      (私聊/群聊消息附件场景,转发不重传仅加 link,自动获得权限)
	//   3. owner 兜底: claimer 是该 file 的 owner(向后兼容老逻辑)
	// 三者都不满足才 403,防 UUID 枚举越权下载他人私有文件。
	//
	// claimer 计算: agent 用其 ownerID(agent.owner_id 是真实 user_id),
	// 这跟 owner 兜底校验时一致(agent 没有自己的文件,owner 落的是它服务的 user)。
	claimer := c.GetString("userID")
	memberType := c.GetString("role")
	if memberType == "agent" {
		if ownerID := c.GetString("ownerID"); ownerID != "" {
			claimer = ownerID
		}
	}
	access, err := h.fileRepo.CheckAccess(c.Request.Context(), id, claimer, memberType)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "download 权限校验查询失败",
			"err", err, "file_id", id, "remote", c.ClientIP())
		ErrMsg(c, http.StatusInternalServerError, "权限校验失败")
		return
	}
	if !access.Allowed() {
		logpkg.FromCtx(c.Request.Context()).WarnContext(c.Request.Context(), "download 权限校验失败",
			"file_id", id,
			"owner", f.OwnerID,
			"claimer", claimer,
			"role", memberType,
			"remote", c.ClientIP())
		Err(c, http.StatusForbidden, "forbidden", "无权访问")
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
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "download 读取失败",
			"err", err,
			"file_id", id,
			"storage_path", servePath,
			"remote", c.ClientIP())
		ErrMsg(c, http.StatusInternalServerError, "读取失败")
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
	//
	// M5: Content-Disposition 强制 attachment（防浏览器 inline 渲染存储型 XSS，
	// 如上传的图片/PDF 在浏览器中直接打开导致跨域脚本执行）；filename 用 RFC 5987
	// 编码（UTF-8 文件名非 ASCII 字符也能正确还原）。X-Content-Type-Options: nosniff
	// 防 IE/旧版浏览器 MIME sniffing 把 image/jpeg 误判成 text/html 执行。
	c.Header("Content-Type", serveMime)
	c.Header("Content-Disposition", "attachment; filename*=UTF-8''"+url.PathEscape(f.Filename))
	c.Header("X-Content-Type-Options", "nosniff")
	c.Header("Cache-Control", "public, max-age=2592000, immutable")
	if isThumb {
		c.Header("ETag", "\""+id+"-thumb\"")
	} else {
		c.Header("ETag", "\""+id+"\"")
	}
	c.DataFromReader(http.StatusOK, serveContentLength, serveMime, reader, nil)
}
