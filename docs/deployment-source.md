# Wanling 部署指南（源码 + systemd 路线）

本文档自洽完整，按本文件操作即可完成源码 + systemd 路线的全部部署、运维、备份、监控。
命令视角统一为 `systemctl` / `psql` / `go build`（不直接用 `docker compose`，Redis 可选用容器拉起）。

Docker Compose 路线见 [`docs/deployment-docker.md`](./deployment-docker.md)。

---

## 1. 系统架构

```
用户 APP (Flutter, Android)
    ↕ WebSocket + HTTP REST (JWT 鉴权)
Nginx/Caddy (反向代理, TLS 终止, 可选)
    ↕
Go 服务端 (:18008, systemd unit wanling-server)
    ↕ WebSocket (JWT: role=agent)
Hermes Gateway + Wanling Plugin (每个 agent 一个进程, 路线无关)
    ↕
AI 平台 (Hermes Agent)
```

依赖（由本机或公司基础设施提供，不通过容器拉起）：

| 组件 | 版本 | 是否必需 | 用途 |
|---|---|---|---|
| Linux + systemd | 任意主流发行版 | 必需 | 进程托管 / 日志 / 自启 |
| Go | >= 1.25 | 二选一 | 本机编译 server 与工具（cmd/main.go、cmd/migrate、cmd/admin-tool） |
| release 二进制 | 跟随发版 | 二选一 | 无 Go 环境时从发版附件下载预编译二进制 |
| PostgreSQL | >= 15 | 必需 | 消息 / 用户 / Agent 持久化 |
| Redis | >= 7 | 可选 | 在线状态 / 限流（不装自动降级单机内存，单实例无影响） |
| Flutter | >= 3.44 | APP 构建时需要 | 打包客户端，路线无关 |
| Python | >= 3.11 | hermes 端需要 | Hermes 插件运行时，路线无关 |

> Redis 不装也能跑：限流降级为单进程内存计数，在线状态恒返回离线。即便配置了 Redis 但 Ping 失败（网络抖动 / Redis 宕机），server 也不 `log.Fatal`，而是打 `[WARN]` 并以 `rdb=nil` 降级启动。多实例部署时这会导致限流 / 在线状态不一致，单实例无影响。
>
> 在线状态自愈：presence 心跳续期用幂等 `SET`（带 ttl）。Redis 被 `FLUSHALL` 或 server 重启（WS 连接不断开）后，下一次心跳（秒级）自动重建，agent 在线状态自愈，无需重连 WS。

migration 文件清单与表结构见 [`docs/ai-handbook/migrations.md`](./ai-handbook/migrations.md)（`001_init.sql` 已合并历史完整 schema，新增 schema 变更用 `NNN_<feature>.sql`）。

---

## 2. 前置条件

- **Linux 服务器**（systemd 支持；本路线不适用 Windows Server）
- **Go >= 1.25**（用于编译 server / migrate / admin-tool）——或从 release 附件下载预编译二进制
- **PostgreSQL >= 15**（已安装或自装，server 与 PG 通常同机部署）
- **Redis >= 7**（可选；不装会自动降级）
- 服务器外网防火墙：默认开放 `80/443`（如要前置 nginx），按需开放 `18008`（如不走反代）

版本自检：

```bash
go version               # >= go1.25
psql --version           # >= 15
redis-cli --version      # >= 7（可选）
systemctl --version      # systemd 任意现代版本
```

创建运行用户与目录骨架：

```bash
sudo useradd -r -s /bin/false wanling
sudo mkdir -p /usr/local/wanling/{bin,etc,uploads,backups}
sudo chown -R wanling:wanling /usr/local/wanling
```

---

## 3. 数据库初始化（建库）

> 本节**只建库**（CREATE DATABASE），不执行 schema migration。schema 由 §4 的 `cmd/migrate` 统一执行（带版本表追踪）。

**前置**：PG 已安装且 superuser / 有建库权限的账号可用。

**方式一：脚本建库（推荐，幂等）**

仓库提供的 `scripts/init_db.sh` 已精简为只建库（不碰任何 `.sql` 文件），第 5 个位置参数指定库名：

