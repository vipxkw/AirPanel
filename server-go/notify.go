package main

// 通知模块：服务端离线通知，对接设备端 Lua 的 13 种通知渠道
// 参考 script/utils/util_notify.lua 移植为 Go 实现

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// NotifyField 通知渠道的单个配置字段
type NotifyField struct {
	Key         string `json:"key"`
	Label       string `json:"label"`
	Type        string `json:"type"` // text | password | number | textarea
	Placeholder string `json:"placeholder,omitempty"`
	Required    bool   `json:"required,omitempty"`
}

// NotifyChannelDef 通知渠道定义（供前端渲染配置表单）
type NotifyChannelDef struct {
	Name   string        `json:"name"`
	Label  string        `json:"label"`
	Fields []NotifyField `json:"fields"`
}

// notifyChannelDefs 返回全部支持的通知渠道定义
func notifyChannelDefs() []NotifyChannelDef {
	defs := []NotifyChannelDef{
		{
			Name: "message-pusher", Label: "Message-Pusher",
			Fields: []NotifyField{
				{Key: "api", Label: "服务地址", Type: "text", Placeholder: "https://push.example.com", Required: true},
				{Key: "username", Label: "用户名", Type: "text", Placeholder: "message-pusher 登录账号", Required: true},
				{Key: "title", Label: "消息标题", Type: "text", Placeholder: "可选"},
				{Key: "channel", Label: "推送通道", Type: "text", Placeholder: "如 wechat/lark/telegram/bark/ding/corp，留空用后台默认"},
				{Key: "token", Label: "令牌 Token", Type: "password", Placeholder: "可选"},
			},
		},
		{
			Name: "serverchan", Label: "Server酱",
			Fields: []NotifyField{
				{Key: "api", Label: "SendKey 地址", Type: "text", Placeholder: "https://sctapi.ftqq.com/SCT...send", Required: true},
				{Key: "title", Label: "消息标题", Type: "text", Placeholder: "必填", Required: true},
			},
		},
		{
			Name: "dingtalk", Label: "钉钉",
			Fields: []NotifyField{
				{Key: "webhook", Label: "Webhook 地址", Type: "text", Placeholder: "https://oapi.dingtalk.com/robot/send?access_token=...", Required: true},
				{Key: "secret", Label: "加签密钥", Type: "password", Placeholder: "可选，配置后使用加签方式"},
			},
		},
		{
			Name: "feishu", Label: "飞书",
			Fields: []NotifyField{
				{Key: "webhook", Label: "Webhook 地址", Type: "text", Placeholder: "https://open.feishu.cn/open-apis/bot/v2/hook/...", Required: true},
			},
		},
		{
			Name: "wecom", Label: "企业微信",
			Fields: []NotifyField{
				{Key: "webhook", Label: "Webhook 地址", Type: "text", Placeholder: "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...", Required: true},
			},
		},
		{
			Name: "bark", Label: "Bark",
			Fields: []NotifyField{
				{Key: "api", Label: "服务地址", Type: "text", Placeholder: "https://api.day.app", Required: true},
				{Key: "key", Label: "设备 Key", Type: "text", Placeholder: "推送 Key", Required: true},
			},
		},
		{
			Name: "pushdeer", Label: "PushDeer",
			Fields: []NotifyField{
				{Key: "api", Label: "服务地址", Type: "text", Placeholder: "https://api2.pushdeer.com/message/push", Required: true},
				{Key: "key", Label: "PushKey", Type: "password", Placeholder: "PushDeer 设备 PushKey", Required: true},
			},
		},
		{
			Name: "pushover", Label: "Pushover",
			Fields: []NotifyField{
				{Key: "api_token", Label: "应用 Token", Type: "password", Placeholder: "Application Token", Required: true},
				{Key: "user_key", Label: "用户 Key", Type: "text", Placeholder: "User Key", Required: true},
			},
		},
		{
			Name: "telegram", Label: "Telegram",
			Fields: []NotifyField{
				{Key: "api", Label: "Bot API 地址", Type: "text", Placeholder: "https://api.telegram.org/bot<TOKEN>/sendMessage", Required: true},
				{Key: "chat_id", Label: "Chat ID", Type: "text", Placeholder: "接收消息的会话 ID", Required: true},
			},
		},
		{
			Name: "gotify", Label: "Gotify",
			Fields: []NotifyField{
				{Key: "api", Label: "服务地址", Type: "text", Placeholder: "https://gotify.example.com", Required: true},
				{Key: "token", Label: "应用 Token", Type: "password", Placeholder: "必填", Required: true},
				{Key: "title", Label: "消息标题", Type: "text", Placeholder: "默认: 设备离线通知"},
				{Key: "priority", Label: "优先级", Type: "number", Placeholder: "默认 5"},
			},
		},
		{
			Name: "custom_post", Label: "自定义 HTTP POST",
			Fields: []NotifyField{
				{Key: "url", Label: "请求地址", Type: "text", Placeholder: "https://example.com/notify", Required: true},
				{Key: "content_type", Label: "Content-Type", Type: "text", Placeholder: "application/json", Required: true},
				{Key: "body", Label: "请求体模板", Type: "textarea", Placeholder: "支持 {msg} 占位符，如：{\"content\":\"{msg}\"}", Required: true},
			},
		},
		{
			Name: "inotify", Label: "iNotify",
			Fields: []NotifyField{
				{Key: "api", Label: "推送地址", Type: "text", Placeholder: "如 https://example.com/send/xxx.send", Required: true},
			},
		},
		{
			Name: "next-smtp-proxy", Label: "SMTP 邮件转发",
			Fields: []NotifyField{
				{Key: "api", Label: "转发服务地址", Type: "text", Placeholder: "next-smtp-proxy 服务地址", Required: true},
				{Key: "user", Label: "发件账号", Type: "text", Placeholder: "必填", Required: true},
				{Key: "password", Label: "发件密码", Type: "password", Placeholder: "必填", Required: true},
				{Key: "host", Label: "SMTP 主机", Type: "text", Placeholder: "如 smtp.qq.com", Required: true},
				{Key: "port", Label: "SMTP 端口", Type: "number", Placeholder: "如 465", Required: true},
				{Key: "form_name", Label: "发件人名称", Type: "text", Placeholder: "可选"},
				{Key: "to_email", Label: "收件邮箱", Type: "text", Placeholder: "必填", Required: true},
				{Key: "subject", Label: "邮件主题", Type: "text", Placeholder: "默认: 设备离线通知"},
			},
		},
	}
	return defs
}

