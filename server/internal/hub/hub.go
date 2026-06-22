package hub

import (
	"encoding/json"
	"log"
	"sync"
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
	clients       sync.Map // key: "role:id" → []*Client
	Register      chan *Client
	Unregister    chan *Client
	presence      *presence.Presence
	agentRepo     *repository.AgentRepo
	agentOwnerMap sync.Map
	buffers       sync.Map
}

func NewHub(p *presence.Presence, agentRepo *repository.AgentRepo) *Hub {
	return &Hub{
		Register:   make(chan *Client),
		Unregister: make(chan *Client),
		presence:   p,
		agentRepo:  agentRepo,
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

// SendToConv 把消息同时发给会话的 user 和 agent 双方。
// Hub 以 role:id 为 key 管理连接,没有"会话"概念,所以由调用方提供 userID + agentID。
// 任一端不在线无副作用(SendToUser/SendToAgent 在 key 不存在时返回 nil)。
func (h *Hub) SendToConv(userID, agentID string, msg *model.WSMessage) {
	h.SendToUser(userID, msg)
	h.SendToAgent(agentID, msg)
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
