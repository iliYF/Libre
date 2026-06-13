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

# 获取公网 IP，依次尝试多个服务（过滤私有地址，确保返回公网 IP）
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

# 从 .env 文件读取实际端口配置（需在 validate_port 定义后调用）
read_env_ports() {
    local env_file="$SCRIPT_DIR/.env"

    [ -f "$env_file" ] || return 0

    local api_port vpn_port
    api_port=$(grep -E '^API_PORT=' "$env_file" | cut -d'=' -f2- | tr -d '\r')
    vpn_port=$(grep -E '^VPN_PORT=' "$env_file" | cut -d'=' -f2- | tr -d '\r')

    if [ -n "$api_port" ] && validate_port "$api_port" 2>/dev/null; then
        DEFAULT_API_PORT="$api_port"
    fi
    if [ -n "$vpn_port" ] && validate_port "$vpn_port" 2>/dev/null; then
        DEFAULT_VPN_PORT="$vpn_port"
    fi
}

# 初始化时读取端口配置
read_env_ports

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
        
        # 使用 shell 脚本生成证书
        if [ -f "$SCRIPT_DIR/scripts/gen_cert.sh" ]; then
            printf '%b\n' "${CYAN}📝 使用简化版脚本生成证书...${NC}"
            if LIBRE_DATA_DIR="$DATA_DIR" bash "$SCRIPT_DIR/scripts/gen_cert.sh"; then                printf '%b\n' "${GREEN}✅ 证书生成成功${NC}"
                return 0
            else
                printf '%b\n' "${RED}❌ 证书生成失败${NC}"
            fi
        fi
        
        printf '%b\n' "${RED}❌ 证书自动生成失败，请手动将 cert.pem / key.pem 放入 $DATA_DIR/config/ 目录${NC}"
        printf '%b\n' "${YELLOW}💡 手动生成方法：openssl req -new -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650${NC}"
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────
# 核心命令
# ─────────────────────────────────────────────

