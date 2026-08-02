package message

import (
	"errors"
	"fmt"
	"testing"

	"github.com/lib/pq"
)

func TestIsDeadlock(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{
			name: "PG deadlock 40P01",
			err:  &pq.Error{Code: "40P01", Message: "deadlock detected"},
			want: true,
		},
		{
			name: "PG query_canceled 57014 不是死锁",
			err:  &pq.Error{Code: "57014"},
			want: false,
		},
		{
			name: "PG 其他错误码 不是死锁",
			err:  &pq.Error{Code: "23505"},
			want: false,
		},
		{
			name: "wrapped PG deadlock 仍识别",
			err:  fmt.Errorf("取消隐藏失败: %w", &pq.Error{Code: "40P01"}),
			want: true,
		},
		{
			name: "普通 error 不是死锁",
			err:  errors.New("connection refused"),
			want: false,
		},
		{
			name: "nil 不是死锁",
			err:  nil,
			want: false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isDeadlock(tt.err); got != tt.want {
				t.Errorf("isDeadlock(%v) = %v, want %v", tt.err, got, tt.want)
			}
		})
	}
}
