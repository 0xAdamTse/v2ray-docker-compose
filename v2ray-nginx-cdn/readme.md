# V2Ray Nginx CDN 部署指南

本方案在一台 VPS 上通过 Docker 部署 V2Ray，配合 Nginx 反代和 Cloudflare CDN，提供以下三个节点：

| 节点 | 协议 | 端口 | 说明 |
|---|---|---|---|
| VMess-TLS | VMess + WS + TLS | 443 | 经 Cloudflare CDN，抗封锁 |
| Trojan-TLS | Trojan + TLS | 1220 | 直连域名，高安全性 |
| VMess-Raw | VMess + TCP | 1312 | 直连 IP，无加密，备用 |

---

## 架构

```
客户端
  ├── VMess-TLS  →  Cloudflare CDN  →  Nginx:443  →  V2Ray:1310 (VMess+WS)
  ├── Trojan-TLS →  direct.域名:1220              →  V2Ray:1220 (Trojan+TLS)
  └── VMess-Raw  →  服务器IP:1312                 →  V2Ray:1312 (VMess+TCP)

证书管理：nginx-proxy-acme 自动申请 Let's Encrypt SAN 证书（覆盖两个域名）
```

---

## 前提条件

- VPS 系统：Ubuntu 20.04 / 22.04
- 已安装：Docker、Docker Compose
- 已有域名，并添加到 Cloudflare

---

## 快速部署

```bash
bash deploy.sh
```

脚本会全程引导，最后自动输出 Surge 配置。

---

## 完整流程（手动操作参考）

### 第一步：确认端口已开放

在服务器防火墙 / 云控制台安全组中开放：

| 端口 | 用途 |
|---|---|
| 80 | HTTP，Let's Encrypt 证书验证必须 |
| 443 | HTTPS，VMess+TLS 入口 |
| 1220 | Trojan+TLS 直连 |
| 1312 | VMess Raw 直连（备用） |

使用 ufw 的服务器：
```bash
ufw allow 80 && ufw allow 443 && ufw allow 1220 && ufw allow 1312 && ufw enable
```

---

### 第二步：安装 Docker

```bash
curl -fsSL https://get.docker.com | sh
apt install docker-compose-plugin -y

# 可选：将当前用户加入 docker 组（避免每次 sudo）
sudo usermod -aG docker $USER
# 重新登录后生效
```

---

### 第三步：Cloudflare DNS 配置

在 Cloudflare DNS 面板添加两条 A 记录：

| 类型 | 名称 | 内容 | 代理状态 |
|---|---|---|---|
| A | 主子域（如 `play`） | 服务器 IP | 🌫️ **灰色云（先关代理）** |
| A | 直连子域（如 `nv`） | 服务器 IP | 🌫️ **灰色云（始终关代理）** |

> ⚠️ 申请证书期间两条记录都必须是灰色云，证书申请成功后再把主子域改为橙色云。

同时设置 SSL/TLS 模式：
```
Cloudflare → SSL/TLS → 概述 → 加密模式 → 完全 (Full)
```

---

### 第四步：修改配置文件

**docker-compose.yml** 关键配置：

```yaml
v2ray:
  environment:
    - VIRTUAL_HOST=主域名,直连域名       # Nginx 反代 + 证书申请
    - LETSENCRYPT_HOST=主域名,直连域名   # SAN 证书覆盖两个域名
    - VIRTUAL_PORT=1310                  # Nginx 代理到 V2Ray 的端口
  ports:
    - '1312:1312'   # VMess Raw，对外暴露
    - '1220:1220'   # Trojan+TLS，对外暴露
    # 1310 不暴露到宿主机，Nginx 通过内部网络访问
```

> ⚠️ **VIRTUAL_PORT 必须设为 1310**（VMess+WS 端口），因为 docker-gen 会以第一个暴露端口作为回退，
> 将 VMess+WS 放在 1310 确保 Nginx 路由正确。

**v2ray/config/config.json** 端口分工：

| 端口 | 协议 | 传输 | 说明 |
|---|---|---|---|
| 1310 | VMess | WebSocket `/vmess` | Nginx 反代，不直接对外 |
| 1312 | VMess | TCP | 直连，无 TLS |
| 1220 | Trojan | TCP + TLS | 直连，V2Ray 自行终止 TLS |

---

### 第五步：分阶段启动

