-- 通过 MQTT 对接服务端（替代原 WebSocket 方案）
-- 相比 WebSocket，MQTT 消息头仅 2~5 字节、心跳间隔可拉长（默认 300s）、
-- 支持双向发布/订阅，显著降低设备端流量消耗。
local mqtt = require "mqtt"
local log = require "log"
local sys = require "sys"
local misc = require "misc"
local util_mobile = require "util_mobile"
local util_temperature = require "util_temperature"
local config = require "config"
local nvm = require "nvm"

local mqttc = nil

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
            else
                error = "未知的任务类型: " .. (json_data.task or "nil")
            end
        end)
        if not success then
            error = err
        end

        -- 通过 MQTT 回报任务结果
        local response = {
            type = "task_result",
            taskId = json_data.taskId,
            task = json_data.task,
            result = result,
            error = error
        }
        log.info("发送任务结果：", json.encode(response))
        if mqttc then
            local ok, perr = mqttc:publish("device/" .. imei .. "/result", json.encode(response), 1, 0)
            if not ok then
                log.error("mqtt", "发布任务结果失败", perr)
            end
        end
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

    -- clientId, keepAlive(默认300秒), username, password, cleanSession
    mqttc = mqtt.client(clientID, config.MQTT_KEEPALIVE or 300,
        config.MQTT_USERNAME, config.MQTT_PASSWORD, 1)

    sys.taskInit(function()
        while true do
            local target = config.MQTT_URL
            if not target then
                target = (config.MQTT_HOST or "") .. ":" .. tostring(config.MQTT_PORT or 1883)
            end
            log.info("mqtt", "正在连接服务端", target)
            local ok = mqttConnect(mqttc, 30)
            if ok then
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

                    -- 接收循环（receive 内部会自动发送心跳包）
                    while true do
                        local r, data = mqttc:receive(300000)
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
                -- 断开本次连接，等待重连
                mqttc:disconnect()
            else
                log.error("mqtt", "MQTT 连接失败，5 秒后重试")
            end
            sys.wait(5000)
        end
    end)
end

return {
    start = startMQTT
}