```bash
./scripts/init_db.sh [host] [port] [user] [password] [db-name]
# 默认：localhost 6333 agent agent123 wanling
# 例：本机 PG 标准 5432 端口 + 自定义密码
./scripts/init_db.sh localhost 5432 agent '<strong-password>' wanling
```

**方式二：手动 SQL**

```sql
-- 用 superuser 或有 CREATEROLE 权限的账号连 postgres 库执行
CREATE USER agent WITH PASSWORD '<strong-password>';
CREATE DATABASE wanling OWNER agent;
```

验证：

```bash
psql -U agent -d wanling -h localhost -p 5432 -c "SELECT 1"
```

> 多实例场景：建多个库即可，如 `CREATE DATABASE wanling_b OWNER agent;`。`init_db.sh` 末位参数换成 `wanling_b` 同样适用（详见 §12）。

---

## 4. 跑 Migration（核心：首次部署与升级用同一个工具）

**这是源码 + systemd 路线的关键步骤**。万灵的 schema migration 统一由 `cmd/migrate` 工具执行——它维护 `schema_migrations` 版本表，事务内应用 SQL + 登记版本，**幂等**：已应用的 migration 会跳过，未应用的按文件名顺序执行。

> 不要再用旧的 `for m in *.sql; do psql -f ...; done` 循环：那种方式没有版本追踪，每次都重跑全部 SQL，遇到非幂等的 DDL（如 `ALTER TABLE ADD COLUMN`）会失败。也不要直接 `psql -f server/migrations/001_init.sql` 单独跑。

### 4.1 编译 migrate 工具

```bash
cd server
go build -o /tmp/wanling-migrate ./cmd/migrate
```

### 4.2 执行 migration

```bash
# 应用全部未应用的 migration（已是最新时退出码 0，不报错）
/tmp/wanling-migrate --env=.env

# 查看已应用版本（只读，不改库）
/tmp/wanling-migrate --env=.env --status
```

> **路径说明**：`cmd/migrate` 启动时从当前目录向上查找 `go.mod` 定位 project root，并在其下读 `migrations/` 子目录。因此**运行前先 `cd server`**（go.mod 所在目录）即可，`--env=` 指向 `server/.env` 或绝对路径 `/usr/local/wanling/etc/.env` 均可。
>
> **幂等机制**：首次部署时 `schema_migrations` 表不存在，工具会 `CREATE TABLE IF NOT EXISTS`（`version VARCHAR(255) PRIMARY KEY` + `applied_at TIMESTAMPTZ`），然后逐个文件执行 + 登记。后续每次升级只跑新增的 `NNN_<feature>.sql`。
>
> **重量级 migration 提醒**：含 `ADD COLUMN ... STORED` 生成列的 migration（如 008 `messages_main_stream`）会让 PostgreSQL 重写整张 `messages` 表——每行计算生成列并落盘，期间持 `ACCESS EXCLUSIVE` 锁阻塞读写。万灵私域部署通常 messages 行数有限（数千~数十万），耗时数秒到数分钟；但仍建议**低峰期执行**，并先 `--status` 确认是否已应用。预估量级：1 万行约 < 1s，10 万行约数秒。

### 4.3 交互式替代

不想记命令可走 `scripts/admin.sh` 菜单 [9]：

```bash
./scripts/admin.sh
# 选 [9] 数据库迁移：先打印 --status，回车确认后才执行
# 服务器上跑时指定 env 文件路径：
#   export MIGRATE_ENV_FILE=/usr/local/wanling/etc/.env && ./scripts/admin.sh
```

### 4.4 服务器端跑（首次部署）

把源码或编译产物放到服务器，然后：

```bash
ssh user@server
cd /usr/local/wanling   # 或源码 clone 路径
# 已编译好的 migrate 二进制放在 bin/，migrations/ 目录与二进制同级或源码目录里
# 需先把 server/migrations/ 同步到服务器（rsync 命令见 §10.2）
/tmp/wanling-migrate --env=/usr/local/wanling/etc/.env --status
/tmp/wanling-migrate --env=/usr/local/wanling/etc/.env
```

---

## 5. 配置 .env

