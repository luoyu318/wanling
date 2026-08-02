package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/joho/godotenv"
	"github.com/redis/go-redis/v9"
	"github.com/wanling/server/internal/agent"
	"github.com/wanling/server/internal/approval"
	"github.com/wanling/server/internal/auth"
	"github.com/wanling/server/internal/config"
	"github.com/wanling/server/internal/handler"
	"github.com/wanling/server/internal/hub"
	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/message"
	"github.com/wanling/server/internal/middleware"
	"github.com/wanling/server/internal/pair"
	"github.com/wanling/server/internal/presence"
	"github.com/wanling/server/internal/ratelimit"
	"github.com/wanling/server/internal/repository"
	"github.com/wanling/server/internal/storage"
)

func main() {
	_ = godotenv.Load() //nolint:errcheck // .env 可不存在（生产用环境变量），失败不致命
	logpkg.Init()
	cfg, err := config.Load()
	if err != nil {
		log.Fatal("配置加载失败:", err)
	}

	db, err := repository.NewDB(cfg.DB)
	if err != nil {
		log.Fatal("数据库连接失败:", err)
	}
	defer db.Close()

	store, err := storage.NewLocalStorage(cfg.Storage.Path)
	if err != nil {
		log.Fatal("初始化存储失败:", err)
	}

	userRepo := repository.NewUserRepo(db)
	agentRepo := repository.NewAgentRepo(db)
	convRepo := repository.NewConversationRepo(db)
	msgRepo := repository.NewMessageRepo(db)
	fileRepo := repository.NewFileRepo(db)
	pairRepo := repository.NewPairingRepo(db)
	// participants 模型新增的两 repo:
	// - participantRepo:N 方参与者关系 + 个人维度(unread_count/pin/hide)
	// - deliveryRepo:per-recipient 投递状态(read_at)
	// MessageProcessor 在事务内调它们的 *Tx 方法保证 4 个写操作原子性。
	participantRepo := repository.NewParticipantRepo(db)
	deliveryRepo := repository.NewDeliveryRepo(db)
	friendshipRepo := repository.NewFriendshipRepo(db)

	rdb := redis.NewClient(&redis.Options{
		Addr:     cfg.Redis.Host + ":" + strconv.Itoa(cfg.Redis.Port),
		Password: cfg.Redis.Password,
		DB:       cfg.Redis.DB,
	})

	// Redis 是可选增强：连不上不致命，降级到单机模式。
	// - presence：方法对 nil rdb 短路返回（在线状态恒为离线，IM 体验略降）。
	// - ratelimit：传 nil 走内存限流（仅单实例有效），不阻塞业务。
	// 多实例部署仍需 Redis 保证一致限流 / 在线状态，此时 Ping 失败应查部署。
	p := presence.New(rdb)
	if err := p.Ping(); err != nil {
		logpkg.FromCtx(context.Background()).WarnContext(context.Background(), "Redis 连接失败,降级单机模式(限流/在线状态仅本实例有效)", "err", err)
		rdb = nil
	}

	// tokenStore 强依赖 Redis：rdb 为 nil（降级模式）时传 nil，
	// AuthMiddlewareWithStore / issueTokenPair 内部 nil-safe 跳过 Redis 检查，
	// access token 仍可签发，但 refresh/logout/tokenver 失效等增强能力不可用。
	var tokenStore *auth.TokenStore
	if rdb != nil {
		tokenStore = auth.NewTokenStore(rdb)
	}

	// RPCRegistry 单例:RPC pending map,WSHandler 接收 OpPluginResult 时查找;
	// 同时注入 Hub,plugin 断线时 Unregister 调 CancelAllForAgent 让 APP 立即收 -32003。
	rpcRegistry := hub.NewRPCRegistry()
	h := hub.NewHub(p, agentRepo, participantRepo, rpcRegistry)
	h.SetHeartbeatTimeout(cfg.Hub.HeartbeatTimeout)
	// hub 事件循环 ctx:优雅关闭时先 cancel hub,再 srv.Shutdown,确保 dispatch 队列排空
	hubCtx, hubCancel := context.WithCancel(context.Background())
	defer hubCancel()
	go h.Run(hubCtx)

	// AgentRegistry 单例:plugin 上报的可选模型清单内存缓存。
	// server 重启清空,plugin 重连后 1-2 秒内重新上报(WS onopen 触发 loadProviderNames)。
	// AGENT_MODELS 事件经 Processor.HandleIncoming 写入,REST /api/agents/:id/models 读取。
	agentRegistry := agent.NewAgentRegistry()
	// SlashCatalogRegistry 单例:plugin 上报的命令清单内存缓存,与 AgentRegistry 同构。
	// AGENT_SLASH_CATALOG 事件写入,REST /api/agents/:id/slash-catalog 读取(Task 6 引入)。
	slashCatalogRegistry := agent.NewSlashCatalogRegistry()
	// CapabilityRegistry 单例:plugin 上报的 RPC 方法清单内存缓存,与 AgentRegistry 同构。
	// PLUGIN_CAPABILITIES 事件写入,RPC 路由层 + REST 读取(Phase 2 引入)。
	capabilityRegistry := agent.NewCapabilityRegistry()
	processor := message.NewProcessor(h, convRepo, msgRepo, agentRepo, userRepo, fileRepo, participantRepo, deliveryRepo, agentRegistry, slashCatalogRegistry, capabilityRegistry)

	authHandler := handler.NewAuthHandler(userRepo, agentRepo, cfg.JWT.Secret, tokenStore, cfg.JWT.AccessTTL, cfg.JWT.RefreshTTL)
	agentHandler := handler.NewAgentHandler(agentRepo, convRepo, p, agentRegistry, slashCatalogRegistry)
	convHandler := handler.NewConversationHandler(db, convRepo, participantRepo, friendshipRepo, msgRepo, deliveryRepo, agentRepo, userRepo, h, rpcRegistry)
	fileHandler := handler.NewFileHandler(fileRepo, store, cfg.Storage.MaxUploadBytes)
	userHandler := handler.NewUserHandler(userRepo, tokenStore, cfg.JWT.Secret, cfg.JWT.AccessTTL, cfg.JWT.RefreshTTL)
	wsHandler := handler.NewWSHandler(h, cfg.JWT.Secret, cfg.WS.AllowedOrigins, processor.HandleIncoming, rpcRegistry)
	rpcHandler := handler.NewRPCHandler(agentRepo, h, rpcRegistry, capabilityRegistry, convRepo)

	msgHandler := handler.NewMessageHandler(msgRepo, convRepo, participantRepo, userRepo, agentRepo, h)
	msgHandler.SetMaxBatchDelete(cfg.Message.MaxBatchDelete)
	msgHandler.SetRecallWindow(cfg.Message.RecallWindow)

	sendHandler := handler.NewSendHandler(processor)

	pairHandler := handler.NewPairingHandler(pairRepo, agentRepo, convRepo)

	approvalRepo := repository.NewApprovalRepo(db)
	approvalSvc := approval.NewService(approvalRepo, h, approvalRepo)
	approvalHandler := handler.NewApprovalHandler(
		approvalRepo, msgRepo, convRepo, agentRepo, participantRepo, h, approvalSvc,
	)

	// participants 模型新增的三个 handler
	groupHandler := handler.NewGroupHandler(db, convRepo, participantRepo, h)
	friendshipHandler := handler.NewFriendshipHandler(friendshipRepo, userRepo, h)
	userSearchHandler := handler.NewUserSearchHandler(userRepo)

	// 扫码配对限流：
	// - GET /tickets/:id 按 IP 60/min（hermes 端 2s 一次轮询 ×30 并发足够）
	// - POST /complete 按 user 10/min（防枚举/滥用）
	pairGetLimiter := ratelimit.New(ratelimit.Options{
		Window:  time.Minute,
		Max:     60,
		KeyFunc: func(c *gin.Context) string { return c.ClientIP() },
		Redis:   rdb,
		Prefix:  "rl:pair_get:",
	})
	pairCompleteLimiter := ratelimit.New(ratelimit.Options{
		Window:  time.Minute,
		Max:     10,
		KeyFunc: func(c *gin.Context) string { return c.GetString("userID") },
		Redis:   rdb,
		Prefix:  "rl:pair_complete:",
	})

	// 审批发起限流：20/min/会话（key=agent_id:conv_id），防 agent 异常刷屏。
	approvalCreateLimiter := ratelimit.New(ratelimit.Options{
		Window: time.Minute,
		Max:    20,
		KeyFunc: func(c *gin.Context) string {
			// agentAuth 中间件写入 userID 字段实际是 agent_id（JWT sub）
			return c.GetString("userID") + ":" + c.Param("id")
		},
		Redis:  rdb,
		Prefix: "rl:approval_create:",
	})

	// user 搜索限流：30/min/user（spec §4.2 防枚举 username）
	userSearchLimiter := ratelimit.New(ratelimit.Options{
		Window:  time.Minute,
		Max:     30,
		KeyFunc: func(c *gin.Context) string { return c.GetString("userID") },
		Redis:   rdb,
		Prefix:  "rl:user_search:",
	})

	// 加好友请求限流：10/min/user（spec §4.2 防滥用）
	friendRequestLimiter := ratelimit.New(ratelimit.Options{
		Window:  time.Minute,
		Max:     10,
		KeyFunc: func(c *gin.Context) string { return c.GetString("userID") },
		Redis:   rdb,
		Prefix:  "rl:friend_request:",
	})

	// 登录限流：5/min/IP（密码撞库防御）
	loginLimiter := ratelimit.New(ratelimit.Options{
		Window:  time.Minute,
		Max:     5,
		KeyFunc: func(c *gin.Context) string { return c.ClientIP() },
		Redis:   rdb,
		Prefix:  "rl:login:",
	})

	// Agent Token 限流：10/min/IP（secret_key 撞库防御）
	agentTokenLimiter := ratelimit.New(ratelimit.Options{
		Window:  time.Minute,
		Max:     10,
		KeyFunc: func(c *gin.Context) string { return c.ClientIP() },
		Redis:   rdb,
		Prefix:  "rl:agent_token:",
	})

	// refresh 限流：10/min/IP（防 refresh token 撞库 / 滥用轮换）
	refreshLimiter := ratelimit.New(ratelimit.Options{
		Window:  time.Minute,
		Max:     10,
		KeyFunc: func(c *gin.Context) string { return c.ClientIP() },
		Redis:   rdb,
		Prefix:  "rl:refresh:",
	})

	// RPC 调用限流:60/min/user,防 plugin 调用滥用(每用户每分钟最多 60 次 RPC)。
	// key=userID,Prefix=rl:rpc:,与现有 limiter 同构(Redis 可用走 Redis,nil 走内存兜底)。
	rpcLimiter := ratelimit.New(ratelimit.Options{
		Window:  time.Minute,
		Max:     60,
		KeyFunc: func(c *gin.Context) string { return c.GetString("userID") },
		Redis:   rdb,
		Prefix:  "rl:rpc:",
	})

	// 后台清理过期票据：每 10 分钟扫一次，删 1 小时前的记录。
	// 随 server 生命周期结束（main 退出时 ctx 取消）。
	cleanupCtx, cleanupCancel := context.WithCancel(context.Background())
	defer cleanupCancel()
	go pair.RunCleanup(cleanupCtx, pairRepo, 10*time.Minute, time.Hour)

	// 后台清理过期审批：每分钟扫一次（间隔短，因为审批 1 分钟超时），dispatch APPROVAL_EXPIRED。
	go approval.RunCleanup(cleanupCtx, approvalSvc, approvalSvc, h, time.Minute)

	// 不用 gin.Default()：它自带的 Logger 会把 NoRoute 的 404（公网扫描器探测
	// /mcp /actuator/health /HNAP1 等）也打到 access log，污染 journalctl。
	// 改为手动组装：Recovery（panic 兜底，必须保留）+ BusinessAccessLog（仅记录
	// 命中注册路由的请求，扫描器的 404 静默）+ 原 CORS 中间件。
	r := gin.New()
	// 限制 multipart 解析的内存缓冲阈值，超出部分落临时文件而非堆内存。
	// 与 file_handler 的 MaxBytesReader（按字节拦截请求体）配合，防超大上传耗尽内存。
	r.MaxMultipartMemory = cfg.Storage.MaxUploadBytes
	r.Use(gin.Recovery())
	r.Use(middleware.RequestID())
	r.Use(handler.BusinessAccessLog())

	// 全局 JSON body 限制(防超大 JSON 请求体耗内存)。
	// /api/upload 路由由 file_handler 自带的 MaxBytesReader 拦截(更大),跳过本中间件。
	// /ws 路由读取二进制帧,也跳过(由 ws_handler.SetReadLimit 64KB 兜底)。
	maxJSONBody := cfg.Server.MaxJSONBodyBytes
	r.Use(func(c *gin.Context) {
		if c.Request.URL.Path != "/api/upload" && c.Request.URL.Path != "/ws" {
			c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxJSONBody)
		}
		c.Next()
	})

	// CORS:fail-closed 默认。env CORS_ALLOWED_ORIGINS 未配 → 不放行任何跨域(仅同源可访问);
	// 显式配 "*" 才放行所有。生产单域名建议显式列出。
	if len(cfg.CORS.AllowedOrigins) == 0 {
		logpkg.FromCtx(context.Background()).WarnContext(context.Background(), "CORS_ALLOWED_ORIGINS 未配置,/api/* 仅同源可访问(生产请显式列出域名)")
	}
	r.Use(func(c *gin.Context) {
		origin := c.Request.Header.Get("Origin")
		allowed := false
		for _, o := range cfg.CORS.AllowedOrigins {
			if o == "*" || o == origin {
				allowed = true
				break
			}
		}
		if allowed && origin != "" {
			c.Header("Access-Control-Allow-Origin", origin)
		}
		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Content-Type, Authorization")
		if c.Request.Method == "OPTIONS" {
			c.AbortWithStatus(204)
			return
		}
		c.Next()
	})

	// 给所有 /api/* 路由加 30s 超时兜底。
	// /ws(长连接)和 /health(健康检查)由中间件内部判断 path 跳过,可以全局挂。
	// ctx 经 c.Request.WithContext 下沉,repos 调 *Context() 变体时自动消费此 ctx,
	// 在 client 不断但 PG 慢的场景,30s 强制返回释放连接。
	r.Use(handler.TimeoutMiddleware(30 * time.Second))

	r.POST("/api/auth/login", loginLimiter, authHandler.Login)
	r.POST("/api/agents/:id/token", agentTokenLimiter, authHandler.AgentToken)
	r.POST("/api/auth/refresh", refreshLimiter, authHandler.Refresh)
	r.POST("/api/auth/logout", handler.AuthMiddlewareWithStore(cfg.JWT.Secret, tokenStore, "user"), authHandler.Logout)

	// 扫码配对：前 2 个匿名（凭 ticket_id 鉴权），后 2 个 user JWT。
	// GET 加 IP 限流防 ticket_id 枚举；complete 加 user 限流防滥用。
	r.POST("/api/pair/tickets", pairHandler.CreateTicket)
	r.GET("/api/pair/tickets/:id", pairGetLimiter, pairHandler.GetTicket)

	pairAuth := r.Group("", handler.AuthMiddlewareWithStore(cfg.JWT.Secret, tokenStore, "user"))
	{
		pairAuth.POST("/api/pair/tickets/:id/scan", pairHandler.ScanTicket)
		pairAuth.POST("/api/pair/tickets/:id/complete", pairCompleteLimiter, pairHandler.CompleteTicket)
	}

	userAuth := r.Group("", handler.AuthMiddlewareWithStore(cfg.JWT.Secret, tokenStore, "user"))
	{
		userAuth.GET("/api/agents", agentHandler.List)
		userAuth.POST("/api/agents", agentHandler.Create)
		userAuth.PUT("/api/agents/:id", agentHandler.Update)
		userAuth.DELETE("/api/agents/:id", agentHandler.Delete)
		// 重置密钥:owner 自助轮换,旧连接立即失效。新 key 仅本次响应下发。
		userAuth.POST("/api/agents/:id/rotate-secret", agentHandler.RotateSecret)
		// 模型清单:plugin 通过 WS AGENT_MODELS 上报 → registry 缓存 → 本端点供 APP 读取(Task 3)。
		// 空清单也返 200(plugin 离线 / server 重启 / opencode 未就绪 均合法)。
		userAuth.GET("/api/agents/:id/models", agentHandler.Models)
		// 命令清单: plugin 通过 WS AGENT_SLASH_CATALOG 上报 → registry 缓存 → 本端点供 APP 读取。
		userAuth.GET("/api/agents/:id/slash-catalog", agentHandler.SlashCatalog)
		// RPC 调用:APP → server 转 OpPluginCall WS 给 plugin,等回包后返 HTTP 响应。
		// JSON-RPC 2.0 envelope(详见 docs/superpowers/specs/2026-07-19-rpc-protocol-design.md §6.1),
		// 与其他 agent REST 端点的 {ok, data, error} envelope 不同。
		// 挂 rpcLimiter(60/min/user)防滥用。
		userAuth.POST("/api/agents/:id/rpc", rpcLimiter, rpcHandler.Call)
		// RPC 方法清单:plugin 通过 WS PLUGIN_CAPABILITIES 上报 → capabilityRegistry 缓存 → 本端点供 APP 读取。
		// 对称 /models + /slash-catalog,空清单返 200 + updated_at=null。
		userAuth.GET("/api/agents/:id/rpc-methods", rpcHandler.Methods)
		// user 视角查某 agent 的 agent_session 群(APP 二级列表页:点 opencode agent → 列出所有 session 实例)
		userAuth.GET("/api/agents/:id/sessions", convHandler.ListAgentSessions)
		// 会话相关
		userAuth.GET("/api/conversations", convHandler.List)
		userAuth.POST("/api/conversations", convHandler.Create)
		userAuth.GET("/api/conversations/:id", convHandler.Get)
		userAuth.GET("/api/conversations/:id/unread", convHandler.UnreadInfo)
		userAuth.GET("/api/conversations/:id/messages", convHandler.Messages)
		userAuth.POST("/api/conversations/:id/read", convHandler.MarkRead)
		userAuth.POST("/api/conversations/:id/messages/read", convHandler.MarkMessagesRead)
		// 停止生成:user 点击停止按钮 → server dispatch GENERATION_ABORT 给 agent(plugin)
		userAuth.POST("/api/conversations/:id/abort", convHandler.AbortGeneration)
		userAuth.POST("/api/messages", sendHandler.Send)
		// 跨页跳转:点击引用块取 target + 前后 N 条上下文(handler 内 participant 权限校验)
		userAuth.GET("/api/messages/:id/context", msgHandler.GetMessageContext)
		userAuth.POST("/api/conversations/:id/pin", convHandler.Pin)
		userAuth.DELETE("/api/conversations/:id/pin", convHandler.Unpin)
		userAuth.DELETE("/api/conversations/:id", convHandler.Hide)
		// 群管理(spec §4.1):邀请 / 踢人 / 退群 / 改群信息
		userAuth.PATCH("/api/conversations/:id", groupHandler.Update)
		userAuth.POST("/api/conversations/:id/participants", groupHandler.InviteMember)
		userAuth.DELETE("/api/conversations/:id/participants/:member_id", groupHandler.KickMember)
		userAuth.POST("/api/conversations/:id/leave", groupHandler.Leave)
		// 用户资料
		userAuth.GET("/api/users/me", userHandler.GetMe)
		userAuth.PUT("/api/users/me", userHandler.UpdateMe)
		userAuth.PUT("/api/users/me/password", userHandler.ChangePassword)
		// 好友系统(spec §4.2):用户搜索 + 好友请求 + 好友列表
		userAuth.GET("/api/users/search", userSearchLimiter, userSearchHandler.Search)
		// 用户详情页（按 username 查 UserSummary，不暴露 user_id）
		userAuth.GET("/api/users/by-username/:username", userSearchHandler.GetByUsername)
		userAuth.POST("/api/users/me/friend-requests", friendRequestLimiter, friendshipHandler.CreateRequest)
		userAuth.GET("/api/users/me/friend-requests/incoming", friendshipHandler.ListIncoming)
		userAuth.GET("/api/users/me/friend-requests/outgoing", friendshipHandler.ListOutgoing)
		userAuth.GET("/api/users/me/friends", friendshipHandler.ListFriends)
		userAuth.DELETE("/api/users/me/friends/:username", friendshipHandler.RemoveFriend)
		userAuth.POST("/api/friend-requests/:id/accept", friendshipHandler.Accept)
		userAuth.POST("/api/friend-requests/:id/reject", friendshipHandler.Reject)
		userAuth.POST("/api/friend-requests/:id/cancel", friendshipHandler.Cancel)
	}

	// 文件相关：user 和 agent 都可访问。
	// - user：APP 上传图片给 agent 看，下载 agent 发的图片
	// - agent：hermes adapter 下载 user 发的图片（inbound），上传 agent 发的图片（outbound）
	// 单独分组避免影响 userAuth 的语义。
	fileAuth := r.Group("", handler.AuthMiddlewareWithStore(cfg.JWT.Secret, tokenStore, "user", "agent"))
	{
		fileAuth.POST("/api/upload", fileHandler.Upload)
		fileAuth.GET("/api/files/:id", fileHandler.Download)
	}

	// 消息删除:user 和 agent 都可删自己的消息。
	// 单独分组(user+agent),不挂 userAuth(仅 user)以免 agent 无法删。
	msgAuth := r.Group("", handler.AuthMiddlewareWithStore(cfg.JWT.Secret, tokenStore, "user", "agent"))
	{
		msgAuth.DELETE("/api/messages/:id", msgHandler.Delete)
		msgAuth.PATCH("/api/messages/:id", msgHandler.UpdateContent)
		msgAuth.POST("/api/messages/batch-delete", msgHandler.BatchDelete)
	}

	// === 审批消息路由 ===
	// agent 在会话中发起审批卡片：限流 20/min/会话
	agentAuth := r.Group("", handler.AuthMiddlewareWithStore(cfg.JWT.Secret, tokenStore, "agent"))
	{
		agentAuth.POST("/api/conversations/:id/approvals", approvalCreateLimiter, approvalHandler.CreateApproval)
		// agent 视角 findOrCreate：用于审批卡片等场景，agent 主动建立/获取会话
		// （无 user 先发消息时也能拿到 conv_id）。跟 user 的 POST /api/conversations 对称。
		agentAuth.POST("/api/agents/me/conversations", convHandler.CreateAsAgent)
		agentAuth.GET("/api/agents/me/conversations", convHandler.ListAsAgent)
		// agent 视角改会话标题(opencode-plugin ensureConversation 异步改名用)
		agentAuth.PATCH("/api/agents/me/conversations/:id/title", convHandler.UpdateTitleAsAgent)
		// agent 视角同步 session 元数据(plugin session.updated 事件触发)
		agentAuth.PATCH("/api/agents/me/conversations/:id/session-meta", convHandler.UpdateSessionMetaAsAgent)
		// agent 通过 REST 发消息（plugin 发交互卡片用），复用 PersistAndDispatch，
		// 同步返 message_id 供 plugin 存 card_store 追踪卡片↔request 映射。
		agentAuth.POST("/api/conversations/:id/messages", sendHandler.SendAsAgent)
	}

	// user 决策审批（同意/拒绝）
	userAuth.POST("/api/approvals/:id/decide", approvalHandler.Decide)

	// 双角色查审批详情（user + agent 都可，用于兜底/刷新）
	fileAuth.GET("/api/approvals/:id", approvalHandler.Get)

	r.GET("/ws", gin.WrapH(wsHandler))

	r.GET("/health", func(c *gin.Context) {
		c.JSON(200, gin.H{"status": "ok"})
	})

	// /ready 验依赖连通性,供 docker / k8s healthcheck 区分进程存活 vs 依赖就绪。
	// DB 必须可达;Redis 是可选增强(启动时连不上已降级为单机模式),不可达不算不健康。
	r.GET("/ready", func(c *gin.Context) {
		ctx := c.Request.Context()
		if err := db.PingContext(ctx); err != nil {
			c.JSON(503, gin.H{"status": "unhealthy", "error": "db unreachable"})
			return
		}
		if rdb != nil {
			if err := rdb.Ping(ctx).Err(); err != nil {
				c.JSON(503, gin.H{"status": "unhealthy", "error": "redis unreachable"})
				return
			}
		}
		c.JSON(200, gin.H{"status": "ready"})
	})

	// 优雅关闭：SIGTERM/SIGINT 时先停止 accept 新连接，
	// 等活跃请求（含 WS）写完再关 DB pool，避免 kill 丢消息。
	// 用 http.Server 替代 r.Run()，拿到 Shutdown 的控制权。
	srv := &http.Server{
		Addr:              ":" + cfg.Server.Port,
		Handler:           r,
		ReadHeaderTimeout: cfg.Server.ReadHeaderTimeout,
		IdleTimeout:       cfg.Server.IdleTimeout,
		// 注意：不设 ReadTimeout / WriteTimeout。
		// - WriteTimeout 会掐断 WS 握手（101 响应）+ 大文件流式下载
		// - ReadTimeout 覆盖请求体读取，对 WS 路由有误伤风险；慢 body 由 file_handler 的 MaxBytesReader 防护更精准
		// WS 连接 Upgrade 后 Hijack 脱离 http.Server 管理，靠 ws_handler 自管的 deadline 收尾。
	}

	go func() {
		logpkg.FromCtx(context.Background()).InfoContext(context.Background(), "服务启动", "port", cfg.Server.Port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal("服务启动失败:", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	logpkg.FromCtx(context.Background()).InfoContext(context.Background(), "收到退出信号,开始优雅关闭(最长等待 30s)")

	// 关闭顺序(自上而下,每步都给后续机会排空):
	//   1. cleanupCancel:停后台清理 goroutine(票据/审批),避免新事件进 hub
	//   2. hubCancel:停 hub 事件循环(不再 dispatch 新 WS 帧)
	//   3. srv.Shutdown:停 accept 新连接 + 等活跃请求(含 WS)写完
	//   4. presence.Close / rdb.Close:释放 Redis 连接池(必须在 srv.Shutdown 之后,
	//      避免 WS 还在用 presence.RefreshTTL 时连接被关)
	cleanupCancel()
	hubCancel()
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer shutdownCancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logpkg.FromCtx(context.Background()).WarnContext(context.Background(), "优雅关闭超时或出错", "err", err)
	}
	if err := p.Close(); err != nil {
		logpkg.FromCtx(context.Background()).WarnContext(context.Background(), "presence 关闭失败", "err", err)
	}
	if rdb != nil {
		_ = rdb.Close()
	}
	if err := db.Close(); err != nil {
		logpkg.FromCtx(context.Background()).WarnContext(context.Background(), "db 关闭失败", "err", err)
	}
	logpkg.FromCtx(context.Background()).InfoContext(context.Background(), "服务已退出")
}
