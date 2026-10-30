-- ═══════════════════════════════════════════════════════════════════════════
--  JIRNYAK V6  •  ALUSIVE EDITION  •  Blade Ball Auto-Parry & More
--  Стиль: glassmorphism, фиолетово-синие градиенты, плавные анимации
--  Инжекторы: Delta (Android), PC (getgenv, CoreGui, TweenService)
-- ═══════════════════════════════════════════════════════════════════════════

local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local Workspace    = game:GetService("Workspace")
local Stats        = game:GetService("Stats")
local UIS          = game:GetService("UserInputService")
local CoreGui      = game:GetService("CoreGui")
local TweenService = game:GetService("TweenService")
local HttpService  = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LP           = Players.LocalPlayer

local _G = getgenv and getgenv() or _G
if _G.JIRNYAK_V6 and _G.JIRNYAK_V6.running then
    pcall(function() _G.JIRNYAK_V6.destroy() end)
end

task.wait(math.random(20, 60) / 100)

-- ── ЛОГ ──
local LOG = {}
local function log(lvl, msg)
    local line = string.format("[%s] %s", lvl, tostring(msg))
    table.insert(LOG, line)
    if #LOG > 300 then table.remove(LOG, 1) end
    pcall(function() print("[JIRNYAK-ALUSIVE] " .. line) end)
end
local function safe(fn, tag)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log("ERR", (tag or "?") .. ": " .. tostring(err)) end
        return ok
    end
end

-- ── КОНФИГ ──
local DEFAULT = {
    AutoParry = true, AutoRadius = true, OnlyIncoming = true,
    AutoSwing = false, AutoSpam = false, ESPBall = false,
    ForceTool = true,
    Cooldown = 0.10, MinRadius = 7, MaxRadius = 30,
    SafetyFactor = 1.4, SmoothAlpha = 0.25,
    BallSpeed = 120, SampleHz = 2,
    ParryLeadTime = 0.02,
    MenuKey = Enum.KeyCode.RightShift,
    ParryKey = Enum.KeyCode.Q,
    SwingKey = Enum.KeyCode.E,
}
local C = {}
for k, v in pairs(DEFAULT) do C[k] = v end

local CONFIG_FILE = "jirnyak_alusive_config.json"
local function serialize()
    local t = {}
    for k, v in pairs(C) do
        if typeof(v) == "EnumItem" then t[k] = {__e=true, name=v.Name, ty=tostring(v.EnumType)}
        else t[k] = v end
    end
    return HttpService:JSONEncode(t)
end
local function deserialize(str)
    local ok, t = pcall(function() return HttpService:JSONDecode(str) end)
    if not ok or type(t) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(t) do
        if type(v) == "table" and v.__e and Enum[v.ty] and Enum[v.ty][v.name] then
            out[k] = Enum[v.ty][v.name]
        elseif DEFAULT[k] ~= nil and type(v) == type(DEFAULT[k]) then
            out[k] = v
        end
    end
    return out
end
pcall(function()
    if isfile and readfile and isfile(CONFIG_FILE) then
        local s = deserialize(readfile(CONFIG_FILE))
        if s then for k, v in pairs(s) do if DEFAULT[k] ~= nil then C[k] = v end end end
    end
end)
local function saveConfig()
    pcall(function() if writefile then writefile(CONFIG_FILE, serialize()) end end)
end

-- ── СОСТОЯНИЕ ──
local S = {
    lastParry = 0, radius = C.MinRadius, ping = 80,
    pingHistory = {}, parryCount = 0, attempts = 0,
    remote = nil, remoteList = {}, tool = nil,
    menuOpen = true, waitBind = nil, lastRemoteCheck = 0,
    dragging = false, dragStart = nil, startPos = nil,
    focusSlider = nil, destroyed = false, running = true,
    version = "6.2-ALUSIVE", lastScan = 0,
    lastFireOk = 0,
}
_G.JIRNYAK_V6 = S

-- ═══════════════════════════════════════════════════════════════════════════
--  СКАНЕР РЕМОУТОВ
-- ═══════════════════════════════════════════════════════════════════════════
local NAME_HINTS = {
    ["parry"]=10, ["block"]=9, ["swing"]=6, ["hit"]=4, ["attack"]=3,
    ["deflect"]=9, ["clash"]=8, ["strike"]=4, ["slash"]=4,
    ["remoteparry"]=11, ["parryremote"]=11, ["blockevent"]=9, ["swingevent"]=7,
    ["combat"]=5, ["action"]=3, ["input"]=3,
}

local function scoreRemote(name)
    local ln = string.lower(name)
    local best = 0
    for hint, sc in pairs(NAME_HINTS) do
        if ln:find(hint, 1, true) then best = math.max(best, sc) end
    end
    return best
end

