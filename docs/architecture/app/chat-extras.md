# APP 新增组件（v1.0.9+）

本次开发新增 widget，按功能域分组。`widgets/` 顶层 + `widgets/chat/` 子目录混排，按功能聚合而非目录。

## 二级会话目录面板

AgentSessionsPage 的目录聚合视图（Drawer / 侧栏共用）：

- **`directory_utils`**(`utils/`)— `DirectoryInfo` 数据类(`path?`/`sessionCount`/`unreadCount`/`pendingCount`/`busyCount`) + `groupByDirectory`（按 `conversation.directory` 分组,NULL = 「未分类」）+ `computeBusyCount`（读 `agentStatusProvider` 聚合 session 的 busy 态）+ `buildDirectoryList`（聚合 + 排序:选中态 → 有未读 → 有 pending → 有 busy → 字母序）
- **`DirectoryPanel`**(`widgets/`)— 目录面板主体(ConsumerWidget)。`ReorderableListView` 长按拖拽排序持久化 + 目录头部(目录名 + session 数 + 未读 badge + pending/busy 计数) + 「新建会话」入口。Drawer(窄屏) / 侧栏(宽屏 `splitView`)共用
- **`DirectoryTile`**(`widgets/`)— 单个目录行。选中态左竖线 + 圆形彩色气泡(首字母) + 目录名 marquee 滚动(超长) + 副标题(session 数 / pending · busy 三档优先级)
- **`DirectoryPickerSheet`**(`widgets/`)— 目录选择底部弹层。`showDirectoryPickerSheet(context, agentId, defaultDirectory?)` 拉 `GET /api/agents/:id/rpc` 的 `project.list` 列 OC 已知项目 + 「默认」项。返 `({directory?, cancelled})`
- **`DirectoryMenuBadge`**(`widgets/`)— 目录切换按钮(AgentSessionsPage AppBar 左侧 menu IconButton)上的双色角标。`build(unread, pending)` 静态方法返回 `List<Widget>`(Positioned 列表,空列表 = 无角标),红色未读右上(`#FA5151`)+ 橙色待处理左下(`#FF9500`),镜像对称。聚合**全部目录**(含当前选中)的 unread/pending,引导用户感知其他目录动态;两者独立 badge 避免语义重叠(一条 pending_card 可同时是 unread)导致数字虚高。每个 badge 包 `IgnorePointer` 不拦截下层 IconButton 点击事件。定位基于 48×48 IconButton(top/right/bottom/left=10)。复用 `_BadgePill` 胶囊(同 UnreadBadge 风格,99+ 截断,白描边)

## Agent 状态三体指示器

agent_session 的 agent 状态可视化（平衡势能物理模型）：

- **`ThreeBodyPhysics`**(`widgets/chat/`)— 三体物理模拟(`Body` 质点 + `TrailFrame` 轨迹帧)。三质点在平衡势能场中运动,按 agent 状态调参:idle 慢速回中 / busy 活跃运动 / retry 抖动。纯 Dart 物理,不依赖 Flutter
- **`ThreeBodyIndicator`**(`widgets/chat/`)— 三体指示器 widget(StatefulWidget + `CustomPainter`)。`Ticker` 驱动 60fps 重绘,`_ThreeBodyPainter` 画三质点 + 拖尾。三青灵韵配色(青/蓝/紫)。用于 SessionTile 副标题(列表页 busy 态) + chat_page agent 状态文案。读 `agentStatusProvider` 切态
- **`ShimmerText`**(`widgets/chat/`)— 逐字符波浪扫光动效(StatefulWidget)。`Ticker` 驱动,每个字符错相位渐变扫光。用于品牌文案 / 状态提示

## 文件浏览套件

FileBrowserPage / FilePreviewPage 的辅助组件（2026-07 单栏重做后,只剩图标 + diff 查看器；原双栏时代的 SplitView / SplitToggleButton / Breadcrumb / FileListAside / FileViewer / FilePreviewBar 已删除）：

- **`FileEntryIcon`**(`widgets/chat/`)— 文件条目图标。按 `type` dir|file + 扩展名映射彩色图标
- **`DiffPatchViewer`**(`widgets/chat/`)— unified diff patch 查看器。`DiffLine` 解析 +/- 行 + `_DiffLineRow` 染色渲染(绿增/红删/灰上下文)。SessionDiffFilePage 用

## 命令 / 模型选择面板

agent_session 输入栏的斜杠命令 + 模型切换：

- **`SlashHandle`**(`widgets/chat/`)— 屏边感应线,触发斜杠命令面板。吸附侧中点判定(`relativeX < 0.5` 贴左 / `≥ 0.5` 贴右,纯函数可单测)
- **`SlashCommandSheet`**(`widgets/chat/`)— 命令面板。按 `source` 分组(命令/技能) + 搜索 + 列表。位置贴感应线一侧(贴右→卡片右 / 贴左→卡片左),贴近顶部。读 `slash-catalog` 清单
- **`ModelPickerSheet`**(`widgets/chat/`)— 模型选择弹出框(`ModelPickerDialog`)。紧凑列表 + 搜索 + provider 过滤 pill。按 provider 分段 + radio 选中标记,搜索同时匹配 name 和 id。读 `models` 清单

## 其他 banner / 菜单

- **`LocalStoreBanner`**(`widgets/`)— 本地存储异常提示 banner。监听 `localStoreHealthProvider`:degraded(true) 时显示「本地存储异常」。触发条件:`_persistToStore` 连续失败超阈值(磁盘满 / DB 损坏)。amber 色警告
- **`ConvActionMenu`**(`widgets/`)— 会话长按操作菜单(置顶/取消置顶 + 删除)。`PageRouteBuilder(Duration.zero)` 无动画弹出,全屏 GestureDetector 点空白关闭。菜单左上角对齐 `globalPos`,带边界保护不溢出
