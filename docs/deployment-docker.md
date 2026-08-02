# Wanling 部署指南（Docker Compose 路线）

本文档自洽完整，按本文件操作即可完成 Docker Compose 路线的全部部署、运维、备份、监控。
命令视角统一为 `docker compose`（不直接用 `systemctl` / 裸 `psql`）。

---

## 1. 系统架构

```
用户 APP (Flutter, Android)
    ↕ WebSocket + HTTP REST (JWT 鉴权)
Nginx/Caddy (反向代理, TLS 终止, 可选)
    ↕
Go 服务端 (:18008, 容器 server)
    ↕ WebSocket (JWT: role=agent)
Hermes Gateway + Wanling Plugin (每个 agent 一个进程, 路线无关)
    ↕
AI 平台 (Hermes Agent)
```

依赖（均由 compose 起容器，无需本机自装）：

| 组件 | 镜像 | 容器名(服务名) | 用途 |
|---|---|---|---|
| PostgreSQL 16 | `postgres:16-alpine` | `postgres` | 消息 / 用户 / Agent 持久化 |
| Redis 7 | `redis:7-alpine` | `redis` | 在线状态 / 限流（连不上自动降级单机内存，单实例无影响） |
| Migrate（one-shot） | 本仓 `server/Dockerfile` | `migrate` | 首启 + 升级时自动跑 schema migration，跑完即退 |
| Wanling Server | 本仓 `server/Dockerfile` | `server` | 业务服务端，监听 `:18008` |

> Redis 不装也能跑：限流降级为单进程内存计数，在线状态恒返回离线。即便配置了 Redis 但 Ping 失败（网络抖动 / Redis 宕机），server 也不 `log.Fatal`，而是打 `[WARN]` 并以 `rdb=nil` 降级启动。多实例部署时这会导致限流 / 在线状态不一致，单实例无影响。
>
> 在线状态自愈：presence 心跳续期用幂等 `SET`（带 ttl）。Redis 被 `FLUSHALL` 或 server 重启（WS 连接不断开）后，下一次心跳（秒级）自动重建，agent 在线状态自愈，无需重连 WS。

migration 文件清单与表结构见 [`docs/ai-handbook/migrations.md`](./ai-handbook/migrations.md)（`001_init.sql` 已合并历史完整 schema，新增 schema 变更用 `NNN_<feature>.sql`）。

---

## 2. 前置条件

- **Docker Engine >= 24**
- **Docker Compose v2 >= 2.20**（`docker compose` 子命令形式，非旧版 `docker-compose` 独立二进制）
- 服务器外网防火墙：默认开放 `80/443`（如要前置 nginx），按需开放 `18008`（如不走反代）
- 磁盘空间：镜像 build 后约 1-2 GB + uploads 数据增长
- 首次 build 镜像需要外网拉取 `postgres:16-alpine` / `redis:7-alpine` / Go 编译依赖

版本自检：

```bash
docker version              # Server version >= 24
docker compose version      # v2 >= 2.20
```

---

## 3. 一键启动（prod）

仓库提供 3 个模板文件（入 git）：

- `docker-compose.example.yml`（base 配置：4 个核心服务）
- `docker-compose.prod.example.yml`（prod override）
- `docker-compose.dev.example.yml`（dev override，开发模式用，见 §11）

用户拷贝成实际文件（已被 gitignore，改了不跟上游冲突）：

```bash
git clone <repo> && cd wanling

# 拷贝 compose 模板
cp docker-compose.example.yml docker-compose.yml
cp docker-compose.prod.example.yml docker-compose.prod.yml
# （开发模式改用：cp docker-compose.dev.example.yml docker-compose.dev.yml）

# 拷贝 .env 模板并填值
cp .env.example.docker .env

# 编辑 .env，填两个必填项（生成命令在文件注释里）：
#   POSTGRES_PASSWORD=<openssl rand -hex 32>
#   JWT_SECRET=<openssl rand -hex 32>
vim .env

# .env 里 COMPOSE_FILE 默认指向 prod，直接启动：
docker compose up -d
```

