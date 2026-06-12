# Libre

基于 Docker 的自由工具集合，包含多个开箱即用的代理与 VPN 服务部署方案。

## 目录结构

```
Libre/
├── lantern/    # Lantern Server Manager — WireGuard VPN 管理面板
└── xray/       # 3x-ui — Xray 多协议代理管理面板
```

---

## 快速开始

### 远程一键安装（推荐）

#### 交互式菜单安装
```bash
bash <(curl -Ls https://raw.githubusercontent.com/iliYF/Libre/main/install.sh)
```

#### 仅安装 Lantern
```bash
bash <(curl -Ls https://raw.githubusercontent.com/iliYF/Libre/main/install.sh) lantern
```

#### 仅安装 Xray
```bash
bash <(curl -Ls https://raw.githubusercontent.com/iliYF/Libre/main/install.sh) xray
```

#### 安装全部服务
```bash
bash <(curl -Ls https://raw.githubusercontent.com/iliYF/Libre/main/install.sh) all
```

#### 自定义安装路径
```bash
LIBRE_DIR=/home/user/libre bash <(curl -Ls https://raw.githubusercontent.com/iliYF/Libre/main/install.sh) all
```

> 远程执行时会自动将所需文件下载到 `/opt/libre`，可通过环境变量自定义路径。

### 本地安装

#### 克隆仓库
```bash
git clone https://github.com/iliYF/Libre.git && cd Libre
```

#### 交互式菜单安装
```bash
bash install.sh
```

#### 仅安装 Lantern
```bash
bash install.sh lantern
```

#### 仅安装 Xray
```bash
bash install.sh xray
```

#### 安装全部服务
```bash
bash install.sh all
```

安装完成后，`libre` 命令已注册到系统，可直接使用：

#### 查看服务状态
```bash
libre status
```

#### 启动服务
```bash
libre start lantern       # 启动 Lantern
libre start xray          # 启动 Xray
libre start all           # 启动所有服务
```

#### 停止服务
```bash
libre stop lantern        # 停止 Lantern
libre stop xray           # 停止 Xray
libre stop all            # 停止所有服务
```

#### 重启服务
```bash
libre restart lantern     # 重启 Lantern
libre restart xray        # 重启 Xray
libre restart all         # 重启所有服务
```

#### 查看日志
```bash
libre logs lantern        # 查看 Lantern 日志
libre logs xray           # 查看 Xray 日志
```

#### 更新服务
```bash
libre update              # 更新所有服务
libre update lantern      # 仅更新 Lantern
libre update xray         # 仅更新 Xray
```

---

## 依赖

- Docker >= 20.10
- Docker Compose >= 2.0
- Python 3.6+（Lantern 证书生成需要）

---

## 🔦 Lantern

基于 Docker 部署的 [Lantern Server Manager](https://github.com/getlantern/lantern-server-manager)，提供 Web UI 管理界面与 WireGuard VPN 服务。

### 目录结构

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

### 快速开始

```bash
# 启动服务（首次启动自动生成证书）
libre start lantern
```

访问 Web UI：

```
https://<服务器IP>:18080
```

> 使用自签名证书时，浏览器会提示不安全，忽略警告继续访问即可。

### 端口配置

端口通过 `lantern/.env` 文件配置，修改后重启服务生效：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `API_PORT` | `18080` | Web UI / REST API 端口 |
| `VPN_PORT` | `30001` | WireGuard VPN 端口（TCP）|

### 管理命令

| 命令 | 说明 |
|------|------|
| `libre start lantern` | 启动服务（自动检查并生成证书） |
| `libre stop lantern` | 停止服务 |
| `libre restart lantern` | 重启服务 |
| `libre status lantern` | 查看运行状态与访问地址 |
| `libre update lantern` | 拉取最新镜像并重启 |
| `libre lantern gen-cert` | 手动重新生成自签名证书 |
| `libre shell lantern` | 进入容器交互式终端 |
| `libre logs lantern` | 实时查看容器日志 |
| `libre ip lantern` | 显示当前公网 IP |

### 证书说明

- **自动生成**：启动时若 `config/cert.pem` 或 `config/key.pem` 不存在，脚本会自动调用 `gen_cert.py` 生成自签名证书。
- **手动放入**：也可将自有证书文件直接放入 `config/` 目录，文件名须为 `cert.pem` / `key.pem`。
- **Let's Encrypt**：容器内无法使用 ACME 自动签发，需在宿主机申请后手动放入。

---

## ⚡ Xray（3x-ui）

基于 [3x-ui](https://github.com/MHSanaei/3x-ui) 的 Docker 部署方案，支持 VMess / VLESS / Trojan / Shadowsocks 等多种协议，提供可视化 Web 管理面板。

- **镜像**：[bigbugcc/3x-ui](https://hub.docker.com/r/bigbugcc/3x-ui)（支持 amd64 / arm64 / armv7）
- **上游项目**：https://github.com/MHSanaei/3x-ui

### 目录结构

```
xray/
├── docker-compose.yaml   # Docker Compose 配置
├── 3xui.sh               # 管理脚本
├── db/                   # 数据库持久化目录（自动创建）
└── cert/                 # SSL 证书目录（可选）
```

### 快速开始

```bash
# 使用默认端口 2026 启动
libre start xray

# 指定端口启动
libre xray port 8443 && libre start xray
```

访问面板：

```
http://<服务器IP>:2026/panel
```

> 首次启动时，用户名和密码由容器随机生成，请查看启动日志获取。

### 管理命令

| 命令 | 说明 |
|------|------|
| `libre start xray` | 启动服务（默认端口 2026） |
| `libre stop xray` | 停止服务 |
| `libre restart xray` | 重启服务 |
| `libre status xray` | 查看运行状态及访问地址 |
| `libre xray port [端口]` | 查看或修改面板端口 |
| `libre xray reset-port` | 重置端口为默认值（2026） |
| `libre xray reset-creds` | 从 `.env` 读取用户名/密码并重置登录凭据 |
| `libre update xray` | 拉取最新镜像并重启 |
| `libre xray cli [命令]` | 在容器内执行 x-ui 命令 |
| `libre shell xray` | 进入容器交互式终端 |
| `libre logs xray` | 查看容器日志（实时） |
| `libre ip xray` | 显示公网 IP |

### 配置说明

| 配置项 | 默认值 |
|--------|--------|
| 面板端口 | `2026` |
| 时区 | `Asia/Shanghai` |
| 数据库路径（容器内） | `/etc/x-ui/x-ui.db` |
| 数据库路径（宿主机） | `./db/` |
| SSL 证书目录 | `./cert/` |

自定义登录凭据：在 `xray/` 目录下创建 `.env` 文件后执行 `libre xray reset-creds`：

```env
XUI_USERNAME=your_username
XUI_PASSWORD=your_password
```

> 容器使用**宿主机网络模式**（`network_mode: host`），无需端口映射，所有入站端口直接监听在宿主机上。

---

## License

本项目基于 [MIT License](LICENSE) 开源。

本项目集成了以下开源项目，各自遵循其原始许可证：

| 项目 | 许可证 |
|------|--------|
| [Lantern Server Manager](https://github.com/getlantern/lantern-server-manager) | Apache 2.0 |
| [3x-ui](https://github.com/MHSanaei/3x-ui) | GPL-3.0 |
