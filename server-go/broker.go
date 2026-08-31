package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
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

	settingsMu sync.RWMutex
	settings   *Settings // 面板设置（账号/通知/离线超时），DB 缓存的只读副本
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

	// MQTT TCP 监听（可选，内网直连场景）：port=0 时禁用。
	// 默认只走 WebSocket —— MQTT over WSS 与 HTTP 面板共享同一端口（路径 /websocket），
	// 公网仅需开放面板端口，nginx 把 /websocket 反代到面板端口即可。
	if cfg.MQTT.Port > 0 {
		addr := fmt.Sprintf("%s:%d", cfg.MQTT.Host, cfg.MQTT.Port)
		tcp := listeners.NewTCP("t1", addr, nil)
		if err := broker.AddListener(tcp); err != nil {
			return nil, fmt.Errorf("启动 MQTT 监听 %s 失败: %w", addr, err)
		}
	}

	app.broker = broker
	return app, nil
}

// Start 启动 broker 的事件循环
func (a *App) Start() {
	// 加载设置（首次运行时从 config.json 迁移账号到数据库）
	a.initSettings()

	// 服务启动时重置所有设备为离线（清理上次运行残留的在线状态，
	// 服务异常退出/升级重启不会触发 OnDisconnect，设备重连上报 online 后自动恢复）
	if err := a.db.resetAllOffline(); err != nil {
		log.Printf("重置设备在线状态失败: %v", err)
	}
	go func() {
		if err := a.broker.Serve(); err != nil {
			log.Printf("MQTT broker 异常退出: %v", err)
		}
	}()
	// 离线巡检：定期扫描设备，超过设置时限未上报则判定离线并通知
	go a.patrolLoop()
}

// patrolLoop 离线巡检协程（每 30 秒一次）
func (a *App) patrolLoop() {
	time.Sleep(5 * time.Second)
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		a.checkOffline()
	}
}

// checkOffline 检查设备心跳超时：超过 offlineTimeout 未收到任何上报的设备判定为离线
// （TCP/WS 连接可能在网络抖动时静默断开，OnDisconnect 不触发，此处兜底）
func (a *App) checkOffline() {
	timeout := int64(a.offlineTimeout())
	if timeout <= 0 {
		return
	}
	now := time.Now().Unix()
	var offline []Device
	a.mu.Lock()
	for imei, st := range a.devices {
		if st.Connected && now-st.LastSeen > timeout {
			st.Connected = false // 提前置离线，防止重复触发
			offline = append(offline, Device{IMEI: imei, Phone: st.Phone, LastSeen: st.LastSeen})
		}
	}
	a.mu.Unlock()

	for _, d := range offline {
		if err := a.db.upsertDevice(d.IMEI, "", false, now); err != nil {
			log.Printf("更新设备离线状态失败: %v", err)
		}
		log.Printf("设备离线超时判定 - IMEI: %s（超过 %d 秒未上报）", d.IMEI, timeout)
		a.notifyDeviceOffline(d)
	}
}

