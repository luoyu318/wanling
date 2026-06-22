# Wanling 生产部署发布文档

## 系统架构

```
用户 APP (Flutter, Linux/Android/iOS)
    ↕ WebSocket + HTTP REST (JWT 鉴权)
Nginx/Caddy (反向代理, TLS 终止)
    ↕
Go 服务端 (:18008)
    ↕ WebSocket (JWT: role=agent)
Hermes Gateway + Wanling Plugin (每个 agent 一个进程)
    ↕
AI 平台 (Hermes Agent)
```

依赖：PostgreSQL（消息/用户/Agent 持久化）+ Redis（在线状态）

---

## 1. 环境要求

| 组件 | 版本要求 |
|------|---------|
| Go | >= 1.21 |
| Flutter | >= 3.44 |
| PostgreSQL | >= 15 |
| Redis | >= 7 |
| Python (Hermes) | >= 3.11 |
| Docker (可选) | >= 24 |

---

## 1.5 Docker Compose 一键部署（推荐）

> **适用场景**：快速部署、不想手动配 systemd / nginx、单机部署。
> **不适用**：需要 k8s 编排、多副本、跨机扩展。

### 前置条件

- Docker Engine >= 24
- Docker Compose v2 >= 2.20
- 服务器外网防火墙：默认开放 80/443（如要前置 nginx），按需开放 18008（如不走反代）

### 一键启动（prod）

仓库提供 3 个模板文件（入 git）：
- `docker-compose.example.yml`（base 配置）
- `docker-compose.prod.example.yml`（prod override）
- `docker-compose.dev.example.yml`（dev override）

用户拷贝成实际文件（gitignored），改了不会跟上游冲突：

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

首次启动会自动 build 镜像（耗时 3-5 分钟）。启动完成后：

```bash
docker compose ps                # 看 4 个服务都 healthy
curl http://localhost:18008/health   # 验证 server
```

### 切换 dev / prod

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

### 创建用户（重要）

**Wanling 没有开放公开注册 API**，必须用 admin-tool 加用户：

```bash
# Linux / macOS / Windows PowerShell（都直接跑，PowerShell 不做路径转换）
docker compose run --rm --entrypoint /app/wanling-admin server add-user --username=alice --password=secret123
```

```bash
# Windows Git Bash 必须加 MSYS_NO_PATHCONV=1，否则 /app/wanling-admin 会被转换成 Windows 路径破坏执行
MSYS_NO_PATHCONV=1 docker compose run --rm --entrypoint /app/wanling-admin server add-user --username=alice --password=secret123
```

**怎么判断你在用哪个 shell？**
- 提示符 `$` 或 `%` → Linux/macOS/zsh/bash → 用上面那条
- 提示符 `PS D:\>` → PowerShell → **用上面那条**（不需要 MSYS_NO_PATHCONV）
- 提示符包含 `MINGW64` 或在 Git Bash 窗口 → Git Bash → 用下面那条

admin-tool 子命令：
- `add-user --username=<name> [--password=<pwd>]`：创建用户
- `reset-password --username=<name>`：重置密码
- `list-users`：列出所有用户

### 本地自定义（不污染上游模板）

如果你想加自己的服务 / 改日志驱动 / 改端口绑定，**直接编辑你拷贝出来的 `docker-compose.prod.yml` 或 `docker-compose.dev.yml`**。这些文件已被 gitignore，不会被 `git pull` 覆盖，也不会污染上游模板。

如果上游模板更新了（比如 PG 升级到 17），你只需要：
```bash
# 看上游模板的改动
git diff HEAD~1 -- docker-compose.prod.example.yml

# 手动 merge 到你自己的 docker-compose.prod.yml（或者直接重新拷贝再应用你的改动）
```

### 端口自定义（host 暴露端口）

host 上已有服务占用某个端口时（比如 18008 被其他服务占了），改 `.env` 的端口变量即可：

```ini
# .env
SERVER_HOST_PORT=18009       # server 暴露到 host 的端口（默认 18008）
DB_HOST_PORT=6334            # dev 模式 PG 暴露到 host 的端口（默认 6333）
REDIS_HOST_PORT=6380         # dev 模式 Redis 暴露到 host 的端口（默认 6379）
```