首次启动会自动 build 镜像（耗时 3-5 分钟）。启动完成后按 §5 验证。

> **可选环境变量**（多域名场景需配，单域名留空即可）：`WS_ALLOWED_ORIGINS`（逗号分隔的 WS Origin 白名单，空=同源校验，详见 §12 多域名 WS 放行）。

### 3.1 compose 内部链路说明（一条命令背后发生了什么）

`docker compose up -d` 这一条命令在内部按依赖顺序自动完成了**建库 → 跑 migration → 启服务**三步，用户不需要手动建库，也不需要手动跑 migration。链路如下（依据 `docker-compose.example.yml`）：

**第 1 步：postgres 官方镜像首启自动建库**

`postgres` 服务用 `postgres:16-alpine` 官方镜像（`docker-compose.example.yml:10`）。该镜像的 entrypoint 在数据目录为空（首次启动）时，读取环境变量自动完成：

- 用 `POSTGRES_USER`（默认 `wanling`）创建超级用户
- 用 `POSTGRES_DB`（默认 `wanling`）创建数据库，owner 设为上面的用户
- 用 `POSTGRES_PASSWORD` 设置该用户密码

所以**不需要手动 `CREATE DATABASE` / `CREATE USER`**。healthcheck 用 `pg_isready` 探活（`:16-20`），最多重试 10 次。

**第 2 步：migrate one-shot 自动跑全部 migration**

`migrate` 服务（`docker-compose.example.yml:34-51`）复用同一份 server 镜像，把 entrypoint 换成 `/app/wanling-migrate`（即 `cmd/migrate` 二进制），command 为 `["up"]`，按文件名顺序应用 `server/migrations/*.sql`。关键设计：

- `depends_on: postgres: condition: service_healthy`（`:47-49`）—— 等 PG 的 healthcheck 通过后才起
- `restart: "no"`（`:51`）—— one-shot，跑完即退，正常退出码 0

**第 3 步：server 等 migrate 成功完成才起**

`server` 服务（`:53-83`）的依赖里有一行关键约束（`:75-76`）：

```yaml
depends_on:
  ...
  migrate:
    condition: service_completed_successfully
```

`service_completed_successfully` 表示 server 要等 migrate 容器以**退出码 0** 结束后才启动。这样保证：

- migration 全部成功 → server 才起，启动时表结构已就绪
- migration 失败（非 0 退出）→ server **不会启动**，避免 server 查不到表导致 500

> 排查提示：若 `docker compose up -d` 后 server 迟迟没起，先看 `docker compose logs migrate`——正常应看到 "migrate up" 完成并 `Exited 0`；若 migrate 报错退出，server 会被依赖条件阻塞。详见 §17。

---

## 4. 创建用户（重要）

**Wanling 没有开放公开注册 API**，必须用 admin-tool 加用户：

```bash
# Linux / macOS / Windows PowerShell（都直接跑，PowerShell 不做路径转换）
docker compose run --rm --entrypoint /app/wanling-admin server add-user --username=alice --password=secret123
```

```bash
# Windows Git Bash 必须加 MSYS_NO_PATHCONV=1，否则 /app/wanling-admin 会被转换成 Windows 路径破坏执行
MSYS_NO_PATHCONV=1 docker compose run --rm \
    --entrypoint /app/wanling-admin server add-user --username=alice --password=secret123
```

**怎么判断你在用哪个 shell？**

- 提示符 `$` 或 `%` → Linux/macOS/zsh/bash → 用上面那条
- 提示符 `PS D:\>` → PowerShell → **用上面那条**（不需要 MSYS_NO_PATHCONV）
- 提示符包含 `MINGW64` 或在 Git Bash 窗口 → Git Bash → 用下面那条

admin-tool 子命令：

