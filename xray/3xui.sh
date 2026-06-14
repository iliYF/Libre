#!/bin/bash
# 3x-ui 管理脚本 v3.1
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

# 从 .env 读取配置值
# 用法：read_env <KEY> [默认值]
read_env() {
    local key="$1"
    local default="${2:-}"
    local env_file="$DATA_DIR/.env"
    local val
    val=$(grep -E "^${key}=" "$env_file" 2>/dev/null | cut -d'=' -f2- | tr -d '\r')
    echo "${val:-$default}"
}

# 初始化 .env 配置（首次启动时引导用户设置端口和凭据）
# 密码为必填项，不允许为空；WebBasePath 为可选项
_init_env() {
    local env_file="$DATA_DIR/.env"

    # 读取已有配置（.env 存在时）
    local cur_port cur_username cur_password cur_web_base_path
    cur_port=$(read_env "XUI_PORT" "")
    cur_username=$(read_env "XUI_USERNAME" "")
    cur_password=$(read_env "XUI_PASSWORD" "")
    cur_web_base_path=$(read_env "XUI_WEB_BASE_PATH" "")

    # 端口、用户名、密码均已配置且密码非空时：
    # - WebBasePath 也已设置（含主动设为空的 skip 情况除外）→ 直接返回
    # - WebBasePath 尚未写入 .env → 仅补充询问 WebBasePath
    if [ -n "$cur_port" ] && [ -n "$cur_username" ] && [ -n "$cur_password" ]; then
        # 检查 .env 中是否存在 XUI_WEB_BASE_PATH 这一行（无论值是否为空）
        if grep -qE '^XUI_WEB_BASE_PATH=' "$env_file" 2>/dev/null; then
            return 0
        fi
        # WebBasePath 行不存在，补充询问
        printf '%b\n' "${CYAN}🔧 补充配置 WebBasePath${NC}"
        local rand_path
        rand_path=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 7)
        local default_web_base_path="/${rand_path}"
        local web_base_path=""
        printf '%b\n' "${BLUE}面板 WebBasePath（可选）:${NC}"
        printf '%b\n' "   回车使用默认值 ${BOLD}${default_web_base_path}${NC}，输入自定义路径，或输入 ${BOLD}skip${NC} 跳过不设置"
        printf '%b' "   > "
        read -r input_web_base_path
        if [ -z "$input_web_base_path" ]; then
            web_base_path="$default_web_base_path"
        elif [ "$input_web_base_path" = "skip" ]; then
            web_base_path=""
        else
            web_base_path="$input_web_base_path"
        fi
        _save_env "$env_file" "$cur_port" "$cur_username" "$cur_password" "$web_base_path"
        return 0
    fi

    printf '%b\n' "${CYAN}🔧 首次启动，请完成初始化配置${NC}"
    printf '%b\n' "   ${YELLOW}⚠️  镜像默认密码随机生成，必须手动设置后才能登录${NC}"
    printf '%b\n' ""

    # 端口
    local port="${cur_port:-$DEFAULT_PORT}"
    printf '%b' "${BLUE}面板端口 [默认: $port]: ${NC}"
    read -r input_port
    if [ -n "$input_port" ]; then
        if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1024 ] && [ "$input_port" -le 65535 ]; then
            port="$input_port"
        else
            printf '%b\n' "${YELLOW}⚠️  端口无效，使用默认值: $port${NC}"
        fi
    fi

    # 用户名
    local username="${cur_username:-admin}"
    printf '%b' "${BLUE}登录用户名 [默认: $username]: ${NC}"
    read -r input_username
    if [ -n "$input_username" ]; then
        if [[ "$input_username" =~ ^[a-zA-Z0-9_-]+$ ]] && [ ${#input_username} -ge 3 ]; then
            username="$input_username"
        else
            printf '%b\n' "${YELLOW}⚠️  用户名无效，使用默认值: $username${NC}"
        fi
    fi

    # 密码（必填，循环直到输入非空）
    local password=""
    while [ -z "$password" ]; do
        printf '%b' "${BLUE}登录密码 (建议8位以上，含字母、数字和特殊符号，必填): ${NC}"
        read -r -s input_password
        printf '\n'
        if [ -z "$input_password" ]; then
            printf '%b\n' "${RED}❌ 密码不能为空${NC}"
        else
            password="$input_password"
        fi
    done

    # WebBasePath（可选，随机生成默认值）
    local rand_path
    rand_path=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 7)
    local default_web_base_path="/${rand_path}"
    local web_base_path="${cur_web_base_path:-}"
    printf '%b\n' "${BLUE}面板 WebBasePath（可选）:${NC}"
    printf '%b\n' "   回车使用默认值 ${BOLD}${default_web_base_path}${NC}，输入自定义路径，或输入 ${BOLD}skip${NC} 跳过不设置"
    printf '%b' "   > "
    read -r input_web_base_path
    if [ -z "$input_web_base_path" ]; then
        web_base_path="$default_web_base_path"
    elif [ "$input_web_base_path" = "skip" ]; then
        web_base_path=""
    else
        web_base_path="$input_web_base_path"
    fi

    # 保存到 .env
    _save_env "$env_file" "$port" "$username" "$password" "$web_base_path"
    printf '%b\n' ""
}