从模板复制：

```bash
cp server/.env.example server/.env
```

必填项（生产场景示例）：

```ini
SERVER_PORT=18008
DB_HOST=localhost
DB_PORT=5432
DB_USER=agent
DB_PASSWORD=<your-db-password>      # 与 §3 建库时一致
DB_NAME=wanling
DB_SSLMODE=disable                  # 与 PG 同机部署可 disable；跨机走 TLS 改 require

REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=
REDIS_DB=0                          # 多实例用不同 db 隔离，见 §12

# 必填，openssl rand -hex 32 生成
JWT_SECRET=<generate-with-openssl-rand-hex-32>

STORAGE_PATH=/usr/local/wanling/uploads
CORS_ALLOWED_ORIGINS=*             # 生产环境限制为具体域名（如 https://chat.example.com）
WS_ALLOWED_ORIGINS=                # 可选。逗号分隔的 WS Origin 白名单（如 http://localhost:3000,https://chat.example.com）；空=同源校验(Origin host == Host header)；无 Origin 头(plugin adapter 等非浏览器 client)始终放行。Nginx 单域名反代场景留空即可,多域名/多子域名场景需配
```

生成 JWT 密钥：

```bash
openssl rand -hex 32
```

文件权限收紧：

```bash
chmod 600 server/.env
```

> **部署到服务器时**：把 `.env` 拷到 `/usr/local/wanling/etc/.env`（systemd unit 的 `EnvironmentFile=` 指向它，见 §7）。

---

## 6. 编译 server

### 6.1 源码编译（本机有 Go）

```bash
cd server
CGO_ENABLED=0 go build -ldflags="-s -w" \
    -o /usr/local/wanling/bin/wanling-server ./cmd/main.go
```

`-ldflags="-s -w"` 去掉调试符号缩小体积；`CGO_ENABLED=0` 编出纯静态二进制，跨机 / 跨 glibc 版本可移植。

### 6.2 Release 二进制（无 Go 环境）

从发版附件下载预编译的 `wanling-server-linux-amd64`，放到 `/usr/local/wanling/bin/wanling-server` 并 `chmod +x`。

### 6.3 文件存储目录

确保 `STORAGE_PATH`（默认 `/usr/local/wanling/uploads`）存在且 owner 是运行用户：

```bash
sudo mkdir -p /usr/local/wanling/uploads
sudo chown -R wanling:wanling /usr/local/wanling/uploads
```

对象存储扩展（MinIO / S3）接口已在 `server/internal/storage/` 预留，实现 `FileStorage` 接口后在 `cmd/main.go` 替换注入即可，handler / repository 层无需改动。

---

## 7. systemd 服务

`/etc/systemd/system/wanling-server.service`：

```ini
[Unit]
Description=Wanling Server
After=network.target postgresql.service redis.service

[Service]
Type=simple
User=wanling
WorkingDirectory=/usr/local/wanling
EnvironmentFile=/usr/local/wanling/etc/.env
ExecStart=/usr/local/wanling/bin/wanling-server
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
```

启用：

```bash
# 把 .env 拷到 etc/
sudo cp server/.env /usr/local/wanling/etc/
sudo chown wanling:wanling /usr/local/wanling/etc/.env
sudo chmod 600 /usr/local/wanling/etc/.env

sudo systemctl daemon-reload
sudo systemctl enable --now wanling-server
```

启动 Redis（可选，任选一种）：

```bash
# 方式 A：systemd（本机自装）
sudo systemctl enable --now redis

# 方式 B：Docker 容器（仅 Redis 这一个组件走容器）
docker run -d --name agent-redis -p 6379:6379 redis:7-alpine
```

---

## 8. 创建用户（重要）

**万灵没有开放公开注册 API**，必须用 admin-tool 加用户。这一步在旧文档的源码路线里缺失，必须补上。

### 8.1 命令行：admin-tool

```bash
cd server
go build -o /tmp/wanling-admin ./cmd/admin-tool

# 服务器上 .env 在 /usr/local/wanling/etc/ 时（用 sudo bash -c 在单进程内 source + 执行）
sudo bash -c 'set -a; . /usr/local/wanling/etc/.env; set +a; exec /tmp/wanling-admin add-user --username=alice --password=secret123'
```

