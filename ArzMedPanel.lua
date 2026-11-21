script_name('ArzMedPanel')
script_version('1.2')

require 'lib.moonloader'
local imgui    = require 'mimgui'
local encoding = require 'encoding'
local vkeys    = require 'vkeys'
local ffi      = require 'ffi'
local bit      = require 'bit'
local hasSampEvents, sampev = pcall(require, 'lib.samp.events')

encoding.default = 'CP1251'
local u8 = encoding.UTF8

local PANEL_SIDE     = 'right'
local PANEL_MARGIN_X = 40
local ECHO_SENT      = true

local W, H = 400, 440
local M = 18
local CARD_H, CARD_GAP = 46, 6
local MAX_ID = 1004
local NEAR_RADIUS = 10.0
local TOAST_TIME = 2.4

local MODES = { 'process', 'type', 'raw' }
local MODE_DESC = {
    'sampProcessChatInput (имитация ввода, ловит Arizona Helper)',
    'ввод в чат + Enter (как руками)',
    'sampSendChat (напрямую на сервер)',
}
local sendModeIdx = 1

local isUnlocked   = false
local panelAlpha   = 0.0
local frameDt      = 0.016
local focusFrames  = 0
local pendingCmd   = nil
local pendingIdx   = nil
local retryReq     = nil
local lastSent     = nil
local idBuf        = imgui.new.char[5]()
local anim         = {}
local fonts        = {}
local toast        = { text = '', t = 0, kind = 'info' }

local DEFAULT_CMDS = { '/hl', '/med', '/hlb', '/recept', '/ant' }
local ACTIONS = {
    { name = 'Лечение',           cmd = DEFAULT_CMDS[1] },
    { name = 'Медкарта',          cmd = DEFAULT_CMDS[2] },
    { name = 'Лечение от завис.', cmd = DEFAULT_CMDS[3] },
    { name = 'Рецепт',            cmd = DEFAULT_CMDS[4] },
    { name = 'Антибиотик',        cmd = DEFAULT_CMDS[5] },
}

local CFG_DIR  = getWorkingDirectory() .. '\\config'
local CFG_PATH = CFG_DIR .. '\\ArzMedPanel.json'

local function saveConfig()
    pcall(createDirectory, CFG_DIR)
    local list = {}
    for i = 1, #ACTIONS do list[i] = ACTIONS[i].cmd end
    local f = io.open(CFG_PATH, 'w')
    if f then
        f:write(encodeJson({ cmds = list, mode = MODES[sendModeIdx] }))
        f:close()
    end
end

local function loadConfig()
    local f = io.open(CFG_PATH, 'r')
    if not f then return end
    local s = f:read('*a')
    f:close()
    local ok, t = pcall(decodeJson, s)
    if not ok or type(t) ~= 'table' then return end
    local list = t.cmds or t
    for i = 1, #ACTIONS do
        if type(list[i]) == 'string' and list[i]:match('^/[%w_]+$') then
            ACTIONS[i].cmd = list[i]
        end
    end
    if type(t.mode) == 'string' then
        for i, m in ipairs(MODES) do
            if m == t.mode then sendModeIdx = i end
        end
    end
end

loadConfig()

local COL = {
    text     = { 0.93, 0.94, 0.98, 1.0 },
    dim      = { 0.52, 0.57, 0.70, 1.0 },
    faint    = { 0.37, 0.42, 0.55, 1.0 },
    accent   = { 0.42, 0.48, 1.00, 1.0 },
    accentHi = { 0.68, 0.73, 1.00, 1.0 },
    green    = { 0.30, 0.82, 0.58, 1.0 },
    red      = { 0.96, 0.40, 0.45, 1.0 },
    orange   = { 1.00, 0.64, 0.25, 1.0 },
    field    = { 0.040, 0.046, 0.078, 1.0 },
    keycap   = { 0.17, 0.19, 0.29, 1.0 },
    badge    = { 0.14, 0.16, 0.24, 1.0 },
    outline  = { 0.20, 0.24, 0.37, 1.0 },
}

