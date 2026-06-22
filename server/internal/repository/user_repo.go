package repository

import (
	"database/sql"
	"errors"
	"strconv"
	"strings"

	"github.com/wanling/server/internal/model"
)

type UserRepo struct {
	db *sql.DB
}

func NewUserRepo(db *sql.DB) *UserRepo {
	return &UserRepo{db: db}
}

// UpdateUserParams 用户资料更新参数。
// Nickname/Bio 用指针：nil=不动，&""=清空，&"x"=更新。
// AvatarURL 用普通 string：空串=不动（COALESCE 模式，不支持清空）。
type UpdateUserParams struct {
	Nickname  *string
	Bio       *string
	AvatarURL string
}

func (r *UserRepo) Create(username, passwordHash string) (*model.User, error) {
	u := &model.User{}
	err := r.db.QueryRow(
		`INSERT INTO users (username, password_hash) VALUES ($1, $2)
		 RETURNING id, username, nickname, bio, avatar_url, created_at`,
		username, passwordHash,
	).Scan(&u.ID, &u.Username, &u.Nickname, &u.Bio, &u.AvatarURL, &u.CreatedAt)
	if err != nil {
		return nil, err
	}
	return u, nil
}

func (r *UserRepo) GetByUsername(username string) (*model.User, error) {
	u := &model.User{}
	err := r.db.QueryRow(
		`SELECT id, username, password_hash, nickname, bio, avatar_url, created_at FROM users WHERE username = $1`,
		username,
	).Scan(&u.ID, &u.Username, &u.PasswordHash, &u.Nickname, &u.Bio, &u.AvatarURL, &u.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return u, err
}

func (r *UserRepo) GetByID(id string) (*model.User, error) {
	u := &model.User{}
	err := r.db.QueryRow(
		`SELECT id, username, password_hash, nickname, bio, avatar_url, created_at FROM users WHERE id = $1`,
		id,
	).Scan(&u.ID, &u.Username, &u.PasswordHash, &u.Nickname, &u.Bio, &u.AvatarURL, &u.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return u, err
}

// UpdatePassword 按 userID 更新 password_hash。用户不存在时返回 sql.ErrNoRows
// 让调用方区分"用户不存在"和"DB 错误"。
func (r *UserRepo) UpdatePassword(id, passwordHash string) error {
	res, err := r.db.Exec(
		`UPDATE users SET password_hash = $2 WHERE id = $1`,
		id, passwordHash,
	)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// Update 部分更新用户资料，动态构造 SET 子句：指针非 nil 才拼入。
// avatar_url 空串不动（空串跳过，不支持清空）。
// 返回更新后的完整 User（含所有字段），供 handler 直接返回。
func (r *UserRepo) Update(id string, p UpdateUserParams) (*model.User, error) {
	setClauses := []string{}
	args := []interface{}{}
	argIdx := 1

	if p.Nickname != nil {
		setClauses = append(setClauses, "nickname = $"+strconv.Itoa(argIdx))
		args = append(args, *p.Nickname)
		argIdx++
	}
	if p.Bio != nil {
		setClauses = append(setClauses, "bio = $"+strconv.Itoa(argIdx))
		args = append(args, *p.Bio)
		argIdx++
	}
	// avatar_url：空串不动
	if p.AvatarURL != "" {
		setClauses = append(setClauses, "avatar_url = $"+strconv.Itoa(argIdx))
		args = append(args, p.AvatarURL)
		argIdx++
	}

	if len(setClauses) == 0 {
		// 无字段需要更新，直接返回当前值
		return r.GetByID(id)
	}

	// WHERE id = $N，RETURNING 拿回最新值
	args = append(args, id)
	u := &model.User{}
	query := "UPDATE users SET " + strings.Join(setClauses, ", ") +
		" WHERE id = $" + strconv.Itoa(argIdx) +
		" RETURNING id, username, nickname, bio, avatar_url, created_at"
	err := r.db.QueryRow(query, args...).Scan(
		&u.ID, &u.Username, &u.Nickname, &u.Bio, &u.AvatarURL, &u.CreatedAt)
	if err != nil {
		return nil, err
	}
	return u, nil
}

// List 返回所有用户（不含密码哈希，仅元数据）。按 created_at 升序。
// 管理工具 list-users 用。生产规模大时建议加分页，当前规模不需要。
func (r *UserRepo) List() ([]*model.User, error) {
	rows, err := r.db.Query(
		`SELECT id, username, nickname, bio, avatar_url, created_at FROM users ORDER BY created_at`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var users []*model.User
	for rows.Next() {
		u := &model.User{}
		if err := rows.Scan(&u.ID, &u.Username, &u.Nickname, &u.Bio, &u.AvatarURL, &u.CreatedAt); err != nil {
			return nil, err
		}
		users = append(users, u)
	}
	return users, rows.Err()
}
