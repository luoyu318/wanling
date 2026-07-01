package hub

import (
	"encoding/json"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/presence"
	"github.com/wanling/server/internal/repository"
)

const bufferSize = 100
const heartbeatTimeout = 90 * time.Second // 3 倍心跳间隔（30s）

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
	clients        sync.Map // key: "role:id" → []*Client
	Register       chan *Client
	Unregister     chan *Client
	presence       *presence.Presence
	agentRepo      *repository.AgentRepo
	participantRepo *repository.ParticipantRepo // N 方参与者模型,SendToConv 按此遍历路由
	agentOwnerMap  sync.Map
	buffers        sync.Map
	seq            int64 // Hub 直发 dispatch 的序号分配器
}

// NextSeq 暴露内部 seq 自增，供 dispatch.go 的新事件用。
// 注意：MessageProcessor 另持有独立的 seq，两套计数器写入同一 client 时
// 各自单调即可（dispatch buffer 按 per-client seq 比对）。
func (h *Hub) NextSeq() int64 {
	return atomic.AddInt64(&h.seq, 1)
}

func NewHub(p *presence.Presence, agentRepo *repository.AgentRepo, participantRepo *repository.ParticipantRepo) *Hub {
	return &Hub{
		Register:        make(chan *Client),
		Unregister:      make(chan *Client),
		presence:        p,
		agentRepo:       agentRepo,
		participantRepo: participantRepo,
	}
}

func (h *Hub) Run() {
	gcTicker := time.NewTicker(30 * time.Second)
	defer gcTicker.Stop()

	for {
		select {
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
			h.presence.Online(client.Role, client.ID)

			if client.Role == "agent" {
				agent, err := h.agentRepo.GetByID(client.ID)
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
					h.presence.Offline(client.Role, client.ID)
					h.buffers.Delete(key)
				} else {
					h.clients.Store(key, filtered)
				}
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
			if time.Since(c.LastHeartbeat) > heartbeatTimeout {
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

// SendToConv 把消息推给该会话所有 participants(按 member_type 路由 SendToUser/SendToAgent)。
// 离线端无副作用(SendToUser/SendToAgent 在 key 不存在时返 nil)。
// participants 查询失败时 fail-closed(不推),避免漏推半个会话成员造成状态不一致。
func (h *Hub) SendToConv(convID string, msg *model.WSMessage) {
	if h.participantRepo == nil {
		log.Printf("SendToConv participantRepo 未注入,跳过 conv=%s", convID)
		return
	}
	participants, err := h.participantRepo.ListByConversation(convID)
	if err != nil {
		log.Printf("SendToConv 查 participants 失败 conv=%s: %v", convID, err)
		return
	}
	for _, p := range participants {
		if p.MemberType == "user" {
			h.SendToUser(p.MemberID, msg)
		} else {
			h.SendToAgent(p.MemberID, msg)
		}
	}
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

func (h *Hub) Heartbeat(role, id string) {
	h.presence.RefreshTTL(role, id)
}

func (h *Hub) GetMissedMessages(role, id string, afterSeq int64) [][]byte {
	key := clientKey(role, id)
	v, ok := h.buffers.Load(key)
	if !ok {
		return nil
	}
	return v.(*dispatchBuffer).getAfter(afterSeq)
}

// IsUserViewingConv 判断 user 是否正在看某个会话（任一 WS 连接的 ActiveConvID == convID 即算在看）。
// 多端登录时返回 true；无连接或所有连接都没在看 → false。
//
// 历史用途:之前 processor 在 agent 发消息前调用本函数跳过 IncrUnreadTx
// (假设「在会话 = 看到新消息」)。该守卫已移除,所有 agent 消息一律计未读,
// client 端 chat_page.dart 在底部时 _markRead() 归零。
//
// 当前状态:无业务消费方。保留供 participants 模型重构或 client ack 模型复用,
// grep TODO(participants-refactor) 可定位相关改造点。
func (h *Hub) IsUserViewingConv(userID, convID string) bool {
	if userID == "" || convID == "" {
		return false
	}
	v, ok := h.clients.Load(clientKey("user", userID))
	if !ok {
		return false
	}
	for _, client := range v.([]*Client) {
		if client.GetActiveConv() == convID {
			return true
		}
	}
	return false
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
		log.Printf("客户端 %s 发送缓冲区满", client.ID)
	}
	return nil
}

func clientKey(role, id string) string {
	return role + ":" + id
}
