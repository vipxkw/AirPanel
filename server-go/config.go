package main

import (
	"encoding/json"
	"os"
)

// Config 服务端配置
type Config struct {
	JWTSecret    string   `json:"jwtSecret"`
	User         UserConf `json:"user"`
	TokenVersion int      `json:"tokenVersion"`
	Port         int      `json:"port"`
	MQTT         MQTTConf `json:"mqtt"`
	DBPath       string   `json:"dbPath"`

	configFile string // 配置文件路径（不参与序列化）
}

// UserConf 管理用户
type UserConf struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// MQTTConf 内嵌 MQTT broker 监听配置
type MQTTConf struct {
	Host string `json:"host"`
	Port int    `json:"port"`
}

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
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
	if cfg.MQTT.Port == 0 {
		cfg.MQTT.Port = 1883
	}
	if cfg.MQTT.Host == "" {
		cfg.MQTT.Host = "0.0.0.0"
	}
	if cfg.DBPath == "" {
		cfg.DBPath = "panel.db"
	}
	return &cfg, nil
}

// Save 将当前配置写回文件
func (c *Config) Save() error {
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(c.configFile, data, 0o644)
}
