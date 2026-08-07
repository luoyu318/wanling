# APP Rendering

消息内容渲染器体系(注册表模式)。

## message_content_renderer

`MessageContentRenderer` 接口（`selectable`/`wrapInBubble`/`build`）+ `ContentRendererRegistry` 注册表（`MsgType → Renderer`）+ `MessageRenderContext`。MessageBubble 只管外壳，内容渲染委托给注册表查到的 renderer。扩展新类型只需写一个 renderer 并 `register`

**MessageRenderContext 透传字段**:`isMe`/`baseUrl`/`token`/`isDark`/`conversationMessages`/`openGallery`(点击图片进画廊)/`onFileTap`(点击文件触发下载 Sheet,4 参数 fileId/filename/mimeType/fileSize)/`fileDownloadSnapshots`(Map<fileId, FileDownloadSnapshot>,ChatPage 注入下载进度让 FileCard 实时切态)/`onToolGroupToggle`(折叠展开滚动补偿回调,聚合卡内可折叠元素 todowrite/权限卡终态经它同帧上报 ChatPage jumpTo,history 反向列表展开内容向上顶时视觉锚点不动)/`isHistorySliver`(当前消息所属 sliver 是否 history 反向,由 ChatPage 双 sliver 构建时透传)。`FileDownloadSnapshot` 是简单数据类(state: 0=notDownloaded/1=downloading/2=downloaded/3=uploading + progress 0.0-1.0)

## builtin_renderers

