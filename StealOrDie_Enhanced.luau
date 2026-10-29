--[[
    ============================================================
     StealOrDie-Enhanced  v1.0.0
     Built on CDMUI v2.6.9

     功能：
       · 物品透视      按稀有度配色 + 价值/重量/距离
       · 玩家透视      对局内玩家
       · 实体透视      场景怪物（EntityKind）
       · 无限体力      AdminInfStamina
       · 不增加重量    CarryWeight / HandWeight = 0
       · 无限背包      CarryCapacity 拉满
       · 瞬间拾取      ProximityPrompt.HoldDuration = 0
       · 移动速度      RenderStepped 覆盖（绕过 MovementController）
       · 跳跃高度      RenderStepped 覆盖

     安全说明：
       · 不调用任何 Remote（ForceAdmin/AddBucks/GiveMoney 会被立刻检测）
       · 移动类修改有风险，默认关闭，使用时自行承担
       · 所有写入操作关闭时立即还原
    ============================================================
]]

-- ============================ 加载 CDMUI ============================
-- 和 Examination 完全一致的加载策略：
--   1) 优先读本地 CDMUI.lua（改完立刻生效）
--   2) 本地失败则走网络（GitHub raw + jsDelivr 双备份）
--   3) 最后兜底用 getgenv().CDMUI
local CDMUI
do
    local errs = {}

    -- 1) 本地文件
    local ok1, res1 = pcall(function()
        local src = readfile("CDMUI.lua")
        return loadstring(src)()
    end)
    if ok1 and type(res1) == "table" and res1.Create then
        CDMUI = res1
    else
        table.insert(errs, "local: " .. tostring(res1))
    end

    -- 2) 网络兜底
    if not CDMUI then
        local urls = {
            "https://raw.githubusercontent.com/Cubee332/CDMUI/main/CDMUI.lua",
            "https://cdn.jsdelivr.net/gh/Cubee332/CDMUI@main/CDMUI.lua",
        }
        for _, url in ipairs(urls) do
            local ok, res = pcall(function()
                local chunk = loadstring(game:HttpGet(url))
                if not chunk then error("loadstring failed") end
                return chunk()
            end)
            if ok and type(res) == "table" and res.Create then
                CDMUI = res
                break
            end
            table.insert(errs, url .. " -> " .. tostring(res))
        end
    end

    -- 3) 已加载的实例
    if not CDMUI then
        local g = getgenv().CDMUI
        if type(g) == "table" and g.Create then
            CDMUI = g
        end
    end

    if not CDMUI then
        warn("[SOD] CDMUI 加载失败: " .. table.concat(errs, " | "))
        return
    end
end
getgenv().CDMUI = CDMUI
print("[SOD] CDMUI v" .. tostring(CDMUI.Version) .. " 已加载")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

-- ============================ 配置 ============================
local GameConfig
pcall(function()
    GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig", 10))
end)
local ItemConfig = (GameConfig and GameConfig.Items) or {}
local RarityColour = (GameConfig and GameConfig.RarityColour) or {}

-- 稀有度中文 + 排序
local RARITY_CN = {
    Common = "普通", Uncommon = "优秀", Rare = "稀有",
    Mythic = "神话", Legendary = "传说", Secret = "隐秘",
}
local RARITY_RANK = { Common = 1, Uncommon = 2, Rare = 3, Mythic = 4, Legendary = 5, Secret = 6 }

