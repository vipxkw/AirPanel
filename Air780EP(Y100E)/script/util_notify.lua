-- Y100E 通知模块（message-pusher，与 Air724UG 使用同一通知服务）
-- https://github.com/vipxkw/message-pusher
local sys = require "sys"
local config = require "config"

-- 消息队列
local msg_queue = {}

-- 连续失败计数：达到阈值后进出一次飞行模式重置网络栈
-- （合宙官方建议：PDP 被动去激活后继续发 HTTP 会持续失败，CFUN 0/1 可恢复）
local fail_streak = 0
local net_recovering = false

local function resetNetwork()
    if net_recovering then return end
    net_recovering = true
    log.warn("util_notify", "连续失败, 进出飞行模式重置网络栈")
    pcall(mobile.flymode, 0, true)
    sys.wait(3000)
    pcall(mobile.flymode, 0, false)
    -- 等网络重新就绪（最长 60 秒），期间 MQTT 也会自动重连
    sys.waitUntil("IP_READY", 60000)
    sys.wait(5000) -- 就绪后再缓冲 5 秒，避免 PDP 尚未完全激活
    net_recovering = false
end

--- URL 编码（UTF-8 字节逐个百分号编码）
local function urlencode(s)
    return (string.gsub(s, "[^%w%-_%.~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function urlencodeTab(params)
    local msg = {}
    for k, v in pairs(params) do
        if type(v) ~= "string" then v = tostring(v) end
        table.insert(msg, urlencode(k) .. "=" .. urlencode(v))
        table.insert(msg, "&")
    end
    table.remove(msg)
    return table.concat(msg)
end

--- 按 UTF-8 字符数安全截取字符串前 n 个字符（避免中文被截断出现乱码）
local function utf8sub(s, n)
    local t = {}
    local i, cnt = 1, 0
    while i <= #s and cnt < n do
        local c = string.byte(s, i)
        local l = c < 0x80 and 1 or (c < 0xE0 and 2 or (c < 0xF0 and 3 or 4))
        if i + l - 1 > #s then break end
        t[#t + 1] = s:sub(i, i + l - 1)
        i = i + l
        cnt = cnt + 1
    end
    return table.concat(t)
end

--- 发送通知
-- @return (boolean) 发送成功/无需重发返回 true
local function send(msg)
    if not config.MESSAGE_PUSHER_API or config.MESSAGE_PUSHER_API == "" then
        log.error("util_notify", "未配置 `config.MESSAGE_PUSHER_API`")
        return true
    end
    if not config.MESSAGE_PUSHER_USERNAME or config.MESSAGE_PUSHER_USERNAME == "" then
        log.error("util_notify", "未配置 `config.MESSAGE_PUSHER_USERNAME`")
        return true
    end

    local url = config.MESSAGE_PUSHER_API .. "/push/" .. config.MESSAGE_PUSHER_USERNAME
    -- content 为消息内容, description 为描述(取消息前 50 个字符)
    local body = { content = msg, description = utf8sub(msg, 50) }
    -- 以下均为选填
    if config.MESSAGE_PUSHER_TITLE and config.MESSAGE_PUSHER_TITLE ~= "" then
        body.title = config.MESSAGE_PUSHER_TITLE
    end
    if config.MESSAGE_PUSHER_CHANNEL and config.MESSAGE_PUSHER_CHANNEL ~= "" then
        body.channel = config.MESSAGE_PUSHER_CHANNEL
    end
    if config.MESSAGE_PUSHER_TOKEN and config.MESSAGE_PUSHER_TOKEN ~= "" then
        body.token = config.MESSAGE_PUSHER_TOKEN
    end

    local headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
    log.info("util_notify", "POST", url)
    -- 内部自动重试：蜂窝网偶发抖动会导致连接失败(error event -1, code -4)，
    -- 重试 3 次仍失败则重置网络栈（飞行模式）后再试一次；超时 30 秒覆盖服务端慢应答
    local code, res_body
    for attempt = 1, 3 do
        code, _, res_body = http.request("POST", url, headers, urlencodeTab(body), { timeout = 30000 }).wait()
        if code and code >= 200 and code < 500 then
            fail_streak = 0
            log.info("util_notify", "发送通知成功", "code:", code)
            return true
        end
        if attempt < 3 then
            log.warn("util_notify", "发送失败(code:", code, "), 3 秒后进行第", attempt + 1, "次重试")
            sys.wait(3000)
        end
    end
    -- 连续多轮失败：大概率 PDP 已被动去激活，重置网络栈后最后再试一次
    fail_streak = fail_streak + 1
    if fail_streak >= 2 and not net_recovering then
        resetNetwork()
        code, _, res_body = http.request("POST", url, headers, urlencodeTab(body), { timeout = 30000 }).wait()
        if code and code >= 200 and code < 500 then
            fail_streak = 0
            log.info("util_notify", "网络重置后发送成功", "code:", code)
            return true
        end
    end
    log.error("util_notify", "发送通知失败, 等待重发", "code:", code, "body:", res_body)
    return false
end

--- 添加到消息队列
-- @param msg (string/table) 通知内容
function add(msg)
    if type(msg) == "table" then
        msg = table.concat(msg, "\n")
    end
    if not config.NOTIFY_ENABLE then return end
    table.insert(msg_queue, { msg = msg, retry = 0 })
    sys.publish("NEW_MSG")
    log.info("util_notify", "添加到消息队列, 当前队列长度:", #msg_queue)
end

--- 轮询消息队列：发送成功则移除，失败则等待下次轮询
sys.taskInit(function()
    while true do
        if #msg_queue > 0 then
            local item = msg_queue[1]
            table.remove(msg_queue, 1)

            if item.retry > 100 then
                log.error("util_notify", "超过最大重发次数", "msg:", item.msg)
            else
                -- pcall 保护：协程内未捕获错误会导致 Lua VM 退出整机重启
                local ok, result = pcall(send, item.msg)
                if not ok or not result then
                    -- 发送失败, 移到队尾
                    item.retry = item.retry + 1
                    table.insert(msg_queue, item)
                    sys.wait(5000)
                end
            end
            sys.wait(50)
        else
            sys.waitUntil("NEW_MSG", 1000 * 10)
        end
    end
end)

return { add = add }
