---
name: wanling-miniprogram-publish
description: 当用户要求「写一个小程序/做个小程序/发布小程序/把小程序传到服务器/小程序上线」或提到「wanling 小程序」的编写与发布时使用。覆盖万灵小程序包格式规范与 Agent 直传上传全流程（agent 在 opencode-plugin 环境下运行）。
---

# 万灵小程序开发与发布

帮用户开发并发布万灵小程序（WebView 容器，标准 H5 技术栈）。本 skill 让你完成「写包 → 自检 → 上传 → 汇报」全流程，用户无需手动操作。

## 一、包格式规范（必须严格遵守，server 端 fail fast 校验）

```
<目录>/
├── manifest.json     # 必须在目录根
└── …                 # 静态产物（HTML/JS/CSS/图片），纯前端，无服务端代码
```

`manifest.json` 字段：

| 字段 | 必填 | 规则 |
|---|---|---|
| appid | 是 | `^[a-z0-9][a-z0-9-]{2,31}$`（小写/数字/连字符），全局唯一 |
| name | 是 | 显示名 |
| version | 是 | 正整数；**同 appid 重传必须递增**（重传=换版本且状态重置回私有） |
| entry | 否 | 入口 HTML，默认 `index.html`，必须真实存在于包内 |
| icon | 否 | 包内相对路径；扩展名 png/jpg/jpeg/webp、≤256KB、内容须为真实图片（魔数校验） |
| permissions | 否 | 白名单四选：`wanling.api` / `wanling.chat.read` / `wanling.chat.share` / `wanling.nav`，其他值会被拒 |
| navigationBar | 否 | 导航栏声明：`{"style":"default"|"custom","backgroundColor":"#RRGGBB","foregroundColor":"#RRGGBB"}`；default=宿主原生 AppBar（可配色），custom=全屏无标题栏 |
| minHostVersion | 否 | 宿主最低版本声明 |

硬限制：包 ≤ 20MB、文件数 ≤ 2000、manifest ≤ 1MB、条目名禁止 `../`/绝对路径/反斜杠。

## 二、可用的宿主 JSBridge（页面内调用）

- `wanling.request({path, method, body})` — 调万灵 API（仅 `/api/` 前缀，`/api/users/me`、`/api/me` 与 `/api/admin/*` 收紧不可调），带用户登录态，返回业务 data
- `wanling.getProfile()` — 获取当前用户身份 `{openid, nickname, avatarUrl}`（调用式授权：首次弹授权窗，拒绝可重试）。openid 为本小程序内专属匿名标识，不同小程序互不相同，永久稳定——做用户标识一律用它，不要依赖全局账号 id
- `wanling.getChatContext()` — 返回 `{conversation_id}`（仅从聊天卡片打开时有值）
- `wanling.shareToChat({title, params})` — 弹会话选择器分享卡片（仅公开小程序可分享）
- `wanling.openPage({page, params})` — 跳宿主页面白名单：`home` / `miniPrograms` / `agentDetail`（params.agentId 须 UUID）
- `wanling.close()` — 关闭小程序

权限语义：`wanling.api` 声明即生效；chat 类与 nav 首次运行由用户逐项弹窗授权，profile 为调用式授权（调 getProfile 时弹）。token 永远不会进入 JS——所有 API 必须经 `wanling.request`。

错误契约：bridge 返回的 error 恒为字符串（JS 侧 `catch (e)` 后 `e.message` 直接可读，无需判型）。语义性拒绝格式为 `-<code> <message>`，可按前缀分流：`-32091 身份信息请使用 wanlingGetProfile`（request 打到身份端点）/ `-32090 用户未授权`（getProfile 被拒）；权限拒绝为 `permission denied: <perm>`（如 `permission denied: wanling.api`）。

存储与资源：
- **localStorage 按账号隔离**：同设备多账号打开同一小程序，storage 互不可见（同账号共享）；宿主升级可能重置旧 storage，勿作为唯一持久化依赖
- **宿主资源直引**：`<img src="/api/...">` 等相对路径由宿主带登录态代理回源（GET），可直接引用当前用户可见的宿主图片资源（如 getProfile 返回的 avatarUrl）

## 二·五、页面与导航约定（强制，违反会被返回键退出）

- **不要自绘标题栏/返回按钮**——宿主 AppBar 承担标题与返回（navigationBar.style=default 时）；需要品牌化头部（搜索框等）时用 `style:"custom"` 自绘，参考 `scripts/examples/miniprogram-header/`
- **切页设置 `document.title`**：宿主 AppBar 标题实时跟随（如 `document.title='订单详情'`）
- **多级页面用 hash/history 路由**（`location.hash='#detail'` + `hashchange`）：系统返回键=回上一页，入口页再按=退出小程序；纯 div 切换没有历史，返回键会直接退出小程序
- **右上角胶囊由宿主固定提供**（更多/关闭）：自绘头部时右上角预留高 32dp、右边距 12dp 的区域，不要把可点内容放那里

## 三、发布流程

1. 在工作目录写好小程序（结构如上）
2. 自检 + 打包 + 上传一条龙：
   ```bash
   python3 <skill目录>/publish.py <小程序目录>
   ```
   脚本会先本地自检（与 server 同规则），通过后自动换 token 并上传，成功打印 server 返回的 `{id, appid, version}`。
3. 向用户汇报：appid/version、当前为私有（仅用户自己可见）、如何查看（APP 侧滑栏 → 小程序 → 我的）

## 四、常见错误对照（脚本报错 → 处理）

| 报错 | 处理 |
|---|---|
| `invalid_package` + 具体原因 | 按 message 修 manifest/包结构 |
| `appid 已被占用` | 该 appid 属其他小程序，换一个 appid |
| version 相关 | 同 appid 重传 version 必须比上次的值大 |
| `payload_too_large` | 包超 20MB，删减资源 |
| `unsupported_media_type` | 只接受 .zip |

## 五、安全规约（强制）

- `publish.py` 凭据按探测顺序取用：宿主 env 三元组（`WANLING_SERVER_URL`/`WANLING_AGENT_ID`/`WANLING_SECRET_KEY`，hermes 等宿主 agent 进程注入，身份随宿主）→ `$WANLING_CONFIG_DIR/config.json` → `~/.config/opencode-wanling`（存在则用）→ `~/.config/wanling-skills`（存在则用，子密钥）；**禁止打印、记录或把 secretKey 写进任何文件、提交或回复内容**
- 不要把 server 地址之外的实例内部信息写进小程序包
- 小程序代码运行在用户设备 WebView 沙箱内，不要引导用户输入敏感凭证

## 六、上架公共库

私有小程序仅 owner 可见。用户要求「让所有人都能用」时，告知：需要实例管理员在管理侧执行 publish（当前无自助入口，管理员可在 APP 侧栏「小程序审核」页操作，或 `PUT /api/admin/mini-programs/:id/status {"status":"published"}`）。
