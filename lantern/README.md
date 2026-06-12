# Lantern Server Manager

基于 Docker 部署的 [Lantern Server Manager](https://github.com/getlantern/lantern-server-manager)，提供 Web UI 管理界面与 WireGuard VPN 服务。

## 目录结构

```
lantern/
├── config/              # 持久化配置目录（挂载到容器 /config）
│   ├── cert.pem         # TLS 证书（自动生成或手动放入）
│   └── key.pem          # TLS 私钥（自动生成或手动放入）
├── scripts/
│   ├── gen_cert.py      # 自签名证书生成脚本
│   ├── lantern.sh       # 管理脚本
│   └── requirements.txt # Python 依赖
├── .env                 # 端口环境变量
└── docker-compose.yml   # Docker Compose 配置
```

## 快速开始

### 1. 安装依赖

```bash
pip install -r scripts/requirements.txt
```

### 2. 启动服务

```bash
bash scripts/lantern.sh start
```

首次启动会自动检测 `config/` 目录下的证书文件，若不存在则调用 `gen_cert.py` 自动生成自签名证书。

### 3. 访问 Web UI

```
https://<服务器IP>:18080
```

> 使用自签名证书时，浏览器会提示不安全，忽略警告继续访问即可。

---

## 端口配置

端口通过 `.env` 文件配置，修改后重启服务生效：

| 变量        | 默认值  | 说明                    |
|-------------|---------|-------------------------|
| `API_PORT`  | `18080` | Web UI / REST API 端口  |
| `VPN_PORT`  | `30001` | WireGuard VPN 端口（TCP）|

```ini
# .env
API_PORT=18080
VPN_PORT=30001
```

---

## 管理脚本

```bash
bash scripts/lantern.sh <命令>
```

| 命令       | 说明                           |
|------------|--------------------------------|
| `start`    | 启动服务（自动检查并生成证书） |
| `stop`     | 停止服务                       |
| `restart`  | 重启服务                       |
| `status`   | 查看运行状态与访问地址         |
| `update`   | 拉取最新镜像并重启             |
| `gen-cert` | 手动重新生成自签名证书         |
| `shell`    | 进入容器交互式终端             |
| `logs`     | 实时查看容器日志               |
| `ip`       | 显示当前公网 IP                |
| `help`     | 显示帮助信息                   |

---

## 证书说明

- **自动生成**：启动时若 `config/cert.pem` 或 `config/key.pem` 不存在，脚本会自动调用 `gen_cert.py` 生成自签名证书。
- **手动放入**：也可将自有证书文件直接放入 `config/` 目录，文件名须为 `cert.pem` / `key.pem`。
- **Let's Encrypt**：容器内无法使用 ACME 自动签发，需在宿主机申请后手动放入。

---

## 参考链接

- 上游项目：<https://github.com/getlantern/lantern-server-manager>
- Docker Hub：<https://hub.docker.com/r/getlantern/lantern-server-manager>