> 本机开发场景直接 `cd server` 后跑 `/tmp/wanling-admin add-user ...` 即可，admin-tool 会自动从 `server/.env` 读 DB 配置。
> `--password` 不传时从 `/dev/tty` 无回显读取（≥6 位）。

admin-tool 子命令：

| 命令 | 作用 |
|---|---|
| `add-user --username=<name> [--password=<pwd>]` | 创建用户（注册接口已关，这是唯一加用户途径） |
| `reset-password --username=<name> [--new-password=<pwd>]` | 重置密码 |
| `list-users` | 列出所有用户（表格输出 id / username / created_at） |

### 8.2 交互式：admin.sh 菜单

```bash
./scripts/admin.sh
# [1] 添加用户（提示输入用户名 + 密码）
# [2] 重置用户密码
# [3] 列出所有用户
```

`admin.sh` 自动编译 admin-tool、加载 `server/.env`、调对应子命令。服务器上跑时 `set -a; . /usr/local/wanling/etc/.env; set +a` 后再跑即可。

---

## 9. 健康检查

```bash
curl http://localhost:18008/health    # 进程存活，返 {"status":"ok"}（不验依赖）
curl http://localhost:18008/ready     # 依赖就绪，返 {"status":"ready"}（验 DB + Redis 连通）
```

- `/health` 适合 load balancer 判断进程在不在
- `/ready` 适合判断「能不能服务」（DB 挂了 `/ready` 返 503）

systemd 视角的存活检查：

```bash
systemctl is-active wanling-server    # active / inactive / failed
systemctl status wanling-server       # 详细状态 + 最近日志
```

---

## 10. 升级

### 10.1 一键脚本（推荐）

仓库提供的 `scripts/deploy.sh` 封装了完整流程：本地编译 → rsync 到远程 → 跑 migration → systemctl restart → 健康检查轮询。

```bash
./scripts/deploy.sh                # 发布当前 HEAD
./scripts/deploy.sh --build-only   # 仅本地构建，不推送
```

依赖 `server/.env.deploy`（`REMOTE_HOST=user@ip`、`REMOTE_PATH=/usr/local/wanling`），不存在会打印提示并退出。

**关键行为（v1.0.6+）**：

- **migration 快速失败**：迁移失败默认 `die` 中止发布（schema 不匹配会让重启后的 server 查表 500，比停下更糟）。已是最新（无待应用 migration）时退出码 0 不误伤。需强制跳过：`SKIP_MIGRATE_FAIL=1 ./scripts/deploy.sh`（风险自负）
- **健康检查轮询**：`systemctl restart` 后轮询 `is-active`（最多 15s）+ HTTP `/health`（最多 10s），取代固定 `sleep 2`。避免「服务在但路由还没起来」或「restart 还没完成」的窗口期误判

### 10.2 手动升级（无 deploy.sh 时）

```bash
# 1. 编译新二进制
cd server
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" \
    -o /tmp/wanling-server-linux ./cmd/main.go

# 2. 编译 migrate 并推送
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" \
    -o /tmp/wanling-migrate-linux ./cmd/migrate

rsync -avz /tmp/wanling-server-linux user@server:/usr/local/wanling/bin/wanling-server.new
rsync -avz /tmp/wanling-migrate-linux user@server:/tmp/wanling-migrate
rsync -avz --delete server/migrations/ user@server:/usr/local/wanling/migrations/

# 3. 远程跑 migration（与首次部署完全一致的工具）
ssh user@server "/tmp/wanling-migrate --env=/usr/local/wanling/etc/.env --status"
ssh user@server "/tmp/wanling-migrate --env=/usr/local/wanling/etc/.env"

# 4. 原子替换 + 重启
ssh user@server "cd /usr/local/wanling/bin && cp wanling-server wanling-server.prev && mv wanling-server.new wanling-server"
ssh user@server "sudo systemctl restart wanling-server"
```

---

## 11. 回滚

