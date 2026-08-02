package hub

import (
	"context"
	"encoding/json"
	"runtime/debug"
	"sync"
	"sync/atomic"
	"time"

	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/presence"
	"github.com/wanling/server/internal/repository"
)

const bufferSize = 1000 // M11:从 100 加大,降低断线丢消息概率;dispatchBuffer 数组上限,改值需同步改类型

// defaultHeartbeatTimeout 是心跳超时默认值(3 倍心跳间隔 30s)。
// main.go 启动时通过 SetHeartbeatTimeout 用 cfg 覆盖。
const defaultHeartbeatTimeout = 90 * time.Second

type dispatchBuffer struct {
	mu    sync.Mutex
	msgs  [bufferSize]bufferedMsg
	head  int
	count int
}

type bufferedMsg struct {
	seq  int64
	data []byte
}

func (b *dispatchBuffer) push(seq int64, data []byte) {
	b.mu.Lock()
	defer b.mu.Unlock()
	idx := (b.head + b.count) % bufferSize
	b.msgs[idx] = bufferedMsg{seq: seq, data: data}
	if b.count < bufferSize {
		b.count++
	} else {
		b.head = (b.head + 1) % bufferSize
	}
}

func (b *dispatchBuffer) getAfter(afterSeq int64) [][]byte {
	b.mu.Lock()
	defer b.mu.Unlock()
	var result [][]byte
	for i := 0; i < b.count; i++ {
		idx := (b.head + i) % bufferSize
		if b.msgs[idx].seq > afterSeq {
			result = append(result, b.msgs[idx].data)
		}
	}
	return result
}

type Hub struct {
	clients          sync.Map // key: "role:id" → []*Client
	Register         chan *Client
	Unregister       chan *Client
	presence         *presence.Presence
	agentRepo        *repository.AgentRepo
	participantRepo  *repository.ParticipantRepo // N 方参与者模型,SendToConv 按此遍历路由
	agentOwnerMap    sync.Map
	buffers          sync.Map
	seq              int64         // Hub 直发 dispatch 的序号分配器
	heartbeatTimeout time.Duration // 心跳超时,gcStaleClients 用
	rpcRegistry      *RPCRegistry  // RPC pending map;agent 断线时 CancelAllForAgent fail-fast
}

// NextSeq 是唯一的 dispatch seq 分配器。
// Hub 直发事件(agent status / SendToUser 单播等)+ Processor 消息事件都通过此方法取序号,
// 保证单个 client 收到的所有 dispatch seq 单调递增(避免双计数器重叠导致 Resume 漏推)。
func (h *Hub) NextSeq() int64 {
	return atomic.AddInt64(&h.seq, 1)
}

func NewHub(p *presence.Presence, agentRepo *repository.AgentRepo, participantRepo *repository.ParticipantRepo, rpcRegistry *RPCRegistry) *Hub {
	return &Hub{
		Register:         make(chan *Client),
		Unregister:       make(chan *Client),
		presence:         p,
		agentRepo:        agentRepo,
		participantRepo:  participantRepo,
		heartbeatTimeout: defaultHeartbeatTimeout,
		rpcRegistry:      rpcRegistry,
	}
}

// SetHeartbeatTimeout 覆盖默认心跳超时。main.go 启动时从 cfg 注入。
// 传 0 或负值无效(保留默认)。在 Run 启动前调用,避免并发写。
func (h *Hub) SetHeartbeatTimeout(d time.Duration) {
	if d > 0 {
		h.heartbeatTimeout = d
	}
}

