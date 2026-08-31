-- 通过 MQTT 对接服务端（替代原 WebSocket 方案）
-- 相比 WebSocket，MQTT 消息头仅 2~5 字节、心跳间隔可拉长（默认 300s）、
-- 支持双向发布/订阅，显著降低设备端流量消耗。
local mqtt = require "mqtt"
local log = require "log"
local sys = require "sys"
local misc = require "misc"
local net = require "net"
local sim = require "sim"
local cc = require "cc"
local ril = require "ril"
local util_mobile = require "util_mobile"
local util_audio = require "util_audio"
local util_notify = require "util_notify"
local util_temperature = require "util_temperature"
local pins = require "pins"
local config = require "config"
local nvm = require "nvm"

local mqttc = nil

-- 看门狗状态（rtos.tick()*5 为开机起毫秒数的单调时钟）
-- lastAliveMs：MQTT 主循环仍在运转（所有阻塞调用都正常返回）的最新时刻
-- lastOkMs  ：最近一次成功连上服务端的时刻
local lastAliveMs, lastOkMs = 0, 0

local function tickMs() return rtos.tick() * 5 end
local function touchAlive() lastAliveMs = tickMs() end
local function touchOk() lastOkMs = tickMs() end

-- USSD 查询结果 URC：运营商回复后通过通知渠道推送
ril.regUrc("+CUSD", function(data)
    util_notify.add({ "USSD 查询结果", data or "", "#USSD" })
end)

-- 任务结果待发队列：handleTask 只入队，由主循环统一发布
-- （避免任务协程与主循环并发访问同一 socket 导致报文损坏/脚本崩溃重启）
local resultQueue = {}

-- 主题约定（与服务端保持一致）
-- 设备订阅 : cmd/{imei}          （接收服务端下发指令）
-- 设备上报 : device/{imei}/online（上线 retained）
-- 设备上报 : device/{imei}/result（任务执行结果）

-- 将 Lua 配置字符串解析为 Lua 表的辅助函数
local function parse_lua_config_string(config_text)
    local sandbox_env = {}
    sandbox_env.table = table
    sandbox_env.string = string
    sandbox_env.pairs = pairs
    sandbox_env.ipairs = ipairs
    sandbox_env.type = type
    sandbox_env.tostring = tostring

    local captured_module_table = nil
    sandbox_env.module = function(_, module_name_arg)
        local new_table = {}
        captured_module_table = new_table
        setfenv(1, new_table)
        return new_table
    end

    local func, err = loadstring(config_text)
    if not func then
        return nil, "加载配置失败: " .. err
    end

    setfenv(func, sandbox_env)

    local success, result = pcall(func)
    if not success then
        return nil, "执行配置失败: " .. result
    end

    if captured_module_table then
        return captured_module_table
    else
        local final_config_table = {}
        for k, v in pairs(sandbox_env) do
            if k ~= "table" and k ~= "string" and k ~= "pairs" and k ~= "ipairs" and
               k ~= "type" and k ~= "tostring" and k ~= "module" then
                final_config_table[k] = v
            end
        end
        return final_config_table
    end
end

