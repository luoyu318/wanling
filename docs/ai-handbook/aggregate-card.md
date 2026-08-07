# 聚合卡协议

聚合卡（aggregate_card）：一次问答一条消息，elements[] 按时序承载全部步骤。由 opencode-plugin 聚合模式产生，本文件被各子 CLAUDE.md 通过 @import 引用。

## 消息结构

`data:{schema_ver, state:"generating"|"done", elements:[{type, element_id, data}]}`，创建时 `silent:true`，回合结束 PATCH 翻转 `silent:false`+`state:"done"`（未读/响铃由翻转承接，见 websocket-protocol.md MESSAGE_UPDATE silent 翻转）。

- **schema_ver 协议版本**：建卡写 `1`，缺失视为 1，破坏性协议变更时递增；server 合并保留未知字段天然透传；APP 读本地 content 的 schema_ver，`> 支持版本` 时不应用增量 op（保持现状防误用），等全量替换兜底
- **element_id 规则**：按 type_seq 生成（如 reasoning_1 / tool_card_2），全卡唯一、字母开头、≤20 字符；reasoning/markdown 流式用预留 seq，与终态 append 同一号

## 增量 PATCH（非全量）

plugin → server 的 `PATCH /api/messages/:id` `data` 带 `op` 走增量合并，server `applyContentOp` 合并到全量存储、广播**带增量**的 MESSAGE_UPDATE；无 `op` 带 `elements` 仍全量替换兼容旧 plugin。server 广播的 MESSAGE_UPDATE content 即增量 delta，APP `_applyAggregateCardDelta` 按 op 合并本地元素。

| op | 语义 |
|---|---|
| `append` | elements 末尾追加 element（无 upsert） |
| `update` | element_id 命中的元素 data 整体替换（不存在 → 400） |
| `remove` | element_id 删除（不存在幂等跳过） |
| `reorder` | order 数组重排（未列出的保序追加尾部） |
| `set_state` | 改 data.state |
| `set_silent` | 改顶层 content.silent（翻转 true→false 触发 IncrUnread） |

## 元素级 finished 标记

reasoning 元素 `data.finished`（流式占位 false / 终态 append true），APP 据此在卡片整体 generating 期间也显示真实思考内容（否则子 agent 并行阶段思考链不可见）。

## 元素类型表

| 元素 type | data 字段 | 渲染（复用现有 renderer） |
|---|---|---|
| `reasoning` | `{text, finished?, duration?}` | 同独立 reasoning（思考抽屉）；流式「正在思考...」/ 终态真实 text 预览 |
| `tool_card` | `{name, input, output?, error?, status, sub_session_id?, ...}` | 同独立 tool_card |
| `markdown` | `{text}` | 同独立 markdown |
| `compact_divider` | `{phase}` | 压缩分隔线（自绘） |
| `footer` | `{reason, cost, tokens, duration, finished, stopped?, mode?, model?}` | 同 step_finish（tokens 汇总行）；finished=true 且卡 done 时底部渲染提示条（模式/时长/模型/tokens），mode/model 为回合结束快照；`stopped=true`（abort 主动收尾）时提示条显示「已停止」；`reason` 取值 `stop`（用户停止）/`interrupt`（消息边界分段新回合） |
| `question_card` | `{oc_request_id, questions, status}` | 选择题卡片（嵌入聚合卡，交互需回调故不折叠） |
| `permission_card` | `{oc_request_id, action, resources, status}` | 权限审批卡（嵌入聚合卡，交互需回调故不折叠） |

## 保持独立（不进聚合卡）

permission_card / question_card（交互需回调）、task 工具（子 agent 需 parent/root 串树）、子 session 所有消息；历史独立消息照常渲染（双轨兼容）。

## 开关

`WANLING_AGGREGATE_CARD_ENABLED`（默认 true）置 false 回退旧逐条发送，协议不变。

## 流式定位

聚合模式 op=14 流式帧带 `aggregate:{message_id, element_id}`：不建独立占位气泡，定位 msg_type=aggregate_card 消息、全量替换 element_id 匹配元素的 data.text（终态仍由 plugin PATCH 持久化兜底，仅实时刷新观看端）。element_id 用流式预留 seq（与终态 append 同一号，定位连续）；首帧前插件先 append 目标元素占位（ensureStreamElement），否则 APP 因元素不存在丢弃帧。缺 `aggregate` 字段 = 非聚合模式，走旧独立占位（兼容）。详见 websocket-protocol.md「流式输出(op=14 Stream)」。