# 启动服务
start() {
    # 重新读取端口配置，确保打印值与实际启动端口一致
    read_env_ports

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
    # 重新读取端口配置
    read_env_ports
    
    printf '%b\n' "${CYAN}🔄 重启 Lantern Server Manager...${NC}"
    printf '%b\n' "   ${BLUE}API 端口:${NC} ${DEFAULT_API_PORT}"
    printf '%b\n' "   ${BLUE}VPN 端口:${NC} ${DEFAULT_VPN_PORT}"
    
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

# 交互式配置端口并保存到 .env 文件
config_ports() {
    local env_file="$SCRIPT_DIR/.env"
    
    # 读取当前端口配置
    local current_api_port current_vpn_port
    current_api_port="$DEFAULT_API_PORT"
    current_vpn_port="$DEFAULT_VPN_PORT"
    
    if [ -f "$env_file" ]; then
        local temp_api_port temp_vpn_port
        temp_api_port=$(grep -E '^API_PORT=' "$env_file" | cut -d'=' -f2- | tr -d '\r')
        temp_vpn_port=$(grep -E '^VPN_PORT=' "$env_file" | cut -d'=' -f2- | tr -d '\r')
        
        [ -n "$temp_api_port" ] && current_api_port="$temp_api_port"
        [ -n "$temp_vpn_port" ] && current_vpn_port="$temp_vpn_port"
    fi
    
    printf '%b\n' "${CYAN}🔧 当前端口配置${NC}"
    printf '%b\n' "   ${BLUE}🌐 Web UI / API 端口:${NC} $current_api_port"
    printf '%b\n' "   ${BLUE}🔒 VPN 端口 (TCP):${NC} $current_vpn_port"
    printf '%b\n' ""

    # 询问是否修改端口
    printf '%b\n' "${BLUE}是否修改端口配置？${NC}"
    printf '%b\n' "   ${GREEN}1${NC}) 使用当前端口（直接重启生效）"
    printf '%b\n' "   ${GREEN}2${NC}) 修改 Web UI / API 端口"
    printf '%b\n' "   ${GREEN}3${NC}) 修改 VPN 端口"
    printf '%b\n' "   ${GREEN}4${NC}) 修改所有端口"
    printf '%b\n' "   ${RED}0${NC}) 取消操作"
    printf '%b\n' ""

    local choice
    printf '%b\n' "${BLUE}请选择操作 [1-4, 0取消]:${NC}"
    read -r choice

    local api_port="$current_api_port"
    local vpn_port="$current_vpn_port"

    case "$choice" in
        1)
            # 使用当前端口
            printf '%b\n' "${CYAN}✅ 使用当前端口配置...${NC}"
            ;;
        2)
            # 修改 API 端口
            printf '%b\n' "${CYAN}🔧 修改 Web UI / API 端口${NC}"
            printf '%b\n' "${BLUE}请输入新的 Web UI / API 端口 [当前: $current_api_port]:${NC}"
            read -r input_port
            if [ -n "$input_port" ]; then
                if validate_port "$input_port"; then
                    api_port="$input_port"
                else
                    printf '%b\n' "${YELLOW}⚠️  端口无效，使用原端口${NC}"
                fi
            fi
            ;;
        3)
            # 修改 VPN 端口
            printf '%b\n' "${CYAN}🔧 修改 VPN 端口${NC}"
            printf '%b\n' "${BLUE}请输入新的 VPN 端口 [当前: $current_vpn_port]:${NC}"
            read -r input_port
            if [ -n "$input_port" ]; then
                if validate_port "$input_port"; then
                    vpn_port="$input_port"
                else
                    printf '%b\n' "${YELLOW}⚠️  端口无效，使用原端口${NC}"
                fi
            fi
            ;;
        4)
            # 修改所有端口
            printf '%b\n' "${CYAN}🔧 修改所有端口${NC}"
            
            printf '%b\n' "${BLUE}请输入新的 Web UI / API 端口 [当前: $current_api_port]:${NC}"
            read -r input_api_port
            if [ -n "$input_api_port" ]; then
                if validate_port "$input_api_port"; then
                    api_port="$input_api_port"
                else
                    printf '%b\n' "${YELLOW}⚠️  API 端口无效，使用原端口${NC}"
                fi
            fi
            
            printf '%b\n' "${BLUE}请输入新的 VPN 端口 [当前: $current_vpn_port]:${NC}"
            read -r input_vpn_port
            if [ -n "$input_vpn_port" ]; then
                if validate_port "$input_vpn_port"; then
                    vpn_port="$input_vpn_port"
                else
                    printf '%b\n' "${YELLOW}⚠️  VPN 端口无效，使用原端口${NC}"
                fi
            fi
            ;;
        0|*)
            printf '%b\n' "${YELLOW}❌ 操作已取消${NC}"
            return 0
            ;;
    esac

    # 更新 .env 文件
    update_env_file "$env_file" "$api_port" "$vpn_port"
    
    # 重新读取端口配置
    read_env_ports
    
    printf '%b\n' "${GREEN}✅ 端口配置已保存到 .env 文件${NC}"
    printf '%b\n' "   ${BLUE}🌐 Web UI / API 端口:${NC} $api_port"
    printf '%b\n' "   ${BLUE}🔒 VPN 端口:${NC} $vpn_port"
    printf '%b\n' "${YELLOW}📝 重启服务后新配置生效${NC}"
}