local function scanRemotes()
    local found = {}
    local roots = {ReplicatedStorage, LP, LP:FindFirstChild("PlayerScripts"), LP:FindFirstChild("PlayerGui"), Workspace}
    for _, root in ipairs(roots) do
        if root then
            for _, d in ipairs(root:GetDescendants()) do
                if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
                    local sc = scoreRemote(d.Name)
                    table.insert(found, {obj=d, score=sc, path=d:GetFullName(), cls=d.ClassName})
                end
            end
        end
    end
    table.sort(found, function(a,b) return a.score > b.score end)
    S.remoteList = found
    log("SCAN", string.format("remotes: %d, top: %s", #found, found[1] and found[1].path or "-"))
    return found
end

local function pickBestRemote()
    scanRemotes()
    for _, r in ipairs(S.remoteList) do
        if r.score >= 6 and r.obj:IsA("RemoteEvent") then return r.obj end
    end
    return nil
end

local function findTool()
    local char = LP.Character
    if not char then return nil end
    for _, t in ipairs(char:GetChildren()) do
        if t:IsA("Tool") then return t end
    end
    local backpack = LP:FindFirstChild("Backpack")
    if backpack then
        for _, t in ipairs(backpack:GetChildren()) do
            if t:IsA("Tool") then return t end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  МЯЧ И ПИНГ
-- ═══════════════════════════════════════════════════════════════════════════
local function getBall()
    local best, bestScore = nil, 0
    for _, o in ipairs(Workspace:GetDescendants()) do
        if o:IsA("BasePart") then
            local n = string.lower(o.Name)
            local sc = 0
            if n == "ball" then sc = 10
            elseif n:find("ball", 1, true) then sc = 7
            elseif n:find("projectile", 1, true) then sc = 5
            elseif n:find("orb", 1, true) then sc = 4 end
            if sc > 0 and o.Parent ~= LP.Character then
                local v = o.AssemblyLinearVelocity.Magnitude
                if v > 5 then sc = sc + 3 end
                if sc > bestScore then bestScore = sc; best = o end
            end
        end
    end
    return best
end

local function readPing()
    local ok, v = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and type(v) == "number" and v > 0 then
        table.insert(S.pingHistory, v)
        if #S.pingHistory > 60 then table.remove(S.pingHistory, 1) end
        return v
    end
    return S.ping
end

local function isIncoming(ball, pos)
    local v = ball.AssemblyLinearVelocity
    if v.Magnitude < 1 then return false end
    local toMe = (pos - ball.Position)
    if toMe.Magnitude < 0.1 then return true end
    return v.Unit:Dot(toMe.Unit) > 0.35
end

-- ═══════════════════════════════════════════════════════════════════════════
--  ПАРИРОВАНИЕ (мультистратегия)
-- ═══════════════════════════════════════════════════════════════════════════
local fireLog = {}
local function fireParry()
    S.attempts = S.attempts + 1
    local success = false

    if S.remote and S.remote.Parent then
        local ok = pcall(function() S.remote:FireServer() end)
        if ok then success = true; S.lastFireOk = tick() end
    end

    if not success then
        for _, r in ipairs(S.remoteList) do
            if r.score >= 6 and r.obj:IsA("RemoteEvent") and r.obj.Parent then
                local ok = pcall(function() r.obj:FireServer() end)
                if ok then success = true; S.lastFireOk = tick(); break end
            end
        end
    end

    if C.ForceTool and not success then
        local tool = findTool()
        if tool then
            pcall(function()
                if tool.Parent ~= LP.Character then tool.Parent = LP.Character end
                tool:Activate()
            end)
            success = true
        end
    end

    if not success then
        pcall(function()
            local vim = game:GetService("VirtualInputManager")
            vim:SendMouseButtonEvent(0,0,0,true,game,0)
            task.wait(0.005)
            vim:SendMouseButtonEvent(0,0,0,false,game,0)
        end)
    end

    table.insert(fireLog, string.format("%.2f %s", tick()%1000, success and "OK" or "FAIL"))
    if #fireLog > 30 then table.remove(fireLog, 1) end
    return success
end

local function parry()
    local now = tick()
    if now - S.lastParry < C.Cooldown then return end
    S.lastParry = now
    if fireParry() then S.parryCount = S.parryCount + 1 end
end

local function ensureRemote()
    if S.remote and S.remote.Parent then return end
    local now = tick()
    if now - S.lastRemoteCheck < 2 then return end
    S.lastRemoteCheck = now
    S.remote = pickBestRemote()
    if S.remote then log("INFO", "remote: " .. S.remote:GetFullName()) end
end

S.remote = pickBestRemote()

LP.CharacterAdded:Connect(safe(function()
    S.lastParry = 0; S.radius = C.MinRadius; S.remote = pickBestRemote()
end, "CharAdded"))

-- ═══════════════════════════════════════════════════════════════════════════
--  ОСНОВНОЙ ЦИКЛ
-- ═══════════════════════════════════════════════════════════════════════════
local sampleAcc = 0
RunService.Heartbeat:Connect(safe(function(dt)
    if S.destroyed then return end
    ensureRemote()

    if C.AutoRadius then
        sampleAcc = sampleAcc + dt
        if sampleAcc >= 1 / C.SampleHz then
            sampleAcc = 0
            S.ping = readPing()
            local b = getBall()
            local spd = b and b.AssemblyLinearVelocity.Magnitude or C.BallSpeed
            if spd < 20 then spd = C.BallSpeed end
            local reach = spd * (S.ping / 1000) * 0.5 * C.SafetyFactor
            local target = math.clamp(reach + 4, C.MinRadius, C.MaxRadius)
            S.radius = S.radius + (target - S.radius) * C.SmoothAlpha
        end
    else
        S.radius = C.MinRadius
    end

    local char = LP.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local myPos = hrp.Position

    if C.AutoParry then
        local b = getBall()
        if b then
            local v = b.AssemblyLinearVelocity
            local pingSec = S.ping / 1000
            local predicted = b.Position + v * (pingSec + C.ParryLeadTime)
            local dist = (predicted - myPos).Magnitude

            if dist <= S.radius then
                if not C.OnlyIncoming or isIncoming(b, myPos) then parry() end
            end
        end
    end

    if C.AutoSwing then
        local b = getBall()
        if b and (b.Position - myPos).Magnitude <= 12 then fireParry() end
    end
end, "Heartbeat"))

task.spawn(safe(function()
    while not S.destroyed do
        task.wait(0.05)
        if C.AutoSpam then fireParry() end
    end
end, "SpamLoop"))

-- ═══════════════════════════════════════════════════════════════════════════
--  ALUSIVE UI (glassmorphism + градиенты)
-- ═══════════════════════════════════════════════════════════════════════════
local theme = {
    bg      = Color3.fromRGB(12, 12, 16),
    panel   = Color3.fromRGB(22, 22, 30),
    panel2  = Color3.fromRGB(30, 30, 40),
    sidebar = Color3.fromRGB(16, 16, 22),
    accent  = Color3.fromRGB(150, 100, 255),   -- фиолетовый
    accent2 = Color3.fromRGB(80, 200, 255),    -- голубой
    text    = Color3.fromRGB(240, 240, 250),
    sub     = Color3.fromRGB(150, 150, 170),
    off     = Color3.fromRGB(60, 60, 75),
    good    = Color3.fromRGB(100, 220, 150),
    bad     = Color3.fromRGB(240, 100, 100),
    stroke  = Color3.fromRGB(55, 55, 70),
    glass   = Color3.fromRGB(28, 28, 38),
}

if S.gui and S.gui.Parent then pcall(function() S.gui:Destroy() end) end
local gui = Instance.new("ScreenGui")
gui.Name = "AlusiveOverlay_" .. tostring(math.random(1000,9999))
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 999
pcall(function() gui.Parent = CoreGui end)
if not gui.Parent then
    local ok = pcall(function() gui.Parent = LP:WaitForChild("PlayerGui", 3) end)
    if not ok then log("ERR", "no gui parent"); return end
end
S.gui = gui

-- утилиты UI
local function corner(p,r) local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,r or 10); c.Parent=p; return c end
local function stroke(p,col,th,tr) local s=Instance.new("UIStroke"); s.Color=col or theme.stroke; s.Thickness=th or 1; s.Transparency=tr or 0.4; s.Parent=p; return s end
local function pad(p,v) local u=Instance.new("UIPadding"); u.PaddingTop=UDim.new(0,v); u.PaddingBottom=UDim.new(0,v); u.PaddingLeft=UDim.new(0,v); u.PaddingRight=UDim.new(0,v); u.Parent=p; return u end
local function tween(obj,props,dur,style,dir)
    local ti=TweenInfo.new(dur or 0.22, style or Enum.EasingStyle.Quart, dir or Enum.EasingDirection.Out)
    local t=TweenService:Create(obj,ti,props); t:Play(); return t
end
local function grad(p,c1,c2,rot) local g=Instance.new("UIGradient"); g.Color=ColorSequence.new(c1,c2); g.Rotation=rot or 0; g.Parent=p; return g end

-- главное окно
local W, H = 620, 460
local root = Instance.new("Frame")
root.Size = UDim2.new(0,0,0,0)
root.Position = UDim2.new(0.5,-W/2,0.5,-H/2)
root.BackgroundColor3 = theme.bg
root.BackgroundTransparency = 0.03
root.BorderSizePixel = 0
root.ClipsDescendants = true
root.Parent = gui
corner(root, 16)
stroke(root, theme.accent, 1, 0.5)
tween(root, {Size=UDim2.new(0,W,0,H)}, 0.35, Enum.EasingStyle.Back)

-- верхний градиентный блик
local topGlow = Instance.new("Frame")
topGlow.Size = UDim2.new(1,0,0,3)
topGlow.BackgroundColor3 = Color3.new(1,1,1)
topGlow.BorderSizePixel = 0
topGlow.Parent = root
grad(topGlow, theme.accent, theme.accent2, 0)

-- шапка
local header = Instance.new("Frame")
header.Size = UDim2.new(1,0,0,52)
header.BackgroundTransparency = 1
header.Parent = root

local logoDot = Instance.new("Frame")
logoDot.Size = UDim2.new(0,10,0,10)
logoDot.Position = UDim2.new(0,20,0.5,-5)
logoDot.BackgroundColor3 = theme.accent
logoDot.BorderSizePixel = 0
logoDot.Parent = header
corner(logoDot, 5)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1,-220,1,0)
title.Position = UDim2.new(0,38,0,0)
title.BackgroundTransparency = 1
title.Text = "JIRNYAK"
title.TextColor3 = theme.text
title.TextSize = 18
title.Font = Enum.Font.GothamBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local sub = Instance.new("TextLabel")
sub.Size = UDim2.new(0,120,1,0)
sub.Position = UDim2.new(1,-130,0,0)
sub.BackgroundTransparency = 1
sub.Text = "ALUSIVE"
sub.TextColor3 = theme.accent2
sub.TextSize = 11
sub.Font = Enum.Font.GothamBold
sub.TextXAlignment = Enum.TextXAlignment.Right
sub.Parent = header

