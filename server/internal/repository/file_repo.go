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