```bash
# 1. 停服
sudo systemctl stop wanling-server

# 2. 恢复数据库（如需；migration 不向后兼容时才需要）
gunzip -c /usr/local/wanling/backups/wanling_YYYYMMDD.sql.gz | \
    psql -U agent -d wanling

# 3. 切回旧二进制（deploy.sh 自动保留 .prev）
sudo cp /usr/local/wanling/bin/wanling-server.prev /usr/local/wanling/bin/wanling-server

# 4. 启动
sudo systemctl start wanling-server
```

> migration 一般只增不改（新增 `NNN_<feature>.sql`），向后兼容旧二进制。仅在出现破坏性 migration（删列 / 改类型）时才需要恢复 DB。`schema_migrations` 表的版本记录会随 DB 备份一起保留，恢复后无需重新标记。

---

## 12. 同机多实例部署（server + opencode-plugin）

场景：同一台机上跑两套独立的 Wanling（如开发版 + 稳定版、多租户隔离）。核心思路是**端口 + 数据库 + Redis + storage + configDir** 五维隔离，OpenCode 数据目录全局共用。

> Hermes Plugin 的部署与多实例（多 profile）见 [`docs/architecture/plugin/hermes-deploy.md`](./architecture/plugin/hermes-deploy.md)。

### 12.1 隔离维度

| 维度 | 实例 A（默认） | 实例 B（示例） | 隔离手段 |
|------|----------------|----------------|----------|
| server 端口 | `SERVER_PORT=18008` | `SERVER_PORT=18009` | `.env` 或环境变量覆盖 |
| PG 库名 | `DB_NAME=wanling` | `DB_NAME=wanling_b` | `init_db.sh ... wanling_b` 建库 + `.env` 指向 |
| Redis db | `REDIS_DB=0` | `REDIS_DB=1` | `.env` |
| 文件存储 | `STORAGE_PATH=…/uploads` | `STORAGE_PATH=…/uploads_b` | `.env` |
| systemd 服务名 | `wanling-server` | `wanling-server-b` | 复制 unit 文件改名 |
| opencode-plugin configDir | `~/.config/opencode-wanling/` | `~/.config/opencode-wanling-b/` | `install.sh --config-dir=` |
| opencode-plugin 服务名 | `opencode-wanling` | `opencode-wanling-b` | `install.sh --service-name=` |
| opencode serve / proxy / control 端口 | 4096 / 5096 / 19780 | 4097 / 5097 / 19781 | `install.sh --opencode-port=` 等 |
| OpenCode 数据目录 | `~/.local/share/opencode/` | **共用** | 设计如此，不隔离 |

> **鉴权(1.2.1+)**：`opencode attach` 需带 `--password <token>`，token 为 config.json 的 `proxyPassword`（首次启动自动生成，chmod 600，可见于启动日志或 config.json，可用 `WANLING_PROXY_PASSWORD` 环境变量覆盖）。Control API（curl `/status` 等）需 `Authorization: Bearer <token>`，token 见启动日志 `[control] API token:`（每次启动重新生成）。

### 12.2 server 多实例

为实例 B 单独建库 + 一份 `.env`：

```bash
./scripts/init_db.sh localhost 5432 agent '<password>' wanling_b
```

复制 systemd unit，改服务名和 `EnvironmentFile=` 路径：

```bash
sudo cp /etc/systemd/system/wanling-server.service \
        /etc/systemd/system/wanling-server-b.service
sudo vim /etc/systemd/system/wanling-server-b.service
# 改：Description、EnvironmentFile 指向实例 B 的 .env
sudo systemctl daemon-reload
sudo systemctl enable --now wanling-server-b
```

实例 B 的 `.env` 至少改这五项：`SERVER_PORT` / `DB_NAME` / `REDIS_DB` / `STORAGE_PATH` / `JWT_SECRET`（强烈建议不同密钥）。

> `godotenv.Load()` 不覆盖已存在的环境变量——所以也可以用环境变量覆盖 `.env` 里的端口/库名，其余（DB 密码、JWT_SECRET）由 `.env` 补充。

### 12.3 opencode-plugin 多实例

OpenCode Plugin（TypeScript）桥接 OpenCode CLI 与 Wanling server，每个实例绑定一个 agent。

