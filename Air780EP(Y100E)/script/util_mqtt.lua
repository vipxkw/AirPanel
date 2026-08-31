-- Y100E MQTT 对接（与 Air724UG Web 面板共用同一服务端）
--
-- 主题约定（与服务端 broker.go 保持一致）：
--   设备订阅 : cmd/{imei}           （接收服务端下发指令）
--   设备上报 : device/{imei}/online （上线 retained，服务端重启后仍可感知设备）
--   设备上报 : device/{imei}/result （任务执行结果）
--
-- MQTT over WebSocket 说明：
--   MQTT_URL 传 wss://host/websocket 即走 WebSocket 传输，
--   要求 EC618 固件 >= 2025-09-23（mqtt 库自该版本起支持 ws/wss URL）
local sys = require "sys"
local config = require "config"
local util_hw = require "util_hw"
local util_notify = require "util_notify"

-- 任务结果待发队列：任务协程只入队，由发布协程统一发布
-- （避免任务协程与 MQTT 回调并发访问同一 socket 导致报文损坏）
local resultQueue = {}

local mqttc = nil
local connected = false
local online_notified = false
local imei = nil

local CONFIG_OVERRIDE_PATH = "/lfs/config_override.json"

--- 设备状态汇总
local function statusResult()
    local status = {
        model = rtos.bsp(),
        imei = mobile.imei(),
        number = mobile.number() or "",
        iccid = mobile.iccid(),
        csq = mobile.csq(),
        vbat_mv = util_hw.getVbat(),
        adc_mv = util_hw.getAdc(),
        temp_c = util_hw.getTemp(),
        gpio_in = util_hw.getGpio(),
    }
    local ok, rsrp = pcall(mobile.rsrp)
    if ok and type(rsrp) == "number" then status.rsrp = rsrp end
    local ok2, net_status = pcall(mobile.status)
    if ok2 then status.net_status = net_status end
    local ok3, fw_ver = pcall(rtos.version)
    if ok3 then status.firmware = fw_ver end
    return status
end

--- 由 IMSI 前缀推断运营商（46000/02/04/07/08 移动，46001/06/09 联通，46003/05/11 电信）
local function carrierName()
    local ok, imsi = pcall(mobile.imsi)
    if ok and type(imsi) == "string" and #imsi >= 5 then
        local mnc = imsi:sub(1, 5)
        if mnc == "46000" or mnc == "46002" or mnc == "46004" or mnc == "46007" or mnc == "46008" then return "移动" end
        if mnc == "46001" or mnc == "46006" or mnc == "46009" then return "联通" end
        if mnc == "46003" or mnc == "46005" or mnc == "46011" then return "电信" end
    end
    local ok2, apn = pcall(mobile.apn)
    if ok2 and type(apn) == "string" and apn ~= "" then return apn end
    return "未知"
end

--- 开机时间（当前时间减开机时长；取不到合理时长时退化为当前时间）
local function bootTimeText()
    local uptime_s
    local ok, ticks = pcall(mcu.ticks)
    if ok and type(ticks) == "number" and ticks > 0 then
        uptime_s = math.floor(ticks / 1000)
        if uptime_s <= 0 or uptime_s > 86400 * 365 then uptime_s = nil end -- 值不合理则放弃
    end
    local t = os.time()
    if uptime_s and t > 1000000000 then
        return os.date("%Y-%m-%d %H:%M:%S", t - uptime_s)
    end
    return os.date("%Y-%m-%d %H:%M:%S", t)
end

