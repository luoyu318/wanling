# 万灵小程序开发指南

面向第三方开发者:如何构建、上传、运行、调试一个万灵小程序。协议细节(包格式 / JSBridge / 两层模型 / 签名)见 [docs/ai-handbook/miniprogram.md](./ai-handbook/miniprogram.md),本文以可直接跑通的 hello-demo 为例。

完整示例:`scripts/examples/miniprogram-hello/`(appid `hello-demo`,三按钮演示:`wanling.request` / `wanling.getChatContext` / `wanling.shareToChat`)。

## 1. 最小包手工构建

目录结构(zip 根目录直接含 manifest.json,不要把外层文件夹打进 zip):

```
hello-demo/
├── manifest.json
└── index.html
```

manifest.json:

```json
{
  "appid": "hello-demo",
  "name": "Hello 示例",
  "version": 2,
  "entry": "index.html",
  "icon": "icon.png",
  "permissions": ["wanling.api", "wanling.chat.read", "wanling.chat.share"],
  "minHostVersion": "1.6.3"
}
```

字段约束(全字段表见协议文档 §1):

- `appid`:匹配 `^[a-z0-9][a-z0-9-]{2,31}$`,全局唯一,先到先得(他人占用上传 403)
- `version`:正整数,同 appid 重传即换版本
- `permissions`:只能从 `wanling.api` / `wanling.chat.read` / `wanling.chat.share` / `wanling.nav` 里选,未知值整个包被拒
- `entry` 缺省 `index.html`,但无论写什么,该文件必须真实存在于包内
- `navigationBar`(可选):`{"style":"default"|"custom","backgroundColor":"#RRGGBB","foregroundColor":"#RRGGBB"}`;default=宿主原生 AppBar(可配色),custom=全屏无标题栏
- `icon`(可选):包内相对路径(如 `icon.png`),扩展名 png/jpg/jpeg/webp,≤256KB;上传时校验文件存在+魔数,缺一整包被拒。建议 512×512 PNG;宿主在列表宫格/底栏直接展示(圆角遮罩由宿主处理),未提供时用「名称首字+哈希色块」fallback

## 页面与导航约定(容器托管,小程序免画标题栏)

- **不要自绘标题栏/返回按钮**——宿主 AppBar 承担标题与返回(default 形态)
- **切页时设置 `document.title`**:宿主 AppBar 标题实时跟随,例如 `document.title = '订单详情'`
- **多级页面用 hash/history 路由**(如 `location.hash='#detail'` + `hashchange`),系统返回键=回上一页;入口页再按返回=退出小程序。纯 div 切换不产生历史,返回键会直接退出小程序
- **右上角胶囊为宿主固定提供**(更多/关闭,两形态均显示):自绘头部时右上角预留 `高 32dp、右边距 12dp` 的区域,避免内容被遮挡(微信小程序同款规范)
- 参考实现:`scripts/examples/miniprogram-showcase/index.html`(hash 路由 + document.title 同步)、`scripts/examples/miniprogram-header/index.html`(custom 自绘搜索框头部)

index.html 是一个纯静态页,需要宿主能力时调 `window.wanling`(完整示例见 `scripts/examples/miniprogram-hello/index.html`):

```html
<script>
// 万灵 API 代理(需 wanling.api;path 仅允许 /api/ 前缀),失败 throw Error
const types = await wanling.request({ path: '/api/agent-types', method: 'GET' });

// 会话上下文(需 wanling.chat.read):从聊天卡片打开返回 {conversation_id},独立打开 null
const ctx = await wanling.getChatContext();

// 分享卡片到会话(需 wanling.chat.share;仅 published 小程序可用),用户取消 throw 'cancelled'
const r = await wanling.shareToChat({ title: '标题', params: { any: 'json' } });

// 关闭小程序页
wanling.close();
</script>
```

打包:

```bash
cd hello-demo && zip -r ../hello-demo.zip .
```

## 2. 全流程:上传 → 私有运行 → 授权 → 分享 → publish