**前置条件**：Node.js >= 18、`opencode` CLI 在 PATH 中。

**单实例安装**：

```bash
cd plugin/opencode-plugin
./install.sh --server=http://localhost:18008 \
  --agent-id=<uuid> --secret-key=<key>
# 或扫码配对（推荐，无需手输凭据）
./install.sh --pair --server=http://localhost:18008
```

安装产物：配置写入 `~/.config/opencode-wanling/config.json`，systemd user service `opencode-wanling`，shell 别名 `ocwl` / `ocwl-restart`。

**多实例安装**（第二套，隔离 configDir + 端口 + 服务名）：

```bash
./install.sh \
  --config-dir=$HOME/.config/opencode-wanling-b \
  --service-name=opencode-wanling-b \
  --opencode-port=4097 --proxy-port=5097 --control-port=19781 \
  --server=http://localhost:18009 \
  --agent-id=<实例B的-agent-id> --secret-key=<key>
```

shell 别名按 configDir 自动派生：默认实例 `ocwl`，非默认实例 `ocwl-<suffix>`（如 `ocwl-b`）。每个实例的 systemd unit 注入 `WANLING_CONFIG_DIR`，让 plugin 的 `config.json` / `session-maps.json` / `pending-cards.json` 三套状态文件随 configDir 隔离。

> **OpenCode 数据目录共用**：所有实例的 `opencode serve` 读写同一个 `~/.local/share/opencode/`（session db / repos / snapshot）。这是设计决定——OpenCode 是全局共享的开发工具，隔离的是 Wanling 侧的会话映射与凭据，不是 OpenCode 自身的工作区。

`install.sh --help` 查看完整选项；`--update` 模式只同步代码不动配置。

> **运行时调优旋钮**（systemd unit 注入 `Environment=` 后重启服务即可生效，无需重编译）：
> - `WANLING_MAX_DOWNLOAD_BYTES` — plugin 下载 Agent 产生文件的单文件上限，默认 20 MB（防 OOM / 磁盘滥用）。大文件场景（代码库归档等）可调大，如 `52428800`（50 MB）。
> - `WANLING_CHILD_TIMEOUT_MS` — 子 session（subagent / task 工具）漏发终态时的强制清理超时，默认 1800000（30 min）。复杂 task 跑久被误清时调大。

---

## 13. Nginx 反向代理

生产环境强烈建议前置 nginx 做 TLS 终止 + WebSocket 升级。仓库提供现成模板（[`deploy/nginx/`](../deploy/nginx/)）：

- `nginx.example.conf` — 纯 HTTP 反代（内网 / Cloudflare 前置 / 自签场景）
- `nginx-tls.example.conf` — 含 TLS（直接对公网）

用法：

```bash
sudo cp deploy/nginx/nginx-tls.example.conf /etc/nginx/sites-available/wanling
sudo vim /etc/nginx/sites-available/wanling    # 改 server_name + 证书路径
sudo ln -s /etc/nginx/sites-available/wanling /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

证书申请 + 自动续期见 [`deploy/nginx/README.md`](../deploy/nginx/README.md)。

**APP 端配置**：用户在 APP 设置里填反代后的 URL（如 `https://chat.example.com`），不是 `http://ip:18008`。

systemd 路线下，建议 nginx 反代到 `127.0.0.1:18008`，并把 `SERVER_PORT=18008` 仅监听本地（防火墙规则不放通公网）。

> **多域名 WS 放行**：若同一 server 实例被多个域名访问（如 `chat.example.com` + `chat2.example.com`），WS 握手的 Origin 校验需配 `WS_ALLOWED_ORIGINS=https://chat.example.com,https://chat2.example.com`（逗号分隔），否则非主域名的 WS 连接会被拒。单域名场景留空走同源校验即可。

---

## 14. APP 构建发布

> **平台支持**：APP 仅 Android 发布（Linux desktop / iOS 不做支持，相关构建章节已移除）。

### 14.1 Android APK

```bash
cd app
PUB_HOSTED_URL=https://pub.flutter-io.cn \
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
flutter build apk --release --flavor prod
# 输出：build/app/outputs/flutter-apk/app-prod-release.apk
```

