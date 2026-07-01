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

// GetIDByUsername 反查 username → user_id(server 内部用,不暴露到 API)。
// 用于 friend request handler:client 发 to_username,server 反查 id 后写 friendships 表。
// 用户不存在返 sql.ErrNoRows,handler 转 404。
func (r *UserRepo) GetIDByUsername(username string) (string, error) {
	var id string
	err := r.db.QueryRow(`SELECT id FROM users WHERE username = $1`, username).Scan(&id)
	if err != nil {
		return "", err
	}
	return id, nil
}

// SearchByUsername 按 username 前缀模糊搜索,返回 UserSummary 列表(不含 user_id 防泄漏)。
// 用于「加好友」搜索框:用户输入 username 前缀,APP 展示匹配候选。
//
// 用 ILIKE 前缀匹配(`query%`),走 idx_users_username(UNIQUE 索引支持前缀范围扫描)。
// 大小写不敏感对齐主流 IM 习惯。limit 上限由调用方控制(spec 建议 ≤ 20)。
//
// 返回结果不含调用方自己(由 handler 层用 WHERE id != $me 过滤,本方法不知调用者身份)。
// 不存在的 username 返回空切片 + nil err,不报错。
func (r *UserRepo) SearchByUsername(query string, limit int) ([]model.UserSummary, error) {
	if limit <= 0 {
		return nil, nil
	}
	rows, err := r.db.Query(
		`SELECT username, nickname, avatar_url
		 FROM users WHERE username ILIKE $1 || '%'
		 ORDER BY username
		 LIMIT $2`,
		query, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.UserSummary
	for rows.Next() {
		var s model.UserSummary
		if err := rows.Scan(&s.Username, &s.Nickname, &s.AvatarURL); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// GetSummaryByID 按 user_id 查展示型摘要(不含 password_hash / id)。
// 用于 participant 摘要渲染等场景:服务端内部用 user_id 查,但对外暴露时不带 id。
//
// 用户不存在返 (nil, nil) 让调用方用 nil 判断分支。
func (r *UserRepo) GetSummaryByID(id string) (*model.UserSummary, error) {
	s := &model.UserSummary{}
	err := r.db.QueryRow(
		`SELECT username, nickname, avatar_url FROM users WHERE id = $1`,
		id,
	).Scan(&s.Username, &s.Nickname, &s.AvatarURL)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return s, nil
}
