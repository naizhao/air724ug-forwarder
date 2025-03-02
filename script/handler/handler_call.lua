------------------------------------------------- Config --------------------------------------------------

-- 去除链接最后的斜杠
local function trimSlash(url)
    return string.gsub(url, "/$", "")
end

-- 录音上传接口
local record_upload_url = trimSlash(config.UPLOAD_URL) .. "/record"

-- 录音格式, 1:pcm 2:wav 3:amrnb 4:speex
local record_format = 2

-- 录音质量, 仅 amrnb 格式有效, 0：一般 1：中等 2：高 3：无损
local record_quality = 3

-- 录音最长时间, 单位秒, <=50
local record_max_time = 50

-- 音量配置
audio.setCallVolume(7)
audio.setMicVolume(15)
audio.setMicGain("record", 7)

------------------------------------------------- 初始化及状态记录 --------------------------------------------------

local record_extentions = {
    [1] = "pcm",
    [2] = "wav",
    [3] = "amr",
    [4] = "speex"
}
local record_mime_types = {
    [1] = "audio/x-pcm",
    [2] = "audio/wav",
    [3] = "audio/amr",
    [4] = "audio/speex"
}
local record_extention = record_extentions[record_format]
local record_mime_type = record_mime_types[record_format]

local record_upload_header = {["Content-Type"] = record_mime_type, ["Connection"] = "keep-alive"}
local record_upload_body = {[1] = {["file"] = record.getFilePath()}}

CALL_IN = false
CALL_NUMBER = ""

local CALL_CONNECTED_TIME = 0
local CALL_DISCONNECTED_TIME = 0
local CALL_RECORD_START_TIME = 0

------------------------------------------------- 录音上传相关 --------------------------------------------------

local function recordUploadResultNotify(result, url, msg)
    CALL_DISCONNECTED_TIME = CALL_DISCONNECTED_TIME == 0 and os.time() or CALL_DISCONNECTED_TIME

    local lines = {
        "来电号码: " .. CALL_NUMBER,
        "通话时长: " .. CALL_DISCONNECTED_TIME - CALL_CONNECTED_TIME .. " S",
        "录音时长: " .. (result and (CALL_DISCONNECTED_TIME - CALL_RECORD_START_TIME) or 0) .. " S",
        "录音结果: " .. (result and "成功" or ("失败, " .. (msg or ""))),
        result and ("录音文件: " .. url) or "",
        "",
        "#CALL #CALL_RECORD"
    }

    util_notify.add(lines)
end

-- 录音上传结果回调
local function customHttpCallback(url, result, prompt, head, body)
    if result and prompt == "200" then
        log.info("handler_call.customHttpCallback", "录音上传成功", url, result, prompt)
        recordUploadResultNotify(true, url)
    else
        log.error("handler_call.customHttpCallback", "录音上传失败", url, result, prompt, head, body)
        recordUploadResultNotify(false, nil, "录音上传失败")
    end
end

-- 录音上传
local function upload()
    local local_file = record.getFilePath()
    local time = os.time()
    local date = os.date("*t", time)
    local date_str =
        table.concat(
        {
            date.year .. "/",
            string.format("%02d", date.month) .. "/",
            string.format("%02d", date.day) .. "/",
            string.format("%02d", date.hour) .. "-",
            string.format("%02d", date.min) .. "-",
            string.format("%02d", date.sec)
        },
        ""
    )
    -- URL 结构: /record/18888888888/2022/12/12/12-00-00/10086_1668784328.wav
    local url = record_upload_url .. "/"
    url = url .. (sim.getNumber() or "unknown") .. "/"
    url = url .. date_str .. "/"
    url = url .. CALL_NUMBER .. "_" .. time .. "." .. record_extention

    local function httpCallback(...)
        customHttpCallback(url, ...)
    end

    sys.taskInit(http.request, "PUT", url, nil, record_upload_header, record_upload_body, 50000, httpCallback)
end

------------------------------------------------- 录音相关 --------------------------------------------------

-- 录音结束回调
local function recordCallback(result, size)
    -- 先停止所有挂断电话定时器，再挂断电话
    sys.timerStopAll(cc.hangUp)
    cc.hangUp(CALL_NUMBER)

    -- 如果录音成功, 上传录音文件
    if result then
        log.info("handler_call.recordCallback", "录音成功", "result:", result, "size:", size)
        upload()
    else
        log.error("handler_call.recordCallback", "录音失败", "result:", result, "size:", size)
        recordUploadResultNotify(false, nil, "录音失败 size:" .. (size or "nil"))
    end
end

-- 开始录音
local function reacrdStart()
    if (CALL_IN and cc.CONNECTED) then
        log.info("handler_call.reacrdStart", "正在通话中, 开始录音", "result:", result)
        CALL_RECORD_START_TIME = os.time()
        record.start(record_max_time, recordCallback, "FILE", record_quality, 2, record_format)
    else
        log.info("handler_call.reacrdStart", "通话已结束, 不录音", "result:", result)
        recordUploadResultNotify(false, nil, "呼叫方提前挂断电话, 无录音")
    end
end

------------------------------------------------- TTS 相关 --------------------------------------------------

