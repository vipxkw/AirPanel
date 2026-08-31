module(...)

-------------------------------------------------- 功能及使用说明 --------------------------------------------------

-- 本项目支持外接扬声器和麦克风, 可以实现接打电话等功能, 推荐连接后使用

-- 连接扬声器后, 可以通过短按/双击/长按 POWERKEY 来切换选择菜单项
-- 菜单项包含: 扬声器音量/通话音量/麦克音量/回拨电话/测试通知/网卡/短信播报/历史短信/来电动作/开机通知/查询流量/查询温度/查询时间/查询信号/查询内存/查询电压/状态指示灯/切换卡槽/重启/关机
-- 连接扬声器后, 可以播放: 通知发送成功提示音/来电铃声/通话外放声/短信验证码/短信内容
-- 来电动作配置为无操作时, 如果来电话, 可以通过短按/长按 POWERKEY 来手动接听/挂断电话

-- 支持虚拟U盘来存储历史短信, 需要使用 core 目录下的底层固件

-- 下面配置文件编辑时注意删除注释 (两个短横杠--是lua的注释), 推荐使用 VSCode 代码编辑器

-------------------------------------------------- 通知相关配置 --------------------------------------------------

-- 通知类型, 支持配置多个
-- NOTIFY_TYPE = { "custom_post", "telegram", "pushdeer", "bark", "dingtalk", "feishu", "wecom", "pushover", "inotify", "next-smtp-proxy", "gotify", "serverchan", "message-pusher" }
NOTIFY_TYPE = { "message-pusher" }

-- custom_post 通知配置, 自定义 POST 请求
-- CUSTOM_POST_CONTENT_TYPE 支持 application/x-www-form-urlencoded 和 application/json
-- CUSTOM_POST_BODY_TABLE 中的 {msg} 会被替换为通知内容
-- CUSTOM_POST_URL = "https://sctapi.ftqq.com/<SENDKEY>.send"
-- CUSTOM_POST_CONTENT_TYPE = "application/json"
-- CUSTOM_POST_BODY_TABLE = { ["title"] = "这里是标题", ["desp"] = "{msg}" }

-- telegram 通知配置, https://github.com/0wQ/telegram-notify 或者自行反代
-- TELEGRAM_API = "https://api.telegram.org/bot{token}/sendMessage"
-- TELEGRAM_CHAT_ID = ""

-- pushdeer 通知配置, https://www.pushdeer.com/
-- PUSHDEER_API = "https://api2.pushdeer.com/message/push"
-- PUSHDEER_KEY = ""

-- bark 通知配置, https://github.com/Finb/Bark
-- BARK_API = "https://api.day.app"
-- BARK_KEY = ""

-- dingtalk 通知配置, https://open.dingtalk.com/document/robots/custom-robot-access
-- 自定义关键词方式可填写 ":" "#" "号码"
-- 如果是加签方式, 请填写 DINGTALK_SECRET, 否则留空为自定义关键词方式, https://open.dingtalk.com/document/robots/customize-robot-security-settings
-- DINGTALK_WEBHOOK = "https://oapi.dingtalk.com/robot/send?access_token=xxx"
-- DINGTALK_SECRET = ""

-- feishu 通知配置, https://open.feishu.cn/document/ukTMukTMukTM/ucTM5YjL3ETO24yNxkjN
-- FEISHU_WEBHOOK = "https://open.feishu.cn/open-apis/bot/v2/hook/xxx"

-- wecom 通知配置, https://developer.work.weixin.qq.com/document/path/91770
-- WECOM_WEBHOOK = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx"

-- pushover 通知配置, https://pushover.net/api
-- PUSHOVER_API_TOKEN = ""
-- PUSHOVER_USER_KEY = ""

-- inotify 通知配置, https://github.com/xpnas/Inotify 或者使用合宙提供的 https://push.luatos.org
-- INOTIFY_API = "https://push.luatos.org/xxx.send"

