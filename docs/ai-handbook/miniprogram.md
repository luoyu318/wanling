# 小程序协议(容器 + 包签名)

万灵小程序跨系统协议真相源:server 包校验/两层模型/端点、APP WebView 容器 JSBridge/权限/验签、聊天卡片协议。设计 spec:docs/superpowers/specs/2026-08-31-miniprogram-container-design.md。开发者教程:docs/miniprogram-dev-guide.md。

## 1. 包格式(server 校验,fail fast)

zip 包,manifest.json 必须在压缩包根目录。任一规则不满足即 400 `invalid_package`(明细随 message 下发)。

manifest.json 全字段:

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| appid | string | 是 | 全局唯一,正则 `^[a-z0-9][a-z0-9-]{2,31}$`;兼作 APP 虚拟 origin(`<appid>.mini.wanling.local`)与本地安装目录名 |
| name | string | 是 | 显示名 |
| version | int | 是 | 正整数,同 appid 单调递增;重传即换版本 |
| entry | string | 否 | 入口 HTML,默认 `index.html`,必须存在于包内 |
| icon | string | 否 | 图标**包内相对路径**,扩展名 png/jpg/jpeg/webp,≤256KB;上传时校验存在+魔数(fail fast);列表 DTO 下发为相对 URL `/api/mini-programs/{id}/icon?v={版本}`(无 icon 空串,APP 用首字哈希色块 fallback) |
| permissions | string[] | 否 | 白名单:`wanling.api` / `wanling.chat.read` / `wanling.chat.share` / `wanling.nav`,未知值拒绝 |
| navigationBar | object | 否 | 导航栏声明:`{style, backgroundColor, foregroundColor}`;style ∈ `default`(缺省,宿主原生 AppBar)/`custom`(隐藏 AppBar 全屏,SafeArea 避让状态栏);颜色 `#RRGGBB`,非法值 400 |
| minHostVersion | string | 否 | 宿主 APP 最低版本声明,server 当前不校验 |

容器交互约定(APP 侧实现,小程序遵守):
- **标题同步**:宿主 AppBar 标题跟随 `document.title`(WebView onTitleChanged),默认 fallback manifest.name;小程序切页时设置 `document.title` 即可,零协议
- **返回键语义**:宿主拦截系统返回(含 AppBar 返回键)→ WebView `canGoBack()` 为真回上一页,否则退出小程序;因此多级页面导航须用 hash/history 路由(产生 history 条目),纯 div 切换会被返回键直接退出
- **禁止自绘标题栏**:default 形态下标题/返回由宿主 AppBar 承担,小程序不再画 header
- **右上角胶囊**(宿主固定提供,两形态均显示):`●●● 更多`(刷新/分享到会话/关闭)+ `◉ 关闭`;default 形态驻留 AppBar 右侧、入口页(无历史)隐藏返回键,custom 形态悬浮 WebView 右上角(SafeArea 下 6dp/右边距 12dp,高 32dp);**自绘头部时页面右上角须预留该区域**,避免内容被胶囊遮挡
- **胶囊分享与 bridge 分享同规则**:仅 published + 声明 `wanling.chat.share` 可用,否则提示未申请权限

硬限制:
- 包大小:压缩后与解压后总大小均 ≤ 上限(默认 20MB,`MINIPROGRAM_MAX_ZIP_BYTES` 可配);请求体超限 413 `payload_too_large`
- 文件数 ≤ 2000;manifest.json ≤ 1MB
- 路径穿越拒绝:条目名含 `../`、绝对路径、反斜杠一律拒绝(解压总大小 uint64 饱和加累加,防溢出回绕绕过)

## 2. 两层模型(migrations 012/013)

`mini_programs` 表:id / appid UNIQUE / owner_id / name / version / manifest(jsonb) / package_file_id(→files) / sha256 / size / status / signature(NULL=未签)。

状态机(流转仅 admin,非法流转 409 `invalid_transition`):

```
private → published ⇄ disabled
```

- owner 上传即 `private`(仅自己可见可运行);admin publish 上公共库(published 全员可见可运行);disabled 停用(APP 拒绝运行)
- owner 语义:appid 被他人占用上传 403;owner 仅能删自己的 private(否则 409 `invalid_state`);包下载非 owner 仅 published 放行(防 IDOR)
- 同 owner 同 appid 重传 = 换版本:覆盖版本信息并重置 `private` + `signature=NULL`(包字节已变旧签作废,需重新 publish 重新签名)
- 仅 published 可分享聊天卡片(shareToChat 校验)

## 3. 端点(均在 AuthMiddleware 后)

