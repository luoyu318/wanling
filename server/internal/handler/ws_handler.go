package handler

import (
	"encoding/json"
	"log"
	"net/http"
	"time"

	"github.com/gorilla/websocket"

	"github.com/wanling/server/internal/auth"
	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/model"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

// WSHandler 处理 WebSocket 连接升级和消息收发
type WSHandler struct {
	hub       *hub.Hub
	jwtSecret string
	onMessage func(senderType, senderID string, msg *model.WSMessage)
}

// NewWSHandler 创建新的 WSHandler 实例
func NewWSHandler(h *hub.Hub, jwtSecret string, onMessage func(string, string, *model.WSMessage)) *WSHandler {
	return &WSHandler{hub: h, jwtSecret: jwtSecret, onMessage: onMessage}
}

// ServeHTTP 处理 WebSocket 升级请求
func (h *WSHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Println("WS 升级失败:", err)
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

	client := hub.NewClient(claims.Subject, claims.Role, conn)
	h.hub.Register <- client

	go h.writePump(client)
	h.readPump(client)
}

const readTimeout = 90 * time.Second // 3 倍心跳间隔，超时触发清理

// readPump 从客户端读取消息并分发处理
func (h *WSHandler) readPump(client *hub.Client) {
	defer func() {
		h.hub.Unregister <- client
	}()

	for {
		client.Conn.SetReadDeadline(time.Now().Add(readTimeout))
		_, message, err := client.Conn.ReadMessage()
		if err != nil {
			break
		}

		var msg model.WSMessage
		if err := json.Unmarshal(message, &msg); err != nil {
			continue
		}

		switch msg.Op {
		case model.OpHeartbeat:
			client.LastHeartbeat = time.Now()
			h.hub.Heartbeat(client.Role, client.ID)
			ack := model.WSMessage{Op: model.OpHeartbeatACK}
			data, _ := json.Marshal(ack)
			client.Send <- data

		case model.OpResume:
			var resume struct {
				LastSeq int64 `json:"last_seq"`
			}
			if err := json.Unmarshal(msg.D, &resume); err != nil {
				continue
			}
			missed := h.hub.GetMissedMessages(client.Role, client.ID, resume.LastSeq)
			for _, m := range missed {
				client.Send <- m
			}

		default:
			if msg.Op == model.OpDispatch || msg.T != "" {
				if h.onMessage != nil {
					h.onMessage(client.Role, client.ID, &msg)
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
			break
		}
	}
}