var notifyHTTPClient = &http.Client{Timeout: 15 * time.Second}

// notifyRequest 发起 HTTP 请求，返回状态码与响应体
func notifyRequest(method, reqURL, contentType string, body io.Reader) (int, []byte, error) {
	var reqBody io.Reader = body
	if body == nil {
		reqBody = nil
	}
	req, err := http.NewRequest(method, reqURL, reqBody)
	if err != nil {
		return 0, nil, err
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	resp, err := notifyHTTPClient.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return resp.StatusCode, data, err
}

// utf8sub 按字符数安全截取（等价 Lua utf8sub）
func utf8sub(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

// encodeForm 将键值对编码为 application/x-www-form-urlencoded
func encodeForm(params map[string]string) string {
	v := url.Values{}
	for k, val := range params {
		v.Set(k, val)
	}
	return v.Encode()
}

// isSuccess 判断通知是否发送成功（2xx 即成功；个别渠道在响应体内标记失败）
func isSuccess(code int) bool {
	return code >= 200 && code < 300
}

// sendNotify 通过指定渠道发送通知
// @param msg     通知内容
// @param channel 渠道名称（notifyChannelDefs 中的 name）
// @param conf    该渠道的配置项（key -> value）
func sendNotify(msg, channel string, conf map[string]string) error {
	if msg == "" {
		return fmt.Errorf("通知内容为空")
	}
	if conf == nil {
		conf = map[string]string{}
	}
	switch channel {
	case "message-pusher":
		return notifyMessagePusher(msg, conf)
	case "serverchan":
		return notifyServerchan(msg, conf)
	case "dingtalk":
		return notifyDingtalk(msg, conf)
	case "feishu":
		return notifyFeishu(msg, conf)
	case "wecom":
		return notifyWecom(msg, conf)
	case "bark":
		return notifyBark(msg, conf)
	case "pushdeer":
		return notifyPushdeer(msg, conf)
	case "pushover":
		return notifyPushover(msg, conf)
	case "telegram":
		return notifyTelegram(msg, conf)
	case "gotify":
		return notifyGotify(msg, conf)
	case "custom_post":
		return notifyCustomPost(msg, conf)
	case "inotify":
		return notifyInotify(msg, conf)
	case "next-smtp-proxy":
		return notifyNextSMTPProxy(msg, conf)
	default:
		return fmt.Errorf("未知通知渠道: %s", channel)
	}
}

// ---------------- 各渠道实现 ----------------

func notifyMessagePusher(msg string, c map[string]string) error {
	api := c["api"]
	if api == "" || c["username"] == "" {
		return fmt.Errorf("message-pusher 未配置 api/username")
	}
	body := map[string]string{
		"content":     msg,
		"description": utf8sub(msg, 50),
	}
	for _, k := range []string{"title", "channel", "token"} {
		if v := c[k]; v != "" {
			body[k] = v
		}
	}
	u := strings.TrimRight(api, "/") + "/push/" + url.PathEscape(c["username"])
	code, res, err := notifyRequest("POST", u, "application/x-www-form-urlencoded", strings.NewReader(encodeForm(body)))
	if err != nil {
		return err
	}
	if !isSuccess(code) {
		return fmt.Errorf("message-pusher 返回 %d: %s", code, truncate(string(res), 200))
	}
	return nil
}

func notifyServerchan(msg string, c map[string]string) error {
	if c["api"] == "" || c["title"] == "" {
		return fmt.Errorf("serverchan 未配置 api/title")
	}
	body := map[string]string{"title": c["title"], "desp": msg}
	code, res, err := notifyRequest("POST", c["api"], "application/x-www-form-urlencoded", strings.NewReader(encodeForm(body)))
	if err != nil {
		return err
	}
	if !isSuccess(code) {
		return fmt.Errorf("serverchan 返回 %d: %s", code, truncate(string(res), 200))
	}
	return nil
}

func notifyDingtalk(msg string, c map[string]string) error {
	if c["webhook"] == "" {
		return fmt.Errorf("钉钉未配置 webhook")
	}
	u := c["webhook"]
	if c["secret"] != "" {
		ts := strconv.FormatInt(time.Now().UnixMilli(), 10)
		signStr := ts + "\n" + c["secret"]
		mac := hmac.New(sha256.New, []byte(c["secret"]))
		mac.Write([]byte(signStr))
		sign := base64.StdEncoding.EncodeToString(mac.Sum(nil))
		sep := "?"
		if strings.Contains(u, "?") {
			sep = "&"
		}
		u = u + sep + "timestamp=" + ts + "&sign=" + url.QueryEscape(sign)
	}
	payload, _ := json.Marshal(map[string]any{
		"msgtype": "text",
		"text":    map[string]string{"content": msg},
	})
	code, res, err := notifyRequest("POST", u, "application/json; charset=utf-8", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	// 钉钉限流/系统繁忙/时间戳无效视为发送失败
	if code == 200 && len(res) > 0 {
		var d struct {
			ErrCode int    `json:"errcode"`
			ErrMsg  string `json:"errmsg"`
		}
		if json.Unmarshal(res, &d) == nil {
			if d.ErrCode == -1 || d.ErrCode == 410100 {
				return fmt.Errorf("钉钉发送受限: %s", d.ErrMsg)
			}
			if d.ErrCode == 310000 && strings.Contains(d.ErrMsg, "timestamp") {
				return fmt.Errorf("钉钉时间戳无效: %s", d.ErrMsg)
			}
		}
	}
	if !isSuccess(code) {
		return fmt.Errorf("钉钉返回 %d: %s", code, truncate(string(res), 200))
	}
	return nil
}

func notifyFeishu(msg string, c map[string]string) error {
	if c["webhook"] == "" {
		return fmt.Errorf("飞书未配置 webhook")
	}
	payload, _ := json.Marshal(map[string]any{
		"msg_type": "text",
		"content":  map[string]string{"text": msg},
	})
	code, res, err := notifyRequest("POST", c["webhook"], "application/json; charset=utf-8", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	if !isSuccess(code) {
		return fmt.Errorf("飞书返回 %d: %s", code, truncate(string(res), 200))
	}
	return nil
}

func notifyWecom(msg string, c map[string]string) error {
	if c["webhook"] == "" {
		return fmt.Errorf("企业微信未配置 webhook")
	}
	payload, _ := json.Marshal(map[string]any{
		"msgtype": "text",
		"text":    map[string]string{"content": msg},
	})
	code, res, err := notifyRequest("POST", c["webhook"], "application/json; charset=utf-8", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	if !isSuccess(code) {
		return fmt.Errorf("企业微信返回 %d: %s", code, truncate(string(res), 200))
	}
	return nil
}

func notifyBark(msg string, c map[string]string) error {
	if c["api"] == "" || c["key"] == "" {
		return fmt.Errorf("bark 未配置 api/key")
	}
	u := strings.TrimRight(c["api"], "/") + "/" + url.PathEscape(c["key"])
	body := map[string]string{"body": msg}
	code, res, err := notifyRequest("POST", u, "application/x-www-form-urlencoded", strings.NewReader(encodeForm(body)))
	if err != nil {
		return err
	}
	if !isSuccess(code) {
		return fmt.Errorf("bark 返回 %d: %s", code, truncate(string(res), 200))
	}
	return nil
}

func notifyPushdeer(msg string, c map[string]string) error {
	if c["api"] == "" || c["key"] == "" {
		return fmt.Errorf("pushdeer 未配置 api/key")
	}
	body := map[string]string{"pushkey": c["key"], "type": "text", "text": msg}
	code, res, err := notifyRequest("POST", c["api"], "application/x-www-form-urlencoded", strings.NewReader(encodeForm(body)))
	if err != nil {
		return err
	}
	if !isSuccess(code) {
		return fmt.Errorf("pushdeer 返回 %d: %s", code, truncate(string(res), 200))
	}
	return nil
}

func notifyPushover(msg string, c map[string]string) error {
	if c["api_token"] == "" || c["user_key"] == "" {
		return fmt.Errorf("pushover 未配置 api_token/user_key")
	}
	payload, _ := json.Marshal(map[string]string{
		"token": c["api_token"], "user": c["user_key"], "message": msg,
	})
	code, res, err := notifyRequest("POST", "https://api.pushover.net/1/messages.json", "application/json; charset=utf-8", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	if !isSuccess(code) {
		return fmt.Errorf("pushover 返回 %d: %s", code, truncate(string(res), 200))
	}
	return nil
}

func notifyTelegram(msg string, c map[string]string) error {
	if c["api"] == "" || c["chat_id"] == "" {
		return fmt.Errorf("telegram 未配置 api/chat_id")
	}
	payload, _ := json.Marshal(map[string]any{
		"chat_id": c["chat_id"], "disable_web_page_preview": true, "text": msg,
	})
	code, res, err := notifyRequest("POST", c["api"], "application/json", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	if !isSuccess(code) {
		return fmt.Errorf("telegram 返回 %d: %s", code, truncate(string(res), 200))
	}
	return nil
}

func notifyGotify(msg string, c map[string]string) error {
	if c["api"] == "" || c["token"] == "" {
		return fmt.Errorf("gotify 未配置 api/token")
	}
	title := c["title"]
	if title == "" {
		title = "设备离线通知"
	}
	prio := 5
	if p, err := strconv.Atoi(c["priority"]); err == nil {
		prio = p
	}
	payload, _ := json.Marshal(map[string]any{
		"title": title, "message": msg, "priority": prio,
	})
	u := strings.TrimRight(c["api"], "/") + "/message?token=" + url.QueryEscape(c["token"])
	code, res, err := notifyRequest("POST", u, "application/json; charset=utf-8", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	if !isSuccess(code) {
		return fmt.Errorf("gotify 返回 %d: %s", code, truncate(string(res), 200))
	}
	return nil
}

func notifyCustomPost(msg string, c map[string]string) error {
	if c["url"] == "" || c["body"] == "" {
		return fmt.Errorf("custom_post 未配置 url/body")
	}
	contentType := c["content_type"]
	if contentType == "" {
		contentType = "application/json"
	}
	// 请求体模板中的 {msg} 替换为通知内容
	tmpl := strings.ReplaceAll(c["body"], "{msg}", msg)
	var body string
	if strings.Contains(contentType, "json") {
		// 校验为合法 JSON
		var obj any
		if err := json.Unmarshal([]byte(tmpl), &obj); err != nil {
			return fmt.Errorf("custom_post body 不是合法 JSON: %v", err)
		}
		body = tmpl
	} else {
		// 表单格式：k=v&k2=v2，仅对值中的 {msg} 已替换，整体重新编码
		form, err := url.ParseQuery(tmpl)
		if err != nil {
			return fmt.Errorf("custom_post body 表单解析失败: %v", err)
		}
		body = form.Encode()
	}
	code, res, err := notifyRequest("POST", c["url"], contentType, strings.NewReader(body))
	if err != nil {
		return err
	}
	if !isSuccess(code) {
		return fmt.Errorf("custom_post 返回 %d: %s", code, truncate(string(res), 200))
	}
	return nil
}

func notifyInotify(msg string, c map[string]string) error {
	if c["api"] == "" {
		return fmt.Errorf("inotify 未配置 api")
	}
	u := strings.TrimRight(c["api"], "/") + "/" + url.PathEscape(msg)
	code, res, err := notifyRequest("GET", u, "", nil)
	if err != nil {
		return err
	}
	if !isSuccess(code) {
		return fmt.Errorf("inotify 返回 %d: %s", code, truncate(string(res), 200))
	}
	return nil
}

func notifyNextSMTPProxy(msg string, c map[string]string) error {
	for _, k := range []string{"api", "user", "password", "host", "port", "to_email"} {
		if c[k] == "" {
			return fmt.Errorf("next-smtp-proxy 未配置 %s", k)
		}
	}
	subject := c["subject"]
	if subject == "" {
		subject = "设备离线通知"
	}
	body := map[string]string{
		"user": c["user"], "password": c["password"], "host": c["host"],
		"port": c["port"], "form_name": c["form_name"], "to_email": c["to_email"],
		"subject": subject, "text": msg,
	}
	code, res, err := notifyRequest("POST", c["api"], "application/x-www-form-urlencoded", strings.NewReader(encodeForm(body)))
	if err != nil {
		return err
	}
	if !isSuccess(code) {
		return fmt.Errorf("next-smtp-proxy 返回 %d: %s", code, truncate(string(res), 200))
	}
	return nil
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "..."
}