| 方法 | 路径 | 鉴权组 | 说明 |
|---|---|---|---|
| POST | /api/mini-programs | user+agent | 上传 zip 新建私有 / 同 owner 换版本;agent 直传 handler 内 owner 换算(照 file_handler 先例) |
| GET | /api/mini-programs | user | published 全量 + 自己的(含 disabled);DTO 扇出 manifest 字段 + sha256/size/signature |
| GET | /api/mini-programs/signing-key | user | 下发 ed25519 公钥 `{public_key}`(私钥永不出 server) |
| DELETE | /api/mini-programs/:id | user | 仅 owner 删自己的 private,否则 409 |
| GET | /api/mini-programs/:id/package | user+agent | 包下载(owner 或 published),响应头 `X-Mini-Program-Sha256` |
| GET | /api/mini-programs/:id/icon | user+agent | 图标只读(owner 或 published,鉴权同 package);按 `mp-icon/{appid}/{version}` 快照取,`Cache-Control: public, max-age=86400`,Content-Type 按魔数嗅探;无 icon 404 |
| PUT | /api/mini-programs/:id/status | admin | publish / disable,状态机白名单 |

上传链路:MaxBytesReader 413 → `.zip` 扩展名 415 → `ValidatePackage` 400 → appid 归属判定(他人 403 / 自己换版本 / 新建)→ sha256 + storage.Save + files 落库。

## 4. JSBridge(window.wanling)

**核心安全决策:token 不进 JS。** JS 调 API 经原生代理注入 Bearer(401 走宿主既有 refresh 重试)。容器页每小程序独立虚拟 origin `https://<appid>.mini.wanling.local`,静态文件由 shouldInterceptRequest 从本地包目录读取(zip-slip 第二层防护,解压时第一层);外链导航一律拦截。

| API | 权限 | 行为 |
|---|---|---|
| `wanling.request({path, method?, body?})` | wanling.api | path 仅允许 `/api/` 前缀;归一化(剥 query/fragment + URI 解码 + 消解 `.`/`..`/`%2e`)后仍须 `/api/` 前缀,防 `/api/../xxx` 绕过 |
| `wanling.getChatContext()` | wanling.chat.read | 返回 `{conversation_id}`;仅从聊天卡片打开时有值,独立打开 null |
| `wanling.shareToChat({title?, params?})` | wanling.chat.share | 弹会话选择器 → 以 `mini_program_card` 发消息;仅 published 可分享;用户取消 rejected `cancelled` |
| `wanling.openPage({page, params?})` | wanling.nav | 跳宿主页面白名单:`home`(出栈回消息页)/`miniPrograms`(小程序列表)/`agentDetail`(params.agentId 必填且须 UUID);白名单外/非法参数 rejected |
| `wanling.getProfile()` | 无(调用式授权) | 返回 `{openid, nickname, avatarUrl}`;授权键 `wanling.profile` 不进 manifest,首次调用弹授权对话框(拒绝不落痕,下次调用重弹),允许后 KVS 落痕;appid 由宿主注入,JS 不可传参 |
| `wanling.close()` | 无 | 关闭小程序页 |

- envelope:原生返回 `{ok: true, data}` / `{ok: false, error}`,JS bootstrap 将 ok 转 resolve(data)/throw Error(error)
- 权限 fail fast:未声明/未授权直接 reject `permission denied: <perm>`,不静默降级
- 有效权限 = manifest 声明 ∩ 用户已授权(只收窄,不放大)
- **身份端点收紧**(宿主行为,存量包立即生效无需改包):`wanling.request` 归一化后命中 `/api/users/me`(真实身份端点,返回全局 user_id)/`/api/me`(防御性拦截,server 当前无此路由,防未来别名漏拦;精确匹配)或 `/api/admin/`(前缀)→ 拒绝,错误 `{code: -32091, message: '身份信息请使用 wanlingGetProfile'}`;迁移指引:身份获取改用 `wanling.getProfile()`
- **JS 错误消费契约**:语义性拒绝(用户未授权 -32090 / 端点收紧或不支持 -32091)envelope error 为 jsonrpc 对象 `{code, message}`,传输异常(网络/原生异常)为 String;宿主 bootstrap 统一 `throw new Error(error)`,对象形态经 String 转换后 `e.message` 显示 `[object Object]`(已知限制),JS 侧按 `e.message === '[object Object]'` 判型为语义性拒绝

## 5. 权限模型(双轨)

**声明式权限**(`manifest.permissions`,启动弹序列):
- `wanling.api`:不涉及用户会话数据,manifest 声明即静默生效,无弹窗
- `wanling.chat.*`(read/share):首次运行逐项弹授权对话框,拒绝 = 该项持续 reject;文案:read「读取当前会话 ID(用于关联你正在看的会话)」/ share「向你选择的好友/群聊分享小程序卡片」
- `wanling.nav`:跳宿主页面白名单,首次运行弹授权对话框(跳转动作不涉及用户数据读取,但宿主导航属可感知行为需用户知情);拒绝 = 持续 reject

