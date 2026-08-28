-- ============================================================================
-- nvm_para.lua —— 设备端参数文件【参考模板】（以下示例全部已注释）
-- ============================================================================
-- 作用：设备上掉电不丢失的实时参数存储文件（路径 /nvm_para.lua，备份
--       /nvm_para_bak.lua）。开机时由 main.lua 调用 nvm.init("config.lua")
--       自动加载，参数优先级高于 config.lua 默认值。
--
-- 用法：把下方需要的配置项【取消注释】并改成自己的值，然后粘贴到管理面板的
--       「任务执行 → 写入配置」中，即可写入设备并合并到当前运行的 config 表。
--       也可以通过设备端菜单（长按 POWERKEY）在运行时修改部分参数。
--
-- 生效规则（重要）：
--   1. 固件里用 nvm.get() 读取的参数（音量 / 来电动作 / 短信播报 / 开机通知 /
--      网卡 / 指示灯 / SIM pin / 录音上传地址等）：
--      写入后【重启即持久生效】。
--   2. 固件里用 config.xxx 读取的参数（MQTT 地址、通知渠道等）：
--      写入后【当前运行立即生效】；但设备重启后 config 表会恢复为
--      config.lua 默认值，如需跨重启持久生效，请同时修改 script/config.lua。
--
-- 所有键名必须与 config.lua / 固件代码中的名称一致，否则不生效。
-- ============================================================================

-- ------------------------------ 通知方式配置 ------------------------------
-- 通知渠道，可同时配置多个，例如 { "telegram", "bark" }
-- NOTIFY_TYPE = { "gotify" }

-- custom_post：自定义 POST 通知
-- CUSTOM_POST_URL = "https://sctapi.ftqq.com/<SENDKEY>.send"
-- CUSTOM_POST_CONTENT_TYPE = "application/json"
-- CUSTOM_POST_BODY_TABLE = { ["title"] = "这里是标题", ["desp"] = "{msg}" }

-- telegram 通知
-- TELEGRAM_API = "https://api.telegram.org/bot{token}/sendMessage"
-- TELEGRAM_CHAT_ID = ""

-- pushdeer 通知
-- PUSHDEER_API = "https://api2.pushdeer.com/message/push"
-- PUSHDEER_KEY = ""

-- bark 通知
-- BARK_API = "https://api.day.app"
-- BARK_KEY = ""

-- 钉钉机器人通知（加签方式请填 DINGTALK_SECRET，留空则为自定义关键词方式）
-- DINGTALK_WEBHOOK = "https://oapi.dingtalk.com/robot/send?access_token=xxx"
-- DINGTALK_SECRET = ""

-- 飞书机器人通知
-- FEISHU_WEBHOOK = "https://open.feishu.cn/open-apis/bot/v2/hook/xxx"

-- 企业微信机器人通知
-- WECOM_WEBHOOK = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx"

-- pushover 通知
-- PUSHOVER_API_TOKEN = ""
-- PUSHOVER_USER_KEY = ""

-- inotify 通知
-- INOTIFY_API = "https://push.luatos.org/xxx.send"

-- next-smtp-proxy 邮件通知
-- NEXT_SMTP_PROXY_API = ""
-- NEXT_SMTP_PROXY_USER = ""
-- NEXT_SMTP_PROXY_PASSWORD = ""
-- NEXT_SMTP_PROXY_HOST = "smtp-mail.outlook.com"
-- NEXT_SMTP_PROXY_PORT = 587
-- NEXT_SMTP_PROXY_FORM_NAME = "Air724UG"
-- NEXT_SMTP_PROXY_TO_EMAIL = ""
-- NEXT_SMTP_PROXY_SUBJECT = "来自 Air724UG 的通知"

-- gotify 通知（面板默认使用的渠道）
-- GOTIFY_API = "http://127.0.0.1:8080"
-- GOTIFY_TITLE = "转发器"
-- GOTIFY_PRIORITY = 8
-- GOTIFY_TOKEN = ""          -- 应用的 token（需在 gotify 上创建名为 sms 的 app）
-- GOTIFY_CLIENT_TOKEN = ""   -- 客户端的 token

