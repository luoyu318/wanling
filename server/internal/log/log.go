// Package log 提供 slog 结构化日志 + requestID 注入。
//
// 设计:
//   - log.Init() 在 main 启动时调一次,设默认 logger(JSON 输出到 stdout,systemd 兼容)
//   - middleware.RequestID() 给每个 HTTP 请求注入 request_id 到 ctx
//   - log.FromCtx(ctx) 取 ctx 中的 request_id,返带 request_id 字段的 *slog.Logger
//   - 业务代码统一用 log.FromCtx(ctx).Info/Warn/Error(...) 而非 log.Printf
//
// WS 长连接无 HTTP request 上下文,FromCtx 会拿到 request_id="-",
// 由调用方自行附加 client_id 等字段补充追踪。
package log

import (
	"context"
	"log/slog"
	"os"
)

type ctxKey struct{}

var requestIDKey = ctxKey{}

// Init 初始化默认 slog logger(JSON handler,INFO 级别,输出 stdout)。
// main.go 启动时调用一次。
func Init() {
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})
	slog.SetDefault(slog.New(h))
}

// WithRequestID 把 request_id 注入 ctx。中间件用,业务代码不直接调。
func WithRequestID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, requestIDKey, id)
}

// FromCtx 从 ctx 取 request_id,返回带 request_id 字段的 *slog.Logger。
// ctx 无 request_id 时返 "-"(WS 长连接等场景)。
// ctx 为 nil 时返带 "-" 的默认 logger,避免测试 / 早期启动路径 nil panic。
func FromCtx(ctx context.Context) *slog.Logger {
	rid := "-"
	if ctx != nil {
		if v, ok := ctx.Value(requestIDKey).(string); ok && v != "" {
			rid = v
		}
	}
	return slog.Default().With("request_id", rid)
}
