package main

import (
	"encoding/json"
	"errors"
	"log"
	"strconv"
	"time"
)

// Schedule 定时任务记录
type Schedule struct {
	ID           int64           `json:"id"`
	Name         string          `json:"name"`
	IMEI         string          `json:"imei"`
	DeviceName   string          `json:"deviceName,omitempty"`
	Task         string          `json:"task"`
	Params       string          `json:"params"` // JSON 对象字符串，作为任务附加参数
	Spec         json.RawMessage `json:"spec"`   // 执行周期 JSON
	Enabled      bool            `json:"enabled"`
	CreatedAt    int64           `json:"createdAt"`
	LastExecuted int64           `json:"lastExecuted"`
	LastCheck    int64           `json:"-"` // 最近一次周期判定（含离线跳过），用于去重
}

// scheduleSpec 执行周期（宝塔面板-计划任务风格）
// type: weekly 每周 / monthly 每月 / daily 每天 / hourly 每小时 / interval 每N分钟|每N小时
type scheduleSpec struct {
	Type    string `json:"type"`
	Weekday int    `json:"weekday,omitempty"` // 0=周日 ... 6=周六（weekly）
	Day     int    `json:"day,omitempty"`     // 每月几日（monthly）
	Hour    int    `json:"hour,omitempty"`
	Minute  int    `json:"minute,omitempty"`
	N       int    `json:"n,omitempty"`    // 间隔数值（interval）
	Unit    string `json:"unit,omitempty"` // minute / hour（interval）
}

var weekdayNames = []string{"周日", "周一", "周二", "周三", "周四", "周五", "周六"}

// describe 人类可读的周期描述
func (s scheduleSpec) describe() string {
	hm := func() string {
		return pad2(s.Hour) + " 点 " + pad2(s.Minute) + " 分"
	}
	switch s.Type {
	case "weekly":
		if s.Weekday >= 0 && s.Weekday < 7 {
			return "每周" + weekdayNames[s.Weekday] + " " + hm()
		}
	case "monthly":
		return "每月 " + pad2(s.Day) + " 日 " + hm()
	case "daily":
		return "每天 " + hm()
	case "hourly":
		return "每小时 " + pad2(s.Minute) + " 分"
	case "interval":
		if s.Unit == "hour" {
			return "每 " + itoa(s.N) + " 小时"
		}
		return "每 " + itoa(s.N) + " 分钟"
	}
	return "未知周期"
}

func pad2(n int) string {
	if n < 10 {
		return "0" + itoa(n)
	}
	return itoa(n)
}

func itoa(n int) string {
	return strconv.Itoa(n)
}

// validateSpec 校验执行周期参数
func validateSpec(raw json.RawMessage) error {
	if len(raw) == 0 {
		return errors.New("缺少执行周期")
	}
	var s scheduleSpec
	if err := json.Unmarshal(raw, &s); err != nil {
		return errors.New("执行周期格式错误")
	}
	switch s.Type {
	case "weekly":
		if s.Weekday < 0 || s.Weekday > 6 || s.Hour < 0 || s.Hour > 23 || s.Minute < 0 || s.Minute > 59 {
			return errors.New("每周周期参数超出范围")
		}
	case "monthly":
		if s.Day < 1 || s.Day > 31 || s.Hour < 0 || s.Hour > 23 || s.Minute < 0 || s.Minute > 59 {
			return errors.New("每月周期参数超出范围")
		}
	case "daily":
		if s.Hour < 0 || s.Hour > 23 || s.Minute < 0 || s.Minute > 59 {
			return errors.New("每天周期参数超出范围")
		}
	case "hourly":
		if s.Minute < 0 || s.Minute > 59 {
			return errors.New("每小时周期参数超出范围")
		}
	case "interval":
		if s.N < 1 || (s.Unit != "minute" && s.Unit != "hour") {
			return errors.New("间隔周期参数错误")
		}
		if s.Unit == "minute" && s.N > 59 {
			return errors.New("分钟间隔最大 59")
		}
		if s.Unit == "hour" && s.N > 23 {
			return errors.New("小时间隔最大 23")
		}
	default:
		return errors.New("不支持的周期类型")
	}
	return nil
}

// isDeviceOnline 判断设备当前是否在线
func (a *App) isDeviceOnline(imei string) bool {
	a.mu.RLock()
	st, ok := a.devices[imei]
	online := ok && st.Connected
	a.mu.RUnlock()
	return online
}