// notifyDeviceOffline 推送设备离线通知（按设置中启用的渠道逐个发送）
func (a *App) notifyDeviceOffline(d Device) {
	s := a.getSettings()
	if !s.NotifyEnabled || len(s.NotifyChannels) == 0 {
		return
	}
	name := a.db.getDeviceName(d.IMEI)
	lastSeen := "—"
	if d.LastSeen > 0 {
		lastSeen = time.Unix(d.LastSeen, 0).Format("2006-01-02 15:04:05")
	}
	devLabel := d.IMEI
	if name != "" {
		devLabel = name + "（" + d.IMEI + "）"
	}
	msg := fmt.Sprintf("【设备离线】\n设备: %s\n最后活跃: %s", devLabel, lastSeen)
	for _, ch := range s.NotifyChannels {
		if err := sendNotify(msg, ch, s.NotifyConfig[ch]); err != nil {
			log.Printf("离线通知发送失败 channel=%s: %v", ch, err)
		} else {
			log.Printf("离线通知已发送 channel=%s imei=%s", ch, d.IMEI)
		}
	}
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

// OnDisconnect 设备断开：延迟检查避免 session takeover 竞态条件
// 当新连接接管同 clientID 的旧连接时，旧连接的 OnDisconnect 可能在
// 新连接上线后才异步触发，导致设备被误判为离线。
func (h *AppHook) OnDisconnect(cl *mqtt.Client, err error, expire bool) {
	imei := cl.ID
	if imei == "" {
		return
	}
	log.Printf("设备连接断开 - IMEI: %s, 原因: %v, expire: %v", imei, err, expire)
	// 延迟 5 秒再检查：如果设备在此期间重新上线（新连接发送 online），
	// markDeviceOffline 会检测到 LastSeen 是最近更新的，不标记离线
	go func() {
		time.Sleep(5 * time.Second)
		h.app.markDeviceOffline(imei)
	}()
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
		// 首次上线（离线→在线转变）时回复连接成功；心跳上报仅刷新 lastSeen，不重复回复
		wasOffline := !a.isDeviceOnline(imei)
		a.upsertDevice(imei, msg.Phone, true)
		if wasOffline {
			reply := fmt.Sprintf(`{"type":"connection_success","message":"连接成功"}`)
			_ = a.broker.Publish(topicPrefixCmd+imei, []byte(reply), false, 1)
			log.Printf("设备上线 - IMEI: %s, 手机号: %s", imei, msg.Phone)
		} else {
			log.Printf("设备心跳 - IMEI: %s", imei)
		}

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
	if phone != "" {
		st.Phone = phone
	}
	st.Connected = connected
	st.LastSeen = now
	a.mu.Unlock()

	if err := a.db.upsertDevice(imei, phone, connected, now); err != nil {
		log.Printf("写入设备记录失败: %v", err)
	}
}

// markDeviceOffline 设备断开：标记离线，且从在线转为离线时发送离线通知
// 延迟调用（OnDisconnect 延迟 5 秒）：先查询 broker 中该 IMEI 是否仍有存活连接
// （session takeover 时新连接已接管，旧连接的 OnDisconnect 不应把设备判离线）
func (a *App) markDeviceOffline(imei string) {
	if imei == "" {
		return
	}
	// 权威判断：broker 中该 clientID 仍有存活连接则说明设备已重连，忽略旧连接断开
	if cl, ok := a.broker.Clients.Get(imei); ok && !cl.Closed() {
		log.Printf("设备仍有存活连接，忽略断开标记 - IMEI: %s", imei)
		return
	}

	now := time.Now().Unix()
	var wasOnline bool
	var phone, lastSeen = "", int64(0)
	shouldMarkOffline := false

	a.mu.Lock()
	if st, ok := a.devices[imei]; ok {
		wasOnline = st.Connected
		st.Connected = false
		phone = st.Phone
		lastSeen = st.LastSeen
		shouldMarkOffline = true
	}
	a.mu.Unlock()

	if !shouldMarkOffline {
		// 内存中无此设备（可能已被删除），仅在记录已存在时更新为离线，
		// 不能 upsert —— 否则会把刚删除的设备重新写回数据库
		if err := a.db.markDeviceOfflineExisting(imei, now); err != nil {
			log.Printf("更新设备离线状态失败: %v", err)
		}
		return
	}

	if err := a.db.upsertDevice(imei, "", false, now); err != nil {
		log.Printf("更新设备离线状态失败: %v", err)
	}
	log.Printf("设备已离线 - IMEI: %s（最后活跃 %d秒前）", imei, now-lastSeen)
	if wasOnline {
		a.notifyDeviceOffline(Device{IMEI: imei, Phone: phone, LastSeen: lastSeen})
	}
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

// deleteDevice 删除设备：若在线先断开其 MQTT 连接（否则心跳会立刻重新登记），再清理内存与数据库
func (a *App) deleteDevice(imei string) error {
	if cl, ok := a.broker.Clients.Get(imei); ok && !cl.Closed() {
		log.Printf("删除设备 - 断开在线连接 - IMEI: %s", imei)
		if err := a.broker.DisconnectClient(cl, packets.CodeDisconnect); err != nil {
			log.Printf("断开设备连接失败 imei=%s: %v", imei, err)
		}
	}
	a.mu.Lock()
	delete(a.devices, imei)
	a.mu.Unlock()
	return a.db.deleteDevice(imei)
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
	// 设备回报 error 时（如不支持的任务类型）把原因带回调用方，
	// 前端可见具体错误而不是 null
	res := any(msg.Result)
	if msg.Error != "" {
		res = map[string]any{"error": msg.Error}
	}
	select {
	case p.ch <- res:
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

// MQTTWebSocketHandler 返回共享 HTTP 端口的 MQTT over WebSocket handler（路径 /websocket）。
// 设备以 wss://host/websocket 接入：公网 nginx 只需把 /websocket 反代到面板端口（默认 9527）。
func (a *App) MQTTWebSocketHandler() http.Handler {
	upgrader := websocket.Upgrader{
		Subprotocols: []string{"mqtt"},
		CheckOrigin:  func(r *http.Request) bool { return true },
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			log.Printf("MQTT WebSocket 升级失败: %v", err)
			return
		}
		if err := a.broker.EstablishConnection("ws", &mqttWSConn{Conn: c}); err != nil {
			log.Printf("MQTT WebSocket 连接建立失败: %v", err)
			_ = c.Close()
		}
	})
}

// mqttWSConn 将 WebSocket 二进制帧桥接为 net.Conn，供 mochi-mqtt 建立客户端连接。
type mqttWSConn struct {
	*websocket.Conn
	mu sync.Mutex
	r  io.Reader
}

func (c *mqttWSConn) Read(p []byte) (int, error) {
	if c.r == nil {
		op, r, err := c.NextReader()
		if err != nil {
			return 0, err
		}
		if op != websocket.BinaryMessage {
			return 0, errors.New("mqtt websocket: 非二进制消息")
		}
		c.r = r
	}
	n, err := c.r.Read(p)
	if err == io.EOF {
		c.r = nil
		err = nil
	}
	return n, err
}

func (c *mqttWSConn) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.WriteMessage(websocket.BinaryMessage, p); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (c *mqttWSConn) Close() error {
	return c.Conn.Close()
}

func (c *mqttWSConn) SetDeadline(t time.Time) error {
	if err := c.Conn.SetReadDeadline(t); err != nil {
		return err
	}
	return c.Conn.SetWriteDeadline(t)
}
