package message

import (
	"errors"

	"github.com/lib/pq"
)

// isDeadlock 判断错误是否为 PostgreSQL 死锁 (SQLSTATE 40P01)。
// lib/pq 把 server 返回的 ErrorResponse 包装成 *pq.Error,errors.As 透传包裹层。
// 镜像 repository 包 isPQQueryCanceled(57014) 的判定模式。
func isDeadlock(err error) bool {
	var pqErr *pq.Error
	if errors.As(err, &pqErr) {
		return pqErr.Code == "40P01"
	}
	return false
}