**第一阶段**：先不加入 Trojan+TLS（证书文件尚不存在，V2Ray 读取会报错）

```bash
docker compose up -d
```

等待证书申请完成（约 1~3 分钟）：
```bash
watch -n 3 "ls ./certs/"
# 出现主域名目录后按 Ctrl+C
```

验证 SAN 证书同时覆盖两个域名：
```bash
openssl x509 -in ./certs/主域名/fullchain.pem -text -noout | grep -A2 "Subject Alternative"
# 应看到：DNS:主域名, DNS:直连域名
```

**第二阶段**：更新 config.json 加入 Trojan+TLS，重启 V2Ray：
```bash
docker compose restart v2ray
docker compose logs v2ray | tail -20   # 确认无 ERROR
```

---

### 第六步：开启 Cloudflare CDN

证书申请完成后：
- 主域名（`play.example.com`）→ 改为 🟠 **橙色云**
- 直连域名（`nv.example.com`）→ 保持 🌫️ **灰色云**

---

### 第七步：设置证书续签后自动重启

Let's Encrypt 证书 90 天过期，acme-companion 自动续签，但 V2Ray 需重启才能加载新证书。

```bash
crontab -e
```

添加（UTC 时区服务器，对应北京时间凌晨 3 点）：
```
0 19 * * * cd /path/to/v2ray-nginx-cdn && docker compose restart v2ray >> /var/log/v2ray-restart.log 2>&1
```

若服务器时区是 Asia/Shanghai：
```
0 3 * * * cd /path/to/v2ray-nginx-cdn && docker compose restart v2ray >> /var/log/v2ray-restart.log 2>&1
```

---

## Surge 客户端配置

```ini
[General]
loglevel = notify
dns-server = 8.8.8.8, 8.8.4.4, 223.5.5.5
skip-proxy = 127.0.0.1, 192.168.0.0/16, 10.0.0.0/8, localhost, *.local
ipv6 = false

[Proxy]
VMess-Raw = vmess, 服务器IP, 1312, username=VMESS_UUID, vmess-aead=true, tls=false
VMess-TLS = vmess, 主域名, 443, username=VMESS_UUID, vmess-aead=true, tls=true, ws=true, ws-path=/vmess, skip-cert-verify=false
Trojan-TLS = trojan, 直连域名, 1220, password=TROJAN_PASSWORD, tls=true, skip-cert-verify=false

[Proxy Group]
Proxy = select, VMess-TLS, Trojan-TLS, VMess-Raw

[Rule]
GEOIP, CN, DIRECT
FINAL, Proxy
```

---

## 常用运维命令

```bash
# 查看容器状态
docker compose ps

# 查看日志
docker compose logs v2ray
docker compose logs nginx
docker compose logs nginx-proxy-acme

# 重启单个容器
docker compose restart v2ray

# 停止所有服务
docker compose down

# 查看已保存的凭证
cat credentials.txt
```

---

## 故障排查

| 现象 | 检查命令 | 常见原因 |
|---|---|---|
| 证书申请失败 | `docker compose logs nginx-proxy-acme \| tail -30` | DNS 未生效 / 80 端口未开 / Cloudflare 未关灰云 |
| VMess-TLS 失败 | `docker compose exec nginx grep "server 172" /etc/nginx/conf.d/default.conf` | Nginx upstream 端口错误（应为 1310） |
| Trojan-TLS 失败 | `docker compose logs v2ray \| grep -i error` | 证书路径错误 / 证书不含直连域名 |
| 所有节点失败 | `docker compose ps` | 容器未启动 |
| 证书未包含直连域名 | `openssl x509 -in ./certs/主域名/fullchain.pem -text -noout \| grep -A2 "Subject Alt"` | 直连域名 DNS 记录未添加 |

---

## 注意事项

1. `credentials.txt` 包含敏感信息，已在 `.gitignore` 中排除，请勿提交到 git
2. Trojan-Raw（无 TLS）在 Surge 客户端支持不稳定，已从方案中去除
3. 直连域名（`nv.example.com`）的 Cloudflare 代理必须始终保持**灰色云**，否则 Trojan+TLS 连接会经过 Cloudflare 但 Trojan 不是 HTTP 协议导致失败
4. Cloudflare 免费套餐支持 WebSocket，但需确认 SSL 模式为「完全 (Full)」而非「灵活」
