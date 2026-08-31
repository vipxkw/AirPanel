PROJECT = "air724ug-forwarder"
VERSION = "1.0.0"

require "log"
LOG_LEVEL = log.LOGLEVEL_INFO
require "config"
require "nvm"
nvm.init("config.lua")
require "audio"
audio.setStrategy(1)
require "cc"
require "common"
require "http"
require "misc"
require "net"
require "netLed"
require "ntp"
require "powerKey"
require "record"
require "ril"
require "sim"
require "sms"
require "sys"
require "util_mobile"
require "util_audio"
require "util_http"
require "util_notify"
require "util_temperature"
require "util_ntp"
require "handler_call"
require "handler_powerkey"
require "handler_sms"
require "usbmsc"
require "websocket"

local util_mqtt = require "util_mqtt"
-- 配置
local GOTIFY_POLL_INTERVAL = 20 * 1000 -- 轮询间隔 20 秒
-- 输出音频通道选项, 0:听筒 1:耳机 2:喇叭
-- 输入音频通道选项, 0:main_mic 1:auxiliary_mic 3:headphone_mic_left 4:headphone_mic_right

-- 静音音频通道
AUDIO_OUTPUT_CHANNEL_MUTE = 0
AUDIO_INPUT_CHANNEL_MUTE = 1
-- 正常音频通道
AUDIO_OUTPUT_CHANNEL_NORMAL = 2
AUDIO_INPUT_CHANNEL_NORMAL = 0

audio.setChannel(AUDIO_OUTPUT_CHANNEL_NORMAL, AUDIO_INPUT_CHANNEL_NORMAL)

-- 配置内部 PA 类型 audiocore.CLASS_AB, audiocore.CLASS_D
audiocore.setpa(audiocore.CLASS_D)
-- 配置外部 PA
-- pins.setup(pio.P0_14, 0)
-- audiocore.pa(pio.P0_14, 1, 0, 0)
-- audio.setChannel(1)

-- 设置睡眠等待时间
-- ril.request("AT+WAKETIM=0")

-- 定时查询温度
sys.timerLoopStart(util_temperature.get, 1000 * 60)
-- 定时查询 信号强度 基站信息
net.startQueryAll(1000 * 60, 1000 * 60 * 10)

-- RNDIS
ril.request("AT+RNDISCALL=" .. (nvm.get("RNDIS_ENABLE") and 1 or 0) .. ",0")

-- NET 指示灯, LTE 指示灯
if nvm.get("LED_ENABLE") then
    pmd.ldoset(2, pmd.LDO_VLCD)
end
netLed.setup(true, pio.P0_1, pio.P0_4)
netLed.updateBlinkTime("SCK", 50, 50)
netLed.updateBlinkTime("GPRS", 200, 2000)

-- 开机查询本机号码
sim.setQueryNumber(true)
sys.timerStart(ril.request, 3000, "AT+CNUM")
-- 如果查询不到本机号码, 可以取消下面注释的代码, 尝试手动写入到 SIM 卡, 写入成功后注释掉即可
-- sys.timerStart(ril.request, 5000, 'AT+CPBS="ON"')
-- sys.timerStart(ril.request, 6000, 'AT+CPBW=1,"+8618888888888",145')

-- SIM 自动切换开关
ril.request("AT*SIMAUTO=1")

-- SIM 热插拔
pins.setup(23, function(msg)
    if msg == cpu.INT_GPIO_POSEDGE then
        log.info("SIM_DETECT", "插卡")
        rtos.notify_sim_detect(1, 1)
        -- 查询本机号码
        sys.timerStart(ril.request, 1000, "AT+CNUM")
        -- 发送插卡通知
        sys.timerStart(util_notify.add, 2000, "#SIM_INSERT")
    else
        log.info("SIM_DETECT", "拔卡")
        rtos.notify_sim_detect(1, 0)
    end
end, pio.PULLUP)


