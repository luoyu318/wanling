# 万灵 v1.0.5 发布说明

> **版本号**：`1.0.5+7`
> **应用 ID**：`com.wanling.app`
> **应用名**：万灵
> **平台**：Android
> **构建产物**：`app-release.apk`（92.4 MB）
> **发布日期**：2026-06-23
> **Git 标签**：`v1.0.5`

---

## 一、本次更新概览

本次为**审批卡片系统**首发版本。Agent 执行敏感操作前会发送卡片到对话，用户通过按钮决策，替代了原先的纯文本审批。覆盖四类审批场景：

1. **危险命令审批**（如 `rm -rf`）—— 三按钮「允许 / 始终 / 拒绝」
2. **工具审批** —— 两按钮「允许 / 拒绝」
3. **文件审批** —— 两按钮「允许 / 拒绝」
4. **破坏性 slash 命令审批**（`/new` `/clear` `/reset` `/undo`）—— 三按钮「执行一次 / 不再询问 / 取消」

---

## 二、新功能与改进

### 1. 审批卡片交互

- **卡片式 UI**：带气泡三角的白底卡片，风格与普通气泡统一
- **强对比三色按钮**（绿 / 蓝 / 红实心）+ 矢量图标（check / shield / close），不再用 emoji
- **5 分钟倒计时**：每秒刷新，超时自动失效为 `expired` 终态
- **乐观更新**：点按钮即时本地切换视觉（按钮变色），失败回滚 + snackbar 提示
- **双端状态同步**：决策后通过 WS `MESSAGE_UPDATE` 广播，多设备/多端按钮同步置灰
- **终态展示**：选中按钮加深变色 + 其他按钮置灰 + 右上角状态徽章（✓已批准 / ✗已拒绝 / ⏰已超时）

### 2. 后端审批系统

- **`approvals` 表 + 状态机**：`pending → approved/denied/expired`（终态不可逆），migration 008/009/010
- **会话级命令白名单**：危险命令审批选「始终」后写入 `allow_pattern`，下次同会话同 agent 发同 pattern 命令时直接放行（`*`/`?` 通配，大小写敏感对齐 shell）
- **后台超时清理**：`RunCleanup` goroutine 每 1 分钟扫描超时审批，标记 expired 并广播 `APPROVAL_EXPIRED`
- **WS 协议扩展**：新增 3 个 Dispatch 事件
  - `MESSAGE_UPDATE`（双端）—— 消息内容更新，APP 切换卡片终态
  - `APPROVAL_DECIDED`（仅 agent）—— 推决策结果，带 session_key / confirm_id 路由到等待协程
  - `APPROVAL_EXPIRED`（仅 agent）—— 超时通知
- **HTTP API**：
  - `POST /api/conversations/:id/approvals`（agent 创建审批卡片）
  - `POST /api/approvals/:id/decide`（user 决策）
  - `GET /api/approvals/:id`（双角色兜底查询）
  - `POST /api/agents/me/conversations`（agent 视角 findOrCreate，供 agent 主动发起审批时定位会话）
- **限流**：审批 API 20/min

### 3. Hermes 插件接入

- 实现 `send_exec_approval` / `send_slash_confirm` 跨平台契约（hermes gateway 检测这两个方法存在即走卡片路径，否则降级文本）
- **立即返回设计**：发卡片后立即返回 `success=True`，不 await 用户决策（hermes gateway 调用有 15s timeout，await 会被杀掉）
- 用户决策通过 `APPROVAL_DECIDED` 事件异步回传，插件按 decision 分流唤醒 hermes 等待队列：
  - `once/always/cancel` → `tools.slash_confirm.resolve(session_key, confirm_id, choice)`
  - `allow_once/allow_always/deny` → `tools.approval.resolve_gateway_approval(session_key, choice)`

### 4. 拒绝流程精简

- 用户点「拒绝」**直接触发拒绝**，不再弹理由填写框（hermes 内部不支持回传拒绝理由，故移除该 UI）

---

## 三、安装说明

### 最低系统要求
- Android 5.0（API 21）及以上

### 安装步骤
1. 将 `app-release.apk` 传输至手机（USB / 网盘 / 蓝牙均可）
2. 手机端点击 APK 文件
3. 首次安装若提示「未知来源应用」，按系统引导允许「从该来源安装」
4. 完成安装后打开「万灵」

