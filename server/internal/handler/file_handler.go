package handler

import (
	"log"
	"net/http"

	"github.com/gin-gonic/gin"
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

	f, err := h.fileRepo.Create(userID, header.Filename, header.Header.Get("Content-Type"), header.Size, path)
	if err != nil {
		// DB 写失败常见原因：owner_id 为空触发外键约束、DB 连接断、字段超长。
		log.Printf("[upload] DB 写入失败: %v | user_id=%s filename=%s storage_path=%s remote=%s",
			err, userID, header.Filename, path, c.ClientIP())
		c.JSON(http.StatusInternalServerError, gin.H{"error": "记录失败"})
		return
	}

	c.JSON(http.StatusCreated, gin.H{"id": f.ID, "filename": f.Filename})
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

	reader, err := h.storage.Read(f.StoragePath)
	if err != nil {
		log.Printf("[download] 读取失败: %v | file_id=%s storage_path=%s remote=%s",
			err, id, f.StoragePath, c.ClientIP())
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取失败"})
		return
	}
	defer reader.Close()

	c.Header("Content-Type", f.MimeType)
	c.Header("Content-Disposition", "inline; filename="+f.Filename)
	c.DataFromReader(http.StatusOK, f.Size, f.MimeType, reader, nil)
}
