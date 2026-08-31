package main

// 面板设置：登录账号 / 离线通知，全部存储于 SQLite settings 表
// 账号信息从 config.json 迁移至数据库，后续登录/改密均走数据库

import (
	"encoding/json"
	"log"

	"golang.org/x/crypto/bcrypt"
)

// Settings 面板设置（账号 / 离线通知）
type Settings struct {
	Username       string                       `json:"username"`
	Password       string                       `json:"-"` // bcrypt 哈希，不返回给前端
	NotifyEnabled  bool                         `json:"notifyEnabled"`  // 是否启用离线通知
	NotifyChannels []string                     `json:"notifyChannels"` // 启用的通知渠道
	NotifyConfig   map[string]map[string]string `json:"notifyConfig"`   // 各渠道配置项
}

// settings 表的键名
const (
	settingUsername       = "username"
	settingPassword       = "password"
	settingNotifyEnabled  = "notify_enabled"
	settingNotifyChannels = "notify_channels"
	settingNotifyConfig   = "notify_config"
)

// defaultOfflineTimeout 固定离线判定超时（秒）= 5 分钟，不支持远程修改。
// 设备心跳默认 2 分钟，允许连续漏 2 次心跳才判离线，避免网络抖动误报。
const defaultOfflineTimeout = 300

func boolToStr(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

// ---------------- DB 存取 ----------------

// loadSettings 从数据库读取设置（不存在则返回默认值）
func (d *DB) loadSettings() (*Settings, error) {
	all, err := d.allSettings()
	if err != nil {
		return nil, err
	}
	s := &Settings{
		Username:      all[settingUsername],
		Password:      all[settingPassword],
		NotifyEnabled: all[settingNotifyEnabled] == "1",
		NotifyConfig:  map[string]map[string]string{},
	}
	if s.Username == "" {
		s.Username = "admin"
	}
	if v := all[settingNotifyChannels]; v != "" {
		_ = json.Unmarshal([]byte(v), &s.NotifyChannels)
	}
	if v := all[settingNotifyConfig]; v != "" {
		_ = json.Unmarshal([]byte(v), &s.NotifyConfig)
	}
	if s.NotifyConfig == nil {
		s.NotifyConfig = map[string]map[string]string{}
	}
	return s, nil
}

// saveSettings 将设置整体写入数据库
func (d *DB) saveSettings(s *Settings) error {
	if s.Username == "" {
		s.Username = "admin"
	}
	if s.NotifyConfig == nil {
		s.NotifyConfig = map[string]map[string]string{}
	}
	ch, _ := json.Marshal(s.NotifyChannels)
	if len(ch) == 0 {
		ch = []byte("[]")
	}
	cf, _ := json.Marshal(s.NotifyConfig)
	if len(cf) == 0 {
		cf = []byte("{}")
	}
	pairs := [][2]string{
		{settingUsername, s.Username},
		{settingPassword, s.Password},
		{settingNotifyEnabled, boolToStr(s.NotifyEnabled)},
		{settingNotifyChannels, string(ch)},
		{settingNotifyConfig, string(cf)},
	}
	for _, kv := range pairs {
		if err := d.setSetting(kv[0], kv[1]); err != nil {
			return err
		}
	}
	return nil
}

// ---------------- App 缓存与辅助 ----------------

// initSettings 启动时加载设置；若数据库尚无账号（首次升级），从 config.json 迁移账号并写入默认值
func (a *App) initSettings() {
	s, err := a.db.loadSettings()
	if err != nil {
		log.Printf("读取设置失败: %v", err)
		s, _ = a.db.loadSettings()
	}
	if s.Password == "" {
		s.Username = a.cfg.User.Username
		if s.Username == "" {
			s.Username = "admin"
		}
		s.Password = a.cfg.User.Password
		if s.Password == "" {
			// 兜底：生成默认密码（admin123）哈希，保证可登录
			if h, herr := bcrypt.GenerateFromPassword([]byte("admin123"), 10); herr == nil {
				s.Password = string(h)
			}
		}
		s.NotifyEnabled = false
		s.NotifyChannels = []string{}
		if err := a.db.saveSettings(s); err != nil {
			log.Printf("初始化设置失败: %v", err)
		}
		log.Printf("已将账号信息迁移至数据库（后续账号/通知设置均存储于数据库）")
	}
	a.settingsMu.Lock()
	a.settings = s
	a.settingsMu.Unlock()
}

// getSettings 返回设置的深拷贝（含密码哈希，仅供服务端使用）
func (a *App) getSettings() *Settings {
	a.settingsMu.RLock()
	defer a.settingsMu.RUnlock()
	if a.settings == nil {
		return &Settings{
			Username: "admin", NotifyEnabled: false,
			NotifyConfig: map[string]map[string]string{},
		}
	}
	s := *a.settings
	s.NotifyChannels = append([]string{}, a.settings.NotifyChannels...)
	nc := make(map[string]map[string]string, len(a.settings.NotifyConfig))
	for k, v := range a.settings.NotifyConfig {
		mv := make(map[string]string, len(v))
		for kk, vv := range v {
			mv[kk] = vv
		}
		nc[k] = mv
	}
	s.NotifyConfig = nc
	return &s
}

// saveSettings 保存设置并更新内存缓存
func (a *App) saveSettings(s *Settings) error {
	if err := a.db.saveSettings(s); err != nil {
		return err
	}
	a.settingsMu.Lock()
	a.settings = s
	a.settingsMu.Unlock()
	return nil
}

// offlineTimeout 返回固定离线判定超时（秒），供巡检协程使用
func (a *App) offlineTimeout() int {
	return defaultOfflineTimeout
}