## working 补发语义

子 agent task 卡 `updateElement` 早于元素 append 落地时不静默丢弃，缓存待 append 完成后补发 `{op:"update"}`，避免卡片永卡 starting。

## 跨轮瞬态清理（2026-08-08 修复）

收尾（`_sealCard`/finalizeCard）时除 reset `aggregateSeq`/`aggregateElements`/`aggregateCardMsgId` 外，**必须一并清空流式占位去重 Set `aggregateStreamedElementIds` + `aggregatePendingUpdates` + `aggregateToolElementIds`**——seq 归零后下一轮 element_id 会复用（reasoning_1/markdown_1），若 Set 残留会让 `ensureStreamElement` 命中去重直接 return、跳过新卡首元素占位 append，导致跨轮首条 thinking 空白直到终态才显示。

## 停止收尾

用户点停止（`GENERATION_ABORT`）后 plugin 主动对当前聚合卡 `finishCard("stop")` 追加 `{reason:"stop", stopped:true, finished:true}` footer + 翻转 `state:"done"`/`silent:false`（APP 提示条显示「已停止」）。幂等：卡 done 时跳过；abort 后 step-finish 仍回推时 isLoopEnd 检测卡已收尾跳过重复 footer。

## 消息边界分段（interrupt）

聚合卡按 opencode 消息边界自动分段——plugin 订阅 `message.updated`(role=assistant)，每条 user→assistant 回合建独立 message（带 `parentID` 指向 user 消息）。新 assistant 出现且旧 assistant 以 `tool-calls` 完成（旧回合被新消息打断，未正常 `stop`）时，plugin 对旧卡 `finishCard("interrupt")` 追加 `{reason:"interrupt", stopped:false, finished:true}` footer + 翻转 done/silent，新回合自动建新卡。旧回合正常 `stop`（step-finish 已定稿）时不打断。同回合多 step（工具循环）的 assistant `parentID` 相同，不触发分段。

## 状态呈现（APP 展示层）

聚合卡不再有顶栏「回复中/完成」条；generating 时卡底部 footer 状态条显示动态阶段词（思考中/执行中/汇总中，按最后元素推导），done 后切换为静态信息条（模式/时长/模型/tokens）；generating 聚合卡存在期间 APP 隐藏消息列表 busy 气泡。mode/model 由 plugin 在 step-finish 时写入 footer data（消息快照，不随 sessionMeta 实时态变动）；时长/tokens 复用 footer 既有字段。footer 无 mode/model（历史消息）时提示条仅显示有时长/tokens 的段。

## 工具卡折叠

APP 渲染层按「折叠类别 + 连续性」合并 tool_card 元素为可展开折叠组（对齐 opencode groupParts）：探索组（read/glob/grep）、命令组（bash）、编辑组（edit/write）同类物理连续合并成组，类别切换即拆组，单条也折叠；收起标题语义化（进行中「正在探索/正在执行/正在编辑」、完成「已探索/已执行/已编辑」+ X次读取/搜索/命令/编辑，类别间 `,` 分隔）；webfetch、task 子 agent 卡、permission_card、question_card、todowrite（折叠行，2026-08-08 起不再隐藏）不折叠保持平铺。协议层 elements 仍平铺每个 tool_card，折叠纯属 APP 展示逻辑。

## 聚合卡样式

外壳无边框改阴影浮起（0 2px 8px rgba(0,0,0,0.10)）、圆角 12px；思考块白底 + #EEEEEE 边框（无琥珀左条浅黄底，2026-08-08 改纯文字行风格）；工具组折叠块浅灰底 #F8F8F8；展开工具卡浅灰底 #F7F7F7 + 语义色左条；正文无边框直排；footer 静态条顶部分隔线 #F0F0F0。

## 折叠展开滚动补偿

折叠组（tool_group）与平铺折叠元素（todowrite 折叠行、权限卡终态折叠外壳）展开/收起时，内容始终渲染（Align heightFactor 控制视觉高度）+ 同步测量真实高度，经 `rc.onToolGroupToggle` 上报 ChatPage 同帧 jumpTo 补偿（history 反向列表展开内容向上顶时视觉锚点不动、无补间动画）；`rc.isHistorySliver` 区分 history/live sliver，仅 history 补偿。
