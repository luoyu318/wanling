# ─── Stage 1: builder ─────────────────────────────────────────
FROM golang:1.25-alpine AS builder

WORKDIR /src

# 国内构建走 goproxy.cn，否则 go mod download 拉 proxy.golang.org 会失败
ENV GOPROXY=https://goproxy.cn,direct

# 先拷依赖利用 layer 缓存
COPY go.mod go.sum ./
RUN go mod download

# 拷源码
COPY . .

# 三个二进制一起编译（CGO_ENABLED=0 出静态二进制，方便 alpine 跑）
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/wanling-server ./cmd/main.go && \
    CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/wanling-migrate ./cmd/migrate && \
    CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/wanling-admin ./cmd/admin-tool

# ─── Stage 2: runtime ─────────────────────────────────────────
FROM alpine:3.20

# ca-certificates: HTTPS 调用；tzdata: 时区；wget: healthcheck
RUN apk add --no-cache ca-certificates tzdata wget

# 非 root 用户（uid 10001 避开常见 1000 跟 host 冲突）
RUN adduser -D -u 10001 wanling
USER wanling

WORKDIR /app
COPY --from=builder /out/wanling-server /out/wanling-migrate /out/wanling-admin ./
# migrations 目录供 wanling-migrate 读取（findProjectRoot 在容器里靠 /app/migrations 兜底）
COPY --from=builder /src/migrations /app/migrations
RUN mkdir -p /app/uploads

VOLUME ["/app/uploads"]
EXPOSE 18008

# 默认 entrypoint 是 server；migrate / admin 通过 docker compose run 改 entrypoint
CMD ["/app/wanling-server"]
