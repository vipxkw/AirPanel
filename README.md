# AirPanel

基于合宙 Air 系列 4G 模组（Air724UG / Air780EP）的远程管理面板与短信/通话转发器。

服务端由 **Go 单二进制**（内置 HTTP 面板 + MQTT Broker），前端使用 **Tailwind CSS** 构建，相比原 WebSocket 方案显著降低设备流量消耗。

> 请勿用于非法用途及盈利。

## 特性

- **设备远程管理**：设备列表、在线状态、一键下发任务（查询温度 / 发送短信 / 读取配置 / 写入配置）、删除设备
- **多硬件支持**：Air724UG（LuatOS-Air）与 Air780EP / Y100E（LuatOS）两种设备端固件，共用同一服务端
- **MQTT 接入**：Go 服务端内置 MQTT Broker，设备端通过 MQTT 对接，心跳仅 2 字节、间隔 30s，节省流量
- **任务记录**：SQLite 持久化任务执行记录，分页查看（每页 10 条）
- **定时任务**：宝塔面板式计划任务，支持每周 / 每月 / 每天 / 每小时 / 每 N 分钟 / 每 N 小时周期自动下发，设备离线时静默跳过该次执行
- **远程配置**：读取 / 写入设备端 `nvm_para.lua` 参数文件，支持动态修改设备配置
- **多通道通知**：设备端支持 gotify / telegram / bark / 钉钉 / 飞书 / 企业微信 / pushover / message-pusher 等通知渠道
- **离线通知**：服务端通过心跳超时（固定 300 秒）或连接断开判定设备离线，支持 13 个通知渠道推送离线告警，并可发送测试通知验证渠道配置
- **断线自愈**：设备端连接失败指数退避重连（5s→60s 封顶），内置双重看门狗（主循环假死 / 长期连不上自动重启自愈），静默断开检测（2 个 keepalive 周期无数据即重连），服务端重部署后设备自动恢复连接，无需人工断电
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
│ Air724UG   │ ◄──────(443 加密)──────►│        nginx (仅443)         │
│ 设备端Lua  │    MQTT over WebSocket   │  /websocket ──┐              │
│ 固件 script│    cmd/{imei} 等主题      │  /  ──────────┼────────────┐ │
└────────────┘                          │              ▼            │ │
                                        │  ┌──────────────────────┐ │ │
                                        │  │   panel-server :9527 │ │ │
                                        │  │ ┌───────┐ ┌────────┐ │ │ │
                                        │  │ │ MQTT  │ │ HTTP   │ │ │ │
                                        │  │ │ Broker│ │ 面板    │ │ │ │
                                        │  │ │ (WS)  │ │ REST+前端│ │ │
                                        │  │ └───────┘ └────────┘ │ │ │
                                        │  │        │ SQLite      │ │ │
                                        │  └────────┴─────────────┘ │ │
                                        └──────────────────────────┘ ┘
```

- 公网仅开放 **一个端口**：nginx 443 终结 TLS，`/websocket` 与 `/` 都反代到 `panel-server` 的 **9527** 端口——MQTT over WSS 与 Web 面板共用同一端口，无需再暴露 1883/8083
- 设备经 **wss（443）** 接入，MQTT 数据封装在 WebSocket 帧中传输，加密且省流量；内网也可用 `ws://host:9527/websocket` 直连，或可选启用 MQTT TCP 内网直连
- 设备订阅 `cmd/{imei}` 接收指令，上报 `device/{imei}/online`（上线）与 `device/{imei}/result`（任务结果）
- 面板通过 REST API 下发任务，服务端转 MQTT 推送给设备并等待回报（30 秒超时）

## 目录结构