-- 处理服务端下发任务
local function handleTask(imei, json_data)
    log.info("mqtt:task", json_data.task)
    if json_data.type ~= "task" or not json_data.taskId then
        return
    end

    sys.taskInit(function()
        local result = nil
        local error = nil

        local success, err = pcall(function()
            if json_data.task == "get_temperature" then
                result = util_temperature.get()
            elseif json_data.task == "send_sms" then
                if not json_data.rcv_phone or not json_data.content then
                    error = "缺少必要参数: rcv_phone 或 content"
                else
                    log.info("发送短信", json_data.rcv_phone, json_data.content)
                    local sms_success, sms_err = pcall(function()
                        sms.send(json_data.rcv_phone, json_data.content)
                    end)
                    if sms_success then
                        result = "短信发送成功"
                    else
                        error = "短信发送失败: " .. tostring(sms_err)
                    end
                end
            elseif json_data.task == "get_config" then
                local file = io.open("/nvm_para.lua", "r")
                if file then
                    result = file:read("*a")
                    file:close()
                else
                    error = "无法读取/nvm_para.lua文件"
                end
            elseif json_data.task == "set_config" then
                if not json_data.configText or type(json_data.configText) ~= "string" then
                    error = "缺少必要参数: configText (必须是字符串)"
                else
                    local file = io.open("/nvm_para.lua", "w+")
                    if file then
                        file:write(json_data.configText)
                        file:close()
                        local newcfg, cerr = parse_lua_config_string(json_data.configText)
                        if newcfg then
                            for k, v in pairs(newcfg) do
                                config[k] = v
                            end
                            result = { success = true }
                        else
                            error = "解析配置字符串失败: " .. cerr
                        end
                    else
                        error = "无法写入/nvm_para.lua文件"
                    end
                end
            elseif json_data.task == "get_status" then
                -- 设备状态汇总（电压/温度/信号/运营商/本机号码/SIM卡槽）
                result = {
                    voltage = misc.getVbatt(),
                    temperature = util_temperature.get(),
                    rssi = net.getRssi(),
                    rsrp = net.getRsrp(),
                    operator = util_mobile.getOper(true),
                    number = util_mobile.getNumber(),
                    sim_id = sim.getId() == 0 and "主卡槽" or "副卡槽",
                    net_state = net.getState()
                }
            elseif json_data.task == "dial_call" then
                if not json_data.phone or json_data.phone == "" then
                    error = "缺少必要参数: phone"
                else
                    sys.taskInit(cc.dial, json_data.phone)
                    result = "拨打指令已执行: " .. json_data.phone
                end
            elseif json_data.task == "hang_up" then
                if cc.anyCallExist() then
                    cc.hangUp("REMOTE_HANGUP")
                    result = "挂断指令已执行"
                else
                    result = "当前无通话"
                end
            elseif json_data.task == "tts_speak" then
                if not json_data.text or json_data.text == "" then
                    error = "缺少必要参数: text"
                else
                    util_audio.play(7, "TTS", json_data.text)
                    result = "TTS 播报已执行"
                end
            elseif json_data.task == "set_volume" then
                local vol = tonumber(json_data.vol)
                if vol == nil or vol < 0 or vol > 10 then
                    error = "参数 vol 必须为 0-10 的数字"
                else
                    nvm.set("AUDIO_VOLUME", vol)
                    nvm.set("CALL_VOLUME", vol)
                    result = "音量已设置为 " .. vol
                end
            elseif json_data.task == "query_traffic" then
                -- 向运营商发送流量查询短信（回复短信会触发通知推送）
                sys.taskInit(util_mobile.queryTraffic)
                result = "流量查询短信已发送，运营商回复将推送通知"
            elseif json_data.task == "set_ccfc" then
                -- 设置无条件呼转, phone 为 "0" 时取消所有呼转
                local phone = tostring(json_data.phone or "")
                if phone == "" then
                    error = "缺少必要参数: phone（设为 0 可取消呼转）"
                else
                    if phone == "0" then
                        ril.request("AT+CCFC=4,4,0")
                        result = "取消呼转指令已下发"
                    else
                        ril.request("AT+CCFC=0,3," .. phone)
                        result = "呼转指令已下发: " .. phone
                    end
                end
            elseif json_data.task == "switch_sim" then
                -- 切换 SIM 卡槽并重启（重启后生效）
                local new_id = sim.getId() == 0 and 1 or 0
                result = "切换SIM: " .. (sim.getId() == 0 and "主卡槽 -> 副卡槽" or "副卡槽 -> 主卡槽") .. ", 10秒后重启生效"
                sim.setId(new_id)
                sys.timerStart(sys.restart, 10000, "REMOTE_SIMSWITCH")
            elseif json_data.task == "reboot" then
                result = "重启指令已接收, 10秒后重启"
                sys.timerStart(sys.restart, 10000, "REMOTE_REBOOT")
            elseif json_data.task == "get_device_info" then
                -- 设备硬件信息（IMEI/SN/ICCID/固件版本/模块型号）
                result = {
                    imei = misc.getImei(),
                    sn = misc.getSn(),
                    iccid = sim.getIccid(),
                    version = misc.getVersion(),
                    model = misc.getModelType()
                }
            elseif json_data.task == "ussd_query" then
                -- USSD 查询（话费/流量余额等，结果异步经通知渠道推送）
                if not json_data.code or json_data.code == "" then
                    error = "缺少必要参数: code（如 *108#，具体查运营商）"
                else
                    ril.request('AT+CUSD=1,"' .. json_data.code .. '",15')
                    result = "USSD 查询已发送: " .. json_data.code .. "，运营商回复将通过通知推送"
                end
            elseif json_data.task == "send_dtmf" then
                -- 通话中向对端发送 DTMF 按键（如输入分机号、语音信箱密码）
                if not json_data.dtmf or json_data.dtmf == "" then
                    error = "缺少必要参数: dtmf（仅支持数字和 ABCD*#）"
                elseif not cc.anyCallExist() then
                    error = "当前无通话，无法发送 DTMF"
                else
                    cc.sendDtmf(tostring(json_data.dtmf))
                    result = "DTMF 已发送: " .. json_data.dtmf
                end
            elseif json_data.task == "set_gpio" then
                -- GPIO 输出控制（可外接继电器实现远程开关）
                local pin = tonumber(json_data.pin)
                local level = tonumber(json_data.level)
                if pin == nil or level == nil or (level ~= 0 and level ~= 1) then
                    error = "参数 pin(GPIO编号,数字) 与 level(0或1) 必填"
                else
                    pins.setup(pin, level)
                    result = "GPIO" .. pin .. " 已输出 " .. level
                end
            else
                error = "未知的任务类型: " .. (json_data.task or "nil")
            end
        end)
        if not success then
            error = err
        end

        -- 任务结果入队，由主循环统一发布（避免并发访问 socket）
        local response = {
            type = "task_result",
            taskId = json_data.taskId,
            task = json_data.task,
            result = result,
            error = error
        }
        log.info("发送任务结果：", json.encode(response))
        table.insert(resultQueue, { imei = imei, payload = json.encode(response) })
    end)