local status = Instance.new("TextLabel")
status.Size = UDim2.new(0,180,1,0)
status.Position = UDim2.new(1,-320,0,0)
status.BackgroundTransparency = 1
status.Text = "ready"
status.TextColor3 = theme.good
status.TextSize = 12
status.Font = Enum.Font.Gotham
status.TextXAlignment = Enum.TextXAlignment.Right
status.Parent = header

local headerLine = Instance.new("Frame")
headerLine.Size = UDim2.new(1,0,0,1)
headerLine.Position = UDim2.new(0,0,0,51)
headerLine.BackgroundColor3 = theme.stroke
headerLine.BackgroundTransparency = 0.6
headerLine.BorderSizePixel = 0
headerLine.Parent = root

-- сайдбар
local sideW = 160
local side = Instance.new("Frame")
side.Size = UDim2.new(0,sideW,1,-52)
side.Position = UDim2.new(0,0,0,52)
side.BackgroundColor3 = theme.sidebar
side.BackgroundTransparency = 0.05
side.BorderSizePixel = 0
side.Parent = root
corner(side, 12)
pad(side, 8)
local sideLayout = Instance.new("UIListLayout")
sideLayout.Padding = UDim.new(0,4)
sideLayout.SortOrder = Enum.SortOrder.LayoutOrder
sideLayout.Parent = side