local function V2(x, y) return imgui.ImVec2(x, y) end
local function C(t, a) return imgui.ImVec4(t[1], t[2], t[3], a or t[4] or 1) end
local function U32(t, a)
    return imgui.ColorConvertFloat4ToU32(
        imgui.ImVec4(t[1], t[2], t[3], (a or t[4] or 1) * panelAlpha))
end
local function lerp(a, b, t) return a + (b - a) * t end
local function mix(a, b, t)
    return { lerp(a[1], b[1], t), lerp(a[2], b[2], t), lerp(a[3], b[3], t),
             lerp(a[4] or 1, b[4] or 1, t) }
end
local function smoothStep(cur, target, speed, dt)
    local res = cur + (target - cur) * math.min(1.0, dt * speed)
    if math.abs(target - res) < 0.01 then return target end
    return res
end
local function animTo(key, target, speed)
    anim[key] = smoothStep(anim[key] or 0, target, speed or 14, frameDt)
    return anim[key]
end
local function pf(f) if f then imgui.PushFont(f) end end
local function pp(f) if f then imgui.PopFont() end end

local function showToast(text, kind)
    toast.text = u8(text)
    toast.t = TOAST_TIME
    toast.kind = kind or 'info'
end

local function chatMsg(utf8text)
    sampAddChatMessage(u8:decode(utf8text), -1)
end

local function lockPanel()
    isUnlocked = false
    focusFrames = 0
end

local function unlockPanel()
    isUnlocked = true
    if panelAlpha < 0.02 then panelAlpha = 0.02 end
    ffi.copy(idBuf, '')
    focusFrames = 20
    toast.t = 0
end

local function togglePanel()
    if isUnlocked then lockPanel() else unlockPanel() end
end

local function parseId(str)
    if not str:match('^%d+$') then return nil end
    local id = tonumber(str)
    if not id or id > MAX_ID then return nil end
    return id
end

local function getMyId()
    local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if ok then return id end
    return -1
end

local function rpNick(id)
    local n = sampGetPlayerNickname(id)
    if not n or #n == 0 then return 'Unknown' end
    return (n:gsub('_', ' '))
end

local function findNearestPlayer(radius)
    if not isSampAvailable() or not doesCharExist(PLAYER_PED) then return nil end
    local myId = getMyId()
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    local bestId, bestDist = nil, radius
    for id = 0, sampGetMaxPlayerId(false) do
        if id ~= myId and sampIsPlayerConnected(id) then
            local ok, ped = sampGetCharHandleBySampPlayerId(id)
            if ok and doesCharExist(ped) then
                local x, y, z = getCharCoordinates(ped)
                local d = getDistanceBetweenCoords3d(px, py, pz, x, y, z)
                if d <= bestDist then bestDist, bestId = d, id end
            end
        end
    end
    return bestId, bestDist
end

local function onAction(i, act)
    local id = parseId(ffi.string(idBuf))
    if not id then
        showToast('Сначала введи ID игрока', 'warn')
        focusFrames = 20
        return
    end
    pendingCmd = act.cmd .. ' ' .. id
    pendingIdx = i
    lockPanel()
end

local function sendViaMode(mode, text)
    local s = u8:decode(text)
    if mode == 'process' then
        if sampProcessChatInput then
            local ok = pcall(sampProcessChatInput, s)
            if not ok then pcall(sampSendChat, s) end
        else
            pcall(sampSendChat, s)
        end
    elseif mode == 'type' then
        sampSetChatInputEnabled(true)
        wait(70)
        sampSetChatInputText(s)
        wait(70)
        setVirtualKeyDown(vkeys.VK_RETURN, true)
        wait(50)
        setVirtualKeyDown(vkeys.VK_RETURN, false)
    else
        pcall(sampSendChat, s)
    end
