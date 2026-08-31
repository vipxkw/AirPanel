-- Y100E 硬件抽象（GPIO / ADC / UART）
-- 引脚映射见 config.lua，按银尔达 Y100E 实际电路修改
local sys = require "sys"
local config = require "config"
local util_notify = require "util_notify"

local hw = {}

-- GPIO 输出（默认低电平，可接继电器）
local gpio_out = nil
-- GPIO 输入（状态检测，电平变化推送通知）
local gpio_in_ok = false

pcall(function()
    gpio_out = gpio.setup(config.GPIO_OUT, 0)
end)

pcall(function()
    local first_cb = true
    gpio.setup(config.GPIO_IN, function(state)
        -- gpio.setup 初始化完成会立即回调一次初始电平，并非真实电平变化，
        -- 跳过以免开机误报（开机状态已并入上线综合通知）
        if first_cb then
            first_cb = false
            return
        end
        if config.GPIO_IN_NOTIFY then
            util_notify.add("GPIO" .. config.GPIO_IN .. " 输入电平变化: " ..
                (state == 1 and "高电平" or "低电平"))
        end
    end, gpio.PULLUP)
    gpio_in_ok = true
end)

-- ADC（普通通道 + VBAT 电源电压 + CPU 内部温度）
pcall(function() adc.open(config.ADC_CH) end)
pcall(function() adc.open(adc.CH_VBAT) end)
pcall(function() adc.open(adc.CH_CPU) end)

-- TTL 串口（透传外部设备）
pcall(function()
    uart.setup(config.UART_ID, config.UART_BAUD, 8, 1)
    uart.on(config.UART_ID, "recv", function(id, len)
        local data = ""
        while true do
            local tmp = uart.read(id, 127)
            if not tmp or #tmp == 0 then break end
            data = data .. tmp
        end
        if #data > 0 then
            log.info("uart", "收到数据", "长度:", #data)
            if config.UART_NOTIFY then
                util_notify.add({ "串口收到数据", "长度: " .. #data, "hex: " .. string.toHex(data) })
            end
        end
    end)
end)

--- GPIO 输出控制
-- @param pin (number) GPIO 编号
-- @param level (number) 0 或 1
-- @return (boolean[, string])
function hw.setGpio(pin, level)
    pin = tonumber(pin)
    level = tonumber(level)
    if pin == nil or level == nil or (level ~= 0 and level ~= 1) then
        return false, "参数 pin(GPIO编号) 与 level(0或1) 必填"
    end
    if pin == config.GPIO_OUT and gpio_out then
        gpio_out(level)
    else
        -- 其他引脚直接初始化为输出并输出指定电平
        local ok, err = pcall(gpio.setup, pin, level)
        if not ok then
            return false, "GPIO" .. pin .. " 初始化失败: " .. tostring(err)
        end
    end
    return true
end

--- 读取 GPIO 输入电平
-- @return (number/nil) 0 或 1，未初始化返回 nil
function hw.getGpio()
    if not gpio_in_ok then return nil end
    local ok, level = pcall(gpio.get, config.GPIO_IN)
    if ok then return level end
    return nil
end

--- 读取 ADC 电压（毫伏）
function hw.getAdc()
    local ok, v = pcall(adc.get, config.ADC_CH)
    if ok and type(v) == "number" then return v end
    return nil
end

--- 读取 VBAT 电源电压（毫伏）
function hw.getVbat()
    local ok, v = pcall(adc.get, adc.CH_VBAT)
    if ok and type(v) == "number" then return v end
    return nil
end

--- 读取 CPU 内部温度（摄氏度，Air780EP 经 adc.CH_CPU 通道，返回千分之一度）
function hw.getTemp()
    local ok, t = pcall(adc.get, adc.CH_CPU)
    if ok and type(t) == "number" and t > -40000 and t < 125000 then
        return string.format("%.1f", t / 1000)
    end
    return nil
end

--- 串口发送数据
-- @param data (string) 待发送数据（原文透传）
function hw.uartSend(data)
    if type(data) ~= "string" or data == "" then
        return false, "缺少必要参数: data"
    end
    local ok, err = pcall(uart.write, config.UART_ID, data)
    if not ok then
        return false, "串口发送失败: " .. tostring(err)
    end
    return true
end

return hw
