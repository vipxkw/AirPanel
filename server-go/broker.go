package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	mqtt "github.com/mochi-mqtt/server/v2"
	"github.com/mochi-mqtt/server/v2/hooks/auth"
	"github.com/mochi-mqtt/server/v2/listeners"
	"github.com/mochi-mqtt/server/v2/packets"
)

// 主题前缀约定
const (
	topicPrefixDevice = "device/" // device/{imei}/online | device/{imei}/result
	topicPrefixCmd    = "cmd/"    // cmd/{imei} 服务端下发指令
)

// Device 设备信息（用于 API 返回）
type Device struct {
	IMEI      string `json:"imei"`
	Phone     string `json:"phone"`
	Name      string `json:"name"`
	Connected bool   `json:"connected"`
	LastSeen  int64  `json:"lastSeen"`
	FirstSeen int64  `json:"firstSeen"`
}

// DeviceState 内存中的设备在线状态
type DeviceState struct {
	Phone     string
	Connected bool
	LastSeen  int64
}

// TaskRecord 任务执行记录
type TaskRecord struct {
	TaskID     string `json:"taskId"`
	IMEI       string `json:"imei"`
	DeviceName string `json:"deviceName,omitempty"` // 关联的设备备注名（可为空）
	Task       string `json:"task"`
	Params     string `json:"params"`
	Result     string `json:"result"`
	Error      string `json:"error"`
	Status     string `json:"status"`
	CreatedAt  int64  `json:"createdAt"`
	FinishedAt int64  `json:"finishedAt"`
}

// onlineMsg 设备上线消息
type onlineMsg struct {
	Phone string `json:"phone"`
	IMEI  string `json:"imei"`
}

// resultMsg 设备任务结果消息
type resultMsg struct {
	TaskID string `json:"taskId"`
	Task   string `json:"task"`
	Result any    `json:"result"`
	Error  string `json:"error"`
}

// pendingTask 挂起的任务（等待设备回报）
type pendingTask struct {
	ch      chan any
	timeout *time.Timer
}

// App 应用主体：内嵌 MQTT broker + 设备状态 + 任务管理
type App struct {
	cfg     *Config
	db      *DB
	broker  *mqtt.Server
	mu      sync.RWMutex
	devices map[string]*DeviceState
	pending sync.Map // taskId -> *pendingTask
}

// NewApp 初始化 MQTT broker 与设备状态
func NewApp(cfg *Config, db *DB) (*App, error) {
	app := &App{
		cfg:     cfg,
		db:      db,
		devices: make(map[string]*DeviceState),
	}

	broker := mqtt.New(&mqtt.Options{InlineClient: true})
	// 允许所有设备接入（本服务面向自有设备）
	if err := broker.AddHook(new(auth.AllowHook), nil); err != nil {
		return nil, fmt.Errorf("添加鉴权 hook 失败: %w", err)
	}
	// 业务 hook：处理设备上下线、消息
	if err := broker.AddHook(&AppHook{app: app}, nil); err != nil {
		return nil, fmt.Errorf("添加业务 hook 失败: %w", err)
	}

	addr := fmt.Sprintf("%s:%d", cfg.MQTT.Host, cfg.MQTT.Port)
	tcp := listeners.NewTCP("t1", addr, nil)
	if err := broker.AddListener(tcp); err != nil {
		return nil, fmt.Errorf("启动 MQTT 监听 %s 失败: %w", addr, err)
	}

	// WebSocket 监听：设备经 nginx 反代 wss 接入（对外仅暴露 443，nginx 将 /websocket 反代到该端口）
	if cfg.MQTT.WSPort > 0 {
		wsAddr := fmt.Sprintf("%s:%d", cfg.MQTT.Host, cfg.MQTT.WSPort)
		ws := listeners.NewWebsocket("ws", wsAddr, nil)
		if err := broker.AddListener(ws); err != nil {
			return nil, fmt.Errorf("启动 MQTT WebSocket 监听 %s 失败: %w", wsAddr, err)
		}
	}

	app.broker = broker
	return app, nil
}

// Start 启动 broker 的事件循环
func (a *App) Start() {
	go func() {
		if err := a.broker.Serve(); err != nil {
			log.Printf("MQTT broker 异常退出: %v", err)
		}
	}()
}

// AppHook 内嵌 broker 的业务钩子
type AppHook struct {
	mqtt.HookBase
	app *App
}

func (h *AppHook) ID() string { return "air724-app-hook" }

func (h *AppHook) Provides(b byte) bool {
	return bytes.Contains([]byte{
		mqtt.OnConnectAuthenticate,
		mqtt.OnACLCheck,
		mqtt.OnDisconnect,
		mqtt.OnPublished,
	}, []byte{b})
}

func (h *AppHook) OnConnectAuthenticate(cl *mqtt.Client, pk packets.Packet) bool { return true }
func (h *AppHook) OnACLCheck(cl *mqtt.Client, topic string, write bool) bool     { return true }

// OnDisconnect 设备断开：将其标记为离线（clientId 即 IMEI）
func (h *AppHook) OnDisconnect(cl *mqtt.Client, err error, expire bool) {
	h.app.markDeviceOffline(cl.ID)
}

// OnPublished 设备上报：处理上线 / 任务结果
func (h *AppHook) OnPublished(cl *mqtt.Client, pk packets.Packet) {
	h.app.handleDevicePublish(cl.ID, pk.TopicName, string(pk.Payload))
}

