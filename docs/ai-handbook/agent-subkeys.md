# Agent 子密钥授权

万灵 Agent 子密钥（sub key）授权协议:在不触碰主密钥独占绑定的前提下,给技能等**纯 REST 消费方**发放可独立吊销的凭据。三端共同遵守,被 server / app 子 CLAUDE.md 通过 @import 引用;技能侧用户视角见 `skills/README.md`「凭据获取」。

背景:扫码配对是覆盖语义(选已有 agent 必重置主密钥,见 [qr-pair.md](./qr-pair.md)),对宿主适配器(opencode/hermes,独占 WS 长连接)正确,但技能只换 token 调 REST、不建 WS,需要共享授权。子密钥即解法:**授权不动绑定,吊销不伤主密钥**。

## 概念模型

| | 主密钥(现状) | 子密钥(本协议) |
|---|---|---|
| 载体 | `agents.secret_key`,64 hex | `agent_sub_keys.secret_key`,`wlsk_<64hex>` 共 69 字符 |
| 能力 | REST + WS 长连接(绑定载体) | **仅 REST**(token 端点按 `wlsk_` 前缀路由识别) |
| 数量 | 1(轮换即失效旧值) | 每 agent 上限 10 把未吊销,可单独吊销 |
| 吊销 | `POST /api/agents/:id/rotate-secret` 重置 | 软吊销(`revoked_at`);**主密钥轮换级联吊销全部子密钥** |

前缀约定:server `auth.SubKeyPrefix = "wlsk_"` 为唯一事实源;主密钥是纯 hex,不可能撞 `wlsk_` 前缀。技能侧文档/脚本写死该前缀仅做校验,不做路由。

## 数据模型(migration 016 + 017 + 018)

```sql
agent_sub_keys(id UUID PK 应用侧生成, agent_id FK→agents ON DELETE CASCADE,
               name TEXT DEFAULT '',
               secret_key TEXT UNIQUE, created_at, last_used_at, revoked_at)
```

- `secret_key` 明文存储,对齐主密钥先例(哈希化属另一特性)
- `last_used_at`:每次子密钥成功换 token 更新(fail-soft,失败仅日志)
- `agent_id` FK **ON DELETE CASCADE**(018):agent 删除时子密钥行随级联物理删除;鉴权对悬空凭据的 401 防御为纵深兜底
- `pairing_tickets` 加 `action TEXT NOT NULL DEFAULT 'bind'` 列;**017** 把 `pairing_tickets.secret_key` 从 VARCHAR(64) 扩为 TEXT(bind 64 hex 卡满,authorize 凭据 69 字符超长必须 TEXT)

## 端点

| 方法 | 路径 | 鉴权 | 语义 |
|---|---|---|---|
| POST | `/api/agents/:id/token` | 凭据即鉴权 | **前缀路由**:`secret_key` 带 `wlsk_` → 查子密钥表(未吊销)签发 sub token + 更新 last_used_at;无前缀 → 主密钥原路径(恒定时间比较)。TTL 同为 72h |
| GET | `/api/agents/:id/subkeys` | userAuth + owner | 列表 `id/name/created_at/last_used_at/revoked_at`(created_at DESC),**不返密钥本体**(`json:"-"` + handler 不拼装) |
| DELETE | `/api/agents/:id/subkeys/:keyId` | userAuth + owner | 软吊销,幂等 200(已吊销再删仍 200,不覆盖首次时间) |
| POST | `/api/agents/:id/rotate-secret` | 现有语义不变 | 成功后追加级联 `UPDATE agent_sub_keys SET revoked_at=now() WHERE agent_id=$1 AND revoked_at IS NULL` |

**owner 数据边界**:subkeys 两端点校验 `agent.owner_id == userID`,admin 经中间件归一为 user 后同样受限(admin 不例外)。DELETE 额外做 **keyId 归属白名单**:先 `ListByAgent` 圈定名下密钥再线性匹配,keyId 不属于该 agent(含他人 agent)按不存在处理直接幂等 200、绝不执行 Revoke——封死跨 agent 越权吊销。

## JWT claims

- 子密钥 token:`key_kind="sub"` + `key_id=<agent_sub_keys.id>`;主密钥 token:`key_kind="master"`、key_id 空
- **向后兼容**:存量 token 无 `key_kind` claim 一律按 master 处理(空串=master),滚动升级窗口不断连
- 吊销粒度 = 凭证发放层:吊销/级联后已签发的 72h JWT 至自然过期仍有效(JWT 无状态是现有模型),但不能再换新 token;需要即时断连走 RotateSecret(本来就会断 WS)

## WS 拦截(sub_key_ws_forbidden)

