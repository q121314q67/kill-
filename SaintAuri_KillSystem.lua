--[[
    杀戮系统 v10.1 [紧急修复版]
    修复：Part 无 Visible 属性导致脚本崩溃的问题，改用 Parent 控制显隐
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

-- [全局统一配置]
local Config = {
    -- 近战
    Melee_Enabled = false,
    Melee_Range = 30,
    Melee_MultiHit = true,
    Melee_ForceCombatMode = true,
    Melee_SelfAntiCombatMode = false,
    Melee_CheckFriends = false,
    Melee_CheckVisibility = false,
    Melee_AllowedTeams = {},
    
    -- 远程
    Ranged_Enabled = false,
    Ranged_Range = 1000,
    Ranged_AutoHeadshot = true,
    Ranged_MultiBullet = true,
    Ranged_WallBang = false,
    Ranged_NoCooldown = true,
    Ranged_CheckFriends = false,
    Ranged_CheckVisibility = false,
    Ranged_AllowedTeams = {},
    
    -- 实用工具
    ESP_Enabled = false,
    InstantInteract_Enabled = false,
    
    -- 其他
    TestMode = false
}

-- [全局状态与回调中心]
local State = {
    RemoteEvent = nil,
    MeleeThread = nil,
    RangedThread = nil,
    AutoHideThread = nil,
    Shortcuts = {},
    IsPlacingShortcut = false,
    CurrentActionToBind = nil,
    CombatModeTick = 0,
    MeleeHighlights = {}, 
    RangedHighlights = {},
    ActiveToggles = {},
    ESPObjects = {},
    
    GlobalCallbacks = {
        Melee_Enabled = function(val) if val then StartMeleeLoop() end end,
        Ranged_Enabled = function(val) if val then StartRangedLoop() end end,
        TestMode = function(val) print("[System] 测试开关状态改变 ->", val) end,
        ESP_Enabled = function(val) if not val then ClearESP() end end
    }
}

local function GenerateNeonTheme()
    local h1 = math.random()
    local h2 = (h1 + 0.15) % 1
    return {
        C1 = Color3.fromHSV(h1, 0.8, 1),
        C2 = Color3.fromHSV(h2, 0.9, 1),
        Dark = Color3.fromHSV(h1, 0.5, 0.1),
        Darker = Color3.fromHSV(h1, 0.5, 0.05),
        Background = Color3.fromHSV(h1, 0.5, 0.15)
    }
end

local Theme = GenerateNeonTheme()

local function ApplyGradient(guiObj)
    local grad = Instance.new("UIGradient")
    grad.Color = ColorSequence.new(Theme.C1, Theme.C2)
    grad.Rotation = math.random(0, 360)
    grad.Parent = guiObj
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "KillSystemUI_v10"
ScreenGui.ResetOnSpawn = false
ScreenGui.DisplayOrder = 999
pcall(function() ScreenGui.Parent = CoreGui end)
if not ScreenGui.Parent then ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local BlurEffect = Instance.new("BlurEffect")
BlurEffect.Size = 0
BlurEffect.Parent = Lighting

-- ==========================================
-- [范围可视化圆环 - 修复版]
-- ==========================================
local RangeMarker = Instance.new("Part")
RangeMarker.Shape = Enum.PartType.Ball
RangeMarker.Material = Enum.Material.ForceField
RangeMarker.Color = Color3.fromRGB(0, 255, 0)
RangeMarker.Transparency = 0.8
RangeMarker.Anchored = true
RangeMarker.CanCollide = false
RangeMarker.CanQuery = false
RangeMarker.Parent = nil -- 默认隐藏，通过 Parent 控制显隐

RunService.RenderStepped:Connect(function()
    local char = LocalPlayer.Character
    if char and char:FindFirstChild("HumanoidRootPart") then
        local root = char.HumanoidRootPart
        local showMelee = Config.Melee_Enabled
        local showRanged = Config.Ranged_Enabled
        
        if showMelee or showRanged then
            RangeMarker.Parent = workspace
            local r = showMelee and Config.Melee_Range or Config.Ranged_Range
            RangeMarker.Size = Vector3.new(r*2, r*2, r*2)
            RangeMarker.CFrame = root.CFrame
            RangeMarker.Color = showMelee and Color3.fromRGB(255, 50, 50) or Color3.fromRGB(50, 150, 255)
        else
            RangeMarker.Parent = nil
        end
    else
        RangeMarker.Parent = nil
    end
end)

-- ==========================================
-- [侧边栏系统]
-- ==========================================
local SideBarTrigger = Instance.new("TextButton")
SideBarTrigger.Size = UDim2.new(0, 20, 0, 150)
SideBarTrigger.Position = UDim2.new(1, -5, 0.5, -75)
SideBarTrigger.BackgroundColor3 = Theme.Dark
SideBarTrigger.Text = ""
SideBarTrigger.Parent = ScreenGui
Instance.new("UICorner", SideBarTrigger).CornerRadius = UDim.new(0, 8)
ApplyGradient(SideBarTrigger)

local SideBar = Instance.new("Frame")
SideBar.Size = UDim2.new(0, 80, 0, 260)
SideBar.Position = UDim2.new(1, 0, 0.5, -130)
SideBar.BackgroundColor3 = Theme.Darker
SideBar.Parent = ScreenGui
Instance.new("UICorner", SideBar).CornerRadius = UDim.new(0, 16)
local sbStroke = Instance.new("UIStroke", SideBar)
sbStroke.Thickness = 2
ApplyGradient(sbStroke)

local SideList = Instance.new("UIListLayout", SideBar)
SideList.Padding = UDim.new(0, 10)
SideList.HorizontalAlignment = Enum.HorizontalAlignment.Center
SideList.VerticalAlignment = Enum.VerticalAlignment.Center

local isSideBarOut = false
local function ToggleSideBar(show)
    isSideBarOut = show
    if show then
        TweenService:Create(SideBar, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Position = UDim2.new(1, -90, 0.5, -130)}):Play()
        if State.AutoHideThread then task.cancel(State.AutoHideThread) end
        State.AutoHideThread = task.delay(5, function()
            if isSideBarOut and not (ActivePopup and ActivePopup.Parent) then
                ToggleSideBar(false)
            end
        end)
    else
        TweenService:Create(SideBar, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Position = UDim2.new(1, 0, 0.5, -130)}):Play()
    end
