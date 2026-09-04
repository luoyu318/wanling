// 小程序云数据订阅频道表:MP_DATA_UPDATE 的 fanout 路由层。
// 频道 = (appid, coll) 二元组;订阅者 = 经 ws_handler 校验过可见性的 user WS 连接。
// 与 clients map(按 role:id 路由)平行的独立索引,断连经 hub.Run Unregister 分支全清。
package hub

import (
	"encoding/json"

	"github.com/wanling/server/internal/model"
)

// mpChannelKey 频道键:appid + NUL + coll。
// NUL 不会出现在合法 appid/coll 中,防 (a, "b\x00c") 类边界拼接歧义。
func mpChannelKey(appid, coll string) string {
	return appid + "\x00" + coll
}

// SubscribeMp 把 client 登记到 (appid, colls...) 各频道。
// 幂等合并:同 client 重复订阅同频道只记一份(map set 语义),fanout 不重复投递。
func (h *Hub) SubscribeMp(c *Client, appid string, colls []string) {
	h.mpMu.Lock()
	defer h.mpMu.Unlock()
	for _, coll := range colls {
		key := mpChannelKey(appid, coll)
		set, ok := h.mpChannels[key]
		if !ok {
			set = make(map[*Client]struct{})
			h.mpChannels[key] = set
		}
		set[c] = struct{}{}
		chans, ok := h.mpClientChans[c]
		if !ok {
			chans = make(map[string]struct{})
			h.mpClientChans[c] = chans
		}
		chans[key] = struct{}{}
	}
}

// UnsubscribeMp 全清该 client 的所有小程序频道订阅(OpMpUnsubscribe 帧与断连清理共用)。
// 经反向索引只遍历自身频道逐一摘除,空频道键随之删除。
func (h *Hub) UnsubscribeMp(c *Client) {
	h.mpMu.Lock()
	defer h.mpMu.Unlock()
	chans, ok := h.mpClientChans[c]
	if !ok {
		return
	}
	for key := range chans {
		if set, ok := h.mpChannels[key]; ok {
			delete(set, c)
			if len(set) == 0 {
				delete(h.mpChannels, key)
			}
		}
	}
	delete(h.mpClientChans, c)
}

// SendMpDataUpdate 向 (appid, coll) 频道全部订阅者广播 MP_DATA_UPDATE:
// {op:0, t:"MP_DATA_UPDATE", s:NextSeq(), d:{appid, coll, key, value|nil, deleted, version, writer_openid}}。
// value=nil(deleted 事件)序列化为 JSON null。经 bufferedSend 投递,Send 满则丢
// (瞬态可丢,客户端按 _version 兜底重拉);无订阅者时无副作用。
func (h *Hub) SendMpDataUpdate(appid, coll, key string, value json.RawMessage, deleted bool, version int64, writerOpenID string) {
	h.mpMu.Lock()
	set := h.mpChannels[mpChannelKey(appid, coll)]
	// 取订阅者快照后解锁,避免持锁跨 goroutine 调 bufferedSend
	subscribers := make([]*Client, 0, len(set))
	for c := range set {
		subscribers = append(subscribers, c)
	}
	h.mpMu.Unlock()
	if len(subscribers) == 0 {
		return
	}
	data := marshalOrWarn(map[string]any{
		"appid":         appid,
		"coll":          coll,
		"key":           key,
		"value":         value,
		"deleted":       deleted,
		"version":       version,
		"writer_openid": writerOpenID,
	})
	if data == nil {
		return
	}
	msg := &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMpDataUpdate,
		S:  h.NextSeq(),
		D:  data,
	}
	for _, c := range subscribers {
		_ = h.bufferedSend(c, msg) // 满则丢:瞬态可丢,客户端 _version 兜底
	}
}
