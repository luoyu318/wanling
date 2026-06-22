package repository

import (
	"database/sql"
	"errors"
)

type File struct {
	ID          string
	OwnerID     string
	Filename    string
	MimeType    string
	Size        int64
	StoragePath string
	CreatedAt   string
}

type FileRepo struct {
	db *sql.DB
}

func NewFileRepo(db *sql.DB) *FileRepo {
	return &FileRepo{db: db}
}

func (r *FileRepo) Create(ownerID, filename, mimeType string, size int64, storagePath string) (*File, error) {
	f := &File{}
	err := r.db.QueryRow(
		`INSERT INTO files (owner_id, filename, mime_type, size, storage_path)
		 VALUES ($1, $2, $3, $4, $5)
		 RETURNING id, owner_id, filename, mime_type, size, storage_path, created_at`,
		ownerID, filename, mimeType, size, storagePath,
	).Scan(&f.ID, &f.OwnerID, &f.Filename, &f.MimeType, &f.Size, &f.StoragePath, &f.CreatedAt)
	return f, err
}

func (r *FileRepo) GetByID(id string) (*File, error) {
	f := &File{}
	err := r.db.QueryRow(
		`SELECT id, owner_id, filename, mime_type, size, storage_path, created_at FROM files WHERE id = $1`,
		id,
	).Scan(&f.ID, &f.OwnerID, &f.Filename, &f.MimeType, &f.Size, &f.StoragePath, &f.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return f, err
}