**调用式授权**(`wanling.profile`,不在声明体系):
- 不进 manifest.permissions、不占启动弹序列;首次调 `wanling.getProfile()` 时弹授权对话框(「身份信息授权」/「将向该小程序提供你的昵称、头像与用户标识」)
- 拒绝不落痕(无持久拒绝态,下次调用重弹,对齐声明式 M2 拒绝语义);允许后写 KVS 授权痕,后续调用直接返回
- openid 端点失败时 bridge 返回错误,不静默、不缓存失败结果

- 授权按 appid 持久化本地 drift KVS(key `mp_perm:{ownerId}:{appid}`,JSON 能力集),增量合并幂等;`wanling.profile` 复用同键存储
- 卸载小程序同步清 KVS 授权(重装即重新授权)+ 清本地包目录与 WebView storage

### openid 身份语义

- `wanling.getProfile()` 返回的 openid 是 **per-(用户×小程序) 唯一标识**:同一用户在不同小程序(appid)下 openid 不同,小程序之间不可凭 openid 关联同一用户
- **永久稳定**:server 端按 (user_id, appid) 二元组惰性生成随机 UUID,一经生成不变(卸载重装 openid 不变;匿名性来自 per-app 隔离而非可变性)
- 存储:`mini_program_openids` 表(migration 015),`PRIMARY KEY (user_id, appid)` + `UNIQUE(openid)`;换取端点 `GET /api/mini-programs/openid?appid=xxx`(userAuth,小程序不存在 404 防枚举)
- appid 由宿主容器注入 bridge,JS 不可传参,防伪造他人 appid 枚举;昵称头像取本地登录态快照,零额外往返

## 6. 消息卡片协议

```
msg_type: "mini_program_card"
data: { appid: string, title: string, icon?: string, params?: any }
```

- APP shareToChat 发出(title 缺省用小程序名);server 零改动(msg_type 为自由字符串)
- `data.icon`(可选):分享时刻的 icon 相对 URL 快照(`?v=` 版本参数,与列表 DTO `icon` 字段同值);消息不可变恒为分享时刻图标,缺失(旧消息/无 icon 包)渲染端走通用图标 fallback
- 渲染:大图卡(hero icon 84dp + 底部标题栏,独立卡不包气泡);缺 appid 脏数据降级占位,不抛异常
- 点击 → `/mini-program/<appid>?conv=<来源会话>[&launch=<URL 编码 JSON params>]`:conv 供 getChatContext 返 conversation_id,launch 透传入口 query(H5 URLSearchParams 自取,percent-encode 往返无损)

## 7. 包签名机制

- 密钥:server 首次启动生成 ed25519 keypair(Go 标准库 `crypto/ed25519`),hex 存 `mp_signing_key` 单行表;公钥经 signing-key 端点下发,私钥永不出 server
- 签名时机:publish 时对包字节签名 → `signature` 列(失败不阻断 publish,记日志由补签兜底);server 启动对历史 published 缺签包自动补签(单包失败继续,整轮零进展终止,残留留待下次启动)
- 换版本重传 signature=NULL,旧签作废
- APP 验签(cryptography 包 Ed25519;裸 32 字节公钥 hex + 裸 64 字节签名 hex):
  - 策略:**签名存在必验,缺失放行**(升级过渡期,放行记日志)
  - 公钥缓存链:KVS 缓存命中直接用 → 未命中拉 signing-key 端点并写缓存 → 首验失败且有缓存 → 绕缓存强制重拉公钥再验一次(公钥轮换自愈)→ 两次失败抛「签名验证失败」拒装
  - verifyEd25519 纯函数:hex/长度异常一律返 false 不抛(验签失败是安全决策结果而非程序异常)
- 安装顺序:下载 → sha256 校验(不匹配抛「sha256 不匹配」严禁跳过安装)→ ed25519 验签 → 解压到 .tmp → 原子换目录 + 清理旧版本;打开时版本比对静默更新

## 组件清单

- server:`internal/miniprogram`(validate.go 包校验 / signing.go ed25519 纯函数)、`handler/mini_program_handler.go`(含 openid 查询端点)、`repository/mini_program_repo.go` + `mini_program_openid_repo.go`(GetOrCreateOpenid) + `signing_key_repo.go`、`migrations/012` / `013` / `015`
- app:`pages/mini_program_page.dart`(WebView 容器 + profile 授权弹窗)、`services/mini_program_bridge.dart`(wanlingGetProfile / 端点收紧) + `mini_program_permission_flow.dart`、`pages/mini_program_list_page.dart`(公共库/我的两个分组 + 上传/卸载)、`widgets/mini_program_conversation_picker.dart`
- wanling_core:`services/mini_program_service.dart`(下载/sha256/验签/解压安装)、`rendering/mini_program_card_renderer.dart`、`providers/mini_programs_provider.dart`
- 示例:`scripts/examples/miniprogram-hello/`(appid `hello-demo`)
