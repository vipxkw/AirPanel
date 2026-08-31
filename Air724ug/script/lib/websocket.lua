--- 模块功能：websocket客户端
-- @module websocket
-- @author wendal
-- @license MIT
-- @copyright OpenLuat.com
-- @release 2023.09.18
require "utils"
require "socket"
module(..., package.seeall)

local magic = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

local ws = {}
ws.__index = ws
local function websocket(url, cert)
    return setmetatable({
        io = nil,
        url = url,
        key = "",
        wss = "",
        cert = cert,
        host = "",
        port = "",
        input = "",
        callbacks = {},
        send_data = {},
        send_text = nil,
        sendsize = 1460,
        open_callback = false,
        connected = false,
        terminated = false,
        readyState = "CONNECTING"
    }, ws)
end
--- 创建 websocket 对象
-- @string url websocket服务器的连接地址,格式为ws(或wss)://xxx开头
-- @table[opt=nil] cert ssl连接需要的证书配置，cert格式如下：
-- {
--     caCert = "ca.crt", --CA证书文件(Base64编码 X.509格式)，如果存在此参数，则表示客户端会对服务器的证书进行校验；不存在则不校验
--     clientCert = "client.crt", --客户端证书文件(Base64编码 X.509格式)，服务器对客户端的证书进行校验时会用到此参数
--     clientKey = "client.key", --客户端私钥文件(Base64编码 X.509格式)
--     clientPassword = "123456", --客户端证书文件密码[可选]
--     insist = 1, --证书中的域名校验失败时，是否坚持连接，默认为1，坚持连接，0为不连接
-- }
-- @return table 返回1个websocket对象
-- @usage local ws = websocket.new("ws://121.40.165.18:8800")
function new(url, cert)
    return websocket(url, cert)
end

--- ws:on 注册函数
-- @string event 事件，可选值"open","message","close","error","pong"
-- @function callback 回调方法，message|error|pong形参是该方法需要的数据。
-- @usage mt:on("message",function(message) local print(message)end)
function ws:on(event, callback)
    self.callbacks[event] = callback
end