end

SideBarTrigger.MouseButton1Click:Connect(function()
    ToggleSideBar(not isSideBarOut)
end)

-- ==========================================
-- [弹窗系统]
-- ==========================================
local ActivePopup = nil

local function ClosePopup()
    if ActivePopup then
        local pop = ActivePopup
        ActivePopup = nil
        table.clear(State.ActiveToggles)
        TweenService:Create(pop, TweenInfo.new(0.2), {Size = UDim2.new(0, 0, 0, 0)}):Play()
        TweenService:Create(BlurEffect, TweenInfo.new(0.2), {Size = 0}):Play()
        task.wait(0.2)
        pop:Destroy()
        ToggleSideBar(true)
    end
end

local function OpenPopup(TitleText, BuildContentFunc)
    if ActivePopup then ClosePopup() end
    Theme = GenerateNeonTheme()
    ToggleSideBar(false)

    SideBar.BackgroundColor3 = Theme.Darker
    ApplyGradient(sbStroke)
    ApplyGradient(SideBarTrigger)

    ActivePopup = Instance.new("Frame")
    ActivePopup.Size = UDim2.new(0, 0, 0, 0)
    ActivePopup.Position = UDim2.new(0.5, 0, 0.5, 0)
    ActivePopup.AnchorPoint = Vector2.new(0.5, 0.5)
    ActivePopup.BackgroundColor3 = Theme.Dark
    ActivePopup.Parent = ScreenGui
    ActivePopup.ClipsDescendants = true
    Instance.new("UICorner", ActivePopup).CornerRadius = UDim.new(0, 16)
    local popStroke = Instance.new("UIStroke", ActivePopup)
    popStroke.Thickness = 2
    ApplyGradient(popStroke)

    TweenService:Create(ActivePopup, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Size = UDim2.new(0, 350, 0, 450)}):Play()
    TweenService:Create(BlurEffect, TweenInfo.new(0.3), {Size = 24}):Play()

    local Header = Instance.new("TextLabel")
    Header.Size = UDim2.new(1, 0, 0, 40)
    Header.BackgroundTransparency = 1
    Header.Text = TitleText
    Header.TextColor3 = Theme.C1
    Header.Font = Enum.Font.GothamBold
    Header.TextSize = 18
    Header.Parent = ActivePopup

    local CloseBtn = Instance.new("TextButton")
    CloseBtn.Size = UDim2.new(0, 30, 0, 30)
    CloseBtn.Position = UDim2.new(1, -35, 0, 5)
    CloseBtn.BackgroundColor3 = Theme.Darker
    CloseBtn.Text = "X"
    CloseBtn.TextColor3 = Theme.C1
    CloseBtn.Font = Enum.Font.GothamBold
    CloseBtn.TextSize = 14
    CloseBtn.Parent = ActivePopup
    Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(1, 0)
    CloseBtn.MouseButton1Click:Connect(ClosePopup)

    local ContentHolder = Instance.new("ScrollingFrame")
    ContentHolder.Size = UDim2.new(1, -20, 1, -50)
    ContentHolder.Position = UDim2.new(0, 10, 0, 45)
    ContentHolder.BackgroundTransparency = 1
    ContentHolder.ScrollBarThickness = 4
    ContentHolder.CanvasSize = UDim2.new(0, 0, 0, 0)
    ContentHolder.AutomaticCanvasSize = Enum.AutomaticSize.Y
    ContentHolder.Parent = ActivePopup
    
    local ListLayout = Instance.new("UIListLayout", ContentHolder)
    ListLayout.Padding = UDim.new(0, 8)
    ListLayout.SortOrder = Enum.SortOrder.LayoutOrder

    local Pad = Instance.new("UIPadding", ContentHolder)
    Pad.PaddingBottom = UDim.new(0, 10)

    BuildContentFunc(ContentHolder)
