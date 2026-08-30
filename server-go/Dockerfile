# ---------- 构建阶段 ----------
# 使用 golang 官方镜像编译 Go 服务端
FROM golang:1.22-alpine AS builder

WORKDIR /build

# 先拷贝依赖清单，利用 Docker 层缓存，避免每次重复下载依赖
COPY go.mod go.sum ./
RUN go mod download

# 拷贝源码及前端静态文件（static/ 由 go:embed 内嵌进二进制）
COPY . .

# 项目使用纯 Go 实现（modernc.org/sqlite 不依赖 CGO），可静态编译
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o panel-server .

# ---------- 运行阶段 ----------
FROM alpine:3.20

WORKDIR /app

# 安装 CA 证书（设备端 HTTPS 通知等场景）与完整时区数据
RUN apk add --no-cache ca-certificates tzdata

# 设定容器时区为北京时间，保证定时任务按东八区判断周期
ENV TZ=Asia/Shanghai

COPY --from=builder /build/panel-server /app/panel-server

# config.json 含敏感凭据，不入镜像也不入库；
# 首次启动时服务会自动生成默认配置（admin/admin123），如需自定义可用卷挂载 config.json

# SQLite 数据库持久化目录（通过卷挂载）
VOLUME ["/app/data"]

# 单端口：HTTP 面板 + MQTT over WebSocket（/websocket）共用 9527
EXPOSE 9527

ENTRYPOINT ["/app/panel-server"]
CMD ["-config", "/app/config.json", "-db", "/app/data/panel.db"]