# ─────────────────────────────────────────────
# 核心命令
# ─────────────────────────────────────────────

# 启动服务
# 用法：start [端口] [用户名] [密码]
# 端口优先级：命令行参数 > .env 中 XUI_PORT > DEFAULT_PORT
# 凭据优先级：命令行参数 > .env > 交互式引导（.env 不存在或密码为空时）
start() {
    local port="${1:-}"
    local arg_username="${2:-}"
    local arg_password="${3:-}"

    # 命令行传入凭据时，直接保存到 .env，跳过交互式引导
    if [ -n "$arg_username" ] && [ -n "$arg_password" ]; then
        local cur_web_base_path
        cur_web_base_path=$(read_env "XUI_WEB_BASE_PATH" "")
        _save_env "$DATA_DIR/.env" "${port:-$DEFAULT_PORT}" "$arg_username" "$arg_password" "$cur_web_base_path"
    else
        # 确保 .env 存在且密码已设置，否则交互式引导
        _init_env
    fi

    # 解析端口：命令行参数 > .env > DEFAULT_PORT
    if [ -z "$port" ]; then
        port=$(read_env "XUI_PORT" "$DEFAULT_PORT")
    fi
    validate_port "$port" || return 1

    # 读取凭据和 WebBasePath（此时 .env 必然已存在且有效）
    local username password web_base_path
    username=$(read_env "XUI_USERNAME" "admin")
    password=$(read_env "XUI_PASSWORD" "")
    web_base_path=$(read_env "XUI_WEB_BASE_PATH" "")

    printf '%b\n' "${CYAN}🚀 启动 3x-ui，面板端口: ${BOLD}$port${NC}"
    _pull_down_up || return 1

    # 轮询等待容器就绪（最多 30 秒）
    printf '%b' "${YELLOW}⏳ 等待服务就绪"
    local waited=0
    while ! is_running; do
        if [ "$waited" -ge 30 ]; then
            printf '\n'
            printf '%b\n' "${RED}❌ 容器启动超时，请检查日志：$0 logs${NC}"
            return 1
        fi
        printf '%b' "."
        sleep 1
        waited=$((waited + 1))
    done
    printf '\n'

    # 设置端口
    cli setting -port "$port" \
        || { printf '%b\n' "${RED}❌ 端口设置失败${NC}"; return 1; }

    # 设置凭据
    printf '%b\n' "${CYAN}🔑 应用登录凭据 (用户名: $username)...${NC}"
    cli setting -username "$username" -password "$password" \
        || printf '%b\n' "${YELLOW}⚠️  凭据设置失败，请手动执行：$0 creds${NC}"

    # 设置 WebBasePath（可选）
    if [ -n "$web_base_path" ]; then
        printf '%b\n' "${CYAN}🔧 设置 WebBasePath: $web_base_path${NC}"
        cli setting -webBasePath "$web_base_path" \
            || printf '%b\n' "${YELLOW}⚠️  WebBasePath 设置失败，请手动执行：$0 web-path${NC}"
    fi

    docker restart "$CONTAINER"

    # 轮询等待重启完成（最多 20 秒）
    printf '%b' "${YELLOW}⏳ 等待重启完成"
    waited=0
    while ! is_running; do
        if [ "$waited" -ge 20 ]; then
            printf '\n'
            printf '%b\n' "${RED}❌ 容器重启超时，请检查日志：$0 logs${NC}"
            return 1
        fi
        printf '%b' "."
        sleep 1
        waited=$((waited + 1))
    done
    printf '\n'

    printf '%b\n' "${GREEN}✅ 启动完成${NC}"
    printf '%b\n' ""
    printf '%b\n' "${BOLD}登录信息:${NC}"
    printf '%b\n' "   ${BLUE}👤 用户名:${NC} $username"
    printf '%b\n' "   ${BLUE}🔑 密码:${NC}   $password"
    local access_path="${web_base_path:-/}"
    local host_ip
    host_ip=$(get_ip)
    printf '%b\n' "   ${BLUE}🌐 访问地址:${NC} http://${host_ip}:${port}${access_path}"
}
# 停止服务
stop() {
    printf '%b\n' "${CYAN}🛑 停止 3x-ui...${NC}"
    docker_compose down && printf '%b\n' "${GREEN}✅ 已停止${NC}"
}