end

-- ==========================================
-- [UI 控件构建器]
-- ==========================================
local function CreateRow(parent, height)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, height)
    row.BackgroundColor3 = Theme.Darker
    row.Parent = parent
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)
    return row
end

local function CreateToggle(parent, name, configKey, icon)
    local row = CreateRow(parent, 40)
    local state = Config[configKey]
    
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -60, 0, 40)
    label.Position = UDim2.new(0, 15, 0, 0)
    label.BackgroundTransparency = 1
    label.Text = name
    label.TextColor3 = Color3.fromRGB(230, 230, 230)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Font = Enum.Font.Gotham
    label.TextSize = 14
    label.Parent = row

    local switch = Instance.new("TextButton")
    switch.Size = UDim2.new(0, 45, 0, 22)
    switch.Position = UDim2.new(1, -55, 0.5, -11)
    switch.BackgroundColor3 = Theme.Dark
    switch.AutoButtonColor = false
    switch.Text = ""
    switch.Parent = row
    Instance.new("UICorner", switch).CornerRadius = UDim.new(1, 0)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 16, 0, 16)
    knob.Position = UDim2.new(0, 3, 0.5, -8)
    knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    knob.Parent = switch
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    local function UpdateVisual()
        if state then
            TweenService:Create(switch, TweenInfo.new(0.2), {BackgroundColor3 = Theme.C1}):Play()
            TweenService:Create(knob, TweenInfo.new(0.2, Enum.EasingStyle.Back), {Position = UDim2.new(1, -19, 0.5, -8)}):Play()
        else
            TweenService:Create(switch, TweenInfo.new(0.2), {BackgroundColor3 = Theme.Dark}):Play()
            TweenService:Create(knob, TweenInfo.new(0.2), {Position = UDim2.new(0, 3, 0.5, -8)}):Play()
        end
    end
    
    local function ToggleState()
        state = not state
        Config[configKey] = state
        UpdateVisual()
        if State.GlobalCallbacks[configKey] then
            State.GlobalCallbacks[configKey](state)
        end
    end

    State.ActiveToggles[configKey] = function(val)
        state = val
        UpdateVisual()
    end

    UpdateVisual()
    switch.MouseButton1Click:Connect(ToggleState)

    if icon then
        local pressTime = 0
        local isPressing = false
        switch.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                isPressing = true
                pressTime = tick()
                task.delay(0.8, function()
                    if isPressing and tick() - pressTime >= 0.8 then
                        State.IsPlacingShortcut = true
                        State.CurrentActionToBind = { configKey = configKey, icon = icon }
                        ClosePopup()
                        ToggleSideBar(false)
                    end
                end)
            end
        end)
        switch.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                isPressing = false
            end
        end)
    end
    return row
end

local function CreateSlider(parent, name, minVal, maxVal, default, configKey)
    local row = CreateRow(parent, 50)
    
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(0.5, -20, 0, 40)
    label.Position = UDim2.new(0, 15, 0, 5)
    label.BackgroundTransparency = 1
    label.Text = name
    label.TextColor3 = Color3.fromRGB(230, 230, 230)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Font = Enum.Font.Gotham
    label.TextSize = 14
    label.Parent = row

    local valLabel = Instance.new("TextLabel")
    valLabel.Size = UDim2.new(0.5, -10, 0, 40)
    valLabel.Position = UDim2.new(0.5, 5, 0, 5)
    valLabel.BackgroundTransparency = 1
    valLabel.TextColor3 = Theme.C1
    valLabel.TextXAlignment = Enum.TextXAlignment.Right
    valLabel.Font = Enum.Font.GothamMedium
    valLabel.TextSize = 14
    valLabel.Text = tostring(default)
    valLabel.Parent = row

    local barBg = Instance.new("Frame")
    barBg.Size = UDim2.new(1, -30, 0, 6)
    barBg.Position = UDim2.new(0, 15, 0, 38)
    barBg.BackgroundColor3 = Theme.Background
    barBg.Parent = row
    Instance.new("UICorner", barBg).CornerRadius = UDim.new(1, 0)
    
    local fill = Instance.new("Frame")
    fill.Size = UDim2.new((default-minVal)/(maxVal-minVal), 0, 1, 0)
    fill.BackgroundColor3 = Theme.C1
    fill.Parent = barBg
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

    local dragging = false
    local function update(inputPos)
        local rel = (inputPos.X - barBg.AbsolutePosition.X) / barBg.AbsoluteSize.X
        rel = math.clamp(rel, 0, 1)
        local val = math.floor(minVal + (maxVal - minVal) * rel)
        fill.Size = UDim2.new(rel, 0, 1, 0)
        valLabel.Text = tostring(val)
        Config[configKey] = val
    end

    barBg.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            update(input.Position)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            update(input.Position)
        end
    end)
    return row