```
AirPanel/
├── Air724ug/             # Air724UG 设备端 Lua 固件（LuatOS-Air）
│   ├── core/             # 底层固件包（.pac）
│   └── script/
│       ├── main.lua      # 入口：初始化、MQTT/通知监听启动
│       ├── config.lua    # 设备端默认配置（通知/MQTT/音量/来电动作等，含注释示例）
│       ├── nvm_para.lua  # 设备端参数文件【参考模板】（可写入配置的示例）
│       ├── lib/          # 底层库（nvm / mqtt / websocket / sys 等）
│       ├── utils/        # 功能模块（util_mqtt / util_notify / util_mobile 等）
│       └── handler/      # 事件处理（短信 / 来电 / 电源键菜单）
├── Air780EP(Y100E)/      # Air780EP / Y100E 设备端脚本（LuatOS，银尔达 Y100E）
│   ├── core/             # 底层固件包（.soc）
│   └── script/
│       ├── main.lua      # 入口：初始化、MQTT/通知启动
│       ├── config.lua    # 默认配置 + /lfs 远程覆盖层（set_config 持久化）
│       ├── util_mqtt.lua # MQTT 对接（固件内置 mqtt 库，事件驱动 + 自动重连）
│       ├── util_notify.lua # message-pusher 通知
│       └── util_hw.lua   # GPIO / ADC / 串口硬件操作
├── server-go/            # Go 服务端（当前主版本）
│   ├── main.go           # 入口：加载配置、启动 HTTP + MQTT + 定时任务调度器
│   ├── api.go            # REST API 与静态资源（go:embed）
│   ├── broker.go         # MQTT Broker、设备在线管理、任务下发
│   ├── notify.go         # 离线通知渠道（13 渠道）
│   ├── settings.go       # 面板设置（账号/通知，SQLite 持久化）
│   ├── db.go             # SQLite 持久化
│   ├── scheduler.go      # 定时任务调度器（周期检查 + 自动下发，离线静默跳过）
│   ├── config.go         # 配置加载/保存
│   ├── config.example.json # 服务端配置示例（账号、端口、MQTT）
│   ├── static/           # 前端页面/脚本/CSS（编译进二进制，改动后直接重新 build）
│   ├── sim_device_ws.py  # 模拟设备脚本（WebSocket MQTT 联调用）
│   ├── Dockerfile
│   └── tools/            # 本地工具（tailwindcss CLI 等，不入库）
├── docker-compose.yml    # Docker 一键部署
└── README.md
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

- HTTP 面板 + MQTT over WebSocket（`/websocket`）：`http://127.0.0.1:9527`（单端口）
- 默认账号：`admin / admin123`（可在面板「设置」中修改用户名/密码，或编辑 `config.json`）

### 前端修改（改动 static/ 后需重新构建）

前端资源在 `server-go/static/`（页面、JS、CSS），编译时通过 `go:embed` 内嵌进二进制，改动后重新 `go build` 即生效：

```powershell
cd server-go
go build -o panel-server.exe .
```

> `static/css/style.css` 为 Tailwind 编译产物，缺少的工具类请用内联样式或手动补齐，无需重新编译 Tailwind（`web/` 源目录已移除）。

### Docker 部署

**方式一：使用已发布镜像（推荐）**

镜像已发布到 Docker Hub：`vipiu/airpanel`（linux/amd64 + linux/arm64）

```bash
# 拉取镜像
docker pull vipiu/airpanel:latest

# 启动容器（单端口：面板 + MQTT over WebSocket 共用 9527）
docker run -d --name airpanel --restart unless-stopped \
  -p 9527:9527 \
  -v panel-data:/app/data \
  vipiu/airpanel:latest
```

- `-p 9527` HTTP 面板 + MQTT over WebSocket（`/websocket`）共用，**只需这一个端口**
- `-v panel-data:/app/data` SQLite 数据与 `config.json` 配置统一持久化到命名卷；容器内首次启动会自动生成默认配置（账号 `admin / admin123`，登录后请及时修改），**升级容器不会丢失已修改的账号密码等配置**
- 公网仅暴露 443 给 nginx 反代时，把 `/websocket` 与 `/` 都反代到 `127.0.0.1:9527` 即可

**方式二：本地构建 + docker-compose**

```bash
docker-compose up -d
```

`docker-compose.yml` 仅发布 `9527`（HTTP 面板 + MQTT over WebSocket 共用），SQLite 数据库与 `config.json` 配置通过卷 `panel-data` 持久化到容器 `/app/data/` 下。

> **从旧版本升级**（旧镜像把配置放在 `/app/config.json`）：升级前先导出旧配置，再放入卷：
> ```bash
> docker cp airpanel:/app/config.json ./config.json
> docker compose up -d --build
> docker cp ./config.json airpanel:/app/data/config.json
> docker restart airpanel
> ```
> 之后 `config.json` 与数据库同目录持久化，升级容器不再需要重新配置。

### WSS 加密接入（推荐，公网部署）

MQTT over WebSocket 与 Web 面板共享 `9527` 端口（路径 `/websocket`）。公网部署用 nginx 做 TLS 终结并反代，设备以 `wss://你的域名/websocket` 一条链接接入，全程加密：