### 14.2 Android 运行时配置要点

APK 构建命令本身没特殊，但要让 APP 真正在 Android 上跑起来（后台收消息、上传头像、发通知），需确认 `android/app/src/main/AndroidManifest.xml` 含以下权限与服务声明：

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
    android:maxSdkVersion="32" />
<uses-permission android:name="android.permission.CAMERA" />
```

`flutter_background_service` 还需在 `<application>` 内注册 service + receiver：

```xml
<service
    android:name="id.flutter.flutter_background_service.android.BackgroundService"
    android:foregroundServiceType="dataSync"
    android:exported="false" />
<receiver
    android:name="id.flutter.flutter_background_service.androidBootReceiver"
    android:enabled="true"
    android:exported="false">
    <intent-filter>
        <action android:name="android.intent.action.BOOT_COMPLETED" />
    </intent-filter>
</receiver>
```

**固定竖屏**：`MainActivity` 的 `<activity>` 加 `android:screenOrientation="portrait"`。APP 走单栏布局，不支持横屏。

> **明文 HTTP 允许**：APP 默认连 `http://localhost:18008` 或自定义服务器地址。若服务端未上 TLS，需在 `android/app/src/main/res/xml/network_security_config.xml` 配置 `cleartextTrafficPermitted`，并在 manifest 引用 `android:networkSecurityConfig="@xml/network_security_config"`。生产环境强烈建议服务端上 TLS（见 §13）。

---

## 15. 备份和恢复

### 15.1 数据库逻辑备份

```bash
pg_dump -U agent -d wanling | gzip > \
    /usr/local/wanling/backups/wanling_$(date +%Y%m%d).sql.gz
```

### 15.2 文件备份

```bash
rsync -av /usr/local/wanling/uploads/ backup.example.com:/backups/wanling/
```

### 15.3 数据库恢复

```bash
gunzip -c /usr/local/wanling/backups/wanling_20260622.sql.gz | \
    psql -U agent -d wanling
```

### 15.4 定期清理未引用文件

```bash
find /usr/local/wanling/uploads -type f -mtime +90 -delete
```

### 15.5 Cron（建议每天凌晨备份）

```cron
0 3 * * * pg_dump -U agent -d wanling | gzip > /usr/local/wanling/backups/wanling_$(date +\%Y\%m\%d).sql.gz
0 4 * * * rsync -av /usr/local/wanling/uploads/ /backup/files/
0 5 * * * find /usr/local/wanling/backups/ -name '*.sql.gz' -mtime +30 -delete
```

---

## 16. 监控

### 16.1 关键指标

| 指标 | 来源 / 命令 | 告警阈值 |
|------|------|---------|
| 服务端是否存活 | `systemctl is-active wanling-server` | 非 active |
| WebSocket 连接数 | Hub `sync.Map` Range 计数（需自接指标） | 突降 50% |
| PG 连接数 | `psql -U agent -d wanling -c "SELECT count(*) FROM pg_stat_activity"` | > 100 |
| 磁盘（uploads 目录） | `df -h /usr/local/wanling/uploads` | > 80% |
| Gateway 连接状态 | `hermes gateway status`（hermes 侧，路线无关） | disconnected |

### 16.2 日志（systemd journal）

```bash
journalctl -u wanling-server -f                              # 跟踪 server 日志
journalctl -u wanling-server --since "1 hour ago" | grep -i error
journalctl -u wanling-server -n 100                          # 最近 100 行
```

> **Access log 降噪**：服务端用自定义 `handler.BusinessAccessLog()` 中间件（`server/internal/handler/access_log.go`），只记录命中注册路由的请求。扫描器探测的 NoRoute 404（`/mcp`、`/actuator/health`、`/HNAP1` 等）**完全静默**，不污染 journal。判定用 gin 的 `c.FullPath()`（命中 NoRoute 返回空串）。file_handler 的错误都用 `log.Printf` 带 `[upload]`/`[download]` 前缀打 stderr，可用 `journalctl -u wanling-server | grep -E "\[upload\]|\[download\]"` 过滤。

---

## 17. 安全清单