--- 开机综合报告：上线 + 运营商/开机时间/本机号码/信号/电压/温度/GPIO 输入状态，合并为一条通知
local function bootReport(id)
    local lines = { "Y100E 已上线", "IMEI: " .. id, "运营商: " .. carrierName() }
    local number = mobile.number()
    table.insert(lines, "本机号码: " .. ((number and number ~= "") and number or "未获取(SIM未存储)"))
    table.insert(lines, "开机时间: " .. bootTimeText())
    -- 上次开机原因（排查异常重启：0=硬件复位(查供电/RST脚) 3=软件重启 5=正常上电 6=底层异常）
    local ok_pm, r1, r2 = pcall(pm.lastReson)
    if ok_pm and r1 ~= nil then
        local reason_map = {
            [0] = "硬件复位(查供电/RST复位脚)",
            [1] = "充电开机", [2] = "闹钟开机",
            [3] = "软件重启", [4] = "复位脚重启",
            [5] = "按键/正常上电", [6] = "异常重启(底层出错)",
            [8] = "看门狗复位",
        }
        local txt = tostring(r1)
        if reason_map[r1] then txt = txt .. " " .. reason_map[r1] end
        if r2 ~= nil and r2 ~= r1 then txt = txt .. " / " .. tostring(r2) end
        table.insert(lines, "开机原因: " .. txt)
    end
    local sig = "信号: CSQ " .. tostring(mobile.csq() or "?")
    local ok_r, rsrp = pcall(mobile.rsrp)
    if ok_r and type(rsrp) == "number" and rsrp ~= 0 then sig = sig .. " / RSRP " .. rsrp .. "dBm" end
    table.insert(lines, sig)
    local vbat = util_hw.getVbat()
    if vbat then table.insert(lines, "电压: " .. string.format("%.2fV", vbat / 1000)) end
    local temp = util_hw.getTemp()
    if temp then table.insert(lines, "温度: " .. temp .. "℃") end
    local gpio_level = util_hw.getGpio()
    if gpio_level ~= nil then
        table.insert(lines, "GPIO" .. config.GPIO_IN .. " 输入: " .. (gpio_level == 1 and "高电平" or "低电平"))
    end
    return lines
end

--- 处理服务端下发任务
local function handleTask(data)
    log.info("mqtt:task", data.task)
    if data.type ~= "task" or not data.taskId then
        return
    end

    sys.taskInit(function()
        local result, err
        local success, e = pcall(function()
            if data.task == "get_status" then
                result = statusResult()
            elseif data.task == "get_device_info" then
                result = {
                    imei = mobile.imei(),
                    iccid = mobile.iccid(),
                    model = rtos.bsp(),
                    version = _G.VERSION,
                }
            elseif data.task == "set_gpio" then
                -- GPIO 输出控制（可外接继电器实现远程开关）
                local level = tonumber(data.level)
                if level == nil then
                    err = "缺少必要参数: level(0或1)"
                else
                    local pin = tonumber(data.pin) or config.GPIO_OUT
                    local ok, gerr = util_hw.setGpio(pin, level)
                    if ok then
                        result = "GPIO" .. pin .. " 已输出 " .. level
                    else
                        err = gerr
                    end
                end
            elseif data.task == "get_gpio" then
                local level = util_hw.getGpio()
                if level == nil then
                    err = "GPIO 输入未初始化"
                else
                    result = "GPIO" .. config.GPIO_IN .. " 电平: " .. level
                end
            elseif data.task == "uart_send" then
                -- 串口透传发送
                if not data.data or data.data == "" then
                    err = "缺少必要参数: data"
                else
                    local ok, uerr = util_hw.uartSend(data.data)
                    if ok then
                        result = "串口数据已发送, 长度: " .. #data.data
                    else
                        err = uerr
                    end
                end
            elseif data.task == "send_sms" then
                -- 发送短信（Air780EP 内置 sms 库；仅支持移动/联通卡，电信卡不支持）
                if not data.rcv_phone or not data.content then
                    err = "缺少必要参数: rcv_phone 或 content"
                else
                    log.info("mqtt:task", "发送短信", data.rcv_phone, data.content)
                    local ok_sms, s_err = pcall(sms.send, data.rcv_phone, data.content)
                    if ok_sms then
                        result = "短信发送成功"
                    else
                        err = "短信发送失败: " .. tostring(s_err)
                    end
                end
            elseif data.task == "get_config" then
                -- 返回当前生效配置（敏感 token 打码）
                local snapshot = {}
                for k, v in pairs(config) do
                    if k == "MESSAGE_PUSHER_TOKEN" and v ~= "" then
                        snapshot[k] = "***"
                    else
                        snapshot[k] = v
                    end
                end
                result = json.encode(snapshot)
            elseif data.task == "set_config" then
                -- 支持 params(table) 或 configText(JSON 字符串)
                local newcfg = data.params
                if type(newcfg) ~= "table" and type(data.configText) == "string" then
                    local okj, j = pcall(json.decode, data.configText)
                    if okj and type(j) == "table" then newcfg = j end
                end
                if type(newcfg) ~= "table" then
                    err = "缺少必要参数: params(table) 或 configText(JSON字符串)"
                else
                    local file = io.open(CONFIG_OVERRIDE_PATH, "w")
                    if not file then
                        err = "无法写入 " .. CONFIG_OVERRIDE_PATH
                    else
                        file:write(json.encode(newcfg))
                        file:close()
                        -- 热更新已存在的键（GPIO/UART 引脚类修改需重启生效）
                        local applied = {}
                        for k, v in pairs(newcfg) do
                            if config[k] ~= nil then
                                config[k] = v
                                table.insert(applied, k)
                            end
                        end
                        result = { success = true, applied = applied, note = "引脚类修改需重启生效" }
                    end
                end
            elseif data.task == "reboot" then
                result = "重启指令已接收, 10秒后重启"
                sys.timerStart(rtos.reboot, 10000)
            else
                err = "未知的任务类型: " .. tostring(data.task)
            end
        end)
        if not success then
            err = tostring(e)
        end

        -- 任务结果入队，由发布协程统一发布
        -- pcall 保护 json.encode：result 可能含无法序列化的值，未捕获错误会导致整机重启
        local ok_enc, encoded = pcall(json.encode, {
            type = "task_result",
            taskId = data.taskId,
            task = data.task,
            result = result,
            error = err,
        })
        if ok_enc and type(encoded) == "string" then
            table.insert(resultQueue, encoded)
        else
            local ok_f, fallback = pcall(json.encode, {
                type = "task_result", taskId = data.taskId, task = data.task,
                error = "结果序列化失败: " .. tostring(err),
            })
            if ok_f then table.insert(resultQueue, fallback) end
        end
        sys.publish("Y100E_MQTT_RESULT")
    end)
