package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"time"

	"github.com/gorilla/websocket"

	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/ratelimit"

	"github.com/wanling/server/internal/auth"
	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// WS 限流参数
const (
	wsMsgRateWindow = time.Second // 限流窗口
	wsMsgRateMax    = 10          // 每客户端每窗口最大业务消息数
)

// WSHandler 处理 WebSocket 连接升级和消息收发
type WSHandler struct {
	hub            *hub.Hub
	jwtSecret      string
	allowedOrigins []string
	onMessage      func(ctx context.Context, senderType, senderID string, msg *model.WSMessage)
	msgLimiter     *ratelimit.Limiter
	rpcRegistry    *hub.RPCRegistry
	mpRepo         *repository.MiniProgramRepo // 小程序注册表,OpMpSubscribe 可见性校验用
}

// NewWSHandler 创建新的 WSHandler 实例。
// allowedOrigins 控制 CheckOrigin 白名单(空切片 = 走同源校验,见 checkOrigin)。
// onMessage 接 per-conn ctx,processor 用此 ctx 做 repo 调用,client 断开时进行中查询自动中止。
// 内部创建 msgLimiter 对业务消息限流（每客户端 10 msg/s），防洪水消息 DoS。
// rpcRegistry 为 RPC pending map,OpPluginResult 响应在此查找匹配并投递给等待方。
// mpRepo 供 OpMpSubscribe 校验小程序可见性(published 或 owner),防 private 数据泄漏。
func NewWSHandler(h *hub.Hub, jwtSecret string, allowedOrigins []string, onMessage func(context.Context, string, string, *model.WSMessage), rpcRegistry *hub.RPCRegistry, mpRepo *repository.MiniProgramRepo) *WSHandler {
	return &WSHandler{
		hub:            h,
		jwtSecret:      jwtSecret,
		allowedOrigins: allowedOrigins,
		onMessage:      onMessage,
		msgLimiter:     ratelimit.NewLimiter(wsMsgRateWindow, wsMsgRateMax),
		rpcRegistry:    rpcRegistry,
		mpRepo:         mpRepo,
	}
}

// checkOrigin 实现 WS 同源 + 白名单兜底,防跨站 WS 劫持(CSWH):
//   - Origin 头缺失(非浏览器 client,如 plugin adapter) → 放行
//   - allowedOrigins 非空 → 仅匹配白名单(开发多域名场景)
//   - allowedOrigins 空 → 同源校验(Origin host == Host header,单域名生产)
func (h *WSHandler) checkOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	if len(h.allowedOrigins) > 0 {
		for _, o := range h.allowedOrigins {
			if o == origin {
				return true
			}
		}
		return false
	}
	u, err := url.Parse(origin)
	if err != nil {
		return false
	}
	return u.Host == r.Host
}

