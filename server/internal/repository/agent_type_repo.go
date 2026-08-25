package repository

import (
	"context"
	"database/sql"
	"fmt"

	"github.com/wanling/server/internal/model"
)

// AgentTypeRepo agent type 注册表数据访问层。
// 表极小(个位数行),直接读库不做内存缓存;调用方(List/下拉清单)低频。
type AgentTypeRepo struct {
	queryExecutor
}

func NewAgentTypeRepo(db *sql.DB) *AgentTypeRepo {
	return &AgentTypeRepo{queryExecutor: queryExecutor{db: db}}
}

// ListAll 全量拉取(GET /api/agent-types 数据源,APP 类型下拉/徽标查表用)。
// LIMIT 兜底 256:防注册表被灌脏数据拖垮响应。
func (r *AgentTypeRepo) ListAll(ctx context.Context) ([]model.AgentTypeInfo, error) {
	const q = `SELECT type, multi_session, label, badge_bg, badge_bg_elevated, badge_fg
		FROM agent_type_registry ORDER BY created_at, type LIMIT 256`
	rows, err := r.query(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("agent_type list: %w", err)
	}
	defer rows.Close()

	result := []model.AgentTypeInfo{}
	for rows.Next() {
		var e model.AgentTypeInfo
		if err := rows.Scan(&e.Type, &e.MultiSession, &e.Label, &e.BadgeBg, &e.BadgeBgElevated, &e.BadgeFg); err != nil {
			return nil, fmt.Errorf("agent_type scan: %w", err)
		}
		result = append(result, e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("agent_type rows: %w", err)
	}
	return result, nil
}

// GetByType 按 type 查单条;未注册返回 nil,nil(调用方兜底 multi_session=false)。
func (r *AgentTypeRepo) GetByType(ctx context.Context, agentType string) (*model.AgentTypeInfo, error) {
	const q = `SELECT type, multi_session, label, badge_bg, badge_bg_elevated, badge_fg
		FROM agent_type_registry WHERE type = $1`
	row := r.queryRow(ctx, q, agentType)
	var e model.AgentTypeInfo
	if err := row.Scan(&e.Type, &e.MultiSession, &e.Label, &e.BadgeBg, &e.BadgeBgElevated, &e.BadgeFg); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("agent_type get: %w", err)
	}
	return &e, nil
}