end

local function doSend(full, idx, mi)
    lastSent = {
        t = os.clock(),
        full = full,
        cmd = full:match('^(/[%w_]+)') or full,
        idx = idx,
        mi = mi,
    }
    if ECHO_SENT then
        chatMsg(u8('{6C7BFF}[MedPanel] {FFFFFF}Отправлено: {FFD166}' .. full
            .. ' {9AA3C7}[' .. MODES[mi] .. ']'))
    end
    sendViaMode(MODES[mi], full)
end

local function printCmdList()
    chatMsg(u8('{6C7BFF}[MedPanel] {FFFFFF}Текущие команды кнопок:'))
    for i, a in ipairs(ACTIONS) do
        chatMsg(u8('{9AA3C7}  ' .. i .. '. ' .. a.name .. ' {FFFFFF}-> ' .. a.cmd))
    end
    chatMsg(u8('{9AA3C7}Изменить: {FFFFFF}/medcmd <номер> <команда>{9AA3C7}, сбросить: {FFFFFF}/medcmd reset'))
end

local function cmdMedcmd(arg)
    arg = (arg or ''):match('^%s*(.-)%s*$')
    if arg == '' then
        printCmdList()
        return
    end
    if arg:lower() == 'reset' then
        for i = 1, #ACTIONS do ACTIONS[i].cmd = DEFAULT_CMDS[i] end
        saveConfig()
        chatMsg(u8('{6C7BFF}[MedPanel] {FFFFFF}Команды сброшены на стандартные.'))
        return
    end
    local n, c = arg:match('^(%d+)%s+/?([%w_]+)$')
    n = tonumber(n)
    if n and ACTIONS[n] and c then
        ACTIONS[n].cmd = '/' .. c
        saveConfig()
        chatMsg(u8('{6C7BFF}[MedPanel] {FFFFFF}Кнопка №' .. n .. ' (' .. ACTIONS[n].name
            .. ') теперь отправляет {6C7BFF}/' .. c .. ' ID'))
    else
        chatMsg(u8('{FF6666}[MedPanel] {FFFFFF}Формат: /medcmd <номер 1-5> <команда без слеша>. Пример: /medcmd 1 heal'))
    end
end

local function cmdMedmode(arg)
    arg = (arg or ''):match('^%s*(.-)%s*$')
    local n = tonumber(arg)
    if n and MODES[n] then
        sendModeIdx = n
        saveConfig()
        chatMsg(u8('{6C7BFF}[MedPanel] {FFFFFF}Режим отправки: {FFD166}' .. n .. ' - ' .. MODE_DESC[n]))
        return
    end
    chatMsg(u8('{6C7BFF}[MedPanel] {FFFFFF}Текущий режим: {FFD166}' .. sendModeIdx .. ' - ' .. MODE_DESC[sendModeIdx]))
    for i = 1, #MODES do
        chatMsg(u8('{9AA3C7}  /medmode ' .. i .. ' {FFFFFF}- ' .. MODE_DESC[i]))
    end
end

