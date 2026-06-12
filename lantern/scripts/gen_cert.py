#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Lantern Server Manager 自签名 TLS 证书生成脚本。

在没有域名或 Let's Encrypt 证书时，可使用此脚本生成自签名证书，
生成的证书文件将保存到 ./config 目录。

依赖：
    pip install cryptography
"""

import datetime
import ipaddress
import os
import socket

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID


# 证书输出目录
CONFIG_DIR = os.path.join(os.path.dirname(__file__), "config")
CERT_PATH = os.path.join(CONFIG_DIR, "cert.pem")
KEY_PATH = os.path.join(CONFIG_DIR, "key.pem")

# 证书有效期（天）
CERT_VALID_DAYS = 3650


def get_local_ip() -> str:
    """获取本机局域网 IP 地址。"""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("8.8.8.8", 80))
            return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def generate_self_signed_cert(server_ip: str) -> None:
    """生成自签名 TLS 证书和私钥。

    :param server_ip: 服务器 IP 地址，将写入证书 SAN 字段
    """
    os.makedirs(CONFIG_DIR, exist_ok=True)

    # 生成 RSA 私钥
    private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
    )

    # 构建证书主题
    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Lantern Server"),
        x509.NameAttribute(NameOID.COMMON_NAME, server_ip),
    ])

    # SAN：同时支持 IP 和 localhost
    san_list = [
        x509.IPAddress(ipaddress.IPv4Address(server_ip)),
        x509.IPAddress(ipaddress.IPv4Address("127.0.0.1")),
        x509.DNSName("localhost"),
    ]

    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(private_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=CERT_VALID_DAYS))
        .add_extension(
            x509.SubjectAlternativeName(san_list),
            critical=False,
        )
        .sign(private_key, hashes.SHA256())
    )

    # 写入私钥文件
    with open(KEY_PATH, "wb") as key_file:
        key_file.write(
            private_key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.TraditionalOpenSSL,
                encryption_algorithm=serialization.NoEncryption(),
            )
        )

    # 写入证书文件
    with open(CERT_PATH, "wb") as cert_file:
        cert_file.write(cert.public_bytes(serialization.Encoding.PEM))

    print(f"证书已生成：")
    print(f"  私钥：{KEY_PATH}")
    print(f"  证书：{CERT_PATH}")
    print(f"  有效期：{CERT_VALID_DAYS} 天")
    print(f"  服务器 IP：{server_ip}")


if __name__ == "__main__":
    local_ip = get_local_ip()
    print(f"检测到本机 IP：{local_ip}")
    user_ip = input(f"请输入服务器公网 IP（直接回车使用 {local_ip}）：").strip()
    target_ip = user_ip if user_ip else local_ip
    generate_self_signed_cert(target_ip)
