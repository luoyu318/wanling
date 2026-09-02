package repository

import (
	"context"
	"database/sql"
	"fmt"
)

// MiniProgramOpenidRepo 小程序 openid 标识数据访问层((用户×appid) 二元组惰性生成永久稳定标识)。
type MiniProgramOpenidRepo struct {
	queryExecutor
}

func NewMiniProgramOpenidRepo(db *sql.DB) *MiniProgramOpenidRepo {
	return &MiniProgramOpenidRepo{queryExecutor: queryExecutor{db: db}}
}

// GetOrCreateOpenid 惰性生成并返回 (userID, appid) 对应的 openid。
// 首次插入由 gen_random_uuid() 默认值生成;已存在时经 DO UPDATE 触发 RETURNING 返回原值(幂等稳定)。
func (r *MiniProgramOpenidRepo) GetOrCreateOpenid(ctx context.Context, userID, appid string) (string, error) {
	const q = `INSERT INTO mini_program_openids (user_id, appid)
		VALUES ($1, $2)
		ON CONFLICT (user_id, appid) DO UPDATE SET user_id = EXCLUDED.user_id
		RETURNING openid`
	var openid string
	if err := r.queryRow(ctx, q, userID, appid).Scan(&openid); err != nil {
		return "", fmt.Errorf("mini_program_openid get_or_create: %w", err)
	}
	return openid, nil
}