-- message-pusher 通知（https://github.com/vipxkw/message-pusher）
-- 聚合推送服务，可一次推送到微信/钉钉/飞书/Telegram 等，channel 留空则用后台默认通道
-- MESSAGE_PUSHER_API = "https://msgpusher.com"    -- 服务端地址（自建填 http://IP:3000）
-- MESSAGE_PUSHER_USERNAME = "test"                -- 推送用户名
-- MESSAGE_PUSHER_TOKEN = ""                       -- 推送 token（后台设置了才需要）
-- MESSAGE_PUSHER_CHANNEL = ""                     -- 通道类型：lark/telegram/bark/ding/corp 等
-- MESSAGE_PUSHER_TITLE = "来自 Air724UG 的通知"    -- 标题（选填）

-- serverchan 通知
-- SERVERCHAN_TITLE = "来自 Air724UG 的通知"
-- SERVERCHAN_API = ""

-- ------------------------------ MQTT 对接配置 ------------------------------
-- 自建 Go 服务端（内置 MQTT broker）的连接参数，可在这里远程修改
-- 推荐单链接方式（二选一）：
-- MQTT_URL = "wss://panel.example.com/websocket"  -- 加密 WebSocket（推荐，nginx 反代 443 到面板端口）
-- MQTT_URL = "ws://192.168.1.100:9527/websocket"  -- 明文 WebSocket（直接连面板端口）
-- 旧参数（MQTT_URL 留空时才生效）：
-- MQTT_HOST = "192.168.1.100"   -- 服务端地址（IP 或域名）
-- MQTT_PORT = 1883              -- 端口，默认 1883
-- MQTT_KEEPALIVE = 300          -- 心跳间隔（秒），默认 300
-- MQTT_CLIENT_ID = ""           -- 客户端 ID，留空自动使用 IMEI
-- MQTT_USERNAME = ""            -- 服务端若启用 MQTT 认证则填写
-- MQTT_PASSWORD = ""

-- ------------------------------ 录音上传配置 ------------------------------
-- 对象存储上传地址（腾讯云 COS / 阿里云 OSS / AWS S3 等）
-- 配置后通话录音会上传；留空则不启用上传，且来电动作会被覆盖为"接听后挂断"
-- UPLOAD_URL = "http://xxx-123456.cos.ap-nanjing.myqcloud.com/{录音文件目录}"

-- ------------------------------ 短信 / 来电配置 ------------------------------
-- 允许发短信控制设备的号码白名单（留空则禁止所有号码）
-- 短信格式示例：CALL,10086 / SMS,10086,查询流量 / CCFC,? / CCFC,18888888888 / SIMSWITCH
-- SMS_CONTROL_WHITELIST_NUMBERS = { "18xxxxxxx", "18xxxxxxx" }

-- 扬声器 TTS 播报短信内容：0 关闭（默认），1 仅验证码，2 全部
-- SMS_TTS = 0

-- 电话接通后 TTS 提示语（留空则播放 audio_pickup_record.amr 等文件）
-- TTS_TEXT = "您好，请在语音结束后留言，稍后将发送到机主，结束请挂机。"

-- 来电动作：0 无操作，1 自动接听，2 挂断，3 自动接听后挂断，4 等待 30 秒后自动接听
-- CALL_IN_ACTION = 0

-- ------------------------------ 其它参数配置 ------------------------------
-- 扬声器音量 0-7
-- AUDIO_VOLUME = 1
-- 通话音量 0-7
-- CALL_VOLUME = 0
-- 麦克音量 0-7
-- MIC_VOLUME = 7
-- 开启 RNDIS 网卡
-- RNDIS_ENABLE = false
-- 状态指示灯开关
-- LED_ENABLE = true
-- SIM 卡 pin 码
-- PIN_CODE = ""
-- 开机通知开关
-- BOOT_NOTIFY = true
-- 定时查询流量间隔（毫秒），0 关闭
-- QUERY_TRAFFIC_INTERVAL = 0
