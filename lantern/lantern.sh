#!/bin/bash
# Lantern Server Manager 管理脚本 v1.0
#
# 镜像：getlantern/lantern-server-manager
# Docker Hub：https://hub.docker.com/r/getlantern/lantern-server-manager
# 上游项目：https://github.com/getlantern/lantern-server-manager
#
# ── 默认配置 ──────────────────────────────────
# API 端口：  18080  (Web UI / REST API)
# VPN 端口：  30001  (WireGuard TCP)
# 配置目录：  ./config (宿主机) → /config (容器内)
# 证书文件：  ./config/cert.pem / ./config/key.pem
# ─────────────────────────────────────────────

# ─────────────────────────────────────────────
# 常量配置
# ─────────────────────────────────────────────
DEFAULT_API_PORT=18080
DEFAULT_VPN_PORT=30001
CONTAINER="lantern"

# 脚本目录（追踪软链接，兼容 Linux / macOS）
_resolve_script_dir() {
    local src="$0"
    while [ -L "$src" ]; do
        local link_dir
        link_dir="$(cd "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$link_dir/$src"
    done
    cd "$(dirname "$src")" && pwd
}
SCRIPT_DIR="$(_resolve_script_dir)"

# 数据目录（证书、配置等运行时数据）
DATA_DIR="${LIBRE_DATA_DIR:-/usr/local/app/libre/lantern}"

# 颜色变量 (当终端不支持颜色时自动降级)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

# ─────────────────────────────────────────────
# 工具函数
# ─────────────────────────────────────────────

# 获取公网 IP，依次尝试多个服务
get_ip() {
    local ip
    for service in "ifconfig.me" "icanhazip.com" "api.ipify.org"; do
        ip=$(curl -s --connect-timeout 3 "$service" 2>/dev/null)
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    done
    echo "未知"
    return 1
}

# 检测 docker compose 命令 (兼容新旧版本，始终在脚本目录执行)
docker_compose() {
    if docker compose version &>/dev/null; then
        docker compose -f "$SCRIPT_DIR/docker-compose.yml" --project-directory "$SCRIPT_DIR" "$@"
    else
        docker-compose -f "$SCRIPT_DIR/docker-compose.yml" --project-directory "$SCRIPT_DIR" "$@"
    fi
}

# 校验端口号合法性 (1-65535)
validate_port() {
    local port=$1
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        printf '%b\n' "${RED}❌ 端口无效：$port (有效范围 1-65535)${NC}"
        return 1
    fi
    return 0
}

# 检查容器是否正在运行
is_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"
}

# 检查证书文件是否存在
check_certs() {
    local cert="$DATA_DIR/config/cert.pem"
    local key="$DATA_DIR/config/key.pem"

    # 确保数据目录存在
    mkdir -p "$DATA_DIR/config"

    if [ ! -f "$cert" ] || [ ! -f "$key" ]; then
        printf '%b\n' "${YELLOW}⚠️  未找到证书文件，尝试自动生成...${NC}"
        if [ -f "$SCRIPT_DIR/scripts/gen_cert.py" ]; then
            LIBRE_DATA_DIR="$DATA_DIR" python3 "$SCRIPT_DIR/scripts/gen_cert.py" \
                && printf '%b\n' "${GREEN}✅ 证书生成成功${NC}" \
                || { printf '%b\n' "${RED}❌ 证书生成失败，请手动将 cert.pem / key.pem 放入 $DATA_DIR/config/ 目录${NC}"; return 1; }
        else
            printf '%b\n' "${RED}❌ 未找到 gen_cert.py，请手动将 cert.pem / key.pem 放入 $DATA_DIR/config/ 目录${NC}"
            return 1
        fi
    fi
    return 0
}

# ─────────────────────────────────────────────
# 核心命令
# ─────────────────────────────────────────────

# 启动服务
start() {
    check_certs || return 1

    printf '%b\n' "${CYAN}🚀 启动 Lantern Server Manager...${NC}"
    printf '%b\n' "   ${BLUE}API 端口:${NC} ${DEFAULT_API_PORT}"
    printf '%b\n' "   ${BLUE}VPN 端口:${NC} ${DEFAULT_VPN_PORT}"

    docker_compose down 2>/dev/null
    docker_compose up -d || { printf '%b\n' "${RED}❌ 容器启动失败${NC}"; return 1; }

    printf '%b\n' "${YELLOW}⏳ 等待服务就绪...${NC}"
    sleep 5

    if is_running; then
        local ip
        ip=$(get_ip)
        printf '%b\n' "${GREEN}✅ 启动完成${NC}"
        printf '%b\n' "   ${BLUE}🌐 Web UI:${NC} ${BOLD}https://$ip:${DEFAULT_API_PORT}${NC}"
        printf '%b\n' "   ${BLUE}🔒 VPN 端口:${NC} $ip:${DEFAULT_VPN_PORT}"
    else
        printf '%b\n' "${RED}❌ 容器启动后未检测到运行状态，请查看日志${NC}"
        return 1
    fi
}