// StartScheduler 启动定时任务调度循环（每 30 秒检查一次）
func (a *App) StartScheduler() {
	go func() {
		// 启动后先等一个周期，避免与 broker 初始化抢资源
		time.Sleep(10 * time.Second)
		a.runDueSchedules()
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			a.runDueSchedules()
		}
	}()
	log.Printf("定时任务调度器已启动（每 30 秒检查一次，设备离线时静默跳过）")
}

// runDueSchedules 检查并执行到期的定时任务
func (a *App) runDueSchedules() {
	list, err := a.db.listSchedules()
	if err != nil {
		log.Printf("[定时任务] 读取任务列表失败: %v", err)
		return
	}
	now := time.Now()
	for _, sc := range list {
		if !sc.Enabled {
			continue
		}
		var spec scheduleSpec
		if err := json.Unmarshal(sc.Spec, &spec); err != nil {
			log.Printf("[定时任务] #%d 周期解析失败，已跳过: %v", sc.ID, err)
			continue
		}
		if !spec.due(now, sc.LastCheck, sc.CreatedAt) {
			continue
		}

		// 设备离线：静默跳过（仅推进判定时间，不执行、不记录、不通知）
		if !a.isDeviceOnline(sc.IMEI) {
			_ = a.db.markScheduleProcessed(sc.ID, false)
			continue
		}

		// 先推进判定时间，再异步执行（ExecuteTask 最多等待 30 秒，不能阻塞调度循环）
		_ = a.db.markScheduleProcessed(sc.ID, true)
		go func(sc Schedule) {
			var extra map[string]any
			if sc.Params != "" && sc.Params != "{}" {
				if err := json.Unmarshal([]byte(sc.Params), &extra); err != nil {
					log.Printf("[定时任务] #%d 参数解析失败: %v", sc.ID, err)
					return
				}
			}
			if extra == nil {
				extra = map[string]any{}
			}
			log.Printf("[定时任务] 执行 #%d %s -> %s（%s）", sc.ID, sc.IMEI, sc.Task, spec.describe())
			_, err := a.ExecuteTask(sc.IMEI, sc.Task, extra)
			if err != nil {
				log.Printf("[定时任务] #%d 执行失败: %v", sc.ID, err)
			}
		}(sc)
	}
}

// due 判断某时刻是否命中周期。lastCheck 为上次判定时间（去重依据），createdAt 为任务创建时间（interval 基准）。
// 时间点类周期（每周/每月/每天/每小时）只在命中那一分钟内触发；服务重启错过的整点不补执行（与宝塔一致）。
func (s scheduleSpec) due(now time.Time, lastCheck, createdAt int64) bool {
	switch s.Type {
	case "interval":
		var interval time.Duration
		if s.Unit == "hour" {
			interval = time.Duration(s.N) * time.Hour
		} else {
			interval = time.Duration(s.N) * time.Minute
		}
		if interval <= 0 {
			return false
		}
		baseline := lastCheck
		if baseline < createdAt {
			baseline = createdAt
		}
		return now.Unix()-baseline >= int64(interval.Seconds())

	case "daily":
		t := time.Date(now.Year(), now.Month(), now.Day(), s.Hour, s.Minute, 0, 0, now.Location())
		return inMinute(now, t) && lastCheck < t.Unix()

	case "hourly":
		t := now.Truncate(time.Hour).Add(time.Duration(s.Minute) * time.Minute)
		return inMinute(now, t) && lastCheck < t.Unix()

	case "weekly":
		offset := (int(now.Weekday()) - s.Weekday + 7) % 7
		day := now.AddDate(0, 0, -offset)
		t := time.Date(day.Year(), day.Month(), day.Day(), s.Hour, s.Minute, 0, 0, now.Location())
		return inMinute(now, t) && lastCheck < t.Unix()

	case "monthly":
		if now.Day() != s.Day {
			return false
		}
		t := time.Date(now.Year(), now.Month(), s.Day, s.Hour, s.Minute, 0, 0, now.Location())
		return inMinute(now, t) && lastCheck < t.Unix()
	}
	return false
}

// inMinute 判断 now 是否落在 [t, t+1min) 这一分钟内
func inMinute(now, t time.Time) bool {
	u := now.Unix()
	return u >= t.Unix() && u < t.Unix()+60
}