- `add-user --username=<name> [--password=<pwd>]`：创建用户
- `reset-password --username=<name>`：重置密码
- `list-users`：列出所有用户

---

## 5. 验证

```bash
docker compose ps                # postgres / redis / server 应 healthy；migrate 应 Exited (0)
curl http://localhost:18008/health   # 进程存活, 返 {"status":"ok"}（不验依赖）
curl http://localhost:18008/ready    # 依赖就绪, 返 {"status":"ready"}（验 DB+Redis 连通）
```

`docker compose ps` 预期：

| 服务 | 状态 |
|---|---|
| `postgres` | `Up (healthy)` |
| `redis` | `Up (healthy)` |
| `migrate` | `Exited (0)`（one-shot，正常） |
| `server` | `Up (healthy)` |

> `/health` 适合 load balancer 判断进程在不在；`/ready` 适合判断「能不能服务」（DB 挂了 `/ready` 返 503，触发容器重启）。`server` 的 healthcheck 用的就是 `/health`（`docker-compose.example.yml:78`）。

---

## 6. dev / prod 切换

改 `.env` 里 `COMPOSE_FILE` 那一行（注释一行，取消注释另一行）：

```ini
# prod 模式（默认）
COMPOSE_FILE=docker-compose.yml:docker-compose.prod.yml
# COMPOSE_FILE=docker-compose.yml:docker-compose.dev.yml

# dev 模式（注释上一行，取消注释这行）
# COMPOSE_FILE=docker-compose.yml:docker-compose.prod.yml
COMPOSE_FILE=docker-compose.yml:docker-compose.dev.yml
```

切换后：

```bash
docker compose down             # 停当前模式
docker compose up -d            # 起新模式
```

---

## 7. 端口自定义（host 暴露端口）

host 上已有服务占用某个端口时（比如 18008 被其他服务占了），改 `.env` 的端口变量即可：

```ini
# .env
SERVER_HOST_PORT=18009       # server 暴露到 host 的端口（默认 18008）
DB_HOST_PORT=6334            # dev 模式 PG 暴露到 host 的端口（默认 6333）
REDIS_HOST_PORT=6380         # dev 模式 Redis 暴露到 host 的端口（默认 6379）
```

**只改 host 端口，容器内端口固定**（server 18008 / PG 5432 / Redis 6379），所以 server 连 PG/Redis 的内部配置不受影响。

prod 模式不暴露 PG/Redis，只有 `SERVER_HOST_PORT` 生效。

---

## 8. 本地自定义（不污染上游模板）

如果你想加自己的服务 / 改日志驱动 / 改端口绑定，**直接编辑你拷贝出来的 `docker-compose.prod.yml` 或 `docker-compose.dev.yml`**。这些文件已被 gitignore，不会被 `git pull` 覆盖，也不会污染上游模板。

如果上游模板更新了（比如 PG 升级到 17），你只需要：

```bash
# 看上游模板的改动
git diff HEAD~1 -- docker-compose.prod.example.yml

# 手动 merge 到你自己的 docker-compose.prod.yml（或者直接重新拷贝再应用你的改动）
```

---

## 9. DB 密码修改陷阱

postgres 官方镜像只在**首次初始化**时读 `POSTGRES_PASSWORD`。之后改 `.env` 不会同步到 PG。正确流程：

```bash
# 1. 先在 PG 改密码
docker compose exec postgres \
  psql -U wanling -d wanling -c "ALTER USER wanling PASSWORD 'new_password'"

# 2. 改 .env 的 POSTGRES_PASSWORD 为新值

# 3. 重建容器让 server / migrate 读到新密码
docker compose up -d --force-recreate server migrate
```

---

## 10. 升级

```bash
git pull
docker compose build            # 重新 build 镜像（如有 Dockerfile / 源码改动）
docker compose up -d            # migrate one-shot 会自动跑新 migrations（机制见 §3.1）
```