--- websocket 与 websocket 服务器建立连接
-- @number timeout 与websocket服务器建立连接最长超时
-- @return bool,true,表示连接成功,false or nil 表示连接失败
-- @usage while not ws:connect(20000) do sys.wait(2000) end
function ws:connect(timeout)
    self.wss, self.host, self.port, self.path = self.url:match("(%a+)://([%w%.%-]+):?(%d*)(.*)")
    self.wss, self.host = self.wss:lower(), self.host:lower()
    self.port = self.port ~= "" and self.port or (self.wss == "wss" and 443 or 80)
    if self.wss == "wss" then
        self.io = socket.tcp(true, self.cert)
    else
        self.io = socket.tcp()
    end
    if not self.io then
        log.error("websocket:connect:", "没有可用的TCP通道!")
        return false
    end
    log.info("websocket url:", self.url)
    if not self.io:connect(self.host, self.port, timeout) then
        log.error("websocket:connect", "服务器连接失败!")
        -- 连接失败也必须关闭 socket：connect 超时路径中 core 层 socket 未释放，
        -- 不关闭会泄漏通道，多次重试后耗尽模块 socket（只能重启设备恢复）
        self.io:close()
        return false
    end
    self.key = crypto.base64_encode(math.random(100000000000000, 999999999999999) .. 0, 16)
    local req = "GET " .. self.path .. " HTTP/1.1\r\nHost: " .. self.host .. ":" .. self.port .. "\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n" .. "Origin: http://" .. self.host ..
                    "\r\nSec-WebSocket-Version: 13\r\n" .. "Sec-WebSocket-Key: " .. self.key .. "\r\n\r\n"
    if self.io:send(req, tonumber(timeout) or 20000) then
        local r, s = self.io:recv(tonumber(timeout) or 5000)
        if not r then
            self.io:close()
            log.error("websocket:connect", "与 websocket server 握手超时!")
            return false
        end
        local _, idx, code = s:find("%s(%d+)%s.-\r\n")
        if code == "101" then
            local header, accept = {}, self.key .. magic
            accept = crypto.sha1(accept, #accept):fromHex()
            accept = crypto.base64_encode(accept, #accept)
            for k, v in string.gmatch(s:sub(idx + 1, -1), "(.-):%s*(.-)\r\n") do
                header[k:lower()] = v
            end
            if header["sec-websocket-accept"] and header["sec-websocket-accept"] == accept then
                log.info("websocket:connect", "与 websocket server 握手成功!")
                self.connected, self.readyState = true, "OPEN"
                if self.callbacks.open then
                    self.open_callback = true
                end
                return true
            end
        end
    end
    log.error("websocket:connect", "与 websocket server 握手失败!")
    -- 握手失败（如服务端重启期间 nginx 返回 502）必须关闭底层连接：
    -- 否则每次重试泄漏一个 socket 通道，重部署期间 5 秒一次重试会迅速
    -- 耗尽模块 socket，导致设备从此连不上、只能重启恢复
    self.io:close()
    return false
end
-- 掩码加密
-- mask: 4位长度掩码字符串
-- data: 待加密的字符串
-- return: 掩码加密后的字符串
local function wsmask(mask, data)
    local i = 0
    return data:gsub(".", function(c)
        i = i + 1
        return string.char(bit.bxor(data:byte(i), mask:byte((i - 1) % 4 + 1)))
    end)
end
--- websocket发送帧方法
-- @bool fin true表示结束帧,false表示延续帧
-- @number opcode 0x0--0xF,其他值非法,代码意义参考websocket手册
-- @string data 用户要发送的数据
-- @usage self:sendFrame(true, 0x1, "www.openluat.com")
function ws:sendFrame(fin, opcode, data)
    if not self.connected then
        return
    end
    local finbit, maskbit, len = fin and 0x80 or 0, 0x80, #data
    local frame = pack.pack("b", bit.bor(finbit, opcode))
    if len < 126 then
        frame = frame .. pack.pack("b", bit.bor(len, maskbit))
    elseif len < 0xFFFF then
        frame = frame .. pack.pack(">bH", bit.bor(126, maskbit), len)
    else
        -- frame = frame .. pack.pack(">BL", bit.bor(127, maskbit), len)
        log.error("ws:sendFrame", "数据长度超过最大值!")
        return
    end
    local mask = pack.pack(">I", os.time())
    frame = frame .. mask .. wsmask(mask, data)
    for i = 1, #frame, self.sendsize do
        if not self.io:send(frame:sub(i, i + self.sendsize - 1)) then
            break
        end
    end
    return true
end
-- websocket 发送用户数据方法
-- @string data: 用户要发送的字符串数据
-- @bool text: true 数据为文本字符串,nil或false数据为二进制数据。
-- @usage self:send("www.openluat.com")
-- @usage self:send("www.openluat.com",true)
-- @usage self:send(string.fromHex("www.openluat.com"))
local function send(ws, data, text)
    if text then
        log.info("websocket cleint send:", data:sub(1, 100))
        ws:sendFrame(true, 0x1, data)
    else
        ws:sendFrame(true, 0x2, data)
    end
    if ws.callbacks.sent then
        ws.callbacks.sent()
    end
end
-- websocket发送数据包
-- @usage self:send(data, is_text)
function ws:send(data, text)
    table.insert(self.send_data, {data, text})
    sys.publish("WEBSOCKET_SEND_DATA", "send")
end

local function ping(ws)
    ws:sendFrame(true, 0x9, "")
end

local function pong(ws, data)
    ws:sendFrame(true, 0xA, data or "")
end

-- websocket发送ping包(已废弃)
-- @usage self:ping()
function ws:ping() end

-- websocket发送pong包(已废弃)
-- @usage self:pong()
function ws:pong() end

local function uplink(ws)
    while #ws.send_data > 0 do
        local tmp = {}
        for _, v in ipairs(ws.send_data) do
            table.insert(tmp, v)
        end
        ws.send_data = {}
        for _, v in ipairs(tmp) do
            send(ws, v[1], v[2])
        end
    end
end

-- 处理 websocket 发过来的数据并解析帧数据
-- @return string : 返回解析后的单帧用户数据
function ws:recvFrame()
    uplink(self) -- 有没有待上传数据, 有就全部上报
    local close_ctrl = "EXIT_TASK" .. self.io.id
    local r, s, p = self.io:recv(5000, "WEBSOCKET_SEND_DATA")
    if not r then
        if s == "timeout" then
            return false, nil, "WEBSOCKET_OK"
        elseif s == "WEBSOCKET_SEND_DATA" then
            if p == "send" then -- 主动上报
                uplink(self)
            elseif p == "ping" then -- 本地心跳上行
                ping(self, "")
            elseif p == "pong" then -- 服务器心跳下行,马上回应
                pong(self, "")
            elseif p == close_ctrl then
                return false, nil, close_ctrl
            end
            return false, nil, "WEBSOCKET_OK"
        else
            return false, nil, "Read byte error!"
        end
    end
    if #self.input ~= 0 then
        s = self.input .. s
    end
    local _, firstByte, secondByte = pack.unpack(s:sub(1, 2), "bb")
    local fin = bit.band(firstByte, 0x80) ~= 0
    local rsv = bit.band(firstByte, 0x70) ~= 0
    local opcode = bit.band(firstByte, 0x0f)
    local isControl = bit.band(opcode, 0x08) ~= 0
    -- 检查RSV1,RSV2,RSV3 是否为0,客户端不支持扩展
    if rsv then
        return false, nil, "服务器正在使用未定义的扩展!"
    end
    -- 检查数据是否存在掩码加密
    local maskbit = bit.band(secondByte, 0x80) ~= 0
    local length = bit.band(secondByte, 0x7f)
    if isControl and (length >= 126 or not fin) then
        return false, nil, "控制帧异常!"
    end
    if maskbit then
        return false, nil, "数据帧被掩码处理过!"
    end
    -- 获取载荷长度
    if length == 126 then
        -- if not r then return false, nil, "读取帧载荷长度失败!" end
        _, length = pack.unpack(s:sub(3, 4), ">H")
    elseif length == 127 then
        return false, nil, "数据帧长度超过支持范围!"
    end
    -- 获取有效载荷数据
    if length > 0 then
        -- TODO 支持大于64的包
        -- log.info("teste", #s, length)
        if length >= 126 then
            -- 长度字段为 126/127 时使用扩展长度(2/8字节), 载荷从包头后开始
            if #s < length + 4 then
                self.input = s
                return true, false, ""
            end
            s = s:sub(5, 5 + length - 1)
        else
            s = s:sub(3, 3 + length - 1)
        end
        -- log.info("s的长度", #s, length)
        -- if not r then return false, nil, "读取帧有效载荷数据失败!" end
    end
    -- 处理切片帧
    if not fin then -- 切片未完成
        return true, false, s
    else -- 未分片帧
        if opcode < 0x3 then -- 数据帧
            self.input = ""
            return true, true, s
        elseif opcode == 0x8 then -- close
            local code, reason
            if #s >= 2 then
                _, code = pack.unpack(s:sub(1, 2), ">H")
            end
            if #s > 2 then
                reason = s:sub(3)
            end
            self.terminated = true
            -- self:close(code, reason)
            self.input = ""
            return false, nil, reason
        elseif opcode == 0x9 then -- Ping
            pong(self, s or "")
        elseif opcode == 0xA then -- Pong
            if self.callbacks.pong then
                self.callbacks.pong(s)
            end
        end
        self.input = ""
        return true, true, nil
    end
end
--- 处理 websocket 发过来的数据并拼包
-- @return result, boolean: 返回数据的状态 true 为正常, false 为失败
-- @return data, string: result为true时为数据,false时为报错信息
-- @usage local result, data = ws:recv()
function ws:recv()
    local data = ""
    while true do
        local success, final, message = self:recvFrame()
        -- 数据帧解析错误
        if not success then
            return success, message
        end
        -- 数据帧分片处理
        if message then
            data = data .. message
        else
            data = "" -- 数据帧包含控制帧处理
        end
        -- 数据帧处理完成
        if final and message then
            break
        end
    end
    if self.callbacks.message then
        self.callbacks.message(data)
    end
    return true, data
end

--- 关闭 websocket 与服务器的链接
-- @number code 1000或1002等,请参考websocket标准
-- @string reason 关闭原因
-- @return nil
-- @usage ws:close()
-- @usage ws:close(1002,"协议错误")
function ws:close(code, reason)
    -- 1000  "normal closure" status code
    self.readyState = "CLOSING"
    if self.terminated then
        log.error("ws:close server code:", code, reason)
    elseif self.io and self.io.connected then
        if code == nil and reason ~= nil then
            code = 1000
        end
        local data = ""
        if code ~= nil then
            data = pack.pack(">H", code)
        end
        if reason ~= nil then
            data = data .. reason
        end
        self.terminated = true
        self:sendFrame(true, 0x8, data)
    end
    if self.io then self.io:close() end
    self.readyState, self.connected = "CLOSED", false
    if self.callbacks.close then
        self.callbacks.close(code or 1001)
    end
    self.input = ""
end
--- 主动退出一个指定的websocket任务
-- @传入一个websocket对象
-- @return nil
-- @usage wesocket.exit(ws)
function exit(ws)
    sys.publish("WEBSOCKET_SEND_DATA", "EXIT_TASK" .. ws.io.id)
end
--- 获取websocket当前状态
-- @return string,状态值("CONNECTING","OPEN","CLOSING","CLOSED")
-- @usage ws:state()
function ws:state()
    return self.readyState
end
--- 获取websocket与服务器连接状态
-- @return boolean: true 连接成功,其他值连接失败
-- @usage ws:online()
function ws:online()
    return self.connected
end
--- websocket 需要在任务中启动,带自动重连,支持心跳协议
-- @number[opt=nil] keepAlive websocket心跳包，建议30秒
-- @function[opt=nil] proc 处理服务器下发消息的函数
-- @number[opt=1000] reconnTime 断开链接后的重连时间
-- @return nil
-- @usage sys.taskInit(ws.start,ws,30)
-- @usage sys.taskInit(ws.start,ws,30,function(msg)u1:send(msg) end)
function ws:start(keepAlive, proc, reconnTime)
    reconnTime = tonumber(reconnTime) and reconnTime * 1000 or 1000
    keepAlivetimer = sys.timerLoopStart(self.ping, 30000, self)
    while true do
        while not socket.isReady() do
            sys.wait(1000)
        end
        if self:connect() then
            if self.open_callback == true then
                self.callbacks.open()
                self.open_callback = false
            end
            local close_ctrl = "EXIT_TASK" .. self.io.id
            repeat
                local r, message = self:recv()
                if r then
                    if type(proc) == "function" then
                        proc(message)
                    end
                elseif message == close_ctrl then
                    self:close()
                    sys.timerStop(keepAlivetimer)
                    if self.io.id ~= nil then
                        self = nil
                    end
                    return true
                elseif not r and message ~= "WEBSOCKET_OK" then
                    log.error('ws recv error', message)
                end
            until not r and message ~= "WEBSOCKET_OK"
        end
        self:close()
        log.info("websocket:Start", "与 websocket Server 的连接已断开!")
        sys.wait(reconnTime)
    end
end