end

--- 建立 MQTT 连接（自动重连）
local function startMQTT()
    local ok, id = pcall(mobile.imei)
    if not ok or not id or #id < 10 then
        log.error("mqtt", "获取 IMEI 失败, 30秒后重试")
        sys.timerStart(startMQTT, 30000)
        return
    end
    imei = id

    local url = config.MQTT_URL or ""
    if url == "" then
        log.error("mqtt", "未配置 `config.MQTT_URL`")
        return
    end

    local scheme = url:match("^(%a+)://")
    if scheme == "wss" or scheme == "ws" then
        -- WebSocket 传输（wss 加密，ws 明文），host 参数直接传完整 URL
        log.info("mqtt", "WebSocket 传输模式", url)
        -- 旧固件（<2025-09-23）的 mqtt.create 不支持 ws/wss URL，第3参 port 为 nil 会抛错，
        -- 导致协程崩溃 -> Lua VM 退出 -> 重启循环，这里 pcall 保护并给出明确提示
        local ok, c = pcall(mqtt.create, nil, url, nil)
        if not ok or not c then
            log.error("mqtt", "当前固件不支持 ws/wss URL 直连(需 2025-09-23 之后固件)，已停止连接，请升级底层固件")
            return
        end
        mqttc = c
    else
        -- 普通域名:端口 明文 MQTT（服务端需开放 1883，默认未开放）
        local host, port = url:match("^([^:]+):(%d+)$")
        log.info("mqtt", "TCP 传输模式", host or url, tonumber(port) or 1883)
        mqttc = mqtt.create(nil, host or url, tonumber(port) or 1883, false)
    end

    -- clientId 必须为 IMEI（服务端以此识别设备）
    mqttc:auth(imei, config.MQTT_USERNAME, config.MQTT_PASSWORD)
    -- 心跳须小于 nginx 空闲超时(60s)，防止空闲被掐断
    mqttc:keepalive(config.MQTT_KEEPALIVE or 30)
    -- 自动重连（间隔 3 秒）
    mqttc:autoreconn(true, 3000)

    mqttc:on(function(client, event, data, payload)
        if event == "conack" then
            -- 连接成功，订阅服务端指令主题
            local sub_ok = client:subscribe("cmd/" .. imei, 1)
            if not sub_ok then
                -- 订阅失败则断开走重连流程，避免"假在线"
                log.error("mqtt", "订阅失败, 断开连接等待重连")
                connected = false
                client:disconnect()
            else
                connected = true
                log.info("mqtt", "MQTT 连接成功, IMEI:", imei)
                sys.publish("Y100E_MQTT_CONACK")
            end
        elseif event == "recv" then
            -- data 为 topic, payload 为内容
            local okj, jdata = pcall(json.decode, payload)
            if okj and type(jdata) == "table" then
                handleTask(jdata)
            else
                log.warn("mqtt", "收到无法解析的消息", data)
            end
        elseif event == "disconnect" or event == "close" then
            if connected then
                connected = false
                log.warn("mqtt", "连接断开, 自动重连中")
            end
        end
    end)

    mqttc:connect()

    -- 上线发布协程：连接成功后上报在线（retained），并周期性发送心跳供服务端离线判定
    sys.taskInit(function()
        while true do
            sys.waitUntil("Y100E_MQTT_CONACK")
            -- pcall 保护：mobile/json/mqtt 库调用抛错时避免 Lua VM 退出导致整机重启
            local ok_run, e = pcall(function()
                if connected and mqttc then
                    -- 本机号码（部分 SIM 未存储号码，回退 ICCID，与 Air724UG 行为一致）
                    local phone = mobile.number()
                    if not phone or phone == "" then
                        phone = mobile.iccid() or ""
                    end
                    local payload = json.encode({ type = "online", imei = imei, phone = phone })
                    pcall(mqttc.publish, mqttc, "device/" .. imei .. "/online", payload, 1, 1)
                    if not online_notified then
                        online_notified = true
                        if config.ONLINE_NOTIFY then
                            -- 开机后 PDP 刚激活时 TCP 尚不稳定（DNS 可通但连接报 -14），
                            -- 延迟 10 秒让网络栈稳定，避免通知 HTTP 反复重试
                            sys.wait(10000)
                            util_notify.add(bootReport(imei))
                        end
                    end
                    -- 周期心跳：连接保持期间按 HEARTBEAT_INTERVAL 重复上报，刷新服务端 lastSeen
                    local interval = config.HEARTBEAT_INTERVAL or 120000
                    while connected and mqttc do
                        sys.wait(interval)
                        if connected and mqttc then
                            local ok, ret = pcall(mqttc.publish, mqttc, "device/" .. imei .. "/online", payload, 1, 1)
                            if not ok or not ret or (type(ret) == "number" and ret < 0) then
                                -- 发布失败说明连接已静默断开（服务端重启/网络中断，事件回调可能不触发），
                                -- 强制断开以触发库内自动重连
                                log.error("mqtt", "心跳发布失败，强制断开以触发重连")
                                connected = false
                                pcall(mqttc.disconnect)
                            end
                        end
                    end
                end
            end)
            if not ok_run then
                log.error("mqtt", "上线/心跳协程异常:", e)
                connected = false
                pcall(function() if mqttc then mqttc:disconnect() end end)
            end
        end
    end)

    -- 任务结果发布协程：串行访问 socket，避免并发发送
    sys.taskInit(function()
        while true do
            if #resultQueue > 0 and connected and mqttc then
                local payload = table.remove(resultQueue, 1)
                -- pcall 保护 publish：断线瞬间对象可能已失效，抛错会导致整机重启
                local ok, ret = pcall(mqttc.publish, mqttc, "device/" .. imei .. "/result", payload, 1, 0)
                if not ok or not ret or (type(ret) == "number" and ret < 0) then
                    log.error("mqtt", "发布任务结果失败, 等待重连后重发")
                    table.insert(resultQueue, 1, payload)
                    sys.wait(3000)
                end
                sys.wait(50)
            else
                sys.waitUntil("Y100E_MQTT_RESULT", 5000)
            end
        end
    end)
