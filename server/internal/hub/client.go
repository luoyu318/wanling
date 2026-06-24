package hub

import (
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// Client 表示一个 WebSocket 连接的客户端
type Client struct {
	ID            string
	Role          string
	Conn          *websocket.Conn
	Send          chan []byte
	mu            sync.Mutex
	seq           int64
	activeConvID  string    // 该连接当前正在看的会话（前端 setActiveConv 上报），空=没在看任何会话
	LastHeartbeat time.Time // 最近一次心跳时间，GC 用
	closeOnce     sync.Once // 保证 Send/Conn 只关一次
}

// NewClient 创建新的客户端实例
func NewClient(id, role string, conn *websocket.Conn) *Client {
	return &Client{
		ID:            id,
		Role:          role,
		Conn:          conn,
		Send:          make(chan []byte, 256),
		LastHeartbeat: time.Now(),
	}
}

// Close 安全关闭 client：close Send channel + close WS 连接，幂等。
// readPump 和 writePump 都 defer 了 Unregister，GC 也可能触发清理，
// 同一个 client 的 Close 可能被多次调用，用 sync.Once 防 panic。
func (c *Client) Close() {
	c.closeOnce.Do(func() {
		close(c.Send)
		if c.Conn != nil {
			c.Conn.Close()
		}
	})
}

// SetSeq 设置客户端的序列号
func (c *Client) SetSeq(s int64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.seq = s
}

// GetSeq 获取客户端的序列号
func (c *Client) GetSeq() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.seq
}

// SetActiveConv 设置该连接当前正在看的会话 ID（前端 op=3 上报）。
// 空字符串表示退出会话（没在看任何会话）。并发安全：readPump 与 processor 可能同时访问。
func (c *Client) SetActiveConv(convID string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.activeConvID = convID
}

// GetActiveConv 获取该连接当前正在看的会话 ID。
func (c *Client) GetActiveConv() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.activeConvID
}
