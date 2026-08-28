package main

import (
	"crypto/subtle"
	"embed"
	"encoding/json"
	"io/fs"
	"log"
	"net/http"
	"path"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"
)

//go:embed static/*
var staticFS embed.FS

// 认证相关状态
var (
	authMu        sync.Mutex
	invalidTokens = map[string]int64{} // token -> 过期时间(ms)
)

// API 服务
type API struct {
	app *App
	cfg *Config
}

func (api *API) routes() http.Handler {
	mux := http.NewServeMux()

	// REST API
	mux.HandleFunc("/api/login", api.handleLogin)
	mux.HandleFunc("/api/logout", api.authenticate(api.handleLogout))
	mux.HandleFunc("/api/change-user-info", api.authenticate(api.handleChangeUserInfo))
	mux.HandleFunc("/api/userPool", api.authenticate(api.handleUserPool))
	mux.HandleFunc("/api/device/remark", api.authenticate(api.handleUpdateDeviceRemark))
	mux.HandleFunc("/api/executeTask", api.authenticate(api.handleExecuteTask))
	mux.HandleFunc("/api/tasks", api.authenticate(api.handleTasks))
	mux.HandleFunc("/api/tasks/clear", api.authenticate(api.handleClearTasks))
	mux.HandleFunc("/api/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	})

	// MQTT over WebSocket：与面板共享同一端口（nginx 把 /websocket 反代到本端口）
	mux.Handle("/websocket", api.app.MQTTWebSocketHandler())

	// 静态资源 + SPA 回退
	mux.HandleFunc("/", api.handleStatic)

	return mux
}

// ---------------- 认证 ----------------

// authenticate 校验 Bearer Token
func (api *API) authenticate(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		authHeader := r.Header.Get("Authorization")
		token := ""
		if strings.HasPrefix(authHeader, "Bearer ") {
			token = strings.TrimPrefix(authHeader, "Bearer ")
		}
		if token == "" {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"message": "未提供认证令牌"})
			return
		}

		authMu.Lock()
		if exp, ok := invalidTokens[token]; ok && exp > time.Now().UnixMilli() {
			authMu.Unlock()
			writeJSON(w, http.StatusForbidden, map[string]any{"message": "token已失效"})
			return
		}
		authMu.Unlock()

		claims := jwt.MapClaims{}
		parsed, err := jwt.ParseWithClaims(token, claims, func(t *jwt.Token) (any, error) {
			return []byte(api.cfg.JWTSecret), nil
		})
		if err != nil || !parsed.Valid {
			writeJSON(w, http.StatusForbidden, map[string]any{"message": "无效的认证令牌"})
			return
		}
		if v, ok := claims["version"]; ok {
			ver, _ := v.(float64)
			if int(ver) != api.cfg.TokenVersion {
				writeJSON(w, http.StatusForbidden, map[string]any{"message": "token已过期，请重新登录"})
				return
			}
		}
		next(w, r)
	}
}

// ---------------- 接口实现 ----------------

func (api *API) handleLogin(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"message": "请求体格式错误"})
		return
	}
	cfg := api.cfg
	if subtle.ConstantTimeCompare([]byte(body.Username), []byte(cfg.User.Username)) != 1 ||
		bcrypt.CompareHashAndPassword([]byte(cfg.User.Password), []byte(body.Password)) != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"message": "用户名或密码错误"})
		return
	}

	claims := jwt.MapClaims{
		"username": body.Username,
		"version":  cfg.TokenVersion,
		"exp":      time.Now().Add(24 * time.Hour).Unix(),
	}
	tk := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	tokenStr, err := tk.SignedString([]byte(cfg.JWTSecret))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"message": "生成令牌失败"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"token": tokenStr})
}

func (api *API) handleLogout(w http.ResponseWriter, r *http.Request) {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if token != "" {
		authMu.Lock()
		invalidTokens[token] = time.Now().Add(24 * time.Hour).UnixMilli()
		authMu.Unlock()
	}
	writeJSON(w, http.StatusOK, map[string]any{"message": "退出登录成功"})
}