end

local function CreateMultiSelectList(parent, name, getOptionsFunc, configKey, callback)
    local row = CreateRow(parent, 40)
    local selectedTable = Config[configKey]
    
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -60, 0, 40)
    label.Position = UDim2.new(0, 15, 0, 0)
    label.BackgroundTransparency = 1
    label.Text = name
    label.TextColor3 = Color3.fromRGB(230, 230, 230)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Font = Enum.Font.Gotham
    label.TextSize = 14
    label.Parent = row

    local listContainer = Instance.new("Frame")
    listContainer.Size = UDim2.new(1, 0, 0, 0)
    listContainer.Position = UDim2.new(0, 0, 0, 40)
    listContainer.BackgroundTransparency = 1
    listContainer.Parent = row
    listContainer.ClipsDescendants = true

    local listLayout = Instance.new("UIListLayout", listContainer)
    listLayout.Padding = UDim.new(0, 5)
    listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

    local isExpanded = false
    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Size = UDim2.new(0, 30, 0, 30)
    toggleBtn.Position = UDim2.new(1, -40, 0, 5)
    toggleBtn.BackgroundColor3 = Theme.Dark
    toggleBtn.Text = "v"
    toggleBtn.TextColor3 = Theme.C1
    toggleBtn.Font = Enum.Font.GothamBold
    toggleBtn.TextSize = 12
    toggleBtn.Parent = row
    Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(1, 0)

    local function RebuildList()
        for _, child in ipairs(listContainer:GetChildren()) do
            if child:IsA("TextButton") then child:Destroy() end
        end
        local teams = getOptionsFunc()
        local h = 0
        for _, team in ipairs(teams) do
            local tBtn = Instance.new("TextButton")
            tBtn.Size = UDim2.new(1, -20, 0, 30)
            tBtn.BackgroundColor3 = Theme.Dark
            tBtn.Text = team.Name
            tBtn.TextColor3 = team.TeamColor.Color
            tBtn.Font = Enum.Font.GothamMedium
            tBtn.TextSize = 12
            tBtn.Parent = listContainer
            Instance.new("UICorner", tBtn).CornerRadius = UDim.new(1, 0)

            local isSelected = table.find(selectedTable, team.Name) ~= nil
            if isSelected then tBtn.BackgroundColor3 = Theme.C1 end

            tBtn.MouseButton1Click:Connect(function()
                local idx = table.find(selectedTable, team.Name)
                if idx then
                    table.remove(selectedTable, idx)
                    tBtn.BackgroundColor3 = Theme.Dark
                else
                    table.insert(selectedTable, team.Name)
                    tBtn.BackgroundColor3 = Theme.C1
                end
                callback(selectedTable)
            end)
            h = h + 35
        end
        return h
    end

    toggleBtn.MouseButton1Click:Connect(function()
        isExpanded = not isExpanded
        if isExpanded then
            local h = RebuildList()
            toggleBtn.Text = "^"
            TweenService:Create(row, TweenInfo.new(0.3), {Size = UDim2.new(1, 0, 0, 40 + h)}):Play()
            TweenService:Create(listContainer, TweenInfo.new(0.3), {Size = UDim2.new(1, 0, 0, h)}):Play()
        else
            toggleBtn.Text = "v"
            TweenService:Create(row, TweenInfo.new(0.3), {Size = UDim2.new(1, 0, 0, 40)}):Play()
            TweenService:Create(listContainer, TweenInfo.new(0.3), {Size = UDim2.new(1, 0, 0, 0)}):Play()
        end
    end)
end