```nginx
server {
    listen 443 ssl;
    server_name panel.example.com;

    ssl_certificate     /etc/nginx/ssl/fullchain.pem;   # 你的证书
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;

    # 设备 MQTT over WSS：/websocket -> 127.0.0.1:9527
    location /websocket {
        proxy_pass http://127.0.0.1:9527;
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

> 若 80/443 与 Go 服务端不在同一台机器，把 `proxy_pass` 指向服务端 IP 即可；仅需开放 443，**无需**再暴露任何其它端口。

## 设备端固件对接

支持两种设备端固件，共用同一服务端：

| 设备 | 目录 | 说明 |
| --- | --- | --- |
| Air724UG | `Air724ug/` | LuatOS-Air，自带 mqtt/websocket 库，手写重连循环 + 双看门狗 |
| Air780EP / Y100E | `Air780EP(Y100E)/` | LuatOS，固件内置 mqtt 库（事件驱动 + autoreconn），支持 ws/wss（需 EC618 固件 >= 2025-09-23） |

### Air724UG

1. 将 `Air724ug/script/` 目录内容按原结构烧录到设备（底层固件见 `Air724ug/core/`）
2. 在 `Air724ug/script/config.lua` 中配置服务端地址，**推荐单链接 `MQTT_URL`**（一条链接搞定）：

```lua
-- 公网（推荐）：wss 加密，nginx 反代 443 → 面板端口 /websocket
MQTT_URL = "wss://panel.example.com/websocket"
-- 内网明文 WebSocket（直接连面板端口）：
-- MQTT_URL = "ws://192.168.1.100:9527/websocket"
-- 内网 MQTT TCP（需服务端 config.json 中 mqtt.port > 0 启用）：
-- MQTT_URL = "mqtt://192.168.1.100:1883"

MQTT_KEEPALIVE = 30    -- 心跳间隔（秒），仅在此间隔发 2 字节心跳包，可降低流量；30s 可避免 nginx 空闲超时断开
```

> 也兼容旧参数 `MQTT_HOST` / `MQTT_PORT`（TCP 明文，`MQTT_URL` 留空时生效）。

3. `main.lua` 检测到 `MQTT_URL` 或 `MQTT_HOST` 任一非空即自动启动 MQTT 连接；同时需配置一个通知渠道（如 gotify）用于接收设备事件。

### Air780EP / Y100E（银尔达 Y100E）

1. 将 `Air780EP(Y100E)/script/` 目录内容烧录到设备（底层固件见 `Air780EP(Y100E)/core/`）
2. 在 `Air780EP(Y100E)/script/config.lua` 中配置 `MQTT_URL`（与 Air724UG 格式一致，`wss://` 走 WebSocket 传输，需 EC618 固件 >= 2025-09-23）及 message-pusher 通知参数
3. 支持 `get_status` / `get_device_info` / `set_gpio` / `uart_send` / `set_config`（写入 `/lfs/config_override.json`，重启后自动生效）等任务类型

### 断线重连与自愈机制

设备端 MQTT 采用**长连接 + 自动重连**设计，应对服务端重部署 / 网络波动等场景（以 Air724UG 为例，Y100E 由固件库 autoreconn + 心跳发布失败检测实现同类机制）：

- **重连指数退避**：连接失败后按 5s→10s→20s→40s→60s（封顶）间隔重试，避免密集 SSL 连接风暴冲击模块 socket/AT 通道；服务端恢复后最多 60 秒内自动重连
- **静默断开检测**：超过 2 个 keepalive 周期未收到服务端任何数据即判定断线，主动触发重连（服务端重启 / 网络中断后设备自动恢复，无需人工重启设备）
- **应用层心跳**：按 `HEARTBEAT_INTERVAL`（默认 120 秒）周期上报 `device/{imei}/online`，服务端据此判定在线状态（心跳间隔须 ≤ 离线判定超时的一半）
- **双重看门狗**（独立协程，主循环卡死时依然生效）：
  - `MQTT_STUCK_TIMEOUT`（默认 5 分钟）：MQTT 主循环无响应（假死）→ 自动重启模块自愈
  - `MQTT_REBOOT_TIMEOUT`（默认 15 分钟）：持续连不上服务端（如 socket 通道耗尽）→ 自动重启模块自愈
  - 置 0 可关闭对应检测；均可通过 `nvm_para.lua` 远程覆盖
- **开机通知带原因**：开机推送显示重启原因（按键开机 / 充电开机 / 软件重启 / 异常复位），便于远程区分正常开机与异常重启

### 设备端参数文件 nvm_para.lua

设备端掉电保存的实时参数文件（`/nvm_para.lua`，备份 `/nvm_para_bak.lua`），优先级高于 `config.lua`。仓库内 `Air724ug/script/nvm_para.lua` 提供了**全部可写参数的注释示例**，可直接复制到面板「任务执行 → 写入配置」中使用，支持远程配置：

- **通知方式**：`NOTIFY_TYPE` 及 gotify/telegram/bark/钉钉/飞书/企业微信等渠道参数
- **MQTT 参数**：`MQTT_URL`（推荐单链接）/ `MQTT_HOST` / `MQTT_PORT` / `MQTT_KEEPALIVE` / `HEARTBEAT_INTERVAL`（心跳间隔，默认 120 秒）等
- **自愈参数**：`MQTT_STUCK_TIMEOUT`（假死看门狗，默认 5 分钟）/ `MQTT_REBOOT_TIMEOUT`（连接看门狗，默认 15 分钟），0 关闭
- 音量、来电动作、短信播报、开机通知、网卡、指示灯、SIM pin、录音上传地址等