改完跑：
```bash
docker compose down
docker compose up -d
```

**只改 host 端口，容器内端口固定**（server 18008 / PG 5432 / Redis 6379），所以 server 连 PG/Redis 的内部配置不受影响。

prod 模式不暴露 PG/Redis，只 `SERVER_HOST_PORT` 生效。

### 可选：挂 nginx 反代 + TLS

见 [`deploy/nginx/README.md`](../deploy/nginx/README.md)。compose 不内置反代，由用户决定是否使用、用什么。

### 日常运维

| 操作 | 命令 |
|---|---|
| 看服务状态 | `docker compose ps` |
| 看实时日志 | `docker compose logs -f server` |
| 重启 server | `docker compose restart server` |
| 停服（保数据） | `docker compose down` |
| 停服 + 删数据 | `docker compose down -v` |
| 调用 admin-tool | 见上一节"创建用户" |
| 升级 | `git pull && docker compose build && docker compose up -d` |

### DB 密码修改陷阱

postgres 官方镜像只在**首次初始化**时读 `POSTGRES_PASSWORD`。之后改 `.env` 不会同步到 PG。正确流程：

```bash
# 1. 先在 PG 改密码
docker compose exec postgres \
  psql -U wanling -d wanling -c "ALTER USER wanling PASSWORD 'new_password'"

# 2. 改 .env 的 POSTGRES_PASSWORD 为新值

# 3. 重建容器让 server / migrate 读到新密码
docker compose up -d --force-recreate server migrate
```

### 备份 / 恢复

```bash
# PG 逻辑备份（建议每天 cron）
docker compose exec postgres \
  pg_dump -U wanling wanling | gzip > backups/wanling_$(date +%Y%m%d).sql.gz

# uploads 物理备份
docker run --rm -v $(pwd):/backup -v wanling_uploads:/data alpine \
  tar czf /backup/uploads_$(date +%Y%m%d).tar.gz -C /data .

# PG 恢复
gunzip -c backups/wanling_20260622.sql.gz | \
  docker compose exec -T postgres psql -U wanling -d wanling
```

### 开发模式（dev）

dev 模式启用 air 热重载 + 暴露调试端口。

跟 prod 的差异：

| 维度 | prod | dev |
|---|---|---|
| server 镜像 | prod Dockerfile（multi-stage，小镜像） | dev Dockerfile（含 air，大镜像） |
| 数据持久化 | named volume（隔离） | bind mount `./data/`（可查看） |
| 端口暴露 | `0.0.0.0:18008` | 加 `0.0.0.0:6333`（PG）+ `0.0.0.0:6379`（Redis） |
| 热重载 | 无 | 改 `.go` 文件 air 自动重建 |

**Windows 用户注意**：dev 模式的 air 已配置 `poll = true`（轮询模式），因为 Docker Desktop on Windows 的 bind mount 不向容器内 inotify 转发文件事件，默认的 fsnotify 监听不触发。Linux / macOS 用户也兼容（poll 模式跨平台工作）。

直连 PG：`psql -h localhost -p 6333 -U wanling -d wanling`（密码看 `.env`）。
直连 Redis：`redis-cli -h localhost -p 6379`。

**dev uploads 权限提示**：dev 容器以 root 跑，bind mount `./data/uploads` 里 host 上看文件 owner 是 `root:root`。host 普通用户读写需要 sudo（`sudo ls data/uploads`）。如希望 host 普通用户能直接读写，在 dev override 加 `user: "${UID}:${GID}"` 让容器 uid 匹配 host 用户（高级用法，不推荐）。

---

## 2. 数据库初始化

### 2.1 创建 PostgreSQL 数据库

```sql
CREATE USER agent WITH PASSWORD '<strong-password>';
CREATE DATABASE wanling OWNER agent;
```

### 2.2 运行迁移

```bash
# 一键执行全部 migration
for m in server/migrations/00{1,2,3,4,5,6,7}_*.sql; do
  psql -U agent -d wanling -h localhost -f "$m"
done
```

或用 `scripts/init_db.sh` 一键执行。