### 覆盖安装（升级）
- 直接覆盖安装即可，用户数据与登录态保留

### 服务端升级（自托管用户必读）
本次涉及数据库 migration，**必须执行**：
```bash
cd server
go run ./cmd/migrate          # 跑 008/009/010
# 或手动 psql 执行 migrations/008/009/010 三个文件
```
并同步更新 hermes 插件（含审批卡片接入代码）：
```bash
cd <hermes-plugin 目录>
./install.sh --update         # 同步最新插件代码
```

---

## 四、已知限制与说明

1. **iOS 暂不支持**：本次仅构建 Android APK
2. **「始终允许」仅会话级**：危险命令的「始终」白名单作用于单个会话内，不跨会话。slash 命令的「不再询问」是 hermes 端持久化 config（关掉这类命令的确认），语义不同
3. **拒绝不带理由**：用户拒绝时无法填写理由回传给 agent（hermes `tools.approval` 内部不支持 reason 字段）

---

## 五、变更文件清单

| 文件 | 类型 | 说明 |
|------|------|------|
| `server/migrations/008_approvals.sql` | 新增 | 审批卡片表 |
| `server/migrations/009_approval_confirm_id.sql` | 新增 | confirm_id 字段（slash_confirm 用） |
| `server/migrations/010_approval_slash_confirm_type.sql` | 新增 | 放宽 card_type CHECK 加 slash_confirm |
| `server/internal/model/approval.go` | 新增 | Approval / CardContent / FileRef model |
| `server/internal/repository/approval_repo.go` | 新增 | CRUD + 状态机 + 白名单匹配 |
| `server/internal/approval/service.go` | 新增 | 决策编排 + 双写 content + dispatch |
| `server/internal/approval/cleanup.go` | 新增 | 超时清理 goroutine |
| `server/internal/hub/dispatch.go` | 新增 | 3 个审批广播 helper |
| `server/internal/handler/approval_handler.go` | 新增 | 审批 3 接口 |
| `server/internal/handler/conversation_handler.go` | 修改 | 加 FindOrCreateAsAgent |
| `server/cmd/main.go` | 修改 | 路由注册 + cleanup 启动 + 限流 |
| `app/lib/models/approval.dart` | 新增 | 审批数据模型 |
| `app/lib/rendering/card_renderer.dart` | 新增 | 卡片渲染器（乐观更新 + 状态机） |
| `app/lib/widgets/card_button.dart` | 新增 | 三色按钮组件 |
| `app/lib/widgets/card_state_badge.dart` | 新增 | 终态徽章 |
| `app/lib/widgets/countdown_timer.dart` | 新增 | 倒计时组件 |
| `app/lib/models/msg_type.dart` | 修改 | 加 card 枚举 |
| `app/lib/services/api_service.dart` | 修改 | decideApproval / getApproval |
| `app/lib/services/websocket_service.dart` | 修改 | messageUpdates Stream |
| `app/lib/providers/chat_provider.dart` | 修改 | 处理 MESSAGE_UPDATE |
| `plugin/hermes-plugin/adapter.py` | 修改 | send_exec_approval / send_slash_confirm + WS 事件处理 |

---

## 六、提交记录

```
（v1.0.5 本次发布）
b533c78 升级: APP 版本号至 v1.0.5
9ce5c19 修复: ApprovalRepo.Create 空ID导致测试 panic
6726562 合并: 审批卡片功能（feature/approval-card）
02bc64d 新增: slash_confirm 审批卡片（/new /clear /reset /undo 等破坏性命令）
cb6f451 修复: 会话列表最后一条为审批卡片时预览为空
63723a8 调整: 审批卡片拒绝不再弹理由框
cecb8dc 修复: 审批卡片决策 404「审批不存在」
730832f 修复: send_exec_approval 立即返回（之前 await user 决策被 hermes 15s timeout 杀掉）
989e33b 新增: agent 视角 findOrCreate 接口 + plugin 走 HTTP 兜底
...（共 23 个 feature 提交 + 修复）
```

> 版本递进：v1.0.4（字号调优 + gradle 内存修复）→ **v1.0.5（审批卡片系统）**

---

## 七、致谢与反馈

如发现 Bug 或有功能建议，请通过以下方式反馈：
- 提交 Issue 至代码仓库
- 附带：设备型号、Android 版本、复现步骤、截图

---

*万灵 · 唤灵即应*
