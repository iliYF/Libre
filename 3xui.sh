#!/bin/bash
# 3x-ui 管理脚本 v3.0
#
# 镜像：bigbugcc/3x-ui
# Docker Hub：https://hub.docker.com/r/bigbugcc/3x-ui
# 上游项目：https://github.com/MHSanaei/3x-ui
# 支持架构：amd64 / arm64 / armv7
#
# ── 镜像默认配置 ──────────────────────────────
# 时区：        Asia/Shanghai
# 面板端口：    2053 (镜像默认; 本脚本已改为 2026)
# 用户名/密码： 首次启动随机生成 (未手动设置时)
# 数据库路径：  /etc/x-ui/x-ui.db (容器内)
# Xray 配置：   /usr/local/x-ui/bin/config.json (容器内)
# 面板地址：    http://<IP>:${DEFAULT_PORT}/panel
#              https://<域名>:${DEFAULT_PORT}/panel (部署 SSL 后)
# ─────────────────────────────────────────────

# ─────────────────────────────────────────────
# 常量配置
# ─────────────────────────────────────────────
DEFAULT_PORT=2026
CONTAINER="3x-ui"

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

# 获取容器当前监听端口
get_port() {
    docker exec "$CONTAINER" netstat -tlnp 2>/dev/null \
        | grep x-ui \
        | grep -o ":[0-9]*" \
        | grep -o "[0-9]*" \
        | head -1
}