-- контент
local content = Instance.new("Frame")
content.Size = UDim2.new(1,-sideW-16,1,-64)
content.Position = UDim2.new(0,sideW+8,0,60)
content.BackgroundTransparency = 1
content.Parent = root

local pages, pageButtons = {}, {}
local currentPage = "Combat"

local function showPage(name)
    for n,p in pairs(pages) do
        if n == name then
            p.Visible = true
            p.Position = UDim2.new(0,12,0,0)
            tween(p, {Position=UDim2.new(0,0,0,0)}, 0.22)
        else p.Visible = false end
    end
    currentPage = name
end

local function makePage(name)
    local p = Instance.new("ScrollingFrame")
    p.Size = UDim2.new(1,0,1,0)
    p.BackgroundTransparency = 1
    p.BorderSizePixel = 0
    p.ScrollBarThickness = 2
    p.ScrollBarImageColor3 = theme.accent
    p.CanvasSize = UDim2.new(0,0,0,0)
    p.AutomaticCanvasSize = Enum.AutomaticSize.Y
    p.Visible = false
    p.Parent = content
    local l = Instance.new("UIListLayout")
    l.Padding = UDim.new(0,8)
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Parent = p
    pages[name] = p
    return p
end

-- уведомления
local function notify(text, kind)
    local box = Instance.new("Frame")
    box.Size = UDim2.new(0,260,0,36)
    box.Position = UDim2.new(1,-275,1,12)
    box.BackgroundColor3 = theme.panel
    box.BorderSizePixel = 0
    box.Parent = root
    corner(box, 10)
    stroke(box, kind=="err" and theme.bad or (kind=="ok" and theme.good or theme.accent), 1, 0.3)
    local t = Instance.new("TextLabel")
    t.Size = UDim2.new(1,-20,1,0)
    t.Position = UDim2.new(0,14,0,0)
    t.BackgroundTransparency = 1
    t.Text = text
    t.TextColor3 = theme.text
    t.TextSize = 12
    t.Font = Enum.Font.Gotham
    t.TextXAlignment = Enum.TextXAlignment.Left
    t.Parent = box
    tween(box, {Position=UDim2.new(1,-275,1,-48)}, 0.25, Enum.EasingStyle.Back)
    task.delay(2.2, safe(function()
        tween(box, {Position=UDim2.new(1,-275,1,12), BackgroundTransparency=1}, 0.25)
        task.wait(0.3); box:Destroy()
    end, "nClose"))
end