end

-- 按配置建立 MQTT 连接（优先 MQTT_URL 单链接，兼容旧的 MQTT_HOST/MQTT_PORT）
-- MQTT_URL 支持格式：
--   wss://host/websocket      -- 加密 WebSocket（推荐，nginx 反代 443 → 面板端口）
--   ws://host:9527/websocket  -- 明文 WebSocket（直接连面板端口）
--   mqtt://host:1883          -- MQTT 明文（需服务端 config.json 中 mqtt.port > 0）
--   mqtts://host:8883         -- MQTT over TLS
local function mqttConnect(mqttc, timeout)
    local url = config.MQTT_URL
    if url and url ~= "" then
        local scheme, host, port, path = url:match("(%a+)://([^:/]+):?(%d*)(.*)")
        scheme = scheme and scheme:lower() or ""
        if scheme == "wss" or scheme == "ws" then
            -- WebSocket 传输（wss 加密，ws 明文），host 直接传完整 URL
            return mqttc:connect(url, nil, scheme, nil, timeout)
        elseif scheme == "mqtts" then
            local p = (port and port ~= "") and tonumber(port) or 8883
            return mqttc:connect(host, p, "tcp_ssl", nil, timeout)
        else
            -- mqtt 明文
            local p = (port and port ~= "") and tonumber(port) or 1883
            return mqttc:connect(host, p, "tcp", nil, timeout)
        end
    else
        -- 兼容旧参数：MQTT_HOST / MQTT_PORT（明文 TCP）
        local host = config.MQTT_HOST
        local port = config.MQTT_PORT or 1883
        return mqttc:connect(host, port, "tcp", nil, timeout)
    end
end