> 升级后若 server 没起，先查 `docker compose logs migrate` 是否报错（migration 失败会阻塞 server，见 §3.1 第 3 步）。

---

## 11. 开发模式（dev）

dev 模式启用 air 热重载 + 暴露调试端口。切换方式见 §6（改 `.env` 的 `COMPOSE_FILE` 指向 `docker-compose.dev.yml`）。

跟 prod 的差异：

| 维度 | prod | dev |
|---|---|---|
| server 镜像 | prod Dockerfile（multi-stage，小镜像） | dev Dockerfile（含 air，大镜像） |
| 数据持久化 | named volume（隔离） | bind mount `./data/`（可查看） |
| 端口暴露 | `0.0.0.0:18008` | 加 `0.0.0.0:6333`（PG）+ `0.0.0.0:6379`（Redis） |
| 热重载 | 无 | 改 `.go` 文件 air 自动重建 |

**Windows 用户注意**：dev 模式的 air 已配置 `poll = true`（轮询模式），因为 Docker Desktop on Windows 的 bind mount 不向容器内 inotify 转发文件事件，默认的 fsnotify 监听不触发。Linux / macOS 用户也兼容（poll 模式跨平台工作）。

直连 PG（调试用）：`psql -h localhost -p 6333 -U wanling -d wanling`（密码看 `.env`）。
直连 Redis（调试用）：`redis-cli -h localhost -p 6379`。

### 11.1 文件存储路径

容器内 server 固定用 `STORAGE_PATH=/app/uploads`（由 compose 注入，无需手动配）。区别在 volume 映射：

| 模式 | 容器内路径 | host 映射 |
|---|---|---|
| prod | `/app/uploads` | named volume `uploads`（由 docker 管理，`docker volume inspect wanling_uploads` 看位置） |
| dev | `/app/uploads` | bind mount `./data/uploads`（直接在仓库目录可见） |

prod 的 uploads 备份见 §14。

> 对象存储扩展（MinIO / S3）：`server/internal/storage/` 预留了 `FileStorage` 接口（参考 `local_storage.go` 实现），切换时实现接口并在 `cmd/main.go` 替换注入即可，无需改 handler / repository 层。当前部署默认用本地存储。

### 11.2 dev uploads 权限提示

dev 容器以 root 跑，bind mount `./data/uploads` 里 host 上看文件 owner 是 `root:root`。host 普通用户读写需要 sudo（`sudo ls data/uploads`）。如希望 host 普通用户能直接读写，在 dev override 加 `user: "${UID}:${GID}"` 让容器 uid 匹配 host 用户（高级用法，不推荐）。

---

## 12. Nginx 反向代理

生产环境强烈建议前置 nginx 做 TLS 终止 + WebSocket 升级。

仓库提供现成模板（[`deploy/nginx/`](../deploy/nginx/)）：

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

> 走 nginx 反代时，compose 只需暴露 `SERVER_HOST_PORT` 给 nginx 所在 host 访问，不必对公网开 18008。

> **多域名 WS 放行**：若同一 server 实例被多个域名访问（如 `chat.example.com` + `chat2.example.com`），WS 握手的 Origin 校验需在 `.env` 配 `WS_ALLOWED_ORIGINS=https://chat.example.com,https://chat2.example.com`（逗号分隔），否则非主域名的 WS 连接会被拒。单域名场景留空走同源校验即可。

---

## 13. APP 构建

APP 构建与 server 部署路线无关，Flutter >= 3.44。**仅 Android 发布**（Linux desktop / iOS 不做支持，相关构建章节已移除）。

### 13.1 Android APK

```bash
PUB_HOSTED_URL=https://pub.flutter-io.cn \
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
flutter build apk --release --flavor prod

# 输出：build/app/outputs/flutter-apk/app-prod-release.apk
```

### 13.2 Android 运行时配置要点

APK 构建命令本身没特殊，但要让 APP 真正在 Android 上跑起来（后台收消息、上传头像、发通知），需确认 `android/app/src/main/AndroidManifest.xml` 含以下权限与服务声明：