-- ==========================================
-- [多快捷键共存系统]
-- ==========================================
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if State.IsPlacingShortcut and State.CurrentActionToBind then
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            local pos = input.Position
            State.IsPlacingShortcut = false

            local bindAction = State.CurrentActionToBind
            State.CurrentActionToBind = nil
            local key = bindAction.configKey

            local shortcut = Instance.new("TextButton")
            shortcut.Size = UDim2.new(0, 50, 0, 50)
            shortcut.Position = UDim2.new(0, pos.X - 25, 0, pos.Y - 25)
            shortcut.BackgroundColor3 = Theme.Darker
            shortcut.BackgroundTransparency = Config[key] and 0.2 or 0.5
            shortcut.Text = bindAction.icon or "⚡"
            shortcut.TextColor3 = Theme.C1
            shortcut.Font = Enum.Font.GothamBold
            shortcut.TextSize = 20
            shortcut.Parent = ScreenGui
            Instance.new("UICorner", shortcut).CornerRadius = UDim.new(1, 0)
            
            table.insert(State.Shortcuts, shortcut)

            local holding = false
            local pressTime = 0
            shortcut.InputBegan:Connect(function(inp)
                if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
                    holding = true
                    pressTime = tick()
                    task.delay(0.8, function()
                        if holding and tick() - pressTime >= 0.8 and shortcut.Parent then
                            shortcut:Destroy()
                            for i, sc in ipairs(State.Shortcuts) do
                                if sc == shortcut then table.remove(State.Shortcuts, i) break end
                            end
                        end
                    end)
                end
            end)

            shortcut.InputEnded:Connect(function(inp)
                if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
                    if holding and shortcut.Parent then
                        holding = false
                        if tick() - pressTime < 0.8 then
                            Config[key] = not Config[key]
                            if State.GlobalCallbacks[key] then State.GlobalCallbacks[key](Config[key]) end
                            if State.ActiveToggles[key] then State.ActiveToggles[key](Config[key]) end
                            shortcut.BackgroundTransparency = Config[key] and 0.2 or 0.5
                        end
                    end
                end
            end)
        end
    end
end)

-- ==========================================
-- [侧边栏图标绑定]
-- ==========================================
local function CreateSideIcon(iconText, openFunc)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 60, 0, 60)
    btn.BackgroundColor3 = Theme.Dark
    btn.Text = iconText
    btn.TextColor3 = Theme.C1
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 30
    btn.Parent = SideBar
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0.5, 0)
    local stroke = Instance.new("UIStroke", btn)
    stroke.Thickness = 2
    ApplyGradient(stroke)
    btn.MouseButton1Click:Connect(openFunc)
    return btn
end

CreateSideIcon("⚔️", function()
    OpenPopup("近战杀戮", function(holder)
        CreateSlider(holder, "攻击范围", 5, 1000, Config.Melee_Range, "Melee_Range")
        CreateToggle(holder, "自动攻击", "Melee_Enabled", "⚔️")
        CreateToggle(holder, "多部位打击", "Melee_MultiHit", "🎯")
        CreateToggle(holder, "强制战斗模式", "Melee_ForceCombatMode", "🔥")
        CreateToggle(holder, "自身免战斗模式", "Melee_SelfAntiCombatMode", "🛡️")
        CreateToggle(holder, "好友检测", "Melee_CheckFriends", "🤝")
        CreateToggle(holder, "可见性检测", "Melee_CheckVisibility", "👁️")

        local function GetTeams() 
            local t = {}
            for _, team in ipairs(game:GetService("Teams"):GetTeams()) do table.insert(t, team) end
            return t
        end
        CreateMultiSelectList(holder, "队伍选择检测", GetTeams, "Melee_AllowedTeams", function(sel) end)
    end)
end)

CreateSideIcon("🔫", function()
    OpenPopup("远程杀戮", function(holder)
        CreateSlider(holder, "攻击范围", 100, 5000, Config.Ranged_Range, "Ranged_Range")
        CreateToggle(holder, "自动枪锁", "Ranged_Enabled", "🔫")
        CreateToggle(holder, "仅爆头", "Ranged_AutoHeadshot", "🧠")
        CreateToggle(holder, "散弹多发模拟", "Ranged_MultiBullet", "💥")
        CreateToggle(holder, "子弹穿墙", "Ranged_WallBang", "🧱")
        CreateToggle(holder, "无停顿连射", "Ranged_NoCooldown", "⚡")
        CreateToggle(holder, "好友检测", "Ranged_CheckFriends", "🤝")
        CreateToggle(holder, "可见性检测", "Ranged_CheckVisibility", "👁️")

        local function GetTeams() 
            local t = {}
            for _, team in ipairs(game:GetService("Teams"):GetTeams()) do table.insert(t, team) end
            return t
        end
        CreateMultiSelectList(holder, "队伍选择检测", GetTeams, "Ranged_AllowedTeams", function(sel) end)
    end)
end)