func (api *API) handleChangeUserInfo(w http.ResponseWriter, r *http.Request) {
	var body struct {
		OldPassword string `json:"oldPassword"`
		NewUsername string `json:"newUsername"`
		NewPassword string `json:"newPassword"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"message": "请求体格式错误"})
		return
	}
	cfg := api.cfg
	if bcrypt.CompareHashAndPassword([]byte(cfg.User.Password), []byte(body.OldPassword)) != nil {
		writeJSON(w, http.StatusOK, map[string]any{"message": "原密码错误"})
		return
	}

	hasChanges := false
	if body.NewUsername != "" && body.NewUsername != cfg.User.Username {
		cfg.User.Username = body.NewUsername
		hasChanges = true
	}
	if body.NewPassword != "" {
		hash, err := bcrypt.GenerateFromPassword([]byte(body.NewPassword), 10)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"message": "加密失败"})
			return
		}
		cfg.User.Password = string(hash)
		hasChanges = true
	}
	if hasChanges {
		cfg.TokenVersion++
	}
	if err := api.cfg.Save(); err != nil {
		log.Printf("保存配置失败: %v", err)
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"message":    "用户信息修改成功",
		"username":   cfg.User.Username,
		"needRelogin": hasChanges,
	})
}

func (api *API) handleUserPool(w http.ResponseWriter, r *http.Request) {
	devices, err := api.app.deviceList()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"message": "查询设备失败"})
		return
	}
	writeJSON(w, http.StatusOK, devices)
}

func (api *API) handleUpdateDeviceRemark(w http.ResponseWriter, r *http.Request) {
	var body struct {
		IMEI string `json:"imei"`
		Name string `json:"name"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"message": "请求体格式错误"})
		return
	}
	body.Name = strings.TrimSpace(body.Name)
	if body.IMEI == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"message": "缺少设备 IMEI"})
		return
	}
	if err := api.app.updateDeviceName(body.IMEI, body.Name); err != nil {
		log.Printf("保存设备备注失败: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]any{"message": "保存备注失败"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"message": "备注已保存"})
}

func (api *API) handleExecuteTask(w http.ResponseWriter, r *http.Request) {
	raw := map[string]any{}
	if err := decodeJSON(r, &raw); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"success": false, "message": "请求体格式错误"})
		return
	}
	imei, _ := raw["imei"].(string)
	task, _ := raw["task"].(string)
	if imei == "" || task == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"success": false, "message": "缺少必要参数"})
		return
	}
	// 其余字段作为任务附加参数转发给设备
	delete(raw, "imei")
	delete(raw, "task")

	result, err := api.app.ExecuteTask(imei, task, raw)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"success": false, "message": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "result": result})
}

func (api *API) handleTasks(w http.ResponseWriter, r *http.Request) {
	tasks, err := api.app.db.recentTasks(50)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"message": "查询任务失败"})
		return
	}
	writeJSON(w, http.StatusOK, tasks)
}

// handleClearTasks 删除任务记录。body: {"days": 7} 表示删除 7 天前的旧日志（保留近 7 天）；days <= 0 或缺省表示删除全部。
func (api *API) handleClearTasks(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Days int `json:"days"`
	}
	// 允许空请求体（视为删除全部）
	if err := decodeJSON(r, &body); err != nil && err.Error() != "EOF" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"message": "请求体格式错误"})
		return
	}
	n, err := api.app.db.deleteTasks(body.Days)
	if err != nil {
		log.Printf("删除任务记录失败: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]any{"message": "删除失败"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"message": "删除成功", "deleted": n})
}

// ---------------- 静态资源 ----------------

func (api *API) handleStatic(w http.ResponseWriter, r *http.Request) {
	// 只处理 GET/HEAD
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"message": "方法不允许"})
		return
	}
	p := strings.TrimPrefix(path.Clean(r.URL.Path), "/")
	if p == "." || p == "" {
		p = "index.html"
	}

	sub, err := fs.Sub(staticFS, "static")
	if err != nil {
		http.Error(w, "静态资源不可用", http.StatusInternalServerError)
		return
	}

	// 尝试真实文件
	if f, err := sub.Open(p); err == nil {
		f.Close()
		http.ServeFileFS(w, r, sub, p)
		return
	}
	// SPA 回退到 index.html
	http.ServeFileFS(w, r, sub, "index.html")
}

// ---------------- 工具 ----------------

func decodeJSON(r *http.Request, v any) error {
	defer r.Body.Close()
	return json.NewDecoder(r.Body).Decode(v)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
