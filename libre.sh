#!/bin/bash
# Libre 统一管理脚本
#
# 统一管理以下服务：
#   lantern  — Lantern Server Manager（WireGuard VPN）
#   xray     — 3x-ui（多协议代理）
#
# 用法：
#   bash libre.sh <命令> [服务] [参数]
#
# 公共命令（支持 lantern / xray / all）：
#   bash libre.sh status              # 查看所有服务状态
#   bash libre.sh start lantern       # 启动 Lantern
#   bash libre.sh stop xray           # 停止 Xray
#   bash libre.sh restart all         # 重启所有服务
#   bash libre.sh logs xray           # 查看 Xray 日志（必须指定服务）
#   bash libre.sh shell lantern       # 进入 Lantern 容器终端（必须指定服务）
#
# Lantern 专属命令：
#   bash libre.sh gen-cert            # 生成自签名证书
#
# Xray 专属命令：
#   bash libre.sh port [端口]         # 查看或修改面板端口
#   bash libre.sh reset-port          # 重置端口为默认值
#   bash libre.sh reset-creds         # 重置登录凭据
#   bash libre.sh cli [命令]          # 执行 x-ui 内部命令

# ─────────────────────────────────────────────
# 常量
# ─────────────────────────────────────────────
# 追踪软链接，解析脚本真实所在目录（兼容 Linux / macOS）
_resolve_script_dir() {
    local src="$0"
    # 循环追踪软链接，直到找到真实文件
    while [ -L "$src" ]; do
        local link_dir
        link_dir="$(cd "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        # readlink 返回相对路径时，需要拼接上一级目录
        [[ "$src" != /* ]] && src="$link_dir/$src"
    done
    cd "$(dirname "$src")" && pwd
}
SCRIPT_DIR="$(_resolve_script_dir)"
LANTERN_SH="$SCRIPT_DIR/lantern/lantern.sh"
XRAY_SH="$SCRIPT_DIR/xray/3xui.sh"

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

print_header() {
    printf '%b\n' "${CYAN}${BOLD}▶ $1${NC}"
}

# 检查服务脚本是否存在
check_script() {
    local name="$1"
    local sh="$2"
    if [ ! -f "$sh" ]; then
        printf '%b\n' "${RED}❌ 未找到 $name 管理脚本：$sh${NC}"
        return 1
    fi
    return 0
}

# 调用 lantern 脚本（在其目录下执行）
run_lantern() {
    check_script "lantern" "$LANTERN_SH" || return 1
    LIBRE_DATA_DIR="$LIBRE_APP_DIR/lantern" bash "$LANTERN_SH" "$@"
}

# 调用 xray 脚本（切换到 xray 目录执行，因脚本内部使用相对路径）
run_xray() {
    check_script "xray" "$XRAY_SH" || return 1
    (cd "$SCRIPT_DIR/xray" && LIBRE_DATA_DIR="$LIBRE_APP_DIR/xray" bash 3xui.sh "$@")
}

# 解析服务参数，默认 all
parse_service() {
    local svc="${1:-all}"
    case "$svc" in
        lantern|xray|all) echo "$svc" ;;
        *)
            printf '%b\n' "${RED}❌ 未知服务：$svc（可选：lantern / xray / all）${NC}"
            exit 1
            ;;
    esac
}

# ─────────────────────────────────────────────
# 公共命令分发
# ─────────────────────────────────────────────

# 对指定服务执行同一命令（支持透传额外参数）
dispatch() {
    local cmd="$1"
    local svc="$2"
    shift 2
    local extra=("$@")

    case "$svc" in
        lantern)
            print_header "Lantern — $cmd"
            run_lantern "$cmd" "${extra[@]}"
            ;;
        xray)
            print_header "Xray — $cmd"
            run_xray "$cmd" "${extra[@]}"
            ;;
        all)
            print_header "Lantern — $cmd"
            run_lantern "$cmd" "${extra[@]}"
            printf '\n'
            print_header "Xray — $cmd"
            run_xray "$cmd" "${extra[@]}"
            ;;
    esac
}

# ─────────────────────────────────────────────
# 帮助信息
# ─────────────────────────────────────────────
show_help() {
    local me
    me="$(basename "$0")"
    printf '%b\n' "${BOLD}用法: $me <命令> [服务] [参数]${NC}"
    printf '\n'
    printf '%b\n' "${BOLD}服务:${NC}"
    printf "  ${GREEN}%s${NC} %s\n" "lantern  " "Lantern Server Manager（WireGuard VPN）"
    printf "  ${GREEN}%s${NC} %s\n" "xray     " "3x-ui（多协议代理）"
    printf "  ${GREEN}%s${NC} %s\n" "all      " "所有服务（默认）"
    printf '\n'
    printf '%b\n' "${BOLD}命令:${NC}"
    printf "  ${GREEN}%s${NC} %s\n" "status  [服务]  " "查看运行状态"
    printf "  ${GREEN}%s${NC} %s\n" "start   [服务]  " "启动服务"
    printf "  ${GREEN}%s${NC} %s\n" "stop    [服务]  " "停止服务"
    printf "  ${GREEN}%s${NC} %s\n" "restart [服务]  " "重启服务"
    printf "  ${GREEN}%s${NC} %s\n" "update  [服务]  " "拉取最新镜像并重启"
    printf "  ${GREEN}%s${NC} %s\n" "logs    <服务>  " "查看容器日志（实时，必须指定服务）"
    printf "  ${GREEN}%s${NC} %s\n" "shell   <服务>  " "进入容器终端（必须指定服务）"
    printf "  ${GREEN}%s${NC} %s\n" "ip      [服务]  " "显示公网 IP"
    printf "  ${GREEN}%s${NC} %s\n" "install [服务]  " "安装并首次启动服务"
    printf '\n'
    printf '%b\n' "${BOLD}Lantern 专属命令:${NC}"
    printf "  ${GREEN}%s${NC} %s\n" "gen-cert        " "生成自签名证书到 config/ 目录"
    printf '\n'
    printf '%b\n' "${BOLD}Xray 专属命令:${NC}"
    printf "  ${GREEN}%s${NC} %s\n" "port    [端口]  " "查看或修改面板端口"
    printf "  ${GREEN}%s${NC} %s\n" "reset-port      " "重置端口为默认值"
    printf "  ${GREEN}%s${NC} %s\n" "reset-creds     " "从 .env 重置登录凭据"
    printf "  ${GREEN}%s${NC} %s\n" "cli     [命令]  " "在容器内执行 x-ui 命令"
    printf '\n'
    printf '%b\n' "${BOLD}help            显示此帮助信息${NC}"
    printf '\n'
    printf '%b\n' "${BOLD}示例:${NC}"
    printf "  bash %s status\n"             "$me"
    printf "  bash %s start lantern\n"      "$me"
    printf "  bash %s restart all\n"        "$me"
    printf "  bash %s logs xray\n"          "$me"
    printf "  bash %s gen-cert\n"           "$me"
    printf "  bash %s port 8443\n"          "$me"
    printf "  bash %s cli setting -show\n"  "$me"
}

# ─────────────────────────────────────────────
# 入口分发
# ─────────────────────────────────────────────
CMD="${1:-help}"
shift || true

case "$CMD" in
    # logs / shell 必须指定具体服务，不支持 all
    logs|shell)
        SVC="${1:-}"
        if [ -z "$SVC" ] || [ "$SVC" = "all" ]; then
            printf '%b\n' "${RED}❌ $CMD 命令必须指定具体服务：lantern 或 xray${NC}"
            exit 1
        fi
        parse_service "$SVC" > /dev/null
        shift || true
        dispatch "$CMD" "$SVC" "$@"
        ;;

    # install 委托给 install.sh
    install)
        SVC="${1:-all}"
        parse_service "$SVC" > /dev/null
        bash "$SCRIPT_DIR/install.sh" "$SVC"
        ;;

    # 通用命令：支持 lantern / xray / all（默认 all）
    status|start|stop|restart|update|ip)
        SVC=$(parse_service "${1:-all}")
        shift || true
        dispatch "$CMD" "$SVC" "$@"
        ;;

    # Lantern 专属命令
    gen-cert)
        print_header "Lantern — gen-cert"
        run_lantern gen-cert
        ;;

    # Xray 专属命令
    port|reset-port|reset-creds)
        print_header "Xray — $CMD"
        run_xray "$CMD" "$@"
        ;;

    cli)
        print_header "Xray — cli"
        run_xray cli "$@"
        ;;

    help|--help|-h)
        show_help
        ;;

    *)
        printf '%b\n' "${RED}❌ 未知命令：$CMD${NC}"
        printf '\n'
        show_help
        exit 1
        ;;
esac