# 检测 docker compose 命令 (兼容新旧版本)
docker_compose() {
    if docker compose version &>/dev/null; then
        docker compose "$@"
    else
        docker-compose "$@"
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

# 在容器内执行 /app/x-ui 命令
# 用法：cli [子命令] [参数...]
# 无参数时显示 x-ui 自身帮助信息
cli() {
    is_running || { printf '%b\n' "${RED}❌ 容器未运行，请先执行 start${NC}"; return 1; }
    docker exec "$CONTAINER" /app/x-ui "$@"
}

# ─────────────────────────────────────────────
# 核心命令
# ─────────────────────────────────────────────

# 启动服务
start() {
    local port=${1:-$DEFAULT_PORT}
    validate_port "$port" || return 1

    printf '%b\n' "${CYAN}🚀 启动 3x-ui，面板端口: ${BOLD}$port${NC}"
    docker_compose down && docker_compose up -d || { printf '%b\n' "${RED}❌ 容器启动失败${NC}"; return 1; }

    printf '%b\n' "${YELLOW}⏳ 等待服务就绪...${NC}"
    sleep 5

    cli setting -port "$port" \
        || { printf '%b\n' "${RED}❌ 端口设置失败${NC}"; return 1; }
    docker restart "$CONTAINER"
    sleep 3

    local ip
    ip=$(get_ip)
    printf '%b\n' "${GREEN}✅ 启动完成: ${BOLD}http://$ip:$port/panel${NC}"
}

# 停止服务
stop() {
    printf '%b\n' "${CYAN}🛑 停止 3x-ui...${NC}"
    docker_compose down && printf '%b\n' "${GREEN}✅ 已停止${NC}"
}

# 重启服务 (保留当前端口)
restart() {
    local port=${1:-$(get_port)}
    [ -z "$port" ] && port=$DEFAULT_PORT
    start "$port"
}

# 查看运行状态
status() {
    if is_running; then
        local port ip
        port=$(get_port)
        ip=$(get_ip)
        printf '%b\n' "${GREEN}✅ 状态: 运行中${NC}"
        printf '%b\n' "   ${BLUE}📍 端口:${NC} ${port:-未知}"
        printf '%b\n' "   ${BLUE}🌐 IP:${NC}   $ip"
        printf '%b\n' "   ${BLUE}🔗 地址:${NC} http://$ip:${port:-?}/panel"
    else
        printf '%b\n' "${RED}❌ 状态: 未运行${NC}"
    fi
}

# 查看或修改面板端口
set_port() {
    if [ -z "$1" ]; then
        local current
        current=$(get_port)
        printf '%b\n' "${BLUE}📍 当前端口: ${BOLD}${current:-未知}${NC}"
        return 0
    fi

    validate_port "$1" || return 1
    is_running || { printf '%b\n' "${RED}❌ 容器未运行，请先执行 start${NC}"; return 1; }

    printf '%b\n' "${CYAN}🔧 设置端口为: $1${NC}"
    cli setting -port "$1" \
        || { printf '%b\n' "${RED}❌ 端口设置失败${NC}"; return 1; }
    docker restart "$CONTAINER"
    printf '%b\n' "${GREEN}✅ 端口已更新为: ${BOLD}$1${NC}"
}

# 重置端口为默认值
reset_port() {
    printf '%b\n' "${CYAN}🔄 重置端口为默认值: ${BOLD}$DEFAULT_PORT${NC}"
    set_port "$DEFAULT_PORT"
}

# 拉取最新镜像并重启
update() {
    printf '%b\n' "${CYAN}⬆️  拉取最新镜像...${NC}"
    docker_compose pull || { printf '%b\n' "${RED}❌ 镜像拉取失败${NC}"; return 1; }

    local port
    port=$(get_port)
    [ -z "$port" ] && port=$DEFAULT_PORT

    printf '%b\n' "${CYAN}🔄 重启服务 (端口: $port)...${NC}"
    start "$port"
    printf '%b\n' "${GREEN}✅ 更新完成${NC}"
}

# 透传 x-ui 子命令（直接调用容器内 /app/x-ui）
# 用法：./3xui.sh cli [子命令] [参数...]
# 示例：./3xui.sh cli setting -show
#        ./3xui.sh cli (无参数，显示 x-ui 帮助)
run_cli() {
    cli "$@"
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

# 显示帮助信息
show_help() {
    printf '%b\n' "${BOLD}用法: $0 <命令> [参数]${NC}"
    printf '\n'
    printf '%b\n' "${BOLD}命令列表:${NC}"
    # 命令名手动补空格对齐 (目标显示宽度 16，中文字符显示宽度 2 但占 3 字节)
    printf "  ${GREEN}%s${NC} %s\n" "start [端口]   " "启动服务 (默认端口 $DEFAULT_PORT)"
    printf "  ${GREEN}%s${NC} %s\n" "stop           " "停止服务"
    printf "  ${GREEN}%s${NC} %s\n" "restart [端口] " "重启服务 (默认保留当前端口)"
    printf "  ${GREEN}%s${NC} %s\n" "status         " "查看运行状态"
    printf "  ${GREEN}%s${NC} %s\n" "port [端口]    " "查看或修改面板端口"
    printf "  ${GREEN}%s${NC} %s\n" "reset-port     " "重置端口为默认值 ($DEFAULT_PORT)"
    printf "  ${GREEN}%s${NC} %s\n" "update         " "拉取最新镜像并重启"
    printf "  ${GREEN}%s${NC} %s\n" "cli [命令]     " "在容器内执行 x-ui 命令 (无参数显示 x-ui 帮助)"
    printf "  ${GREEN}%s${NC} %s\n" "shell          " "进入容器交互式终端"
    printf "  ${GREEN}%s${NC} %s\n" "logs           " "查看容器日志 (实时)"
    printf "  ${GREEN}%s${NC} %s\n" "ip             " "显示公网 IP"
    printf "  ${GREEN}%s${NC} %s\n" "help           " "显示此帮助信息"
}

# ─────────────────────────────────────────────
# 入口分发
# ─────────────────────────────────────────────
case "${1:-help}" in
    start)      start "$2"      ;;
    stop)       stop            ;;
    restart)    restart "$2"    ;;
    status)     status          ;;
    port)       set_port "$2"   ;;
    reset-port) reset_port      ;;
    update)     update          ;;
    cli)        run_cli "${@:2}"  ;;
    shell)      shell           ;;
    logs)       logs            ;;
    ip)         show_ip         ;;
    help|*)     show_help       ;;
esac