-- MQTT 连接与消息循环（自动重连）
local function startMQTT()
    local imei = misc.getImei()
    local clientID = config.MQTT_CLIENT_ID
    if clientID == nil or clientID == "" then
        clientID = imei
    end

    -- 看门狗基准初始化
    lastAliveMs, lastOkMs = tickMs(), tickMs()

    -- 独立看门狗协程（与 MQTT 主循环相互独立，主循环卡死时它依然运行）：
    -- 1) MQTT_STUCK_TIMEOUT（默认 5 分钟）内主循环毫无动静 —— 主循环卡死在某个
    --    永不返回的阻塞调用里（假死），重启模块自愈
    -- 2) MQTT_REBOOT_TIMEOUT（默认 15 分钟）内没有一次成功连接 —— socket 通道
    --    耗尽/网络异常等，重启模块自愈
    -- 对应配置为 0 时关闭对应检测
    sys.taskInit(function()
        local stuckTimeout = config.MQTT_STUCK_TIMEOUT or 300000
        local rebootTimeout = config.MQTT_REBOOT_TIMEOUT or 900000
        while true do
            sys.wait(30000)
            local n = tickMs()
            if stuckTimeout > 0 and n - lastAliveMs >= stuckTimeout then
                log.error("mqtt", "主循环超过", math.floor(stuckTimeout / 60000),
                    "分钟无响应（假死），自动重启自愈")
                sys.restart("MQTT_STUCK")
            elseif rebootTimeout > 0 and n - lastOkMs >= rebootTimeout then
                log.error("mqtt", "持续", math.floor(rebootTimeout / 60000),
                    "分钟未能连接服务端，自动重启自愈")
                sys.restart("MQTT_WATCHDOG")
            end
        end
    end)

    sys.taskInit(function()
        -- 重连指数退避：连续失败时等待 5s→10s→20s→40s→60s（封顶）
        -- 服务端停机期间若仍 5 秒一次地密集新建 SSL 连接，会持续冲击模块
        -- socket/AT 通道，可能触发 ril 的 AT 超时保护（3 分钟无应答即重启模块），
        -- 表现为"断线重连后设备自己重启"。退避可消除该压力，服务端恢复后最多
        -- 60 秒内自动重连
        local retry = 0
        while true do
            touchAlive()
            local target = config.MQTT_URL
            if not target then
                target = (config.MQTT_HOST or "") .. ":" .. tostring(config.MQTT_PORT or 1883)
            end
            log.info("mqtt", "正在连接服务端", target)
            -- 每次连接前都重建客户端对象：
            -- MQTT 客户端断开后不能复用（内部状态未重置），复用会导致重连失败、只能重启设备
            mqttc = mqtt.client(clientID, config.MQTT_KEEPALIVE or 300,
                config.MQTT_USERNAME, config.MQTT_PASSWORD, 1)
            local ok = mqttConnect(mqttc, 30)
            if ok then
                retry = 0
                touchOk()
                log.info("mqtt", "MQTT 连接成功, IMEI:", imei)
                -- 订阅服务端指令主题
                local sub_ok = mqttc:subscribe("cmd/" .. imei, 1)
                if not sub_ok then
                    -- 订阅失败则无法接收服务端指令，断开走重连流程，避免"假在线"
                    log.error("mqtt", "订阅失败，断开连接等待重连")
                else
                    -- 上报在线（retained，服务端重启后仍可感知设备）
                    local payload = json.encode({ type = "online", imei = imei, phone = util_mobile.getNumber() })
                    mqttc:publish("device/" .. imei .. "/online", payload, 1, 1)

                    -- 应用心跳间隔（毫秒）：周期重复上报 online，刷新服务端 lastSeen，用于离线判定
                    local beatInterval = config.HEARTBEAT_INTERVAL or 120000
                    local lastBeatMs = rtos.tick() * 5 -- 单调时钟（开机起毫秒数，不受 NTP 校时影响）

                    -- 接收循环（receive 内部会自动发送协议心跳包）
                    -- receive 每约 5 秒内部超时返回一次，借此间隙发送排队中的任务结果与应用心跳
                    local dead = false
                    while not dead do
                        -- 周期心跳：按间隔重复上报，避免设备真离线/假离线无法被服务端及时感知
                        local nowMs = rtos.tick() * 5
                        if nowMs - lastBeatMs >= beatInterval then
                            lastBeatMs = nowMs
                            -- QoS1 发布会等待服务端 PUBACK；连接若已静默断开（服务端重启/网络中断），
                            -- PUBACK 超时后 publish 返回 false，据此判定连接已死并触发重连
                            local pok, perr = mqttc:publish("device/" .. imei .. "/online", payload, 1, 1)
                            if not pok then
                                log.error("mqtt", "心跳发布失败，连接已断开，准备重连:", perr)
                                break
                            end
                        end
                        -- 统一发布任务结果（与接收同协程，串行访问 socket）
                        while #resultQueue > 0 do
                            local item = table.remove(resultQueue, 1)
                            local ok, perr = mqttc:publish("device/" .. item.imei .. "/result", item.payload, 1, 0)
                            if not ok then
                                -- 发布失败说明连接已断：放回队列，待重连成功后补发，并跳出接收循环
                                log.error("mqtt", "发布任务结果失败，连接已断开，放回队列待重连后补发:", perr)
                                table.insert(resultQueue, 1, item)
                                dead = true
                                break
                            end
                        end
                        if dead then
                            break
                        end
                        local r, data = mqttc:receive(5000) -- 短轮询，保证队列结果及时上报（心跳在 receive 内部自动维持）
                        touchAlive() -- receive 是最可能永久阻塞的调用，返回即证明主循环存活
                        touchOk()    -- 连接健康存活即视为"可达服务端"，持续刷新连接看门狗
                                     -- （否则连接成功 15 分钟后 lastOkMs 不再更新，会被
                                     --   MQTT_WATCHDOG 误判为"一直连不上"而周期性重启）
                        if r then
                            log.info("mqtt", "收到消息 topic=", data.topic)
                            local djson, json_data = pcall(json.decode, data.payload)
                            if djson and json_data then
                                handleTask(imei, json_data)
                            end
                        elseif data == "timeout" then
                            -- 正常等待超时，继续
                        else
                            log.error("mqtt", "接收异常，准备重连:", data)
                            break
                        end
                    end
                end
                -- 断开本次连接，等待重连（连接可能已断开，忽略断开错误）
                pcall(mqttc.disconnect, mqttc)
            else
                -- 兜底释放底层 socket：服务端重启期间（nginx 返回 502/连接超时）
                -- 每次失败若不释放会泄漏一个 socket 通道，耗尽后设备无法再连接
                pcall(mqttc.disconnect, mqttc)
            end
            retry = retry + 1
            local waitMs = math.min(5000 * (2 ^ (retry - 1)), 60000)
            if retry > 1 then
                log.info("mqtt", "下次重连等待", math.floor(waitMs / 1000), "秒（第", retry, "次重试）")
            end
            sys.wait(waitMs)
        end
    end)
end

return {
    start = startMQTT
}
