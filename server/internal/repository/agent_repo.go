package repository

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"

	"github.com/wanling/server/internal/model"
)

type AgentRepo struct {
	queryExecutor
}

func NewAgentRepo(db *sql.DB) *AgentRepo {
	return &AgentRepo{queryExecutor: queryExecutor{db: db}}
}

func (r *AgentRepo) Create(ctx context.Context, ownerID, name, secretKey, agentType string) (*model.Agent, error) {
	a := &model.Agent{}
	err := r.queryRow(ctx,
		`INSERT INTO agents (owner_id, name, secret_key, type) VALUES ($1, $2, $3, $4)
		 RETURNING id, owner_id, name, avatar_url, bio, secret_key, type, created_at`,
		ownerID, name, secretKey, agentType,
	).Scan(&a.ID, &a.OwnerID, &a.Name, &a.AvatarURL, &a.Bio, &a.SecretKey, &a.Type, &a.CreatedAt)
	return a, err
}

func (r *AgentRepo) GetByID(ctx context.Context, id string) (*model.Agent, error) {
	a := &model.Agent{}
	err := r.queryRow(ctx,
		`SELECT id, owner_id, name, avatar_url, bio, secret_key, type, created_at FROM agents WHERE id = $1`,
		id,
	).Scan(&a.ID, &a.OwnerID, &a.Name, &a.AvatarURL, &a.Bio, &a.SecretKey, &a.Type, &a.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return a, err
}

func (r *AgentRepo) ListByOwner(ctx context.Context, ownerID string) ([]model.Agent, error) {
	rows, err := r.query(ctx,
		`SELECT id, owner_id, name, avatar_url, bio, secret_key, type, created_at FROM agents WHERE owner_id = $1 ORDER BY created_at LIMIT 200`,
		ownerID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var agents []model.Agent
	for rows.Next() {
		var a model.Agent
		if err := rows.Scan(&a.ID, &a.OwnerID, &a.Name, &a.AvatarURL, &a.Bio, &a.SecretKey, &a.Type, &a.CreatedAt); err != nil {
			return nil, err
		}
		agents = append(agents, a)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return agents, nil
}

// Update 更新 agent。name/avatarURL 保持 COALESCE(NULLIF) 模式（空串=不动，不支持清空）。
// bio 用指针：nil=不动，&""=清空，&"x"=更新。
// 返回更新后的完整 Agent。
func (r *AgentRepo) Update(ctx context.Context, id, name, avatarURL string, bio *string) (*model.Agent, error) {
	if bio == nil {
		// bio 不动：用原 COALESCE 模式
		if _, err := r.exec(ctx,
			`UPDATE agents SET name = COALESCE(NULLIF($1, ''), name),
			        avatar_url = COALESCE(NULLIF($2, ''), avatar_url) WHERE id = $3`,
			name, avatarURL, id,
		); err != nil {
			return nil, err
		}
	} else {
		// bio 非 nil：UPDATE 时一并设置 bio 列
		if _, err := r.exec(ctx,
			`UPDATE agents SET name = COALESCE(NULLIF($1, ''), name),
			        avatar_url = COALESCE(NULLIF($2, ''), avatar_url),
			        bio = $3 WHERE id = $4`,
			name, avatarURL, *bio, id,
		); err != nil {
			return nil, err
		}
	}
	return r.GetByID(ctx, id)
}

func (r *AgentRepo) Delete(ctx context.Context, id string) error {
	_, err := r.exec(ctx, `DELETE FROM agents WHERE id = $1`, id)
	return err
}

// UpdateType 更新 agent 的 type 标签。用于扫码配对"选已有 agent"分支:
// ticket 带 type=opencode 但老 agent.Type="" 时,补写 type 让多 session 功能生效。
func (r *AgentRepo) UpdateType(ctx context.Context, id string, agentType string) error {
	_, err := r.exec(ctx, `UPDATE agents SET type = $1 WHERE id = $2`, agentType, id)
	return err
}

// ResetSecretKey 重置 agent 的 secret_key，返回新 key。
// 扫码配对"选已有 agent"分支用：旧 hermes 持有的 key 立即失效。
// repo 内部用 crypto/rand 生成 256-bit hex，避免与 handler 包循环依赖。
// agent 不存在时返回错误（RowsAffected == 0）。
func (r *AgentRepo) ResetSecretKey(ctx context.Context, id string) (string, error) {
	newKey, err := generateKey()
	if err != nil {
		return "", err
	}
	res, err := r.exec(ctx,
		`UPDATE agents SET secret_key = $1 WHERE id = $2`,
		newKey, id,
	)
	if err != nil {
		return "", err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return "", err
	}
	if n == 0 {
		return "", errors.New("agent 不存在")
	}
	return newKey, nil
}

// generateKey 生成 256-bit hex 密钥（64 字符）。repo 内部用。
func generateKey() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// DBForTest 暴露内部 *sql.DB，仅测试用（handler 测试需要直接插入老记录构造过期场景）。
// 生产代码不应调用。
func (r *AgentRepo) DBForTest() *sql.DB { return r.queryExecutor.db }
