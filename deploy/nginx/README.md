# Wanling 反向代理模板

本目录提供 nginx 反代配置示例。**compose 不内置反代**，由用户决定是否使用、用什么反代。

## 文件

| 文件 | 场景 |
|---|---|
| `nginx.example.conf` | 纯 HTTP 反代。适合内网部署、Cloudflare 前置 TLS、自签证书环境 |
| `nginx-tls.example.conf` | 直接对公网，含 TLS 证书配置和 HTTP→HTTPS 强制跳转 |

## 用法

### Linux（裸 nginx）

```bash
# 选模板（这里以 TLS 版为例）
sudo cp deploy/nginx/nginx-tls.example.conf /etc/nginx/sites-available/wanling

# 编辑：改 server_name、改证书路径（如果不用 certbot 默认路径）
sudo vim /etc/nginx/sites-available/wanling

# 启用
sudo ln -s /etc/nginx/sites-available/wanling /etc/nginx/sites-enabled/

# 验证语法
sudo nginx -t

# 重载
sudo systemctl reload nginx
```

### Docker 化 nginx（可选）

如果你想把 nginx 也容器化（独立 compose），把模板挂进容器：

```yaml
services:
  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./deploy/nginx/nginx-tls.example.conf:/etc/nginx/conf.d/wanling.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"   # 让容器能访问宿主机的 18008
```

注意：模板里 `proxy_pass http://127.0.0.1:18008` 要改成 `proxy_pass http://host.docker.internal:18008`。

## 证书管理

### certbot 申请

```bash
# 首次申请（需 80 端口可用，临时停 nginx）
sudo systemctl stop nginx
sudo certbot certonly --standalone -d chat.example.com
sudo systemctl start nginx
```

### 自动续期

certbot 默认装好后会自动加 systemd timer。手动验证：

```bash
sudo certbot renew --dry-run
```

如果想加续期后 reload nginx：

```bash
sudo crontab -e
# 加一行（每周日 0 点检查，有更新就 reload）：
0 0 * * 0 certbot renew --deploy-hook "systemctl reload nginx"
```

## 不内置 certbot 的理由

compose 不内置 certbot 自动续期，理由：

1. 反代选型应由用户决定（可能用 Caddy / Traefik / Cloudflare Tunnel）
2. 证书申请跟 DNS / 域名强耦合，自动化失败排查复杂
3. certbot 续期机制跟反代生命周期解耦（独立 systemd timer / cron 更稳）

## APP 端配置

挂好反代后，在 Wanling APP 设置里把服务器地址改为 `https://chat.example.com`（不是 `http://ip:18008`）。