-- кнопка сайдбара
local function sideBtn(label, page, order)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1,0,0,36)
    b.BackgroundColor3 = theme.panel2
    b.BackgroundTransparency = 1
    b.BorderSizePixel = 0
    b.Text = "  "..label
    b.TextColor3 = theme.sub
    b.TextSize = 13
    b.Font = Enum.Font.GothamBold
    b.TextXAlignment = Enum.TextXAlignment.Left
    b.AutoButtonColor = false
    b.LayoutOrder = order or 1
    b.Parent = side
    corner(b, 8)
    local ind = Instance.new("Frame")
    ind.Size = UDim2.new(0,3,0,0)
    ind.Position = UDim2.new(0,0,0.5,0)
    ind.BackgroundColor3 = Color3.new(1,1,1)
    ind.BorderSizePixel = 0
    ind.Parent = b
    corner(ind, 2)
    grad(ind, theme.accent, theme.accent2, 90)
    pageButtons[page] = {btn=b, ind=ind}
    b.MouseEnter:Connect(safe(function()
        if currentPage ~= page then
            tween(b, {BackgroundTransparency=0.6}, 0.15); b.TextColor3 = theme.text
        end
    end, "sbE"))
    b.MouseLeave:Connect(safe(function()
        if currentPage ~= page then
            tween(b, {BackgroundTransparency=1}, 0.15); b.TextColor3 = theme.sub
        end
    end, "sbL"))
    b.MouseButton1Click:Connect(safe(function()
        for _,w in pairs(pageButtons) do
            tween(w.btn, {BackgroundTransparency=1}, 0.15)
            w.btn.TextColor3 = theme.sub
            tween(w.ind, {Size=UDim2.new(0,3,0,0)}, 0.15)
        end
        tween(b, {BackgroundTransparency=0.4}, 0.15)
        b.TextColor3 = theme.text
        tween(ind, {Size=UDim2.new(0,3,0,22)}, 0.2)
        showPage(page)
    end, "sbC"))
    return b
end

-- секция
local function section(parent, txt, order)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1,0,0,28)
    f.BackgroundTransparency = 1
    f.LayoutOrder = order or 1
    f.Parent = parent
    local t = Instance.new("TextLabel")
    t.Size = UDim2.new(1,0,1,0)
    t.BackgroundTransparency = 1
    t.Text = txt
    t.TextColor3 = theme.accent
    t.TextSize = 12
    t.Font = Enum.Font.GothamBold
    t.TextXAlignment = Enum.TextXAlignment.Left
    t.Parent = f
    local ln = Instance.new("Frame")
    ln.Size = UDim2.new(1,0,0,1)
    ln.Position = UDim2.new(0,0,1,-1)
    ln.BackgroundColor3 = theme.stroke
    ln.BackgroundTransparency = 0.5
    ln.BorderSizePixel = 0
    ln.Parent = f
end

-- тумблер
local function toggleRow(parent, labelTxt, key, order)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1,0,0,38)
    row.BackgroundColor3 = theme.panel
    row.BackgroundTransparency = 0.2
    row.BorderSizePixel = 0
    row.LayoutOrder = order or 1
    row.Parent = parent
    corner(row, 10)
    stroke(row, theme.stroke, 1, 0.7)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1,-80,1,0)
    lbl.Position = UDim2.new(0,14,0,0)
    lbl.BackgroundTransparency = 1
    lbl.Text = labelTxt
    lbl.TextColor3 = theme.text
    lbl.TextSize = 13
    lbl.Font = Enum.Font.Gotham
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row
    local pill = Instance.new("Frame")
    pill.Size = UDim2.new(0,46,0,24)
    pill.Position = UDim2.new(1,-60,0.5,-12)
    pill.BackgroundColor3 = C[key] and theme.accent or theme.off
    pill.BorderSizePixel = 0
    pill.Parent = row
    corner(pill, 12)
    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0,18,0,18)
    knob.Position = C[key] and UDim2.new(1,-21,0.5,-9) or UDim2.new(0,3,0.5,-9)
    knob.BackgroundColor3 = theme.text
    knob.BorderSizePixel = 0
    knob.Parent = pill
    corner(knob, 9)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1,0,1,0)
    btn.BackgroundTransparency = 1
    btn.Text = ""
    btn.Parent = row
    btn.MouseButton1Click:Connect(safe(function()
        C[key] = not C[key]
        tween(pill, {BackgroundColor3=C[key] and theme.accent or theme.off}, 0.2)
        tween(knob, {Position=C[key] and UDim2.new(1,-21,0.5,-9) or UDim2.new(0,3,0.5,-9)}, 0.2, Enum.EasingStyle.Back)
        saveConfig()
    end, "tgC"))
end