// ServeHTTP 处理 WebSocket 升级请求
func (h *WSHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// upgrader 在请求级别构造,绑定 h.checkOrigin,不污染 package-level 状态。
	upgrader := websocket.Upgrader{
		CheckOrigin: h.checkOrigin,
	}

	// per-conn ctx:从 r.Context() 派生,ServeHTTP 退出(含 conn.Close)时 cancel。
	// client 持有此 ctx,hub.Run Register / processor.HandleIncoming 等下游都消费它,
	// 客户端断开 → ctx cancel → 进行中的 DB 查询中止,不浪费连接池。
	connCtx, cancel := context.WithCancel(r.Context())
	defer cancel()

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		// 升级失败时 ctx 仍带 request_id(来自 ServeHTTP 链路)
		logpkg.FromCtx(r.Context()).ErrorContext(r.Context(), "WS 升级失败", "remote", r.RemoteAddr, "err", err)
		return
	}

	// 发送 Hello
	helloData, _ := json.Marshal(map[string]int{"heartbeat_interval": 30000})
	helloMsg := model.WSMessage{Op: model.OpHello, D: helloData}
	conn.WriteJSON(helloMsg)

	// 等待 Identify
	var identifyMsg model.WSMessage
	if err := conn.ReadJSON(&identifyMsg); err != nil {
		conn.Close()
		return
	}
	if identifyMsg.Op != model.OpIdentify {
		conn.Close()
		return
	}

	var identify struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(identifyMsg.D, &identify); err != nil {
		conn.Close()
		return
	}

	claims, err := auth.ParseToken(h.jwtSecret, identify.Token)
	if err != nil {
		conn.WriteJSON(model.WSMessage{Op: model.OpReconnect})
		conn.Close()
		return
	}

	// 子密钥禁止建立 WS 长连接(绑定独占主密钥):子密钥(wlsk_)换出的 token 携带
	// key_kind="sub",仅限 HTTP API 使用;WS 通道必须用主密钥。判定必须正向——
	// 仅显式 "sub" 拒绝,空串(存量 token)/"master"/user token(key_kind 恒空)一律放行。
	// 位置在 role 归一之前:子密钥无论声明什么角色都拒。
	if claims.KeyKind == "sub" {
		logpkg.FromCtx(connCtx).WarnContext(connCtx, "WS 拒绝子密钥连接",
			"agent_id", claims.Subject, "key_id", claims.KeyID)
		_ = conn.WriteJSON(map[string]string{"error": "sub_key_ws_forbidden"})
		conn.Close()
		return
	}

	// admin 兼作 user(与 HTTP AuthMiddlewareWithStore 的归一口径一致):
	// hub 分发(SendToUser/流式/busy)仅认 user/agent 两键,admin 原样注册
	// 会成为收不到任何广播的孤儿连接。放行侧无角色白名单,归一不影响连接。
	wsRole := claims.Role
	if wsRole == "admin" {
		wsRole = "user"
	}
	client := hub.NewClient(connCtx, claims.Subject, wsRole, conn)
	h.hub.Register <- client

	go h.writePump(client)
	h.readPump(client)
}

const (
	readTimeout  = 90 * time.Second // 3 倍心跳间隔，超时触发清理
	maxReadBytes = 524288           // 512KB,WS 帧上限(AGENT_SLASH_CATALOG 47 条命令达 ~150KB,原 64KB 不够)
)

// readPump 从客户端读取消息并分发处理
func (h *WSHandler) readPump(client *hub.Client) {
	defer func() {
		h.hub.Unregister <- client
	}()

	client.Conn.SetReadLimit(maxReadBytes)
	for {
		client.Conn.SetReadDeadline(time.Now().Add(readTimeout))
		_, message, err := client.Conn.ReadMessage()
		if err != nil {
			logpkg.FromCtx(client.Ctx()).WarnContext(client.Ctx(), "WS readPump 退出",
				"role", client.Role, "id", client.ID, "err", err)
			break
		}

		var msg model.WSMessage
		if err := json.Unmarshal(message, &msg); err != nil {
			continue
		}

		switch msg.Op {
		case model.OpHeartbeat:
			client.LastHeartbeat = time.Now()
			h.hub.Heartbeat(client.Ctx(), client.Role, client.ID)
			ack := model.WSMessage{Op: model.OpHeartbeatACK}
			data, _ := json.Marshal(ack)
			select {
			case client.Send <- data:
			default:
				logpkg.FromCtx(client.Ctx()).WarnContext(client.Ctx(), "client Send 满,丢弃心跳 ACK", "client_id", client.ID)
			}

		case model.OpResume:
			var resume struct {
				LastSeq int64 `json:"last_seq"`
			}
			if err := json.Unmarshal(msg.D, &resume); err != nil {
				continue
			}
			missed := h.hub.GetMissedMessages(client.Role, client.ID, resume.LastSeq)
			for _, m := range missed {
				select {
				case client.Send <- m:
				default:
					logpkg.FromCtx(client.Ctx()).WarnContext(client.Ctx(), "client Send 满,丢弃 Resume 补发帧",
						"client_id", client.ID, "missed_remaining", len(missed))
					return // Send 满,继续读后续消息没意义,直接退出触发 Unregister
				}
			}

		case model.OpSetActiveConv:
			// 前端上报「我正在看 conv X」/「我退出会话了」。
			// participants 模型重构后,unread_count 由 IncrUnreadTx 无条件给非 sender 全员 +1,
			// server 端不再据此决定计未读;client 端据本字段判断是否弹通知/归零时机。
			// conv_id 为空 = 退出会话。仅 user 角色有意义(agent 不计未读)。
			var active struct {
				ConvID string `json:"conv_id"`
			}
			if len(msg.D) > 0 {
				_ = json.Unmarshal(msg.D, &active)
			}
			client.SetActiveConv(active.ConvID)

		case model.OpPluginResult:
			if client.Role != "agent" {
				continue
			}
			h.routeAgentIncoming(client.Ctx(), client.ID, &msg)

		case model.OpPluginCall: // user 不允许发 OpPluginCall
			if client.Role == "user" {
				logpkg.FromCtx(client.Ctx()).WarnContext(client.Ctx(),
					"user 尝试发 OpPluginCall,拒绝",
					"user_id", client.ID)
			}

		case model.OpStream:
			// 流式输出(plugin → server → 正在观看的 user)。仅 agent 可发,
			// role 门禁 + IDOR 校验集中在 handleOpStream(提取出来便于单测)。
			h.handleOpStream(client, msg.D)

		case model.OpMpSubscribe:
			// 小程序云数据订阅。role=user(含 admin 归一);校验小程序可见性
			// (published 或请求者是 owner)后才登记,防 private 小程序变更泄漏。
			var sub struct {
				Appid string   `json:"appid"`
				Colls []string `json:"colls"`
			}
			if len(msg.D) > 0 {
				_ = json.Unmarshal(msg.D, &sub)
			}
			h.handleMpSubscribe(client, sub.Appid, sub.Colls)

		case model.OpMpUnsubscribe:
			// 退订该连接的全部小程序云数据频道(断连时 hub.Run 也会全清,此帧供客户端主动退订)。
			h.hub.UnsubscribeMp(client)

		default:
			if msg.Op == model.OpDispatch || msg.T != "" {
				if h.msgLimiter != nil && !h.msgLimiter.Allow(client.ID) {
					logpkg.FromCtx(client.Ctx()).WarnContext(client.Ctx(), "WS 消息限流，丢弃", "client_id", client.ID)
					continue
				}
				if h.onMessage != nil {
					// 用 client 的 per-conn ctx,client 断开时进行中的查询自动中止
					h.onMessage(client.Ctx(), client.Role, client.ID, &msg)
				}
			}
		}
	}
}