CreateSideIcon("👁️", function()
    OpenPopup("实用工具", function(holder)
        CreateToggle(holder, "玩家透视", "ESP_Enabled", "👻")
        CreateToggle(holder, "秒互动 (防按住)", "InstantInteract_Enabled", "⚡")
    end)
end)

CreateSideIcon("⚙️", function()
    OpenPopup("设置", function(holder)
        CreateToggle(holder, "测试开关", "TestMode", "🧪")
    end)
end)

-- ==========================================
-- [核心公共逻辑]
-- ==========================================
local function FetchRemote()
    if State.RemoteEvent then return State.RemoteEvent end
    local success, result = pcall(function()
        return ReplicatedStorage:WaitForChild("Remote", 3):WaitForChild("PlayerEvent", 3)
    end)
    if success and result then
        State.RemoteEvent = result
        return result
    end
    return nil
end

local function GetValidTargets(mode)
    local localChar = LocalPlayer.Character
    if not localChar or not localChar:FindFirstChild("HumanoidRootPart") or not localChar:FindFirstChild("Humanoid") then return {} end
    if localChar.Humanoid.Health <= 0 then return {} end

    local localRoot = localChar.HumanoidRootPart
    local validTargets = {}
    
    local checkFriends = Config[mode .. "_CheckFriends"]
    local checkVis = Config[mode .. "_CheckVisibility"]
    if mode == "Ranged" and Config.Ranged_WallBang then checkVis = false end
    
    local allowedTeams = Config[mode .. "_AllowedTeams"]
    local range = Config[mode .. "_Range"]
    
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            if #allowedTeams > 0 then
                if not player.Team or not table.find(allowedTeams, player.Team.Name) then continue end
            end
            if checkFriends and LocalPlayer:IsFriendsWith(player.UserId) then continue end

            local targetChar = player.Character
            if targetChar and targetChar:FindFirstChild("HumanoidRootPart") and targetChar:FindFirstChild("Humanoid") then
                if targetChar.Humanoid.Health > 0 then
                    local targetRoot = targetChar.HumanoidRootPart
                    local dist = (targetRoot.Position - localRoot.Position).Magnitude
                    
                    if dist <= range then
                        local isVisible = true
                        if checkVis then
                            local params = RaycastParams.new()
                            params.FilterDescendantsInstances = {localChar}
                            params.FilterType = Enum.RaycastFilterType.Exclude
                            local hit = workspace:Raycast(localRoot.Position, (targetRoot.Position - localRoot.Position), params)
                            if hit and not hit.Instance:IsDescendantOf(targetChar) then isVisible = false end
                        end
                        
                        if isVisible then
                            table.insert(validTargets, {Player = player, Dist = dist, Char = targetChar, Root = targetRoot})
                        end
                    end
                end
            end
        end
    end
    
    table.sort(validTargets, function(a, b) return a.Dist < b.Dist end)
    return validTargets
end

local function ManageMultiHighlight(activeChars, highlightTable, color)
    for key, hl in pairs(highlightTable) do
        if not hl.Parent or not hl.Parent.Parent or not table.find(activeChars, hl.Parent) then
            hl:Destroy()
            highlightTable[key] = nil
        end
    end

    for _, char in ipairs(activeChars) do
        local hasHighlight = false
        for _, hl in pairs(highlightTable) do
            if hl.Parent == char then
                hasHighlight = true
                break
            end
        end
        if not hasHighlight then
            local newHl = Instance.new("Highlight")
            newHl.FillColor = color
            newHl.OutlineColor = Color3.fromRGB(255, 255, 255)
            newHl.FillTransparency = 0.5
            newHl.Parent = char
            table.insert(highlightTable, newHl)
        end
    end
end

local function ClearHighlights(highlightTable)
    for _, hl in pairs(highlightTable) do
        if hl then hl:Destroy() end
    end
    table.clear(highlightTable)
end

-- ==========================================
-- [近战战斗逻辑]
-- ==========================================
local function GetBodyPartsArray(character)
    local parts = {}
    local priority = {"Head", "Torso", "UpperTorso", "HumanoidRootPart", "LowerTorso", "LeftArm", "RightArm", "LeftHand", "RightHand", "LeftLeg", "RightLeg"}
    for _, name in ipairs(priority) do
        local p = character:FindFirstChild(name)
        if p then table.insert(parts, { [1] = name, [2] = 1 }) end
    end
    if #parts == 0 then table.insert(parts, { [1] = "HumanoidRootPart", [2] = 1 }) end
    return parts
end

