package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
)

func main() {
	configFile := flag.String("config", "config.json", "配置文件路径")
	dbFile := flag.String("db", "panel.db", "SQLite 数据库文件路径")
	httpPort := flag.Int("http-port", 0, "HTTP 监听端口（覆盖配置文件）")
	flag.Parse()

	cfg, err := loadConfig(*configFile)
	if err != nil {
		log.Fatalf("加载配置失败: %v", err)
	}
	if *httpPort > 0 {
		cfg.Port = *httpPort
	}
	if *dbFile != "panel.db" {
		cfg.DBPath = *dbFile
	}

	db, err := openDB(cfg.DBPath)
	if err != nil {
		log.Fatalf("打开数据库失败: %v", err)
	}

	app, err := NewApp(cfg, db)
	if err != nil {
		log.Fatalf("初始化失败: %v", err)
	}
	app.Start()
	app.StartScheduler()

	api := &API{app: app, cfg: cfg}
	server := &http.Server{
		Addr:    fmt.Sprintf(":%d", cfg.Port),
		Handler: api.routes(),
	}

	log.Printf("======================================================")
	log.Printf(" AirPanel (Go)")
	log.Printf(" HTTP 面板   : http://0.0.0.0:%d", cfg.Port)
	log.Printf(" MQTT over WSS: /websocket（与面板共享端口 %d，nginx 反代 wss://域名/websocket 至该端口）", cfg.Port)
	if cfg.MQTT.Port > 0 {
		log.Printf(" MQTT TCP(可选): mqtt://%s:%d（仅内网直连）", cfg.MQTT.Host, cfg.MQTT.Port)
	} else {
		log.Printf(" MQTT TCP   : 未启用（公网仅走 WebSocket/WSS）")
	}
	log.Printf(" 数据库     : %s", cfg.DBPath)
	log.Printf("======================================================")

	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("HTTP 服务异常退出: %v", err)
	}
}