# 更新 .env 文件中的端口配置
update_env_file() {
    local env_file="$1"
    local api_port="$2"
    local vpn_port="$3"
    
    # 备份原文件
    cp "$env_file" "$env_file.bak" 2>/dev/null
    
    # 更新文件内容
    cat > "$env_file" << EOF
# Lantern Server Manager 端口配置
# Web UI / REST API 端口（宿主机端口）
API_PORT=$api_port

# VPN 端口（宿主机 UDP 端口）
VPN_PORT=$vpn_port
EOF
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

# 健康探测
health_check() {
    read_env_ports
    local ip
    ip=$(get_ip)
    local url="https://$ip:${DEFAULT_API_PORT}/api/v1/health"

    printf '%b\n' "${CYAN}🏥 健康探测: $url${NC}"

    local http_code
    http_code=$(curl -sk -o /dev/null -w '%{http_code}' \
        --connect-timeout 10 --max-time 15 "$url" 2>/dev/null)

    if [ "$http_code" = "200" ]; then
        printf '%b\n' "${GREEN}✅ 服务健康 (HTTP $http_code)${NC}"
        return 0
    elif [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
        printf '%b\n' "${RED}❌ 连接失败，服务可能未启动或端口不通${NC}"
        return 1
    else
        printf '%b\n' "${YELLOW}⚠️  服务响应异常 (HTTP $http_code)${NC}"
        return 1
    fi
}

# 从指定目录导入证书文件（替换 cert.pem / key.pem，替换前备份）
#
# 查找策略：
#   1. 精确文件名匹配：cert.pem / key.pem，匹配到直接使用
#   2. 未匹配时扫描目录下所有 .pem / .key 后缀文件，用 openssl 读取 PEM 头识别类型：
#      - 包含 CERTIFICATE → 证书候选
#      - 包含 PRIVATE KEY  → 私钥候选
#      候选唯一时自动使用，多个时列出让用户选择
cert_update() {
    local src_dir="${1:-}"

    # 未传参时交互式输入
    if [ -z "$src_dir" ]; then
        printf '%b\n' "${CYAN}📂 请输入证书文件所在目录路径：${NC}"
        read -r src_dir
    fi

    # 去除末尾斜杠
    src_dir="${src_dir%/}"

    if [ -z "$src_dir" ]; then
        printf '%b\n' "${RED}❌ 目录路径不能为空${NC}"
        return 1
    fi

    if [ ! -d "$src_dir" ]; then
        printf '%b\n' "${RED}❌ 目录不存在：$src_dir${NC}"
        return 1
    fi

    local src_cert="" src_key=""

    # ── 第一步：精确文件名匹配 ──────────────────
    [ -f "$src_dir/cert.pem" ] && src_cert="$src_dir/cert.pem"
    [ -f "$src_dir/key.pem"  ] && src_key="$src_dir/key.pem"

    # ── 第二步：后缀扫描 + 内容识别（仅在精确匹配缺失时触发）──
    if [ -z "$src_cert" ] || [ -z "$src_key" ]; then
        if ! command -v openssl &>/dev/null; then
            printf '%b\n' "${RED}❌ 未安装 openssl，无法识别证书类型${NC}"
            return 1
        fi

        local cert_candidates=() key_candidates=()
        while IFS= read -r -d '' f; do
            local header
            header=$(head -1 "$f" 2>/dev/null)
            case "$header" in
                *CERTIFICATE*)
                    cert_candidates+=("$f")
                    ;;
                *PRIVATE\ KEY*)
                    key_candidates+=("$f")
                    ;;
            esac
        done < <(find "$src_dir" -maxdepth 1 \( -name "*.pem" -o -name "*.key" \) -type f -print0 2>/dev/null)

        # 证书候选处理
        if [ -z "$src_cert" ]; then
            if [ "${#cert_candidates[@]}" -eq 0 ]; then
                printf '%b\n' "${RED}❌ 未找到证书文件（目录下无包含 CERTIFICATE 的 .pem/.key 文件）${NC}"
                return 1
            elif [ "${#cert_candidates[@]}" -eq 1 ]; then
                src_cert="${cert_candidates[0]}"
                printf '%b\n' "${CYAN}🔍 证书文件：$(basename "$src_cert")${NC}"
            else
                printf '%b\n' "${CYAN}🔍 找到多个证书文件，请选择：${NC}"
                local i=1
                for f in "${cert_candidates[@]}"; do
                    printf "  ${GREEN}%d)${NC} %s\n" "$i" "$(basename "$f")"
                    i=$((i + 1))
                done
                printf '%b' "  请输入序号 [1-${#cert_candidates[@]}]： "
                read -r _idx
                if [[ "$_idx" =~ ^[0-9]+$ ]] && [ "$_idx" -ge 1 ] && [ "$_idx" -le "${#cert_candidates[@]}" ]; then
                    src_cert="${cert_candidates[$((_idx - 1))]}"
                else
                    printf '%b\n' "${RED}❌ 无效选择${NC}"
                    return 1
                fi
            fi
        fi

        # 私钥候选处理
        if [ -z "$src_key" ]; then
            if [ "${#key_candidates[@]}" -eq 0 ]; then
                printf '%b\n' "${RED}❌ 未找到私钥文件（目录下无包含 PRIVATE KEY 的 .pem/.key 文件）${NC}"
                return 1
            elif [ "${#key_candidates[@]}" -eq 1 ]; then
                src_key="${key_candidates[0]}"
                printf '%b\n' "${CYAN}🔍 私钥文件：$(basename "$src_key")${NC}"
            else
                printf '%b\n' "${CYAN}🔍 找到多个私钥文件，请选择：${NC}"
                local i=1
                for f in "${key_candidates[@]}"; do
                    printf "  ${GREEN}%d)${NC} %s\n" "$i" "$(basename "$f")"
                    i=$((i + 1))
                done
                printf '%b' "  请输入序号 [1-${#key_candidates[@]}]： "
                read -r _idx
                if [[ "$_idx" =~ ^[0-9]+$ ]] && [ "$_idx" -ge 1 ] && [ "$_idx" -le "${#key_candidates[@]}" ]; then
                    src_key="${key_candidates[$((_idx - 1))]}"
                else
                    printf '%b\n' "${RED}❌ 无效选择${NC}"
                    return 1
                fi
            fi
        fi
    fi

    local dest_dir="$DATA_DIR/config"
    mkdir -p "$dest_dir"

    local dest_cert="$dest_dir/cert.pem"
    local dest_key="$dest_dir/key.pem"
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')

    # 备份已有证书
    if [ -f "$dest_cert" ]; then
        cp "$dest_cert" "${dest_cert}.bak.${ts}"
        printf '%b\n' "${YELLOW}📦 已备份旧证书：${dest_cert}.bak.${ts}${NC}"
    fi
    if [ -f "$dest_key" ]; then
        cp "$dest_key" "${dest_key}.bak.${ts}"
        printf '%b\n' "${YELLOW}📦 已备份旧私钥：${dest_key}.bak.${ts}${NC}"
    fi

    # 复制新证书
    cp "$src_cert" "$dest_cert" || { printf '%b\n' "${RED}❌ 复制 cert.pem 失败${NC}"; return 1; }
    cp "$src_key"  "$dest_key"  || { printf '%b\n' "${RED}❌ 复制 key.pem 失败${NC}"; return 1; }

    printf '%b\n' "${GREEN}✅ 证书已更新到 $dest_dir${NC}"
    printf '%b\n' "   ${BLUE}cert.pem${NC} ← $src_cert"
    printf '%b\n' "   ${BLUE}key.pem${NC}  ← $src_key"
    printf '\n'

    # 询问是否重启容器
    printf '%b' "${CYAN}是否立即重启容器使证书生效？[y/N]：${NC} "
    read -r _restart
    case "$_restart" in
        y|Y)
            restart
            ;;
        *)
            printf '%b\n' "${YELLOW}💡 证书已替换，请手动执行 restart 使其生效${NC}"
            ;;
    esac
}

