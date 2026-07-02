package repository

import (
	"database/sql"
	"errors"
)

type File struct {
	ID            string
	OwnerID       string
	Filename      string
	MimeType      string
	Size          int64
	StoragePath   string
	CreatedAt     string
	ThumbnailPath *string // 缩略图存储路径，NULL 表示无缩略图（非图片 / 生成失败 / 存量数据）
	Width         *int    // 原图宽（px），仅图片类型有值
	Height        *int    // 原图高（px），仅图片类型有值
}

type FileRepo struct {
	db *sql.DB
}

func NewFileRepo(db *sql.DB) *FileRepo {
	return &FileRepo{db: db}
}

// CreateFileParams Create 的参数集合，避免参数过多导致调用方难以阅读。
type CreateFileParams struct {
	OwnerID       string
	Filename      string
	MimeType      string
	Size          int64
	StoragePath   string
	ThumbnailPath *string // 可空
	Width         *int    // 可空
	Height        *int    // 可空
}

func (r *FileRepo) Create(p CreateFileParams) (*File, error) {
	f := &File{}
	err := r.db.QueryRow(
		`INSERT INTO files (owner_id, filename, mime_type, size, storage_path, thumbnail_path, width, height)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		 RETURNING id, owner_id, filename, mime_type, size, storage_path, created_at, thumbnail_path, width, height`,
		p.OwnerID, p.Filename, p.MimeType, p.Size, p.StoragePath, p.ThumbnailPath, p.Width, p.Height,
	).Scan(&f.ID, &f.OwnerID, &f.Filename, &f.MimeType, &f.Size, &f.StoragePath, &f.CreatedAt,
		&f.ThumbnailPath, &f.Width, &f.Height)
	return f, err
}

func (r *FileRepo) GetByID(id string) (*File, error) {
	f := &File{}
	err := r.db.QueryRow(
		`SELECT id, owner_id, filename, mime_type, size, storage_path, created_at, thumbnail_path, width, height
		 FROM files WHERE id = $1`,
		id,
	).Scan(&f.ID, &f.OwnerID, &f.Filename, &f.MimeType, &f.Size, &f.StoragePath, &f.CreatedAt,
		&f.ThumbnailPath, &f.Width, &f.Height)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return f, err
}

// AddConvLink 把文件关联到会话(幂等)。用于消息附件上传 + 未来转发场景。
// 同 (file_id, conv_id) 重复调用安全(ON CONFLICT DO NOTHING)。
//
// 设计见 migration 018: 主流 IM 共享文件指针模式,转发时不重传,
// 仅 INSERT 一行 file_conv_links,新会话成员自动获得下载权限。
func (r *FileRepo) AddConvLink(fileID, convID string) error {
	_, err := r.db.Exec(`
		INSERT INTO file_conv_links (file_id, conv_id)
		VALUES ($1, $2)
		ON CONFLICT DO NOTHING`,
		fileID, convID)
	return err
}

// FileAccessResult 是 [FileRepo.CheckAccess] 的返回,带详细原因供日志记录。
// 三个放行条件任一为 true 即可下载(对齐主流 IM 授权模型,见 migration 018):
//   - IsOwner: claimer 是文件 owner(向后兼容老逻辑)
//   - IsAvatar: 文件是某 user/agent 的头像(社交公开属性,任何登录用户可看)
//   - IsConvParticipant: claimer 是该文件被引用的任一会话的 participant
type FileAccessResult struct {
	IsOwner           bool
	IsUserAvatar      bool
	IsAgentAvatar     bool
	IsConvParticipant bool
}

// IsAvatar 任一头像标志命中即视为头像公开文件。
func (r FileAccessResult) IsAvatar() bool {
	return r.IsUserAvatar || r.IsAgentAvatar
}

// Allowed 任一放行条件满足即允许下载。
func (r FileAccessResult) Allowed() bool {
	return r.IsOwner || r.IsAvatar() || r.IsConvParticipant
}

// CheckAccess 一次 SQL 综合校验文件下载权限。
// 文件不存在返 (零值, nil),由调用方按 404 处理。
//
// 三档放行(任一即 OK,对齐 migration 018 设计):
//  1. 头像白名单: file_id 出现在 users.avatar_url 或 agents.avatar_url 中
//  2. 会话 participant: claimer 是该 file 被引用(经 file_conv_links)的任一 conv 的 participant
//  3. owner 兜底: claimer 是该 file 的 owner_id
//
// 单次查询拿全三个判断,避免分多次 SQL 增加下载延迟。
func (r *FileRepo) CheckAccess(fileID, claimerID, memberType string) (FileAccessResult, error) {
	var res FileAccessResult
	err := r.db.QueryRow(`
		SELECT
			(f.owner_id = $2) AS is_owner,
			EXISTS(SELECT 1 FROM users WHERE avatar_url = '/api/files/' || f.id::text) AS is_user_avatar,
			EXISTS(SELECT 1 FROM agents WHERE avatar_url = '/api/files/' || f.id::text) AS is_agent_avatar,
			EXISTS(
				SELECT 1 FROM file_conv_links l
				JOIN conversation_participants p
				  ON p.conv_id = l.conv_id AND p.member_id = $2 AND p.member_type = $3
				WHERE l.file_id = f.id
			) AS is_participant
		FROM files f WHERE f.id = $1`,
		fileID, claimerID, memberType,
	).Scan(&res.IsOwner, &res.IsUserAvatar, &res.IsAgentAvatar, &res.IsConvParticipant)
	if errors.Is(err, sql.ErrNoRows) {
		return FileAccessResult{}, nil
	}
	if err != nil {
		return FileAccessResult{}, err
	}
	return res, nil
}