imgui.OnInitialize(function()
    local io = imgui.GetIO()
    io.IniFilename = nil

    local ranges = io.Fonts:GetGlyphRangesCyrillic()
    local dir = getFolderPath(0x14) .. '\\'
    local reg, bold = dir .. 'arial.ttf', dir .. 'arialbd.ttf'
    if not doesFileExist(bold) then bold = reg end
    if doesFileExist(reg) then
        fonts.main      = io.Fonts:AddFontFromFileTTF(reg,  16.0, nil, ranges)
        fonts.small     = io.Fonts:AddFontFromFileTTF(reg,  14.0, nil, ranges)
        fonts.bold      = io.Fonts:AddFontFromFileTTF(bold, 16.0, nil, ranges)
        fonts.boldSmall = io.Fonts:AddFontFromFileTTF(bold, 14.0, nil, ranges)
        fonts.title     = io.Fonts:AddFontFromFileTTF(bold, 20.0, nil, ranges)
    end

    local style = imgui.GetStyle()
    local c = style.Colors
    style.WindowRounding   = 14.0
    style.ChildRounding    = 10.0
    style.FrameRounding    = 8.0
    style.PopupRounding    = 8.0
    style.WindowBorderSize = 1.0
    style.FrameBorderSize  = 0.0

    c[imgui.Col.WindowBg]       = imgui.ImVec4(0.065, 0.075, 0.110, 0.97)
    c[imgui.Col.PopupBg]        = imgui.ImVec4(0.090, 0.100, 0.145, 0.99)
    c[imgui.Col.Border]         = imgui.ImVec4(0.20, 0.24, 0.37, 0.55)
    c[imgui.Col.FrameBg]        = imgui.ImVec4(0.040, 0.046, 0.078, 1.00)
    c[imgui.Col.FrameBgHovered] = imgui.ImVec4(0.055, 0.063, 0.100, 1.00)
    c[imgui.Col.FrameBgActive]  = imgui.ImVec4(0.060, 0.070, 0.110, 1.00)
    c[imgui.Col.Text]           = imgui.ImVec4(0.93, 0.94, 0.98, 1.00)
    c[imgui.Col.TextDisabled]   = imgui.ImVec4(0.37, 0.42, 0.55, 1.00)
    c[imgui.Col.TextSelectedBg] = imgui.ImVec4(0.42, 0.48, 1.00, 0.40)
end)

local function drawHeader(dl, wp)
    local a = COL.accent

    local x0, x1 = wp.x + 28, wp.x + W - 28
    local xm = (x0 + x1) / 2
    local y0, y1 = wp.y + 1, wp.y + 3
    dl:AddRectFilledMultiColor(V2(x0, y0), V2(xm, y1), U32(a, 0), U32(a, 0.95), U32(a, 0.95), U32(a, 0))
    dl:AddRectFilledMultiColor(V2(xm, y0), V2(x1, y1), U32(a, 0.95), U32(a, 0), U32(a, 0), U32(a, 0.95))
    dl:AddRectFilledMultiColor(V2(x0, y1), V2(xm, y1 + 30), U32(a, 0), U32(a, 0.10), U32(a, 0), U32(a, 0))
    dl:AddRectFilledMultiColor(V2(xm, y1), V2(x1, y1 + 30), U32(a, 0.10), U32(a, 0), U32(a, 0), U32(a, 0.10))

    local lx, ly = wp.x + M, wp.y + 14
    local cx, cy = lx + 17, ly + 17
    dl:AddRectFilled(V2(lx, ly), V2(lx + 34, ly + 34), U32(a), 10)
    dl:AddRectFilled(V2(cx - 8, cy - 2.5), V2(cx + 8, cy + 2.5), U32(COL.text), 1.5)
    dl:AddRectFilled(V2(cx - 2.5, cy - 8), V2(cx + 2.5, cy + 8), U32(COL.text), 1.5)

    pf(fonts.title)
    dl:AddText(V2(lx + 46, ly - 4), U32(COL.text), 'MED PANEL')
    pp(fonts.title)
    pf(fonts.small)
    dl:AddText(V2(lx + 47, ly + 21), U32(COL.dim), u8('Быстрые действия'))
    pp(fonts.small)

    local rightEdge = wp.x + W - M
    local kin  = math.min(1.0, (TOAST_TIME - toast.t) * 7.0)
    local kout = math.min(1.0, toast.t / 0.3)
    local k = (toast.t > 0) and math.min(kin, kout) or 0

    if k < 0.99 then
        pf(fonts.small)
        local lbl = u8('закрыть')
        local ls = imgui.CalcTextSize(lbl)
        pp(fonts.small)
        pf(fonts.boldSmall)
        local ks = imgui.CalcTextSize('ESC')
        pp(fonts.boldSmall)

        local kw = ks.x + 14
        local hx = rightEdge - (kw + 8 + ls.x)
        local al = 1 - k
        dl:AddRectFilled(V2(hx, cy - 11), V2(hx + kw, cy + 11), U32(COL.keycap, al), 6)
        pf(fonts.boldSmall)
        dl:AddText(V2(hx + 7, cy - ks.y / 2), U32(COL.text, al), 'ESC')
        pp(fonts.boldSmall)
        pf(fonts.small)
        dl:AddText(V2(hx + kw + 8, cy - ls.y / 2), U32(COL.dim, al), lbl)
        pp(fonts.small)
    end

    if k > 0.01 then
        local col = (toast.kind == 'ok' and COL.green)
            or (toast.kind == 'warn' and COL.orange) or COL.accentHi
        pf(fonts.small)
        local tsz = imgui.CalcTextSize(toast.text)
        local pw, ph = tsz.x + 38, 28
        local px = rightEdge - pw + (1 - k) * 12
        local py = cy - ph / 2
        dl:AddRectFilled(V2(px, py), V2(px + pw, py + ph), U32(col, 0.14 * k), 14)
        dl:AddRect(V2(px, py), V2(px + pw, py + ph), U32(col, 0.55 * k), 14)
        dl:AddCircleFilled(V2(px + 15, cy), 3.5, U32(col, k), 12)
        dl:AddText(V2(px + 26, cy - tsz.y / 2), U32(COL.text, k), toast.text)
        pp(fonts.small)
    end

    dl:AddLine(V2(wp.x + M, wp.y + 60), V2(wp.x + W - M, wp.y + 60), U32({ 1, 1, 1, 0.07 }), 1)