migration 清表：
- `001_init.sql` — 基础表（users / agents / conversations / messages / files）
- `002_conversation_last_message.sql` — `conversations.last_message_content` JSONB 缓存
- `003_unread_count.sql` — `conversations.unread_count` + `messages.is_read`（已读回执）
- `004_pin_hide.sql` — `conversations.hidden_at` + `conversations.pinned_at`（置顶 + 软删除）
- `005_profile_fields.sql` — `users.nickname` + `users.bio` + `agents.bio`（个人资料扩展）
- `006_message_soft_delete.sql` — `messages.deleted_at`（软删除）+ 部分索引 `idx_messages_conv_not_deleted`
- `007_pairing_tickets.sql` — `pairing_tickets` 扫码配对票据表（非业务表，仅握手用，5min TTL）

### 2.3 启动 Redis

```bash
# Docker
docker run -d --name agent-redis -p 6379:6379 redis:7-alpine

# 或 systemd
systemctl enable --now redis
```

---

## 3. 服务端部署

### 3.1 配置环境变量

复制 `.env.example` 为 `.env`，修改必填项：

```bash
cp server/.env.example server/.env
```

```ini
SERVER_PORT=18008
DB_HOST=localhost
DB_PORT=5432
DB_USER=agent
DB_PASSWORD=<your-db-password>
DB_NAME=wanling
DB_SSLMODE=disable       # 生产环境与 PG 同机部署可 disable

REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=
REDIS_DB=0

JWT_SECRET=<generate-with-openssl-rand-hex-32>
STORAGE_PATH=/usr/local/wanling/uploads
CORS_ALLOWED_ORIGINS=*   # 生产环境限制为具体域名
```

生成 JWT 密钥：

```bash
openssl rand -hex 32
```

### 3.2 创建目录结构

```bash
sudo mkdir -p /usr/local/wanling/{bin,etc,uploads,backups}
```

### 3.3 编译二进制

```bash
cd server
CGO_ENABLED=0 go build -ldflags="-s -w" -o /usr/local/wanling/bin/wanling-server ./cmd/main.go
```

### 3.4 Systemd 服务

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
sudo useradd -r -s /bin/false wanling
sudo cp server/.env /usr/local/wanling/etc/
sudo chown -R wanling:wanling /usr/local/wanling
sudo systemctl daemon-reload
sudo systemctl enable --now wanling-server
```

### 3.5 健康检查

```bash
curl http://localhost:18008/api/auth/login  # 应返回 JSON（非 502）
```

### 3.6 扫码配对（hermes 插件接入）

hermes 终端通过扫码授权连接 Agent，无需手动复制 agent_id/secret_key，也无需粘 user token。

**hermes 端用法**（详见 [plugin/README.md](../plugin/README.md)）：

```bash
# 远程一键（推荐）
curl -fsSL https://gitee.com/luoyu318/wanling-plugin/raw/main/install-remote.sh | \
  bash -s -- --pair --server=https://your.server.com

# 本地已 clone 镜像 repo
./install.sh --pair --server=https://your.server.com
```

**运维要点**：
- 票据表 `pairing_tickets` 自动清理：server 启动时起后台 goroutine，每 10 分钟删 1 小时前的记录（`internal/pair/cleanup.go`）。**无需手动维护**。
- 限流：`GET /api/pair/tickets/:id` 按 IP 60/min（防 ticket_id 枚举）；`POST /complete` 按 user 10/min。Redis 可用时走 Redis，否则内存降级（`internal/ratelimit/`）。
- 凭据领完即焚：hermes 端第一次 GET completed 拿到 `secret_key` 后，server 立即清空该字段。同 ticket 再查只返 `{status:"completed"}` 不带凭据。
- 排查："配对码已失效"= ticket 过期或已被领过，让用户重新跑 `--pair`。

---

## 4. APP 构建发布

### 4.1 Linux Desktop

```bash
cd app
PUB_HOSTED_URL=https://pub.flutter-io.cn \
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
flutter build linux --release

# 输出：app/build/linux/x64/release/bundle/
```

分发方式：
- **tar.gz 打包**：`tar -czf wanling-linux-amd64.tar.gz -C build/linux/x64/release/bundle .`
- **AppImage / deb / rpm**：按需配置 `linux/packaging/` 目录

### 4.2 Android APK

```bash
PUB_HOSTED_URL=https://pub.flutter-io.cn \
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
flutter build apk --release

