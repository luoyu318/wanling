# 万灵小程序开发指南

面向第三方开发者的完整文档已迁移至文档站（内容已覆盖原 107 行正文，本页仅保留内部开发专属说明）：

- 站点源码：`docs-site/`（`make docs-dev` 本地预览，`make docs-build` 构建）
- 协议真相源：[docs/ai-handbook/miniprogram.md](./ai-handbook/miniprogram.md)
- 示例：`scripts/examples/miniprogram-hello` / `-showcase` / `-header`

## 内部专属（不对外）

- agent token 直传：`POST /api/mini-programs`，handler 内 owner 换算（照 file_handler 先例）；SKILL 发布流程见 `plugin/opencode-plugin/skills/wanling-miniprogram-publish/`
- 部署文档站：[docs-site/DEPLOY.md](../docs-site/DEPLOY.md)
