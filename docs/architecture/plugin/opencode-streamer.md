# OpenCode Plugin Streamer 模块结构

> `sync/streamer.ts` 是 SSE 事件流→万灵 WS 的过程同步引擎。已拆解为组装根 + 共享状态仓 + 发送路由 + 6 个领域模块,streamer 本身只负责构造组装、`start()` wire 订阅、`stop()` 生命周期委托,不再持有业务状态。

## 目录结构

```
sync/
├── streamer.ts          # 组装根:constructor/start/stop/updateMainSessionId + 兼容委托
├── session_store.ts     # SessionStore 共享状态仓
├── messaging.ts         # MessageRouter 发送路由
├── types.ts             # SessionState / ChildSessionEntry 等共享类型
├── ensure_conversation.ts  # 主 session 首次出现建群 + 改名(in-flight 防重)
├── card_store.ts        # 交互卡片内存 cache + 持久化备份
├── domains/             # 6 个领域模块(按事件语义切分)
│   ├── meta_sync.ts
│   ├── tool_card.ts
│   ├── interaction.ts
│   ├── session_lifecycle.ts
│   ├── part_dispatcher.ts
│   └── compaction.ts
└── utils/
    ├── diff.ts          # 文件 diff 序列化(markdown 聚合)
    └── task_meta.ts     # task 工具元数据抽取(input 字段 + 持续时长)
```

## 组件清单

- **SessionStore** (`session_store.ts`) — 跨事件共享状态仓。收敛 `sessions` / `childSessionTree` / `partIndex` / `idleHandled` / `createStateInflight` 五个 map;`getOrCreateState` 幂等入口(主 session 首次出现调 `ensureConversation` 建群,非主 session 丢弃返回 null,同一 session 跨多次 SSE 事件共享 inflight promise 防重复建群);`registerChild` / `cleanupChild` 子 session 注册与超时兜底清理;`flushReasoning` / `flushText` 缓冲 flush;`stop()` 撤销所有 child 兜底 timer + 清空 map。
- **MessageRouter** (`messaging.ts`) — 主/子 session 发送路由。`send`(按 part 类型聚合后发普通消息) + `sendCard`(发交互卡片) 走 `wanling` client,内部按 store 的 convId 映射决定目标会话。
- **MetaSync** (`domains/meta_sync.ts`) — session 元数据同步。`loadAll` 启动并发拉取 providers + slash catalog + capabilities;`onSessionUpdated` / `onVcsBranchUpdated` 增量同步 mode/model/cwd/gitBranch;step-finish `reason=stop` 主动 `session.get` 拉 tokens + `vcs.get` 拉最新 branch 兜底;按 `mode|modelId|directory` 去重防 SSE 抖动。持有 `knownTitles` / `knownMeta` / `knownFullMeta` / `providerNames` 四个状态 map。
- **ToolCardManager** (`domains/tool_card.ts`) — tool/task 卡片状态机。普通 tool + task 工具的 running/completed/error;inflight Promise 修复「同 partId 两次推送」竞态;子 session 注册经 store 委托。不持有状态(toolPartsSent/toolCardMsgIds 等随 SessionState 流动),错误经注入的 emitter 上抛。
- **PartDispatcher** (`domains/part_dispatcher.ts`) — part_updated/part_delta 文本/推理分发。reasoning/text case 聚合 + step-finish loopEnd 处理;delta 增量;idle/stop 时 flush 缓冲。tool/compaction case 由 ToolCard/Compaction 各自独立订阅 part_updated 自行过滤,本模块不处理。错误经注入的 emitter 上抛。
- **CompactionTracker** (`domains/compaction.ts`) — compaction part 处理。running/done 状态机(OC 1.18.3 实测不发第二次 done,靠 step-finish loopEnd 兜底 PATCH);发压缩分隔符消息。持有 `compactionParts` 状态 map。
- **InteractionCards** (`domains/interaction.ts`) — permission/question 交互卡片。正向流发卡(approval_request/question_asked)+ 反向流 PATCH 终态(permission_replied/question_replied/question_rejected)+ 启动孤儿卡片清理(`cleanupOrphans` PATCH 超时残留为 expired)。不持有状态(card_store 是模块级单例),错误经注入的 emitter 上抛。
- **SessionLifecycle** (`domains/session_lifecycle.ts`) — session 状态/心跳/flush 兜底。busy/retry/idle 状态透传;20s 心跳保活;session.idle flush 缓冲兜底。持有 `activeSessions` + `heartbeatTimer` 两个状态。

## 组装根职责 (streamer.ts)

- **constructor** — 构造 `MessageRouter` + `SessionStore`(注入 router/ensureDeps/wanling/childTimeoutMs)+ 6 个领域模块(按依赖顺序注入 store/router/wanling/opencode/dispatcher/metaSync/compaction/toolCard/partDispatcher/emitter)。
- **start()** — `interaction.cleanupOrphans()` 清孤儿卡片 → `metaSync.loadAll()` 拉元数据 → wire SSE 订阅(part_updated 三路分发到 PartDispatcher + ToolCard + Compaction、part_delta、session_status、session_idle、session_updated、vcs_branch_updated + 5 个交互事件)。
- **stop()** — `lifecycle.stop()` 清心跳 + activeSessions;`store.stop()` flush all 缓冲 + 撤销 child 兜底 timer + 清空 map。
- **updateMainSessionId(id)** — 日志 + 委托 `store.updateMainSessionId`(getOrCreateState 主/非主判定依赖此值)。
- **兼容委托** — 大量 `// 待测试改造后移除` 标记的 getter/方法(sessions/childSessionTree/providerNames/activeSessions/heartbeatTimer 访问器 + `_registerChildSession`/`loadProviderNames`/`onPartUpdated`/`onSessionStatus`/`onPermissionAsked` 等委托),供 `streamer.test.ts` 通过 `(streamer as any).<private>` 直接访问 map/方法的回归网。**禁止删除**——测试改造是后续独立 task。

> 兼容委托清单与精确语义见 `sync/streamer.ts` 内联注释(每条都标 `待测试改造后移除`)。