-- next-smtp-proxy 通知配置, https://github.com/0wQ/next-smtp-proxy
-- NEXT_SMTP_PROXY_API = ""
-- NEXT_SMTP_PROXY_USER = ""
-- NEXT_SMTP_PROXY_PASSWORD = ""
-- NEXT_SMTP_PROXY_HOST = "smtp-mail.outlook.com"
-- NEXT_SMTP_PROXY_PORT = 587
-- NEXT_SMTP_PROXY_FORM_NAME = "Air724UG"
-- NEXT_SMTP_PROXY_TO_EMAIL = ""
-- NEXT_SMTP_PROXY_SUBJECT = "来自 Air724UG 的通知"

-- gotify 通知配置, https://gotify.net/
-- GOTIFY_API = "http://127.0.0.1:8080"
--GOTIFY_API = ""
-- gotify 标题
--GOTIFY_TITLE = "转发器"
--GOTIFY_PRIORITY = 8
-- gotify token为创建的apps的token(需注意，需在gotify上创建一个名为"sms"的app)
--GOTIFY_TOKEN = ""
-- gotify 客户端token(即为配置好的client的token)
--GOTIFY_CLIENT_TOKEN=""

-- message-pusher 通知配置, https://github.com/vipxkw/message-pusher
-- 部署后通过 {服务端}/push/{用户名} 接口发送, description 为必填字段
-- MESSAGE_PUSHER_API = "https://push.example.com"   -- 服务端地址(自建则填 http://IP:3000)
-- MESSAGE_PUSHER_USERNAME = "your-username"         -- 推送用户名
-- MESSAGE_PUSHER_TOKEN = ""                         -- 后台若设置了推送 token 则必填, 否则留空
-- MESSAGE_PUSHER_CHANNEL = "wechat"                 -- 指定推送通道类型(如 lark/telegram/bark/ding/corp...), 留空使用后台默认通道
-- MESSAGE_PUSHER_TITLE = "来自 Air724UG 的通知"     -- 标题(选填)

-------------------------------------------------- 服务端 MQTT 对接配置 --------------------------------------------------

-- 通过 MQTT 对接自建服务端（Go 服务端内置 broker），替代原 WebSocket 方式以节省流量
-- ==================== 推荐：单链接配置 MQTT_URL ====================
-- 直接填写一条链接即可，支持以下格式（任选其一）：
--   MQTT_URL = "wss://panel.example.com/websocket"  -- 加密 WebSocket（推荐，nginx 反代 443 到面板端口）
--   MQTT_URL = "ws://192.168.1.100:9527/websocket"  -- 明文 WebSocket（直接连面板端口）
--   MQTT_URL = "mqtt://panel.example.com:1883"      -- MQTT 明文（需服务端 config.json 中 mqtt.port > 0）
--   MQTT_URL = "mqtts://panel.example.com:8883"     -- MQTT over TLS
MQTT_URL = "wss://panel.example.com/websocket"
-- ==================== 旧参数（MQTT_URL 留空时才生效） ====================
-- MQTT_HOST 填写服务端地址，例如 "192.168.1.100" 或 "panel.example.com"
MQTT_HOST = ""
-- MQTT 端口，默认 1883
MQTT_PORT = 1883
-- 心跳间隔（秒），默认 30 秒。经 nginx 反代时需小于其 proxy_read_timeout（默认 60s），
-- 否则空闲连接会被反代掐断导致任务下发超时；每次心跳仅 2 字节，流量开销极小
MQTT_KEEPALIVE = 30
-- 客户端 ID，留空自动使用 IMEI
MQTT_CLIENT_ID = ""
-- 服务端若启用了 MQTT 认证则填写，否则留空
MQTT_USERNAME = ""
MQTT_PASSWORD = ""
-- 应用心跳间隔（毫秒），默认 2 分钟。设备周期上报 online 主题，供服务端离线判定
-- （建议 ≤ 服务端"离线判定超时"的一半，防止网络抖动被误判离线）
HEARTBEAT_INTERVAL = 120000
-- 连接看门狗（毫秒），默认 15 分钟。持续该时长未能连上服务端则自动重启模块自愈
-- （兜底防止 socket 通道耗尽/网络栈异常导致设备再也连不上、只能人工断电），0 关闭
MQTT_REBOOT_TIMEOUT = 900000
-- 假死看门狗（毫秒），默认 5 分钟。MQTT 主循环超过该时长无任何响应（卡死在某个
-- 永不返回的阻塞调用中）则自动重启模块自愈，0 关闭
MQTT_STUCK_TIMEOUT = 300000

-- serverchan 通知配置
-- SERVERCHAN_TITLE = "来自 Air724UG 的通知"
-- SERVERCHAN_API = ""

-- 定时查询流量间隔, 单位毫秒, 设置为 0 关闭 (建议检查 util_mobile.lua 文件中运营商号码和查询流量代码是否正确, 以免发错短信导致扣费)
QUERY_TRAFFIC_INTERVAL = 0

-- 开机通知
BOOT_NOTIFY = true

-- 通知内容追加更多信息
NOTIFY_APPEND_MORE_INFO = true

-- 通知最大重发次数
NOTIFY_RETRY_MAX = 100

-------------------------------------------------- 录音上传配置 --------------------------------------------------

-- 腾讯云 COS / 阿里云 OSS / AWS S3 等对象存储上传地址, 以下为腾讯云 COS 示例, 请自行修改
-- 存储桶需设置为: <私有读写>
-- 存储桶 Policy 权限: <用户类型: 所有用户> <授权资源: xxx-123456/{录音文件目录}/*> <授权操作: PutObject,GetObject>
-- 提示: 本项目未使用签名认证上传, 请勿泄露自己的地址及目录名
-- 当注释掉或者为空则不启用上传, 并且会将来电动作配置项覆盖为: 接听 -> 接听后挂断
-- UPLOAD_URL = "http://xxx-123456.cos.ap-nanjing.myqcloud.com/{录音文件目录}"

-------------------------------------------------- 短信来电配置 --------------------------------------------------

-- 允许发短信控制设备的号码, 如果注释掉或者为空, 则禁止所有号码, 短信格式示例:
-- 拨打电话 CALL,10086
-- 发送短信 SMS,10086,查询流量
-- 查询所有呼转状态 CCFC,?
-- 设置无条件呼转 CCFC,18888888888
-- 关闭所有呼转 CCFC,18888888888
-- 切换卡槽优先级 SIMSWITCH
-- SMS_CONTROL_WHITELIST_NUMBERS = { "18xxxxxxx", "18xxxxxxx", "18xxxxxxx" }
SMS_CONTROL_WHITELIST_NUMBERS = {}  

-- 扬声器 TTS 播放短信内容, 0:关闭(默认), 1:仅验证码, 2:全部
SMS_TTS = 0

-- 电话接通后 TTS 语音内容, 在播放完后开始录音, 如果注释掉或者为空则播放 audio_pickup_record.amr 或 audio_pickup_hangup.amr 文件
-- TTS_TEXT = "您好，请在语音结束后留言，稍后将发送到机主，结束请挂机。"

-- 来电动作, 0:无操作, 1:自动接听(默认), 2:挂断, 3:自动接听后挂断, 4:等待30秒后自动接听
-- 无操作 / 等待30秒后自动接听, 可以长按 POWERKEY 来手动接听挂断电话
CALL_IN_ACTION = 0

-------------------------------------------------- 其他配置 --------------------------------------------------

-- 扬声器音量, 0-7
AUDIO_VOLUME = 1

-- 通话音量 0-7
CALL_VOLUME = 0

-- 麦克音量 0-7
MIC_VOLUME = 7

-- 开启 RNDIS 网卡
RNDIS_ENABLE = false

-- 状态指示灯开关
LED_ENABLE = true

-- SIM 卡 pin 码
PIN_CODE = ""