-- 物品中文名
local ITEM_CN = {
    Bag="皮包", BarricadeKit="路障套件", Camera="相机", Candelabra="银烛台",
    Candy="糖果袋", CoffeeMug="咖啡杯", Console="游戏机", CryptoWallet="硬件钱包",
    CrystalBall="水晶球", DeskFan="桌面风扇", DeskLamp="台灯", Dossier="密封档案",
    FireExtinguisher="灭火器", GoldBar="金条", GraphicsCard="显卡", Guitar="木吉他",
    HardDrive="加密硬盘", Headphones="耳机", JackOLantern="南瓜灯", Keyboard="键盘",
    LabCase="样本箱", Laptop="笔记本电脑", Microwave="微波炉", MiniFridge="小冰箱",
    Monitor="一体机", Painting="油画", Phone="手机", Potions="药水套装",
    Projector="投影仪", RecordPlayer="黑胶唱机", Screwdriver="螺丝刀",
    ServerBlade="服务器刀片", Spellbook="魔法书", Tablet="平板电脑",
    Textbooks="一摞课本", Toolbox="工具箱", Watch="手表",
}

-- 距离
local ITEM_DIST = 500
local PLAYER_DIST = 900
local ENTITY_DIST = 1200
local LABEL_DIST = 180

local function rarityColor(r)
    local c = RarityColour[r]
    if not c then return Color3.fromRGB(210, 210, 215) end
    -- 太暗的提亮
    if (c.R + c.G + c.B) / 3 < 0.25 then
        return Color3.fromRGB(240, 240, 250)
    end
    return c
end

-- ============================ 状态 ============================
local State = {
    itemEsp = true,
    playerEsp = true,
    entityEsp = true,
    highValueOnly = false,
    showDistance = true,
    infiniteStamina = true,
    noWeight = false,
    infiniteBag = false,
    instantPickup = false,
    speedEnabled = false,
    jumpEnabled = false,
}

local Settings = {
    speedValue = 14,
    jumpValue = 0,
    itemDist = ITEM_DIST,
    playerDist = PLAYER_DIST,
    entityDist = ENTITY_DIST,
}

-- ============================ 工具 ============================
local function camPos()
    local cam = Workspace.CurrentCamera
    return cam and cam.CFrame.Position or Vector3.zero
end

local function firstPart(inst)
    if inst:IsA("BasePart") then return inst end
    return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
end

local partCache = setmetatable({}, { __mode = "k" })
local function getPart(inst)
    local c = partCache[inst]
    if c and c.Parent then return c end
    local f = firstPart(inst)
    partCache[inst] = f
    return f
end