# 输出：build/app/outputs/flutter-apk/app-release.apk
```

### 4.3 iOS（需 macOS + Xcode）

```bash
PUB_HOSTED_URL=https://pub.flutter-io.cn \
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
flutter build ios --release
```

用 Xcode Archive + TestFlight / App Store 分发。

### 4.4 Android 运行时配置要点

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

**iOS**（`ios/Runner/Info.plist`）需补相机/相册用途描述，否则审核被拒：

```xml
<key>NSCameraUsageDescription</key>
<string>用于拍照发送</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>用于从相册选择图片发送</string>
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

**固定竖屏**：`MainActivity` 的 `<activity>` 标签加 `android:screenOrientation="portrait"`，iOS 的 `Info.plist` 把 `UISupportedInterfaceOrientations`（含 `~ipad`）限定为仅 `UIInterfaceOrientationPortrait`。APP 走 IM 风单栏布局，不支持横屏旋转。

> **明文 HTTP 允许**：APP 默认连 `http://localhost:18008` 或自定义服务器地址。若服务端未上 TLS，需在 `android/app/src/main/res/xml/network_security_config.xml` 配置 `cleartextTrafficPermitted`，并在 manifest 引用 `android:networkSecurityConfig="@xml/network_security_config"`。生产环境强烈建议服务端上 TLS（见第 5 节 Nginx）。

---

## 5. Nginx 反向代理

`/etc/nginx/sites-available/wanling`：

```nginx
server {
    listen 443 ssl http2;
    server_name chat.example.com;

    ssl_certificate     /etc/ssl/chat.example.com.pem;
    ssl_certificate_key /etc/ssl/chat.example.com.key;

    # WebSocket uprade
    location /ws {
        proxy_pass http://127.0.0.1:18008;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # HTTP API
    location / {
        proxy_pass http://127.0.0.1:18008;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

启用：

```bash
sudo ln -s /etc/nginx/sites-available/wanling /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

**APP 端配置**：用户输入 `https://chat.example.com` 作为服务器地址。

---

## 6. Hermes Plugin 部署

> **插件分发**：插件源码在主库 `plugin/` 下，公开镜像在 `gitee.com/luoyu318/wanling-plugin`。
> 第三方用户**无需访问主库**，用一键安装命令即可。改完主库插件后，跑
> `PUBLISH_REPO_DIR=<镜像 repo 路径> ./scripts/publish-plugin.sh` 同步到镜像 repo。

### 6.1 前置条件

- Hermes Agent 已安装（`hermes --version`）
- Wanling 服务端已有 Agent 账号（`agent_id` + `secret_key`）

### 6.2 安装插件（单个 Agent）

**推荐：一键安装（第三方用户，无需主库权限）**

```bash
# 交互式安装（已有 agent_id 和 secret_key）
curl -fsSL https://gitee.com/luoyu318/wanling-plugin/raw/main/install-remote.sh | bash

# 或参数式安装
curl -fsSL https://gitee.com/luoyu318/wanling-plugin/raw/main/install-remote.sh | \
  bash -s -- --server=https://chat.example.com --agent-id=<uuid> --secret-key=<key>

# 或一键注册新 Agent + 安装插件
curl -fsSL https://gitee.com/luoyu318/wanling-plugin/raw/main/install-remote.sh | \
  bash -s -- --register --server=https://chat.example.com \
    --user-token=<user-jwt> --agent-name="我的 Agent"
```

**内部开发：从主库源码安装**

```bash
cd plugin/hermes-plugin && ./install.sh
# 多 profile 场景见 plugin/install-remote.sh --help（--profile / --update / --config）
```

插件安装到 `~/.hermes/plugins/wanling/`，配置写入 `~/.hermes/.env` 和 `~/.hermes/config.yaml`。
install.sh 用 marker 包裹 .env 的 wanling 段（`# >>> wanling-plugin >>>` / `<<<`），清理时按 marker 删，不碰用户其他配置。

### 6.3 启动 Gateway

```bash
# systemd user 模式
systemctl --user restart hermes-gateway

# 或前台运行
hermes gateway start
```

验证：