// Run 启动 hub 事件循环。ctx 取消时退出(SRV shutdown 序列由 main 触发)。
// 调用方应在 main 中 `go h.Run(hubCtx)`,在 srv.Shutdown 前 cancel(hubCtx)。
func (h *Hub) Run(ctx context.Context) {
	defer func() {
		if r := recover(); r != nil {
			logpkg.FromCtx(ctx).ErrorContext(ctx, "hub.Run panic",
				"recover", r, "stack", string(debug.Stack()))
		}
	}()
	gcTicker := time.NewTicker(30 * time.Second)
	defer gcTicker.Stop()

	for {
		select {
		case <-ctx.Done():
			logpkg.FromCtx(ctx).InfoContext(ctx, "hub.Run 收到 ctx.Done,退出事件循环")
			return
		case client := <-h.Register:
			key := clientKey(client.Role, client.ID)
			existing, _ := h.clients.Load(key)
			var list []*Client
			if existing != nil {
				list = append(existing.([]*Client), client)
			} else {
				list = []*Client{client}
			}
			h.clients.Store(key, list)
			h.presence.Online(client.Ctx(), client.Role, client.ID)

			if client.Role == "agent" {
				agent, err := h.agentRepo.GetByID(client.Ctx(), client.ID)
				if err == nil && agent != nil {
					h.agentOwnerMap.Store(client.ID, agent.OwnerID)
					h.broadcastAgentStatus(agent.OwnerID, client.ID, model.EventAgentOnline)
				}
			}

		case client := <-h.Unregister:
			key := clientKey(client.Role, client.ID)
			v, ok := h.clients.Load(key)
			if ok {
				list := v.([]*Client)
				filtered := make([]*Client, 0, len(list))
				for _, c := range list {
					if c != client {
						filtered = append(filtered, c)
					}
				}
				if len(filtered) == 0 {
					h.clients.Delete(key)
					h.presence.Offline(client.Ctx(), client.Role, client.ID)
					h.buffers.Delete(key)
				} else {
					h.clients.Store(key, filtered)
				}
			}

			// RPC fail-fast:agent(plugin)WS 断线时,立即 cancel 该 agent 名下所有 pending RPC,
			// 让等待方收到 503 + -32003 plugin_disconnected,而非等到 60s 超时返 504 + -32002。
			// (spec §12:plugin WS 频繁断线风险对策)
			// 放在 client.Close() 之前,优先把 -32003 投递出去再关 conn。
			// 同一 agent 多连接场景:只有最后一个连接退出才会 presence.Offline,
			// 但 RPC 失败语义应跟随具体连接断开而非全局在线状态——任一 agent conn 断开都 cancel 该 agent 全部 pending,
			// 这与单 plugin 单 agent 的部署模型一致(plugin 端不会对同 agent 建多 WS)。
			if client.Role == "agent" && h.rpcRegistry != nil {
				h.rpcRegistry.CancelAllForAgent(client.ID)
			}

			client.Close()

			if client.Role == "agent" {
				if v, ok := h.agentOwnerMap.LoadAndDelete(client.ID); ok {
					ownerID := v.(string)
					h.broadcastAgentStatus(ownerID, client.ID, model.EventAgentOffline)
				}
			}

		case <-gcTicker.C:
			h.gcStaleClients()
		}
	}
}

func (h *Hub) gcStaleClients() {
	h.clients.Range(func(key, value interface{}) bool {
		list := value.([]*Client)
		alive := make([]*Client, 0, len(list))
		for _, c := range list {
			if time.Since(c.LastHeartbeat) > h.heartbeatTimeout {
				c.Close()
			} else {
				alive = append(alive, c)
			}
		}
		if len(alive) == 0 {
			h.clients.Delete(key)
		} else {
			h.clients.Store(key, alive)
		}
		return true
	})
}

func (h *Hub) SendToUser(userID string, msg *model.WSMessage) error {
	v, ok := h.clients.Load(clientKey("user", userID))
	if !ok {
		return nil
	}
	for _, client := range v.([]*Client) {
		h.bufferedSend(client, msg)
	}
	return nil
}

func (h *Hub) SendToAgent(agentID string, msg *model.WSMessage) error {
	v, ok := h.clients.Load(clientKey("agent", agentID))
	if !ok {
		return nil
	}
	for _, client := range v.([]*Client) {
		h.bufferedSend(client, msg)
	}
	return nil
}

// SendToMember 按 memberType 路由到 SendToUser/SendToAgent。
// 用于 hide scope 的 per-participant 单播(只发给当前请求者,与 SendToConv 全员广播对立)。
func (h *Hub) SendToMember(memberID, memberType string, msg *model.WSMessage) {
	if memberType == "agent" {
		h.SendToAgent(memberID, msg)
	} else {
		h.SendToUser(memberID, msg)
	}
}

// SendToConv 把消息推给该会话所有 participants(按 member_type 路由 SendToUser/SendToAgent)。
// 离线端无副作用(SendToUser/SendToAgent 在 key 不存在时返 nil)。
// participants 查询失败时 fail-closed(不推),避免漏推半个会话成员造成状态不一致。
//
// ctx 来源:SendToConv 不在某个 client 请求路径上(由 dispatch.go 的 Broadcast* helper
// 间接调用,触发方为 HTTP handler / approval service / processor dispatch 等异步链路),
// 故无 client connCtx 可挂。用 context.Background 派生 10s 超时 ctx,防止 DB 慢查询 hang
// dispatch goroutine(影响其他 dispatch 事件落地)。
func (h *Hub) SendToConv(convID string, msg *model.WSMessage) {
	h.SendToConvFiltered(convID, msg, nil)
}

