# 文档站部署说明（内部）

本文件是仓库内部文档，不属于站点内容。实际改动生产 nginx 前必须单独与用户确认（生产操作红线）。

## 构建

```bash
make docs-build  # 产物 docs-site/dist/，站点根路径为 /docs/
```

产物路径为 `docs-site/dist/<slug>/`（如 `dist/quickstart/`、`dist/guides/manifest/`），URL 前缀 `/docs` 由 `astro.config.mjs` 的 `base` 在服务层生效，不体现在产物目录结构中。

## 部署（需人工确认后执行）

1. 同步产物到服务器：

   ```bash
   rsync -av --delete docs-site/dist/ <server>:/usr/local/wanling/docs/
   ```

2. nginx 增加静态托管：

   ```nginx
   location /docs/ {
       alias /usr/local/wanling/docs/;
       index index.html;
   }
   ```

3. 校验并重载：

   ```bash
   nginx -t && systemctl reload nginx
   ```

注意：第 2、3 步涉及生产 nginx 变更，必须单独与用户确认后再执行。