-- 自动生成 GOTIFY_WS_URL 和 GOTIFY_POLL_URL
local function generateGotifyUrls()
    if config.GOTIFY_API == nil or config.GOTIFY_API == "" then
        log.error("util_notify", "未配置 `config.GOTIFY_API`")
        return nil, nil
    end
    if config.GOTIFY_CLIENT_TOKEN == nil or config.GOTIFY_CLIENT_TOKEN == "" then
        log.error("util_notify", "未配置 `config.GOTIFY_CLIENT_TOKEN`")
        return nil, nil
    end

    -- WebSocket URL
    local ws_url = config.GOTIFY_API:gsub("^http://", "ws://"):gsub("^https://", "wss://") .. "/stream?token=" .. config.GOTIFY_CLIENT_TOKEN

    -- Polling URL
    local poll_url = config.GOTIFY_API .. "/message?token=" .. config.GOTIFY_CLIENT_TOKEN .. "&limit=1"

    return ws_url, poll_url
end

local GOTIFY_WS_URL, GOTIFY_POLL_URL = generateGotifyUrls()

-- WebSocket 状态标志
local websocket_enabled = true -- 初始默认启用 WebSocket

-- 检查手机号码格式
local function checkNumber(number)
    if number == nil or type(number) ~= "string" then
        return false
    end
    if number:len() < 5 then
        return false
    end
    return true
end