```bash
hermes gateway status              # 看 wanling 是否 connected
tail -f ~/.hermes/logs/gateway.log # 看连接日志
```

### 6.4 多 Agent 部署

Hermes 单进程只支持一个 Wanling agent。多 Agent 需要多 Profile —— 每个 Profile 独立运行一个 Gateway 进程。

#### Step 1: 创建 Agent

在 Wanling APP 或 API 上创建新 Agent：

```bash
curl -X POST https://chat.example.com/api/agents \
  -H "Authorization: Bearer <user-jwt>" \
  -H "Content-Type: application/json" \
  -d '{"name":"Agent 名称"}'
```

返回 `id`（agent_id）和 `secret_key`。

#### Step 2: 创建 Profile

```bash
# 创建 profile 目录
mkdir -p ~/.hermes/profiles/<profile-name>/{plugins,logs,cron}

# 复制基础配置（可选，从主 profile 拷或手动写）
cp ~/.hermes/config.yaml ~/.hermes/profiles/<profile-name>/

# 修改 config.yaml：
#   model: 改成目标模型
#   plugins.enabled: [wanling-platform]
#   加 wanling 段：
#     wanling:
#       enabled: true
#       extra:
#         server_url: https://chat.example.com
#         agent_id: <新-agent-uuid>
#         secret_key: <新-agent-secret-key>
#         home_user: <user-id>

# 复制插件
cp -r ~/.hermes/plugins/wanling ~/.hermes/profiles/<profile-name>/plugins/wanling

# 配置 .env
cat >> ~/.hermes/profiles/<profile-name>/.env <<'EOF'
WANLING_SERVER_URL=https://chat.example.com
WANLING_AGENT_ID=<新-agent-uuid>
WANLING_SECRET_KEY=<新-agent-secret-key>
WANLING_HOME_USER=<user-id>
WANLING_ALLOW_ALL_USERS=true
EOF
```

#### Step 3: 启动第二个 Gateway

```bash
HERMES_HOME=~/.hermes/profiles/<profile-name> hermes gateway start
```

**生产环境推荐**：每个 Profile 一个 systemd user service：

`~/.config/systemd/user/hermes-gateway-<profile-name>.service`：

```ini
[Unit]
Description=Hermes Gateway - <profile-name>

[Service]
Type=simple
Environment=HERMES_HOME=%h/.hermes/profiles/<profile-name>
ExecStart=%h/.hermes/hermes-agent/hermes_cli/main.py gateway run
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
```

启用：

```bash
systemctl --user enable --now hermes-gateway-<profile-name>
```

### 6.5 生产环境安全检查

```ini
# 关闭全用户允许，改为白名单
# 删除：WANLING_ALLOW_ALL_USERS=true
# 添加：
WANLING_ALLOWED_USERS=<user-id-1>,<user-id-2>
```

---

## 7. 文件存储

默认使用本地存储（`STORAGE_PATH=/usr/local/wanling/uploads`）。

### 对象存储扩展（MinIO / S3）

`server/internal/storage/` 预留了 MinIO 接口。切换方式：

1. 实现 `FileStorage` 接口（参考 `local_storage.go`）
2. 在 `cmd/main.go` 中替换注入的 storage 实现
3. 无需改 handler / repository 层

### 定期清理

```bash
# 清理 90 天前的未引用文件（示例）
find /usr/local/wanling/uploads -type f -mtime +90 -delete
```

---

## 8. 备份

### 数据库

```bash
# 每日全量备份
pg_dump -U agent -d wanling | gzip > /usr/local/wanling/backups/wanling_$(date +%Y%m%d).sql.gz
```

### 文件

```bash
rsync -av /usr/local/wanling/uploads/ backup.example.com:/backups/wanling/
```

### Cron

```cron
0 3 * * * pg_dump -U agent -d wanling | gzip > /usr/local/wanling/backups/wanling_$(date +\%Y\%m\%d).sql.gz
0 4 * * * rsync -av /usr/local/wanling/uploads/ /backup/files/
0 5 * * * find /usr/local/wanling/backups/ -name '*.sql.gz' -mtime +30 -delete
```

---

## 9. 监控

### 关键指标