// SendToConvFiltered 把消息推给会话 participants,可选按 memberType 过滤。
// filter 返回 false 的 participant 不推。filter=nil 等价于 SendToConv。
// 用于 agent 触发事件的"仅推 user"场景(BroadcastConversationUpdateToUsers),
// 物理断开 agent→plugin 的回声路径。
func (h *Hub) SendToConvFiltered(convID string, msg *model.WSMessage, filter func(memberType string) bool) {
	if h.participantRepo == nil {
		logpkg.FromCtx(context.Background()).WarnContext(context.Background(), "SendToConvFiltered participantRepo 未注入,跳过",
			"conv_id", convID)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	participants, err := h.participantRepo.ListByConversation(ctx, convID)
	if err != nil {
		logpkg.FromCtx(ctx).ErrorContext(ctx, "SendToConvFiltered 查 participants 失败",
			"conv_id", convID, "err", err)
		return
	}
	for _, p := range participants {
		if filter != nil && !filter(p.MemberType) {
			continue
		}
		if p.MemberType == "user" {
			h.SendToUser(p.MemberID, msg)
		} else {
			h.SendToAgent(p.MemberID, msg)
		}
	}
}

// SendStreamToConvViewers 把流式快照(STREAM, op=14)只推给"正在看该会话"的 user 连接。
// 按 client.GetActiveConv() 过滤(只推当前打开本会话的连接),agent participant 一律跳过
// (agent 不消费流式,流是 user 端渲染用的)。WSMessage.Op=OpStream(非 OpDispatch)
// → bufferedSend 不会进 dispatchBuffer,也不分配 NextSeq(流式是瞬态,断线不补发,
// 终态走 MESSAGE_CREATE)。
func (h *Hub) SendStreamToConvViewers(convID string, data json.RawMessage) {
	if h.participantRepo == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	participants, err := h.participantRepo.ListByConversation(ctx, convID)
	if err != nil {
		logpkg.FromCtx(ctx).WarnContext(ctx, "SendStreamToConvViewers 查 participants 失败",
			"conv_id", convID, "err", err)
		return
	}
	msg := &model.WSMessage{Op: model.OpStream, D: data}
	pushed := 0
	for _, p := range participants {
		if p.MemberType != "user" {
			continue // agent 不消费流式
		}
		v, ok := h.clients.Load(clientKey("user", p.MemberID))
		if !ok {
			continue
		}
		for _, c := range v.([]*Client) {
			if c.GetActiveConv() == convID {
				// Op!=OpDispatch 不会进 dispatchBuffer,但仍走 client.Send 通道(满则丢,瞬态可丢)
				_ = h.bufferedSend(c, msg)
				pushed++
			}
		}
	}
	logpkg.FromCtx(ctx).InfoContext(ctx,
		"[SSE-DBG] SendStreamToConvViewers 广播",
		"conv_id", convID, "viewers", pushed)
}

// IsParticipant 校验某 member 是否是某会话的 participant(IDOR 防护用,ws_handler op=14 调)。
// 命中走 participantRepo.Exists 的 PRIMARY KEY 查询,比 ListByConversation 轻量。
// participantRepo 未注入时 fail-closed 返 (false, nil):生产 main.go 必注入,
// 此分支仅测试 / 未配置场景兜底,加 warn 暴露配置错误避免静默放行。
func (h *Hub) IsParticipant(ctx context.Context, convID, memberID, memberType string) (bool, error) {
	if h.participantRepo == nil {
		logpkg.FromCtx(ctx).WarnContext(ctx, "IsParticipant participantRepo 未注入,fail-closed",
			"conv_id", convID, "member_id", memberID, "member_type", memberType)
		return false, nil
	}
	return h.participantRepo.Exists(ctx, convID, memberID, memberType)
}

func (h *Hub) GetClient(role, id string) (*Client, bool) {
	v, ok := h.clients.Load(clientKey(role, id))
	if !ok {
		return nil, false
	}
	list := v.([]*Client)
	if len(list) == 0 {
		return nil, false
	}
	return list[0], true
}

// RegisterClient 同步注册一个 client(直接写 clients map),不经过 Run 事件循环。
// 主要供测试确定性构造在线 client(跨 package 无法访问私有 clients map / registerDirect)。
// 生产注册仍应走 Register channel(携带 presence / agent 状态广播副作用)。
func (h *Hub) RegisterClient(c *Client) {
	key := clientKey(c.Role, c.ID)
	existing, _ := h.clients.Load(key)
	var list []*Client
	if existing != nil {
		list = append(existing.([]*Client), c)
	} else {
		list = []*Client{c}
	}
	h.clients.Store(key, list)
}

func (h *Hub) Heartbeat(ctx context.Context, role, id string) {
	h.presence.RefreshTTL(ctx, role, id)
}

func (h *Hub) GetMissedMessages(role, id string, afterSeq int64) [][]byte {
	key := clientKey(role, id)
	v, ok := h.buffers.Load(key)
	if !ok {
		return nil
	}
	return v.(*dispatchBuffer).getAfter(afterSeq)
}

func (h *Hub) broadcastAgentStatus(ownerID, agentID, eventType string) {
	data, _ := json.Marshal(map[string]string{"agent_id": agentID})
	msg := &model.WSMessage{
		Op: model.OpDispatch,
		T:  eventType,
		D:  data,
	}
	h.SendToUser(ownerID, msg)
}

func (h *Hub) bufferedSend(client *Client, msg *model.WSMessage) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}

	if msg.Op == model.OpDispatch {
		key := clientKey(client.Role, client.ID)
		v, _ := h.buffers.LoadOrStore(key, &dispatchBuffer{})
		buf := v.(*dispatchBuffer)
		buf.push(msg.S, data)
	}

	select {
	case client.Send <- data:
	default:
		logpkg.FromCtx(client.Ctx()).WarnContext(client.Ctx(), "client 发送缓冲区满,消息丢失",
			"client_id", client.ID, "seq", msg.S)
	}
	return nil
}

func clientKey(role, id string) string {
	return role + ":" + id
}