end

local function drawNearButton(x, y, w, h)
    imgui.SetCursorPos(V2(x, y))
    local pressed = imgui.InvisibleButton('##near_btn', V2(w, h))
    local hv = animTo('near', imgui.IsItemHovered() and 1 or 0)
    local mn, mx = imgui.GetItemRectMin(), imgui.GetItemRectMax()
    local dl = imgui.GetWindowDrawList()
    local a = COL.accent

    dl:AddRectFilled(mn, mx, U32({ a[1], a[2], a[3], lerp(0.14, 0.34, hv) }), 10)
    dl:AddRect(mn, mx, U32({ a[1], a[2], a[3], lerp(0.40, 0.90, hv) }), 10)

    pf(fonts.boldSmall)
    local label = u8('Рядом')
    local ts = imgui.CalcTextSize(label)
    local groupW = 12 + 8 + ts.x
    local sx = mn.x + (w - groupW) / 2
    local cy = (mn.y + mx.y) / 2
    dl:AddCircle(V2(sx + 6, cy), 5.2, U32(COL.accentHi), 16, 1.5)
    dl:AddCircleFilled(V2(sx + 6, cy), 1.7, U32(COL.accentHi), 8)
    dl:AddText(V2(sx + 20, cy - ts.y / 2), U32(COL.accentHi), label)
    pp(fonts.boldSmall)
    return pressed
end

local function drawClearButton(x, y, size)
    imgui.SetCursorPos(V2(x, y))
    local pressed = imgui.InvisibleButton('##clear_btn', V2(size, size))
    local hv = animTo('clear', imgui.IsItemHovered() and 1 or 0)
    local mn, mx = imgui.GetItemRectMin(), imgui.GetItemRectMax()
    local dl = imgui.GetWindowDrawList()

    dl:AddRectFilled(mn, mx, U32(mix(COL.field, { COL.red[1], COL.red[2], COL.red[3], 0.20 }, hv)), 10)
    dl:AddRect(mn, mx, U32(mix(COL.outline, COL.red, hv)), 10)
    local cx, cy = (mn.x + mx.x) / 2, (mn.y + mx.y) / 2
    local lc = mix(COL.dim, COL.red, hv)
    dl:AddLine(V2(cx - 5, cy - 5), V2(cx + 5, cy + 5), U32(lc), 1.8)
    dl:AddLine(V2(cx + 5, cy - 5), V2(cx - 5, cy + 5), U32(lc), 1.8)
    return pressed
