#!/bin/bash
# Libre 一键安装脚本
#
# 支持安装：
#   1) Lantern Server Manager — WireGuard VPN 管理面板
#   2) Xray (3x-ui)           — 多协议代理管理面板
#   3) 全部安装
#
# 本地用法：
#   bash install.sh [lantern|xray|all]
#
# 远程一键安装：
#   bash <(curl -Ls https://raw.githubusercontent.com/iliYF/Libre/main/install.sh)
#   bash <(curl -Ls https://raw.githubusercontent.com/iliYF/Libre/main/install.sh) xray

# ─────────────────────────────────────────────
# 常量
# ─────────────────────────────────────────────

# GitHub Raw 文件根地址（修改为实际地址）
RAW_BASE="https://raw.githubusercontent.com/iliYF/Libre/main"

# 安装目录（可通过环境变量覆盖）
INSTALL_DIR="${LIBRE_DIR:-/opt/libre}"

# 数据目录（运行时数据，与脚本目录分离）
LIBRE_APP_DIR="${LIBRE_APP_DIR:-/usr/local/app/libre}"

# 颜色变量 (终端不支持时自动降级)
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

print_divider() {
    printf '%b\n' "${BLUE}────────────────────────────────────────────${NC}"
}

# 检查 Docker 是否已安装并运行
check_docker() {
    if ! command -v docker &>/dev/null; then
        printf '%b\n' "${RED}❌ 未检测到 Docker，请先安装 Docker >= 20.10${NC}"
        printf '%b\n' "   安装文档：https://docs.docker.com/engine/install/"
        exit 1
    fi
    if ! docker info &>/dev/null; then
        printf '%b\n' "${RED}❌ Docker 守护进程未运行，请先启动 Docker${NC}"
        exit 1
    fi
    printf '%b\n' "${GREEN}✅ Docker 已就绪：$(docker --version)${NC}"
}

# 检查 Docker Compose 是否可用
check_docker_compose() {
    if docker compose version &>/dev/null; then
        printf '%b\n' "${GREEN}✅ Docker Compose 已就绪：$(docker compose version)${NC}"
    elif command -v docker-compose &>/dev/null; then
        printf '%b\n' "${GREEN}✅ docker-compose 已就绪：$(docker-compose --version)${NC}"
    else
        printf '%b\n' "${RED}❌ 未检测到 Docker Compose，请先安装 Docker Compose >= 2.0${NC}"
        printf '%b\n' "   安装文档：https://docs.docker.com/compose/install/"
        exit 1
    fi
}

# 创建 Lantern 数据目录
create_lantern_data_dir() {
    local data_dir="$LIBRE_APP_DIR/lantern"
    mkdir -p "$data_dir/config"
    printf '%b\n' "${GREEN}✅ Lantern 数据目录已就绪：$data_dir${NC}"
}

# 创建 Xray 数据目录
create_xray_data_dir() {
    local data_dir="$LIBRE_APP_DIR/xray"
    mkdir -p "$data_dir/db" "$data_dir/cert"
    printf '%b\n' "${GREEN}✅ Xray 数据目录已就绪：$data_dir${NC}"
}

# 下载单个文件，失败时退出
# 用法：download_file <远程路径> <本地目标路径>
download_file() {
    local remote_path="$1"
    local local_path="$2"
    local url="${RAW_BASE}/${remote_path}"

    mkdir -p "$(dirname "$local_path")"
    if curl -4fsSL "$url" -o "$local_path"; then
        printf '%b\n' "${GREEN}  ✅ ${remote_path}${NC}"
    else
        printf '%b\n' "${RED}  ❌ 下载失败：$url${NC}"
        printf '%b\n' "${RED}     请检查网络连接或仓库地址是否正确${NC}"
        exit 1
    fi
}

# ─────────────────────────────────────────────
# 运行模式检测
# ─────────────────────────────────────────────

