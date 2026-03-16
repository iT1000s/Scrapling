#!/usr/bin/env bash
# ============================================================
# Scrapling MCP Server - 一键部署脚本
# 适用于 Debian 12 + 1Panel 环境
# ============================================================
set -euo pipefail

# ---- 颜色定义 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# ---- 辅助函数 ----
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# ---- 获取脚本所在目录 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

# ============================================================
# 主函数
# ============================================================
main() {
    echo ""
    echo "=========================================="
    echo "  Scrapling MCP Server 部署脚本"
    echo "=========================================="
    echo ""

    # 1. 检查依赖
    check_dependencies

    # 2. 配置环境变量
    setup_env

    # 3. 拉取 Docker 镜像
    pull_image

    # 4. 启动服务
    start_service

    # 5. 等待服务就绪
    wait_for_service

    # 6. 输出客户端配置
    print_client_config

    echo ""
    log_info "=========================================="
    log_info "  部署完成！"
    log_info "=========================================="
    echo ""
}

# ============================================================
# 步骤函数
# ============================================================

check_dependencies() {
    log_step "检查依赖..."

    local missing=0

    if ! command -v docker &>/dev/null; then
        log_error "未找到 docker，请先通过 1Panel 安装 Docker"
        missing=1
    fi

    if ! command -v curl &>/dev/null; then
        log_warn "未找到 curl，正在安装..."
        apt-get update -qq && apt-get install -y -qq curl >/dev/null 2>&1
    fi

    if [ "$missing" -eq 1 ]; then
        exit 1
    fi

    # 检查 docker compose（v2）
    if ! docker compose version &>/dev/null; then
        log_error "未找到 docker compose (v2)，请升级 Docker 或安装 docker-compose-plugin"
        exit 1
    fi

    log_info "依赖检查通过 ✓"
}

setup_env() {
    log_step "配置环境变量..."

    if [ -f "$ENV_FILE" ]; then
        log_warn ".env 文件已存在，将使用现有配置"
        log_warn "如需重新配置，请删除 ${ENV_FILE} 后重试"

        # 读取现有 Token
        # shellcheck source=/dev/null
        source "$ENV_FILE"
    else
        # 复制模板
        cp "$ENV_EXAMPLE" "$ENV_FILE"

        # 生成安全的随机 Token
        local token
        token=$(openssl rand -hex 32)

        # 替换 Token
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "s/CHANGE_ME_TO_A_SECURE_RANDOM_TOKEN/${token}/" "$ENV_FILE"
        else
            sed -i "s/CHANGE_ME_TO_A_SECURE_RANDOM_TOKEN/${token}/" "$ENV_FILE"
        fi

        # 读取新配置
        # shellcheck source=/dev/null
        source "$ENV_FILE"

        log_info "已生成 .env 配置文件"
        log_info "Bearer Token: ${token}"
        echo ""
        log_warn "请妥善保管此 Token，它是访问 MCP Server 的唯一凭证"
        log_warn "Token 已保存在 ${ENV_FILE} 中"
    fi

    echo ""
}

pull_image() {
    log_step "拉取 Scrapling Docker 镜像..."
    docker pull pyd4vinci/scrapling:latest
    log_info "镜像拉取完成 ✓"
}

start_service() {
    log_step "启动 Scrapling MCP Server..."

    cd "$SCRIPT_DIR"

    # 如果已经在运行，先停止
    if docker compose ps --status running 2>/dev/null | grep -q scrapling; then
        log_warn "检测到服务正在运行，正在重启..."
        docker compose down
    fi

    docker compose up -d

    log_info "服务已启动 ✓"
}

wait_for_service() {
    log_step "等待服务就绪..."

    local max_retries=15
    local retries=0

    while [ $retries -lt $max_retries ]; do
        if curl -sf http://127.0.0.1:"${MCP_HOST_PORT:-8000}"/mcp/ >/dev/null 2>&1; then
            log_info "服务已就绪 ✓"
            return 0
        fi

        retries=$((retries + 1))
        echo -n "."
        sleep 2
    done

    echo ""
    log_error "服务启动超时，请检查日志："
    log_error "  docker compose -f ${SCRIPT_DIR}/docker-compose.yml logs"
    exit 1
}