| 指标 | 来源 | 告警阈值 |
|------|------|---------|
| 服务端是否存活 | `systemctl is-active wanling-server` | 非 active |
| WebSocket 连接数 | Hub `sync.Map` Range 计数 | 突降 50% |
| PG 连接数 | `pg_stat_activity` | > 100 |
| 磁盘 /usr/local/wanling/uploads | `df -h` | > 80% |
| Gateway 连接状态 | `hermes gateway status` | disconnected |

### 日志

```bash
# 服务端：systemd journal
journalctl -u wanling-server -f

# Gateway：Hermes 日志目录
tail -f ~/.hermes/logs/gateway.log
tail -f ~/.hermes/profiles/<name>/logs/gateway.log
```

> **Access log 降噪**：服务端用自定义 `handler.BusinessAccessLog()` 中间件（`server/internal/handler/access_log.go`），
> 只记录命中注册路由的请求。扫描器探测的 NoRoute 404（`/mcp`、`/actuator/health`、`/HNAP1` 等）
> **完全静默**，不污染 journal。判定用 gin 的 `c.FullPath()`（命中 NoRoute 返回空串）。
> file_handler 的 5 处错误都用 `log.Printf` 带 `[upload]`/`[download]` 前缀打 stderr（被 journald 采集），
> 可用 `journalctl -u wanling-server | grep -E "\[upload\]|\[download\]"` 过滤。

---

## 10. 安全清单

- [ ] JWT_SECRET 使用 `openssl rand -hex 32` 生成，非默认值
- [ ] PostgreSQL 密码强度 >= 16 位随机
- [ ] Nginx 开启 TLS 1.2+，禁用 TLS 1.0/1.1
- [ ] 防火墙仅放通 443（Nginx），18008 仅监听 127.0.0.1
- [ ] CORS_ALLOWED_ORIGINS 限制为具体域名
- [ ] Agent secret_key 仅通过安全渠道传输（不在日志/commit 中泄露）
- [ ] `WANLING_ALLOW_ALL_USERS` 生产环境关闭，改用 `WANLING_ALLOWED_USERS`
- [ ] `.env` 文件权限 `600`，owner `wanling`
- [ ] 定期 `apt upgrade` / `yum update` 系统补丁

---

## 11. 回滚步骤

```bash
# 1. 停服
sudo systemctl stop wanling-server

# 2. 恢复数据库（如需）
psql -U agent -d wanling < /usr/local/wanling/backups/wanling_YYYYMMDD.sql

# 3. 切回旧二进制
sudo cp /usr/local/wanling/bin/wanling-server.prev /usr/local/wanling/bin/wanling-server

# 4. 启动
sudo systemctl start wanling-server
```

---

## 12. 故障排查

| 症状 | 检查项 |
|------|--------|
| 客户端连不上 | `systemctl status wanling-server`、`ss -tlnp \| grep 18008` |
| 登录失败 | PG 是否可达：`psql -U agent -d wanling -c "SELECT 1"` |
| WS 连接断开 | `journalctl -u wanling-server \| grep -i error` |
| Agent 不在线 | Gateway 状态：`hermes gateway status`、检查 `gateway.log` |
| 图片不加载 | `STORAGE_PATH` 权限、磁盘空间、Nginx body size 限制 |
| 首次启动报错 DB 连接 | `.env` 中 DB_* 配置是否正确、PG 是否监听对应端口 |
| Android APP 后台收不到通知 | 系统设置 → 应用 → 电池优化（加入白名单）、通知权限是否授予、`foregroundServiceType` 是否声明 |
| Android 杀掉重启后登录态丢失 | 检查 `flutter_secure_storage` 是否被系统清理；Android 13+ 需 POST_NOTIFICATIONS 运行时申请 |
| Android 头像选图崩溃 | `wechat_assets_picker` + `crop_your_image` 已绕开 ActivityResult，旧版本仍崩溃需升级到最新 commit |
| APK 构建报 Kotlin 版本冲突 | `wechat_camera_picker` 间接拉 `sensors_plus 7.x`（需 Kotlin 2.2），项目 Built-in Kotlin 为 2.0。`pubspec.yaml` 的 `dependency_overrides` 已固定 `sensors_plus: ^6.1.1`，若仍报错检查 override 是否生效 |
