# sdk/CLAUDE.md

万灵 Plugin SDK,仓库根 `sdk/`,对外发布 TypeScript + Python 双语言传输层 SDK,供外部开发者接入万灵 server 成为 agent 插件。

## 子系统身份

- `sdk/ts` → npm 包 `@wanling/sdk`:连接生命周期 + 协议编解码 + REST + RPC + 流式 + 能力上报
- `sdk/python` → PyPI 包 `wanling-sdk`(UV 管理):与 TS 对称,`asyncio` + `websockets` + `httpx`
- `sdk/templates` → 最小 agent 插件脚手架(template-ts / template-py)

## 开发命令

```bash
# TS
cd sdk/ts && npm install && npx vitest run && npx eslint src/ test/ && npx tsc --noEmit

# Python(UV)
cd sdk/python && uv sync
cd sdk/python && uv run pytest -v
cd sdk/python && uv run ruff check wanling_sdk tests

# 统一入口(已并入 make lint / test / check)
make lint-sdk   # eslint + ruff
make test-sdk   # vitest + pytest
```

## 架构(概要)

```mermaid
flowchart LR
    DEV[外部开发者] -->|@wanling/sdk / wanling-sdk| SDK[SDK 传输层<br/>TS + Python]
    SDK -->|WS op=0/10/12/13/14| SERVER[万灵 Server]
    SDK -->|REST envelope| SERVER
```

## 协议同步规则

- opcodes 常量以 `server/internal/model/opcodes.go` 为单真相源,改动 server 协议必须同步 `sdk/ts/src/opcodes.ts` + `sdk/python/wanling_sdk/opcodes.py` + 各自对照表单测
- 事件命名两语言一致,见 `docs/architecture/sdk.md` 事件表
- REST 方法遵循 `docs/ai-handbook/rest-response.md` envelope

## 发布

```bash
scripts/publish-sdk.sh   # npm publish + uv publish,版本独立演进
```

SDK 不进 gitee 镜像 repo(镜像只分发可 curl 安装的 plugin)。