// writePump 将消息写入客户端连接
func (h *WSHandler) writePump(client *hub.Client) {
	defer func() {
		h.hub.Unregister <- client
	}()
	for msg := range client.Send {
		client.Conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
		if err := client.Conn.WriteMessage(websocket.TextMessage, msg); err != nil {
			logpkg.FromCtx(client.Ctx()).WarnContext(client.Ctx(), "WS writePump 退出",
				"role", client.Role, "id", client.ID, "err", err)
			break
		}
	}
}

type pluginResultPayload struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      string          `json:"id"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *hub.RPCError   `json:"error,omitempty"`
}

func (h *WSHandler) routeAgentIncoming(ctx context.Context, agentID string, msg *model.WSMessage) {
	var p pluginResultPayload
	if err := json.Unmarshal(msg.D, &p); err != nil {
		logpkg.FromCtx(ctx).WarnContext(ctx, "OpPluginResult 解析失败",
			"agent_id", agentID, "err", err)
		return
	}
	resp := &hub.RPCResponse{Result: p.Result, Err: p.Error}
	if !h.rpcRegistry.Resolve(p.ID, resp) {
		logpkg.FromCtx(ctx).WarnContext(ctx, "OpPluginResult 找不到 pending",
			"agent_id", agentID, "rpc_id", p.ID)
	}
}

// handleOpStream 处理 OpStream(op=14)流式快照转发,三态门禁:
//  1. role != agent → 拒绝(user 不可发流式,仅 agent plugin)
//  2. conversation_id 缺失 → 丢弃(瞬态可丢)
//  3. agent 非该会话 participant(IDOR) → fail-closed 拒绝
//
// 全部通过后才调 SendStreamToConvViewers 透传给正在观看该会话的 user 连接。
// 从 readPump 提取出来便于单测三态(见 ws_handler_test.go)。
func (h *WSHandler) handleOpStream(client *hub.Client, data []byte) {
	if client.Role != "agent" {
		logpkg.FromCtx(client.Ctx()).WarnContext(client.Ctx(),
			"非 agent 尝试发 OpStream,拒绝",
			"client_id", client.ID, "role", client.Role)
		return
	}
	var stream struct {
		ConversationID string `json:"conversation_id"`
		StreamID       string `json:"stream_id"`
		MsgType        string `json:"msg_type"`
		Text           string `json:"text"`
	}
	if len(data) > 0 {
		_ = json.Unmarshal(data, &stream)
	}
	logpkg.FromCtx(client.Ctx()).InfoContext(client.Ctx(),
		"[SSE-DBG] handleOpStream 收到",
		"agent_id", client.ID, "conv_id", stream.ConversationID,
		"sid", stream.StreamID, "kind", stream.MsgType, "len", len(stream.Text))
	if stream.ConversationID == "" {
		return
	}
	// IDOR 防护:agent 必须是该会话 participant,否则拒绝(fail-closed)
	ok, err := h.hub.IsParticipant(client.Ctx(), stream.ConversationID, client.ID, "agent")
	if err != nil || !ok {
		logpkg.FromCtx(client.Ctx()).WarnContext(client.Ctx(),
			"agent 非该会话 participant,拒绝 STREAM",
			"agent_id", client.ID, "conv_id", stream.ConversationID, "err", err)
		return
	}
	h.hub.SendStreamToConvViewers(stream.ConversationID, data)
}

// handleMpSubscribe 处理 OpMpSubscribe(op=15)小程序云数据订阅,门禁链:
//  1. role != user → 拒绝(云数据仅 user 端消费;admin 已在 Identify 归一为 user)
//  2. mpRepo 未注入 → fail-closed 拒绝(生产 main.go 必注入)
//  3. 小程序不存在 / (status!=published 且请求者非 owner) → 拒绝(防 private 数据泄漏)
//  4. colls 逐个校验:manifest 声明集合名或 "default",未声明拒(防订阅未授权频道)
//
// 通过者登记进 hub 频道表,写路径 fanout MP_DATA_UPDATE。从 readPump 提取出来
// 便于单测(对称 handleOpStream)。
func (h *WSHandler) handleMpSubscribe(client *hub.Client, appid string, colls []string) {
	if client.Role != "user" {
		logpkg.FromCtx(client.Ctx()).WarnContext(client.Ctx(),
			"非 user 尝试订阅小程序云数据,拒绝",
			"client_id", client.ID, "role", client.Role, "appid", appid)
		return
	}
	if h.mpRepo == nil {
		logpkg.FromCtx(client.Ctx()).WarnContext(client.Ctx(),
			"mpRepo 未注入,拒绝小程序订阅(fail-closed)",
			"client_id", client.ID, "appid", appid)
		return
	}
	mp, err := h.mpRepo.GetByAppid(client.Ctx(), appid)
	if err != nil {
		logpkg.FromCtx(client.Ctx()).WarnContext(client.Ctx(),
			"查询小程序失败,拒绝订阅",
			"client_id", client.ID, "appid", appid, "err", err)
		return
	}
	if mp == nil || (mp.Status != "published" && mp.OwnerID != client.ID) {
		logpkg.FromCtx(client.Ctx()).WarnContext(client.Ctx(),
			"小程序不存在或不可见,拒绝订阅",
			"client_id", client.ID, "appid", appid)
		return
	}
	// colls 逐个校验:manifest 声明集合名或 "default"(default 恒 private,免声明)
	var m model.MiniprogramManifest
	_ = json.Unmarshal(mp.ManifestJSON, &m)
	declared := make(map[string]bool, len(m.Collections))
	for _, cl := range m.Collections {
		declared[cl.Name] = true
	}
	allowed := make([]string, 0, len(colls))
	for _, coll := range colls {
		if coll != "default" && !declared[coll] {
			logpkg.FromCtx(client.Ctx()).WarnContext(client.Ctx(),
				"collection 未在 manifest 声明,拒绝订阅该频道",
				"client_id", client.ID, "appid", appid, "coll", coll)
			continue
		}
		allowed = append(allowed, coll)
	}
	if len(allowed) == 0 {
		return
	}
	h.hub.SubscribeMp(client, appid, allowed)
}