local function distSq(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

-- ============================ ESP 基础设施 ============================
local TrackedItems = {}
local TrackedPlayers = {}
local TrackedEntities = {}

local function makeHighlight(parent, color, strong)
    local h = Instance.new("Highlight")
    h.Name = "SOD_ESP_HL"
    h.FillColor = color
    h.FillTransparency = strong and 0.5 or 0.72
    h.OutlineColor = color
    h.OutlineTransparency = strong and 0 or 0.15
    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    h.Adornee = parent
    h.Parent = parent
    return h
end

local function makeBillboard(parent, color, offsetY, height, textSize)
    local bb = Instance.new("BillboardGui")
    bb.Name = "SOD_ESP_BB"
    bb.Size = UDim2.fromOffset(260, height or 20)
    bb.StudsOffsetWorldSpace = Vector3.new(0, offsetY or 3, 0)
    bb.AlwaysOnTop = true
    bb.MaxDistance = 2000
    bb.LightInfluence = 0
    bb.ResetOnSpawn = false
    bb.Parent = parent

    local lbl = Instance.new("TextLabel")
    lbl.Name = "Text"
    lbl.Size = UDim2.fromScale(1, 1)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = textSize or 12
    lbl.TextColor3 = color
    lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
    lbl.TextStrokeTransparency = 0.3
    lbl.TextTruncate = Enum.TextTruncate.AtEnd
    lbl.Parent = bb

    return bb, lbl
end

local function destroyEntry(e)
    for _, k in ipairs({"highlight", "billboard"}) do
        if e[k] then
            pcall(function() e[k]:Destroy() end)
            e[k] = nil
        end
    end
end

local function clearAll(t)
    for k, e in pairs(t) do
        destroyEntry(e)
        t[k] = nil
    end
end

-- ============================ 物品数据 ============================
local function itemData(inst)
    local key = inst:GetAttribute("ItemKey")
    local rarity = inst:GetAttribute("Rarity")
    local value = inst:GetAttribute("Value")
    local weight = inst:GetAttribute("Weight")
    local cfg = key and ItemConfig[key]

    if not weight and cfg then weight = cfg.weight end

    return {
        key = key,
        name = ITEM_CN[key] or (cfg and cfg.displayName) or key or "?",
        rarity = rarity,
        value = value,
        weight = weight,
    }
end

local function isHighValue(d)
    if d.rarity and (RARITY_RANK[d.rarity] or 0) >= 4 then return true end
    return d.value ~= nil and d.value >= 500
end

-- ============================ 物品透视 ============================
local LOOT_FOLDERS = {"LootItems", "MyLoot", "Gadgets"}

local function refreshItemEsp()
    -- 收集候选
    local candidates = {}
    if State.itemEsp then
        local cp = camPos()
        local maxSq = Settings.itemDist * Settings.itemDist
        for _, fn in ipairs(LOOT_FOLDERS) do
            local folder = Workspace:FindFirstChild(fn)
            if folder then
                for _, child in ipairs(folder:GetChildren()) do
                    if child:GetAttribute("ItemKey") then
                        local part = getPart(child)
                        if part and distSq(part.Position, cp) <= maxSq then
                            if not State.highValueOnly or isHighValue(itemData(child)) then
                                candidates[child] = part
                            end
                        end
                    end
                end
            end
        end
    end

    -- 移除过期
    for target, e in pairs(TrackedItems) do
        if not candidates[target] or not target.Parent then
            destroyEntry(e)
            TrackedItems[target] = nil
        end
    end

    -- 添加新的
    local count = 0
    for _ in pairs(TrackedItems) do count = count + 1 end
    for target, part in pairs(candidates) do
        if count >= 100 then break end
        if not TrackedItems[target] then
            local d = itemData(target)
            local color = rarityColor(d.rarity)
            local strong = isHighValue(d)
            local hl = makeHighlight(target, color, strong)
            local bb, lbl = makeBillboard(target, color, (part.Size.Y / 2) + 1.2, 18, 12)
            TrackedItems[target] = {
                highlight = hl, billboard = bb, label = lbl,
                part = part, source = target,
            }
            count = count + 1
        else
            TrackedItems[target].part = part
        end
    end
end

local function updateItemTexts()
    local cp = camPos()
    for target, e in pairs(TrackedItems) do
        if e.label and e.part and e.part.Parent then
            local d = itemData(e.source)
            local bits = {}
            if d.rarity then bits[#bits+1] = "[" .. (RARITY_CN[d.rarity] or d.rarity) .. "]" end
            bits[#bits+1] = d.name
            if d.value then bits[#bits+1] = "$" .. tostring(d.value) end
            if d.weight then bits[#bits+1] = tostring(d.weight) .. "kg" end
            local text = table.concat(bits, " ")
            if isHighValue(d) then text = "★ " .. text end

            if State.showDistance then
                local dist = math.floor((e.part.Position - cp).Magnitude)
                text = text .. "  " .. dist .. "m"
            end

            if e._lastText ~= text then
                e._lastText = text
                e.label.Text = text
            end
            -- 标签距离裁剪
            local dist = (e.part.Position - cp).Magnitude
            e.billboard.Enabled = dist <= LABEL_DIST
        end
    end
end

-- ============================ 玩家透视 ============================
local function refreshPlayerEsp()
    local seen = {}
    if State.playerEsp then
        local cp = camPos()
        local maxSq = Settings.playerDist * Settings.playerDist
        for _, pl in ipairs(Players:GetPlayers()) do
            if pl ~= LocalPlayer then
                local char = pl.Character
                local part = char and getPart(char)
                local hum = char and char:FindFirstChildOfClass("Humanoid")
                if part and hum and hum.Health > 0 and distSq(part.Position, cp) <= maxSq then
                    seen[pl] = true
                    local e = TrackedPlayers[pl]
                    if not e or e.target ~= char then
                        if e then destroyEntry(e) end
                        local isEntity = pl:GetAttribute("IsEntity") == true
                        local color = isEntity and Color3.fromRGB(236, 78, 78) or Color3.fromRGB(92, 224, 128)
                        local hl = makeHighlight(char, color, isEntity)
                        local bb, lbl = makeBillboard(char, color, 3.2, 18, 13)
                        TrackedPlayers[pl] = {
                            target = char, part = part,
                            highlight = hl, billboard = bb, label = lbl,
                            isEntity = isEntity,
                        }
                    else
                        e.part = part
                    end
                end
            end
        end
    end

    for pl, e in pairs(TrackedPlayers) do
        if not seen[pl] or not e.target or not e.target.Parent then
            destroyEntry(e)
            TrackedPlayers[pl] = nil
        end
    end
end

local function updatePlayerTexts()
    local cp = camPos()
    for pl, e in pairs(TrackedPlayers) do
        if e.label and e.part and e.part.Parent then
            local text = (e.isEntity and "[实体] " or "") .. pl.DisplayName
            if State.showDistance then
                text = text .. "  " .. math.floor((e.part.Position - cp).Magnitude) .. "m"
            end
            if e._lastText ~= text then
                e._lastText = text
                e.label.Text = text
            end
            e.billboard.Enabled = (e.part.Position - cp).Magnitude <= LABEL_DIST
        end
    end
end

-- ============================ 实体透视 ============================
local function isMonster(model)
    if not model:IsA("Model") then return false end
    -- 排除玩家角色
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl.Character == model then return false end
    end
    local name = model.Name
    if name:find("Menu") or name:find("Preview") then return false end
    return model:GetAttribute("EntityKind") ~= nil
        or model:GetAttribute("PlayerEntity") ~= nil
        or model:GetAttribute("IsEntity") == true
end

local function refreshEntityEsp()
    local desired = {}
    if State.entityEsp then
        local cp = camPos()
        local maxSq = Settings.entityDist * Settings.entityDist
        for _, child in ipairs(Workspace:GetChildren()) do
            if isMonster(child) then
                local part = getPart(child)
                if part and distSq(part.Position, cp) <= maxSq then
                    local kind = tostring(child:GetAttribute("EntityKind") or child.Name)
                    local isAI = child:GetAttribute("Nav") ~= nil or child:GetAttribute("Stimulus") ~= nil
                    desired[child] = {
                        part = part,
                        color = isAI and Color3.fromRGB(255, 158, 66) or Color3.fromRGB(236, 78, 78),
                        text = (isAI and "[AI] " or "[实体] ") .. kind,
                    }
                end
            end
        end
    end

    for target, e in pairs(TrackedEntities) do
        if not desired[target] or not target.Parent then
            destroyEntry(e)
            TrackedEntities[target] = nil
        end
    end

    for target, meta in pairs(desired) do
        local e = TrackedEntities[target]
        if not e then
            local hl = makeHighlight(target, meta.color, true)
            local bb, lbl = makeBillboard(target, meta.color, (meta.part.Size.Y / 2) + 1.6, 20, 13)
            TrackedEntities[target] = {
                highlight = hl, billboard = bb, label = lbl,
                part = meta.part, text = meta.text, color = meta.color,
            }
        else
            e.part = meta.part
            e.text = meta.text
        end
    end
end

local function updateEntityTexts()
    local cp = camPos()
    for _, e in pairs(TrackedEntities) do
        if e.label and e.part and e.part.Parent then
            local text = e.text
            if State.showDistance then
                text = text .. "  " .. math.floor((e.part.Position - cp).Magnitude) .. "m"
            end
            if e._lastText ~= text then
                e._lastText = text
                e.label.Text = text
            end
            e.billboard.Enabled = (e.part.Position - cp).Magnitude <= LABEL_DIST
        end
    end
end

-- ============================ 属性功能 ============================
local function applyStamina(on)
    pcall(function()
        LocalPlayer:SetAttribute("AdminInfStamina", on and true or nil)
    end)
end

local function baseCapacity()
    local cfg = GameConfig and GameConfig.UpgradeByKey and GameConfig.UpgradeByKey.Capacity
    local base = (cfg and cfg.base) or (GameConfig and GameConfig.CarryCapacity) or 15
    local step = (cfg and cfg.step) or 5
    local up = LocalPlayer:GetAttribute((cfg and cfg.attr) or "UpgradeCapacity") or 0
    return base + step * up
end

local function pinCarry()
    if State.infiniteBag then
        if LocalPlayer:GetAttribute("CarryCapacity") ~= 999999 then
            pcall(function() LocalPlayer:SetAttribute("CarryCapacity", 999999) end)
        end
    end
    if State.noWeight then
        for _, a in ipairs({"CarryWeight", "HandWeight"}) do
            if LocalPlayer:GetAttribute(a) ~= 0 then
                pcall(function() LocalPlayer:SetAttribute(a, 0) end)
            end
        end
    end
end

-- ============================ 瞬间拾取 ============================
local instantPrompts = {}
local PICKUP_FOLDERS = {"LootItems", "MyLoot", "Gadgets"}

local function applyInstantPickup(on)
    if not on then
        for p, orig in pairs(instantPrompts) do
            if p.Parent then
                pcall(function() p.HoldDuration = orig end)
            end
        end
        instantPrompts = {}
        return
    end

    for _, fn in ipairs(PICKUP_FOLDERS) do
        local folder = Workspace:FindFirstChild(fn)
        if folder then
            for _, d in ipairs(folder:GetDescendants()) do
                if d:IsA("ProximityPrompt") and d.HoldDuration > 0 then
                    if instantPrompts[d] == nil then
                        instantPrompts[d] = d.HoldDuration
                    end
                    pcall(function() d.HoldDuration = 0 end)
                end
            end
        end
    end

    -- 清理失效
    for p in pairs(instantPrompts) do
        if not p.Parent then instantPrompts[p] = nil end
    end
end

-- ============================ 移动（有风险）============================
local speedConn, jumpConn

local function applySpeed(on)
    if speedConn then
        speedConn:Disconnect()
        speedConn = nil
    end
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return end

    if on then
        local target = Settings.speedValue
        speedConn = RunService.RenderStepped:Connect(function()
            local c = LocalPlayer.Character
            local h = c and c:FindFirstChildOfClass("Humanoid")
            if h and h.WalkSpeed ~= target then
                h.WalkSpeed = target
            end
        end)
    else
        pcall(function() hum.WalkSpeed = 8 end)
    end
end

local function applyJump(on)
    if jumpConn then
        jumpConn:Disconnect()
        jumpConn = nil
    end
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return end

    if on then
        local target = Settings.jumpValue
        if target <= 0 then return end
        jumpConn = RunService.RenderStepped:Connect(function()
            local c = LocalPlayer.Character
            local h = c and c:FindFirstChildOfClass("Humanoid")
            if h and h.JumpPower ~= target then
                h.JumpPower = target
            end
        end)
    else
        pcall(function() hum.JumpPower = 0 end)
    end
end

-- ============================ UI ============================
local win = CDMUI.Create({
    -- Title     = 主UI里的大标题（游戏名字）
    -- TopbarText = 左上角顶栏按钮的文字（固定「控制面板」）
    Title = "偷窃或死亡",
    TopbarText = "控制面板",
    RealLoading = true,
    Tasks = {
        { Name = "读取物品配置", Run = function()
            pcall(function()
                if not GameConfig then
                    GameConfig = require(ReplicatedStorage:WaitForChild("GameConfig", 5))
                end
                ItemConfig = (GameConfig and GameConfig.Items) or {}
                RarityColour = (GameConfig and GameConfig.RarityColour) or {}
            end)
        end },
        { Name = "扫描战利品", Run = function()
            pcall(refreshItemEsp)
        end },
        { Name = "初始化透视", Run = function()
            pcall(refreshPlayerEsp)
            pcall(refreshEntityEsp)
        end },
    },
})

-- ===== 物品透视 =====
local tabItem = win:Tab("物品")
tabItem:Section({ Name = "透视" })
tabItem:Expand({
    Key = "itemEsp",
    Name = "物品透视",
    Desc = "按稀有度显示所有战利品",
    Default = true,
    Callback = function(v)
        State.itemEsp = v
        if not v then clearAll(TrackedItems) else refreshItemEsp() end
    end,
    Children = {
        { Kind = "toggle", Key = "highValueOnly", Name = "只看高级", Default = false,
          Callback = function(v) State.highValueOnly = v; refreshItemEsp() end },
        { Kind = "toggle", Key = "showDist", Name = "显示距离", Default = true,
          Callback = function(v) State.showDistance = v end },
        { Kind = "slider", Key = "itemDist", Name = "显示距离", Min = 100, Max = 2000, Default = 500,
          Suffix = " studs",
          Callback = function(v) Settings.itemDist = v; refreshItemEsp() end },
    },
})

tabItem:Section({ Name = "拾取" })
tabItem:Toggle({
    Key = "instantPickup", Name = "瞬间拾取",
    Desc = "按住时长归零（仍需按 E）", Default = false,
    Callback = function(v) State.instantPickup = v; applyInstantPickup(v) end,
})

-- ===== 玩家透视 =====
local tabPlayer = win:Tab("玩家")
tabPlayer:Section({ Name = "透视" })
tabPlayer:Toggle({
    Key = "playerEsp", Name = "玩家透视", Desc = "显示对局内所有玩家", Default = true,
    Callback = function(v)
        State.playerEsp = v
        if not v then clearAll(TrackedPlayers) else refreshPlayerEsp() end
    end,
})
tabPlayer:Toggle({
    Key = "entityEsp", Name = "实体透视", Desc = "显示场景里的怪物实体", Default = true,
    Callback = function(v)
        State.entityEsp = v
        if not v then clearAll(TrackedEntities) else refreshEntityEsp() end
    end,
})
tabPlayer:Slider({
    Key = "playerDist", Name = "玩家距离", Min = 100, Max = 3000, Default = 900,
    Suffix = " studs",
    Callback = function(v) Settings.playerDist = v; refreshPlayerEsp() end,
})
tabPlayer:Slider({
    Key = "entityDist", Name = "实体距离", Min = 100, Max = 3000, Default = 1200,
    Suffix = " studs",
    Callback = function(v) Settings.entityDist = v; refreshEntityEsp() end,
})

-- ===== 属性 =====
local tabStat = win:Tab("属性")
tabStat:Section({ Name = "体力与负重" })
tabStat:Toggle({
    Key = "infStamina", Name = "无限体力", Desc = "体力永远满", Default = true,
    Callback = function(v) State.infiniteStamina = v; applyStamina(v) end,
})
tabStat:Toggle({
    Key = "noWeight", Name = "不增加重量", Desc = "手持和背包重量常驻 0", Default = false,
    Callback = function(v) State.noWeight = v; pinCarry() end,
})
tabStat:Toggle({
    Key = "infBag", Name = "无限背包", Desc = "容量拉满", Default = false,
    Callback = function(v)
        State.infiniteBag = v
        if v then pinCarry()
        else pcall(function() LocalPlayer:SetAttribute("CarryCapacity", baseCapacity()) end) end
    end,
})

-- ===== 移动（警告）=====
local tabMove = win:Tab("移动")
tabMove:Section({ Name = "⚠ 高风险" })
tabMove:Paragraph({
    Text = "移动类修改会被反作弊检测（speed hack / flying），\n使用后可能被踢出对局。默认关闭。",
})
tabMove:Expand({
    Key = "speedEnabled",
    Name = "移动加速",
    Desc = "只覆盖 WalkSpeed，不改变移动方式（安全上限 16）",
    Default = false,
    Callback = function(v) State.speedEnabled = v; applySpeed(v) end,
    Children = {
        { Kind = "slider", Key = "speedVal", Name = "速度", Min = 10, Max = 16, Default = 14,
          Callback = function(v) Settings.speedValue = v; if State.speedEnabled then applySpeed(true) end end },
    },
})
tabMove:Paragraph({
    Text = "跳跃增强已移除：服务器会判定 flying 并立刻踢出。",
})

-- ===== 信息 =====
local tabInfo = win:Tab("信息")
tabInfo:Section({ Name = "说明" })
tabInfo:Paragraph({
    Text = "本脚本不调用任何 Remote 接口。\nForceAdmin / AddBucks / GiveMoney 等已被服务器拦截，调用会被立刻踢出。",
})
tabInfo:Paragraph({
    Text = "属性类修改（体力/负重/容量）服务器不重置，安全可用。\n移动类修改有检测风险，请谨慎使用。",
})

-- ============================ 主循环 ============================
local scanClock, textClock, carryClock, pickupClock = 0, 0, 0, 0

local heartbeatConn = RunService.Heartbeat:Connect(function(dt)
    scanClock = scanClock + dt
    textClock = textClock + dt
    carryClock = carryClock + dt
    pickupClock = pickupClock + dt

    if carryClock >= 0.25 then
        carryClock = 0
        pinCarry()
    end

    if State.instantPickup and pickupClock >= 0.4 then
        pickupClock = 0
        applyInstantPickup(true)
    end

    if scanClock >= 0.5 then
        scanClock = 0
        if State.itemEsp then refreshItemEsp() end
        if State.playerEsp then refreshPlayerEsp() end
        if State.entityEsp then refreshEntityEsp() end
    end

    if textClock >= 0.25 then
        textClock = 0
        if State.itemEsp then updateItemTexts() end
        if State.playerEsp then updatePlayerTexts() end
        if State.entityEsp then updateEntityTexts() end
    end
end)

-- ============================ 初始化 ============================
if State.infiniteStamina then applyStamina(true) end
refreshItemEsp()
refreshPlayerEsp()
refreshEntityEsp()

LocalPlayer.CharacterAdded:Connect(function()
    task.wait(1)
    if State.infiniteStamina then applyStamina(true) end
    pinCarry()
    if State.speedEnabled then applySpeed(true) end
    if State.jumpEnabled then applyJump(true) end
end)

-- ============================ 卸载 ============================
local function unload()
    if heartbeatConn then
        heartbeatConn:Disconnect()
        heartbeatConn = nil
    end
    if speedConn then speedConn:Disconnect(); speedConn = nil end
    if jumpConn then jumpConn:Disconnect(); jumpConn = nil end

    clearAll(TrackedItems)
    clearAll(TrackedPlayers)
    clearAll(TrackedEntities)

    pcall(function() applyStamina(false) end)
    pcall(function() applyInstantPickup(false) end)
    pcall(function()
        LocalPlayer:SetAttribute("CarryCapacity", baseCapacity())
        LocalPlayer:SetAttribute("CarryWeight", nil)
        LocalPlayer:SetAttribute("HandWeight", nil)
    end)

    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        pcall(function()
            hum.WalkSpeed = 8
            hum.JumpPower = 0
        end)
    end

    pcall(function() win:Destroy() end)
    getgenv().SOD_Unload = nil
end

getgenv().SOD_Unload = unload
print("[SOD] StealOrDie-Enhanced 已加载")