-- TTS 播放结束回调
local function ttsCallback(result)
    log.info("handler_call.ttsCallback", "result:", result)

    -- 判断来电动作是否为接听后挂断
    if nvm.get("CALL_IN_ACTION") == 3 then
        -- 如果是接听后挂断，则不录音，直接返回
        log.info("handler_call.callIncomingCallback", "来电动作", "接听后挂断")
        util_notify.add({"来电号码: " .. CALL_NUMBER, "来电动作: 接听后挂断", "", "#CALL #CALL_IN"})
        cc.hangUp(CALL_NUMBER)
    else
        -- 延迟开始录音, 防止 TTS 播放时主动挂断电话, 会先触发 TTS 结束回调, 再触发挂断电话回调, 导致 reacrdStart() 判断到正在通话中
        sys.timerStart(reacrdStart, 500)
        -- 发通知
        util_notify.add({"来电号码: " .. CALL_NUMBER, "来电动作: 接听并录音", "", "#CALL #CALL_IN"})
    end
end

-- 播放 TTS，播放结束后开始录音
local function tts()
    log.info("handler_call.tts", "TTS 播放开始")

    if config.TTS_TEXT and config.TTS_TEXT ~= "" then
        -- 播放 TTS
        audio.setTTSSpeed(60)
        audio.play(7, "TTS", config.TTS_TEXT, 7, ttsCallback)
    else
        -- 播放音频文件
        if nvm.get("CALL_IN_ACTION") == 3 then
            util_audio.audioStream("/lua/audio_pickup_hangup.amr", ttsCallback)
        else
            util_audio.audioStream("/lua/audio_pickup_record.amr", ttsCallback)
        end
    end
end

------------------------------------------------- 电话回调函数 --------------------------------------------------

-- 电话拨入回调
-- 设备主叫时, 不会触发此回调
local function callIncomingCallback(num)
    -- 来电动作, 挂断
    if nvm.get("CALL_IN_ACTION") == 2 then
        log.info("handler_call.callIncomingCallback", "来电动作", "挂断")
        cc.hangUp(num)
        -- 发通知
        util_notify.add({"来电号码: " .. num, "来电动作: 挂断", "", "#CALL #CALL_IN"})
        return
    end

    -- CALL_IN 从电话接入到挂断都是 true
    if CALL_IN then
        return
    end

    -- 来电动作, 无操作 or 接听
    if nvm.get("CALL_IN_ACTION") == 0 then
        log.info("handler_call.callIncomingCallback", "来电动作", "无操作")
        -- 发通知
        util_notify.add({"来电号码: " .. num, "来电动作: 无操作", "", "#CALL #CALL_IN"})
    else
        log.info("handler_call.callIncomingCallback", "来电动作", "接听")
        -- 标记接听来电中
        CALL_IN = true
        -- 根据用户配置切换音频, 接听电话
        sys.timerStart(
            function()
                local output, input = 2, 0
                -- 切换音频输出为 1:耳机, 用于实现通话时静音
                if not nvm.get("CALL_PLAY_TO_SPEAKER_ENABLE") or nvm.get("AUDIO_VOLUME") == 0 then
                    output = 1
                end
                -- 切换音频输入为 3:耳机mic, 用于实现通话时静音
                if not nvm.get("CALL_MIC_ENABLE") or nvm.get("AUDIO_VOLUME") == 0 then
                    input = 3
                end
                audio.setChannel(output, input)

                -- 接听电话
                cc.accept(num)
            end,
            1000 * 2
        )
    end
end

-- 电话接通回调
local function callConnectedCallback(num)
    -- 再次标记接听来电中, 防止设备主叫时, 不触发 `CALL_INCOMING` 回调, 导致 CALL_IN 为 false
    CALL_IN = true
    -- 接通时间
    CALL_CONNECTED_TIME = os.time()
    -- 来电号码
    CALL_NUMBER = num or "unknown"

    CALL_DISCONNECTED_TIME = 0
    CALL_RECORD_START_TIME = 0

    log.info("handler_call.callConnectedCallback", num)

    -- 设置 mic 增益等级, 通话建立成功之后设置才有效
    audio.setMicGain("call", 7)

    -- 停止之前的播放
    audio.stop()
    -- 向对方播放留言提醒 TTS
    sys.timerStart(tts, 1000 * 1)

    -- 定时结束通话
    sys.timerStart(cc.hangUp, 1000 * 60 * 2, num)
end

-- 电话挂断回调
-- 设备主叫时, 被叫方主动挂断电话或者未接, 也会触发此回调
local function callDisconnectedCallback(discReason)
    -- 标记来电结束
    CALL_IN = false
    -- 通话结束时间
    CALL_DISCONNECTED_TIME = os.time()
    -- 清除所有挂断通话定时器, 防止多次触发挂断回调
    sys.timerStopAll(cc.hangUp)

    log.info("handler_call.callDisconnectedCallback", "挂断原因:", discReason)

    -- 录音结束
    record.stop()
    -- TTS 结束
    audio.stop()

    -- 切换音频输出为 2:喇叭, 音频输入为 0:主mic
    audio.setChannel(2, 0)
end

-- 注册电话回调
sys.subscribe("CALL_INCOMING", callIncomingCallback)
sys.subscribe("CALL_CONNECTED", callConnectedCallback)
sys.subscribe("CALL_DISCONNECTED", callDisconnectedCallback)

ril.regUrc(
    "RING",
    function()
        -- 来电铃声
        util_audio.play(4, "FILE", "/lua/audio_ring.mp3")
    end
)