# 重启服务（保留当前端口，重新应用 .env 凭据）
# 用法：restart [端口] [用户名] [密码]
restart() {
    local port="${1:-$(get_port)}"
    [ -z "$port" ] && port=$(read_env "XUI_PORT" "$DEFAULT_PORT")
    start "$port" "${2:-}" "${3:-}"
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
# 用法：
#   port          — 查看当前端口
#   port <端口>   — 修改端口并立即生效
port_cmd() {
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

# 查看或修改面板 WebBasePath
# 用法：
#   web-path              — 查看当前 WebBasePath
#   web-path <路径>       — 修改 WebBasePath 并立即生效
#   web-path ""           — 清除 WebBasePath
web_path_cmd() {
    if [ "$#" -eq 0 ]; then
        local current
        current=$(read_env "XUI_WEB_BASE_PATH" "")
        if [ -n "$current" ]; then
            printf '%b\n' "${BLUE}🔗 当前 WebBasePath: ${BOLD}$current${NC}"
        else
            printf '%b\n' "${BLUE}🔗 当前 WebBasePath: ${BOLD}（未设置）${NC}"
        fi
        return 0
    fi

    local new_path="$1"
    is_running || { printf '%b\n' "${RED}❌ 容器未运行，请先执行 start${NC}"; return 1; }

    if [ -n "$new_path" ]; then
        printf '%b\n' "${CYAN}🔧 设置 WebBasePath 为: $new_path${NC}"
        cli setting -webBasePath "$new_path" \
            || { printf '%b\n' "${RED}❌ WebBasePath 设置失败${NC}"; return 1; }
    else
        printf '%b\n' "${CYAN}🔧 清除 WebBasePath...${NC}"
        cli setting -webBasePath "" \
            || { printf '%b\n' "${RED}❌ WebBasePath 清除失败${NC}"; return 1; }
    fi

    # 同步保存到 .env
    local env_file="$DATA_DIR/.env"
    local port username password
    port=$(read_env "XUI_PORT" "$DEFAULT_PORT")
    username=$(read_env "XUI_USERNAME" "admin")
    password=$(read_env "XUI_PASSWORD" "")
    _save_env "$env_file" "$port" "$username" "$password" "$new_path"

    docker restart "$CONTAINER"
    if [ -n "$new_path" ]; then
        printf '%b\n' "${GREEN}✅ WebBasePath 已更新为: ${BOLD}$new_path${NC}"
    else
        printf '%b\n' "${GREEN}✅ WebBasePath 已清除${NC}"
    fi
}

# 管理登录凭据
# 用法：
#   creds                    — 交互式修改用户名和密码（保存到 .env）
#   creds <用户名> <密码>    — 直接设置（非交互式，适合脚本调用）
creds_cmd() {
    local env_file="$DATA_DIR/.env"

    # ── 非交互式：直接传参设置 ──────────────────
    if [ -n "$1" ]; then
        local username="$1"
        local password="${2:-}"

        [ -z "$password" ] && { printf '%b\n' "${RED}❌ 用法: creds <用户名> <密码>${NC}"; return 1; }

        if ! [[ "$username" =~ ^[a-zA-Z0-9_-]+$ ]] || [ ${#username} -lt 3 ]; then
            printf '%b\n' "${RED}❌ 用户名无效（仅允许字母、数字、下划线、减号，长度≥3）${NC}"
            return 1
        fi
        if [ -z "$password" ]; then
            printf '%b\n' "${RED}❌ 密码不能为空${NC}"
            return 1
        fi

        printf '%b\n' "${CYAN}🔑 设置登录凭据 (用户名: $username)...${NC}"
        cli setting -username "$username" -password "$password" \
            || { printf '%b\n' "${RED}❌ 凭据设置失败${NC}"; return 1; }
        docker restart "$CONTAINER"

        # 同步保存到 .env（保留端口和 WebBasePath）
        local port web_base_path
        port=$(read_env "XUI_PORT" "$DEFAULT_PORT")
        web_base_path=$(read_env "XUI_WEB_BASE_PATH" "")
        _save_env "$env_file" "$port" "$username" "$password" "$web_base_path"
        printf '%b\n' "${GREEN}✅ 登录凭据已设置${NC}"
        return 0
    fi

    # ── 交互式修改 ──────────────────────────────
    # 初始化 .env（不存在时创建）
    if [ ! -f "$env_file" ]; then
        printf '%b\n' "${YELLOW}⚠️  未找到 .env 文件，创建默认配置...${NC}"
        _save_env "$env_file" "$DEFAULT_PORT" "admin" "admin123" ""
    fi

    local current_username current_password
    current_username=$(read_env "XUI_USERNAME" "admin")
    current_password=$(read_env "XUI_PASSWORD" "admin123")

    printf '%b\n' "${CYAN}🔧 修改登录凭据${NC}"
    printf '%b\n' "   ${BLUE}👤 当前用户名:${NC} $current_username"
    printf '%b\n' "   ${BLUE}🔑 当前密码:${NC}   ${current_password:0:2}****"
    printf '%b\n' ""

    # 输入新用户名
    local username="$current_username"
    printf '%b' "${BLUE}新用户名 [回车保留 $current_username]: ${NC}"
    read -r input_username
    if [ -n "$input_username" ]; then
        if [[ "$input_username" =~ ^[a-zA-Z0-9_-]+$ ]] && [ ${#input_username} -ge 3 ]; then
            username="$input_username"
        else
            printf '%b\n' "${YELLOW}⚠️  用户名无效，保留原值${NC}"
        fi
    fi

    # 输入新密码
    local password="$current_password"
    printf '%b' "${BLUE}新密码 (建议8位以上，含字母、数字和特殊符号) [回车保留原密码]: ${NC}"
    read -r -s input_password
    printf '\n'
    if [ -n "$input_password" ]; then
        password="$input_password"
    fi

    # 无变化时直接退出
    if [ "$username" = "$current_username" ] && [ "$password" = "$current_password" ]; then
        printf '%b\n' "${YELLOW}ℹ️  凭据未变更${NC}"
        return 0
    fi

    printf '%b\n' "${CYAN}🔑 应用新凭据 (用户名: $username)...${NC}"
    cli setting -username "$username" -password "$password" \
        || { printf '%b\n' "${RED}❌ 凭据设置失败${NC}"; return 1; }
    docker restart "$CONTAINER"

    # 保留端口和 WebBasePath
    local port web_base_path
    port=$(read_env "XUI_PORT" "$DEFAULT_PORT")
    web_base_path=$(read_env "XUI_WEB_BASE_PATH" "")
    _save_env "$env_file" "$port" "$username" "$password" "$web_base_path"
    printf '%b\n' "${GREEN}✅ 登录凭据已更新${NC}"
}

# 保存所有配置到 .env 文件（内部函数）
# 用法：_save_env <env_file> <port> <username> <password> <web_base_path>
_save_env() {
    local env_file="$1"
    local port="$2"
    local username="$3"
    local password="$4"
    local web_base_path="$5"

    # 备份原文件
    [ -f "$env_file" ] && cp "$env_file" "${env_file}.bak" 2>/dev/null

    cat > "$env_file" << EOF
# 3x-ui 配置
# 修改后执行 restart 命令生效

# 面板端口
XUI_PORT=$port

# 面板登录用户名
XUI_USERNAME=$username

# 面板登录密码（建议修改为强密码）
XUI_PASSWORD=$password

# 面板 WebBasePath（可选，留空则不启用）
XUI_WEB_BASE_PATH=$web_base_path
EOF
    printf '%b\n' "${GREEN}✅ 配置已保存到 .env${NC}"
}

# 拉取最新镜像 → 停止旧容器 → 启动新容器（内部复用函数）
_pull_down_up() {
    printf '%b\n' "${CYAN}⬇️  拉取最新镜像...${NC}"
    docker_compose pull || { printf '%b\n' "${RED}❌ 镜像拉取失败${NC}"; return 1; }
    docker_compose down || { printf '%b\n' "${RED}❌ 停止容器失败${NC}"; return 1; }
    docker_compose up -d || { printf '%b\n' "${RED}❌ 容器启动失败${NC}"; return 1; }
}

# 拉取最新镜像并重启
update() {
    _pull_down_up || return 1
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

# 显示当前面板配置（端口、用户名、WebBasePath 等）
# x-ui setting -show 会交互式询问是否生成 SSL 证书，用 echo Y 自动确认生成
show_config() {
    is_running || { printf '%b\n' "${RED}❌ 容器未运行，请先执行 start${NC}"; return 1; }
    printf '%b\n' "${CYAN}📋 当前面板配置:${NC}"
    echo "Y" | docker exec -i "$CONTAINER" /app/x-ui setting -show
}

# 显示公网 IP
show_ip() {
    printf '%b\n' "${BLUE}🌐 公网 IP: ${BOLD}$(get_ip)${NC}"
}

# 显示帮助信息
show_help() {
    printf '%b\n' "${BOLD}用法: $0 <命令> [参数]${NC}"
    printf '\n'
    printf '%b\n' "${BOLD}服务管理:${NC}"
    printf "  ${GREEN}start [端口] [用户名] [密码]${NC}     启动服务\n"
    printf "  ${GREEN}stop${NC}                              停止服务\n"
    printf "  ${GREEN}restart [端口] [用户名] [密码]${NC}   重启服务\n"
    printf "  ${GREEN}status${NC}                            查看运行状态\n"
    printf "  ${GREEN}update${NC}                            拉取最新镜像并重启\n"
    printf '\n'
    printf '%b\n' "${BOLD}配置管理:${NC}"
    printf "  ${GREEN}port [端口]${NC}                      查看或修改面板端口（有参数则修改并立即生效）\n"
    printf "  ${GREEN}creds [用户名 密码]${NC}              管理登录凭据（无参数交互式，有参数直接设置）\n"
    printf "  ${GREEN}web-path [路径]${NC}                  查看或修改 WebBasePath（传空字符串则清除）\n"
    printf '\n'
    printf '%b\n' "${BOLD}调试工具:${NC}"
    printf "  ${GREEN}config${NC}                           查看当前面板配置\n"
    printf "  ${GREEN}logs${NC}                             查看容器日志（实时）\n"
    printf "  ${GREEN}shell${NC}                            进入容器交互式终端\n"
    printf "  ${GREEN}cli [命令]${NC}                       在容器内执行 x-ui 命令（无参数显示帮助）\n"
    printf "  ${GREEN}ip${NC}                               显示公网 IP\n"
    printf "  ${GREEN}help${NC}                             显示此帮助信息\n"
}

# ─────────────────────────────────────────────
# 入口分发
# ─────────────────────────────────────────────
case "${1:-help}" in
    start)   start "$2" "$3" "$4"    ;;
    stop)    stop                     ;;
    restart) restart "$2" "$3" "$4"  ;;
    status)  status                   ;;
    update)  update                   ;;
    port)     port_cmd "$2"            ;;
    creds)    creds_cmd "$2" "$3"     ;;
    web-path) web_path_cmd "${2-}"    ;;
    # 调试工具
    config)  show_config               ;;
    logs)    logs                     ;;
    shell)   shell                    ;;
    cli)     run_cli "${@:2}"         ;;
    ip)      show_ip                  ;;
    help|*)  show_help                ;;
esac