end

local function drawActionCard(i, act, x, y, w, h, ready)
    imgui.SetCursorPos(V2(x, y))
    imgui.PushIDInt(i)
    local pressed = imgui.InvisibleButton('##card', V2(w, h))
    imgui.PopID()

    local hov  = imgui.IsItemHovered()
    local held = imgui.IsItemActive()
    local hv   = animTo('card' .. i, hov and 1 or 0, 14)
    local mn, mx = imgui.GetItemRectMin(), imgui.GetItemRectMax()
    local dl = imgui.GetWindowDrawList()
    local a = COL.accent
    local cy = (mn.y + mx.y) / 2

    dl:AddRectFilled(mn, mx, U32(mix({ 1, 1, 1, 0.035 }, { a[1], a[2], a[3], 0.17 }, hv)), 11)
    dl:AddRect(mn, mx, U32(mix({ 1, 1, 1, 0.07 }, { a[1], a[2], a[3], 0.55 }, hv)), 11)
    if held then dl:AddRectFilled(mn, mx, U32({ 1, 1, 1, 0.04 }), 11) end
    if hv > 0.01 then
        local bh = 22 * hv
        dl:AddRectFilled(V2(mn.x - 1, cy - bh / 2), V2(mn.x + 2, cy + bh / 2), U32(COL.accentHi, hv), 2)
    end

    local bx = mn.x + 28
    dl:AddCircleFilled(V2(bx, cy), 15, U32(mix(COL.badge, COL.accent, hv)), 28)
    pf(fonts.bold)
    local num = tostring(i)
    local ns = imgui.CalcTextSize(num)
    dl:AddText(V2(bx - ns.x / 2, cy - ns.y / 2), U32(COL.text), num)

    local title = u8(act.name)
    local tsz = imgui.CalcTextSize(title)
    local tcol = mix(ready and COL.text or COL.dim, COL.text, hv)
    dl:AddText(V2(mn.x + 54, cy - tsz.y / 2), U32(tcol), title)
    pp(fonts.bold)

    pf(fonts.boldSmall)
    local cs = imgui.CalcTextSize(act.cmd)
    local pw, ph = cs.x + 22, 24
    local px, py = mx.x - 14 - pw, cy - ph / 2
    dl:AddRectFilled(V2(px, py), V2(px + pw, py + ph),
        U32({ a[1], a[2], a[3], lerp(0.14, 0.34, hv) }), 12)
    dl:AddText(V2(px + 11, cy - cs.y / 2), U32(COL.accentHi), act.cmd)
    pp(fonts.boldSmall)

    return pressed
end

local function drawStatus(dl, x, y, idStr)
    local col, text
    if #idStr == 0 then
        col, text = COL.faint, u8('Введи ID или нажми "Рядом"')
    else
        local id = parseId(idStr)
        if not id then
            col, text = COL.red, u8('Некорректный ID (только цифры, до ' .. MAX_ID .. ')')
        else
            local myId = getMyId()
            if id == myId or sampIsPlayerConnected(id) then
                col = COL.green
                text = 'Цель: ' .. rpNick(id) .. ' [' .. id .. ']'
                if id == myId then text = text .. ' (это вы)' end
                text = u8(text)
            else
                col, text = COL.orange, u8('Игрок [' .. id .. '] не в сети')
            end
        end
    end
    dl:AddCircleFilled(V2(x + 4, y + 8), 3.5, U32(col), 12)
    pf(fonts.small)
    dl:AddText(V2(x + 16, y), U32(col), text)
    pp(fonts.small)
end

