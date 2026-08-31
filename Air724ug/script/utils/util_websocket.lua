local websocket = require "websocket"
local log = require "log"
local sys = require "sys"
local misc = require "misc"
local util_mobile = require "util_mobile"
local util_notify = require "util_notify"
local util_temperature = require "util_temperature"
local config = require "config"
local nvm = require "nvm"

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

local function handleTask(ws, json_data)
    log.info("websocket:message", json_data.task)
    -- 处理task类型的消息
    if json_data.type == "task" and json_data.taskId then
        -- 执行对应的task函数
        sys.taskInit(function()
            local result = nil
            local error = nil
            
            -- 执行task函数
            local success, err = pcall(function()
                -- 根据taskid执行不同的任务
                if json_data.task == "get_temperature" then
                    -- 调用温度查询函数
                    result = util_temperature.get()
                elseif json_data.task == "send_sms" then
                    -- 检查参数
                    if not json_data.rcv_phone or not json_data.content then
                        error = "缺少必要参数: rcv_phone 或 content"
                    else
                        -- 发送短信
                        log.info('发送短信', json_data.rcv_phone, json_data.content)
                        -- 补全发送短信的逻辑
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
                    -- 直接读取/nvm_para.lua文件内容
                    local file = io.open("/nvm_para.lua", "r")
                    if file then
                        local content = file:read("*a")
                        file:close()
                        result = content
                    else
                        error = "无法读取/nvm_para.lua文件"
                    end
                elseif json_data.task == "set_config" then
                    if not json_data.configText or type(json_data.configText) ~= "string" then
                        error = "缺少必要参数: configText (必须是字符串)"
                    else
                        -- 直接写入 configText 到 /nvm_para.lua
                        local file = io.open("/nvm_para.lua", "w+")
                        if file then
                            file:write(json_data.configText)
                            file:close()
                            -- 直接解析 configText 并更新 config 表
                            local newcfg, err = parse_lua_config_string(json_data.configText)
                            if newcfg then
                                for k, v in pairs(newcfg) do
                                    config[k] = v
                                end
                                result = {success = true}
                            else
                                error = "解析配置字符串失败: " .. err
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
            
            -- 发送执行结果给服务端
            local response = {
                type = "task_result",
                taskId = json_data.taskId,
                task = json_data.task,
                result = result,
                error = error
            }

            log.info('发送任务结果：', json.encode(response))

            ws:send(json.encode(response), true)
        end)
    end
end

local function startWebSocket()
    
    log.info("websocket", "开始连接")

    -- websocket 连接
    -- 使用 config.WEBSOCKET_URL 获取地址
    local ws = websocket.new(config.WEBSOCKET_URL)

    ws:on("open", function()
        log.info("websocket", "连接已打开")
        -- 发送JSON数据
        local json_data = {
            type = "online",
            imei = misc.getImei(),
            phone = util_mobile.getNumber()
        }
        ws:send(json.encode(json_data), true)
    end)

    ws:on("message", function(data)
        -- 解析JSON数据
        local success, json_data = pcall(json.decode, data)
        if success then
            handleTask(ws, json_data)
        end
    end)

    ws:on("close", function()
        log.info("websocket", "连接关闭")
    end)

    ws:on("error", function(ws, err)
        log.error("websocket", "连接错误", err)
    end)

    -- 启动WebSocket任务
    ws:start(120)
end

return {
    start = startWebSocket
} 