```xml
<!-- 网络访问 -->
<uses-permission android:name="android.permission.INTERNET" />
<!-- 后台服务保活 WS 连接 -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
<!-- 通知（Android 13+ 需运行时申请 POST_NOTIFICATIONS） -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<!-- 头像选图 + 聊天相册（wechat_assets_picker） -->
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
    android:maxSdkVersion="32" />
<!-- 拍照（wechat_camera_picker） -->
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

**固定竖屏**：`MainActivity` 的 `<activity>` 标签加 `android:screenOrientation="portrait"`。APP 走 IM 风单栏布局，不支持横屏旋转。

> **明文 HTTP 允许**：APP 默认连 `http://localhost:18008` 或自定义服务器地址。若服务端未上 TLS，需在 `android/app/src/main/res/xml/network_security_config.xml` 配置 `cleartextTrafficPermitted`，并在 manifest 引用 `android:networkSecurityConfig="@xml/network_security_config"`。生产环境强烈建议服务端上 TLS（见 §12）。

---

## 14. 备份和恢复

### 14.1 数据库逻辑备份

```bash
docker compose exec postgres pg_dump -U wanling wanling | gzip > \
    backups/wanling_$(date +%Y%m%d).sql.gz
```

### 14.2 文件备份（uploads volume）

prod 模式 uploads 在 named volume `uploads`：

```bash
docker run --rm -v $(pwd):/backup -v wanling_uploads:/data alpine \
    tar czf /backup/uploads_$(date +%Y%m%d).tar.gz -C /data .
```

### 14.3 数据库恢复

```bash
gunzip -c backups/wanling_20260622.sql.gz | \
    docker compose exec -T postgres psql -U wanling -d wanling
```

### 14.4 定期清理未引用文件

```bash
# 清理 90 天前的未引用文件
docker compose exec server find /app/uploads -type f -mtime +90 -delete
```

### 14.5 Cron（建议每天凌晨备份）

假设 compose 文件在 `/opt/wanling/`：

```cron
# 每天 03:00 备份数据库
0 3 * * * cd /opt/wanling && docker compose exec -T postgres pg_dump -U wanling wanling | gzip > /opt/wanling/backups/wanling_$(date +\%Y\%m\%d).sql.gz
# 每天 05:00 清理 30 天前的备份
0 5 * * * find /opt/wanling/backups/ -name '*.sql.gz' -mtime +30 -delete
```

---

## 15. 监控

### 15.1 关键指标

| 指标 | 来源 / 命令 | 告警阈值 |
|------|------|---------|
| 服务端是否存活 | `docker compose ps`（看 server 是否 healthy） | 非 healthy |
| WebSocket 连接数 | Hub `sync.Map` Range 计数（需自接指标） | 突降 50% |
| PG 连接数 | `docker compose exec postgres psql -U wanling -c "SELECT count(*) FROM pg_stat_activity"` | > 100 |
| 磁盘（uploads volume） | `docker compose exec server df -h /app/uploads` | > 80% |
| Gateway 连接状态 | `hermes gateway status`（hermes 侧，路线无关） | disconnected |

### 15.2 日志

```bash
docker compose logs -f server                              # 跟踪 server 日志
docker compose logs --tail=100 server | grep -i error      # 看最近 100 行里的 error
docker compose logs migrate                                # 看 migration 是否正常退出
```

> **Access log 降噪**：服务端用自定义 `handler.BusinessAccessLog()` 中间件（`server/internal/handler/access_log.go`），只记录命中注册路由的请求。扫描器探测的 NoRoute 404（`/mcp`、`/actuator/health`、`/HNAP1` 等）**完全静默**，不污染 docker logs。判定用 gin 的 `c.FullPath()`（命中 NoRoute 返回空串）。file_handler 的错误都用 `log.Printf` 带 `[upload]`/`[download]` 前缀打 stderr，可用 `docker compose logs server | grep -E "\[upload\]|\[download\]"` 过滤。

