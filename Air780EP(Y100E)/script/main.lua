-- 银尔达 Y100E（合宙 Air780E / EC618 / LuatOS）远程管理脚本
-- 与 Air724UG Web 面板共用同一 MQTT 服务端（wss 单端口方案）
--
-- 烧录方法（Luatools）：
--   1. 固件选择 EC618 LuatOS 最新版（须 >= 2025-09-23，mqtt 库才支持 ws/wss URL）
--   2. 脚本列表添加本目录全部 .lua 文件（main.lua 必须在根目录）
--   3. config.lua 中的引脚按 Y100E 实际电路调整
PROJECT = "y100e-remote"
VERSION = "1.0.0"

_G.sys = require "sys"
_G.sysplus = require "sysplus"

local util_notify = require "util_notify"
local util_mqtt = require "util_mqtt"

-- ---- 外部硬件看门狗（银尔达板载 Air153C 芯片）----
-- Y100E/Core-Y100P 板载外部看门狗芯片 Air153C，喂狗脚为 GPIO28，
-- 超时 209~283 秒（随供电电压变化，不可修改）。不喂狗则整机被周期性复位！
-- 喂狗方式：GPIO28 拉高 400ms 后拉低（官方库 air153C_wtd 实现）
-- 官方建议每 150 秒喂一次，此处 120 秒喂一次留足裕量
local air153C_wtd = require "air153C_wtd"
local WTD_PIN = 28
sys.taskInit(function()
    local ok_init, err = pcall(air153C_wtd.init, WTD_PIN)
    if ok_init then
        air153C_wtd.feed_dog(WTD_PIN) -- 开机必须立即喂一次
        log.info("wtd", "外部看门狗已启动, GPIO" .. WTD_PIN .. ", 120秒周期喂狗")
        while true do
            sys.wait(120000)
            pcall(air153C_wtd.feed_dog, WTD_PIN)
        end
    else
        log.error("wtd", "看门狗初始化失败:", tostring(err))
    end
end)

-- NTP 时间同步（Air780E 固件内置 socket.sntp，无需外部 ntp.lua 脚本库）
-- 移动/电信卡通常基站下发时间，联通卡往往需要 sntp，故保留周期校时
sys.taskInit(function()
    sys.waitUntil("IP_READY", 60000)
    while true do
        -- pcall 保护：协程内未捕获错误会导致 Lua VM 退出整机重启
        pcall(socket.sntp)
        if sys.waitUntil("NTP_UPDATE", 5000) then
            log.info("sntp", "时间同步成功", os.date())
            sys.wait(3600000) -- 每小时校时一次
        else
            sys.wait(60000) -- 失败 1 分钟后重试
        end
    end
end)

-- 启动 MQTT（内部等待网络就绪后连接，开机通知在首次连接成功时触发）
util_mqtt.start()

-- 系统初始化
sys.run()