- [ ] `JWT_SECRET` 使用 `openssl rand -hex 32` 生成，非默认值
- [ ] PostgreSQL 密码强度 >= 16 位随机
- [ ] Nginx 开启 TLS 1.2+，禁用 TLS 1.0/1.1
- [ ] 防火墙仅放通 443（Nginx）；18008 仅监听 127.0.0.1（`SERVER_PORT` 不对公网暴露，走反代）
- [ ] `CORS_ALLOWED_ORIGINS` 限制为具体域名（生产环境不要留 `*`）
- [ ] Agent `secret_key` 仅通过安全渠道传输（不在日志 / commit 中泄露）
- [ ] hermes 插件 `WANLING_ALLOW_ALL_USERS` 生产环境关闭，改用 `WANLING_ALLOWED_USERS`
- [ ] `/usr/local/wanling/etc/.env` 文件权限 `600`，owner 仅限 `wanling` 用户
- [ ] 定期 `apt upgrade` / `yum update` 系统补丁
- [ ] 多实例场景每套实例用独立 `JWT_SECRET`（见 §12）

---

## 18. 故障排查

| 症状 | 检查项 |
|------|--------|
| 客户端连不上 | `systemctl status wanling-server`；`ss -tlnp \| grep 18008` |
| 登录失败 | PG 是否可达：`psql -U agent -d wanling -c "SELECT 1"` |
| WS 连接断开 | `journalctl -u wanling-server \| grep -i error` |
| Agent 不在线 | Gateway 状态：`hermes gateway status`、检查 `~/.hermes/logs/gateway.log` |
| 图片不加载 | `STORAGE_PATH` 权限（owner 是否 `wanling`）/ 磁盘空间 / Nginx body size 限制 |
| 首次启动报错 DB 连接 | `/usr/local/wanling/etc/.env` 中 `DB_*` 是否正确、PG 是否监听对应端口、`pg_hba.conf` 是否放行 |
| migration 报错退出 | `cmd/migrate` 事务内失败会 Rollback + 退出码 1；查 `schema_migrations` 表已登记到哪个版本，对比 `server/migrations/` 目录找断点 |
| 老库接 cmd/migrate（表已存在但版本表空） | 用 `/tmp/wanling-migrate --env=.env --mark-applied` 把现有 schema 标记为 baseline，再跑正常 migrate |
| migration 重跑已应用文件 | 确认走的是 `cmd/migrate`（读 `schema_migrations` 跳过），不是 `for f in *.sql; do psql -f` 循环（无版本追踪，每次重跑） |
| 升级后 server 查表 500 | 多半是 migration 没跑或没跑完——`/tmp/wanling-migrate --env=.env --status` 看版本，必要时手动补跑 |
| admin-tool 报 DB 连接失败 | `.env` 没加载——确认 `cd server` 后跑，或服务器上 `set -a; . /usr/local/wanling/etc/.env; set +a` 后再跑 |
| systemd unit 启动失败 | `journalctl -u wanling-server -n 50`；检查 `EnvironmentFile=` 路径、`User=wanling` 是否存在、二进制路径是否对 |
| Android APP 后台收不到通知 | 系统设置 → 应用 → 电池优化（加入白名单）、通知权限是否授予、`foregroundServiceType` 是否声明 |
| Android 杀掉重启后登录态丢失 | 检查 `flutter_secure_storage` 是否被系统清理；Android 13+ 需 `POST_NOTIFICATIONS` 运行时申请 |
| Android 头像选图崩溃 | `wechat_assets_picker` + `crop_your_image` 已绕开 ActivityResult，旧版本仍崩溃需升级到最新 commit |
| APK 构建报 Kotlin 版本冲突 | `wechat_camera_picker` 间接拉 `sensors_plus 7.x`（需 Kotlin 2.2），项目 Built-in Kotlin 为 2.0。`pubspec.yaml` 的 `dependency_overrides` 已固定 `sensors_plus: ^6.1.1`，若仍报错检查 override 是否生效 |
| admin-tool 命令报路径错（Windows Git Bash） | 加 `MSYS_NO_PATHCONV=1` 前缀；或直接用 PowerShell |