-- слайдер
local function sliderRow(parent, labelTxt, key, mn, mx, st, order)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1,0,0,56)
    row.BackgroundColor3 = theme.panel
    row.BackgroundTransparency = 0.2
    row.BorderSizePixel = 0
    row.LayoutOrder = order or 1
    row.Parent = parent
    corner(row, 10)
    stroke(row, theme.stroke, 1, 0.7)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1,-80,0,22)
    lbl.Position = UDim2.new(0,14,0,6)
    lbl.BackgroundTransparency = 1
    lbl.Text = labelTxt
    lbl.TextColor3 = theme.text
    lbl.TextSize = 13
    lbl.Font = Enum.Font.Gotham
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row
    local val = Instance.new("TextLabel")
    val.Size = UDim2.new(0,60,0,22)
    val.Position = UDim2.new(1,-74,0,6)
    val.BackgroundTransparency = 1
    val.Text = tostring(C[key])
    val.TextColor3 = theme.accent2
    val.TextSize = 13
    val.Font = Enum.Font.GothamBold
    val.TextXAlignment = Enum.TextXAlignment.Right
    val.Parent = row
    local track = Instance.new("Frame")
    track.Size = UDim2.new(1,-28,0,6)
    track.Position = UDim2.new(0,14,0,36)
    track.BackgroundColor3 = theme.off
    track.BorderSizePixel = 0
    track.Parent = row
    corner(track, 3)
    local fill = Instance.new("Frame")
    fill.Size = UDim2.new((C[key]-mn)/(mx-mn),0,1,0)
    fill.BackgroundColor3 = Color3.new(1,1,1)
    fill.BorderSizePixel = 0
    fill.Parent = track
    corner(fill, 3)
    grad(fill, theme.accent, theme.accent2, 0)
    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0,14,0,14)
    knob.Position = UDim2.new((C[key]-mn)/(mx-mn),-7,0.5,-7)
    knob.BackgroundColor3 = theme.text
    knob.BorderSizePixel = 0
    knob.Parent = track
    corner(knob, 7)
    local function setVal(x)
        local rel = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X,1), 0, 1)
        local vv = mn + (mx-mn)*rel
        vv = math.floor(vv/st+0.5)*st
        C[key] = vv
        fill.Size = UDim2.new((vv-mn)/(mx-mn),0,1,0)
        knob.Position = UDim2.new((vv-mn)/(mx-mn),-7,0.5,-7)
        val.Text = tostring(math.floor(vv*100+0.5)/100)
    end
    track.InputBegan:Connect(safe(function(i)
        if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
            S.focusSlider = {setVal=setVal}; setVal(i.Position.X)
        end
    end, "slD"))
    UIS.InputChanged:Connect(safe(function(i)
        if S.focusSlider and (i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseMovement) then
            S.focusSlider.setVal(i.Position.X)
        end
    end, "slM"))
    UIS.InputEnded:Connect(safe(function(i)
        if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
            S.focusSlider = nil; saveConfig()
        end
    end, "slU"))
end

-- биндер
local function binderRow(parent, labelTxt, key, order)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1,0,0,38)
    row.BackgroundColor3 = theme.panel
    row.BackgroundTransparency = 0.2
    row.BorderSizePixel = 0
    row.LayoutOrder = order or 1
    row.Parent = parent
    corner(row, 10)
    stroke(row, theme.stroke, 1, 0.7)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1,-100,1,0)
    lbl.Position = UDim2.new(0,14,0,0)
    lbl.BackgroundTransparency = 1
    lbl.Text = labelTxt
    lbl.TextColor3 = theme.text
    lbl.TextSize = 13
    lbl.Font = Enum.Font.Gotham
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0,80,0,26)
    btn.Position = UDim2.new(1,-94,0.5,-13)
    btn.BackgroundColor3 = theme.panel2
    btn.BorderSizePixel = 0
    btn.Text = C[key].Name
    btn.TextColor3 = theme.accent2
    btn.TextSize = 12
    btn.Font = Enum.Font.GothamBold
    btn.AutoButtonColor = false
    btn.Parent = row
    corner(btn, 7)
    stroke(btn, theme.stroke, 1, 0.5)
    btn.MouseButton1Click:Connect(safe(function()
        S.waitBind = {key=key, btn=btn}
        btn.Text = "..."; btn.TextColor3 = theme.good
    end, "bdC"))
end

-- создаём страницы
local combat = makePage("Combat")
local settings = makePage("Settings")
local binds = makePage("Binds")
local debug = makePage("Debug")

-- Combat
section(combat, "AUTO PARRY", 1)
toggleRow(combat, "Auto Parry", "AutoParry", 2)
toggleRow(combat, "Auto Radius (ping-adaptive)", "AutoRadius", 3)
toggleRow(combat, "Only Incoming", "OnlyIncoming", 4)
toggleRow(combat, "Force Tool / Fallback", "ForceTool", 5)
section(combat, "EXTRAS", 6)
toggleRow(combat, "Auto Swing", "AutoSwing", 7)
toggleRow(combat, "Auto Spam", "AutoSpam", 8)
toggleRow(combat, "ESP Ball", "ESPBall", 9)