function StartMeleeLoop()
    if State.MeleeThread then task.cancel(State.MeleeThread) end
    State.MeleeThread = task.spawn(function()
        while Config.Melee_Enabled do
            task.wait(0.3)
            
            local Remote = FetchRemote()
            if not Remote then task.wait(1) continue end
            
            if Config.Melee_ForceCombatMode and tick() - State.CombatModeTick > (0.4 + math.random()*0.2) then
                State.CombatModeTick = tick()
                pcall(function() Remote:FireServer("combatMode", true) end)
            elseif Config.Melee_SelfAntiCombatMode and not Config.Melee_ForceCombatMode and tick() - State.CombatModeTick > 0.5 then
                State.CombatModeTick = tick()
                pcall(function() Remote:FireServer("combatMode", false) end)
            end

            local targets = GetValidTargets("Melee")
            local localChar = LocalPlayer.Character
            
            if #targets > 0 and localChar and localChar:FindFirstChild("HumanoidRootPart") then
                local activeChars = {}
                local localRoot = localChar.HumanoidRootPart
                local localPos = localRoot.Position
                
                for _, targetData in ipairs(targets) do
                    local targetChar = targetData.Char
                    table.insert(activeChars, targetChar)
                    
                    task.spawn(function()
                        local bodyPartsArr = Config.Melee_MultiHit and GetBodyPartsArray(targetChar) or {{ [1] = "HumanoidRootPart", [2] = 1 }}
                        
                        local targetPos = targetData.Root.Position
                        local direction = (localPos - targetPos).Unit 
                        
                        local args = {
                            [1] = "damage",
                            [2] = {
                                ["bodyParts"] = bodyPartsArr,
                                ["shotCode"] = {
                                    [1] = targetPos, 
                                    [2] = direction 
                                },
                                ["target"] = targetData.Player,
                                ["pos"] = localPos 
                            }
                        }

                        pcall(function() Remote:FireServer(unpack(args)) end)
                    end)
                end
                
                ManageMultiHighlight(activeChars, State.MeleeHighlights, Color3.fromRGB(255, 0, 0))
            else
                ManageMultiHighlight({}, State.MeleeHighlights)
            end
        end
        ClearHighlights(State.MeleeHighlights)
        State.MeleeThread = nil
    end)
end

-- ==========================================
-- [远程战斗逻辑]
-- ==========================================
local function GetEquippedWeaponName()
    local char = LocalPlayer.Character
    if not char then return "Unarmed" end
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Tool") then return item.Name end
    end
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Model") and item:FindFirstChild("Handle") then return item.Name end
    end
    return "Unarmed"
end

local function GetBarrelPos(char)
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Tool") then
            local barrel = item:FindFirstChild("Barrel") or item:FindFirstChild("Handle")
            if barrel then return barrel.Position end
        end
    end
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Model") and item:FindFirstChild("Handle") then 
            local barrel = item:FindFirstChild("Barrel") or item:FindFirstChild("Handle")
            if barrel then return barrel.Position end
        end
    end
    return char.HumanoidRootPart.Position
end

function StartRangedLoop()
    if State.RangedThread then task.cancel(State.RangedThread) end
    State.RangedThread = task.spawn(function()
        while Config.Ranged_Enabled do
            if Config.Ranged_NoCooldown then
                RunService.Heartbeat:Wait()
            else
                task.wait(0.1)
            end
            
            local Remote = FetchRemote()
            if not Remote then task.wait(1) continue end
            
            local targets = GetValidTargets("Ranged")
            local localChar = LocalPlayer.Character
            
            if #targets > 0 and localChar and localChar:FindFirstChild("HumanoidRootPart") then
                local activeChars = {}
                
                for _, targetData in ipairs(targets) do
                    local targetChar = targetData.Char
                    table.insert(activeChars, targetChar)
                    
                    task.spawn(function()
                        local hitPartName = Config.Ranged_AutoHeadshot and "Head" or "HumanoidRootPart"
                        local hitPart = targetChar:FindFirstChild(hitPartName) or targetChar:FindFirstChild("HumanoidRootPart")
                        if not hitPart then return end
                        
                        local hitPos = hitPart.Position
                        local barrelPos = GetBarrelPos(localChar)
                        local direction = (hitPos - barrelPos).Unit
                        local shotCode = { barrelPos, direction }
                        local weaponName = GetEquippedWeaponName()
                        
                        local bulletCount = Config.Ranged_MultiBullet and 3 or 1
                        for i = 1, bulletCount do
                            local bulletArgs = {
                                [1] = "bullet",
                                [2] = {
                                    ["weaponName"] = weaponName,
                                    ["posDestroyX"] = hitPos.X + (i * 0.5), 
                                    ["pos"] = hitPos 
                                }
                            }
                            pcall(function() Remote:FireServer(unpack(bulletArgs)) end)
                        end
                        
                        local damageArgs = {
                            [1] = "damage",
                            [2] = {
                                ["bodyParts"] = { [1] = { [1] = hitPartName, [2] = 1 } },
                                ["shotCode"] = shotCode,
                                ["target"] = targetData.Player,
                                ["pos"] = hitPos
                            }
                        }
                        if Config.Ranged_AutoHeadshot then
                            damageArgs[2]["damageFactor"] = 1.5
                        end
                        
                        pcall(function() Remote:FireServer(unpack(damageArgs)) end)
                    end)
                end
                
                ManageMultiHighlight(activeChars, State.RangedHighlights, Color3.fromRGB(0, 0, 255))
            else
                ManageMultiHighlight({}, State.RangedHighlights)
            end
        end
        ClearHighlights(State.RangedHighlights)
        State.RangedThread = nil
    end)