内置 renderer：`TextContentRenderer`（含 markdown 语法检测分流）、`MarkdownContentRenderer`（走 MarkdownView）、`ImageContentRenderer`（不可选/不包气泡，缩略图包 Hero + 点击进画廊 `rc.openGallery`；用 `thumbUrl` 加载服务端 600px 缩略图 + `memCacheWidth:600` 限解码尺寸 + `cacheKey=thumbCacheKey` 统一内存缓存口径）、`FileContentRenderer`（独立卡片气泡，详见下）、`CardContentRenderer`。`registerBuiltinRenderers()` 在 main.dart 启动时调。text/markdown renderer 在 `rc.isStreaming=true` 时走 `StreamingText`（整段 mdBuilder 渲染,见 [chat-components.md](./app/chat-components.md#streamingtext)）

### FileContentRenderer（v1.0.6 重写）

**独立卡片气泡**(`wrapInBubble=false`,不再走 BubbleWithTail 三角容器)。按 `mime_type` 分流:

- `text/plain` / `text/markdown` / `text/csv` → 渲染私有 `_TextPreviewCard`(白底卡片样式 + "点击预览文本内容"提示),点击 push `TextPreviewPage` 全屏预览
- 其余类型(PDF/Office/zip 等) → 渲染 `FileCard`,`downloadState` 从 `rc.fileDownloadSnapshots[fileId]` 查(无则 notDownloaded),`onTap` 触发 `rc.onFileTap`

依赖 server 端 `enhanceContentFromFile` 补全的 `file_size` + `mime_type` 字段(v1.0.6 服务端改造)。乐观发送期间 client `_mimeFromExt` 推断的 mime 作占位,server 权威值到达后覆盖

## card_renderer

**审批卡片渲染器**（msg_type=card）。`CardContentRenderer` 注册到 MsgType.card，卡片自带白底外壳（`wrapInBubble=false`，MessageBubble 仍给三角）。`_CardView` StatefulWidget 管乐观更新（点按钮立即本地切状态，失败回滚 + snackbar）。按 card_type 分流渲染：command/slash_confirm 用代码块预览，tool 用工具名+预览，file 用文件行。按钮终态映射：deny/cancel→denied，allow_once/allow_always/once/always→approved；终态文案区分（已批准/已拒绝 vs 已确认/已取消）。**`CardContentRenderer.onDecide` 是全局静态回调**，ChatNotifier 构造时注入（避免 Riverpod 循环依赖）。**`_CardView` 整体包 AnimatedSize**(250ms easeOut, alignment topCenter):pending→终态 PATCH 回写高度变化时平滑向下展开

## Agent 过程渲染器（v1.0.7，opencode-plugin streamer 发的过程消息）

9 个新渲染器，注册到 `MsgType` 枚举对应值。底部抽屉模式（`showModalBottomSheet`）替代内联展开：卡片固定高度 + 点击弹抽屉看全文。

- **TuiUserRenderer**（msg_type=tui_user）— 紫色气泡 `#7C5CE7` + 📟 via TUI 标记。ChatPage 用 `MsgTypeX.fromString` 判断 `tui_user` 覆盖 isMe=true（归位「我」侧）
- **ReasoningRenderer**（msg_type=reasoning）— 两态：流式(isStreaming=true 且 data.finished!=true)=✨ 闪烁 + 「正在思考...」固定文案;终态=真实 text 预览。元素级 `data.finished` 标记:聚合卡 generating 期间元素可能已终态(子 agent 并行),finished=true 显示真实内容而非思考中动画。点击抽屉看完整思考链
- **StepFinishRenderer**（msg_type=step_finish）— 元信息行（⏱ 耗时 / tokens / $ 费用），`reason` 字段不展示
- **ToolCallRenderer**（msg_type=tool_call）— `#FAFAFA` 底 + `#E8E8E8` 边框，按 `data.name` 分派图标（bash⚡/edit✏️/read📖/grep🔍/glob📂/todowrite📋/write📝/task🤖/question❓/默认🔧）；TodoBody 限 3 行 + 进度摘要 + 抽屉
- **ToolResultRenderer**（msg_type=tool_result）— ✅ 工具名 + 短输出直显 / 长输出截断 + 抽屉。name=task 时切 SubagentBody 样式
- **ToolErrorRenderer**（msg_type=tool_error）— ❌ 红底 + 左红边框
- **SubagentRenderer**（SubagentBody）— 非独立 msg_type，tool_call name=task 时在 ToolCallRenderer 内分派渲染（紫色子 Agent 标签）
- **QuestionRenderer**（QuestionBody）— 非独立 msg_type，tool_call name=question 时在 ToolCallRenderer 内分派渲染（选择题列表）
- **FileDiffRenderer**（msg_type=file_diff）— header（文件名 + 绿增/红删统计）+ 点击抽屉看完整 diff

### 交互事件渲染器（v1.0.8，opencode-plugin streamer 发，APP 底部抽屉处理）

- **PermissionCardRenderer**（msg_type=permission_card）— `#FFF8F0` pending 暖色卡片 + 底部抽屉 radio 三选项（仅本次/始终允许/拒绝）。`save_rules` 只读展示。终态（resolved）灰阶。用户决策通过 PATCH /api/messages/:id 回传 `permission_reply`。**终态(2026-08-08 起)外包无边框折叠外壳**(对齐折叠组风格):折叠时只显示标题行(图标 + 「权限审批 · label」+ 结果 + 箭头,结果如已批准/已拒绝/会话已结束),展开显示完整原卡(绿/红/灰背景 + 左边框样式不变);折叠展开接入 ToolGroupCard 同构滚动补偿
- **QuestionCardRenderer**（msg_type=question_card）— TabBar 横向切换题目，radio/checkbox/custom 输入，已答题标记绿色小圆点。单题退化隐藏 TabBar。提交按钮汇总后 PATCH /api/messages/:id 回传 `question_reply`

**dm_user_agent 气泡宽度**: Agent 过程消息的 `widthRatio = 0.95`（两侧各 12px padding），渲染器不带自带 maxWidth。`BubbleWithTail` 颜色: `isMe ? #597BFF : #FFFFFF`

## tool_card_renderer（v1.0.10，工具调用统一卡片）

`tool_card` msg_type 渲染器,把所有工具调用(bash/edit/read/write/task/...)统一为卡片视图 + 3 状态机 + 长输出抽屉。

- **_ToolCardRenderer** 主分派:读 `data.status` 切换 starting/working/completed/error;task 工具(name=task)走 task 专属分支保留「子 Agent」身份(含 error 状态,与 _CompletedTaskCard 对称);webfetch/skill/todowrite 三类走无外壳纯文字行/折叠行(webfetch=explore 紫 + url 单行、skill=星标橙 + 「已加载技能」+ 技能名、todowrite=折叠行)。**所有返回统一包 `_wrapAnimated`(AnimatedSize, 250ms easeOut, alignment topCenter)**:卡片 PATCH running→completed 回写增高时高度平滑向下展开,消除瞬间增高跳动
- **_TaskCardShell** 通用外壳:左边界色 + 子 Agent 徽章 + 描述 + 状态行(可注入 statusIcon,completed=check_circle/error=cancel);subSessionId 非空时整体包 GestureDetector 跳 `/chat/subagent/$taskCardId?convId=$convId`
- **task 4 状态机**: starting(蓝灰脉冲)、working(蓝色脉冲)、completed(绿色对勾 + duration)、error(红色 cancel + 失败文案,对称 completed)
- **_TruncatedOutput / _ReadCodeView**(read 工具特化):解析 read output 的 `<path>`/`<content>` XML,折叠态显示文件名+行数按钮,抽屉展开整段 highlight.parse 语法高亮(行号列 + 横向滚动)
- **_RunningToolCard / _CompletedToolCard / _ErrorToolCard**(普通工具三态):非 task 工具的简化卡片
- **input/output 双框限一行预览**(2026-08-08):所有工具卡 input body + output 下框统一 `maxLines:1` + ellipsis(超长点击弹抽屉看全文);EditBody 拆改前/改后两个独立预览框(红 `-` / 绿 `+`,各限一行);tool_result/tool_call/tool_error 旧版独立消息同步限行
- **todowrite 折叠行**(2026-08-08):脱离工具卡外壳,直接折叠组风格(✓ 图标 + 「已完成 x/y 项」+ 箭头,点击展开任务列表,任务行带状态图标 completed=✓绿/in_progress=●橙/pending=○灰,已完成划线);聚合卡不再隐藏 todowrite(移除 isHiddenTool 跳过)
- **skill 纯展示行**(2026-08-08):星标橙(Icons.auto_awesome) + 「已加载技能」+ 技能名(灰斜体),无折叠事件,点击弹抽屉看技能内容
