-- Y100E 远程管理配置（银尔达 Y100E / 合宙 Air780E / LuatOS）
-- 说明：
--   * 修改本文件后需重新烧录脚本
--   * 运行期可通过面板 set_config 任务修改可变参数（持久化到 /lfs，重启后自动生效）
--   * MESSAGE_PUSHER_TOKEN 等敏感信息请勿提交到 Git
local defaults = {
    -- ---- MQTT 服务端（与 Air724UG 面板共用同一服务）----
    -- MQTT over WebSocket：需 EC618 固件 >= 2025-09-23（mqtt 库自该版本起支持 ws/wss URL）
    MQTT_URL = "wss://panel.example.com/websocket",
    MQTT_PORT = 1883,      -- 仅 MQTT_URL 为普通域名/IP 时使用（当前服务端不开放，一般不用）
    MQTT_KEEPALIVE = 30,   -- 秒，须小于 nginx 空闲超时(60s)，防止空闲被掐断
    MQTT_USERNAME = "",
    MQTT_PASSWORD = "",
    HEARTBEAT_INTERVAL = 120000, -- 应用心跳间隔（毫秒），默认2分钟；设备周期上报 online 主题，供服务端离线判定（建议 ≤ 服务端离线超时的一半）

    -- ---- GPIO 引脚映射（按银尔达 Y100E 硬件手册实际电路修改）----
    GPIO_OUT = 18,          -- 板载 OUT 输出脚对应的 GPIO 编号（可接继电器）
    GPIO_IN = 19,           -- 板载 IN 输入脚对应的 GPIO 编号（状态检测）
    GPIO_IN_NOTIFY = true,  -- 输入电平变化是否推送通知

    -- ---- ADC ----
    ADC_CH = 0,             -- 板载 ADC 引脚对应的通道号（Air780E 常用 0~3）

    -- ---- TTL 串口（透传外部设备）----
    UART_ID = 1,            -- LuatOS 串口号（Air780E: 1/2/3，按 Y100E 实际引出的串口修改）
    UART_BAUD = 115200,
    UART_NOTIFY = false,    -- 收到串口数据是否推送通知

    -- ---- 通知（message-pusher，与 Air724UG 同一通知服务）----
    ONLINE_NOTIFY = true,   -- 设备首次上线时推送通知
    NOTIFY_ENABLE = true,
    MESSAGE_PUSHER_API = "https://push.example.com",
    MESSAGE_PUSHER_USERNAME = "your-username",
    MESSAGE_PUSHER_TOKEN = "",  -- 后台若设置了推送 token 则必填（勿提交到 Git）
    MESSAGE_PUSHER_CHANNEL = "wechat",
    MESSAGE_PUSHER_TITLE = "来自 Y100E 的通知",
}

-- 合并远程覆盖层（/lfs/config_override.json，由 set_config 任务生成）
local config = {}
for k, v in pairs(defaults) do config[k] = v end

pcall(function()
    local f = io.open("/lfs/config_override.json", "r")
    if f then
        local text = f:read("*a")
        f:close()
        local data = json.decode(text)
        if type(data) == "table" then
            for k, v in pairs(data) do
                -- 仅允许覆盖默认已存在的键，防止写入无关键
                if defaults[k] ~= nil then config[k] = v end
            end
        end
    end
end)

return config
