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
# 脚本目录（追踪软链接，兼容 Linux / macOS）
# ─────────────────────────────────────────────
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

# ─────────────────────────────────────────────
# 常量配置
# ─────────────────────────────────────────────
DEFAULT_PORT=2026
CONTAINER="3x-ui"

# 数据目录（db、cert 等运行时数据）
DATA_DIR="${LIBRE_DATA_DIR:-/usr/local/app/libre/xray}"

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
    local ip raw
    for service in "ip.sb" "icanhazip.com" "ifconfig.me" "api.ipify.org"; do
        raw=$(curl -s4 --connect-timeout 5 "$service" 2>/dev/null)
        # 提取纯 IPv4 地址，过滤特殊符号
        ip=$(echo "$raw" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        # 过滤私有地址段：10.x、172.16-31.x、192.168.x
        if [ -n "$ip" ] && ! echo "$ip" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'; then
            echo "$ip"
            return 0
        fi
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
# 始终以 SCRIPT_DIR 为项目目录执行，挂载路径由 docker-compose.yaml 中的 LIBRE_DATA_DIR 环境变量控制
docker_compose() {
    local compose_file="$SCRIPT_DIR/docker-compose.yaml"
    if docker compose version &>/dev/null; then
        docker compose -f "$compose_file" --project-directory "$SCRIPT_DIR" "$@"
    else
        docker-compose -f "$compose_file" --project-directory "$SCRIPT_DIR" "$@"
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

# 从 .env 文件读取用户名和密码并重置面板登录凭据
# 支持交互式修改并保存到 .env 文件
reset_credentials() {
    local env_file
    env_file="$SCRIPT_DIR/.env"  # .env 属于脚本配置，保留在脚本目录

    # 如果 .env 文件不存在，创建默认文件
    if [ ! -f "$env_file" ]; then
        printf '%b\n' "${YELLOW}⚠️  未找到 .env 文件，创建默认配置...${NC}"
        cat > "$env_file" << EOF
# 3x-ui 登录凭据配置
# 修改后执行 reset-creds 命令生效

# 面板登录用户名
XUI_USERNAME=admin

# 面板登录密码（建议修改为强密码）
XUI_PASSWORD=admin123
EOF
        printf '%b\n' "${GREEN}✅ 已创建默认 .env 配置文件：$env_file${NC}"
    fi

    # 读取当前凭据
    local current_username current_password
    current_username=$(grep -E '^XUI_USERNAME=' "$env_file" | cut -d'=' -f2- | tr -d '\r')
    current_password=$(grep -E '^XUI_PASSWORD=' "$env_file" | cut -d'=' -f2- | tr -d '\r')

    [ -n "$current_username" ] || { printf '%b\n' "${RED}❌ .env 中未找到 XUI_USERNAME${NC}"; return 1; }
    [ -n "$current_password" ] || { printf '%b\n' "${RED}❌ .env 中未找到 XUI_PASSWORD${NC}"; return 1; }

    printf '%b\n' "${CYAN}🔧 当前登录凭据配置${NC}"
    printf '%b\n' "   ${BLUE}👤 用户名:${NC} $current_username"
    printf '%b\n' "   ${BLUE}🔑 密码:${NC} ${current_password:0:3}****${current_password: -3}"
    printf '%b\n' ""

    # 询问是否修改凭据
    printf '%b\n' "${BLUE}是否修改登录凭据？${NC}"
    printf '%b\n' "   ${GREEN}1${NC}) 使用当前凭据（直接重置）"
    printf '%b\n' "   ${GREEN}2${NC}) 修改用户名和密码"
    printf '%b\n' "   ${GREEN}3${NC}) 仅修改密码"
    printf '%b\n' "   ${RED}0${NC}) 取消操作"
    printf '%b\n' ""

    local choice
    printf '%b\n' "${BLUE}请选择操作 [1-3, 0取消]:${NC}"
    read -r choice

    local username="$current_username"
    local password="$current_password"

    case "$choice" in
        1)
            # 使用当前凭据
            printf '%b\n' "${CYAN}✅ 使用当前凭据进行重置...${NC}"
            ;;
        2)
            # 修改用户名和密码
            printf '%b\n' "${CYAN}🔧 修改用户名和密码${NC}"
            
            # 交互式输入新用户名
            printf '%b\n' "${BLUE}请输入新的用户名 [当前: $current_username]:${NC}"
            read -r input_username
            if [ -n "$input_username" ]; then
                if [[ "$input_username" =~ ^[a-zA-Z0-9_-]+$ ]] && [ ${#input_username} -ge 3 ]; then
                    username="$input_username"
                else
                    printf '%b\n' "${YELLOW}⚠️  用户名无效（仅允许字母、数字、下划线、减号，长度≥3），使用原用户名${NC}"
                fi
            fi
            
            # 交互式输入新密码
            printf '%b\n' "${BLUE}请输入新的密码 [当前: ****]:${NC}"
            read -r -s input_password
            printf '%b\n' ""
            if [ -n "$input_password" ]; then
                if [ ${#input_password} -ge 6 ]; then
                    password="$input_password"
                else
                    printf '%b\n' "${YELLOW}⚠️  密码长度不足（至少6位），使用原密码${NC}"
                fi
            fi
            
            # 更新 .env 文件
            update_env_file "$env_file" "$username" "$password"
            ;;
        3)
            # 仅修改密码
            printf '%b\n' "${CYAN}🔧 仅修改密码${NC}"
            
            printf '%b\n' "${BLUE}请输入新的密码 [当前: ****]:${NC}"
            read -r -s input_password
            printf '%b\n' ""
            if [ -n "$input_password" ]; then
                if [ ${#input_password} -ge 6 ]; then
                    password="$input_password"
                    # 更新 .env 文件
                    update_env_file "$env_file" "$username" "$password"
                else
                    printf '%b\n' "${YELLOW}⚠️  密码长度不足（至少6位），使用原密码${NC}"
                fi
            fi
            ;;
        0|*)
            printf '%b\n' "${YELLOW}❌ 操作已取消${NC}"
            return 0
            ;;
    esac

    # 重置凭据
    printf '%b\n' "${CYAN}🔑 重置登录凭据 (用户名: $username)...${NC}"
    cli setting -username "$username" -password "$password" \
        || { printf '%b\n' "${RED}❌ 凭据重置失败${NC}"; return 1; }

    docker restart "$CONTAINER"
    printf '%b\n' "${GREEN}✅ 登录凭据已更新，请使用新用户名和密码登录${NC}"
}

# 更新 .env 文件中的凭据配置
update_env_file() {
    local env_file="$1"
    local username="$2"
    local password="$3"
    
    # 备份原文件
    cp "$env_file" "$env_file.bak" 2>/dev/null
    
    # 更新文件内容
    cat > "$env_file" << EOF
# 3x-ui 登录凭据配置
# 修改后执行 reset-creds 命令生效

# 面板登录用户名
XUI_USERNAME=$username

# 面板登录密码（建议修改为强密码）
XUI_PASSWORD=$password
EOF
    
    printf '%b\n' "${GREEN}✅ 凭据配置已保存到 .env 文件${NC}"
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
    printf "  ${GREEN}%s${NC} %s\n" "reset-creds    " "从 .env 读取用户名/密码并重置登录凭据"
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
    reset-port)  reset_port        ;;
    reset-creds) reset_credentials ;;
    update)     update          ;;
    cli)        run_cli "${@:2}"  ;;
    shell)      shell           ;;
    logs)       logs            ;;
    ip)         show_ip         ;;
    help|*)     show_help       ;;
esac