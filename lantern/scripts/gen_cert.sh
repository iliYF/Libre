#!/bin/bash
# Lantern Server Manager 自签名 TLS 证书生成脚本（简化版）
# 使用 OpenSSL 命令生成证书，不依赖 Python cryptography 库

# 证书输出目录
_data_dir="${LIBRE_DATA_DIR:-/usr/local/app/libre/lantern}"
CONFIG_DIR="$_data_dir/config"
CERT_PATH="$CONFIG_DIR/cert.pem"
KEY_PATH="$CONFIG_DIR/key.pem"

# 证书有效期（天）
CERT_VALID_DAYS=3650

# 检查 openssl 是否可用
check_openssl() {
    if ! command -v openssl &>/dev/null; then
        echo "❌ 未找到 openssl 命令，请先安装 openssl"
        echo "   Ubuntu/Debian: sudo apt install openssl"
        echo "   CentOS/RHEL: sudo yum install openssl"
        echo "   macOS: brew install openssl"
        return 1
    fi
    return 0
}

# 获取本机 IP 地址
get_local_ip() {
    local ip
    # 尝试多种方法获取 IP（兼容 macOS 和 Linux）
    if command -v ip &>/dev/null; then
        # Linux 系统
        ip=$(ip route get 8.8.8.8 2>/dev/null | grep -Eo 'src [0-9.]+' | awk '{print $2}' | head -1)
    elif command -v ifconfig &>/dev/null; then
        # macOS 系统
        ip=$(ifconfig | grep -E 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | head -1)
    fi
    
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' | head -1)
    fi
    if [ -z "$ip" ]; then
        ip="127.0.0.1"
    fi
    echo "$ip"
}

# 生成自签名证书
generate_cert() {
    local server_ip="$1"
    
    # 创建配置目录
    mkdir -p "$CONFIG_DIR"
    
    # 生成私钥
    echo "🔑 生成私钥..."
    openssl genrsa -out "$KEY_PATH" 2048 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "❌ 私钥生成失败"
        return 1
    fi
    
    # 创建证书签名请求配置文件
    local conf_file="$CONFIG_DIR/cert.conf"
    cat > "$conf_file" << EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
C = US
O = Lantern Server
CN = $server_ip

[v3_req]
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
IP.1 = $server_ip
IP.2 = 127.0.0.1
DNS.1 = localhost
EOF
    
    # 生成证书
    echo "📄 生成证书..."
    openssl req -new -x509 \
        -key "$KEY_PATH" \
        -out "$CERT_PATH" \
        -days "$CERT_VALID_DAYS" \
        -config "$conf_file" \
        -extensions v3_req 2>/dev/null
    
    if [ $? -ne 0 ]; then
        echo "❌ 证书生成失败"
        rm -f "$conf_file"
        return 1
    fi
    
    # 清理临时文件
    rm -f "$conf_file"
    
    echo "✅ 证书已生成："
    echo "   私钥：$KEY_PATH"
    echo "   证书：$CERT_PATH"
    echo "   有效期：$CERT_VALID_DAYS 天"
    echo "   服务器 IP：$server_ip"
    
    return 0
}

# 主函数
main() {
    echo "🔧 Lantern 证书生成工具（简化版）"
    echo "================================"
    
    # 检查 openssl
    if ! check_openssl; then
        exit 1
    fi
    
    # 获取本机 IP
    local local_ip
    local_ip=$(get_local_ip)
    echo "🌐 检测到本机 IP：$local_ip"
    
    # 询问用户 IP
    echo -n "请输入服务器公网 IP（直接回车使用 $local_ip）："
    read -r user_ip
    
    local target_ip="${user_ip:-$local_ip}"
    
    # 验证 IP 格式
    if ! echo "$target_ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        echo "❌ IP 地址格式无效：$target_ip"
        exit 1
    fi
    
    # 生成证书
    if generate_cert "$target_ip"; then
        echo ""
        echo "🎉 证书生成成功！"
        echo "💡 现在可以启动 Lantern 服务了"
    else
        echo ""
        echo "❌ 证书生成失败"
        echo "💡 请检查错误信息或尝试手动生成证书"
        exit 1
    fi
}

# 执行主函数
main "$@"