1. **上传**:APP「万灵」tab → 小程序列表 → 上传按钮 → 系统文件选择器选 zip。任意用户可上传,包落为 `private`(仅自己可见可运行)。Agent 也可用 agent token 直传 `POST /api/mini-programs`(owner 记到 agent 服务的真实用户)
2. **私有运行**:列表「我上传的」分组点开即运行。页面运行在独立虚拟 origin `https://<appid>.mini.wanling.local`,登录 token 不进 JS,API 调用全部经 `wanling.request` 原生代理
3. **权限弹窗**:首次运行时,`wanling.chat.read` / `wanling.chat.share` 逐项弹授权对话框(允许/拒绝;拒绝后对应 API 持续 reject)。`wanling.api` 不弹窗,manifest 声明即静默生效。授权结果本地持久化,**卸载小程序即重置**,重装重新授权
4. **分享卡片**:页内调 `wanling.shareToChat({title, params})` → 弹会话选择器 → 以 `mini_program_card` 发到所选会话。**仅 published 状态可分享**,私有小程序会 reject「仅公开小程序可分享到会话」
5. **admin publish**:管理员对该小程序执行 `PUT /api/mini-programs/:id/status` body `{"status":"published"}` → 进入公共库全员可见。publish 时 server 自动对包做 ed25519 签名
6. **消息侧闭环**:收到卡片的好友点击 → 冷启动小程序并携带来源会话(`conv`)与启动参数(`launch`,URL 编码 JSON),页内 `getChatContext()` 拿到 `conversation_id`,`launch` 从入口 URL query 用 `URLSearchParams` 自取

## 3. 调试

- 页内 `console.log` 输出建议接 vConsole 类页内日志面板(无 remote-debug,页内日志最省事);hello-demo 用 `<pre id="out">` 展示结果,同思路
- JSBridge 错误以 rejected promise 的 `Error(message)` 抛出,`try/catch` 后展示即可;server 校验失败时 400 的 message 含具体明细,先看返回再对照下表

常见错误对照表:

| 错误 | 出处 | 原因与处理 |
|---|---|---|
| `invalid_package`(400) | 上传 | 包结构/manifest 校验失败,message 含明细:非法 zip / 缺少 manifest.json / manifest.json 过大 / appid 需匹配正则 / name 必填 / version 需为正整数 / 未知 permission / entry 不在包内 / 非法包内路径 / 文件数超 2000 / 解压后总大小超上限 |
| `payload_too_large`(413) | 上传 | 包超大小上限(默认 20MB) |
| `unsupported_media_type`(415) | 上传 | 文件扩展名非 `.zip` |
| `forbidden`:appid 已被占用(403) | 上传 | appid 归他人所有,换一个 appid |
| `permission denied: wanling.api` | 运行时 | manifest 未声明,或声明集与授权集交集为空 |
| `permission denied: wanling.chat.read / wanling.chat.share` | 运行时 | 首启弹窗被拒绝;卸载重装可重新授权 |
| `仅公开小程序可分享到会话` | 运行时 | `shareToChat` 要求 published,先请管理员 publish |
| `仅允许 /api/ 前缀路径` / `路径归一化后越出 /api/ 白名单` | 运行时 | `request` 的 path 不合法或试图 `..` / `%2e` 穿越 |
| `sha256 不匹配: 期望 ... 实际 ...` | 安装时 | 下载损坏或服务端数据不一致;重试下载,仍失败重传包 |
| `签名验证失败` | 安装时 | 包字节被篡改或公钥已轮换;APP 会先自动重拉公钥再验一次,仍失败则拒装 |
| `非法 zip` / `缺少 manifest.json` | 上传 | 打包层级错误:manifest.json 必须在 zip 根目录,不要把外层文件夹一起压进去 |

## 4. 版本更新语义

- `version` 单调递增;同 appid 重传要求 owner 一致,整包覆盖(新包字节 + 新 manifest)
- **静默更新**:APP 打开小程序时对比服务端 `version` 与本地已装版本,不一致自动下载替换(下载 → sha256 → 验签 → 解压 .tmp → 原子换目录),用户无感
- 换版本重传后状态重置为 `private` 且签名清空:已 published 的小程序改包后需管理员重新 publish(重新签名后公共可见);重 publish 前 shareToChat 与公共库均不可用
- 宿主能力白名单只有一层:`/api/` 前缀 REST(经 `wanling.request`);页面自身可直接 fetch 外部网络(容器只拦截虚拟 origin 的静态资源请求),但登录凭证永不进 JS,宿主数据一律走 `window.wanling`