// handleDevicePublish 解析设备发布的消息
func (a *App) handleDevicePublish(clientID, topic, payload string) {
	switch {
	case strings.HasPrefix(topic, topicPrefixDevice) && strings.HasSuffix(topic, "/online"):
		var msg onlineMsg
		if err := json.Unmarshal([]byte(payload), &msg); err != nil {
			log.Printf("解析上线消息失败: %v, payload: %s", err, payload)
			return
		}
		imei := strings.TrimPrefix(strings.TrimSuffix(topic, "/online"), topicPrefixDevice)
		if imei == "" {
			imei = msg.IMEI
		}
		a.upsertDevice(imei, msg.Phone, true)
		// 回复连接成功
		reply := fmt.Sprintf(`{"type":"connection_success","message":"连接成功"}`, )
		_ = a.broker.Publish(topicPrefixCmd+imei, []byte(reply), false, 1)
		log.Printf("设备上线 - IMEI: %s, 手机号: %s", imei, msg.Phone)

	case strings.HasPrefix(topic, topicPrefixDevice) && strings.HasSuffix(topic, "/result"):
		var msg resultMsg
		if err := json.Unmarshal([]byte(payload), &msg); err != nil {
			log.Printf("解析任务结果失败: %v, payload: %s", err, payload)
			return
		}
		a.completeTask(msg)

	default:
		log.Printf("未知设备消息 topic=%s", topic)
	}
}

// upsertDevice 登记/更新设备在线状态
func (a *App) upsertDevice(imei, phone string, connected bool) {
	now := time.Now().Unix()
	a.mu.Lock()
	st, ok := a.devices[imei]
	if !ok {
		st = &DeviceState{}
		a.devices[imei] = st
	}
	st.Phone = phone
	st.Connected = connected
	st.LastSeen = now
	a.mu.Unlock()

	if err := a.db.upsertDevice(imei, phone, connected, now); err != nil {
		log.Printf("写入设备记录失败: %v", err)
	}
}

// markDeviceOffline 设备断开
func (a *App) markDeviceOffline(imei string) {
	if imei == "" {
		return
	}
	a.mu.Lock()
	if st, ok := a.devices[imei]; ok {
		st.Connected = false
	}
	a.mu.Unlock()

	if err := a.db.upsertDevice(imei, "", false, time.Now().Unix()); err != nil {
		log.Printf("更新设备离线状态失败: %v", err)
	}
	log.Printf("设备已断开 - IMEI: %s", imei)
}

// deviceList 获取设备列表（内存状态 + 数据库）
func (a *App) deviceList() ([]Device, error) {
	devs, err := a.db.listDevices()
	if err != nil {
		return nil, err
	}
	a.mu.RLock()
	for i := range devs {
		if st, ok := a.devices[devs[i].IMEI]; ok {
			devs[i].Connected = st.Connected
			devs[i].LastSeen = st.LastSeen
			if st.Phone != "" {
				devs[i].Phone = st.Phone
			}
		}
	}
	a.mu.RUnlock()
	return devs, nil
}

// updateDeviceName 设置设备备注（空串表示清除）
func (a *App) updateDeviceName(imei, name string) error {
	return a.db.updateDeviceName(imei, name)
}

// ExecuteTask 下发任务给设备并等待结果（30 秒超时）
func (a *App) ExecuteTask(imei, task string, extra map[string]any) (any, error) {
	a.mu.RLock()
	st, ok := a.devices[imei]
	online := ok && st.Connected
	a.mu.RUnlock()
	if !ok || !online {
		return nil, errors.New("用户未连接")
	}

	taskID := fmt.Sprintf("%d", time.Now().UnixMilli())
	resultCh := make(chan any, 1)

	// 30 秒超时
	timeout := time.AfterFunc(30*time.Second, func() {
		a.pending.Delete(taskID)
		select {
		case resultCh <- map[string]any{"error": "任务执行超时"}:
		default:
		}
	})
	a.pending.Store(taskID, &pendingTask{ch: resultCh, timeout: timeout})

	payload := map[string]any{"type": "task", "taskId": taskID, "task": task}
	for k, v := range extra {
		payload[k] = v
	}
	data, _ := json.Marshal(payload)

	if err := a.broker.Publish(topicPrefixCmd+imei, data, false, 1); err != nil {
		timeout.Stop()
		a.pending.Delete(taskID)
		return nil, fmt.Errorf("下发任务失败: %w", err)
	}

	select {
	case res := <-resultCh:
		timeout.Stop()
		a.recordTask(taskID, imei, task, jsonBytes(payload), jsonBytes(res), "", "done")
		return res, nil
	case <-time.After(31 * time.Second):
		a.pending.Delete(taskID)
		return nil, errors.New("任务执行超时")
	}
}

// completeTask 收到设备回报后匹配并完成挂起任务
func (a *App) completeTask(msg resultMsg) {
	if msg.TaskID == "" {
		return
	}
	v, ok := a.pending.Load(msg.TaskID)
	if !ok {
		return
	}
	a.pending.Delete(msg.TaskID)
	p := v.(*pendingTask)
	p.timeout.Stop()
	select {
	case p.ch <- msg.Result:
	default:
	}
}

// recordTask 记录任务执行日志
func (a *App) recordTask(taskID, imei, task, params, result, errMsg, status string) {
	if taskID == "" {
		return
	}
	rec := TaskRecord{
		TaskID:     taskID,
		IMEI:       imei,
		Task:       task,
		Params:     params,
		Result:     result,
		Error:      errMsg,
		Status:     status,
		CreatedAt:  time.Now().Unix(),
		FinishedAt: time.Now().Unix(),
	}
	if err := a.db.recordTask(rec); err != nil {
		log.Printf("记录任务失败: %v", err)
	}
}