print_client_config() {
    # shellcheck source=/dev/null
    source "$ENV_FILE"

    local domain="${MCP_DOMAIN:-mcp.yourdomain.com}"
    local token="${MCP_AUTH_TOKEN}"
    local port="${MCP_HOST_PORT:-8000}"

    echo ""
    echo "=========================================="
    echo "  客户端配置信息"
    echo "=========================================="
    echo ""

    # ---- 直连测试（无 Nginx）----
    log_info "1. 直连测试（服务器本机）:"
    echo ""
    echo "  curl http://127.0.0.1:${port}/mcp/"
    echo ""

    # ---- 配置 Nginx 后的测试 ----
    log_info "2. 通过 Nginx 反向代理访问（配置域名和 SSL 后）:"
    echo ""
    echo "  # 无认证 → 应返回 401"
    echo "  curl -s -o /dev/null -w '%{http_code}' https://${domain}/mcp/"
    echo ""
    echo "  # 有认证 → 应返回 200"
    echo "  curl -s -o /dev/null -w '%{http_code}' \\"
    echo "    -H 'Authorization: Bearer ${token}' \\"
    echo "    https://${domain}/mcp/"
    echo ""

    # ---- MCP 客户端配置 ----
    log_info "3. Claude Desktop / Cursor 配置（通过 Nginx + HTTPS）:"
    echo ""
    cat <<EOF
  {
    "mcpServers": {
      "ScraplingServer": {
        "type": "streamable-http",
        "url": "https://${domain}/mcp/",
        "headers": {
          "Authorization": "Bearer ${token}"
        }
      }
    }
  }
EOF
    echo ""

    # ---- Nginx 配置提示 ----
    log_info "4. Nginx 配置步骤:"
    echo ""
    echo "  a. 在 1Panel → 网站 → 创建网站 → 反向代理"
    echo "     域名: ${domain}"
    echo "     代理地址: http://127.0.0.1:${port}"
    echo ""
    echo "  b. 在 1Panel → 网站 → 选择站点 → HTTPS"
    echo "     申请 Let's Encrypt 证书"
    echo ""
    echo "  c. 在 1Panel → 网站 → 选择站点 → 配置文件"
    echo "     参考 ${SCRIPT_DIR}/nginx-scrapling-mcp.conf 添加:"
    echo "     - Bearer Token 认证（将 __MCP_AUTH_TOKEN__ 替换为: ${token}）"
    echo "     - SSE 长连接支持"
    echo "     - 速率限制"
    echo ""

    log_info "Bearer Token: ${token}"
    echo ""
}

# ============================================================
# 附加命令
# ============================================================

# 支持传入子命令
case "${1:-}" in
    stop)
        log_step "停止服务..."
        cd "$SCRIPT_DIR"
        docker compose down
        log_info "服务已停止 ✓"
        ;;
    restart)
        log_step "重启服务..."
        cd "$SCRIPT_DIR"
        docker compose restart
        log_info "服务已重启 ✓"
        ;;
    logs)
        cd "$SCRIPT_DIR"
        docker compose logs -f scrapling
        ;;
    status)
        cd "$SCRIPT_DIR"
        docker compose ps
        ;;
    update)
        log_step "更新 Scrapling 镜像..."
        docker pull pyd4vinci/scrapling:latest
        cd "$SCRIPT_DIR"
        docker compose down
        docker compose up -d
        log_info "更新完成 ✓"
        ;;
    token)
        # 重新生成 Token
        local new_token
        new_token=$(openssl rand -hex 32)
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "s/MCP_AUTH_TOKEN=.*/MCP_AUTH_TOKEN=${new_token}/" "$ENV_FILE"
        else
            sed -i "s/MCP_AUTH_TOKEN=.*/MCP_AUTH_TOKEN=${new_token}/" "$ENV_FILE"
        fi
        log_info "新 Token 已生成: ${new_token}"
        log_warn "请同时更新 Nginx 配置和客户端中的 Token"
        ;;
    *)
        main
        ;;
esac
