# skills/ — agent 技能(独立安装)

面向 agent(opencode 等)的技能资产,与 `plugin/` 运行时**解耦**:不随插件安装/更新,按需自主安装。

## 安装

```bash
cd skills
./install.sh            # 列出可用技能
./install.sh all        # 安装全部
./install.sh wanling-miniprogram-publish
```

- 技能落盘 `~/.opencode/skills/<name>/`,新会话/重启 opencode 生效
- 技能附带的 `opencode-plugins/` 子目录(tool 注册挂件)一并部署到 `~/.config/opencode/plugins/`
- 协议真相源在 `docs/ai-handbook/`;技能与协议的同步由维护者负责,插件更新不再自动覆盖