# 停止服务
stop() {
    printf '%b\n' "${CYAN}🛑 停止 Lantern Server Manager...${NC}"
    docker_compose down && printf '%b\n' "${GREEN}✅ 已停止${NC}"
}

# 重启服务
restart() {
    printf '%b\n' "${CYAN}🔄 重启 Lantern Server Manager...${NC}"
    docker_compose restart \
        && printf '%b\n' "${GREEN}✅ 重启完成${NC}" \
        || { printf '%b\n' "${RED}❌ 重启失败${NC}"; return 1; }
}

# 查看运行状态
status() {
    if is_running; then
        local ip
        ip=$(get_ip)
        printf '%b\n' "${GREEN}✅ 状态: 运行中${NC}"
        printf '%b\n' "   ${BLUE}🌐 IP:${NC}      $ip"
        printf '%b\n' "   ${BLUE}🔗 Web UI:${NC}  https://$ip:${DEFAULT_API_PORT}"
        printf '%b\n' "   ${BLUE}🔒 VPN 端口:${NC} $ip:${DEFAULT_VPN_PORT}"
        printf '%b\n' ""
        docker ps --filter "name=${CONTAINER}" --format "   镜像: {{.Image}}\n   运行时长: {{.RunningFor}}\n   状态: {{.Status}}"
    else
        printf '%b\n' "${RED}❌ 状态: 未运行${NC}"
    fi
}

# 拉取最新镜像并重启
update() {
    printf '%b\n' "${CYAN}⬆️  拉取最新镜像...${NC}"
    docker_compose pull || { printf '%b\n' "${RED}❌ 镜像拉取失败${NC}"; return 1; }

    printf '%b\n' "${CYAN}🔄 重启服务...${NC}"
    start
    printf '%b\n' "${GREEN}✅ 更新完成${NC}"
}

# 进入容器交互式终端
shell() {
    is_running || { printf '%b\n' "${RED}❌ 容器未运行，请先执行 start${NC}"; return 1; }
    printf '%b\n' "${CYAN}🐚 进入容器终端 (输入 exit 退出)...${NC}"
    docker exec -it "$CONTAINER" /bin/sh
}

# 查看容器日志
logs() {
    docker logs --tail 100 -f "$CONTAINER"
}

# 显示公网 IP
show_ip() {
    printf '%b\n' "${BLUE}🌐 公网 IP: ${BOLD}$(get_ip)${NC}"
}

# 生成自签名证书
gen_cert() {
    mkdir -p "$DATA_DIR/config"
    if [ -f "$SCRIPT_DIR/scripts/gen_cert.py" ]; then
        LIBRE_DATA_DIR="$DATA_DIR" python3 "$SCRIPT_DIR/scripts/gen_cert.py" \
            && printf '%b\n' "${GREEN}✅ 证书已生成到 $DATA_DIR/config/ 目录${NC}" \
            || printf '%b\n' "${RED}❌ 证书生成失败${NC}"
    else
        printf '%b\n' "${RED}❌ 未找到 gen_cert.py${NC}"
        return 1
    fi
}

# 显示帮助信息
show_help() {
    printf '%b\n' "${BOLD}用法: $0 <命令>${NC}"
    printf '\n'
    printf '%b\n' "${BOLD}命令列表:${NC}"
    printf "  ${GREEN}%s${NC} %s\n" "start      " "启动服务（自动检查并生成证书）"
    printf "  ${GREEN}%s${NC} %s\n" "stop       " "停止服务"
    printf "  ${GREEN}%s${NC} %s\n" "restart    " "重启服务"
    printf "  ${GREEN}%s${NC} %s\n" "status     " "查看运行状态"
    printf "  ${GREEN}%s${NC} %s\n" "update     " "拉取最新镜像并重启"
    printf "  ${GREEN}%s${NC} %s\n" "gen-cert   " "生成自签名证书到 ./config 目录"
    printf "  ${GREEN}%s${NC} %s\n" "shell      " "进入容器交互式终端"
    printf "  ${GREEN}%s${NC} %s\n" "logs       " "查看容器日志（实时）"
    printf "  ${GREEN}%s${NC} %s\n" "ip         " "显示公网 IP"
    printf "  ${GREEN}%s${NC} %s\n" "help       " "显示此帮助信息"
    printf '\n'
    printf '%b\n' "${BOLD}默认端口:${NC}"
    printf "  Web UI / API : ${DEFAULT_API_PORT}\n"
    printf "  VPN : ${DEFAULT_VPN_PORT} (TCP)\n"
}

# ─────────────────────────────────────────────
# 入口分发
# ─────────────────────────────────────────────
case "${1:-help}" in
    start)     start     ;;
    stop)      stop      ;;
    restart)   restart   ;;
    status)    status    ;;
    update)    update    ;;
    gen-cert)  gen_cert  ;;
    shell)     shell     ;;
    logs)      logs      ;;
    ip)        show_ip   ;;
    help|*)    show_help ;;
esac
