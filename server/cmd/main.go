package main

import (
	"context"
	"log"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
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

	rdb := redis.NewClient(&redis.Options{
		Addr:     cfg.Redis.Host + ":" + strconv.Itoa(cfg.Redis.Port),
		Password: cfg.Redis.Password,
		DB:       cfg.Redis.DB,
	})

	p := presence.New(rdb)
	if err := p.Ping(); err != nil {
		log.Fatal("Redis 连接失败:", err)
	}

	h := hub.NewHub(p, agentRepo)
	go h.Run()

	processor := message.NewProcessor(h, convRepo, msgRepo, agentRepo)

	authHandler := handler.NewAuthHandler(userRepo, agentRepo, cfg.JWT.Secret)
	agentHandler := handler.NewAgentHandler(agentRepo, p)
	convHandler := handler.NewConversationHandler(convRepo, msgRepo, agentRepo)
	fileHandler := handler.NewFileHandler(fileRepo, store)
	userHandler := handler.NewUserHandler(userRepo)
	wsHandler := handler.NewWSHandler(h, cfg.JWT.Secret, processor.HandleIncoming)

	msgHandler := handler.NewMessageHandler(msgRepo, convRepo, h)

	pairHandler := handler.NewPairingHandler(pairRepo, agentRepo)

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

	// 后台清理过期票据：每 10 分钟扫一次，删 1 小时前的记录。
	// 随 server 生命周期结束（main 退出时 ctx 取消）。
	cleanupCtx, cleanupCancel := context.WithCancel(context.Background())
	defer cleanupCancel()
	go pair.RunCleanup(cleanupCtx, pairRepo, 10*time.Minute, time.Hour)

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
		userAuth.GET("/api/conversations", convHandler.List)
		userAuth.POST("/api/conversations", convHandler.FindOrCreate)
		userAuth.GET("/api/conversations/:id/messages", convHandler.Messages)
		userAuth.POST("/api/conversations/:id/read", convHandler.MarkRead)
		userAuth.POST("/api/conversations/:id/pin", convHandler.Pin)
		userAuth.DELETE("/api/conversations/:id/pin", convHandler.Unpin)
		userAuth.DELETE("/api/conversations/:id", convHandler.Hide)
		userAuth.GET("/api/users/me", userHandler.GetMe)
		userAuth.PUT("/api/users/me", userHandler.UpdateMe)
		userAuth.PUT("/api/users/me/password", userHandler.ChangePassword)
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

	r.GET("/ws", gin.WrapH(wsHandler))

	r.GET("/health", func(c *gin.Context) {
		c.JSON(200, gin.H{"status": "ok"})
	})

	log.Printf("服务启动在端口 %s", cfg.Server.Port)
	if err := r.Run(":" + cfg.Server.Port); err != nil {
		log.Fatal("服务启动失败:", err)
	}
}
