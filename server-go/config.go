package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"os"

	"golang.org/x/crypto/bcrypt"
)

// Config 服务端配置
type Config struct {
	JWTSecret    string   `json:"jwtSecret"`
	User         UserConf `json:"user"`
	TokenVersion int      `json:"tokenVersion"`
	Port         int      `json:"port"`
	MQTT         MQTTConf `json:"mqtt"`
	DBPath       string   `json:"dbPath"`

	configFile string `json:"-"` // 配置文件路径（不参与序列化）
}

// UserConf 管理用户
type UserConf struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// MQTTConf 内嵌 MQTT broker 监听配置
// MQTT 走 WebSocket 与 HTTP 面板共享同一端口（路径 /websocket），公网只需开放面板端口；
// TCP 监听（port）仅用于内网直连场景，0 表示不启用（默认只走 WebSocket/WSS）。
type MQTTConf struct {
	Host string `json:"host"`
	Port int    `json:"port"` // MQTT TCP 监听端口，0 表示不启用
}

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			// 配置文件不存在：自动生成默认配置（首次部署免配置，后续可改文件或面板）
			return newDefaultConfig(path)
		}
		return nil, err
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	cfg.configFile = path
	// 默认值
	if cfg.Port == 0 {
		cfg.Port = 9527
	}
	if cfg.MQTT.Host == "" {
		cfg.MQTT.Host = "0.0.0.0"
	}
	// 注：MQTT 走 WebSocket 共享 HTTP 端口（/websocket），无需独立 MQTT 端口
	if cfg.DBPath == "" {
		cfg.DBPath = "panel.db"
	}
	return &cfg, nil
}

// newDefaultConfig 生成一份可用的默认配置并写入磁盘
func newDefaultConfig(path string) (*Config, error) {
	secret, err := randomHex(32)
	if err != nil {
		return nil, err
	}
	hash, err := bcrypt.GenerateFromPassword([]byte("admin123"), 10)
	if err != nil {
		return nil, err
	}
	cfg := &Config{
		JWTSecret:    secret,
		User:         UserConf{Username: "admin", Password: string(hash)},
		TokenVersion: 1,
		Port:         9527,
		MQTT:         MQTTConf{Host: "0.0.0.0", Port: 0},
		DBPath:       "panel.db",
		configFile:   path,
	}
	if err := cfg.Save(); err != nil {
		return nil, err
	}
	log.Printf("未找到配置文件 %s，已自动生成默认配置（账号 admin / 密码 admin123），建议登录后及时修改密码", path)
	return cfg, nil
}

// randomHex 生成 n 字节的随机十六进制字符串（用于 JWT 密钥）
func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// Save 将当前配置写回文件
func (c *Config) Save() error {
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(c.configFile, data, 0o644)
}