-- Settings
section(settings, "RADIUS & TIMING", 1)
sliderRow(settings, "Cooldown", "Cooldown", 0.05, 0.5, 0.01, 2)
sliderRow(settings, "Min Radius", "MinRadius", 5, 25, 1, 3)
sliderRow(settings, "Max Radius", "MaxRadius", 12, 50, 1, 4)
sliderRow(settings, "Safety Factor", "SafetyFactor", 1, 2.5, 0.05, 5)
sliderRow(settings, "Smoothing", "SmoothAlpha", 0.05, 0.9, 0.05, 6)
sliderRow(settings, "Lead Time", "ParryLeadTime", 0, 0.15, 0.005, 7)

-- Binds
section(binds, "KEYBINDS", 1)
binderRow(binds, "Menu", "MenuKey", 2)
binderRow(binds, "Parry", "ParryKey", 3)
binderRow(binds, "Swing", "SwingKey", 4)

-- Debug
section(debug, "DIAGNOSTICS", 1)
local scanBtn = Instance.new("TextButton")
scanBtn.Size = UDim2.new(1,0,0,38)
scanBtn.BackgroundColor3 = theme.accent
scanBtn.BorderSizePixel = 0
scanBtn.Text = "RESCAN REMOTES"
scanBtn.TextColor3 = theme.text
scanBtn.TextSize = 13
scanBtn.Font = Enum.Font.GothamBold
scanBtn.LayoutOrder = 2
scanBtn.Parent = debug
corner(scanBtn, 10)
scanBtn.MouseButton1Click:Connect(safe(function()
    local top = pickBestRemote()
    if top then S.remote = top; notify("Remote: "..top.Name, "ok")
    else notify("Remote not found", "err") end
end, "scanBtn"))

local debugBox = Instance.new("Frame")
debugBox.Size = UDim2.new(1,0,0,260)
debugBox.BackgroundColor3 = theme.panel
debugBox.BackgroundTransparency = 0.1
debugBox.BorderSizePixel = 0
debugBox.LayoutOrder = 3
debugBox.Parent = debug
corner(debugBox, 10)
stroke(debugBox, theme.stroke, 1, 0.7)
local debugLabel = Instance.new("TextLabel")
debugLabel.Size = UDim2.new(1,-20,1,-10)
debugLabel.Position = UDim2.new(0,10,0,5)
debugLabel.BackgroundTransparency = 1
debugLabel.Text = ""
debugLabel.TextColor3 = theme.text
debugLabel.TextSize = 11
debugLabel.Font = Enum.Font.Code
debugLabel.TextXAlignment = Enum.TextXAlignment.Left
debugLabel.TextYAlignment = Enum.TextYAlignment.Top
debugLabel.TextWrapped = true
debugLabel.Parent = debugBox

-- кнопки сайдбара
sideBtn("Combat", "Combat", 1)
sideBtn("Settings", "Settings", 2)
sideBtn("Binds", "Binds", 3)
sideBtn("Debug", "Debug", 4)

showPage("Combat")
do
    local w = pageButtons["Combat"]
    if w then
        w.btn.BackgroundTransparency = 0.4
        w.btn.TextColor3 = theme.text
        w.ind.Size = UDim2.new(0,3,0,22)
    end
end

-- перетаскивание
header.InputBegan:Connect(safe(function(i)
    if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
        S.dragging = true; S.dragStart = i.Position; S.startPos = root.Position
    end
end, "drS"))
UIS.InputChanged:Connect(safe(function(i)
    if S.dragging and (i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseMovement) then
        local d = i.Position - S.dragStart
        local vp = Workspace.CurrentCamera.ViewportSize
        local nx = math.clamp(S.startPos.X.Offset + d.X, -W/2+40, vp.X-W/2-40)
        local ny = math.clamp(S.startPos.Y.Offset + d.Y, -H/2+30, vp.Y-H/2-30)
        root.Position = UDim2.new(S.startPos.X.Scale, nx, S.startPos.Y.Scale, ny)
    end
end, "drM"))
UIS.InputEnded:Connect(safe(function(i)
    if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then
        S.dragging = false
    end
end, "drE"))

-- FAB
local fab = Instance.new("TextButton")
fab.Size = UDim2.new(0,50,0,50)
fab.Position = UDim2.new(0,14,0.5,-25)
fab.BackgroundColor3 = Color3.new(1,1,1)
fab.Text = "≡"
fab.TextColor3 = Color3.new(1,1,1)
fab.TextSize = 24
fab.Font = Enum.Font.GothamBold
fab.BorderSizePixel = 0
fab.Parent = gui
corner(fab, 25)
grad(fab, theme.accent, theme.accent2, 45)
stroke(fab, theme.accent2, 1, 0.3)
fab.MouseButton1Click:Connect(safe(function()
    if root.Visible then
        tween(root, {Size=UDim2.new(0,0,0,0)}, 0.22)
        task.wait(0.24); root.Visible = false
    else
        root.Visible = true
        root.Size = UDim2.new(0,0,0,0)
        tween(root, {Size=UDim2.new(0,W,0,H)}, 0.3, Enum.EasingStyle.Back)
    end
end, "fabC"))

