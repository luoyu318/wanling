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
	"github.com/wanling/server/internal/approval"
	"github.com/wanling/server/internal/config"
	"github.com/wanling/server/internal/handler"
	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/message"
	"github.com/wanling/server/internal/pair"
	"github.com/wanling/server/internal/presence"
	"github.com/wanling/server/internal/ratelimit"
	"github.com/wanling/server/internal/repository"
	"github.com/wanling/server/internal/storage"
	"github.com/joho/godotenv"
	"github.com/redis/go-redis/v9"
)

func main() {
	godotenv.Load()
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
		log.Printf("[WARN] Redis 连接失败（降级为单机模式，限流/在线状态仅本实例有效）: %v", err)
		rdb = nil
	}

	h := hub.NewHub(p, agentRepo, participantRepo)
	go h.Run()

	processor := message.NewProcessor(h, convRepo, msgRepo, agentRepo, fileRepo, participantRepo, deliveryRepo)

	authHandler := handler.NewAuthHandler(userRepo, agentRepo, cfg.JWT.Secret)
	agentHandler := handler.NewAgentHandler(agentRepo, p)
	convHandler := handler.NewConversationHandler(db, convRepo, participantRepo, friendshipRepo, msgRepo, agentRepo, userRepo, h)
	fileHandler := handler.NewFileHandler(fileRepo, store)
	userHandler := handler.NewUserHandler(userRepo)
	wsHandler := handler.NewWSHandler(h, cfg.JWT.Secret, processor.HandleIncoming)

	msgHandler := handler.NewMessageHandler(msgRepo, convRepo, participantRepo, h)

	pairHandler := handler.NewPairingHandler(pairRepo, agentRepo)

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
	r.Use(gin.Recovery())
	r.Use(handler.BusinessAccessLog())
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

	r.POST("/api/auth/login", authHandler.Login)
	r.POST("/api/agents/:id/token", authHandler.AgentToken)

	// 扫码配对：前 2 个匿名（凭 ticket_id 鉴权），后 2 个 user JWT。
	// GET 加 IP 限流防 ticket_id 枚举；complete 加 user 限流防滥用。
	r.POST("/api/pair/tickets", pairHandler.CreateTicket)
	r.GET("/api/pair/tickets/:id", pairGetLimiter, pairHandler.GetTicket)

	pairAuth := r.Group("", handler.AuthMiddleware(cfg.JWT.Secret, "user"))
	{
		pairAuth.POST("/api/pair/tickets/:id/scan", pairHandler.ScanTicket)
		pairAuth.POST("/api/pair/tickets/:id/complete", pairCompleteLimiter, pairHandler.CompleteTicket)
	}

	userAuth := r.Group("", handler.AuthMiddleware(cfg.JWT.Secret, "user"))
	{
		userAuth.GET("/api/agents", agentHandler.List)
		userAuth.POST("/api/agents", agentHandler.Create)
		userAuth.PUT("/api/agents/:id", agentHandler.Update)
		userAuth.DELETE("/api/agents/:id", agentHandler.Delete)
		// 会话相关
		userAuth.GET("/api/conversations", convHandler.List)
		userAuth.POST("/api/conversations", convHandler.Create)
		userAuth.GET("/api/conversations/:id", convHandler.Get)
		userAuth.GET("/api/conversations/:id/unread", convHandler.UnreadInfo)
		userAuth.GET("/api/conversations/:id/messages", convHandler.Messages)
		userAuth.POST("/api/conversations/:id/read", convHandler.MarkRead)
		userAuth.POST("/api/conversations/:id/messages/read", convHandler.MarkMessagesRead)
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
	fileAuth := r.Group("", handler.AuthMiddleware(cfg.JWT.Secret, "user", "agent"))
	{
		fileAuth.POST("/api/upload", fileHandler.Upload)
		fileAuth.GET("/api/files/:id", fileHandler.Download)
	}

	// 消息删除:user 和 agent 都可删自己的消息。
	// 单独分组(user+agent),不挂 userAuth(仅 user)以免 agent 无法删。
	msgAuth := r.Group("", handler.AuthMiddleware(cfg.JWT.Secret, "user", "agent"))
	{
		msgAuth.DELETE("/api/messages/:id", msgHandler.Delete)
		msgAuth.POST("/api/messages/batch-delete", msgHandler.BatchDelete)
	}

	// === 审批消息路由 ===
	// agent 在会话中发起审批卡片：限流 20/min/会话
	agentAuth := r.Group("", handler.AuthMiddleware(cfg.JWT.Secret, "agent"))
	{
		agentAuth.POST("/api/conversations/:id/approvals", approvalCreateLimiter, approvalHandler.CreateApproval)
		// agent 视角 findOrCreate：用于审批卡片等场景，agent 主动建立/获取会话
		// （无 user 先发消息时也能拿到 conv_id）。跟 user 的 POST /api/conversations 对称。
		agentAuth.POST("/api/agents/me/conversations", convHandler.CreateAsAgent)
	}

	// user 决策审批（同意/拒绝）
	userAuth.POST("/api/approvals/:id/decide", approvalHandler.Decide)

	// 双角色查审批详情（user + agent 都可，用于兜底/刷新）
	fileAuth.GET("/api/approvals/:id", approvalHandler.Get)

	r.GET("/ws", gin.WrapH(wsHandler))

	r.GET("/health", func(c *gin.Context) {
		c.JSON(200, gin.H{"status": "ok"})
	})

	// 优雅关闭：SIGTERM/SIGINT 时先停止 accept 新连接，
	// 等活跃请求（含 WS）写完再关 DB pool，避免 kill 丢消息。
	// 用 http.Server 替代 r.Run()，拿到 Shutdown 的控制权。
	srv := &http.Server{
		Addr:    ":" + cfg.Server.Port,
		Handler: r,
	}

	go func() {
		log.Printf("服务启动在端口 %s", cfg.Server.Port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal("服务启动失败:", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	log.Println("收到退出信号，开始优雅关闭（最长等待 30s）...")

	// hub 停止后台广播，cleanup goroutine 通过 cleanupCancel 退出。
	cleanupCancel()
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer shutdownCancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("[WARN] 优雅关闭超时或出错: %v", err)
	}
	log.Println("服务已退出")
}
