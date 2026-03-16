# Scrapling MCP Server 部署指南

> 在 Debian 12 + 1Panel 环境下，通过 Docker 部署 Scrapling MCP Server，并配置 Nginx 反向代理 + Bearer Token 身份验证。

---

## 目录

1. [架构概览](#架构概览)
2. [前置条件](#前置条件)
3. [快速部署](#快速部署)
4. [1Panel 配置步骤](#1panel-配置步骤)
5. [客户端连接配置](#客户端连接配置)
6. [运维命令](#运维命令)
7. [安全说明](#安全说明)
8. [故障排查](#故障排查)

---

## 架构概览

```
客户端 (Claude Desktop / Cursor / OpenClaw)
        │
        ▼  HTTPS (443)
┌───────────────────────────┐
│  Nginx (OpenResty)        │ ← 1Panel 管理
│  • SSL 终结               │
│  • Bearer Token 验证      │
│  • 速率限制 & 安全头      │
└───────────┬───────────────┘
            │  HTTP (127.0.0.1:8000)
            ▼
┌───────────────────────────┐
│  Scrapling MCP Server     │ ← Docker 容器
│  • streamable-http 模式   │
│  • 6 个爬取工具           │
│  • 内置 Chromium 浏览器   │
└───────────────────────────┘
```

**核心安全设计**：Docker 容器端口仅绑定 `127.0.0.1`，不直接暴露公网。所有外部流量必须经过 Nginx 的 Token 验证。

---

## 前置条件

| 项目 | 要求 |
|------|------|
| 操作系统 | Debian 12 |
| 服务器配置 | ≥ 4C4G（推荐 8C8G） |
| 1Panel | 已安装 |
| Docker | 已通过 1Panel 安装 |
| OpenResty | 已通过 1Panel 安装 |
| 域名 | 已解析到服务器 IP |

---

## 快速部署

### 第一步：上传文件到服务器

将整个 `deploy/` 目录上传到服务器，例如 `/opt/scrapling/`：

```bash
# 在服务器上创建目录
mkdir -p /opt/scrapling

# 从本地上传（或 git clone 你的 fork）
git clone git@github.com:iT1000s/Scrapling.git
cp -r Scrapling/deploy/* /opt/scrapling/
cd /opt/scrapling
```

### 第二步：执行部署脚本

```bash
chmod +x setup.sh
./setup.sh
```

脚本会自动完成以下操作：
1. ✅ 检查 Docker / Docker Compose 依赖
2. ✅ 生成 `.env` 配置文件和安全的随机 Bearer Token
3. ✅ 拉取 `pyd4vinci/scrapling:latest` 镜像
4. ✅ 启动 Docker 容器
5. ✅ 等待服务健康检查通过
6. ✅ 输出客户端连接配置和 Nginx 配置提示

> **重要**：请记录脚本输出的 **Bearer Token**，后续配置 Nginx 和客户端都需要用到。

### 第三步：验证服务运行

```bash
# 在服务器本机测试
curl http://127.0.0.1:8000/mcp/
```

如果返回内容（非超时/连接拒绝），说明 Scrapling MCP Server 已正常运行。

---

## 1Panel 配置步骤

### 步骤一：创建反向代理网站

1. 登录 **1Panel 面板**
2. 进入 **网站** → **创建网站** → **反向代理**
3. 填写配置：
   - **域名**：`mcp.yourdomain.com`（替换为你的实际域名）
   - **代理地址**：`http://127.0.0.1:8000`

### 步骤二：申请 SSL 证书

1. 进入 **网站** → 选择刚创建的站点 → **HTTPS**
2. 选择 **Acme 账户**（没有则先创建一个）
3. 申请 **Let's Encrypt** 免费证书
4. 勾选 **强制 HTTPS**

### 步骤三：修改 Nginx 配置（添加认证）

1. 进入 **网站** → 选择站点 → **配置文件**
2. 在 `location /` 块中添加 Bearer Token 认证和 SSE 支持
3. 参考以下配置片段（将 `YOUR_TOKEN_HERE` 替换为部署脚本生成的 Token）：

```nginx
location /mcp/ {
    # ===== Bearer Token 身份验证 =====
    set $auth_ok 0;
    if ($http_authorization = "Bearer YOUR_TOKEN_HERE") {
        set $auth_ok 1;
    }
    if ($auth_ok = 0) {
        return 401 '{"error": "Unauthorized"}';
    }

    # ===== 反向代理 =====
    proxy_pass http://127.0.0.1:8000/mcp/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # ===== SSE / 长连接支持（MCP 必需）=====
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
    chunked_transfer_encoding on;
}
```

> 完整配置模板见 [nginx-scrapling-mcp.conf](./nginx-scrapling-mcp.conf)

### 步骤四：验证 Nginx 配置

```bash
# 无 Token → 应返回 401
curl -s -o /dev/null -w "%{http_code}" https://mcp.yourdomain.com/mcp/

# 有 Token → 应返回 200
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer YOUR_TOKEN_HERE" \
  https://mcp.yourdomain.com/mcp/
```

---

## 客户端连接配置

### Claude Desktop

编辑配置文件（菜单 → Settings → Developer → Edit Config）：

```json
{
  "mcpServers": {
    "ScraplingServer": {
      "type": "streamable-http",
      "url": "https://mcp.yourdomain.com/mcp/",
      "headers": {
        "Authorization": "Bearer YOUR_TOKEN_HERE"
      }
    }
  }
}
```

### Cursor

在 Cursor Settings → MCP 中添加：

```json
{
  "mcpServers": {
    "ScraplingServer": {
      "type": "streamable-http",
      "url": "https://mcp.yourdomain.com/mcp/",
      "headers": {
        "Authorization": "Bearer YOUR_TOKEN_HERE"
      }
    }
  }
}
```

### Claude Code

```bash
claude mcp add ScraplingServer \
  --transport streamable-http \
  "https://mcp.yourdomain.com/mcp/" \
  --header "Authorization: Bearer YOUR_TOKEN_HERE"
```

---

## 运维命令

所有命令在 `deploy/` 目录（如 `/opt/scrapling/`）下执行：

| 操作 | 命令 |
|------|------|
| 查看状态 | `./setup.sh status` |
| 查看日志 | `./setup.sh logs` |
| 停止服务 | `./setup.sh stop` |
| 重启服务 | `./setup.sh restart` |
| 升级镜像 | `./setup.sh update` |
| 重新生成 Token | `./setup.sh token` |

### 手动 Docker Compose 命令

```bash
# 启动
docker compose up -d

# 停止
docker compose down

# 查看日志
docker compose logs -f scrapling

# 查看资源使用
docker stats scrapling-mcp
```

---

## 安全说明

### 认证机制

- 采用 **Bearer Token** 认证，Token 通过 Nginx 验证
- Scrapling MCP Server 本身**不包含任何认证功能**
- Token 存储在服务器的 `.env` 文件和 Nginx 配置中

### 安全加固建议

1. **定期轮换 Token**：`./setup.sh token` 后更新 Nginx 和客户端配置
2. **IP 白名单**（可选）：在 Nginx 中添加 `allow/deny` 指令限制来源 IP
3. **速率限制**：取消 `nginx-scrapling-mcp.conf` 中 `limit_req` 相关注释
4. **防火墙**：确保 8000 端口只允许本机访问（默认已绑定 127.0.0.1）

### IP 白名单示例

```nginx
location /mcp/ {
    # 仅允许特定 IP 访问
    allow 1.2.3.4;      # 你的办公网络 IP
    allow 5.6.7.8;      # 其他可信 IP
    deny all;

    # ... 其他配置 ...
}
```

---

## 故障排查

### 容器无法启动

```bash
# 查看详细日志
docker compose logs scrapling

# 常见原因：
# 1. 端口 8000 被占用 → 修改 .env 中的 MCP_HOST_PORT
# 2. 内存不足 → 调整 .env 中的 MCP_MEMORY_LIMIT
# 3. 镜像拉取失败 → 检查网络，或使用 GitHub 镜像：
#    docker pull ghcr.io/d4vinci/scrapling:latest
```

### 返回 502 Bad Gateway

```bash
# 检查容器是否运行
docker compose ps

# 检查容器健康状态
docker inspect scrapling-mcp --format='{{.State.Health.Status}}'

# 在容器内测试
docker exec scrapling-mcp curl -s http://localhost:8000/mcp/
```

### 返回 401 Unauthorized

```bash
# 确认 Token 正确
cat .env | grep MCP_AUTH_TOKEN

# 确认 Nginx 配置中的 Token 与 .env 一致
# 在 1Panel → 网站 → 配置文件 中检查
```

### 浏览器相关错误（Chromium 崩溃）

```bash
# 增加共享内存
# 修改 .env 中的 MCP_SHM_SIZE=4g

# 重启服务
./setup.sh restart
```

### 端口冲突

```bash
# 检查 8000 端口占用
ss -tlnp | grep 8000

# 如果被占用，修改 .env 中的 MCP_HOST_PORT 为其他端口（如 8001）
# 同时更新 Nginx 代理地址
```

---

## 文件说明

```
deploy/
├── .env.example              # 环境变量模板
├── .env                      # 实际配置（部署脚本自动生成，不提交 Git）
├── docker-compose.yml        # Docker Compose 编排文件
├── nginx-scrapling-mcp.conf  # Nginx 完整配置模板
├── setup.sh                  # 一键部署脚本
└── README.md                 # 本文档
```