---

## 16. 安全清单

- [ ] `JWT_SECRET` 使用 `openssl rand -hex 32` 生成，非默认值
- [ ] `POSTGRES_PASSWORD` 强度 >= 16 位随机（注意首启后改密码需走 §9 流程）
- [ ] Nginx 开启 TLS 1.2+，禁用 TLS 1.0/1.1
- [ ] 防火墙仅放通 443（Nginx）；18008 不对公网暴露（走反代，见 §12）
- [ ] `CORS_ALLOWED_ORIGINS` 限制为具体域名（生产环境不要留 `*`）
- [ ] 多域名访问场景配 `WS_ALLOWED_ORIGINS`（逗号分隔白名单，单域名留空）
- [ ] Agent `secret_key` 仅通过安全渠道传输（不在日志 / commit 中泄露）
- [ ] hermes 插件 `WANLING_ALLOW_ALL_USERS` 生产环境关闭，改用 `WANLING_ALLOWED_USERS`
- [ ] `.env` 文件权限 `600`（`chmod 600 .env`）
- [ ] 定期 `apt upgrade` / `yum update` 系统补丁 + 重建镜像（`docker compose build --pull`）

---

## 17. 故障排查

| 症状 | 检查项 |
|------|--------|
| 客户端连不上 | `docker compose ps`（server 是否 healthy）；host 上 `ss -tlnp \| grep <SERVER_HOST_PORT>` |
| `docker compose up -d` 后 server 迟迟不起 | `docker compose logs migrate`——migrate 报错退出（非 0）会因 `service_completed_successfully` 阻塞 server（机制见 §3.1） |
| 登录失败 | PG 是否可达：`docker compose exec postgres psql -U wanling -c "SELECT 1"` |
| WS 连接断开 | `docker compose logs server \| grep -i error` |
| Agent 不在线 | Gateway 状态：`hermes gateway status`、检查 `~/.hermes/logs/gateway.log` |
| 图片不加载 | uploads volume 权限 / 磁盘空间（`docker compose exec server df -h /app/uploads`）/ Nginx body size 限制 |
| 首次启动报错 DB 连接 | `.env` 中 `POSTGRES_*` 是否填对；`docker compose logs postgres` 看 PG 是否起来 |
| migrate 卡住不退出 | `docker compose logs migrate`（正常应 `Exited 0`）；migrate 失败会阻塞 server 启动 |
| 改了 `.env` 的 `POSTGRES_PASSWORD` 不生效 | postgres 官方镜像首启后才认密码，需走 §9 的 `ALTER USER` 流程 |
| Android APP 后台收不到通知 | 系统设置 → 应用 → 电池优化（加入白名单）、通知权限是否授予、`foregroundServiceType` 是否声明 |
| Android 杀掉重启后登录态丢失 | 检查 `flutter_secure_storage` 是否被系统清理；Android 13+ 需 `POST_NOTIFICATIONS` 运行时申请 |
| Android 头像选图崩溃 | `wechat_assets_picker` + `crop_your_image` 已绕开 ActivityResult，旧版本仍崩溃需升级到最新 commit |
| APK 构建报 Kotlin 版本冲突 | `wechat_camera_picker` 间接拉 `sensors_plus 7.x`（需 Kotlin 2.2），项目 Built-in Kotlin 为 2.0。`pubspec.yaml` 的 `dependency_overrides` 已固定 `sensors_plus: ^6.1.1`，若仍报错检查 override 是否生效 |
| Docker dev 模式改代码后 air 不重建 | Windows + Docker Desktop 已配置 `poll = true`；Linux/Mac 检查 `.air.toml` 是否被 bind mount 进容器 |
| admin-tool 命令报路径错（Windows Git Bash） | 加 `MSYS_NO_PATHCONV=1` 前缀；或直接用 PowerShell（见 §4） |
