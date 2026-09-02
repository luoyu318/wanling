package repository

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/google/uuid"

	"github.com/wanling/server/internal/model"
)

// AgentSubKeyRepo agent 子密钥数据访问层(wlsk_ 前缀凭据,REST-only 授权,
// 详见 docs/ai-handbook/agent-subkeys.md)。
type AgentSubKeyRepo struct {
	queryExecutor
}

func NewAgentSubKeyRepo(db *sql.DB) *AgentSubKeyRepo {
	return &AgentSubKeyRepo{queryExecutor: queryExecutor{db: db}}
}

// scanAgentSubKey 把一行扫描进 AgentSubKey(GetByKey/ListByAgent 共用列序)。
func scanAgentSubKey(scanner interface{ Scan(dest ...any) error }) (*model.AgentSubKey, error) {
	k := &model.AgentSubKey{}
	if err := scanner.Scan(&k.ID, &k.AgentID, &k.Name, &k.SecretKey, &k.CreatedAt, &k.LastUsedAt, &k.RevokedAt); err != nil {
		return nil, err
	}
	return k, nil
}

// Create 新建子密钥(id 由应用侧生成,表无默认值)。secret_key 由调用方生成传入。
func (r *AgentSubKeyRepo) Create(ctx context.Context, agentID, name, secretKey string) (*model.AgentSubKey, error) {
	const q = `INSERT INTO agent_sub_keys (id, agent_id, name, secret_key)
		VALUES ($1, $2, $3, $4)
		RETURNING id, agent_id, name, secret_key, created_at, last_used_at, revoked_at`
	k, err := scanAgentSubKey(r.queryRow(ctx, q, uuid.NewString(), agentID, name, secretKey)) // 必须走 queryExecutor(审计 H4)
	if err != nil {
		return nil, fmt.Errorf("agent_sub_key create: %w", err)
	}
	return k, nil
}

// GetByKey 按凭据查子密钥。含已吊销记录也返回(调用方判 RevokedAt);
// 不存在返回 (nil, nil)(跟随 AgentRepo.GetByID 惯例)。
func (r *AgentSubKeyRepo) GetByKey(ctx context.Context, secretKey string) (*model.AgentSubKey, error) {
	const q = `SELECT id, agent_id, name, secret_key, created_at, last_used_at, revoked_at
		FROM agent_sub_keys WHERE secret_key = $1`
	k, err := scanAgentSubKey(r.queryRow(ctx, q, secretKey)) // 必须走 queryExecutor(审计 H4)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("agent_sub_key get_by_key: %w", err)
	}
	return k, nil
}

// ListByAgent 列出 agent 的全部子密钥(含已吊销),created_at DESC 新的在前。
func (r *AgentSubKeyRepo) ListByAgent(ctx context.Context, agentID string) ([]model.AgentSubKey, error) {
	const q = `SELECT id, agent_id, name, secret_key, created_at, last_used_at, revoked_at
		FROM agent_sub_keys WHERE agent_id = $1 ORDER BY created_at DESC`
	rows, err := r.query(ctx, q, agentID) // 必须走 queryExecutor(审计 H4)
	if err != nil {
		return nil, fmt.Errorf("agent_sub_key list: %w", err)
	}
	defer rows.Close()

	var result []model.AgentSubKey
	for rows.Next() {
		k, err := scanAgentSubKey(rows)
		if err != nil {
			return nil, fmt.Errorf("agent_sub_key scan: %w", err)
		}
		result = append(result, *k)
	}
	if err := rows.Err(); err != nil { // rows.Err 校验(审计 M14)
		return nil, fmt.Errorf("agent_sub_key rows: %w", err)
	}
	return result, nil
}

// CountActive 统计 agent 未吊销的子密钥数量(revoked_at IS NULL)。
func (r *AgentSubKeyRepo) CountActive(ctx context.Context, agentID string) (int, error) {
	const q = `SELECT COUNT(*) FROM agent_sub_keys WHERE agent_id = $1 AND revoked_at IS NULL`
	var n int
	if err := r.queryRow(ctx, q, agentID).Scan(&n); err != nil {
		return 0, fmt.Errorf("agent_sub_key count_active: %w", err)
	}
	return n, nil
}

// Revoke 吊销单个子密钥。WHERE 带 revoked_at IS NULL 保证幂等:二次吊销不报错且不覆盖原时间。
func (r *AgentSubKeyRepo) Revoke(ctx context.Context, id string) error {
	const q = `UPDATE agent_sub_keys SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL`
	if _, err := r.exec(ctx, q, id); err != nil {
		return fmt.Errorf("agent_sub_key revoke: %w", err)
	}
	return nil
}

// RevokeAllForAgent 吊销 agent 名下全部未吊销子密钥(跨 agent 严格隔离)。
func (r *AgentSubKeyRepo) RevokeAllForAgent(ctx context.Context, agentID string) error {
	const q = `UPDATE agent_sub_keys SET revoked_at = now() WHERE agent_id = $1 AND revoked_at IS NULL`
	if _, err := r.exec(ctx, q, agentID); err != nil {
		return fmt.Errorf("agent_sub_key revoke_all: %w", err)
	}
	return nil
}

// TouchLastUsed 刷新最后使用时间(鉴权成功时调用)。
func (r *AgentSubKeyRepo) TouchLastUsed(ctx context.Context, id string) error {
	const q = `UPDATE agent_sub_keys SET last_used_at = now() WHERE id = $1`
	if _, err := r.exec(ctx, q, id); err != nil {
		return fmt.Errorf("agent_sub_key touch_last_used: %w", err)
	}
	return nil
}

// DBForTest 供同包测试取底层连接(事务场景用),业务代码禁止使用。
func (r *AgentSubKeyRepo) DBForTest() *sql.DB { return r.queryExecutor.db }
