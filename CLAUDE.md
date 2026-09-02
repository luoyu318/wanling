# CLAUDE.md

万灵（Wanling）— AI Agent 聊天系统。本文档是项目入口,详细架构按目录分到各子 CLAUDE.md。

## 项目身份

- wanling（万灵）AI Agent 聊天系统,类似主流 IM Bot 架构。用户通过 Flutter APP 与 Agent 实时对话,Agent 平台通过标准 WebSocket 接口接入。服务端仅做消息转发和用户/Agent 管理,不包含 Agent 适配层
- APP 端为动态底部 tab 结构（消息 / 万灵固定 + 可 pin 多会话 agent）,紧凑风格
- Go module: `github.com/wanling/server`
- Android applicationId: `com.wanling.app`
- 生产部署: `/usr/local/wanling/`,systemd 服务 `wanling-server`,PG 库 `wanling`

## 开发命令（入口）

- 服务端: `cd server && go run cmd/main.go`（监听 :18008,需先配置 server/.env）
- 服务端测试: `cd server && go test ./...`（用 testcontainers 起 PG 容器,需 docker）
- APP: `cd app && flutter run -d <device-id> --flavor dev`（`adb devices` 看 device-id）
- APP 测试: `cd app && flutter test`
- 本地开发配置：docs/local/
- **Harness 工程命令**:
  - `make help` — 列出所有目标
  - `make install-tools` — 一键装齐 lint/scan 工具（首次必跑）
  - `make install-hooks` — 配置 git hooks（clone 后必跑一次）
  - `make lint` — 三端 lint
  - `make typecheck` — 三端类型检查
  - `make test` — 三端测试（Go -race + Flutter + vitest）
  - `make secscan` — 安全扫描（gosec + semgrep + gitleaks）
  - `make check` — 全量检查（push 前一键跑）
- DB: `psql -U agent -d wanling -h localhost -p 6333`（或 `scripts/init_db.sh` 建库 + `cmd/migrate` 跑 migration）
- **详细 flag / 镜像 / Kotlin override / dependency_overrides 等注意事项见各子 CLAUDE.md**

## 顶层架构

```
APP（Flutter, Android）      ↔WebSocket+REST↔  Server（Go/Gin, :18008）  ↔WS（标准接口）↔  Plugin（hermes / opencode-plugin / dsh-wanling）
Desktop（Flutter, Linux 自用）  ↔REST+WS↘                    ↓
外部开发者通过 SDK 接入:SDK（sdk/,TS+Python 双语言,npm/PyPI `wanling-sdk`）    PostgreSQL（PG）
```

- APP 动态底栏 tab（消息/万灵固定 + pinned agent）,server 仅做转发+管理,不含 Agent 适配层
- agent 类型(hermes/opencode/dsh…)由 server 注册表统一下发(`agent_type_registry`,011):拓扑 multi_session 驱动路由,新类型 INSERT 一行即接入、APP 零发版
- skills/:agent 技能资产(小程序发布/发图等),独立安装(`skills/install.sh`),不随 plugin 分发
- 详细架构按目录分:
  - **改 Go 代码 → 读 [server/CLAUDE.md](./server/CLAUDE.md)**（路由 / Handler / Repo / migration 列表 / WS 协议 / 认证 / 测试规约）
  - **改 Flutter 代码 → 读 [app/CLAUDE.md](./app/CLAUDE.md)**（router / providers / pages / widgets / models / 测试规约）
  - **改桌面端 → 读 [desktop/README.md](./desktop/README.md)**（与 APP 复用 wanling_core,差异点清单）
  - **改 plugin（hermes / opencode）→ 读 [plugin/CLAUDE.md](./plugin/CLAUDE.md)**（分发 / install 模式 / adapter 协议 / streamer;dsh 桥在独立仓 dsh-wanling）
  - **改 SDK（TS / Python）→ 读 [sdk/CLAUDE.md](./sdk/CLAUDE.md)**（双语言传输层 / 协议常量 / 发布）

## 维护规则（改 X 看 Y）