end

local M = {}

function M.start()
    sys.taskInit(function()
        -- 等待网络就绪（最长 5 分钟）
        sys.waitUntil("IP_READY", 1000 * 60 * 5)
        startMQTT()
    end)

    -- 短信接收：底层组装完成（含长短信）后回调，推送微信通知（附设备状态）
    pcall(function()
        sms.setNewSmsCb(function(phone, content)
            log.info("sms", "收到短信", tostring(phone), tostring(content))
            local lines = {
                "收到新短信",
                "来自: " .. ((phone and phone ~= "") and phone or "未知号码"),
                "内容: " .. (content or ""),
                "---- 设备状态 ----",
                "运营商: " .. carrierName(),
            }
            local number = mobile.number()
            table.insert(lines, "本机号码: " .. ((number and number ~= "") and number or "未获取(SIM未存储)"))
            table.insert(lines, "IMEI: " .. (imei or tostring(mobile.imei() or "?")))
            table.insert(lines, "信号: CSQ " .. tostring(mobile.csq() or "?"))
            local vbat = util_hw.getVbat()
            if vbat then table.insert(lines, "电压: " .. string.format("%.2fV", vbat / 1000)) end
            local temp = util_hw.getTemp()
            if temp then table.insert(lines, "温度: " .. temp .. "℃") end
            util_notify.add(lines)
        end)
    end)
end

return M