-- 处理 Gotify 消息
local function handleGotifyMessage(message)
    log.info("Gotify", "收到消息:", message)

    -- 提取消息标题和内容
    local sms_content = message.message
    local receiver_number, sms_content_to_be_sent
    receiver_number, sms_content_to_be_sent = sms_content:match("^%s*(%d+)%s*#%s*(.+)$") -- 英文#
    if not receiver_number then
        receiver_number, sms_content_to_be_sent = sms_content:match("^%s*(%d+)%s*＃%s*(.+)$") -- 中文＃
    end

    if receiver_number then
        sms_content_to_be_sent = sms_content_to_be_sent:gsub("^%s+", ""):gsub("%s+$", "")
        if sms_content_to_be_sent == "" then
            log.warn("Gotify", "短信内容为空")
            return
        end
    else
        log.warn("Gotify", "短信格式错误，需要：手机号#内容 或 手机号＃内容")
        return
    end

    if not checkNumber(receiver_number) then
        log.error("Gotify", "无效的手机号码:", receiver_number)
        return
    end

    log.info("Gotify", "准备发送短信", "接收号码:", receiver_number, "内容长度:", #sms_content_to_be_sent)

    sys.taskInit(function()
        local send_result, err = sms.send(receiver_number, sms_content_to_be_sent)
        local time = os.time()
        local date = os.date("*t", time)
        local date_str = string.format("%04d/%02d/%02d,%02d:%02d:%02d", date.year, date.month, date.day, date.hour, date.min, date.sec)
        if send_result then
            log.info("Gotify", "短信发送成功")
            util_notify.add({
                "短信发送成功",
                "时间: " .. date_str,
                "接收号码: " .. receiver_number,
                "内容长度: " .. #sms_content_to_be_sent
            })
        else
            log.error("Gotify", "短信发送失败:", err)
            util_notify.add({
                "短信发送失败",
                "错误: " .. tostring(err),
                "接收号码: " .. receiver_number
            })
        end
    end)
end

local function startWebSocket()
    -- 连接配置参数（替代手动重试逻辑）
    local config = {
        keepAlive = 180,          -- 心跳间隔（秒）
        retryInterval = 3000,     -- 重连间隔（毫秒）
        maxRetryCount = 5,        -- 最大重试次数（0表示无限重试）
        autoReconnect = true      -- 启用自动重连
    }

    -- 创建连接实例
    local ws = websocket.new(GOTIFY_WS_URL)

    -- 事件回调（精简版，依赖 ws:start 的重连机制）
    ws:on("open", function()
        log.info("Gotify WebSocket", "连接已建立")
        -- 示例：发送初始消息（可选）
        -- ws:send(json.encode({type = "register"}))
    end)

    ws:on("message", function(msg)
        log.info("Gotify WebSocket", "收到消息:", msg)
        local ok, data = pcall(json.decode, msg)
        if ok and data and data.title == "sms" then
            handleGotifyMessage(data)
        end
    end)

    ws:on("error", function(err)
        log.error("Gotify WebSocket", "错误:", err)
        util_notify.add("WebSocket 错误: "..tostring(err))
    end)

    ws:on("close", function(code)
        log.warn("Gotify WebSocket", "连接关闭，状态码:", code)
        -- 无需手动重连，由 ws:start 自动处理
    end)

    -- 启动连接（内置重连）
    sys.taskInit(function()
        if not ws:start(config.keepAlive, nil, config.retryInterval) then
            log.error("Gotify WebSocket", "初始连接失败")
        end
    end)
end


-- HTTP 轮询方式
local function poll_gotify_messages()
    log.info("Gotify Polling", "从 HTTP 拉取消息")
    http.request("GET", GOTIFY_POLL_URL, nil, nil, nil, nil, function(result, prompt, head, body)
        if not result or not body then
            log.warn("Gotify Polling", "无效响应")
            return
        end

        local ok, data = pcall(json.decode, body)
        if ok and data and data.messages and #data.messages > 0 then
            for _, message in ipairs(data.messages) do
                if message.title == "sms" then -- 只处理标题为 "sms" 的消息
                    handleGotifyMessage(message)
                else
                    log.info("Gotify Polling", "忽略消息，标题为:", message.title)
                end
            end
        else
            log.warn("Gotify Polling", "消息无效或 JSON 解析失败")
        end
    end)
    sys.timerStart(poll_gotify_messages, GOTIFY_POLL_INTERVAL) -- 设置下一次轮询
end

-- 根据优先级启动 WebSocket 或轮询
local function startPolling()
    if websocket_enabled then
        startWebSocket()
    else
        poll_gotify_messages()
    end
end

-- 系统初始化任务
sys.taskInit(function()
    -- 等待网络就绪
    sys.waitUntil("IP_READY_IND", 1000 * 60 * 2)
    -- 等待获取 Band 值
    -- sys.wait(1000 * 5)
	
    if (config.MQTT_HOST and config.MQTT_HOST ~= "") or (config.MQTT_URL and config.MQTT_URL ~= "") then
        log.info("main", "MQTT 服务端已配置，开始启动 MQTT 连接。")
        util_mqtt.start()
    end
    -- 开机通知（附带开机原因，便于远程区分正常开机与异常重启）
    if nvm.get("BOOT_NOTIFY") then
        -- 0=开机键 1=充电 2=闹钟 3=软件重启(sys.restart 触发) 4=异常/看门狗复位
        local reasonMap = { [0] = "按键开机", [1] = "充电开机", [2] = "闹钟开机", [3] = "软件重启", [4] = "异常复位" }
        local r = rtos.poweron_reason()
        util_notify.add("#BOOT_" .. (reasonMap[r] or "其他原因") .. "(" .. r .. ")")
    end

    -- 定时查询流量
    if config.QUERY_TRAFFIC_INTERVAL and config.QUERY_TRAFFIC_INTERVAL >= 1000 * 60 then
        sys.timerLoopStart(util_mobile.queryTraffic, config.QUERY_TRAFFIC_INTERVAL)
    end

    -- 开机同步时间
    util_ntp.sync()
    sys.timerLoopStart(util_ntp.sync, 1000 * 30)
    -- 检查配置是否有效
    if not GOTIFY_WS_URL or not GOTIFY_POLL_URL then
        log.error("Gotify", "无法启动监听，因配置无效")
        return
    end

    -- 启动 Gotify 消息监听
    startPolling()
end)
-- 验证 PIN 码
sys.subscribe("SIM_IND", function(msg)
    if msg == "SIM_PIN" then
        util_mobile.pinVerify()
    end
end)
-- 系统初始化
sys.init(0, 0)
sys.run()