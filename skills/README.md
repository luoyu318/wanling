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

## Agent 自助安装(agent 可直接执行,无需人工介入)

agent 在本仓库内工作时,按以下步骤自主完成安装:

1. 安装/更新(幂等,重复执行安全):

   ```bash
   cd skills && ./install.sh all    # 或按名安装: ./install.sh wanling-miniprogram-publish
   ```

2. 验证(无输出 = 与仓库一致):

   ```bash
   diff -rq wanling-miniprogram-publish ~/.opencode/skills/wanling-miniprogram-publish
   diff -rq wanling-send-image ~/.opencode/skills/wanling-send-image
   ```

3. 生效:当前会话不热加载技能,须提示用户新开会话(或重启 opencode)后可用。

安全约束:`install.sh` 仅把仓库内文件复制到 `~/.opencode/skills/` 与 `~/.config/opencode/plugins/`,无网络请求、无删除操作。