-- клавиши
UIS.InputBegan:Connect(safe(function(i, gp)
    if S.waitBind and not gp and i.KeyCode ~= Enum.KeyCode.Unknown then
        C[S.waitBind.key] = i.KeyCode
        S.waitBind.btn.Text = i.KeyCode.Name
        S.waitBind.btn.TextColor3 = theme.accent2
        S.waitBind = nil
        saveConfig()
        return
    end
    if gp then return end
    if i.KeyCode == C.MenuKey then
        if root.Visible then
            tween(root, {Size=UDim2.new(0,0,0,0)}, 0.22)
            task.wait(0.24); root.Visible = false
        else
            root.Visible = true
            root.Size = UDim2.new(0,0,0,0)
            tween(root, {Size=UDim2.new(0,W,0,H)}, 0.3, Enum.EasingStyle.Back)
        end
        return
    end
    if not root.Visible then return end
    if i.KeyCode == C.ParryKey then parry() end
    if i.KeyCode == C.SwingKey then fireParry() end
end, "keyInput"))

-- обновление статуса и дебага
local statTick = 0
RunService.RenderStepped:Connect(safe(function(dt)
    if S.destroyed then return end
    if root.Visible then
        status.Text = string.format("ping %dms  r%.0f", math.floor(S.ping), S.radius)
        status.TextColor3 = S.ping < 100 and theme.good or (S.ping < 180 and theme.accent2 or theme.bad)
    end
    statTick = statTick + dt
    if statTick > 0.2 then
        statTick = 0
        if currentPage == "Debug" and debugLabel and debugLabel.Parent then
            local lines = {}
            table.insert(lines, "── REMOTES (" .. #S.remoteList .. ") ──")
            for i, r in ipairs(S.remoteList) do
                if i > 8 then break end
                table.insert(lines, string.format("[%d] %s → %s", r.score, r.obj.Name, r.path))
            end
            table.insert(lines, "")
            table.insert(lines, "── STATE ──")
            table.insert(lines, "remote:    " .. (S.remote and S.remote:GetFullName() or "NONE"))
            table.insert(lines, "attempts:  " .. S.attempts)
            table.insert(lines, "parries:   " .. S.parryCount)
            table.insert(lines, "ping:      " .. math.floor(S.ping) .. "ms")
            table.insert(lines, "radius:    " .. string.format("%.1f", S.radius))
            table.insert(lines, "ball:      " .. (getBall() and "found" or "NONE"))
            table.insert(lines, "")
            table.insert(lines, "── FIRE LOG ──")
            for i = math.max(1, #fireLog-5), #fireLog do
                if fireLog[i] then table.insert(lines, fireLog[i]) end
            end
            debugLabel.Text = table.concat(lines, "\n")
        end
    end
end, "renderLoop"))

-- ESP
local espBox = Instance.new("Frame")
espBox.Size = UDim2.new(0,0,0,0)
espBox.BackgroundTransparency = 1
espBox.BorderSizePixel = 0
espBox.Visible = false
espBox.Parent = gui
local espStroke = Instance.new("UIStroke")
espStroke.Color = theme.accent2
espStroke.Thickness = 1.5
espStroke.Parent = espBox
local cam = Workspace.CurrentCamera
RunService.RenderStepped:Connect(safe(function()
    if S.destroyed then return end
    if not C.ESPBall or not root.Visible then espBox.Visible = false return end
    local b = getBall()
    if not b then espBox.Visible = false return end
    local pos, on = cam:WorldToViewportPoint(b.Position)
    if not on then espBox.Visible = false return end
    local sz = math.clamp(2000 / math.max((cam.CFrame.Position - b.Position).Magnitude, 1), 20, 200)
    espBox.Size = UDim2.new(0,sz,0,sz)
    espBox.Position = UDim2.new(0,pos.X-sz/2,0,pos.Y-sz/2)
    espBox.Visible = true
end, "esp"))

-- периодический рескан
task.spawn(safe(function()
    while not S.destroyed do
        task.wait(5)
        if not S.remote or not S.remote.Parent then S.remote = pickBestRemote() end
    end
end, "rescanLoop"))

-- чистка
task.spawn(safe(function()
    while not S.destroyed do
        task.wait(3)
        pcall(function()
            for _, g in ipairs(LP.PlayerGui:GetChildren()) do
                if g.Name:find("Drawing") or g.Name:find("Delta") or g.Name:find("Jirnyak") then
                    g:Destroy()
                end
            end
        end)
    end
end, "cleanup"))

-- destroy
S.destroy = function()
    S.destroyed = true
    S.running = false
    pcall(function() gui:Destroy() end)
    log("INFO", "destroyed")
end

notify("Alusive loaded • " .. C.MenuKey.Name, "ok")
saveConfig()
log("INFO", string.format("started. remote=%s", S.remote and S.remote:GetFullName() or "NOT FOUND"))

pcall(function()
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = "JIRNYAK ALUSIVE",
        Text = "Menu ready. Debug tab → RESCAN",
        Duration = 4,
    })
end)