绑定独占性由 WS 握手保证:identify 解析 token 成功后(role 归一之前)正向判定,**仅 `key_kind=="sub"` 拒绝**——空串(存量)/`"master"`/user token 一律放行。拒绝动作:

1. 回**裸 JSON 错误帧** `{"error":"sub_key_ws_forbidden"}`——非 WSMessage `{op,d}` envelope,**client 侧需按裸帧识别**(读到 `error` 字段即子密钥被拒,不能走常规 opcode 分派)
2. 服务端随即关闭连接;连接不进 hub、不注册连接表
3. 服务端 Warn 日志记录 agent_id + key_id(安全事件可追溯)

## 配对 authorize 扩展(qr-pair)

`POST /api/pair/tickets/:id/complete` 请求体加可选 `action` + `note`:

- 缺省 `bind`:现状语义零变化(新建 / 重置已有 agent 主密钥)
- `authorize`:仅允许已有 agent(新建 + authorize → 400);**不重置主密钥**,生成子密钥(`wlsk_` 前缀),`name`=请求 `note`,缺省「技能授权」;不动 agent.Type 补写、不建 conv
- 未知 action 值 → 400 fail fast(白名单 `""`/`bind`/`authorize`,防拼写变体静默降级 bind 踢掉在用 agent)

轮询 `GET /api/pair/tickets/:id` completed 响应**两分支统一带 `action` 字段**(bind 也带,消费方按它判定,不靠字段缺席区分):

| 分支 | 字段 |
|---|---|
| `bind` | `{status, action:"bind", agent_id, agent_name, secret_key(64hex), owner_user_id, owner_conv_id}`(现状字段不变) |
| `authorize` | `{status, action:"authorize", agent_id, agent_name, secret_key(wlsk_), owner_user_id}`——**无 `owner_conv_id`**(技能用不到) |

领完即焚不变(secret_key 领走后清空,已领响应只带 agent_id + action)。authorize 分支先查 agent 名再消费凭据:查询失败 500 可重试,凭据保留不烧。票据 TTL/限流/清理机制全部复用 qr-pair。

APP 侧:选已有 agent 弹三选(授权=发子密钥 / 接管=重置密钥红字警示 / 取消),见 [qr-pair.md](./qr-pair.md) 与 `app/CLAUDE.md`。

## 吊销语义与级联

- 单独吊销:DELETE subkeys 端点软吊销单把
- 级联吊销:RotateSecret 重置主密钥后吊销该 agent 全部未吊销子密钥。**尽力清扫语义**:级联失败仅记日志不回滚(主密钥重置本身已是总闸,下次 rotate 重试清扫)
- 上限:complete authorize 时按 `CountActive`(未吊销)≥10 → 409

## 边界与错误码

| 场景 | 状态码 | error |
|---|---|---|
| complete:新建 + authorize / 缺 agent_id 纯 authorize / 未知 action | 400 | `bad_request` |
| subkeys 端点非 owner(agent 存在) | 403 | `forbidden` |
| subkeys 端点 agent 不存在 | 404 | `not_found` |
| complete authorize 超 10 把上限 | 409 | `subkey_limit` |
| 子密钥换 token:已吊销 / 不存在 / agent 悬空 | 401 | 同主密钥语义 |
| WS identify 携带 sub token | 拒绝连接 | 裸帧 `sub_key_ws_forbidden`(见上节) |

## 技能侧消费(skills/install.sh --setup)

- 两步授权:①填 server URL(`--server` 或交互输入,默认 `http://localhost:18008`)→ `POST /api/pair/tickets` 打印二维码 → ②APP 扫码授权 → 2s 轮询 completed 且 `action=="authorize"` 且凭据 `wlsk_` 前缀校验通过 → 写 `config.json`(600,无明文回显)
- **写路径护栏**:`--setup` 写配置目录**忽略 `WANLING_CONFIG_DIR` env**(运行环境可能被注入该 env,env 优先属纯踩雷),只认 `--config-dir` 或默认 `~/.config/wanling-skills`;目标目录为插件专用 `opencode-wanling`/`opencode-wanling-prod` 时 die(`--force` 可越并红色警示);票据若以 bind 方式完成直接 die——**防主密钥落盘技能配置**
- **读路径探测**(publish.py / upload.py,与写路径规则不同):`WANLING_CONFIG_FILE` → `WANLING_CONFIG_DIR/config.json` → `~/.config/opencode-wanling/config.json`(存在则用,插件零影响)→ `~/.config/wanling-skills/config.json`;全缺 → 报错提示 `--setup`
- 吊销即时生效:APP 吊销子密钥后,技能下次换 token 即 401