> 生效规则：固件用 `nvm.get()` 读取的参数（音量/来电动作/短信播报/开机通知等）写入后**重启持久生效**；用 `config.xxx` 读取的参数（MQTT 地址/通知渠道）写入后**当前运行立即生效**，跨重启持久生效需同步修改 `config.lua`。

## Web 面板功能

- **设备列表**：IMEI / 备注 / 手机号 / 在线状态 / 接入时间，支持在线编辑设备备注、一键跳转执行任务、删除设备（在线设备删除时自动断开其连接）
- **任务执行**：三步向导式指挥台（选择设备 → 选择任务类型 → 下发执行），内置终端风格实时控制台展示执行过程
- **任务类型**：支持 13+ 种远程命令（查询温度 / 发送短信 / 读取配置 / 写入配置 / 查询状态 / GPIO 控制 / 重启等），含命令大全与自定义命令
- **定时任务**：宝塔面板式计划任务管理（新增 / 编辑 / 启停 / 删除 / 立即执行），支持全部任务类型，周期可选每周 / 每月 / 每天 / 每小时 / 每 N 分钟 / 每 N 小时，设备离线时静默跳过该次执行
- **任务记录**：执行记录分页查看（每页 10 条，成功/失败 + 结果详情，可清理旧日志）
- **设置**：Tab 式设置页——登录账号（用户名/密码）、离线通知（通知开关 / 13 渠道配置 / 发送测试通知；离线判定超时固定 300 秒）

## API 一览

| 方法 | 路径 | 说明 | 鉴权 |
| --- | --- | --- | --- |
| POST | `/api/login` | 登录，返回 JWT | 否 |
| POST | `/api/logout` | 退出登录 | 是 |
| POST | `/api/change-user-info` | 修改用户名/密码 | 是 |
| GET | `/api/userPool` | 设备列表 | 是 |
| POST | `/api/device/remark` | 设置设备备注（`{imei, name}`，name 为空表示清除） | 是 |
| POST | `/api/device/delete` | 删除设备（`{imei}`，在线设备会先断开其 MQTT 连接） | 是 |
| POST | `/api/executeTask` | 下发任务（`{imei, task, ...}`） | 是 |
| GET | `/api/tasks` | 任务记录（分页，每页 10 条） | 是 |
| POST | `/api/tasks/clear` | 清理任务记录（`{days}`，≤0 清空全部） | 是 |
| GET | `/api/schedules` | 定时任务列表（分页，每页 5 条） | 是 |
| POST | `/api/schedules/add` | 新增定时任务 | 是 |
| POST | `/api/schedules/update` | 编辑定时任务 | 是 |
| POST | `/api/schedules/toggle` | 启用 / 停用定时任务 | 是 |
| POST | `/api/schedules/delete` | 删除定时任务 | 是 |
| POST | `/api/schedules/run` | 立即执行一次定时任务 | 是 |
| GET | `/api/settings` | 读取面板设置（账号 / 离线通知配置） | 是 |
| POST | `/api/settings/save` | 保存离线通知设置（开关 / 渠道 / 渠道配置） | 是 |
| GET | `/api/notify/channels` | 获取 13 个离线通知渠道定义（供前端渲染表单） | 是 |
| POST | `/api/notify/test` | 发送测试通知（按提交的渠道与配置立即推送） | 是 |
| GET | `/api/health` | 健康检查 | 否 |

## 服务端配置（config.json）

```json
{
  "jwtSecret": "会话签名密钥",
  "user": { "username": "登录用户名", "password": "bcrypt 密文" },
  "tokenVersion": 1,
  "port": 9527,
  "mqtt": { "host": "0.0.0.0", "port": 0 },
  "dbPath": "panel.db"
}
```

- `mqtt.port`：MQTT TCP 监听端口，0 表示不启用；公网默认只走 WebSocket/WSS（与面板共享 9527，路径 `/websocket`）
- 账号与离线通知设置存储在 SQLite `settings` 表（首次启动自动从 `config.json` 迁移账号），面板「设置」中修改即时生效

## 模拟设备联调（无实体设备）

`server-go/sim_device_ws.py`：通过 MQTT over WebSocket 模拟接入（验证 wss 链路），依赖 `paho-mqtt`

```bash
cd server-go
python sim_device_ws.py
```

> 脚本默认连公网 wss（`panel.example.com:443`），内网联调请改为 `BROKER = "127.0.0.1"`、`WS_PORT = 9527`、`USE_TLS = False`。

## 免责声明

本项目仅供学习与技术研究，请勿用于非法用途及盈利。
