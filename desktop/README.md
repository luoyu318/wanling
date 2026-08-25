# wanling_desktop

万灵桌面端(Linux,debug 自用)。独立 Flutter 工程,复用 `packages/wanling_core`(模型/provider/API 层与 APP 同源)。

## 运行

```bash
cd desktop
flutter run -d linux --debug   # 需 export PUB_HOSTED_URL/FLUTTER_STORAGE_BASE_URL(见根 CLAUDE.md)
```

## 与 APP 的差异

- 无 3-tab 壳:NavRail + 消息列表 + 会话窗 + 万灵页(agent sessions 面板)
- 一级列表多 session agent(opencode/dsh 等)路由进二级 sessions 面板(判据同 APP:`multi_session` 注册表)
- 徽标/类型下拉查 server type 注册表(GET /api/agent-types,fallback 本地预置)