# 判断是否在项目根目录中本地运行
# 本地模式：install.sh 旁边存在 lantern/ 和 xray/ 目录
detect_local_mode() {
    # $0 为 /dev/fd/xx 等时说明是管道/进程替换执行（远程模式）
    case "$0" in
        /dev/fd/*|/proc/self/fd/*|/dev/stdin|bash)
            return 1
            ;;
    esac

    local dir
    dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
    if [ -d "$dir/lantern" ] && [ -d "$dir/xray" ]; then
        SCRIPT_DIR="$dir"
        return 0  # 本地模式
    fi
    return 1  # 远程模式
}

# ─────────────────────────────────────────────
# 远程模式：按需下载所需文件
# ─────────────────────────────────────────────

# 下载 Lantern 所需文件到 $INSTALL_DIR/lantern/
download_lantern_files() {
    printf '%b\n' "${CYAN}⬇️  下载 Lantern 配置文件...${NC}"
    download_file "lantern/docker-compose.yml"        "$INSTALL_DIR/lantern/docker-compose.yml"
    download_file "lantern/.env"                      "$INSTALL_DIR/lantern/.env"
    download_file "lantern/lantern.sh"                "$INSTALL_DIR/lantern/lantern.sh"
    download_file "lantern/scripts/gen_cert.py"       "$INSTALL_DIR/lantern/scripts/gen_cert.py"
    download_file "lantern/scripts/requirements.txt"  "$INSTALL_DIR/lantern/scripts/requirements.txt"
    chmod +x "$INSTALL_DIR/lantern/lantern.sh"
    printf '%b\n' "${GREEN}✅ Lantern 文件下载完成 → $INSTALL_DIR/lantern/${NC}"
}

# 下载 Xray 所需文件到 $INSTALL_DIR/xray/
download_xray_files() {
    printf '%b\n' "${CYAN}⬇️  下载 Xray 配置文件...${NC}"
    download_file "xray/docker-compose.yaml"  "$INSTALL_DIR/xray/docker-compose.yaml"
    download_file "xray/3xui.sh"              "$INSTALL_DIR/xray/3xui.sh"
    chmod +x "$INSTALL_DIR/xray/3xui.sh"
    printf '%b\n' "${GREEN}✅ Xray 文件下载完成 → $INSTALL_DIR/xray/${NC}"
}

# 下载 libre.sh 管理脚本到安装目录
download_libre_sh() {
    download_file "libre.sh"  "$INSTALL_DIR/libre.sh"
    chmod +x "$INSTALL_DIR/libre.sh"
}

# ─────────────────────────────────────────────
# 软链接：将 libre.sh 链接到 /usr/local/bin/libre
# ─────────────────────────────────────────────

setup_symlink() {
    local libre_sh="$SCRIPT_DIR/libre.sh"
    local link_path="/usr/local/bin/libre"

    if [ ! -f "$libre_sh" ]; then
        printf '%b\n' "${YELLOW}⚠️  未找到 $libre_sh，跳过软链接创建${NC}"
        return 0
    fi

    # 判断是否有写入权限，没有则尝试 sudo
    local use_sudo=""
    if [ ! -w "/usr/local/bin" ]; then
        if command -v sudo &>/dev/null; then
            use_sudo="sudo"
        else
            printf '%b\n' "${YELLOW}⚠️  无权限写入 /usr/local/bin，跳过软链接创建${NC}"
            printf '%b\n' "   可手动执行：sudo ln -sf $libre_sh $link_path"
            return 0
        fi
    fi

    $use_sudo ln -sf "$libre_sh" "$link_path" \
        && printf '%b\n' "${GREEN}✅ 已创建快捷命令：${BOLD}libre${NC}${GREEN} → $libre_sh${NC}" \
        || printf '%b\n' "${YELLOW}⚠️  软链接创建失败，可手动执行：sudo ln -sf $libre_sh $link_path${NC}"
}

# ─────────────────────────────────────────────
# 安装函数
# ─────────────────────────────────────────────

install_lantern() {
    print_divider
    printf '%b\n' "${CYAN}🔦 安装 Lantern Server Manager${NC}"
    print_divider

    # 远程模式：先下载文件
    if [ "${REMOTE_MODE:-0}" = "1" ]; then
        download_lantern_files
    fi

    # 创建数据目录
    create_lantern_data_dir

    local lantern_sh="$SCRIPT_DIR/lantern/lantern.sh"
    if [ ! -f "$lantern_sh" ]; then
        printf '%b\n' "${RED}❌ 未找到 $lantern_sh${NC}"
        return 1
    fi

    # 检查 Python3（证书生成需要）
    if ! command -v python3 &>/dev/null; then
        printf '%b\n' "${YELLOW}⚠️  未检测到 Python3，证书自动生成功能将不可用${NC}"
        printf '%b\n' "   请手动将 cert.pem / key.pem 放入 lantern/config/ 目录后再启动"
    else
        printf '%b\n' "${GREEN}✅ Python3 已就绪：$(python3 --version)${NC}"
        local req_file="$SCRIPT_DIR/lantern/scripts/requirements.txt"
        if [ -f "$req_file" ]; then
            printf '%b\n' "${CYAN}📦 安装 Python 依赖...${NC}"
            pip3 install -r "$req_file" -q \
                && printf '%b\n' "${GREEN}✅ Python 依赖安装完成${NC}" \
                || printf '%b\n' "${YELLOW}⚠️  Python 依赖安装失败，证书自动生成可能受影响${NC}"
        fi
    fi

    printf '%b\n' "${CYAN}🚀 启动 Lantern...${NC}"
    LIBRE_DATA_DIR="$LIBRE_APP_DIR/lantern" bash "$lantern_sh" start

    printf '\n'
    printf '%b\n' "${GREEN}✅ Lantern 安装完成${NC}"
    printf '%b\n' "   管理命令：${BOLD}bash $SCRIPT_DIR/lantern/lantern.sh <命令>${NC}"
    printf '%b\n' "   统一管理：${BOLD}bash $SCRIPT_DIR/libre.sh <命令> lantern${NC}"
}

install_xray() {
    print_divider
    printf '%b\n' "${CYAN}⚡ 安装 Xray (3x-ui)${NC}"
    print_divider

    # 远程模式：先下载文件
    if [ "${REMOTE_MODE:-0}" = "1" ]; then
        download_xray_files
    fi

    # 创建数据目录
    create_xray_data_dir

    local xray_sh="$SCRIPT_DIR/xray/3xui.sh"
    if [ ! -f "$xray_sh" ]; then
        printf '%b\n' "${RED}❌ 未找到 $xray_sh${NC}"
        return 1
    fi

    printf '%b\n' "${CYAN}🚀 启动 Xray (3x-ui)...${NC}"
    (cd "$SCRIPT_DIR/xray" && LIBRE_DATA_DIR="$LIBRE_APP_DIR/xray" bash 3xui.sh start)

    printf '\n'
    printf '%b\n' "${GREEN}✅ Xray 安装完成${NC}"
    printf '%b\n' "   管理命令：${BOLD}bash $SCRIPT_DIR/xray/3xui.sh <命令>${NC}"
    printf '%b\n' "   统一管理：${BOLD}bash $SCRIPT_DIR/libre.sh <命令> xray${NC}"
}

# ─────────────────────────────────────────────
# 交互式菜单
# ─────────────────────────────────────────────
show_menu() {
    printf '\n'
    printf '%b\n' "${BOLD}╔══════════════════════════════════════════╗${NC}"
    printf '%b\n' "${BOLD}║           Libre 一键安装向导             ║${NC}"
    printf '%b\n' "${BOLD}╚══════════════════════════════════════════╝${NC}"
    printf '\n'
    printf '%b\n' "  ${GREEN}1)${NC} 安装 Lantern Server Manager（WireGuard VPN）"
    printf '%b\n' "  ${GREEN}2)${NC} 安装 Xray (3x-ui)（多协议代理）"
    printf '%b\n' "  ${GREEN}3)${NC} 全部安装"
    printf '%b\n' "  ${RED}0)${NC} 退出"
    printf '\n'
    printf '%b' "  请输入选项 [0-3]: "
    read -r choice

    case "$choice" in
        1) run_install lantern ;;
        2) run_install xray    ;;
        3) run_install all     ;;
        0)
            printf '%b\n' "${YELLOW}已退出${NC}"
            exit 0
            ;;
        *)
            printf '%b\n' "${RED}❌ 无效选项：$choice${NC}"
            show_menu
            ;;
    esac
}

# ─────────────────────────────────────────────
# 执行安装
# ─────────────────────────────────────────────
run_install() {
    local target="$1"

    printf '\n'
    printf '%b\n' "${CYAN}🔍 检查环境依赖...${NC}"
    check_docker
    check_docker_compose
    printf '\n'

    # 远程模式：提前下载 libre.sh
    if [ "${REMOTE_MODE:-0}" = "1" ]; then
        download_libre_sh
    fi

    case "$target" in
        lantern) install_lantern ;;
        xray)    install_xray    ;;
        all)
            install_lantern
            printf '\n'
            install_xray
            ;;
        *)
            printf '%b\n' "${RED}❌ 未知目标：$target${NC}"
            exit 1
            ;;
    esac

    # 创建 libre 快捷命令
    setup_symlink

    print_divider
    printf '%b\n' "${GREEN}${BOLD}🎉 安装完成！${NC}"
    printf '%b\n' "   脚本目录：${BOLD}$SCRIPT_DIR${NC}"
    printf '%b\n' "   数据目录：${BOLD}$LIBRE_APP_DIR${NC}"
    if command -v libre &>/dev/null; then
        printf '%b\n' "   统一管理：${BOLD}libre <命令>${NC}"
    else
        printf '%b\n' "   统一管理：${BOLD}bash $SCRIPT_DIR/libre.sh <命令>${NC}"
    fi
    print_divider
}

# ─────────────────────────────────────────────
# 入口
# ─────────────────────────────────────────────

# 检测运行模式
if detect_local_mode; then
    printf '%b\n' "${GREEN}📂 本地模式：$SCRIPT_DIR${NC}"
    REMOTE_MODE=0
else
    REMOTE_MODE=1
    SCRIPT_DIR="$INSTALL_DIR"
    printf '%b\n' "${CYAN}🌐 远程安装模式：文件将下载到 ${BOLD}$INSTALL_DIR${NC}"
    mkdir -p "$INSTALL_DIR"
fi

# 解析命令行参数
case "${1:-}" in
    lantern) run_install lantern ;;
    xray)    run_install xray    ;;
    all)     run_install all     ;;
    "")      show_menu           ;;
    *)
        printf '%b\n' "${RED}❌ 未知参数：$1${NC}"
        printf '%b\n' "用法：bash install.sh [lantern|xray|all]"
        exit 1
        ;;
esac
