# Air724UG Web Panel

基于合宙 Air724UG（LuatOS-Air）4G 模组的远程管理面板与短信/通话转发器。

设备端固件基于 [0wQ/air724ug-forwarder](https://github.com/0wQ/air724ug-forwarder) 修改扩展；服务端由 **Go 单二进制**（内置 HTTP 面板 + MQTT Broker），前端使用 **Tailwind CSS** 构建，相比原 WebSocket 方案显著降低设备流量消耗。

> 请勿用于非法用途及盈利。

## 特性

- **设备远程管理**：设备列表、在线状态、一键下发任务（查询温度 / 发送短信 / 读取配置 / 写入配置）
- **MQTT 接入**：Go 服务端内置 MQTT Broker，设备端通过 MQTT 对接，心跳仅 2 字节、间隔 300s，节省流量
- **任务记录**：SQLite 持久化最近 50 条任务执行记录
- **远程配置**：读取 / 写入设备端 `nvm_para.lua` 参数文件，支持动态修改设备配置
- **多通道通知**：设备端支持 gotify / telegram / bark / 钉钉 / 飞书 / 企业微信 / pushover / message-pusher 等通知渠道
- **单二进制部署**：前端静态资源通过 `go:embed` 内嵌进 Go 二进制，支持 Docker 一键部署

## 界面预览

### 设备列表

![设备列表](screenshots/ScreenShot_2026-08-27_224939_410.png)

### 任务执行

![任务执行](screenshots/ScreenShot_2026-08-27_224957_057.png)

### 任务记录

![任务记录](screenshots/ScreenShot_2026-08-27_225002_085.png)

### 设置界面

![设置界面](screenshots/ScreenShot_2026-08-27_225007_118.png)

## 系统架构

```
┌────────────┐   wss://host/websocket  ┌──────────────────────────────┐
│ Air724UG   │ ◄──────(443 加密)──────►│          panel-server         │
│ 设备端Lua  │    MQTT over WebSocket   │  ┌────────┐  ┌──────────────┐ │
│ 固件 script│    cmd/{imei} 等主题      │  │ MQTT   │  │ HTTP 面板    │ │
└────────────┘                          │  │ Broker │  │ (REST + 前端)│ │
                                        │  │1883/8083│ └──────────────┘ │
                                        │  └────────┘                   │
                                        │       │   SQLite (panel.db)   │
                                        └───────┴───────────────────────┘
```

- 设备经 **wss（443）** 或内网 **ws://host:8083** 接入，MQTT 数据封装在 WebSocket 帧中传输，加密且省流量；内网也可直连 MQTT TCP 1883
- 设备订阅 `cmd/{imei}` 接收指令，上报 `device/{imei}/online`（上线）与 `device/{imei}/result`（任务结果）
- 面板通过 REST API 下发任务，服务端转 MQTT 推送给设备并等待回报（30 秒超时）

## 目录结构

```
air724ug_web_panel/
├── script/               # 设备端 Lua 固件
│   ├── main.lua          # 入口：初始化、MQTT/Gotify 监听启动
│   ├── config.lua        # 设备端默认配置（通知/MQTT/音量/来电动作等）
│   ├── nvm_para.lua      # 设备端参数文件【参考模板】（可写入配置的示例）
│   ├── lib/              # 底层库（nvm / mqtt / sys 等）
│   ├── utils/            # 功能模块（util_mqtt / util_notify / util_mobile 等）
│   └── handler/          # 事件处理（短信 / 来电 / 电源键菜单）
├── server-go/            # Go 服务端（当前主版本）
│   ├── main.go           # 入口：加载配置、启动 HTTP + MQTT
│   ├── api.go            # REST API 与静态资源（go:embed）
│   ├── broker.go         # MQTT Broker、设备在线管理、任务下发
│   ├── db.go             # SQLite 持久化
│   ├── config.go         # 配置加载/保存
│   ├── config.json       # 服务端配置（账号、端口、MQTT）
│   ├── web/              # 前端源码（Tailwind，源码目录）
│   ├── static/           # 前端构建产物（编译进二进制）
│   ├── build-web.ps1     # 前端构建脚本（Tailwind CLI + 复制到 static）
│   ├── sim_device.py     # 模拟设备脚本（TCP MQTT 联调用）
│   ├── sim_device_ws.py  # 模拟设备脚本（WebSocket MQTT 联调用）
│   ├── Dockerfile
│   └── panel-server.exe  # 构建产物
├── docker-compose.yml    # Docker 一键部署
└── core/                 # 设备端底层固件包
```

## 快速开始（Go 服务端）

### 本地运行

前置：Go 1.22+（本项目使用纯 Go 的 `modernc.org/sqlite`，无需 CGO）。

```bash
cd server-go
go build -o panel-server.exe .
./panel-server.exe
```

默认配置：

- HTTP 面板：`http://127.0.0.1:9527`
- MQTT Broker：`0.0.0.0:1883`
- 默认账号：`admin / admin123`（可在面板「设置」中修改用户名/密码，或编辑 `config.json`）

### 前端构建（改动 web/ 后需重新构建）

前端源码在 `server-go/web/`，构建产物在 `server-go/static/`（编译时通过 `go:embed` 内嵌进二进制，改动后需重新 `go build`）。

```powershell
# 依赖 E:\tool\go-sdk\tailwindcss.exe（Tailwind 独立 CLI）
cd server-go
powershell -ExecutionPolicy Bypass -File .\build-web.ps1
go build -o panel-server.exe .
```

### Docker 部署

**方式一：使用已发布镜像（推荐）**

镜像已发布到 Docker Hub：`vipiu/air724ug_panel`（linux/amd64 + linux/arm64）

```bash
# 拉取镜像
docker pull vipiu/air724ug_panel:latest

# 启动容器
docker run -d --name air724ug-panel --restart unless-stopped \
  -p 9527:9527 \
  -p 1883:1883 \
  -p 8083:8083 \
  -v panel-data:/app/data \
  vipiu/air724ug_panel:latest
```

- `-p 9527` HTTP 面板；`-p 1883` MQTT TCP；`-p 8083` MQTT WebSocket（nginx 反代 wss 用）
- `-v panel-data:/app/data` SQLite 数据持久化到命名卷；容器内首次启动会自动生成默认配置（账号 `admin / admin123`，登录后请及时修改）
- 公网仅暴露 443 给 nginx 反代时，无需映射 1883/8083

**方式二：本地构建 + docker-compose**

```bash
docker-compose up -d
```

`docker-compose.yml` 暴露 `9527`（HTTP）、`1883`（MQTT TCP）与 `8083`（MQTT WebSocket），SQLite 数据通过卷 `panel-data` 持久化到容器 `/app/data/panel.db`。

### WSS 加密接入（推荐，公网部署）

MQTT WebSocket 监听在 `8083` 端口（明文 ws）。公网部署建议用 nginx 做 TLS 终结并反代，设备以 `wss://你的域名/websocket` 一条链接接入，全程加密：

```nginx
server {
    listen 443 ssl;
    server_name panel.example.com;

    ssl_certificate     /etc/nginx/ssl/fullchain.pem;   # 你的证书
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;

    # 设备 MQTT over WSS：/websocket -> 127.0.0.1:8083
    location /websocket {
        proxy_pass http://127.0.0.1:8083;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }

    # Web 面板
    location / {
        proxy_pass http://127.0.0.1:9527;
    }
}
```

> 若 80/443 与 Go 服务端不在同一台机器，把 `proxy_pass` 指向服务端 IP 即可；仅需开放 443，**无需**暴露 1883/8083 到公网。

## 设备端固件对接

1. 将 `script/` 目录内容按原结构烧录到设备（底层固件见 `core/`）
2. 在 `script/config.lua` 中配置服务端地址，**推荐单链接 `MQTT_URL`**（一条链接搞定）：

```lua
-- 公网（推荐）：wss 加密，nginx 反代 443
MQTT_URL = "wss://panel.example.com/websocket"
-- 内网明文 WebSocket：
-- MQTT_URL = "ws://192.168.1.100:8083/websocket"
-- 内网 MQTT 明文：
-- MQTT_URL = "mqtt://192.168.1.100:1883"

MQTT_KEEPALIVE = 300   -- 心跳间隔（秒），仅在此间隔发 2 字节心跳包，可降低流量
```

> 也兼容旧参数 `MQTT_HOST` / `MQTT_PORT`（TCP 明文，`MQTT_URL` 留空时生效）。

3. `main.lua` 检测到 `MQTT_URL` 或 `MQTT_HOST` 任一非空即自动启动 MQTT 连接；同时需配置一个通知渠道（如 gotify）用于接收设备事件。

### 设备端参数文件 nvm_para.lua

设备端掉电保存的实时参数文件（`/nvm_para.lua`，备份 `/nvm_para_bak.lua`），优先级高于 `config.lua`。仓库内 `script/nvm_para.lua` 提供了**全部可写参数的注释示例**，可直接复制到面板「任务执行 → 写入配置」中使用，支持远程配置：

- **通知方式**：`NOTIFY_TYPE` 及 gotify/telegram/bark/钉钉/飞书/企业微信等渠道参数
- **MQTT 参数**：`MQTT_URL`（推荐单链接）/ `MQTT_HOST` / `MQTT_PORT` / `MQTT_KEEPALIVE` 等
- 音量、来电动作、短信播报、开机通知、网卡、指示灯、SIM pin、录音上传地址等

> 生效规则：固件用 `nvm.get()` 读取的参数（音量/来电动作/短信播报/开机通知等）写入后**重启持久生效**；用 `config.xxx` 读取的参数（MQTT 地址/通知渠道）写入后**当前运行立即生效**，跨重启持久生效需同步修改 `config.lua`。

## Web 面板功能

- **设备列表**：IMEI / 备注 / 手机号 / 在线状态 / 接入时间，支持在线编辑设备备注、一键跳转执行任务
- **任务执行**：三步向导式指挥台（选择设备 → 选择任务类型 → 下发执行），内置终端风格实时控制台展示执行过程
- **任务类型**：查询温度、发送短信、读取配置（返回 `nvm_para.lua` 内容）、写入配置（覆盖 `nvm_para.lua`）
- **任务记录**：最近 50 条执行记录（成功/失败 + 结果详情）
- **设置**：修改登录用户名 / 密码

## API 一览

| 方法 | 路径 | 说明 | 鉴权 |
| --- | --- | --- | --- |
| POST | `/api/login` | 登录，返回 JWT | 否 |
| POST | `/api/logout` | 退出登录 | 是 |
| POST | `/api/change-user-info` | 修改用户名/密码 | 是 |
| GET | `/api/userPool` | 设备列表 | 是 |
| POST | `/api/device/remark` | 设置设备备注（`{imei, name}`，name 为空表示清除） | 是 |
| POST | `/api/executeTask` | 下发任务（`{imei, task, ...}`） | 是 |
| GET | `/api/tasks` | 任务记录（最近 50 条） | 是 |
| GET | `/api/health` | 健康检查 | 否 |

## 服务端配置（config.json）

```json
{
  "jwtSecret": "会话签名密钥",
  "user": { "username": "登录用户名", "password": "bcrypt 密文" },
  "tokenVersion": 1,
  "port": 9527,
  "mqtt": { "host": "0.0.0.0", "port": 1883, "wsPort": 8083 },
  "dbPath": "panel.db"
}
```

- `mqtt.port`：MQTT TCP 监听端口（内网明文直连，公网不建议暴露）
- `mqtt.wsPort`：MQTT WebSocket 监听端口，0 表示不启用；供 nginx 反代 wss 使用

## 模拟设备联调（无实体设备）

- `server-go/sim_device.py`：通过 MQTT TCP（1883）模拟接入
- `server-go/sim_device_ws.py`：通过 MQTT over WebSocket（8083，验证 wss 链路）模拟接入，依赖 `paho-mqtt`

```bash
cd server-go
python sim_device.py
# 或验证 WebSocket 链路：
python sim_device_ws.py
```

## 免责声明

本项目仅供学习与技术研究，请勿用于非法用途及盈利。