# 生成自签名证书（简化版，使用 openssl）
gen_cert_sh() {
    mkdir -p "$DATA_DIR/config"
    if [ -f "$SCRIPT_DIR/scripts/gen_cert.sh" ]; then
        LIBRE_DATA_DIR="$DATA_DIR" bash "$SCRIPT_DIR/scripts/gen_cert.sh" \
            && printf '%b\n' "${GREEN}✅ 证书已生成到 $DATA_DIR/config/ 目录${NC}" \
            || printf '%b\n' "${RED}❌ 证书生成失败${NC}"
    else
        printf '%b\n' "${RED}❌ 未找到 gen_cert.sh${NC}"
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
    printf "  ${GREEN}%s${NC} %s\n" "cert-gen        " "生成自签名证书（使用 openssl）"
    printf "  ${GREEN}%s${NC} %s\n" "cert-update [目录]" "从指定目录导入 cert.pem / key.pem（替换前自动备份）"
    printf "  ${GREEN}%s${NC} %s\n" "shell           " "进入容器交互式终端"
    printf "  ${GREEN}%s${NC} %s\n" "logs       " "查看容器日志（实时）"
    printf "  ${GREEN}%s${NC} %s\n" "ip         " "显示公网 IP"
    printf "  ${GREEN}%s${NC} %s\n" "health     " "健康探测（检查 API /health 接口）"
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
    start)           start           ;;
    stop)            stop            ;;
    restart)         restart         ;;
    status)          status          ;;
    update)          update          ;;
    cert-gen)        gen_cert_sh     ;;
    cert-update)     cert_update "${2:-}" ;;
    shell)           shell           ;;
    logs)            logs            ;;
    ip)              show_ip         ;;
    health)          health_check    ;;
    help|*)          show_help       ;;
esac