| 改动类型 | 必读 |
|---|---|
| 新增 / 改 server 路由或 Handler | server/CLAUDE.md |
| 新增 / 改 Flutter page / provider / widget | app/CLAUDE.md |
| 新增 / 改插件 install 模式 / adapter 协议 | plugin/CLAUDE.md |
| 新增 / 改 skills/ 技能 | skills/README.md + 对应 SKILL.md |
| 新增 / 改 SDK 协议或方法 | sdk/CLAUDE.md + docs/architecture/sdk.md |
| 新增 migration | server/CLAUDE.md + docs/ai-handbook/migrations.md（被 server/CLAUDE.md @import） |
| 跨子系统协议变更（WS opcode / 聚合卡 / 审批卡片 / 扫码配对） | docs/ai-handbook/<对应>.md（物理单文件,各子 CLAUDE.md @import 引用同一份） |
| **新增 / 改子系统模块依赖**（新增 internal/ 包 / 改数据流） | **docs/architecture/<子系统>.md 的 Mermaid 图 + 组件清单** |
| **新增 / 改子系统的具体组件实现**（新增 handler / 改 repo 方法 / 加 page / 改 widget / 调整组件目录） | **`docs/architecture/<子系统>/<分组>.md` 对应详情文件**（不再是子系统 .md 本身） |
| **新增跨系统数据流**（新协议 / 新通道） | **docs/architecture/overview.md 的 Mermaid 图 + 数据流描述** |
| 安全红线变更 | 根 CLAUDE.md（本文件） |
| 开发命令 / 镜像 / 构建配置 | 对应子 CLAUDE.md（仅入口级变化才动本文件） |

**关键不变量**:
- 根 CLAUDE.md 永远 ≤ 100 行
- 子 CLAUDE.md 各 ≤ 200 行（架构节 ≤ 20 行,超过说明该子系统需要拆 docs/architecture/ 子主题）
- docs/architecture/overview.md ≤ 50 行（跨系统总图,不堆细节）
- docs/architecture/<子系统>.md ≤ 100 行（Mermaid 拓扑 + 组件简介清单,详细实现在 <子系统>/<分组>.md）
- docs/architecture/<子系统>.md 组件清单每条 ≤ 一行一句(详细实现写到 <子系统>/<分组>.md 详情文件,普通 markdown 链接按需 Read)
- docs/architecture/<子系统>/<分组>.md 单文件 ≤ 200 行(超出说明分组需要再拆)
- docs/ai-handbook/ 单文件 ≤ 200 行（跨系统协议物理单文件,真相源唯一）

## 安全红线（强制）

- **鉴权**: 所有 `/api/*` 业务路由在 `AuthMiddleware` 之后；`/health`、`/ws` 公开是设计如此；file 下载走四档放行（`FileRepo.CheckAccess`: owner / 三类头像白名单 / conv participant）
- **IDOR 防护**: 文件下载必校验归属（owner_id 匹配或 file_conv_links 授权），UUID 不可枚举只是抬高成本,不能替代归属校验
- **配置/凭证**: `.env` / `.yml` 配置文件里的链接信息和密码信息**禁止读**；`.gitignore` 排除的文件**绝对禁止读**
- **不可逆操作**: 推远程主分支 / 合并分支 / revert 分支 / 删数据 等不可逆操作**必须主动询问**,不擅自决定
- **分支纪律**: 除非有明确要求,禁止在主分支直接修改代码,正确做法是创建对应分支；没有明确指示,禁止擅自提交推送到主分支
- **commit message 风格**: 见全局 `~/.claude/CLAUDE.md`（中文,subject 前缀 `新增/修复/改造/...`,body 用 `-` 列要点）
- **业务校验**: fail fast 原则,让问题尽早暴露,严禁吞掉异常
- **数据完整性**: 严禁 mock 数据库,所有 repo 测试连真库（testcontainers）
- **代码模板**: 新增 handler/repo/migration/provider/page/service/model **必须从 `templates/` 复制骨架**，不准从零写（审计经验固化）。Plugin 代码量小不做模板
- **本地 DB 加密**: drift NativeDatabase 的 SQLCipher 加密必须经 build hook 配置（`pubspec.yaml` 的 `hooks.user_defines.sqlite3.source: sqlcipher`），并在 `_openWithKey` 的 setup 回调跑 `PRAGMA cipher_version` 运行时校验。`sqlcipher_flutter_libs` 在 sqlite3 3.0+ 已失效（基于被移除的 `open.overrideFor` API），不可重新引入