imgui.OnFrame(
    function() return panelAlpha > 0.01 end,
    function(self)
        self.HideCursor = not isUnlocked
        self.LockPlayer = isUnlocked

        local dt = imgui.GetIO().DeltaTime
        if dt <= 0 or dt > 0.1 then dt = 0.016 end
        frameDt = dt
        panelAlpha = smoothStep(panelAlpha, isUnlocked and 1.0 or 0.0, 14.0, dt)
        toast.t = math.max(0, toast.t - dt)
        if panelAlpha <= 0.01 and not isUnlocked then return end

        local e = panelAlpha * panelAlpha * (3 - 2 * panelAlpha)
        local sw, sh = getScreenResolution()

        local baseX, slide
        if PANEL_SIDE == 'left' then
            baseX = PANEL_MARGIN_X
            slide = -(1 - e) * 28
        else
            baseX = sw - W - PANEL_MARGIN_X
            slide = (1 - e) * 28
        end
        imgui.SetNextWindowPos(V2(baseX + slide, sh / 2), imgui.Cond.Always, V2(0, 0.5))
        imgui.SetNextWindowSize(V2(W, H), imgui.Cond.Always)
        if isUnlocked and focusFrames > 0 then imgui.SetNextWindowFocus() end

        local flags = bit.bor(
            imgui.WindowFlags.NoTitleBar, imgui.WindowFlags.NoCollapse,
            imgui.WindowFlags.NoResize, imgui.WindowFlags.NoMove,
            imgui.WindowFlags.NoScrollbar, imgui.WindowFlags.NoScrollWithMouse,
            imgui.WindowFlags.NoSavedSettings)
        if not isUnlocked then
            flags = bit.bor(flags, imgui.WindowFlags.NoInputs, imgui.WindowFlags.NoMouseInputs)
        end

        imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, panelAlpha)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V2(0, 0))
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 1.0)
        imgui.Begin('##arz_medpanel', nil, flags)
        imgui.PopStyleVar(2)
        pf(fonts.main)

        local wp = imgui.GetWindowPos()
        local dl = imgui.GetWindowDrawList()
        drawHeader(dl, wp)

        pf(fonts.small)
        dl:AddText(V2(wp.x + M + 2, wp.y + 72), U32(COL.faint), u8('ЦЕЛЬ'))
        pp(fonts.small)

        local IH = 36
        local y0 = 94
        local nearW = 84
        local inputW = (W - M * 2) - nearW - IH - 16

        imgui.SetCursorPos(V2(M, y0))
        local pad = math.max(4, (IH - imgui.GetFontSize()) / 2)
        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, V2(14, pad))
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 10)
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameBorderSize, 1.0)
        imgui.PushStyleColor(imgui.Col.Border, C(COL.outline))
        imgui.PushItemWidth(inputW)

        if isUnlocked and focusFrames > 0 then imgui.SetKeyboardFocusHere() end
        imgui.InputTextWithHint('##target_id', u8('ID игрока'), idBuf, ffi.sizeof(idBuf),
            imgui.InputTextFlags.CharsDecimal)
        local active = imgui.IsItemActive()
        local fmn, fmx = imgui.GetItemRectMin(), imgui.GetItemRectMax()

        imgui.PopItemWidth()
        imgui.PopStyleColor()
        imgui.PopStyleVar(3)

        if active then focusFrames = 0
        elseif focusFrames > 0 then focusFrames = focusFrames - 1 end

        local fa = animTo('focus', active and 1 or 0, 16)
        if fa > 0.01 then
            dl:AddRect(V2(fmn.x - 1, fmn.y - 1), V2(fmx.x + 1, fmx.y + 1), U32(COL.accent, 0.25 * fa), 11)
            dl:AddRect(fmn, fmx, U32(COL.accent, 0.95 * fa), 10)
        end

        if drawNearButton(M + inputW + 8, y0, nearW, IH) then
            local nid = findNearestPlayer(NEAR_RADIUS)
            if nid then
                ffi.copy(idBuf, tostring(nid))
                showToast('Ближайший: ID ' .. nid, 'ok')
            else
                showToast('Рядом никого нет (10 м)', 'warn')
            end
        end
        if drawClearButton(M + inputW + 8 + nearW + 8, y0, IH) then
            ffi.copy(idBuf, '')
            focusFrames = 20
        end

        local idStr = ffi.string(idBuf)
        drawStatus(dl, wp.x + M + 2, wp.y + y0 + IH + 10, idStr)

        local ready = parseId(idStr) ~= nil
        local cardW = W - M * 2
        local cy0 = 168
        for i, act in ipairs(ACTIONS) do
            local y = cy0 + (i - 1) * (CARD_H + CARD_GAP)
            if drawActionCard(i, act, M, y, cardW, CARD_H, ready) then
                onAction(i, act)
            end
        end

        imgui.SetCursorPos(V2(0, H - 2))
        imgui.Dummy(V2(1, 1))

        pp(fonts.main)
        imgui.End()
        imgui.PopStyleVar()
    end
)