end

-- ==========================================
-- [实用工具逻辑]
-- ==========================================

function ClearESP()
    for _, obj in pairs(State.ESPObjects) do
        if obj.Highlight then obj.Highlight:Destroy() end
        if obj.Billboard then obj.Billboard:Destroy() end
    end
    State.ESPObjects = {}
end

Players.PlayerRemoving:Connect(function(player)
    if State.ESPObjects[player] then
        State.ESPObjects[player].Highlight:Destroy()
        State.ESPObjects[player].Billboard:Destroy()
        State.ESPObjects[player] = nil
    end
end)

RunService.RenderStepped:Connect(function()
    if not Config.ESP_Enabled then return end
    
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local char = player.Character
            local obj = State.ESPObjects[player]

            if char and char:FindFirstChild("HumanoidRootPart") and char:FindFirstChild("Humanoid") and char.Humanoid.Health > 0 then
                if not obj then
                    obj = {}
                    obj.Highlight = Instance.new("Highlight")
                    obj.Highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
                    obj.Highlight.FillTransparency = 0.7
                    obj.Highlight.Parent = char

                    obj.Billboard = Instance.new("BillboardGui")
                    obj.Billboard.Size = UDim2.new(0, 200, 0, 30)
                    obj.Billboard.StudsOffset = Vector3.new(0, 3, 0)
                    obj.Billboard.AlwaysOnTop = true
                    obj.Billboard.Parent = char.HumanoidRootPart

                    local lbl = Instance.new("TextLabel", obj.Billboard)
                    lbl.Size = UDim2.new(1, 0, 1, 0)
                    lbl.BackgroundTransparency = 1
                    lbl.TextStrokeTransparency = 0
                    lbl.Font = Enum.Font.GothamBold
                    lbl.TextSize = 14
                    obj.Label = lbl
                    
                    State.ESPObjects[player] = obj
                end
                
                local teamColor = player.Team and player.Team.TeamColor.Color or Color3.fromRGB(255, 255, 255)
                obj.Highlight.FillColor = teamColor
                
                local lockText = ""
                local textColor = teamColor
                local isMeleeLocked = false
                local isRangedLocked = false

                for _, hl in pairs(State.MeleeHighlights) do
                    if hl.Parent == char then isMeleeLocked = true break end
                end
                for _, hl in pairs(State.RangedHighlights) do
                    if hl.Parent == char then isRangedLocked = true break end
                end

                if isMeleeLocked then
                    lockText = " [近战锁]"
                    textColor = Color3.fromRGB(255, 50, 50)
                    obj.Highlight.FillColor = Color3.fromRGB(255, 50, 50)
                elseif isRangedLocked then
                    lockText = " [远程锁]"
                    textColor = Color3.fromRGB(50, 150, 255)
                    obj.Highlight.FillColor = Color3.fromRGB(50, 150, 255)
                end
                
                obj.Label.TextColor3 = textColor
                obj.Label.Text = string.format("%s [%d/%d]%s", player.Name, math.floor(char.Humanoid.Health), char.Humanoid.MaxHealth, lockText)
            else
                if obj then
                    obj.Highlight:Destroy()
                    obj.Billboard:Destroy()
                    State.ESPObjects[player] = nil
                end
            end
        end
    end
end)

workspace.DescendantAdded:Connect(function(d)
    if Config.InstantInteract_Enabled and d:IsA("ProximityPrompt") then
        d.HoldDuration = 0
    end
end)

task.spawn(function()
    while true do
        if Config.InstantInteract_Enabled then
            for _, d in ipairs(workspace:GetDescendants()) do
                if d:IsA("ProximityPrompt") then
                    d.HoldDuration = 0
                end
            end
            task.wait(5)
        else
            task.wait(1)
        end
    end
end)

print("[KillSystem v10.1] 紧急修复版已加载。")