addEventHandler('onWindowMessage', function(msg, wparam, lparam)
    if isUnlocked and (msg == 0x100 or msg == 0x101) and wparam == vkeys.VK_ESCAPE then
        if msg == 0x100 then lockPanel() end
        consumeWindowMessage(true, false)
    end
end)

if hasSampEvents then
    function sampev.onServerMessage(color, text)
        if lastSent and (os.clock() - lastSent.t) < 3.0
            and text and text:find('еизвестная команда', 1, true) then
            local ls = lastSent
            lastSent = nil
            if ls.mi < #MODES then
                retryReq = { full = ls.full, idx = ls.idx, mi = ls.mi + 1, from = ls.mi }
            else
                chatMsg(u8('{FF6666}[MedPanel] {FFFFFF}Ни один способ отправки не помог для {FFD166}'
                    .. ls.cmd .. '{FFFFFF}. Проверь название: {6C7BFF}/medcmd ' .. ls.idx .. ' <команда>'))
            end
        end
    end
end

function main()
    while not isSampAvailable() do wait(100) end

    sampRegisterChatCommand('medpanel', togglePanel)
    sampRegisterChatCommand('medcmd', cmdMedcmd)
    sampRegisterChatCommand('medmode', cmdMedmode)
    chatMsg(u8('{6C7BFF}[ArzMedPanel] {FFFFFF}Загружен. Открыть панель: {6C7BFF}F3{FFFFFF} или {6C7BFF}/medpanel{FFFFFF}. Режим отправки: {6C7BFF}/medmode'))

    while true do
        wait(0)

        local blocked = sampIsChatInputActive() or sampIsDialogActive() or isSampfuncsConsoleActive()
        if not blocked then
            if isKeyJustPressed(vkeys.VK_F3) then
                togglePanel()
            end
            if isUnlocked and isKeyJustPressed(vkeys.VK_ESCAPE) then
                lockPanel()
            end
        end

        if pendingCmd then
            local full, idx = pendingCmd, pendingIdx
            pendingCmd, pendingIdx = nil, nil
            doSend(full, idx, sendModeIdx)
        end

        if retryReq then
            local r = retryReq
            retryReq = nil
            chatMsg(u8('{6C7BFF}[MedPanel] {FFFFFF}Режим {FFD166}' .. MODES[r.from]
                .. '{FFFFFF} не сработал, пробую {FFD166}' .. MODES[r.mi]))
            wait(300)
            doSend(r.full, r.idx, r.mi)
        end

        if lastSent and lastSent.mi ~= sendModeIdx and (os.clock() - lastSent.t) > 3.2 then
            sendModeIdx = lastSent.mi
            lastSent = nil
            saveConfig()
            chatMsg(u8('{6C7BFF}[MedPanel] {FFFFFF}Рабочий режим сохранён: {FFD166}'
                .. sendModeIdx .. ' - ' .. MODE_DESC[sendModeIdx]))
        end
    end
end
