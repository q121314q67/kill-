--[[
    杀戮系统 v10.28 [滑动侧栏与物品选择版]
    更新：
    1. 继承 v10.27 所有功能
    2. 侧栏改为ScrollingFrame可滑动容器，图标再多也不会溢出
    3. 新增单选框选择指定消耗物品（点击背包物品选择）
    4. 支持"自动识别消耗品"和"指定槽位消耗"两种模式
    5. 物品列表带刷新按钮，实时反映背包状态
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

-- 前置声明核心函数
local StartMeleeLoop, StartRangedLoop, ClearLockVisuals, ClearESP, HookWeaponConfig
local ClosePopup  -- 前置声明，供侧栏触发按钮回调使用
local DrawAttackLine, ClearAttackLines  -- 前置声明，供攻击循环与回调使用

-- 启动时强制清理可能残留的旧高亮实例
local function CleanupOrphanVisuals()
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Highlight") and (obj.Name == "KillSystem_MeleeLock" or obj.Name == "KillSystem_RangedLock") then
            obj:Destroy()
        end
    end
end
CleanupOrphanVisuals()

-- [全局统一配置]
local Config = {
    -- 近战
    Melee_Enabled = false,
    Melee_Range = 30,
    Melee_Delay = 0.03,
    Melee_HyperThread = false,
    Melee_MultiHit = true,
    Melee_ForceCombatMode = true,
    Melee_SelfAntiCombatMode = false,
    Melee_CheckFriends = false,
    Melee_CheckVisibility = false,
    Melee_TargetNPC = false,
    Melee_AutoPopTires = false,
    Melee_AllowedTeams = {},

    -- 远程
    Ranged_Enabled = false,
    Ranged_Range = 1000,
    Ranged_Delay = 0.05,
    Ranged_HyperThread = true,
    Ranged_AutoHeadshot = true,
    Ranged_MultiBullet = true,
    Ranged_WallBang = false,
    Ranged_CheckFriends = false,
    Ranged_CheckVisibility = false,
    Ranged_TargetNPC = false,
    Ranged_AutoPopTires = false,
    Ranged_NoRecoil = true,
    Ranged_AllowedTeams = {},

    -- 实用工具
    ESP_Enabled = false,
    InstantInteract_Enabled = false,
    Tool_InfiniteDurability = false,
    TestMode = false,

    -- 全图互动
    GlobalInteract_Enabled = false,

    -- 防御系统（基于反编译事件协议）
    NoKilledVisual_Enabled = false,      -- 反死亡视觉：禁用KilledColorCorrection
    AntiRagdoll_Enabled = false,         -- 反强制Ragdoll：拦截ragdoll事件
    FastGetUp_Enabled = false,           -- 快速起身：监控物理Ragdoll状态
    AntiEject_Enabled = false,           -- 反强制弹出：拦截eject事件后重新上车
    AntiCharHidden_Enabled = false,      -- 反强制隐藏：拦截characterHidden事件
    CleanLightingEffects_Enabled = false, -- 持续清理视觉效果

    -- 转向控制（基于charRot协议）
    AntiForceRotation_Enabled = false,   -- 反强制转向：用摄像机朝向覆盖charRot
    FaceLockedTarget_Enabled = false,    -- 面向锁定目标：锁定时强制面向目标

    -- 防弹衣穿透
    BypassBulletProof_Enabled = false,   -- 防弹衣穿透：damage事件发送bulletProofTool=false

    -- 战斗状态控制（独立分类）
    PermanentCombat_Enabled = false,    -- 永久战斗模式：每30秒发送combatMode,true
    PermanentAntiCombat_Enabled = false, -- 永久免战模式：事件驱动，检测战斗触发时发送一次false
    AutoEquipWeapon_Enabled = false,    -- 自动装备武器：攻击时检测未装备自动equipItem

    -- 攻击线绘制
    DrawMeleeLine_Enabled = false,      -- 近战攻击线：从玩家位置到目标位置
    DrawRangedLine_Enabled = false,     -- 远程攻击线：从枪口到命中位置

    -- 自动消耗物品（基于modifyInventory协议）
    AutoConsume_Enabled = false,        -- 自动消耗：周期性消耗背包物品
    AutoConsume_Delay = 2,              -- 消耗间隔（秒）
    AutoConsume_Count = 1,              -- 单次消耗数量
    AutoConsume_SelectedSlot = nil      -- 选中的消耗物品槽位（nil=自动识别消耗品）
}

-- [全局状态与回调中心]
local State = {
    RemoteEvent = nil,
    IsRemoteHooked = false,
    MeleeThreads = {},
    RangedThreads = {},
    AutoHideThread = nil,
    Shortcuts = {},
    ShortcutsByConfigKey = {},  -- 新增：按configKey索引快捷键，用于状态同步
    SideIcons = {},              -- 新增：侧栏图标引用，用于主题切换时同步颜色
    IsPlacingShortcut = false,
    CurrentActionToBind = nil,
    PlacementCapture = nil,     -- 新增：全屏捕获按钮引用
    CombatModeTick = 0,
    ESPObjects = {},
    VisualRegistry = { Melee = {}, Ranged = {} },
    Connections = {},
    AttackLines = {},  -- 新增：当前活跃的攻击线实例注册表，用于关闭时清理

    GlobalCallbacks = {
        Melee_Enabled = function(val)
            if val then StartMeleeLoop() else
                for _, t in ipairs(State.MeleeThreads) do pcall(task.cancel, t) end
                State.MeleeThreads = {}
                ClearLockVisuals("KillSystem_MeleeLock")
            end
        end,
        Ranged_Enabled = function(val)
            if val then StartRangedLoop() else
                for _, t in ipairs(State.RangedThreads) do pcall(task.cancel, t) end
                State.RangedThreads = {}
                ClearLockVisuals("KillSystem_RangedLock")
            end
        end,
        TestMode = function(val) print("[System] 测试开关状态改变 ->", val) end,
        ESP_Enabled = function(val) if not val then ClearESP() end end,
        DrawMeleeLine_Enabled = function(val) if not val then ClearAttackLines() end end,
        DrawRangedLine_Enabled = function(val) if not val then ClearAttackLines() end end,
        Ranged_NoRecoil = function(val)
            local char = LocalPlayer.Character
            if char then
                for _, tool in ipairs(char:GetChildren()) do
                    if tool:IsA("Tool") or (tool:IsA("Model") and tool:FindFirstChild("Handle")) then
                        HookWeaponConfig(tool)
                    end
                end
            end
        end
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

-- 修复：复用已存在的UIGradient，避免重复实例累积
local function ApplyGradient(guiObj)
    local grad = guiObj:FindFirstChildOfClass("UIGradient")
    if not grad then
        grad = Instance.new("UIGradient")
        grad.Parent = guiObj
    end
    grad.Color = ColorSequence.new(Theme.C1, Theme.C2)
    grad.Rotation = math.random(0, 360)
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "KillSystemUI_v10"
ScreenGui.ResetOnSpawn = false
ScreenGui.DisplayOrder = 999
pcall(function() ScreenGui.Parent = CoreGui end)
if not ScreenGui.Parent then ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local BlurEffect = Instance.new("BlurEffect")
BlurEffect.Name = "KillSystem_Blur"
BlurEffect.Size = 0
BlurEffect.Parent = Lighting

-- ==========================================
-- [原生协议Hook与武器系统]
-- ==========================================
function HookWeaponConfig(tool)
    if not tool then return end
    local cfgModule = tool:FindFirstChild("Config")
    if not cfgModule then return end

    local success, cfg = pcall(require, cfgModule)
    if success and cfg and cfg.GUN then
        if Config.Ranged_NoRecoil then
            cfg.RECOIL = 0
            cfg.TR_DIFF = 0
            cfg.ACCURACY = 0.001
        end
    end
end

LocalPlayer.CharacterAdded:Connect(function(char)
    char.ChildAdded:Connect(function(child)
        if child:IsA("Tool") or (child:IsA("Model") and child:FindFirstChild("Handle")) then
            task.wait(0.1)
            HookWeaponConfig(child)
        end
    end)
end)

task.spawn(function()
    local char = LocalPlayer.Character
    if char then
        for _, tool in ipairs(char:GetChildren()) do
            if tool:IsA("Tool") or (tool:IsA("Model") and tool:FindFirstChild("Handle")) then
                HookWeaponConfig(tool)
            end
        end
    end
end)

local function FetchRemote()
    if State.RemoteEvent then return State.RemoteEvent end
    local success, result = pcall(function() return ReplicatedStorage:WaitForChild("Remote", 3):WaitForChild("PlayerEvent", 3) end)
    if success and result then
        State.RemoteEvent = result
        return result
    end
    return nil
end

task.spawn(function()
    local remote = FetchRemote()
    if remote and not State.IsRemoteHooked then
        State.IsRemoteHooked = true
        local oldFireServer = remote.FireServer
        remote.FireServer = function(self, cmd, ...)
            if Config.Tool_InfiniteDurability and cmd == "degradeItem" then
                return
            end
            return oldFireServer(self, cmd, ...)
        end
    end
end)

-- Hook UnreliableEvent.FireServer：拦截charRot事件
-- 游戏每0.1秒发送charRot(Vector2)到服务器，用于同步角色朝向
-- 我们拦截后可以：1.用摄像机朝向覆盖（反强制转向）2.面向锁定目标
task.spawn(function()
    local success, unreliableRemote = pcall(function()
        return ReplicatedStorage:WaitForChild("Remote", 3):WaitForChild("UnreliableEvent", 3)
    end)
    if not success or not unreliableRemote then
        warn("[KillSystem] 未找到UnreliableEvent，charRot Hook未启动")
        return
    end

    local oldUnreliableFire = unreliableRemote.FireServer
    unreliableRemote.FireServer = function(self, cmd, ...)
        if cmd == "charRot" then
            local char = LocalPlayer.Character
            local camera = workspace.CurrentCamera

            -- 优先级1：面向锁定目标（当近战或远程锁定激活时）
            if Config.FaceLockedTarget_Enabled and char and char:FindFirstChild("HumanoidRootPart") then
                local localRoot = char.HumanoidRootPart
                local targetRoot = nil

                -- 检查近战锁定的目标
                if Config.Melee_Enabled then
                    for targetChar, _ in pairs(State.VisualRegistry.Melee) do
                        if targetChar and targetChar.Parent and targetChar:FindFirstChild("HumanoidRootPart") then
                            targetRoot = targetChar.HumanoidRootPart
                            break
                        end
                    end
                end

                -- 如果近战没锁定，检查远程锁定的目标
                if not targetRoot and Config.Ranged_Enabled then
                    for targetChar, _ in pairs(State.VisualRegistry.Ranged) do
                        if targetChar and targetChar.Parent and targetChar:FindFirstChild("HumanoidRootPart") then
                            targetRoot = targetChar.HumanoidRootPart
                            break
                        end
                    end
                end

                if targetRoot then
                    -- 计算朝向目标的方向向量（XZ平面）
                    local dir = (targetRoot.Position - localRoot.Position)
                    -- charRot是Vector2，根据反编译：SetAttribute("charRot", Vector2.new(X/100, Y/100))
                    -- 原始发送格式：Vector2.new(math.round(attr.X*100), math.round(attr.Y*100))
                    -- 所以服务器接收到的是放大100倍的值，存储时除以100
                    -- 这里我们直接构造方向向量并放大100倍
                    local rotX = math.clamp(dir.X * 100, -9999, 9999)
                    local rotZ = dir.Z * 100
                    -- 使用Vector2.new(X, Z)因为charRot的Y分量对应世界的Z轴（前后）
                    return oldUnreliableFire(self, "charRot", Vector2.new(math.round(rotX), math.round(rotZ)))
                end
            end

            -- 优先级2：反强制转向（用摄像机朝向覆盖）
            if Config.AntiForceRotation_Enabled and camera and char and char:FindFirstChild("HumanoidRootPart") then
                local localRoot = char.HumanoidRootPart
                -- 获取摄像机LookVector在XZ平面的投影
                local lookVec = camera.CFrame.LookVector
                -- 构造方向向量并放大100倍（与游戏原始格式一致）
                local rotX = math.round(lookVec.X * 100)
                local rotZ = math.round(lookVec.Z * 100)
                return oldUnreliableFire(self, "charRot", Vector2.new(rotX, rotZ))
            end
        end
        return oldUnreliableFire(self, cmd, ...)
    end
    print("[KillSystem] UnreliableEvent.charRot Hook 已启动")
end)

-- ==========================================
-- [UI 构建逻辑]
-- ==========================================
local SideBarTrigger = Instance.new("TextButton")
SideBarTrigger.Size = UDim2.new(0, 20, 0, 150)
SideBarTrigger.Position = UDim2.new(1, -5, 0.5, -75)
SideBarTrigger.BackgroundColor3 = Theme.Dark
SideBarTrigger.Text = ""
SideBarTrigger.Parent = ScreenGui
Instance.new("UICorner", SideBarTrigger).CornerRadius = UDim.new(0, 8)
ApplyGradient(SideBarTrigger)

local SideBar = Instance.new("ScrollingFrame")
SideBar.Size = UDim2.new(0, 80, 0, 350)
SideBar.Position = UDim2.new(1, 0, 0.5, -175)
SideBar.BackgroundColor3 = Theme.Darker
SideBar.ScrollBarThickness = 3
SideBar.ScrollBarImageColor3 = Theme.C1
SideBar.CanvasSize = UDim2.new(0, 0, 0, 0)
SideBar.AutomaticCanvasSize = Enum.AutomaticSize.Y
SideBar.ScrollingDirection = Enum.ScrollingDirection.Y
SideBar.Parent = ScreenGui
Instance.new("UICorner", SideBar).CornerRadius = UDim.new(0, 16)
local sbStroke = Instance.new("UIStroke", SideBar)
sbStroke.Thickness = 2
ApplyGradient(sbStroke)

local SideList = Instance.new("UIListLayout", SideBar)
SideList.Padding = UDim.new(0, 8)
SideList.HorizontalAlignment = Enum.HorizontalAlignment.Center
SideList.VerticalAlignment = Enum.VerticalAlignment.Top

local SidePad = Instance.new("UIPadding", SideBar)
SidePad.PaddingTop = UDim.new(0, 8)
SidePad.PaddingBottom = UDim.new(0, 8)

local isSideBarOut = false
local ActivePopup = nil

local function ToggleSideBar(show)
    isSideBarOut = show
    if show then
        TweenService:Create(SideBar, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Position = UDim2.new(1, -90, 0.5, -175)}):Play()
        if State.AutoHideThread then task.cancel(State.AutoHideThread) end
        State.AutoHideThread = task.delay(5, function()
            if isSideBarOut and not (ActivePopup and ActivePopup.Parent) then ToggleSideBar(false) end
        end)
    else
        TweenService:Create(SideBar, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Position = UDim2.new(1, 0, 0.5, -175)}):Play()
    end
end

-- 修复：弹窗打开时点击侧栏触发按钮应先关闭弹窗，避免UI状态混乱
SideBarTrigger.MouseButton1Click:Connect(function()
    if ActivePopup then ClosePopup() return end
    ToggleSideBar(not isSideBarOut)
end)

-- 修复：ClosePopup改为非yield，避免调用方时序问题；新增showSidebar参数控制是否回弹侧栏
ClosePopup = function(showSidebar)
    if not ActivePopup then return end
    local pop = ActivePopup
    ActivePopup = nil
    TweenService:Create(pop, TweenInfo.new(0.2), {Size = UDim2.new(0, 0, 0, 0)}):Play()
    TweenService:Create(BlurEffect, TweenInfo.new(0.2), {Size = 0}):Play()
    task.delay(0.2, function()
        if pop and pop.Parent then pop:Destroy() end
    end)
    if showSidebar ~= false then
        ToggleSideBar(true)
    end
end

-- 修复：快捷键放置函数，统一管理快捷键创建与注册
local function PlaceShortcutAt(pos, key, iconText)
    local shortcut = Instance.new("TextButton")
    shortcut.Size = UDim2.new(0, 50, 0, 50)
    shortcut.Position = UDim2.new(0, pos.X - 25, 0, pos.Y - 25)
    shortcut.BackgroundColor3 = Theme.Darker
    shortcut.BackgroundTransparency = Config[key] and 0.2 or 0.5
    shortcut.Text = iconText or "⚡"
    shortcut.TextColor3 = Theme.C1
    shortcut.Font = Enum.Font.GothamBold
    shortcut.TextSize = 20
    shortcut.Parent = ScreenGui
    Instance.new("UICorner", shortcut).CornerRadius = UDim.new(1, 0)
    shortcut:SetAttribute("ConfigKey", key)
    table.insert(State.Shortcuts, shortcut)
    if not State.ShortcutsByConfigKey[key] then State.ShortcutsByConfigKey[key] = {} end
    table.insert(State.ShortcutsByConfigKey[key], shortcut)

    local isPressing = false
    local isDragging = false
    local pressTime = 0
    local dragStartPos = nil
    local startUdimPos = nil

    shortcut.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            isPressing = true
            isDragging = false
            pressTime = tick()
            dragStartPos = inp.Position
            startUdimPos = shortcut.Position
        end
    end)

    shortcut.InputChanged:Connect(function(inp)
        if isPressing and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
            if dragStartPos and (inp.Position - dragStartPos).Magnitude > 15 then
                isDragging = true
                local dx = inp.Position.X - dragStartPos.X
                local dy = inp.Position.Y - dragStartPos.Y
                shortcut.Position = UDim2.new(startUdimPos.X.Scale, startUdimPos.X.Offset + dx, startUdimPos.Y.Scale, startUdimPos.Y.Offset + dy)
            end
        end
    end)

    shortcut.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            if not isPressing then return end
            isPressing = false

            local duration = tick() - pressTime
            -- 修复：检查总位移而非isDragging标志，避免轻微移动后isDragging卡true导致切换失效
            local totalDisplacement = dragStartPos and (inp.Position - dragStartPos).Magnitude or 0
            local isClick = totalDisplacement < 15

            if isClick then
                if duration >= 0.8 then
                    -- 长按删除
                    local k = shortcut:GetAttribute("ConfigKey")
                    shortcut:Destroy()
                    for i, sc in ipairs(State.Shortcuts) do if sc == shortcut then table.remove(State.Shortcuts, i) break end end
                    if k and State.ShortcutsByConfigKey[k] then
                        for i, sc in ipairs(State.ShortcutsByConfigKey[k]) do if sc == shortcut then table.remove(State.ShortcutsByConfigKey[k], i) break end end
                    end
                else
                    -- 短按切换
                    if ActivePopup then ClosePopup(false) end
                    Config[key] = not Config[key]
                    if State.GlobalCallbacks[key] then State.GlobalCallbacks[key](Config[key]) end
                    shortcut.BackgroundTransparency = Config[key] and 0.2 or 0.5
                end
            end
            -- 重置isDragging，防止下次点击继承上次状态
            isDragging = false
        end
    end)
end

-- 修复：快捷键放置模式改用全屏捕获按钮，避免点击穿透；增加视觉提示与ESC取消
local function StartPlacementMode(configKey, iconText)
    State.IsPlacingShortcut = true
    State.CurrentActionToBind = { configKey = configKey, icon = iconText }

    local capture = Instance.new("TextButton")
    capture.Size = UDim2.new(1, 0, 1, 0)
    capture.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    capture.BackgroundTransparency = 0.6
    capture.Text = "点击屏幕任意位置放置快捷键（ESC取消）"
    capture.TextColor3 = Color3.fromRGB(255, 255, 255)
    capture.TextStrokeTransparency = 0
    capture.Font = Enum.Font.GothamBold
    capture.TextSize = 22
    capture.ZIndex = 100
    capture.AutoButtonColor = false
    capture.Parent = ScreenGui
    State.PlacementCapture = capture

    capture.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            local pos = input.Position
            local bindAction = State.CurrentActionToBind
            State.IsPlacingShortcut = false
            State.CurrentActionToBind = nil
            State.PlacementCapture = nil
            capture:Destroy()
            if bindAction then
                PlaceShortcutAt(pos, bindAction.configKey, bindAction.icon)
            end
            ToggleSideBar(true)
        end
    end)
end

-- ESC取消放置模式
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if State.IsPlacingShortcut and input.KeyCode == Enum.KeyCode.Escape then
        State.IsPlacingShortcut = false
        State.CurrentActionToBind = nil
        if State.PlacementCapture then
            State.PlacementCapture:Destroy()
            State.PlacementCapture = nil
        end
        ToggleSideBar(true)
    end
end)

local function OpenPopup(TitleText, BuildContentFunc)
    -- 修复：打开弹窗时取消侧栏自动隐藏线程，避免无用残留
    if State.AutoHideThread then task.cancel(State.AutoHideThread) State.AutoHideThread = nil end
    if ActivePopup then ClosePopup(false) end
    Theme = GenerateNeonTheme()
    ToggleSideBar(false)

    SideBar.BackgroundColor3 = Theme.Darker
    ApplyGradient(sbStroke)
    ApplyGradient(SideBarTrigger)

    -- 修复：同步侧栏图标颜色至新主题
    for _, icon in ipairs(State.SideIcons) do
        icon.BackgroundColor3 = Theme.Dark
        icon.TextColor3 = Theme.C1
        for _, child in ipairs(icon:GetChildren()) do
            if child:IsA("UIStroke") then
                ApplyGradient(child)
            end
        end
    end

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
    CloseBtn.MouseButton1Click:Connect(function() ClosePopup() end)

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

local function CreateRow(parent, height)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, height)
    row.BackgroundColor3 = Theme.Darker
    row.Parent = parent
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)
    return row
end

-- 修复：CreateToggle增加wasLongPress标志，避免长按设置快捷键后误触开关切换；增加快捷键透明度同步
local function CreateToggle(parent, name, configKey, icon)
    local row = CreateRow(parent, 40)
    local state = Config[configKey]
    local wasLongPress = false

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

    local function SyncShortcuts()
        local shortcuts = State.ShortcutsByConfigKey[configKey]
        if shortcuts then
            for _, sc in ipairs(shortcuts) do
                sc.BackgroundTransparency = state and 0.2 or 0.5
            end
        end
    end

    local function ToggleState()
        -- 修复：如果是长按触发的释放，不切换状态
        if wasLongPress then
            wasLongPress = false
            return
        end
        state = not state
        Config[configKey] = state
        UpdateVisual()
        SyncShortcuts()  -- 修复：同步快捷键透明度
        if State.GlobalCallbacks[configKey] then State.GlobalCallbacks[configKey](state) end
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
                        -- 修复：检查弹窗是否仍然有效（防止弹窗已关闭后误触发）
                        if not ActivePopup or not ActivePopup.Parent then return end
                        wasLongPress = true
                        ClosePopup(false)
                        ToggleSideBar(false)
                        StartPlacementMode(configKey, icon)
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

local function CreateSlider(parent, name, minVal, maxVal, default, configKey, isFloat)
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
    valLabel.Text = isFloat and string.format("%.2f", default) or tostring(default)
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
        local val = isFloat and (minVal + (maxVal - minVal) * rel) or math.floor(minVal + (maxVal - minVal) * rel)
        fill.Size = UDim2.new(rel, 0, 1, 0)
        valLabel.Text = isFloat and string.format("%.2f", val) or tostring(val)
        Config[configKey] = val
    end

    barBg.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            update(input.Position)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then update(input.Position) end
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
        for _, child in ipairs(listContainer:GetChildren()) do if child:IsA("TextButton") then child:Destroy() end end
        local teams = getOptionsFunc()
        if #selectedTable == 0 then for _, team in ipairs(teams) do table.insert(selectedTable, team.Name) end end
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
            if table.find(selectedTable, team.Name) ~= nil then tBtn.BackgroundColor3 = Theme.C1 end
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

local function CreateSideIcon(iconText, openFunc)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 48, 0, 48)
    btn.BackgroundColor3 = Theme.Dark
    btn.Text = iconText
    btn.TextColor3 = Theme.C1
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 24
    btn.Parent = SideBar
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0.5, 0)
    local stroke = Instance.new("UIStroke", btn)
    stroke.Thickness = 2
    ApplyGradient(stroke)
    btn.MouseButton1Click:Connect(openFunc)
    table.insert(State.SideIcons, btn)  -- 新增：注册图标引用
    return btn
end

CreateSideIcon("⚔️", function()
    OpenPopup("近战杀戮", function(holder)
        CreateSlider(holder, "发包延迟 (0=极速)", 0, 1, Config.Melee_Delay, "Melee_Delay", true)
        CreateSlider(holder, "攻击范围", 5, 1000, Config.Melee_Range, "Melee_Range", false)
        CreateToggle(holder, "自动攻击", "Melee_Enabled", "⚔️")
        CreateToggle(holder, "高度多线程", "Melee_HyperThread", "🚀")
        CreateToggle(holder, "多部位打击", "Melee_MultiHit", "🎯")
        CreateToggle(holder, "防弹衣穿透", "BypassBulletProof_Enabled", "🦺")
        CreateToggle(holder, "强制战斗模式", "Melee_ForceCombatMode", "🔥")
        CreateToggle(holder, "自身免战斗模式", "Melee_SelfAntiCombatMode", "🛡️")
        CreateToggle(holder, "瞄准 NPC", "Melee_TargetNPC", "👾")
        CreateToggle(holder, "自动爆胎模式", "Melee_AutoPopTires", "🛞")
        CreateToggle(holder, "好友检测", "Melee_CheckFriends", "🤝")
        CreateToggle(holder, "可见性检测", "Melee_CheckVisibility", "👁️")
        local function GetTeams() local t = {} for _, team in ipairs(game:GetService("Teams"):GetTeams()) do table.insert(t, team) end return t end
        CreateMultiSelectList(holder, "队伍选择检测", GetTeams, "Melee_AllowedTeams", function(sel) end)
    end)
end)

CreateSideIcon("🔫", function()
    OpenPopup("远程杀戮", function(holder)
        CreateSlider(holder, "发包延迟 (0=极速)", 0, 1, Config.Ranged_Delay, "Ranged_Delay", true)
        CreateSlider(holder, "攻击范围", 100, 5000, Config.Ranged_Range, "Ranged_Range", false)
        CreateToggle(holder, "自动枪锁", "Ranged_Enabled", "🔫")
        CreateToggle(holder, "高度多线程", "Ranged_HyperThread", "🚀")
        CreateToggle(holder, "仅爆头(1.5倍率)", "Ranged_AutoHeadshot", "🧠")
        CreateToggle(holder, "散弹多发模拟", "Ranged_MultiBullet", "💥")
        CreateToggle(holder, "子弹穿墙", "Ranged_WallBang", "🧱")
        CreateToggle(holder, "瞄准 NPC", "Ranged_TargetNPC", "👾")
        CreateToggle(holder, "自动爆胎模式", "Ranged_AutoPopTires", "🛞")
        CreateToggle(holder, "激光无后座/无散射", "Ranged_NoRecoil", "🎯")
        CreateToggle(holder, "防弹衣穿透", "BypassBulletProof_Enabled", "🦺")
        CreateToggle(holder, "好友检测", "Ranged_CheckFriends", "🤝")
        CreateToggle(holder, "可见性检测", "Ranged_CheckVisibility", "👁️")
        local function GetTeams() local t = {} for _, team in ipairs(game:GetService("Teams"):GetTeams()) do table.insert(t, team) end return t end
        CreateMultiSelectList(holder, "队伍选择检测", GetTeams, "Ranged_AllowedTeams", function(sel) end)
    end)
end)

CreateSideIcon("👁️", function()
    OpenPopup("实用工具", function(holder)
        CreateToggle(holder, "玩家透视", "ESP_Enabled", "👻")
        CreateToggle(holder, "秒互动(防按住)", "InstantInteract_Enabled", "⚡")
        CreateToggle(holder, "工具无限耐久", "Tool_InfiniteDurability", "♾️")
        CreateToggle(holder, "全图超距互动", "GlobalInteract_Enabled", "🌐")
        CreateToggle(holder, "持续清理视觉效果", "CleanLightingEffects_Enabled", "✨")
        CreateToggle(holder, "近战攻击线", "DrawMeleeLine_Enabled", "📏")
        CreateToggle(holder, "远程攻击线", "DrawRangedLine_Enabled", "📐")
    end)
end)

CreateSideIcon("🛡️", function()
    OpenPopup("防御系统", function(holder)
        CreateToggle(holder, "反死亡视觉", "NoKilledVisual_Enabled", "💀")
        CreateToggle(holder, "反强制Ragdoll", "AntiRagdoll_Enabled", "🤸")
        CreateToggle(holder, "快速起身", "FastGetUp_Enabled", "⬆️")
        CreateToggle(holder, "反强制弹出", "AntiEject_Enabled", "🚗")
        CreateToggle(holder, "反强制隐藏", "AntiCharHidden_Enabled", "👁️")
        CreateToggle(holder, "反强制转向", "AntiForceRotation_Enabled", "🔄")
        CreateToggle(holder, "面向锁定目标", "FaceLockedTarget_Enabled", "🎯")
    end)
end)

CreateSideIcon("🔥", function()
    OpenPopup("战斗状态控制", function(holder)
        CreateToggle(holder, "永久战斗模式", "PermanentCombat_Enabled", "⚔️")
        CreateToggle(holder, "永久免战模式", "PermanentAntiCombat_Enabled", "🕊️")
        CreateToggle(holder, "自动装备武器", "AutoEquipWeapon_Enabled", "🎒")
    end)
end)

CreateSideIcon("🍎", function()
    OpenPopup("自动消耗", function(holder)
        CreateSlider(holder, "消耗间隔（秒）", 0.5, 30, Config.AutoConsume_Delay, "AutoConsume_Delay", true)
        CreateSlider(holder, "单次消耗数量", 1, 10, Config.AutoConsume_Count, "AutoConsume_Count", false)
        CreateToggle(holder, "自动消耗物品", "AutoConsume_Enabled", "🔄")

        -- 物品选择列表（单选）
        local selectRow = CreateRow(holder, 40)
        local selectLabel = Instance.new("TextLabel")
        selectLabel.Size = UDim2.new(1, -20, 0, 40)
        selectLabel.Position = UDim2.new(0, 15, 0, 0)
        selectLabel.BackgroundTransparency = 1
        selectLabel.Text = "选择消耗物品（点击选择）"
        selectLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
        selectLabel.TextXAlignment = Enum.TextXAlignment.Left
        selectLabel.Font = Enum.Font.Gotham
        selectLabel.TextSize = 14
        selectLabel.Parent = selectRow

        -- 刷新按钮
        local refreshBtn = Instance.new("TextButton")
        refreshBtn.Size = UDim2.new(0, 80, 0, 30)
        refreshBtn.Position = UDim2.new(1, -90, 0, 5)
        refreshBtn.BackgroundColor3 = Theme.Dark
        refreshBtn.Text = "刷新列表"
        refreshBtn.TextColor3 = Theme.C1
        refreshBtn.Font = Enum.Font.GothamBold
        refreshBtn.TextSize = 12
        refreshBtn.Parent = selectRow
        Instance.new("UICorner", refreshBtn).CornerRadius = UDim.new(1, 0)

        -- 物品列表容器
        local itemsContainer = Instance.new("Frame")
        itemsContainer.Size = UDim2.new(1, 0, 0, 0)
        itemsContainer.BackgroundTransparency = 1
        itemsContainer.Parent = holder
        local itemsLayout = Instance.new("UIListLayout", itemsContainer)
        itemsLayout.Padding = UDim.new(0, 5)
        itemsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

        local selectedItemLabel = Instance.new("TextLabel")
        selectedItemLabel.Size = UDim2.new(1, -20, 0, 25)
        selectedItemLabel.BackgroundTransparency = 1
        selectedItemLabel.TextColor3 = Theme.C1
        selectedItemLabel.TextXAlignment = Enum.TextXAlignment.Left
        selectedItemLabel.Font = Enum.Font.GothamMedium
        selectedItemLabel.TextSize = 12
        selectedItemLabel.Text = Config.AutoConsume_SelectedSlot and string.format("当前选中: 槽位 %d", Config.AutoConsume_SelectedSlot) or "当前选中: 自动识别消耗品"
        selectedItemLabel.Parent = itemsContainer

        local function RebuildItemList()
            -- 清除旧的物品按钮（保留标签）
            for _, child in ipairs(itemsContainer:GetChildren()) do
                if child:IsA("TextButton") then child:Destroy() end
            end

            -- 添加"自动识别"选项
            local autoBtn = Instance.new("TextButton")
            autoBtn.Size = UDim2.new(1, -20, 0, 30)
            autoBtn.BackgroundColor3 = (Config.AutoConsume_SelectedSlot == nil) and Theme.C1 or Theme.Dark
            autoBtn.Text = "自动识别消耗品"
            autoBtn.TextColor3 = Color3.fromRGB(230, 230, 230)
            autoBtn.Font = Enum.Font.GothamMedium
            autoBtn.TextSize = 12
            autoBtn.Parent = itemsContainer
            Instance.new("UICorner", autoBtn).CornerRadius = UDim.new(1, 0)
            autoBtn.MouseButton1Click:Connect(function()
                Config.AutoConsume_SelectedSlot = nil
                selectedItemLabel.Text = "当前选中: 自动识别消耗品"
                RebuildItemList()
            end)

            -- 扫描背包物品
            local slots = GetInventorySlots()
            for _, slotData in ipairs(slots) do
                local itemBtn = Instance.new("TextButton")
                itemBtn.Size = UDim2.new(1, -20, 0, 30)
                itemBtn.BackgroundColor3 = (Config.AutoConsume_SelectedSlot == slotData.id) and Theme.C1 or Theme.Dark
                itemBtn.Text = string.format("[%d] %s", slotData.id, slotData.name)
                itemBtn.TextColor3 = Color3.fromRGB(230, 230, 230)
                itemBtn.Font = Enum.Font.GothamMedium
                itemBtn.TextSize = 12
                itemBtn.Parent = itemsContainer
                Instance.new("UICorner", itemBtn).CornerRadius = UDim.new(1, 0)
                itemBtn.MouseButton1Click:Connect(function()
                    Config.AutoConsume_SelectedSlot = slotData.id
                    selectedItemLabel.Text = string.format("当前选中: 槽位 %d (%s)", slotData.id, slotData.name)
                    RebuildItemList()
                end)
            end
        end

        refreshBtn.MouseButton1Click:Connect(RebuildItemList)
        RebuildItemList()
    end)
end)

CreateSideIcon("⚙️", function()
    OpenPopup("设置", function(holder)
        CreateToggle(holder, "测试开关", "TestMode", "🧪")
    end)
end)

-- ==========================================
-- [核心视觉清理系统 - 深度扫描版]
-- ==========================================
function ClearLockVisuals(lockName)
    local mode = lockName == "KillSystem_MeleeLock" and "Melee" or "Ranged"
    local registry = State.VisualRegistry[mode]

    for char, hl in pairs(registry) do
        if hl then pcall(function() hl:Destroy() end) end
    end
    State.VisualRegistry[mode] = {}

    local function deepClean(parent)
        if not parent then return end
        for _, obj in ipairs(parent:GetDescendants()) do
            if obj:IsA("Highlight") and obj.Name == lockName then
                obj:Destroy()
            end
        end
    end
    pcall(deepClean, workspace)
    pcall(deepClean, Players)
end

local function SyncLockVisuals(activeChars, mode, lockName, color)
    -- 安全状态锁1：如果对应功能已被关闭，强行中断
    if not Config[mode .. "_Enabled"] then return end

    local registry = State.VisualRegistry[mode]
    local activeMap = {}

    for _, char in ipairs(activeChars) do
        if char and char.Parent then
            activeMap[char] = true
            if not registry[char] then
                -- 安全状态锁2：防止多线程并发在关闭瞬间强行创建
                if not Config[mode .. "_Enabled"] then return end
                local newHl = Instance.new("Highlight")
                newHl.Name = lockName
                newHl.FillColor = color
                newHl.OutlineColor = Color3.fromRGB(255, 255, 255)
                newHl.FillTransparency = 0.5
                newHl.Parent = char
                registry[char] = newHl
            end
        end
    end

    for char, hl in pairs(registry) do
        if not activeMap[char] or not char.Parent or not hl.Parent then
            if hl and hl.Parent then hl:Destroy() end
            registry[char] = nil
        end
    end
end

-- ==========================================
-- [核心公共逻辑：NPC与轮胎缓存扫描]
-- ==========================================
local npcCache = {}
local lastNpcScanTime = 0
local tireCache = {}
local lastTireScanTime = 0

local function UpdateNPCCache()
    if tick() - lastNpcScanTime < 0.5 then return end
    lastNpcScanTime = tick()
    table.clear(npcCache)
    for _, desc in ipairs(workspace:GetDescendants()) do
        if desc:IsA("Model") and not Players:GetPlayerFromCharacter(desc) then
            local hum = desc:FindFirstChildOfClass("Humanoid")
            local root = desc:FindFirstChild("HumanoidRootPart")
            if hum and root then
                table.insert(npcCache, {Char = desc, Humanoid = hum, Root = root})
            end
        end
    end
end

local function UpdateTireCache()
    if tick() - lastTireScanTime < 1 then return end
    lastTireScanTime = tick()
    table.clear(tireCache)
    local vehicles = workspace:FindFirstChild("Gameplay") and workspace.Gameplay:FindFirstChild("Vehicles")
    if vehicles then
        for _, car in ipairs(vehicles:GetChildren()) do
            for _, desc in ipairs(car:GetDescendants()) do
                if desc.Name == "WheelCollision" and not desc:GetAttribute("DontPuncture") then
                    table.insert(tireCache, desc)
                end
            end
        end
    end
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
    local targetNPC = Config[mode .. "_TargetNPC"]

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            if #allowedTeams > 0 and (not player.Team or not table.find(allowedTeams, player.Team.Name)) then continue end
            if checkFriends and LocalPlayer:IsFriendsWith(player.UserId) then continue end

            local targetChar = player.Character
            if targetChar and targetChar:FindFirstChild("HumanoidRootPart") and targetChar:FindFirstChild("Humanoid") and targetChar.Humanoid.Health > 0 then
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
                        table.insert(validTargets, {Player = player, Dist = dist, Char = targetChar, Root = targetRoot, IsNPC = false})
                    end
                end
            end
        end
    end

    if targetNPC then
        UpdateNPCCache()
        for _, npcData in ipairs(npcCache) do
            if npcData.Char ~= localChar and npcData.Humanoid.Health > 0 then
                local dist = (npcData.Root.Position - localRoot.Position).Magnitude
                if dist <= range then
                    local isVisible = true
                    if checkVis then
                        local params = RaycastParams.new()
                        params.FilterDescendantsInstances = {localChar}
                        params.FilterType = Enum.RaycastFilterType.Exclude
                        local hit = workspace:Raycast(localRoot.Position, (npcData.Root.Position - localRoot.Position), params)
                        if hit and not hit.Instance:IsDescendantOf(npcData.Char) then isVisible = false end
                    end
                    if isVisible then
                        table.insert(validTargets, {Player = {Name = npcData.Char.Name, UserId = 0}, Dist = dist, Char = npcData.Char, Root = npcData.Root, IsNPC = true})
                    end
                end
            end
        end
    end

    table.sort(validTargets, function(a, b) return a.Dist < b.Dist end)
    return validTargets
end

local function GetValidTires(rangeVal)
    local localChar = LocalPlayer.Character
    if not localChar or not localChar:FindFirstChild("HumanoidRootPart") then return {} end
    local localRoot = localChar.HumanoidRootPart
    local range = rangeVal
    local validTires = {}

    UpdateTireCache()
    for _, tire in ipairs(tireCache) do
        if tire.Parent and tire:GetAttribute("Durability") ~= 0 then
            local dist = (tire.Position - localRoot.Position).Magnitude
            if dist <= range then
                table.insert(validTires, {Tire = tire, Dist = dist, Pos = tire.Position})
            end
        end
    end
    table.sort(validTires, function(a, b) return a.Dist < b.Dist end)
    return validTires
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
    for _, t in ipairs(State.MeleeThreads) do pcall(task.cancel, t) end
    State.MeleeThreads = {}

    local threadCount = Config.Melee_HyperThread and 3 or 1

    for i = 1, threadCount do
        local t = task.spawn(function()
            while Config.Melee_Enabled do
                task.wait(Config.Melee_Delay > 0 and Config.Melee_Delay or 0.016)

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
                local activeChars = {}

                if #targets > 0 and localChar and localChar:FindFirstChild("HumanoidRootPart") then
                    local localRoot = localChar.HumanoidRootPart
                    local localPos = localRoot.Position

                    for _, targetData in ipairs(targets) do
                        local targetChar = targetData.Char
                        table.insert(activeChars, targetChar)

                        task.spawn(function()
                            local bodyPartsArr = Config.Melee_MultiHit and GetBodyPartsArray(targetChar) or {{ [1] = "HumanoidRootPart", [2] = 1 }}
                            local targetPos = targetData.Root.Position
                            -- 修复：shotCode[1]应为攻击者位置(localPos)，shotCode[2]应为朝目标方向，pos应为命中位置(targetPos)
                            -- 根据抓包：shotCode[1]=攻击者坐标，shotCode[2]=(targetPos-localPos).Unit，pos=命中坐标
                            local args = {
                                [1] = "damage",
                                [2] = {
                                    ["bodyParts"] = bodyPartsArr,
                                    ["shotCode"] = { [1] = localPos, [2] = (targetPos - localPos).Unit },
                                    ["target"] = targetData.Player,
                                    ["pos"] = targetPos
                                }
                            }
                            -- 防弹衣穿透：发送bulletProofTool=false绕过防弹背心减伤
                            if Config.BypassBulletProof_Enabled then
                                args[2].bulletProofTool = false
                            end
                            pcall(function() Remote:FireServer(unpack(args)) end)
                            -- 近战攻击线绘制：从玩家位置到目标位置，红色
                            if Config.DrawMeleeLine_Enabled then
                                pcall(function() DrawAttackLine(localPos, targetPos, Color3.fromRGB(255, 50, 50), 0.15) end)
                            end
                        end)
                    end
                end

                if Config.Melee_AutoPopTires then
                    local tires = GetValidTires(Config.Melee_Range)
                    for _, tireData in ipairs(tires) do
                        task.spawn(function()
                            if not localChar or not localChar:FindFirstChild("HumanoidRootPart") then return end
                            local localPos = localChar.HumanoidRootPart.Position
                            local shotCode = { localPos, (tireData.Pos - localPos).Unit }
                            pcall(function()
                                Remote:FireServer("damage", { shotCode = shotCode, pos = tireData.Pos, targetTire = tireData.Tire })
                            end)
                        end)
                    end
                end

                if i == 1 then
                    SyncLockVisuals(activeChars, "Melee", "KillSystem_MeleeLock", Color3.fromRGB(255, 0, 0))
                end
            end
        end)
        table.insert(State.MeleeThreads, t)
    end
end

-- ==========================================
-- [远程战斗逻辑]
-- ==========================================
local function GetEquippedWeaponName()
    local char = LocalPlayer.Character
    if not char then return "Unarmed" end
    for _, item in ipairs(char:GetChildren()) do if item:IsA("Tool") then return item.Name end end
    for _, item in ipairs(char:GetChildren()) do if item:IsA("Model") and item:FindFirstChild("Handle") then return item.Name end end
    return "Unarmed"
end

local function GetBarrelPos(char)
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Tool") then local barrel = item:FindFirstChild("Barrel") or item:FindFirstChild("Handle") if barrel then return barrel.Position end end
    end
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Model") and item:FindFirstChild("Handle") then local barrel = item:FindFirstChild("Barrel") or item:FindFirstChild("Handle") if barrel then return barrel.Position end end
    end
    return char.HumanoidRootPart.Position
end

function StartRangedLoop()
    for _, t in ipairs(State.RangedThreads) do pcall(task.cancel, t) end
    State.RangedThreads = {}

    local threadCount = Config.Ranged_HyperThread and 3 or 1

    for i = 1, threadCount do
        local t = task.spawn(function()
            while Config.Ranged_Enabled do
                task.wait(Config.Ranged_Delay > 0 and Config.Ranged_Delay or 0.016)

                local Remote = FetchRemote()
                if not Remote then task.wait(1) continue end

                local targets = GetValidTargets("Ranged")
                local localChar = LocalPlayer.Character
                local activeChars = {}

                if Config.Ranged_AutoPopTires then
                    local tires = GetValidTires(Config.Ranged_Range)
                    for _, tireData in ipairs(tires) do
                        task.spawn(function()
                            if not localChar or not localChar:FindFirstChild("HumanoidRootPart") then return end
                            local barrelPos = GetBarrelPos(localChar)
                            local shotCode = { barrelPos, (tireData.Pos - barrelPos).Unit }
                            pcall(function()
                                Remote:FireServer("damage", { shotCode = shotCode, pos = tireData.Pos, targetTire = tireData.Tire })
                            end)
                        end)
                    end
                end

                if #targets > 0 and localChar and localChar:FindFirstChild("HumanoidRootPart") then
                    for _, targetData in ipairs(targets) do
                        local targetChar = targetData.Char
                        table.insert(activeChars, targetChar)

                        task.spawn(function()
                            local hitPartName = Config.Ranged_AutoHeadshot and "Head" or "HumanoidRootPart"
                            local hitPart = targetChar:FindFirstChild(hitPartName) or targetChar:FindFirstChild("HumanoidRootPart")
                            if not hitPart then return end

                            local hitPos = hitPart.Position
                            local barrelPos = GetBarrelPos(localChar)
                            local shotCode = { barrelPos, (hitPos - barrelPos).Unit }
                            local weaponName = GetEquippedWeaponName()

                            for i = 1, (Config.Ranged_MultiBullet and 3 or 1) do
                                pcall(function() Remote:FireServer("bullet", { weaponName = weaponName, posDestroyX = hitPos.X + (i * 0.5), pos = hitPos }) end)
                            end

                            local damageArgs = {
                                [1] = "damage",
                                [2] = { bodyParts = { [1] = { [1] = hitPartName, [2] = 1 } }, shotCode = shotCode, target = targetData.Player, pos = hitPos }
                            }
                            if Config.Ranged_AutoHeadshot then damageArgs[2].damageFactor = 1.5 end
                            -- 防弹衣穿透：发送bulletProofTool=false绕过防弹背心减伤
                            if Config.BypassBulletProof_Enabled then
                                damageArgs[2].bulletProofTool = false
                            end
                            pcall(function() Remote:FireServer(unpack(damageArgs)) end)
                            -- 远程攻击线绘制：从枪口位置到命中位置，蓝色
                            if Config.DrawRangedLine_Enabled then
                                pcall(function() DrawAttackLine(barrelPos, hitPos, Color3.fromRGB(50, 150, 255), 0.2) end)
                            end
                        end)
                    end
                end

                if i == 1 then
                    SyncLockVisuals(activeChars, "Ranged", "KillSystem_RangedLock", Color3.fromRGB(0, 0, 255))
                end
            end
        end)
        table.insert(State.RangedThreads, t)
    end
end

-- ==========================================
-- [ESP与实用工具逻辑 - 兼容workspace.Characters]
-- ==========================================
function ClearESP()
    for char, obj in pairs(State.ESPObjects) do
        if obj.Highlight then obj.Highlight:Destroy() end
        if obj.Billboard then obj.Billboard:Destroy() end
    end
    State.ESPObjects = {}
end

local function UpdateESP()
    if not Config.ESP_Enabled then return end

    local drawnChars = {}
    local localChar = LocalPlayer.Character

    local function ApplyESP(char, name, teamColor)
        if char == localChar then return end
        if not char or not char.Parent then return end

        local root = char:FindFirstChild("HumanoidRootPart")
        local hum = char:FindFirstChildOfClass("Humanoid")
        if not root or not hum or hum.Health <= 0 then return end

        drawnChars[char] = true
        local obj = State.ESPObjects[char]

        local needRebuild = false
        if not obj then
            needRebuild = true
        else
            if not obj.Highlight or not obj.Highlight.Parent or obj.Highlight.Parent ~= char then needRebuild = true end
            if not obj.Billboard or not obj.Billboard.Parent or obj.Billboard.Parent ~= root then needRebuild = true end
        end

        if needRebuild then
            if obj then
                if obj.Highlight then pcall(function() obj.Highlight:Destroy() end) end
                if obj.Billboard then pcall(function() obj.Billboard:Destroy() end) end
            end
            obj = {}
            obj.Highlight = Instance.new("Highlight")
            obj.Highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
            obj.Highlight.FillTransparency = 0.7
            obj.Highlight.Parent = char

            obj.Billboard = Instance.new("BillboardGui")
            obj.Billboard.Size = UDim2.new(0, 200, 0, 30)
            obj.Billboard.StudsOffset = Vector3.new(0, 3, 0)
            obj.Billboard.AlwaysOnTop = true
            obj.Billboard.Parent = root

            local lbl = Instance.new("TextLabel", obj.Billboard)
            lbl.Size = UDim2.new(1, 0, 1, 0)
            lbl.BackgroundTransparency = 1
            lbl.TextStrokeTransparency = 0
            lbl.Font = Enum.Font.GothamBold
            lbl.TextSize = 14
            obj.Label = lbl

            State.ESPObjects[char] = obj
        end

        obj.Highlight.FillColor = teamColor or Color3.fromRGB(255, 255, 255)

        local isMeleeLocked = State.VisualRegistry.Melee[char] ~= nil
        local isRangedLocked = State.VisualRegistry.Ranged[char] ~= nil

        local lockText, textColor = "", teamColor or Color3.fromRGB(255, 255, 255)
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
        obj.Label.Text = string.format("%s [%d/%d]%s", name, math.floor(hum.Health), hum.MaxHealth, lockText)
    end

    -- 1. 扫描 Players
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local char = player.Character
            local tColor = player.Team and player.Team.TeamColor.Color or Color3.fromRGB(255, 255, 255)
            if char then ApplyESP(char, player.Name, tColor) end
        end
    end

    -- 2. 扫描 workspace.Characters (该游戏特有机制)
    local wsChars = workspace:FindFirstChild("Characters")
    if wsChars then
        for _, char in ipairs(wsChars:GetChildren()) do
            if char:IsA("Model") and char ~= localChar then
                local player = Players:FindFirstChild(char.Name)
                local tColor = player and player.Team and player.Team.TeamColor.Color or Color3.fromRGB(200, 200, 200)
                ApplyESP(char, char.Name, tColor)
            end
        end
    end

    -- 3. 清理不再需要绘制的 ESP
    for char, obj in pairs(State.ESPObjects) do
        if not drawnChars[char] or not char.Parent then
            if obj.Highlight then obj.Highlight:Destroy() end
            if obj.Billboard then obj.Billboard:Destroy() end
            State.ESPObjects[char] = nil
        end
    end
end

RunService.RenderStepped:Connect(UpdateESP)

-- 互动系统（已移除自动拾取，仅保留秒互动与全图互动）
local function ProcessPrompt(prompt)
    if not prompt:IsA("ProximityPrompt") then return end

    if not prompt:GetAttribute("KS_OrigMaxDist") then
        prompt:SetAttribute("KS_OrigMaxDist", prompt.MaxActivationDistance)
    end
    if not prompt:GetAttribute("KS_OrigHoldDur") then
        prompt:SetAttribute("KS_OrigHoldDur", prompt.HoldDuration)
    end

    if Config.GlobalInteract_Enabled then
        prompt.MaxActivationDistance = 9999
    else
        prompt.MaxActivationDistance = prompt:GetAttribute("KS_OrigMaxDist")
    end

    if Config.InstantInteract_Enabled then
        prompt.HoldDuration = 0
    else
        prompt.HoldDuration = prompt:GetAttribute("KS_OrigHoldDur")
    end
end

local function ScanAndProcessPrompts()
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("ProximityPrompt") then
            ProcessPrompt(obj)
        end
    end
end

workspace.DescendantAdded:Connect(function(d)
    if d:IsA("ProximityPrompt") then
        ProcessPrompt(d)
    end
end)

task.spawn(function()
    while true do
        if Config.InstantInteract_Enabled or Config.GlobalInteract_Enabled then
            pcall(ScanAndProcessPrompts)
            task.wait(1)
        else
            task.wait(2)
        end
    end
end)

-- ==========================================
-- [防御与生存系统 - 基于反编译事件协议]
-- 通过Hook RemoteEvent.OnClientEvent 监听服务器推送的特定事件
-- 并在事件触发后执行防御性反制操作
-- ==========================================

-- 远程事件监听Hook：拦截服务器推送的特定事件并执行防御逻辑
task.spawn(function()
    local remote = FetchRemote()
    if not remote then
        task.wait(3)
        remote = FetchRemote()
    end
    if not remote then
        warn("[KillSystem] 防御系统：未找到RemoteEvent，事件监听未启动")
        return
    end

    remote.OnClientEvent:Connect(function(eventName, ...)
        -- 永久免战模式：检测到服务器推送combatMode事件（战斗被触发）时发送一次false
        -- 修正：发送false后40秒内仍为战斗状态，40秒后才非战斗
        -- 所以不能频繁发送false（会重置计时），只在战斗被触发时发送一次
        if Config.PermanentAntiCombat_Enabled and not Config.PermanentCombat_Enabled and eventName == "combatMode" then
            local combatMsg = ...
            -- 服务器推送combatMode带字符串消息表示战斗开始，带nil/false表示战斗结束
            -- 只在战斗开始时发送false（取消战斗）
            if combatMsg then
                task.spawn(function()
                    task.wait(0.1)  -- 稍微延迟避免与服务器事件冲突
                    local r = FetchRemote()
                    if r then
                        pcall(function() r:FireServer("combatMode", false) end)
                        print("[战斗控制] 检测到战斗触发，已发送combatMode,false启动40秒倒计时")
                    end
                end)
            end
        end

        -- 反死亡视觉：拦截killedVisual事件，禁用KilledColorCorrection
        -- 游戏原始处理：启用KilledColorCorrection并Tween亮度/对比度/饱和度
        -- 我们的对策：延迟一帧后强制禁用并归零所有参数
        if Config.NoKilledVisual_Enabled and eventName == "killedVisual" then
            task.spawn(function()
                task.wait(0.05)
                local cc = game.Lighting:FindFirstChild("KilledColorCorrection")
                if cc then
                    cc.Enabled = false
                    cc.Brightness = 0
                    cc.Contrast = 0
                    cc.Saturation = 0
                end
            end)
        end

        -- 反强制Ragdoll：拦截ragdoll事件，自动调用GettingUp恢复
        -- 游戏原始处理：调用v_u_9.activate(char, p194, p195, true) 激活Ragdoll
        -- 我们的对策：延迟0.1秒后强制切换到GettingUp状态起身
        if Config.AntiRagdoll_Enabled and eventName == "ragdoll" then
            task.spawn(function()
                task.wait(0.1)
                local char = LocalPlayer.Character
                if char and char:FindFirstChild("Humanoid") then
                    char.Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
                end
            end)
        end

        -- 反强制弹出：拦截eject事件，等待禁用期后重新进入最近车辆
        -- 游戏原始处理：v_u_8.disabled(true, "eject") 禁用互动 Handcuffs.HoldDuration*2 秒
        -- 我们的对策：等待禁用期结束，寻找30 studs内最近车辆并触发ProximityPrompt
        if Config.AntiEject_Enabled and eventName == "eject" then
            task.spawn(function()
                -- 计算eject禁用时长（Handcuffs.HoldDuration.Value * 2 + 1秒缓冲）
                local waitTime = 5
                pcall(function()
                    local handcuffs = game.ReplicatedStorage:FindFirstChild("Gameplay")
                    if handcuffs then
                        handcuffs = handcuffs:FindFirstChild("Items")
                    end
                    if handcuffs then
                        handcuffs = handcuffs:FindFirstChild("Handcuffs")
                    end
                    if handcuffs then
                        local hd = handcuffs:FindFirstChild("HoldDuration")
                        if hd and (hd:IsA("NumberValue") or hd:IsA("IntValue")) then
                            waitTime = hd.Value * 2 + 1
                        end
                    end
                end)
                task.wait(waitTime)

                -- 寻找最近的车辆
                local char = LocalPlayer.Character
                if not char or not char:FindFirstChild("HumanoidRootPart") then return end
                local localPos = char.HumanoidRootPart.Position
                local nearestVehicle = nil
                local nearestDist = math.huge
                local vehicles = workspace:FindFirstChild("Gameplay") and workspace.Gameplay:FindFirstChild("Vehicles")
                if vehicles then
                    for _, car in ipairs(vehicles:GetChildren()) do
                        if car:IsA("Model") then
                            local primaryPart = car.PrimaryPart or car:FindFirstChild("HumanoidRootPart") or car:FindFirstChildWhichIsA("BasePart")
                            if primaryPart then
                                local dist = (primaryPart.Position - localPos).Magnitude
                                if dist < nearestDist and dist < 30 then
                                    nearestDist = dist
                                    nearestVehicle = car
                                end
                            end
                        end
                    end
                end

                -- 尝试通过ProximityPrompt进入车辆
                if nearestVehicle then
                    local promptFound = false
                    for _, desc in ipairs(nearestVehicle:GetDescendants()) do
                        if desc:IsA("ProximityPrompt") then
                            local txt = string.lower(desc.ActionText .. " " .. desc.ObjectText)
                            if string.find(txt, "enter") or string.find(txt, "sit") or string.find(txt, "drive") or string.find(txt, "seat") then
                                pcall(function() desc:InputHoldBegin() end)
                                task.wait(0.15)
                                pcall(function() desc:InputHoldEnd() end)
                                promptFound = true
                                break
                            end
                        end
                    end
                    -- 如果没找到进入Prompt，尝试走向车辆
                    if not promptFound and char:FindFirstChild("Humanoid") then
                        char.Humanoid:MoveTo(nearestVehicle.PrimaryPart.Position)
                    end
                end
            end)
        end

        -- 反强制隐藏：拦截characterHidden事件，恢复触控与装备权限
        -- 游戏原始处理：禁用TouchControls、禁用EquipSlot、停用Ragdoll
        -- 我们的对策：恢复TouchControlsEnabled，标记装备槽为可用
        if Config.AntiCharHidden_Enabled and eventName == "characterHidden" then
            local hidden = ...
            if hidden then
                -- 恢复触控
                pcall(function()
                    game:GetService("GuiService").TouchControlsEnabled = true
                end)
                -- 尝试通过Remote恢复装备权限
                local r = FetchRemote()
                if r then
                    pcall(function() r:FireServer("characterIsPhysicallyOccupied", false) end)
                end
            end
        end
    end)
end)

-- 快速起身循环：持续监控Humanoid状态，物理Ragdoll时立即起身
-- 与AntiRagdoll互补：AntiRagdoll只拦截服务器ragdoll事件，
-- FastGetUp能捕获所有进入Physics状态的Ragdoll（包括物理碰撞导致）
task.spawn(function()
    while true do
        if Config.FastGetUp_Enabled then
            local char = LocalPlayer.Character
            if char and char:FindFirstChild("Humanoid") then
                local hum = char.Humanoid
                local state = hum:GetState()
                -- Physics状态通常表示Ragdoll（包括被车撞、爆炸等物理触发）
                if state == Enum.HumanoidStateType.Physics then
                    hum:ChangeState(Enum.HumanoidStateType.GettingUp)
                end
            end
            task.wait(0.1)
        else
            task.wait(1)
        end
    end
end)

-- 持续清理视觉效果：移除游戏添加的非系统Lighting效果
-- 保留我们自己的BlurEffect（名为KillSystem_Blur）
-- 如果NoKilledVisual开启，则KilledColorCorrection由其管理
local CleanEffectsLastCheck = 0
task.spawn(function()
    while true do
        if Config.CleanLightingEffects_Enabled then
            -- 限频检查，避免每帧遍历
            if tick() - CleanEffectsLastCheck >= 1 then
                CleanEffectsLastCheck = tick()
                for _, child in ipairs(game.Lighting:GetChildren()) do
                    -- 跳过我们自己的BlurEffect
                    if child.Name == "KillSystem_Blur" then continue end
                    -- 如果NoKilledVisual开启，跳过KilledColorCorrection（由其管理）
                    if child.Name == "KilledColorCorrection" and Config.NoKilledVisual_Enabled then continue end
                    -- 禁用各种视觉效果
                    if child:IsA("ColorCorrectionEffect") or child:IsA("BloomEffect") or
                       child:IsA("DepthOfFieldEffect") or child:IsA("SunRaysEffect") or
                       child:IsA("BlurEffect") or child:IsA("Atmosphere") then
                        pcall(function() child.Enabled = false end)
                    end
                end
            end
            task.wait(0.5)
        else
            task.wait(2)
        end
    end
end)

print("[KillSystem v10.18] 防御系统扩展版已加载。")

-- ==========================================
-- [防御系统 v2 - 状态轮询双重保障]
-- 问题：v1基于OnClientEvent事件监听，但可能因为以下原因失效：
--   1. 游戏的Ragdoll模块（v_u_9）可能使用自定义机制，不依赖Humanoid状态
--   2. PlatformStand为true时ChangeState(GettingUp)无效
--   3. Motor6D被禁用后需要手动重新启用
--   4. 事件监听器可能被游戏的包装机制过滤
-- 解决：使用RunService.Heartbeat持续强制状态，不依赖事件
-- ==========================================

local Heartbeat = RunService.Heartbeat
local GuiService = game:GetService("GuiService")

-- 调试计数器（控制台输出频率限制）
local DefDebugCounter = {
    AntiRagdoll = 0,
    FastGetUp = 0,
    NoKilledVisual = 0,
    AntiCharHidden = 0,
    AntiEject = 0
}

-- 持续状态强制循环：每帧检查并强制防御状态
Heartbeat:Connect(function()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChild("Humanoid")

    -- 反强制Ragdoll：持续强制PlatformStand=false、重新启用Motor6D
    if Config.AntiRagdoll_Enabled and hum then
        if hum.PlatformStand then
            hum.PlatformStand = false
            DefDebugCounter.AntiRagdoll = DefDebugCounter.AntiRagdoll + 1
            if DefDebugCounter.AntiRagdoll % 30 == 1 then
                print("[防御] AntiRagdoll: 强制PlatformStand=false")
            end
        end
        -- 重新启用所有Motor6D（Ragdoll模块会禁用它们）
        if char then
            for _, motor in ipairs(char:GetDescendants()) do
                if motor:IsA("Motor6D") and not motor.Enabled then
                    motor.Enabled = true
                end
            end
        end
        -- 调用GettingUp状态（每60帧调一次，避免过度调用）
        if DefDebugCounter.AntiRagdoll % 60 == 0 then
            local state = hum:GetState()
            if state == Enum.HumanoidStateType.Physics or state == Enum.HumanoidStateType.FallingDown then
                hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            end
        end
        DefDebugCounter.AntiRagdoll = DefDebugCounter.AntiRagdoll + 1
    end

    -- 快速起身：检测多种Ragdoll状态，立即起身
    if Config.FastGetUp_Enabled and hum then
        local state = hum:GetState()
        local needGetUp = false
        if state == Enum.HumanoidStateType.Physics then
            needGetUp = true
        elseif state == Enum.HumanoidStateType.FallingDown then
            needGetUp = true
        elseif hum.PlatformStand then
            needGetUp = true
        end
        if needGetUp then
            hum.PlatformStand = false
            hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            DefDebugCounter.FastGetUp = DefDebugCounter.FastGetUp + 1
            if DefDebugCounter.FastGetUp % 30 == 1 then
                print("[防御] FastGetUp: 检测到Ragdoll状态，强制起身")
            end
        end
    end

    -- 反死亡视觉：持续监控KilledColorCorrection.Enabled
    if Config.NoKilledVisual_Enabled then
        local cc = game.Lighting:FindFirstChild("KilledColorCorrection")
        if cc and cc.Enabled then
            cc.Enabled = false
            cc.Brightness = 0
            cc.Contrast = 0
            cc.Saturation = 0
            DefDebugCounter.NoKilledVisual = DefDebugCounter.NoKilledVisual + 1
            if DefDebugCounter.NoKilledVisual % 10 == 1 then
                print("[防御] NoKilledVisual: 检测到死亡视觉启用，已强制禁用")
            end
        end
    end

    -- 反强制隐藏：持续监控TouchControlsEnabled
    if Config.AntiCharHidden_Enabled then
        if not GuiService.TouchControlsEnabled then
            GuiService.TouchControlsEnabled = true
            DefDebugCounter.AntiCharHidden = DefDebugCounter.AntiCharHidden + 1
            if DefDebugCounter.AntiCharHidden % 30 == 1 then
                print("[防御] AntiCharHidden: 检测到触控被禁用，已恢复")
            end
        end
        -- 尝试通过Remote恢复装备权限（限频，避免高频发包）
        if DefDebugCounter.AntiCharHidden % 60 == 0 then
            local r = FetchRemote()
            if r then
                pcall(function() r:FireServer("characterIsPhysicallyOccupied", false) end)
            end
        end
    end
end)

-- 反强制弹出增强版：事件驱动 + 重试机制 + 直接FireServer
-- v1问题：依赖ProximityPrompt可能找不到或触发失败
-- v2改进：1.增加直接FireServer('enterVehicle')备用方案 2.多次重试 3.增加等待时间
local EjectRetryThread = nil
task.spawn(function()
    local remote = FetchRemote()
    if not remote then
        task.wait(3)
        remote = FetchRemote()
    end
    if not remote then return end

    remote.OnClientEvent:Connect(function(eventName, ...)
        if Config.AntiEject_Enabled and eventName == "eject" then
            print("[防御] AntiEject: 检测到eject事件，启动反弹出序列")
            -- 取消之前的重试线程
            if EjectRetryThread then pcall(task.cancel, EjectRetryThread) end
            EjectRetryThread = task.spawn(function()
                -- 等待eject禁用期（默认Handcuffs.HoldDuration*2，备选5秒）
                local waitTime = 5
                pcall(function()
                    local handcuffs = game.ReplicatedStorage:FindFirstChild("Gameplay")
                    if handcuffs then handcuffs = handcuffs:FindFirstChild("Items") end
                    if handcuffs then handcuffs = handcuffs:FindFirstChild("Handcuffs") end
                    if handcuffs then
                        local hd = handcuffs:FindFirstChild("HoldDuration")
                        if hd and (hd:IsA("NumberValue") or hd:IsA("IntValue")) then
                            waitTime = hd.Value * 2 + 1
                        end
                    end
                end)
                task.wait(waitTime)

                -- 重试进入车辆（最多3次）
                for attempt = 1, 3 do
                    local char = LocalPlayer.Character
                    if not char or not char:FindFirstChild("HumanoidRootPart") then break end
                    local localPos = char.HumanoidRootPart.Position
                    local nearestVehicle = nil
                    local nearestDist = math.huge
                    local vehicles = workspace:FindFirstChild("Gameplay") and workspace.Gameplay:FindFirstChild("Vehicles")
                    if vehicles then
                        for _, car in ipairs(vehicles:GetChildren()) do
                            if car:IsA("Model") then
                                local primaryPart = car.PrimaryPart or car:FindFirstChildWhichIsA("BasePart")
                                if primaryPart then
                                    local dist = (primaryPart.Position - localPos).Magnitude
                                    if dist < nearestDist and dist < 50 then
                                        nearestDist = dist
                                        nearestVehicle = car
                                    end
                                end
                            end
                        end
                    end

                    if nearestVehicle then
                        print(string.format("[防御] AntiEject: 尝试 #%d 进入车辆 %s (距离%.1f studs)",
                            attempt, nearestVehicle.Name, nearestDist))

                        -- 方法1：直接通过RemoteEvent请求进入车辆
                        local r = FetchRemote()
                        if r then
                            pcall(function() r:FireServer("enterVehicle", nearestVehicle) end)
                        end

                        -- 方法2：触发ProximityPrompt
                        for _, desc in ipairs(nearestVehicle:GetDescendants()) do
                            if desc:IsA("ProximityPrompt") and desc.Enabled then
                                pcall(function() desc:InputHoldBegin() end)
                                task.wait(0.2)
                                pcall(function() desc:InputHoldEnd() end)
                                break
                            end
                        end

                        -- 方法3：走向车辆（如果还没进入）
                        task.wait(1)
                        local seat = char:FindFirstChild("Seat")
                        local isInVehicle = false
                        if seat and seat:IsA("Weld") and seat.Part1 then
                            isInVehicle = true
                        end
                        -- 检查是否还在车里（通过RootPart的Velocity或Seat属性）
                        if char:FindFirstChild("Humanoid") and char.Humanoid.Sit then
                            isInVehicle = true
                        end
                        if not isInVehicle and char:FindFirstChild("HumanoidRootPart") then
                            local vehiclePos = nearestVehicle.PrimaryPart and nearestVehicle.PrimaryPart.Position or nearestVehicle:GetPivot().Position
                            char.Humanoid:MoveTo(vehiclePos)
                        end
                        if isInVehicle then
                            print("[防御] AntiEject: 成功重新进入车辆")
                            return
                        end
                    else
                        print(string.format("[防御] AntiEject: 尝试 #%d 未找到附近车辆", attempt))
                    end
                    task.wait(1.5)
                end
                print("[防御] AntiEject: 反弹出序列结束")
            end)
        end
    end)
end)

-- ==========================================
-- [快捷键透明度同步系统]
-- 修复：快捷键透明度可能卡在0.5无法变回0.2
-- 原因：isDragging标志卡true、弹窗内Toggle切换后快捷键未同步
-- 解决：Heartbeat持续同步所有快捷键透明度到当前Config状态
-- ==========================================
RunService.Heartbeat:Connect(function()
    for _, shortcut in ipairs(State.Shortcuts) do
        if shortcut and shortcut.Parent then
            local key = shortcut:GetAttribute("ConfigKey")
            if key and Config[key] ~= nil then
                local targetTransparency = Config[key] and 0.2 or 0.5
                -- 只在透明度不一致时更新，避免每帧无意义写入
                if shortcut.BackgroundTransparency ~= targetTransparency then
                    shortcut.BackgroundTransparency = targetTransparency
                end
            end
        end
    end
end)

print("[KillSystem v10.21] 近战修复与快捷键同步版已加载。")

-- ==========================================
-- [战斗状态控制系统 - 基于combatMode协议]
-- 协议说明（修正版）：
--   combatMode, true  = 永久战斗状态（不会自动消失）
--   combatMode, false = 启动40秒倒计时，40秒内仍为战斗状态，40秒后才变为非战斗
--   重新发送false会重置40秒倒计时（导致永远无法变非战斗）
-- 实现策略（修正版）：
--   永久战斗模式：每30秒发送一次combatMode,true（保险，防止意外失效）
--   永久免战模式：事件驱动，检测到服务器推送combatMode事件（战斗被触发）时才发送一次false
--                 让40秒倒计时自然过期，不频繁发送避免重置计时
-- 互斥逻辑：两个模式同时开启时，永久战斗模式优先
-- ==========================================
local CombatControlLastSend = 0
task.spawn(function()
    while true do
        -- 永久战斗模式：每30秒发送一次true
        if Config.PermanentCombat_Enabled then
            if tick() - CombatControlLastSend >= 30 then
                CombatControlLastSend = tick()
                local remote = FetchRemote()
                if remote then
                    pcall(function() remote:FireServer("combatMode", true) end)
                end
            end
            task.wait(1)
        else
            -- 永久免战模式由OnClientEvent事件驱动，这里不需要循环发包
            task.wait(2)
        end
    end
end)

-- ==========================================
-- [自动装备武器系统 - 基于equipItem协议]
-- 协议说明：
--   equipItem, toolInstance = 装备指定工具实例
-- 实现策略：
--   当近战或远程攻击激活时，检测是否已装备武器
--   如果未装备，自动寻找背包中的第一个武器并发送equipItem
-- ==========================================
local function IsWeaponEquipped()
    local char = LocalPlayer.Character
    if not char then return false end
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Tool") then return true end
        if item:IsA("Model") and item:FindFirstChild("Handle") then return true end
    end
    return false
end

local function FindAndEquipWeapon()
    local char = LocalPlayer.Character
    if not char then return false end
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    if not backpack then return false end

    -- 优先寻找枪械类武器（有GUN配置）
    local weapons = {}
    for _, item in ipairs(backpack:GetChildren()) do
        if item:IsA("Tool") then
            table.insert(weapons, item)
        end
    end

    -- 如果背包没有，检查角色（可能已装备但检测失败）
    if #weapons == 0 then return false end

    -- 优先选择有Config且Config.GUN存在的武器
    local bestWeapon = nil
    for _, w in ipairs(weapons) do
        local cfg = w:FindFirstChild("Config")
        if cfg then
            local success, cfgData = pcall(require, cfg)
            if success and cfgData and cfgData.GUN then
                bestWeapon = w
                break
            end
        end
    end
    -- 没有枪械就选第一个工具
    if not bestWeapon then bestWeapon = weapons[1] end

    local remote = FetchRemote()
    if remote and bestWeapon then
        pcall(function() remote:FireServer("equipItem", bestWeapon) end)
        return true
    end
    return false
end

-- 自动装备检测循环：当攻击功能激活且未装备武器时自动装备
local AutoEquipLastCheck = 0
task.spawn(function()
    while true do
        if Config.AutoEquipWeapon_Enabled and (Config.Melee_Enabled or Config.Ranged_Enabled) then
            -- 每2秒检查一次，避免高频发包
            if tick() - AutoEquipLastCheck >= 2 then
                AutoEquipLastCheck = tick()
                if not IsWeaponEquipped() then
                    FindAndEquipWeapon()
                end
            end
            task.wait(1)
        else
            task.wait(2)
        end
    end
end)

print("[KillSystem v10.26] 攻击线性能优化版已加载。")

-- ==========================================
-- [自动消耗物品系统 - 基于modifyInventory协议]
-- 协议说明：
--   modifyInventory, {removeById = 槽位Id, change = 数量}
--   removeById = 背包槽位索引（从1开始）
--   change = 要消耗的数量（负数表示减少）
-- 实现策略：
--   周期性扫描背包，寻找可消耗物品（食物/药品/饮料）
--   找到后发送modifyInventory消耗指定数量
--   智能识别：根据物品名称关键词匹配消耗品
-- ==========================================

-- 获取背包物品列表（返回槽位索引和物品名称的表）
local function GetInventorySlots()
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    if not backpack then return {} end
    local slots = {}
    local idx = 1
    for _, item in ipairs(backpack:GetChildren()) do
        if item:IsA("Tool") then
            table.insert(slots, { id = idx, item = item, name = item.Name })
            idx = idx + 1
        end
    end
    return slots
end

-- 判断物品是否为可消耗品（根据名称关键词）
local function IsConsumable(itemName)
    if not itemName then return false end
    local name = string.lower(itemName)
    -- 食物类关键词
    local foodKeywords = {
        "food", "eat", "bread", "apple", "burger", "pizza", "sandwich",
        "cake", "cookie", "fruit", "meat", "fish", "rice", "noodle",
        "snack", "chocolate", "candy", "banana", "orange", "grape",
        "water", "drink", "juice", "soda", "cola", "milk", "tea",
        "coffee", "beer", "wine", "bottle", "can"
    }
    -- 药品类关键词
    local medicineKeywords = {
        "medicine", "med", "pill", "bandage", "health", "heal", "potion",
        "aid", "kit", "syringe", "capsule", "tablet"
    }
    for _, kw in ipairs(foodKeywords) do
        if string.find(name, kw) then return true end
    end
    for _, kw in ipairs(medicineKeywords) do
        if string.find(name, kw) then return true end
    end
    return false
end

-- 自动消耗循环
task.spawn(function()
    local lastConsumeTime = 0
    while true do
        if Config.AutoConsume_Enabled then
            if tick() - lastConsumeTime >= Config.AutoConsume_Delay then
                lastConsumeTime = tick()
                local remote = FetchRemote()
                if remote then
                    if Config.AutoConsume_SelectedSlot then
                        -- 指定槽位消耗
                        pcall(function()
                            remote:FireServer("modifyInventory", {
                                removeById = Config.AutoConsume_SelectedSlot,
                                change = Config.AutoConsume_Count
                            })
                        end)
                    else
                        -- 自动识别消耗品
                        local slots = GetInventorySlots()
                        for _, slotData in ipairs(slots) do
                            if IsConsumable(slotData.name) then
                                pcall(function()
                                    remote:FireServer("modifyInventory", {
                                        removeById = slotData.id,
                                        change = Config.AutoConsume_Count
                                    })
                                end)
                                break  -- 每次只消耗一个物品
                            end
                        end
                    end
                end
            end
            task.wait(0.5)
        else
            task.wait(2)
        end
    end
end)

print("[KillSystem v10.28] 滑动侧栏与物品选择版已加载。")

-- ==========================================
-- [攻击线绘制系统 - 3D Beam优化版]
-- 修复：2D GUI线绘制错误且每条线一个RenderStepped连接导致严重卡顿
-- 改进：1.改回3D Beam（位置准确，无需投影计算）
--       2.单一RenderStepped连接统一管理所有线的生命周期
--       3.限制最大数量20条，超过删除最老的
--       4.关闭开关时立即清理所有Beam实例
--       5.Beam挂在单一容器下，便于统一清理
-- ==========================================
local MAX_ATTACK_LINES = 20  -- 最大同时存在的攻击线数量
local AttackLineContainer = nil  -- Beam容器，延迟创建

-- 获取或创建Beam容器
local function GetAttackLineContainer()
    if AttackLineContainer and AttackLineContainer.Parent then return AttackLineContainer end
    AttackLineContainer = Instance.new("Folder")
    AttackLineContainer.Name = "KillSystem_AttackLines"
    AttackLineContainer.Parent = workspace
    return AttackLineContainer
end

ClearAttackLines = function()
    -- 立即清理所有活跃的攻击线实例
    for _, lineData in ipairs(State.AttackLines) do
        if lineData and lineData.beamPart then
            pcall(function() lineData.beamPart:Destroy() end)
        end
    end
    State.AttackLines = {}
end

DrawAttackLine = function(startPos, endPos, color, duration)
    duration = duration or 0.2
    local container = GetAttackLineContainer()

    -- 如果超过最大数量，删除最老的线
    if #State.AttackLines >= MAX_ATTACK_LINES then
        local oldest = table.remove(State.AttackLines, 1)
        if oldest and oldest.beamPart then
            pcall(function() oldest.beamPart:Destroy() end)
        end
    end

    -- 创建单一锚点Part挂载两个Attachment和Beam
    local beamPart = Instance.new("Part")
    beamPart.Anchored = true
    beamPart.CanCollide = false
    beamPart.CanQuery = false
    beamPart.CanTouch = false
    beamPart.Transparency = 1
    beamPart.Size = Vector3.new(0.1, 0.1, 0.1)
    beamPart.Position = startPos
    beamPart.Parent = container

    local att0 = Instance.new("Attachment")
    att0.Position = Vector3.new(0, 0, 0)
    att0.Parent = beamPart

    local att1 = Instance.new("Attachment")
    -- 相对位置 = endPos - startPos
    att1.Position = endPos - startPos
    att1.Parent = beamPart

    local beam = Instance.new("Beam")
    beam.Attachment0 = att0
    beam.Attachment1 = att1
    beam.Color = ColorSequence.new(color)
    beam.Transparency = NumberSequence.new(0.2)
    beam.Width0 = 0.3
    beam.Width1 = 0.3
    beam.FaceCamera = true
    beam.Parent = beamPart

    local lineData = {
        beamPart = beamPart,
        beam = beam,
        creationTime = tick(),
        duration = duration
    }
    table.insert(State.AttackLines, lineData)
end

-- 单一RenderStepped连接：统一管理所有攻击线的生命周期
-- 这样无论有多少条线，只有1个连接，不会卡顿
RunService.RenderStepped:Connect(function()
    if #State.AttackLines == 0 then return end

    -- 检查功能是否仍开启（都关闭则清理所有）
    local anyEnabled = Config.DrawMeleeLine_Enabled or Config.DrawRangedLine_Enabled
    if not anyEnabled then
        if #State.AttackLines > 0 then
            ClearAttackLines()
        end
        return
    end

    -- 遍历清理过期线（从后往前删除安全）
    local now = tick()
    for i = #State.AttackLines, 1, -1 do
        local lineData = State.AttackLines[i]
        if lineData and now - lineData.creationTime > lineData.duration then
            -- 过期，删除
            if lineData.beamPart then
                pcall(function() lineData.beamPart:Destroy() end)
            end
            table.remove(State.AttackLines, i)
        end
    end
end)

oot.Position - localRoot.Position)
                    -- charRot是Vector2，根据反编译：SetAttribute("charRot", Vector2.new(X/100, Y/100))
                    -- 原始发送格式：Vector2.new(math.round(attr.X*100), math.round(attr.Y*100))
                    -- 所以服务器接收到的是放大100倍的值，存储时除以100
                    -- 这里我们直接构造方向向量并放大100倍
                    local rotX = math.clamp(dir.X * 100, -9999, 9999)
                    local rotZ = dir.Z * 100
                    -- 使用Vector2.new(X, Z)因为charRot的Y分量对应世界的Z轴（前后）
                    return oldUnreliableFire(self, "charRot", Vector2.new(math.round(rotX), math.round(rotZ)))
                end
            end

            -- 优先级2：反强制转向（用摄像机朝向覆盖）
            if Config.AntiForceRotation_Enabled and camera and char and char:FindFirstChild("HumanoidRootPart") then
                local localRoot = char.HumanoidRootPart
                -- 获取摄像机LookVector在XZ平面的投影
                local lookVec = camera.CFrame.LookVector
                -- 构造方向向量并放大100倍（与游戏原始格式一致）
                local rotX = math.round(lookVec.X * 100)
                local rotZ = math.round(lookVec.Z * 100)
                return oldUnreliableFire(self, "charRot", Vector2.new(rotX, rotZ))
            end
        end
        return oldUnreliableFire(self, cmd, ...)
    end
    print("[KillSystem] UnreliableEvent.charRot Hook 已启动")
end)

-- ==========================================
-- [UI 构建逻辑]
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
SideBar.Size = UDim2.new(0, 80, 0, 350)
SideBar.Position = UDim2.new(1, 0, 0.5, -175)
SideBar.BackgroundColor3 = Theme.Darker
SideBar.Parent = ScreenGui
Instance.new("UICorner", SideBar).CornerRadius = UDim.new(0, 16)
local sbStroke = Instance.new("UIStroke", SideBar)
sbStroke.Thickness = 2
ApplyGradient(sbStroke)

local SideList = Instance.new("UIListLayout", SideBar)
SideList.Padding = UDim.new(0, 8)
SideList.HorizontalAlignment = Enum.HorizontalAlignment.Center
SideList.VerticalAlignment = Enum.VerticalAlignment.Center

local isSideBarOut = false
local ActivePopup = nil

local function ToggleSideBar(show)
    isSideBarOut = show
    if show then
        TweenService:Create(SideBar, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Position = UDim2.new(1, -90, 0.5, -175)}):Play()
        if State.AutoHideThread then task.cancel(State.AutoHideThread) end
        State.AutoHideThread = task.delay(5, function()
            if isSideBarOut and not (ActivePopup and ActivePopup.Parent) then ToggleSideBar(false) end
        end)
    else
        TweenService:Create(SideBar, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Position = UDim2.new(1, 0, 0.5, -175)}):Play()
    end
end

-- 修复：弹窗打开时点击侧栏触发按钮应先关闭弹窗，避免UI状态混乱
SideBarTrigger.MouseButton1Click:Connect(function()
    if ActivePopup then ClosePopup() return end
    ToggleSideBar(not isSideBarOut)
end)

-- 修复：ClosePopup改为非yield，避免调用方时序问题；新增showSidebar参数控制是否回弹侧栏
ClosePopup = function(showSidebar)
    if not ActivePopup then return end
    local pop = ActivePopup
    ActivePopup = nil
    TweenService:Create(pop, TweenInfo.new(0.2), {Size = UDim2.new(0, 0, 0, 0)}):Play()
    TweenService:Create(BlurEffect, TweenInfo.new(0.2), {Size = 0}):Play()
    task.delay(0.2, function()
        if pop and pop.Parent then pop:Destroy() end
    end)
    if showSidebar ~= false then
        ToggleSideBar(true)
    end
end

-- 修复：快捷键放置函数，统一管理快捷键创建与注册
local function PlaceShortcutAt(pos, key, iconText)
    local shortcut = Instance.new("TextButton")
    shortcut.Size = UDim2.new(0, 50, 0, 50)
    shortcut.Position = UDim2.new(0, pos.X - 25, 0, pos.Y - 25)
    shortcut.BackgroundColor3 = Theme.Darker
    shortcut.BackgroundTransparency = Config[key] and 0.2 or 0.5
    shortcut.Text = iconText or "⚡"
    shortcut.TextColor3 = Theme.C1
    shortcut.Font = Enum.Font.GothamBold
    shortcut.TextSize = 20
    shortcut.Parent = ScreenGui
    Instance.new("UICorner", shortcut).CornerRadius = UDim.new(1, 0)
    shortcut:SetAttribute("ConfigKey", key)
    table.insert(State.Shortcuts, shortcut)
    if not State.ShortcutsByConfigKey[key] then State.ShortcutsByConfigKey[key] = {} end
    table.insert(State.ShortcutsByConfigKey[key], shortcut)

    local isPressing = false
    local isDragging = false
    local pressTime = 0
    local dragStartPos = nil
    local startUdimPos = nil

    shortcut.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            isPressing = true
            isDragging = false
            pressTime = tick()
            dragStartPos = inp.Position
            startUdimPos = shortcut.Position
        end
    end)

    shortcut.InputChanged:Connect(function(inp)
        if isPressing and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
            if dragStartPos and (inp.Position - dragStartPos).Magnitude > 15 then
                isDragging = true
                local dx = inp.Position.X - dragStartPos.X
                local dy = inp.Position.Y - dragStartPos.Y
                shortcut.Position = UDim2.new(startUdimPos.X.Scale, startUdimPos.X.Offset + dx, startUdimPos.Y.Scale, startUdimPos.Y.Offset + dy)
            end
        end
    end)

    shortcut.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            if not isPressing then return end
            isPressing = false

            local duration = tick() - pressTime
            -- 修复：检查总位移而非isDragging标志，避免轻微移动后isDragging卡true导致切换失效
            local totalDisplacement = dragStartPos and (inp.Position - dragStartPos).Magnitude or 0
            local isClick = totalDisplacement < 15

            if isClick then
                if duration >= 0.8 then
                    -- 长按删除
                    local k = shortcut:GetAttribute("ConfigKey")
                    shortcut:Destroy()
                    for i, sc in ipairs(State.Shortcuts) do if sc == shortcut then table.remove(State.Shortcuts, i) break end end
                    if k and State.ShortcutsByConfigKey[k] then
                        for i, sc in ipairs(State.ShortcutsByConfigKey[k]) do if sc == shortcut then table.remove(State.ShortcutsByConfigKey[k], i) break end end
                    end
                else
                    -- 短按切换
                    if ActivePopup then ClosePopup(false) end
                    Config[key] = not Config[key]
                    if State.GlobalCallbacks[key] then State.GlobalCallbacks[key](Config[key]) end
                    shortcut.BackgroundTransparency = Config[key] and 0.2 or 0.5
                end
            end
            -- 重置isDragging，防止下次点击继承上次状态
            isDragging = false
        end
    end)
end

-- 修复：快捷键放置模式改用全屏捕获按钮，避免点击穿透；增加视觉提示与ESC取消
local function StartPlacementMode(configKey, iconText)
    State.IsPlacingShortcut = true
    State.CurrentActionToBind = { configKey = configKey, icon = iconText }

    local capture = Instance.new("TextButton")
    capture.Size = UDim2.new(1, 0, 1, 0)
    capture.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    capture.BackgroundTransparency = 0.6
    capture.Text = "点击屏幕任意位置放置快捷键（ESC取消）"
    capture.TextColor3 = Color3.fromRGB(255, 255, 255)
    capture.TextStrokeTransparency = 0
    capture.Font = Enum.Font.GothamBold
    capture.TextSize = 22
    capture.ZIndex = 100
    capture.AutoButtonColor = false
    capture.Parent = ScreenGui
    State.PlacementCapture = capture

    capture.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            local pos = input.Position
            local bindAction = State.CurrentActionToBind
            State.IsPlacingShortcut = false
            State.CurrentActionToBind = nil
            State.PlacementCapture = nil
            capture:Destroy()
            if bindAction then
                PlaceShortcutAt(pos, bindAction.configKey, bindAction.icon)
            end
            ToggleSideBar(true)
        end
    end)
end

-- ESC取消放置模式
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if State.IsPlacingShortcut and input.KeyCode == Enum.KeyCode.Escape then
        State.IsPlacingShortcut = false
        State.CurrentActionToBind = nil
        if State.PlacementCapture then
            State.PlacementCapture:Destroy()
            State.PlacementCapture = nil
        end
        ToggleSideBar(true)
    end
end)

local function OpenPopup(TitleText, BuildContentFunc)
    -- 修复：打开弹窗时取消侧栏自动隐藏线程，避免无用残留
    if State.AutoHideThread then task.cancel(State.AutoHideThread) State.AutoHideThread = nil end
    if ActivePopup then ClosePopup(false) end
    Theme = GenerateNeonTheme()
    ToggleSideBar(false)

    SideBar.BackgroundColor3 = Theme.Darker
    ApplyGradient(sbStroke)
    ApplyGradient(SideBarTrigger)

    -- 修复：同步侧栏图标颜色至新主题
    for _, icon in ipairs(State.SideIcons) do
        icon.BackgroundColor3 = Theme.Dark
        icon.TextColor3 = Theme.C1
        for _, child in ipairs(icon:GetChildren()) do
            if child:IsA("UIStroke") then
                ApplyGradient(child)
            end
        end
    end

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
    CloseBtn.MouseButton1Click:Connect(function() ClosePopup() end)

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

local function CreateRow(parent, height)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, height)
    row.BackgroundColor3 = Theme.Darker
    row.Parent = parent
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)
    return row
end

-- 修复：CreateToggle增加wasLongPress标志，避免长按设置快捷键后误触开关切换；增加快捷键透明度同步
local function CreateToggle(parent, name, configKey, icon)
    local row = CreateRow(parent, 40)
    local state = Config[configKey]
    local wasLongPress = false

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

    local function SyncShortcuts()
        local shortcuts = State.ShortcutsByConfigKey[configKey]
        if shortcuts then
            for _, sc in ipairs(shortcuts) do
                sc.BackgroundTransparency = state and 0.2 or 0.5
            end
        end
    end

    local function ToggleState()
        -- 修复：如果是长按触发的释放，不切换状态
        if wasLongPress then
            wasLongPress = false
            return
        end
        state = not state
        Config[configKey] = state
        UpdateVisual()
        SyncShortcuts()  -- 修复：同步快捷键透明度
        if State.GlobalCallbacks[configKey] then State.GlobalCallbacks[configKey](state) end
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
                        -- 修复：检查弹窗是否仍然有效（防止弹窗已关闭后误触发）
                        if not ActivePopup or not ActivePopup.Parent then return end
                        wasLongPress = true
                        ClosePopup(false)
                        ToggleSideBar(false)
                        StartPlacementMode(configKey, icon)
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

local function CreateSlider(parent, name, minVal, maxVal, default, configKey, isFloat)
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
    valLabel.Text = isFloat and string.format("%.2f", default) or tostring(default)
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
        local val = isFloat and (minVal + (maxVal - minVal) * rel) or math.floor(minVal + (maxVal - minVal) * rel)
        fill.Size = UDim2.new(rel, 0, 1, 0)
        valLabel.Text = isFloat and string.format("%.2f", val) or tostring(val)
        Config[configKey] = val
    end

    barBg.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            update(input.Position)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then update(input.Position) end
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
        for _, child in ipairs(listContainer:GetChildren()) do if child:IsA("TextButton") then child:Destroy() end end
        local teams = getOptionsFunc()
        if #selectedTable == 0 then for _, team in ipairs(teams) do table.insert(selectedTable, team.Name) end end
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
            if table.find(selectedTable, team.Name) ~= nil then tBtn.BackgroundColor3 = Theme.C1 end
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

local function CreateSideIcon(iconText, openFunc)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 48, 0, 48)
    btn.BackgroundColor3 = Theme.Dark
    btn.Text = iconText
    btn.TextColor3 = Theme.C1
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 24
    btn.Parent = SideBar
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0.5, 0)
    local stroke = Instance.new("UIStroke", btn)
    stroke.Thickness = 2
    ApplyGradient(stroke)
    btn.MouseButton1Click:Connect(openFunc)
    table.insert(State.SideIcons, btn)  -- 新增：注册图标引用
    return btn
end

CreateSideIcon("⚔️", function()
    OpenPopup("近战杀戮", function(holder)
        CreateSlider(holder, "发包延迟 (0=极速)", 0, 1, Config.Melee_Delay, "Melee_Delay", true)
        CreateSlider(holder, "攻击范围", 5, 1000, Config.Melee_Range, "Melee_Range", false)
        CreateToggle(holder, "自动攻击", "Melee_Enabled", "⚔️")
        CreateToggle(holder, "高度多线程", "Melee_HyperThread", "🚀")
        CreateToggle(holder, "多部位打击", "Melee_MultiHit", "🎯")
        CreateToggle(holder, "防弹衣穿透", "BypassBulletProof_Enabled", "🦺")
        CreateToggle(holder, "强制战斗模式", "Melee_ForceCombatMode", "🔥")
        CreateToggle(holder, "自身免战斗模式", "Melee_SelfAntiCombatMode", "🛡️")
        CreateToggle(holder, "瞄准 NPC", "Melee_TargetNPC", "👾")
        CreateToggle(holder, "自动爆胎模式", "Melee_AutoPopTires", "🛞")
        CreateToggle(holder, "好友检测", "Melee_CheckFriends", "🤝")
        CreateToggle(holder, "可见性检测", "Melee_CheckVisibility", "👁️")
        local function GetTeams() local t = {} for _, team in ipairs(game:GetService("Teams"):GetTeams()) do table.insert(t, team) end return t end
        CreateMultiSelectList(holder, "队伍选择检测", GetTeams, "Melee_AllowedTeams", function(sel) end)
    end)
end)

CreateSideIcon("🔫", function()
    OpenPopup("远程杀戮", function(holder)
        CreateSlider(holder, "发包延迟 (0=极速)", 0, 1, Config.Ranged_Delay, "Ranged_Delay", true)
        CreateSlider(holder, "攻击范围", 100, 5000, Config.Ranged_Range, "Ranged_Range", false)
        CreateToggle(holder, "自动枪锁", "Ranged_Enabled", "🔫")
        CreateToggle(holder, "高度多线程", "Ranged_HyperThread", "🚀")
        CreateToggle(holder, "仅爆头(1.5倍率)", "Ranged_AutoHeadshot", "🧠")
        CreateToggle(holder, "散弹多发模拟", "Ranged_MultiBullet", "💥")
        CreateToggle(holder, "子弹穿墙", "Ranged_WallBang", "🧱")
        CreateToggle(holder, "瞄准 NPC", "Ranged_TargetNPC", "👾")
        CreateToggle(holder, "自动爆胎模式", "Ranged_AutoPopTires", "🛞")
        CreateToggle(holder, "激光无后座/无散射", "Ranged_NoRecoil", "🎯")
        CreateToggle(holder, "防弹衣穿透", "BypassBulletProof_Enabled", "🦺")
        CreateToggle(holder, "好友检测", "Ranged_CheckFriends", "🤝")
        CreateToggle(holder, "可见性检测", "Ranged_CheckVisibility", "👁️")
        local function GetTeams() local t = {} for _, team in ipairs(game:GetService("Teams"):GetTeams()) do table.insert(t, team) end return t end
        CreateMultiSelectList(holder, "队伍选择检测", GetTeams, "Ranged_AllowedTeams", function(sel) end)
    end)
end)

CreateSideIcon("👁️", function()
    OpenPopup("实用工具", function(holder)
        CreateToggle(holder, "玩家透视", "ESP_Enabled", "👻")
        CreateToggle(holder, "秒互动(防按住)", "InstantInteract_Enabled", "⚡")
        CreateToggle(holder, "工具无限耐久", "Tool_InfiniteDurability", "♾️")
        CreateToggle(holder, "全图超距互动", "GlobalInteract_Enabled", "🌐")
        CreateToggle(holder, "持续清理视觉效果", "CleanLightingEffects_Enabled", "✨")
        CreateToggle(holder, "近战攻击线", "DrawMeleeLine_Enabled", "📏")
        CreateToggle(holder, "远程攻击线", "DrawRangedLine_Enabled", "📐")
    end)
end)

CreateSideIcon("🛡️", function()
    OpenPopup("防御系统", function(holder)
        CreateToggle(holder, "反死亡视觉", "NoKilledVisual_Enabled", "💀")
        CreateToggle(holder, "反强制Ragdoll", "AntiRagdoll_Enabled", "🤸")
        CreateToggle(holder, "快速起身", "FastGetUp_Enabled", "⬆️")
        CreateToggle(holder, "反强制弹出", "AntiEject_Enabled", "🚗")
        CreateToggle(holder, "反强制隐藏", "AntiCharHidden_Enabled", "👁️")
        CreateToggle(holder, "反强制转向", "AntiForceRotation_Enabled", "🔄")
        CreateToggle(holder, "面向锁定目标", "FaceLockedTarget_Enabled", "🎯")
    end)
end)

CreateSideIcon("🔥", function()
    OpenPopup("战斗状态控制", function(holder)
        CreateToggle(holder, "永久战斗模式", "PermanentCombat_Enabled", "⚔️")
        CreateToggle(holder, "永久免战模式", "PermanentAntiCombat_Enabled", "🕊️")
        CreateToggle(holder, "自动装备武器", "AutoEquipWeapon_Enabled", "🎒")
    end)
end)

CreateSideIcon("⚙️", function()
    OpenPopup("设置", function(holder)
        CreateToggle(holder, "测试开关", "TestMode", "🧪")
    end)
end)

-- ==========================================
-- [核心视觉清理系统 - 深度扫描版]
-- ==========================================
function ClearLockVisuals(lockName)
    local mode = lockName == "KillSystem_MeleeLock" and "Melee" or "Ranged"
    local registry = State.VisualRegistry[mode]

    for char, hl in pairs(registry) do
        if hl then pcall(function() hl:Destroy() end) end
    end
    State.VisualRegistry[mode] = {}

    local function deepClean(parent)
        if not parent then return end
        for _, obj in ipairs(parent:GetDescendants()) do
            if obj:IsA("Highlight") and obj.Name == lockName then
                obj:Destroy()
            end
        end
    end
    pcall(deepClean, workspace)
    pcall(deepClean, Players)
end

local function SyncLockVisuals(activeChars, mode, lockName, color)
    -- 安全状态锁1：如果对应功能已被关闭，强行中断
    if not Config[mode .. "_Enabled"] then return end

    local registry = State.VisualRegistry[mode]
    local activeMap = {}

    for _, char in ipairs(activeChars) do
        if char and char.Parent then
            activeMap[char] = true
            if not registry[char] then
                -- 安全状态锁2：防止多线程并发在关闭瞬间强行创建
                if not Config[mode .. "_Enabled"] then return end
                local newHl = Instance.new("Highlight")
                newHl.Name = lockName
                newHl.FillColor = color
                newHl.OutlineColor = Color3.fromRGB(255, 255, 255)
                newHl.FillTransparency = 0.5
                newHl.Parent = char
                registry[char] = newHl
            end
        end
    end

    for char, hl in pairs(registry) do
        if not activeMap[char] or not char.Parent or not hl.Parent then
            if hl and hl.Parent then hl:Destroy() end
            registry[char] = nil
        end
    end
end

-- ==========================================
-- [核心公共逻辑：NPC与轮胎缓存扫描]
-- ==========================================
local npcCache = {}
local lastNpcScanTime = 0
local tireCache = {}
local lastTireScanTime = 0

local function UpdateNPCCache()
    if tick() - lastNpcScanTime < 0.5 then return end
    lastNpcScanTime = tick()
    table.clear(npcCache)
    for _, desc in ipairs(workspace:GetDescendants()) do
        if desc:IsA("Model") and not Players:GetPlayerFromCharacter(desc) then
            local hum = desc:FindFirstChildOfClass("Humanoid")
            local root = desc:FindFirstChild("HumanoidRootPart")
            if hum and root then
                table.insert(npcCache, {Char = desc, Humanoid = hum, Root = root})
            end
        end
    end
end

local function UpdateTireCache()
    if tick() - lastTireScanTime < 1 then return end
    lastTireScanTime = tick()
    table.clear(tireCache)
    local vehicles = workspace:FindFirstChild("Gameplay") and workspace.Gameplay:FindFirstChild("Vehicles")
    if vehicles then
        for _, car in ipairs(vehicles:GetChildren()) do
            for _, desc in ipairs(car:GetDescendants()) do
                if desc.Name == "WheelCollision" and not desc:GetAttribute("DontPuncture") then
                    table.insert(tireCache, desc)
                end
            end
        end
    end
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
    local targetNPC = Config[mode .. "_TargetNPC"]

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            if #allowedTeams > 0 and (not player.Team or not table.find(allowedTeams, player.Team.Name)) then continue end
            if checkFriends and LocalPlayer:IsFriendsWith(player.UserId) then continue end

            local targetChar = player.Character
            if targetChar and targetChar:FindFirstChild("HumanoidRootPart") and targetChar:FindFirstChild("Humanoid") and targetChar.Humanoid.Health > 0 then
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
                        table.insert(validTargets, {Player = player, Dist = dist, Char = targetChar, Root = targetRoot, IsNPC = false})
                    end
                end
            end
        end
    end

    if targetNPC then
        UpdateNPCCache()
        for _, npcData in ipairs(npcCache) do
            if npcData.Char ~= localChar and npcData.Humanoid.Health > 0 then
                local dist = (npcData.Root.Position - localRoot.Position).Magnitude
                if dist <= range then
                    local isVisible = true
                    if checkVis then
                        local params = RaycastParams.new()
                        params.FilterDescendantsInstances = {localChar}
                        params.FilterType = Enum.RaycastFilterType.Exclude
                        local hit = workspace:Raycast(localRoot.Position, (npcData.Root.Position - localRoot.Position), params)
                        if hit and not hit.Instance:IsDescendantOf(npcData.Char) then isVisible = false end
                    end
                    if isVisible then
                        table.insert(validTargets, {Player = {Name = npcData.Char.Name, UserId = 0}, Dist = dist, Char = npcData.Char, Root = npcData.Root, IsNPC = true})
                    end
                end
            end
        end
    end

    table.sort(validTargets, function(a, b) return a.Dist < b.Dist end)
    return validTargets
end

local function GetValidTires(rangeVal)
    local localChar = LocalPlayer.Character
    if not localChar or not localChar:FindFirstChild("HumanoidRootPart") then return {} end
    local localRoot = localChar.HumanoidRootPart
    local range = rangeVal
    local validTires = {}

    UpdateTireCache()
    for _, tire in ipairs(tireCache) do
        if tire.Parent and tire:GetAttribute("Durability") ~= 0 then
            local dist = (tire.Position - localRoot.Position).Magnitude
            if dist <= range then
                table.insert(validTires, {Tire = tire, Dist = dist, Pos = tire.Position})
            end
        end
    end
    table.sort(validTires, function(a, b) return a.Dist < b.Dist end)
    return validTires
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
    for _, t in ipairs(State.MeleeThreads) do pcall(task.cancel, t) end
    State.MeleeThreads = {}

    local threadCount = Config.Melee_HyperThread and 3 or 1

    for i = 1, threadCount do
        local t = task.spawn(function()
            while Config.Melee_Enabled do
                task.wait(Config.Melee_Delay > 0 and Config.Melee_Delay or 0.016)

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
                local activeChars = {}

                if #targets > 0 and localChar and localChar:FindFirstChild("HumanoidRootPart") then
                    local localRoot = localChar.HumanoidRootPart
                    local localPos = localRoot.Position

                    for _, targetData in ipairs(targets) do
                        local targetChar = targetData.Char
                        table.insert(activeChars, targetChar)

                        task.spawn(function()
                            local bodyPartsArr = Config.Melee_MultiHit and GetBodyPartsArray(targetChar) or {{ [1] = "HumanoidRootPart", [2] = 1 }}
                            local targetPos = targetData.Root.Position
                            -- 修复：shotCode[1]应为攻击者位置(localPos)，shotCode[2]应为朝目标方向，pos应为命中位置(targetPos)
                            -- 根据抓包：shotCode[1]=攻击者坐标，shotCode[2]=(targetPos-localPos).Unit，pos=命中坐标
                            local args = {
                                [1] = "damage",
                                [2] = {
                                    ["bodyParts"] = bodyPartsArr,
                                    ["shotCode"] = { [1] = localPos, [2] = (targetPos - localPos).Unit },
                                    ["target"] = targetData.Player,
                                    ["pos"] = targetPos
                                }
                            }
                            -- 防弹衣穿透：发送bulletProofTool=false绕过防弹背心减伤
                            if Config.BypassBulletProof_Enabled then
                                args[2].bulletProofTool = false
                            end
                            pcall(function() Remote:FireServer(unpack(args)) end)
                            -- 近战攻击线绘制：从玩家位置到目标位置，红色
                            if Config.DrawMeleeLine_Enabled then
                                pcall(function() DrawAttackLine(localPos, targetPos, Color3.fromRGB(255, 50, 50), 0.15) end)
                            end
                        end)
                    end
                end

                if Config.Melee_AutoPopTires then
                    local tires = GetValidTires(Config.Melee_Range)
                    for _, tireData in ipairs(tires) do
                        task.spawn(function()
                            if not localChar or not localChar:FindFirstChild("HumanoidRootPart") then return end
                            local localPos = localChar.HumanoidRootPart.Position
                            local shotCode = { localPos, (tireData.Pos - localPos).Unit }
                            pcall(function()
                                Remote:FireServer("damage", { shotCode = shotCode, pos = tireData.Pos, targetTire = tireData.Tire })
                            end)
                        end)
                    end
                end

                if i == 1 then
                    SyncLockVisuals(activeChars, "Melee", "KillSystem_MeleeLock", Color3.fromRGB(255, 0, 0))
                end
            end
        end)
        table.insert(State.MeleeThreads, t)
    end
end

-- ==========================================
-- [远程战斗逻辑]
-- ==========================================
local function GetEquippedWeaponName()
    local char = LocalPlayer.Character
    if not char then return "Unarmed" end
    for _, item in ipairs(char:GetChildren()) do if item:IsA("Tool") then return item.Name end end
    for _, item in ipairs(char:GetChildren()) do if item:IsA("Model") and item:FindFirstChild("Handle") then return item.Name end end
    return "Unarmed"
end

local function GetBarrelPos(char)
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Tool") then local barrel = item:FindFirstChild("Barrel") or item:FindFirstChild("Handle") if barrel then return barrel.Position end end
    end
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Model") and item:FindFirstChild("Handle") then local barrel = item:FindFirstChild("Barrel") or item:FindFirstChild("Handle") if barrel then return barrel.Position end end
    end
    return char.HumanoidRootPart.Position
end

function StartRangedLoop()
    for _, t in ipairs(State.RangedThreads) do pcall(task.cancel, t) end
    State.RangedThreads = {}

    local threadCount = Config.Ranged_HyperThread and 3 or 1

    for i = 1, threadCount do
        local t = task.spawn(function()
            while Config.Ranged_Enabled do
                task.wait(Config.Ranged_Delay > 0 and Config.Ranged_Delay or 0.016)

                local Remote = FetchRemote()
                if not Remote then task.wait(1) continue end

                local targets = GetValidTargets("Ranged")
                local localChar = LocalPlayer.Character
                local activeChars = {}

                if Config.Ranged_AutoPopTires then
                    local tires = GetValidTires(Config.Ranged_Range)
                    for _, tireData in ipairs(tires) do
                        task.spawn(function()
                            if not localChar or not localChar:FindFirstChild("HumanoidRootPart") then return end
                            local barrelPos = GetBarrelPos(localChar)
                            local shotCode = { barrelPos, (tireData.Pos - barrelPos).Unit }
                            pcall(function()
                                Remote:FireServer("damage", { shotCode = shotCode, pos = tireData.Pos, targetTire = tireData.Tire })
                            end)
                        end)
                    end
                end

                if #targets > 0 and localChar and localChar:FindFirstChild("HumanoidRootPart") then
                    for _, targetData in ipairs(targets) do
                        local targetChar = targetData.Char
                        table.insert(activeChars, targetChar)

                        task.spawn(function()
                            local hitPartName = Config.Ranged_AutoHeadshot and "Head" or "HumanoidRootPart"
                            local hitPart = targetChar:FindFirstChild(hitPartName) or targetChar:FindFirstChild("HumanoidRootPart")
                            if not hitPart then return end

                            local hitPos = hitPart.Position
                            local barrelPos = GetBarrelPos(localChar)
                            local shotCode = { barrelPos, (hitPos - barrelPos).Unit }
                            local weaponName = GetEquippedWeaponName()

                            for i = 1, (Config.Ranged_MultiBullet and 3 or 1) do
                                pcall(function() Remote:FireServer("bullet", { weaponName = weaponName, posDestroyX = hitPos.X + (i * 0.5), pos = hitPos }) end)
                            end

                            local damageArgs = {
                                [1] = "damage",
                                [2] = { bodyParts = { [1] = { [1] = hitPartName, [2] = 1 } }, shotCode = shotCode, target = targetData.Player, pos = hitPos }
                            }
                            if Config.Ranged_AutoHeadshot then damageArgs[2].damageFactor = 1.5 end
                            -- 防弹衣穿透：发送bulletProofTool=false绕过防弹背心减伤
                            if Config.BypassBulletProof_Enabled then
                                damageArgs[2].bulletProofTool = false
                            end
                            pcall(function() Remote:FireServer(unpack(damageArgs)) end)
                            -- 远程攻击线绘制：从枪口位置到命中位置，蓝色
                            if Config.DrawRangedLine_Enabled then
                                pcall(function() DrawAttackLine(barrelPos, hitPos, Color3.fromRGB(50, 150, 255), 0.2) end)
                            end
                        end)
                    end
                end

                if i == 1 then
                    SyncLockVisuals(activeChars, "Ranged", "KillSystem_RangedLock", Color3.fromRGB(0, 0, 255))
                end
            end
        end)
        table.insert(State.RangedThreads, t)
    end
end

-- ==========================================
-- [ESP与实用工具逻辑 - 兼容workspace.Characters]
-- ==========================================
function ClearESP()
    for char, obj in pairs(State.ESPObjects) do
        if obj.Highlight then obj.Highlight:Destroy() end
        if obj.Billboard then obj.Billboard:Destroy() end
    end
    State.ESPObjects = {}
end

local function UpdateESP()
    if not Config.ESP_Enabled then return end

    local drawnChars = {}
    local localChar = LocalPlayer.Character

    local function ApplyESP(char, name, teamColor)
        if char == localChar then return end
        if not char or not char.Parent then return end

        local root = char:FindFirstChild("HumanoidRootPart")
        local hum = char:FindFirstChildOfClass("Humanoid")
        if not root or not hum or hum.Health <= 0 then return end

        drawnChars[char] = true
        local obj = State.ESPObjects[char]

        local needRebuild = false
        if not obj then
            needRebuild = true
        else
            if not obj.Highlight or not obj.Highlight.Parent or obj.Highlight.Parent ~= char then needRebuild = true end
            if not obj.Billboard or not obj.Billboard.Parent or obj.Billboard.Parent ~= root then needRebuild = true end
        end

        if needRebuild then
            if obj then
                if obj.Highlight then pcall(function() obj.Highlight:Destroy() end) end
                if obj.Billboard then pcall(function() obj.Billboard:Destroy() end) end
            end
            obj = {}
            obj.Highlight = Instance.new("Highlight")
            obj.Highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
            obj.Highlight.FillTransparency = 0.7
            obj.Highlight.Parent = char

            obj.Billboard = Instance.new("BillboardGui")
            obj.Billboard.Size = UDim2.new(0, 200, 0, 30)
            obj.Billboard.StudsOffset = Vector3.new(0, 3, 0)
            obj.Billboard.AlwaysOnTop = true
            obj.Billboard.Parent = root

            local lbl = Instance.new("TextLabel", obj.Billboard)
            lbl.Size = UDim2.new(1, 0, 1, 0)
            lbl.BackgroundTransparency = 1
            lbl.TextStrokeTransparency = 0
            lbl.Font = Enum.Font.GothamBold
            lbl.TextSize = 14
            obj.Label = lbl

            State.ESPObjects[char] = obj
        end

        obj.Highlight.FillColor = teamColor or Color3.fromRGB(255, 255, 255)

        local isMeleeLocked = State.VisualRegistry.Melee[char] ~= nil
        local isRangedLocked = State.VisualRegistry.Ranged[char] ~= nil

        local lockText, textColor = "", teamColor or Color3.fromRGB(255, 255, 255)
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
        obj.Label.Text = string.format("%s [%d/%d]%s", name, math.floor(hum.Health), hum.MaxHealth, lockText)
    end

    -- 1. 扫描 Players
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local char = player.Character
            local tColor = player.Team and player.Team.TeamColor.Color or Color3.fromRGB(255, 255, 255)
            if char then ApplyESP(char, player.Name, tColor) end
        end
    end

    -- 2. 扫描 workspace.Characters (该游戏特有机制)
    local wsChars = workspace:FindFirstChild("Characters")
    if wsChars then
        for _, char in ipairs(wsChars:GetChildren()) do
            if char:IsA("Model") and char ~= localChar then
                local player = Players:FindFirstChild(char.Name)
                local tColor = player and player.Team and player.Team.TeamColor.Color or Color3.fromRGB(200, 200, 200)
                ApplyESP(char, char.Name, tColor)
            end
        end
    end

    -- 3. 清理不再需要绘制的 ESP
    for char, obj in pairs(State.ESPObjects) do
        if not drawnChars[char] or not char.Parent then
            if obj.Highlight then obj.Highlight:Destroy() end
            if obj.Billboard then obj.Billboard:Destroy() end
            State.ESPObjects[char] = nil
        end
    end
end

RunService.RenderStepped:Connect(UpdateESP)

-- 互动系统（已移除自动拾取，仅保留秒互动与全图互动）
local function ProcessPrompt(prompt)
    if not prompt:IsA("ProximityPrompt") then return end

    if not prompt:GetAttribute("KS_OrigMaxDist") then
        prompt:SetAttribute("KS_OrigMaxDist", prompt.MaxActivationDistance)
    end
    if not prompt:GetAttribute("KS_OrigHoldDur") then
        prompt:SetAttribute("KS_OrigHoldDur", prompt.HoldDuration)
    end

    if Config.GlobalInteract_Enabled then
        prompt.MaxActivationDistance = 9999
    else
        prompt.MaxActivationDistance = prompt:GetAttribute("KS_OrigMaxDist")
    end

    if Config.InstantInteract_Enabled then
        prompt.HoldDuration = 0
    else
        prompt.HoldDuration = prompt:GetAttribute("KS_OrigHoldDur")
    end
end

local function ScanAndProcessPrompts()
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("ProximityPrompt") then
            ProcessPrompt(obj)
        end
    end
end

workspace.DescendantAdded:Connect(function(d)
    if d:IsA("ProximityPrompt") then
        ProcessPrompt(d)
    end
end)

task.spawn(function()
    while true do
        if Config.InstantInteract_Enabled or Config.GlobalInteract_Enabled then
            pcall(ScanAndProcessPrompts)
            task.wait(1)
        else
            task.wait(2)
        end
    end
end)

-- ==========================================
-- [防御与生存系统 - 基于反编译事件协议]
-- 通过Hook RemoteEvent.OnClientEvent 监听服务器推送的特定事件
-- 并在事件触发后执行防御性反制操作
-- ==========================================

-- 远程事件监听Hook：拦截服务器推送的特定事件并执行防御逻辑
task.spawn(function()
    local remote = FetchRemote()
    if not remote then
        task.wait(3)
        remote = FetchRemote()
    end
    if not remote then
        warn("[KillSystem] 防御系统：未找到RemoteEvent，事件监听未启动")
        return
    end

    remote.OnClientEvent:Connect(function(eventName, ...)
        -- 永久免战模式：检测到服务器推送combatMode事件（战斗被触发）时发送一次false
        -- 修正：发送false后40秒内仍为战斗状态，40秒后才非战斗
        -- 所以不能频繁发送false（会重置计时），只在战斗被触发时发送一次
        if Config.PermanentAntiCombat_Enabled and not Config.PermanentCombat_Enabled and eventName == "combatMode" then
            local combatMsg = ...
            -- 服务器推送combatMode带字符串消息表示战斗开始，带nil/false表示战斗结束
            -- 只在战斗开始时发送false（取消战斗）
            if combatMsg then
                task.spawn(function()
                    task.wait(0.1)  -- 稍微延迟避免与服务器事件冲突
                    local r = FetchRemote()
                    if r then
                        pcall(function() r:FireServer("combatMode", false) end)
                        print("[战斗控制] 检测到战斗触发，已发送combatMode,false启动40秒倒计时")
                    end
                end)
            end
        end

        -- 反死亡视觉：拦截killedVisual事件，禁用KilledColorCorrection
        -- 游戏原始处理：启用KilledColorCorrection并Tween亮度/对比度/饱和度
        -- 我们的对策：延迟一帧后强制禁用并归零所有参数
        if Config.NoKilledVisual_Enabled and eventName == "killedVisual" then
            task.spawn(function()
                task.wait(0.05)
                local cc = game.Lighting:FindFirstChild("KilledColorCorrection")
                if cc then
                    cc.Enabled = false
                    cc.Brightness = 0
                    cc.Contrast = 0
                    cc.Saturation = 0
                end
            end)
        end

        -- 反强制Ragdoll：拦截ragdoll事件，自动调用GettingUp恢复
        -- 游戏原始处理：调用v_u_9.activate(char, p194, p195, true) 激活Ragdoll
        -- 我们的对策：延迟0.1秒后强制切换到GettingUp状态起身
        if Config.AntiRagdoll_Enabled and eventName == "ragdoll" then
            task.spawn(function()
                task.wait(0.1)
                local char = LocalPlayer.Character
                if char and char:FindFirstChild("Humanoid") then
                    char.Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
                end
            end)
        end

        -- 反强制弹出：拦截eject事件，等待禁用期后重新进入最近车辆
        -- 游戏原始处理：v_u_8.disabled(true, "eject") 禁用互动 Handcuffs.HoldDuration*2 秒
        -- 我们的对策：等待禁用期结束，寻找30 studs内最近车辆并触发ProximityPrompt
        if Config.AntiEject_Enabled and eventName == "eject" then
            task.spawn(function()
                -- 计算eject禁用时长（Handcuffs.HoldDuration.Value * 2 + 1秒缓冲）
                local waitTime = 5
                pcall(function()
                    local handcuffs = game.ReplicatedStorage:FindFirstChild("Gameplay")
                    if handcuffs then
                        handcuffs = handcuffs:FindFirstChild("Items")
                    end
                    if handcuffs then
                        handcuffs = handcuffs:FindFirstChild("Handcuffs")
                    end
                    if handcuffs then
                        local hd = handcuffs:FindFirstChild("HoldDuration")
                        if hd and (hd:IsA("NumberValue") or hd:IsA("IntValue")) then
                            waitTime = hd.Value * 2 + 1
                        end
                    end
                end)
                task.wait(waitTime)

                -- 寻找最近的车辆
                local char = LocalPlayer.Character
                if not char or not char:FindFirstChild("HumanoidRootPart") then return end
                local localPos = char.HumanoidRootPart.Position
                local nearestVehicle = nil
                local nearestDist = math.huge
                local vehicles = workspace:FindFirstChild("Gameplay") and workspace.Gameplay:FindFirstChild("Vehicles")
                if vehicles then
                    for _, car in ipairs(vehicles:GetChildren()) do
                        if car:IsA("Model") then
                            local primaryPart = car.PrimaryPart or car:FindFirstChild("HumanoidRootPart") or car:FindFirstChildWhichIsA("BasePart")
                            if primaryPart then
                                local dist = (primaryPart.Position - localPos).Magnitude
                                if dist < nearestDist and dist < 30 then
                                    nearestDist = dist
                                    nearestVehicle = car
                                end
                            end
                        end
                    end
                end

                -- 尝试通过ProximityPrompt进入车辆
                if nearestVehicle then
                    local promptFound = false
                    for _, desc in ipairs(nearestVehicle:GetDescendants()) do
                        if desc:IsA("ProximityPrompt") then
                            local txt = string.lower(desc.ActionText .. " " .. desc.ObjectText)
                            if string.find(txt, "enter") or string.find(txt, "sit") or string.find(txt, "drive") or string.find(txt, "seat") then
                                pcall(function() desc:InputHoldBegin() end)
                                task.wait(0.15)
                                pcall(function() desc:InputHoldEnd() end)
                                promptFound = true
                                break
                            end
                        end
                    end
                    -- 如果没找到进入Prompt，尝试走向车辆
                    if not promptFound and char:FindFirstChild("Humanoid") then
                        char.Humanoid:MoveTo(nearestVehicle.PrimaryPart.Position)
                    end
                end
            end)
        end

        -- 反强制隐藏：拦截characterHidden事件，恢复触控与装备权限
        -- 游戏原始处理：禁用TouchControls、禁用EquipSlot、停用Ragdoll
        -- 我们的对策：恢复TouchContr--[[
    杀戮系统 v10.26 [攻击线性能优化版]
    更新：
    1. 继承 v10.25 所有功能
    2. 修复2D GUI线绘制错误：WorldToViewportPoint投影计算有误
    3. 修复开启攻击线后严重卡顿：原每条线一个RenderStepped连接
    4. 改回3D Beam方案：位置准确，无需屏幕投影计算
    5. 关键优化：单一RenderStepped连接统一管理所有线的生命周期
    6. 无论有多少条线，只有1个连接，不会卡顿
    7. 限制最大20条线，超过删除最老的
    8. 所有Beam挂在单一Folder容器下，便于统一清理
    9. 关闭开关时立即清理所有Beam实例
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

-- 前置声明核心函数
local StartMeleeLoop, StartRangedLoop, ClearLockVisuals, ClearESP, HookWeaponConfig
local ClosePopup  -- 前置声明，供侧栏触发按钮回调使用
local DrawAttackLine, ClearAttackLines  -- 前置声明，供攻击循环与回调使用

-- 启动时强制清理可能残留的旧高亮实例
local function CleanupOrphanVisuals()
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Highlight") and (obj.Name == "KillSystem_MeleeLock" or obj.Name == "KillSystem_RangedLock") then
            obj:Destroy()
        end
    end
end
CleanupOrphanVisuals()

-- [全局统一配置]
local Config = {
    -- 近战
    Melee_Enabled = false,
    Melee_Range = 30,
    Melee_Delay = 0.03,
    Melee_HyperThread = false,
    Melee_MultiHit = true,
    Melee_ForceCombatMode = true,
    Melee_SelfAntiCombatMode = false,
    Melee_CheckFriends = false,
    Melee_CheckVisibility = false,
    Melee_TargetNPC = false,
    Melee_AutoPopTires = false,
    Melee_AllowedTeams = {},

    -- 远程
    Ranged_Enabled = false,
    Ranged_Range = 1000,
    Ranged_Delay = 0.05,
    Ranged_HyperThread = true,
    Ranged_AutoHeadshot = true,
    Ranged_MultiBullet = true,
    Ranged_WallBang = false,
    Ranged_CheckFriends = false,
    Ranged_CheckVisibility = false,
    Ranged_TargetNPC = false,
    Ranged_AutoPopTires = false,
    Ranged_NoRecoil = true,
    Ranged_AllowedTeams = {},

    -- 实用工具
    ESP_Enabled = false,
    InstantInteract_Enabled = false,
    Tool_InfiniteDurability = false,
    TestMode = false,

    -- 全图互动
    GlobalInteract_Enabled = false,

    -- 防御系统（基于反编译事件协议）
    NoKilledVisual_Enabled = false,      -- 反死亡视觉：禁用KilledColorCorrection
    AntiRagdoll_Enabled = false,         -- 反强制Ragdoll：拦截ragdoll事件
    FastGetUp_Enabled = false,           -- 快速起身：监控物理Ragdoll状态
    AntiEject_Enabled = false,           -- 反强制弹出：拦截eject事件后重新上车
    AntiCharHidden_Enabled = false,      -- 反强制隐藏：拦截characterHidden事件
    CleanLightingEffects_Enabled = false, -- 持续清理视觉效果

    -- 转向控制（基于charRot协议）
    AntiForceRotation_Enabled = false,   -- 反强制转向：用摄像机朝向覆盖charRot
    FaceLockedTarget_Enabled = false,    -- 面向锁定目标：锁定时强制面向目标

    -- 防弹衣穿透
    BypassBulletProof_Enabled = false,   -- 防弹衣穿透：damage事件发送bulletProofTool=false

    -- 战斗状态控制（独立分类）
    PermanentCombat_Enabled = false,    -- 永久战斗模式：每30秒发送combatMode,true
    PermanentAntiCombat_Enabled = false, -- 永久免战模式：事件驱动，检测战斗触发时发送一次false
    AutoEquipWeapon_Enabled = false,    -- 自动装备武器：攻击时检测未装备自动equipItem

    -- 攻击线绘制
    DrawMeleeLine_Enabled = false,      -- 近战攻击线：从玩家位置到目标位置
    DrawRangedLine_Enabled = false      -- 远程攻击线：从枪口到命中位置
}

-- [全局状态与回调中心]
local State = {
    RemoteEvent = nil,
    IsRemoteHooked = false,
    MeleeThreads = {},
    RangedThreads = {},
    AutoHideThread = nil,
    Shortcuts = {},
    ShortcutsByConfigKey = {},  -- 新增：按configKey索引快捷键，用于状态同步
    SideIcons = {},              -- 新增：侧栏图标引用，用于主题切换时同步颜色
    IsPlacingShortcut = false,
    CurrentActionToBind = nil,
    PlacementCapture = nil,     -- 新增：全屏捕获按钮引用
    CombatModeTick = 0,
    ESPObjects = {},
    VisualRegistry = { Melee = {}, Ranged = {} },
    Connections = {},
    AttackLines = {},  -- 新增：当前活跃的攻击线实例注册表，用于关闭时清理

    GlobalCallbacks = {
        Melee_Enabled = function(val)
            if val then StartMeleeLoop() else
                for _, t in ipairs(State.MeleeThreads) do pcall(task.cancel, t) end
                State.MeleeThreads = {}
                ClearLockVisuals("KillSystem_MeleeLock")
            end
        end,
        Ranged_Enabled = function(val)
            if val then StartRangedLoop() else
                for _, t in ipairs(State.RangedThreads) do pcall(task.cancel, t) end
                State.RangedThreads = {}
                ClearLockVisuals("KillSystem_RangedLock")
            end
        end,
        TestMode = function(val) print("[System] 测试开关状态改变 ->", val) end,
        ESP_Enabled = function(val) if not val then ClearESP() end end,
        DrawMeleeLine_Enabled = function(val) if not val then ClearAttackLines() end end,
        DrawRangedLine_Enabled = function(val) if not val then ClearAttackLines() end end,
        Ranged_NoRecoil = function(val)
            local char = LocalPlayer.Character
            if char then
                for _, tool in ipairs(char:GetChildren()) do
                    if tool:IsA("Tool") or (tool:IsA("Model") and tool:FindFirstChild("Handle")) then
                        HookWeaponConfig(tool)
                    end
                end
            end
        end
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

-- 修复：复用已存在的UIGradient，避免重复实例累积
local function ApplyGradient(guiObj)
    local grad = guiObj:FindFirstChildOfClass("UIGradient")
    if not grad then
        grad = Instance.new("UIGradient")
        grad.Parent = guiObj
    end
    grad.Color = ColorSequence.new(Theme.C1, Theme.C2)
    grad.Rotation = math.random(0, 360)
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "KillSystemUI_v10"
ScreenGui.ResetOnSpawn = false
ScreenGui.DisplayOrder = 999
pcall(function() ScreenGui.Parent = CoreGui end)
if not ScreenGui.Parent then ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local BlurEffect = Instance.new("BlurEffect")
BlurEffect.Name = "KillSystem_Blur"
BlurEffect.Size = 0
BlurEffect.Parent = Lighting

-- ==========================================
-- [原生协议Hook与武器系统]
-- ==========================================
function HookWeaponConfig(tool)
    if not tool then return end
    local cfgModule = tool:FindFirstChild("Config")
    if not cfgModule then return end

    local success, cfg = pcall(require, cfgModule)
    if success and cfg and cfg.GUN then
        if Config.Ranged_NoRecoil then
            cfg.RECOIL = 0
            cfg.TR_DIFF = 0
            cfg.ACCURACY = 0.001
        end
    end
end

LocalPlayer.CharacterAdded:Connect(function(char)
    char.ChildAdded:Connect(function(child)
        if child:IsA("Tool") or (child:IsA("Model") and child:FindFirstChild("Handle")) then
            task.wait(0.1)
            HookWeaponConfig(child)
        end
    end)
end)

task.spawn(function()
    local char = LocalPlayer.Character
    if char then
        for _, tool in ipairs(char:GetChildren()) do
            if tool:IsA("Tool") or (tool:IsA("Model") and tool:FindFirstChild("Handle")) then
                HookWeaponConfig(tool)
            end
        end
    end
end)

local function FetchRemote()
    if State.RemoteEvent then return State.RemoteEvent end
    local success, result = pcall(function() return ReplicatedStorage:WaitForChild("Remote", 3):WaitForChild("PlayerEvent", 3) end)
    if success and result then
        State.RemoteEvent = result
        return result
    end
    return nil
end

task.spawn(function()
    local remote = FetchRemote()
    if remote and not State.IsRemoteHooked then
        State.IsRemoteHooked = true
        local oldFireServer = remote.FireServer
        remote.FireServer = function(self, cmd, ...)
            if Config.Tool_InfiniteDurability and cmd == "degradeItem" then
                return
            end
            return oldFireServer(self, cmd, ...)
        end
    end
end)

-- Hook UnreliableEvent.FireServer：拦截charRot事件
-- 游戏每0.1秒发送charRot(Vector2)到服务器，用于同步角色朝向
-- 我们拦截后可以：1.用摄像机朝向覆盖（反强制转向）2.面向锁定目标
task.spawn(function()
    local success, unreliableRemote = pcall(function()
        return ReplicatedStorage:WaitForChild("Remote", 3):WaitForChild("UnreliableEvent", 3)
    end)
    if not success or not unreliableRemote then
        warn("[KillSystem] 未找到UnreliableEvent，charRot Hook未启动")
        return
    end

    local oldUnreliableFire = unreliableRemote.FireServer
    unreliableRemote.FireServer = function(self, cmd, ...)
        if cmd == "charRot" then
            local char = LocalPlayer.Character
            local camera = workspace.CurrentCamera

            -- 优先级1：面向锁定目标（当近战或远程锁定激活时）
            if Config.FaceLockedTarget_Enabled and char and char:FindFirstChild("HumanoidRootPart") then
                local localRoot = char.HumanoidRootPart
                local targetRoot = nil

                -- 检查近战锁定的目标
                if Config.Melee_Enabled then
                    for targetChar, _ in pairs(State.VisualRegistry.Melee) do
                        if targetChar and targetChar.Parent and targetChar:FindFirstChild("HumanoidRootPart") then
                            targetRoot = targetChar.HumanoidRootPart
                            break
                        end
                    end
                end

                -- 如果近战没锁定，检查远程锁定的目标
                if not targetRoot and Config.Ranged_Enabled then
                    for targetChar, _ in pairs(State.VisualRegistry.Ranged) do
                        if targetChar and targetChar.Parent and targetChar:FindFirstChild("HumanoidRootPart") then
                            targetRoot = targetChar.HumanoidRootPart
                            break
                        end
                    end
                end

                if targetRoot then
                    -- 计算朝向目标的方向向量（XZ平面）
                    local dir = (targetRoot.Position - localRoot.Position)
                    -- charRot是Vector2，根据反编译：SetAttribute("charRot", Vector2.new(X/100, Y/100))
                    -- 原始发送格式：Vector2.new(math.round(attr.X*100), math.round(attr.Y*100))
                    -- 所以服务器接收到的是放大100倍的值，存储时除以100
                    -- 这里我们直接构造方向向量并放大100倍
                    local rotX = math.clamp(dir.X * 100, -9999, 9999)
                    local rotZ = dir.Z * 100
                    -- 使用Vector2.new(X, Z)因为charRot的Y分量对应世界的Z轴（前后）
                    return oldUnreliableFire(self, "charRot", Vector2.new(math.round(rotX), math.round(rotZ)))
                end
            end

            -- 优先级2：反强制转向（用摄像机朝向覆盖）
            if Config.AntiForceRotation_Enabled and camera and char and char:FindFirstChild("HumanoidRootPart") then
                local localRoot = char.HumanoidRootPart
                -- 获取摄像机LookVector在XZ平面的投影
                local lookVec = camera.CFrame.LookVector
                -- 构造方向向量并放大100倍（与游戏原始格式一致）
                local rotX = math.round(lookVec.X * 100)
                local rotZ = math.round(lookVec.Z * 100)
                return oldUnreliableFire(self, "charRot", Vector2.new(rotX, rotZ))
            end
        end
        return oldUnreliableFire(self, cmd, ...)
    end
    print("[KillSystem] UnreliableEvent.charRot Hook 已启动")
end)

-- ==========================================
-- [UI 构建逻辑]
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
SideBar.Size = UDim2.new(0, 80, 0, 350)
SideBar.Position = UDim2.new(1, 0, 0.5, -175)
SideBar.BackgroundColor3 = Theme.Darker
SideBar.Parent = ScreenGui
Instance.new("UICorner", SideBar).CornerRadius = UDim.new(0, 16)
local sbStroke = Instance.new("UIStroke", SideBar)
sbStroke.Thickness = 2
ApplyGradient(sbStroke)

local SideList = Instance.new("UIListLayout", SideBar)
SideList.Padding = UDim.new(0, 8)
SideList.HorizontalAlignment = Enum.HorizontalAlignment.Center
SideList.VerticalAlignment = Enum.VerticalAlignment.Center

local isSideBarOut = false
local ActivePopup = nil

local function ToggleSideBar(show)
    isSideBarOut = show
    if show then
        TweenService:Create(SideBar, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Position = UDim2.new(1, -90, 0.5, -175)}):Play()
        if State.AutoHideThread then task.cancel(State.AutoHideThread) end
        State.AutoHideThread = task.delay(5, function()
            if isSideBarOut and not (ActivePopup and ActivePopup.Parent) then ToggleSideBar(false) end
        end)
    else
        TweenService:Create(SideBar, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Position = UDim2.new(1, 0, 0.5, -175)}):Play()
    end
end

-- 修复：弹窗打开时点击侧栏触发按钮应先关闭弹窗，避免UI状态混乱
SideBarTrigger.MouseButton1Click:Connect(function()
    if ActivePopup then ClosePopup() return end
    ToggleSideBar(not isSideBarOut)
end)

-- 修复：ClosePopup改为非yield，避免调用方时序问题；新增showSidebar参数控制是否回弹侧栏
ClosePopup = function(showSidebar)
    if not ActivePopup then return end
    local pop = ActivePopup
    ActivePopup = nil
    TweenService:Create(pop, TweenInfo.new(0.2), {Size = UDim2.new(0, 0, 0, 0)}):Play()
    TweenService:Create(BlurEffect, TweenInfo.new(0.2), {Size = 0}):Play()
    task.delay(0.2, function()
        if pop and pop.Parent then pop:Destroy() end
    end)
    if showSidebar ~= false then
        ToggleSideBar(true)
    end
end

-- 修复：快捷键放置函数，统一管理快捷键创建与注册
local function PlaceShortcutAt(pos, key, iconText)
    local shortcut = Instance.new("TextButton")
    shortcut.Size = UDim2.new(0, 50, 0, 50)
    shortcut.Position = UDim2.new(0, pos.X - 25, 0, pos.Y - 25)
    shortcut.BackgroundColor3 = Theme.Darker
    shortcut.BackgroundTransparency = Config[key] and 0.2 or 0.5
    shortcut.Text = iconText or "⚡"
    shortcut.TextColor3 = Theme.C1
    shortcut.Font = Enum.Font.GothamBold
    shortcut.TextSize = 20
    shortcut.Parent = ScreenGui
    Instance.new("UICorner", shortcut).CornerRadius = UDim.new(1, 0)
    shortcut:SetAttribute("ConfigKey", key)
    table.insert(State.Shortcuts, shortcut)
    if not State.ShortcutsByConfigKey[key] then State.ShortcutsByConfigKey[key] = {} end
    table.insert(State.ShortcutsByConfigKey[key], shortcut)

    local isPressing = false
    local isDragging = false
    local pressTime = 0
    local dragStartPos = nil
    local startUdimPos = nil

    shortcut.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            isPressing = true
            isDragging = false
            pressTime = tick()
            dragStartPos = inp.Position
            startUdimPos = shortcut.Position
        end
    end)

    shortcut.InputChanged:Connect(function(inp)
        if isPressing and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
            if dragStartPos and (inp.Position - dragStartPos).Magnitude > 15 then
                isDragging = true
                local dx = inp.Position.X - dragStartPos.X
                local dy = inp.Position.Y - dragStartPos.Y
                shortcut.Position = UDim2.new(startUdimPos.X.Scale, startUdimPos.X.Offset + dx, startUdimPos.Y.Scale, startUdimPos.Y.Offset + dy)
            end
        end
    end)

    shortcut.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            if not isPressing then return end
            isPressing = false

            local duration = tick() - pressTime
            -- 修复：检查总位移而非isDragging标志，避免轻微移动后isDragging卡true导致切换失效
            local totalDisplacement = dragStartPos and (inp.Position - dragStartPos).Magnitude or 0
            local isClick = totalDisplacement < 15

            if isClick then
                if duration >= 0.8 then
                    -- 长按删除
                    local k = shortcut:GetAttribute("ConfigKey")
                    shortcut:Destroy()
                    for i, sc in ipairs(State.Shortcuts) do if sc == shortcut then table.remove(State.Shortcuts, i) break end end
                    if k and State.ShortcutsByConfigKey[k] then
                        for i, sc in ipairs(State.ShortcutsByConfigKey[k]) do if sc == shortcut then table.remove(State.ShortcutsByConfigKey[k], i) break end end
                    end
                else
                    -- 短按切换
                    if ActivePopup then ClosePopup(false) end
                    Config[key] = not Config[key]
                    if State.GlobalCallbacks[key] then State.GlobalCallbacks[key](Config[key]) end
                    shortcut.BackgroundTransparency = Config[key] and 0.2 or 0.5
                end
            end
            -- 重置isDragging，防止下次点击继承上次状态
            isDragging = false
        end
    end)
end

-- 修复：快捷键放置模式改用全屏捕获按钮，避免点击穿透；增加视觉提示与ESC取消
local function StartPlacementMode(configKey, iconText)
    State.IsPlacingShortcut = true
    State.CurrentActionToBind = { configKey = configKey, icon = iconText }

    local capture = Instance.new("TextButton")
    capture.Size = UDim2.new(1, 0, 1, 0)
    capture.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    capture.BackgroundTransparency = 0.6
    capture.Text = "点击屏幕任意位置放置快捷键（ESC取消）"
    capture.TextColor3 = Color3.fromRGB(255, 255, 255)
    capture.TextStrokeTransparency = 0
    capture.Font = Enum.Font.GothamBold
    capture.TextSize = 22
    capture.ZIndex = 100
    capture.AutoButtonColor = false
    capture.Parent = ScreenGui
    State.PlacementCapture = capture

    capture.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            local pos = input.Position
            local bindAction = State.CurrentActionToBind
            State.IsPlacingShortcut = false
            State.CurrentActionToBind = nil
            State.PlacementCapture = nil
            capture:Destroy()
            if bindAction then
                PlaceShortcutAt(pos, bindAction.configKey, bindAction.icon)
            end
            ToggleSideBar(true)
        end
    end)
end

-- ESC取消放置模式
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if State.IsPlacingShortcut and input.KeyCode == Enum.KeyCode.Escape then
        State.IsPlacingShortcut = false
        State.CurrentActionToBind = nil
        if State.PlacementCapture then
            State.PlacementCapture:Destroy()
            State.PlacementCapture = nil
        end
        ToggleSideBar(true)
    end
end)

local function OpenPopup(TitleText, BuildContentFunc)
    -- 修复：打开弹窗时取消侧栏自动隐藏线程，避免无用残留
    if State.AutoHideThread then task.cancel(State.AutoHideThread) State.AutoHideThread = nil end
    if ActivePopup then ClosePopup(false) end
    Theme = GenerateNeonTheme()
    ToggleSideBar(false)

    SideBar.BackgroundColor3 = Theme.Darker
    ApplyGradient(sbStroke)
    ApplyGradient(SideBarTrigger)

    -- 修复：同步侧栏图标颜色至新主题
    for _, icon in ipairs(State.SideIcons) do
        icon.BackgroundColor3 = Theme.Dark
        icon.TextColor3 = Theme.C1
        for _, child in ipairs(icon:GetChildren()) do
            if child:IsA("UIStroke") then
                ApplyGradient(child)
            end
        end
    end

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
    CloseBtn.MouseButton1Click:Connect(function() ClosePopup() end)

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

local function CreateRow(parent, height)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, height)
    row.BackgroundColor3 = Theme.Darker
    row.Parent = parent
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)
    return row
end

-- 修复：CreateToggle增加wasLongPress标志，避免长按设置快捷键后误触开关切换；增加快捷键透明度同步
local function CreateToggle(parent, name, configKey, icon)
    local row = CreateRow(parent, 40)
    local state = Config[configKey]
    local wasLongPress = false

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

    local function SyncShortcuts()
        local shortcuts = State.ShortcutsByConfigKey[configKey]
        if shortcuts then
            for _, sc in ipairs(shortcuts) do
                sc.BackgroundTransparency = state and 0.2 or 0.5
            end
        end
    end

    local function ToggleState()
        -- 修复：如果是长按触发的释放，不切换状态
        if wasLongPress then
            wasLongPress = false
            return
        end
        state = not state
        Config[configKey] = state
        UpdateVisual()
        SyncShortcuts()  -- 修复：同步快捷键透明度
        if State.GlobalCallbacks[configKey] then State.GlobalCallbacks[configKey](state) end
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
                        -- 修复：检查弹窗是否仍然有效（防止弹窗已关闭后误触发）
                        if not ActivePopup or not ActivePopup.Parent then return end
                        wasLongPress = true
                        ClosePopup(false)
                        ToggleSideBar(false)
                        StartPlacementMode(configKey, icon)
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

local function CreateSlider(parent, name, minVal, maxVal, default, configKey, isFloat)
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
    valLabel.Text = isFloat and string.format("%.2f", default) or tostring(default)
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
        local val = isFloat and (minVal + (maxVal - minVal) * rel) or math.floor(minVal + (maxVal - minVal) * rel)
        fill.Size = UDim2.new(rel, 0, 1, 0)
        valLabel.Text = isFloat and string.format("%.2f", val) or tostring(val)
        Config[configKey] = val
    end

    barBg.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            update(input.Position)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then update(input.Position) end
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
        for _, child in ipairs(listContainer:GetChildren()) do if child:IsA("TextButton") then child:Destroy() end end
        local teams = getOptionsFunc()
        if #selectedTable == 0 then for _, team in ipairs(teams) do table.insert(selectedTable, team.Name) end end
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
            if table.find(selectedTable, team.Name) ~= nil then tBtn.BackgroundColor3 = Theme.C1 end
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

local function CreateSideIcon(iconText, openFunc)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 48, 0, 48)
    btn.BackgroundColor3 = Theme.Dark
    btn.Text = iconText
    btn.TextColor3 = Theme.C1
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 24
    btn.Parent = SideBar
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0.5, 0)
    local stroke = Instance.new("UIStroke", btn)
    stroke.Thickness = 2
    ApplyGradient(stroke)
    btn.MouseButton1Click:Connect(openFunc)
    table.insert(State.SideIcons, btn)  -- 新增：注册图标引用
    return btn
end

CreateSideIcon("⚔️", function()
    OpenPopup("近战杀戮", function(holder)
        CreateSlider(holder, "发包延迟 (0=极速)", 0, 1, Config.Melee_Delay, "Melee_Delay", true)
        CreateSlider(holder, "攻击范围", 5, 1000, Config.Melee_Range, "Melee_Range", false)
        CreateToggle(holder, "自动攻击", "Melee_Enabled", "⚔️")
        CreateToggle(holder, "高度多线程", "Melee_HyperThread", "🚀")
        CreateToggle(holder, "多部位打击", "Melee_MultiHit", "🎯")
        CreateToggle(holder, "防弹衣穿透", "BypassBulletProof_Enabled", "🦺")
        CreateToggle(holder, "强制战斗模式", "Melee_ForceCombatMode", "🔥")
        CreateToggle(holder, "自身免战斗模式", "Melee_SelfAntiCombatMode", "🛡️")
        CreateToggle(holder, "瞄准 NPC", "Melee_TargetNPC", "👾")
        CreateToggle(holder, "自动爆胎模式", "Melee_AutoPopTires", "🛞")
        CreateToggle(holder, "好友检测", "Melee_CheckFriends", "🤝")
        CreateToggle(holder, "可见性检测", "Melee_CheckVisibility", "👁️")
        local function GetTeams() local t = {} for _, team in ipairs(game:GetService("Teams"):GetTeams()) do table.insert(t, team) end return t end
        CreateMultiSelectList(holder, "队伍选择检测", GetTeams, "Melee_AllowedTeams", function(sel) end)
    end)
end)

CreateSideIcon("🔫", function()
    OpenPopup("远程杀戮", function(holder)
        CreateSlider(holder, "发包延迟 (0=极速)", 0, 1, Config.Ranged_Delay, "Ranged_Delay", true)
        CreateSlider(holder, "攻击范围", 100, 5000, Config.Ranged_Range, "Ranged_Range", false)
        CreateToggle(holder, "自动枪锁", "Ranged_Enabled", "🔫")
        CreateToggle(holder, "高度多线程", "Ranged_HyperThread", "🚀")
        CreateToggle(holder, "仅爆头(1.5倍率)", "Ranged_AutoHeadshot", "🧠")
        CreateToggle(holder, "散弹多发模拟", "Ranged_MultiBullet", "💥")
        CreateToggle(holder, "子弹穿墙", "Ranged_WallBang", "🧱")
        CreateToggle(holder, "瞄准 NPC", "Ranged_TargetNPC", "👾")
        CreateToggle(holder, "自动爆胎模式", "Ranged_AutoPopTires", "🛞")
        CreateToggle(holder, "激光无后座/无散射", "Ranged_NoRecoil", "🎯")
        CreateToggle(holder, "防弹衣穿透", "BypassBulletProof_Enabled", "🦺")
        CreateToggle(holder, "好友检测", "Ranged_CheckFriends", "🤝")
        CreateToggle(holder, "可见性检测", "Ranged_CheckVisibility", "👁️")
        local function GetTeams() local t = {} for _, team in ipairs(game:GetService("Teams"):GetTeams()) do table.insert(t, team) end return t end
        CreateMultiSelectList(holder, "队伍选择检测", GetTeams, "Ranged_AllowedTeams", function(sel) end)
    end)
end)

CreateSideIcon("👁️", function()
    OpenPopup("实用工具", function(holder)
        CreateToggle(holder, "玩家透视", "ESP_Enabled", "👻")
        CreateToggle(holder, "秒互动(防按住)", "InstantInteract_Enabled", "⚡")
        CreateToggle(holder, "工具无限耐久", "Tool_InfiniteDurability", "♾️")
        CreateToggle(holder, "全图超距互动", "GlobalInteract_Enabled", "🌐")
        CreateToggle(holder, "持续清理视觉效果", "CleanLightingEffects_Enabled", "✨")
        CreateToggle(holder, "近战攻击线", "DrawMeleeLine_Enabled", "📏")
        CreateToggle(holder, "远程攻击线", "DrawRangedLine_Enabled", "📐")
    end)
end)

CreateSideIcon("🛡️", function()
    OpenPopup("防御系统", function(holder)
        CreateToggle(holder, "反死亡视觉", "NoKilledVisual_Enabled", "💀")
        CreateToggle(holder, "反强制Ragdoll", "AntiRagdoll_Enabled", "🤸")
        CreateToggle(holder, "快速起身", "FastGetUp_Enabled", "⬆️")
        CreateToggle(holder, "反强制弹出", "AntiEject_Enabled", "🚗")
        CreateToggle(holder, "反强制隐藏", "AntiCharHidden_Enabled", "👁️")
        CreateToggle(holder, "反强制转向", "AntiForceRotation_Enabled", "🔄")
        CreateToggle(holder, "面向锁定目标", "FaceLockedTarget_Enabled", "🎯")
    end)
end)

CreateSideIcon("🔥", function()
    OpenPopup("战斗状态控制", function(holder)
        CreateToggle(holder, "永久战斗模式", "PermanentCombat_Enabled", "⚔️")
        CreateToggle(holder, "永久免战模式", "PermanentAntiCombat_Enabled", "🕊️")
        CreateToggle(holder, "自动装备武器", "AutoEquipWeapon_Enabled", "🎒")
    end)
end)

CreateSideIcon("⚙️", function()
    OpenPopup("设置", function(holder)
        CreateToggle(holder, "测试开关", "TestMode", "🧪")
    end)
end)

-- ==========================================
-- [核心视觉清理系统 - 深度扫描版]
-- ==========================================
function ClearLockVisuals(lockName)
    local mode = lockName == "KillSystem_MeleeLock" and "Melee" or "Ranged"
    local registry = State.VisualRegistry[mode]

    for char, hl in pairs(registry) do
        if hl then pcall(function() hl:Destroy() end) end
    end
    State.VisualRegistry[mode] = {}

    local function deepClean(parent)
        if not parent then return end
        for _, obj in ipairs(parent:GetDescendants()) do
            if obj:IsA("Highlight") and obj.Name == lockName then
                obj:Destroy()
            end
        end
    end
    pcall(deepClean, workspace)
    pcall(deepClean, Players)
end

local function SyncLockVisuals(activeChars, mode, lockName, color)
    -- 安全状态锁1：如果对应功能已被关闭，强行中断
    if not Config[mode .. "_Enabled"] then return end

    local registry = State.VisualRegistry[mode]
    local activeMap = {}

    for _, char in ipairs(activeChars) do
        if char and char.Parent then
            activeMap[char] = true
            if not registry[char] then
                -- 安全状态锁2：防止多线程并发在关闭瞬间强行创建
                if not Config[mode .. "_Enabled"] then return end
                local newHl = Instance.new("Highlight")
                newHl.Name = lockName
                newHl.FillColor = color
                newHl.OutlineColor = Color3.fromRGB(255, 255, 255)
                newHl.FillTransparency = 0.5
                newHl.Parent = char
                registry[char] = newHl
            end
        end
    end

    for char, hl in pairs(registry) do
        if not activeMap[char] or not char.Parent or not hl.Parent then
            if hl and hl.Parent then hl:Destroy() end
            registry[char] = nil
        end
    end
end

-- ==========================================
-- [核心公共逻辑：NPC与轮胎缓存扫描]
-- ==========================================
local npcCache = {}
local lastNpcScanTime = 0
local tireCache = {}
local lastTireScanTime = 0

local function UpdateNPCCache()
    if tick() - lastNpcScanTime < 0.5 then return end
    lastNpcScanTime = tick()
    table.clear(npcCache)
    for _, desc in ipairs(workspace:GetDescendants()) do
        if desc:IsA("Model") and not Players:GetPlayerFromCharacter(desc) then
            local hum = desc:FindFirstChildOfClass("Humanoid")
            local root = desc:FindFirstChild("HumanoidRootPart")
            if hum and root then
                table.insert(npcCache, {Char = desc, Humanoid = hum, Root = root})
            end
        end
    end
end

local function UpdateTireCache()
    if tick() - lastTireScanTime < 1 then return end
    lastTireScanTime = tick()
    table.clear(tireCache)
    local vehicles = workspace:FindFirstChild("Gameplay") and workspace.Gameplay:FindFirstChild("Vehicles")
    if vehicles then
        for _, car in ipairs(vehicles:GetChildren()) do
            for _, desc in ipairs(car:GetDescendants()) do
                if desc.Name == "WheelCollision" and not desc:GetAttribute("DontPuncture") then
                    table.insert(tireCache, desc)
                end
            end
        end
    end
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
    local targetNPC = Config[mode .. "_TargetNPC"]

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            if #allowedTeams > 0 and (not player.Team or not table.find(allowedTeams, player.Team.Name)) then continue end
            if checkFriends and LocalPlayer:IsFriendsWith(player.UserId) then continue end

            local targetChar = player.Character
            if targetChar and targetChar:FindFirstChild("HumanoidRootPart") and targetChar:FindFirstChild("Humanoid") and targetChar.Humanoid.Health > 0 then
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
                        table.insert(validTargets, {Player = player, Dist = dist, Char = targetChar, Root = targetRoot, IsNPC = false})
                    end
                end
            end
        end
    end

    if targetNPC then
        UpdateNPCCache()
        for _, npcData in ipairs(npcCache) do
            if npcData.Char ~= localChar and npcData.Humanoid.Health > 0 then
                local dist = (npcData.Root.Position - localRoot.Position).Magnitude
                if dist <= range then
                    local isVisible = true
                    if checkVis then
                        local params = RaycastParams.new()
                        params.FilterDescendantsInstances = {localChar}
                        params.FilterType = Enum.RaycastFilterType.Exclude
                        local hit = workspace:Raycast(localRoot.Position, (npcData.Root.Position - localRoot.Position), params)
                        if hit and not hit.Instance:IsDescendantOf(npcData.Char) then isVisible = false end
                    end
                    if isVisible then
                        table.insert(validTargets, {Player = {Name = npcData.Char.Name, UserId = 0}, Dist = dist, Char = npcData.Char, Root = npcData.Root, IsNPC = true})
                    end
                end
            end
        end
    end

    table.sort(validTargets, function(a, b) return a.Dist < b.Dist end)
    return validTargets
end

local function GetValidTires(rangeVal)
    local localChar = LocalPlayer.Character
    if not localChar or not localChar:FindFirstChild("HumanoidRootPart") then return {} end
    local localRoot = localChar.HumanoidRootPart
    local range = rangeVal
    local validTires = {}

    UpdateTireCache()
    for _, tire in ipairs(tireCache) do
        if tire.Parent and tire:GetAttribute("Durability") ~= 0 then
            local dist = (tire.Position - localRoot.Position).Magnitude
            if dist <= range then
                table.insert(validTires, {Tire = tire, Dist = dist, Pos = tire.Position})
            end
        end
    end
    table.sort(validTires, function(a, b) return a.Dist < b.Dist end)
    return validTires
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
    for _, t in ipairs(State.MeleeThreads) do pcall(task.cancel, t) end
    State.MeleeThreads = {}

    local threadCount = Config.Melee_HyperThread and 3 or 1

    for i = 1, threadCount do
        local t = task.spawn(function()
            while Config.Melee_Enabled do
                task.wait(Config.Melee_Delay > 0 and Config.Melee_Delay or 0.016)

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
                local activeChars = {}

                if #targets > 0 and localChar and localChar:FindFirstChild("HumanoidRootPart") then
                    local localRoot = localChar.HumanoidRootPart
                    local localPos = localRoot.Position

                    for _, targetData in ipairs(targets) do
                        local targetChar = targetData.Char
                        table.insert(activeChars, targetChar)

                        task.spawn(function()
                            local bodyPartsArr = Config.Melee_MultiHit and GetBodyPartsArray(targetChar) or {{ [1] = "HumanoidRootPart", [2] = 1 }}
                            local targetPos = targetData.Root.Position
                            -- 修复：shotCode[1]应为攻击者位置(localPos)，shotCode[2]应为朝目标方向，pos应为命中位置(targetPos)
                            -- 根据抓包：shotCode[1]=攻击者坐标，shotCode[2]=(targetPos-localPos).Unit，pos=命中坐标
                            local args = {
                                [1] = "damage",
                                [2] = {
                                    ["bodyParts"] = bodyPartsArr,
                                    ["shotCode"] = { [1] = localPos, [2] = (targetPos - localPos).Unit },
                                    ["target"] = targetData.Player,
                                    ["pos"] = targetPos
                                }
                            }
                            -- 防弹衣穿透：发送bulletProofTool=false绕过防弹背心减伤
                            if Config.BypassBulletProof_Enabled then
                                args[2].bulletProofTool = false
                            end
                            pcall(function() Remote:FireServer(unpack(args)) end)
                            -- 近战攻击线绘制：从玩家位置到目标位置，红色
                            if Config.DrawMeleeLine_Enabled then
                                pcall(function() DrawAttackLine(localPos, targetPos, Color3.fromRGB(255, 50, 50), 0.15) end)
                            end
                        end)
                    end
                end

                if Config.Melee_AutoPopTires then
                    local tires = GetValidTires(Config.Melee_Range)
                    for _, tireData in ipairs(tires) do
                        task.spawn(function()
                            if not localChar or not localChar:FindFirstChild("HumanoidRootPart") then return end
                            local localPos = localChar.HumanoidRootPart.Position
                            local shotCode = { localPos, (tireData.Pos - localPos).Unit }
                            pcall(function()
                                Remote:FireServer("damage", { shotCode = shotCode, pos = tireData.Pos, targetTire = tireData.Tire })
                            end)
                        end)
                    end
                end

                if i == 1 then
                    SyncLockVisuals(activeChars, "Melee", "KillSystem_MeleeLock", Color3.fromRGB(255, 0, 0))
                end
            end
        end)
        table.insert(State.MeleeThreads, t)
    end
end

-- ==========================================
-- [远程战斗逻辑]
-- ==========================================
local function GetEquippedWeaponName()
    local char = LocalPlayer.Character
    if not char then return "Unarmed" end
    for _, item in ipairs(char:GetChildren()) do if item:IsA("Tool") then return item.Name end end
    for _, item in ipairs(char:GetChildren()) do if item:IsA("Model") and item:FindFirstChild("Handle") then return item.Name end end
    return "Unarmed"
end

local function GetBarrelPos(char)
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Tool") then local barrel = item:FindFirstChild("Barrel") or item:FindFirstChild("Handle") if barrel then return barrel.Position end end
    end
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Model") and item:FindFirstChild("Handle") then local barrel = item:FindFirstChild("Barrel") or item:FindFirstChild("Handle") if barrel then return barrel.Position end end
    end
    return char.HumanoidRootPart.Position
end

function StartRangedLoop()
    for _, t in ipairs(State.RangedThreads) do pcall(task.cancel, t) end
    State.RangedThreads = {}

    local threadCount = Config.Ranged_HyperThread and 3 or 1

    for i = 1, threadCount do
        local t = task.spawn(function()
            while Config.Ranged_Enabled do
                task.wait(Config.Ranged_Delay > 0 and Config.Ranged_Delay or 0.016)

                local Remote = FetchRemote()
                if not Remote then task.wait(1) continue end

                local targets = GetValidTargets("Ranged")
                local localChar = LocalPlayer.Character
                local activeChars = {}

                if Config.Ranged_AutoPopTires then
                    local tires = GetValidTires(Config.Ranged_Range)
                    for _, tireData in ipairs(tires) do
                        task.spawn(function()
                            if not localChar or not localChar:FindFirstChild("HumanoidRootPart") then return end
                            local barrelPos = GetBarrelPos(localChar)
                            local shotCode = { barrelPos, (tireData.Pos - barrelPos).Unit }
                            pcall(function()
                                Remote:FireServer("damage", { shotCode = shotCode, pos = tireData.Pos, targetTire = tireData.Tire })
                            end)
                        end)
                    end
                end

                if #targets > 0 and localChar and localChar:FindFirstChild("HumanoidRootPart") then
                    for _, targetData in ipairs(targets) do
                        local targetChar = targetData.Char
                        table.insert(activeChars, targetChar)

                        task.spawn(function()
                            local hitPartName = Config.Ranged_AutoHeadshot and "Head" or "HumanoidRootPart"
                            local hitPart = targetChar:FindFirstChild(hitPartName) or targetChar:FindFirstChild("HumanoidRootPart")
                            if not hitPart then return end

                            local hitPos = hitPart.Position
                            local barrelPos = GetBarrelPos(localChar)
                            local shotCode = { barrelPos, (hitPos - barrelPos).Unit }
                            local weaponName = GetEquippedWeaponName()

                            for i = 1, (Config.Ranged_MultiBullet and 3 or 1) do
                                pcall(function() Remote:FireServer("bullet", { weaponName = weaponName, posDestroyX = hitPos.X + (i * 0.5), pos = hitPos }) end)
                            end

                            local damageArgs = {
                                [1] = "damage",
                                [2] = { bodyParts = { [1] = { [1] = hitPartName, [2] = 1 } }, shotCode = shotCode, target = targetData.Player, pos = hitPos }
                            }
                            if Config.Ranged_AutoHeadshot then damageArgs[2].damageFactor = 1.5 end
                            -- 防弹衣穿透：发送bulletProofTool=false绕过防弹背心减伤
                            if Config.BypassBulletProof_Enabled then
                                damageArgs[2].bulletProofTool = false
                            end
                            pcall(function() Remote:FireServer(unpack(damageArgs)) end)
                            -- 远程攻击线绘制：从枪口位置到命中位置，蓝色
                            if Config.DrawRangedLine_Enabled then
                                pcall(function() DrawAttackLine(barrelPos, hitPos, Color3.fromRGB(50, 150, 255), 0.2) end)
                            end
                        end)
                    end
                end

                if i == 1 then
                    SyncLockVisuals(activeChars, "Ranged", "KillSystem_RangedLock", Color3.fromRGB(0, 0, 255))
                end
            end
        end)
        table.insert(State.RangedThreads, t)
    end
end

-- ==========================================
-- [ESP与实用工具逻辑 - 兼容workspace.Characters]
-- ==========================================
function ClearESP()
    for char, obj in pairs(State.ESPObjects) do
        if obj.Highlight then obj.Highlight:Destroy() end
        if obj.Billboard then obj.Billboard:Destroy() end
    end
    State.ESPObjects = {}
end

local function UpdateESP()
    if not Config.ESP_Enabled then return end

    local drawnChars = {}
    local localChar = LocalPlayer.Character

    local function ApplyESP(char, name, teamColor)
        if char == localChar then return end
        if not char or not char.Parent then return end

        local root = char:FindFirstChild("HumanoidRootPart")
        local hum = char:FindFirstChildOfClass("Humanoid")
        if not root or not hum or hum.Health <= 0 then return end

        drawnChars[char] = true
        local obj = State.ESPObjects[char]

        local needRebuild = false
        if not obj then
            needRebuild = true
        else
            if not obj.Highlight or not obj.Highlight.Parent or obj.Highlight.Parent ~= char then needRebuild = true end
            if not obj.Billboard or not obj.Billboard.Parent or obj.Billboard.Parent ~= root then needRebuild = true end
        end

        if needRebuild then
            if obj then
                if obj.Highlight then pcall(function() obj.Highlight:Destroy() end) end
                if obj.Billboard then pcall(function() obj.Billboard:Destroy() end) end
            end
            obj = {}
            obj.Highlight = Instance.new("Highlight")
            obj.Highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
            obj.Highlight.FillTransparency = 0.7
            obj.Highlight.Parent = char

            obj.Billboard = Instance.new("BillboardGui")
            obj.Billboard.Size = UDim2.new(0, 200, 0, 30)
            obj.Billboard.StudsOffset = Vector3.new(0, 3, 0)
            obj.Billboard.AlwaysOnTop = true
            obj.Billboard.Parent = root

            local lbl = Instance.new("TextLabel", obj.Billboard)
            lbl.Size = UDim2.new(1, 0, 1, 0)
            lbl.BackgroundTransparency = 1
            lbl.TextStrokeTransparency = 0
            lbl.Font = Enum.Font.GothamBold
            lbl.TextSize = 14
            obj.Label = lbl

            State.ESPObjects[char] = obj
        end

        obj.Highlight.FillColor = teamColor or Color3.fromRGB(255, 255, 255)

        local isMeleeLocked = State.VisualRegistry.Melee[char] ~= nil
        local isRangedLocked = State.VisualRegistry.Ranged[char] ~= nil

        local lockText, textColor = "", teamColor or Color3.fromRGB(255, 255, 255)
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
        obj.Label.Text = string.format("%s [%d/%d]%s", name, math.floor(hum.Health), hum.MaxHealth, lockText)
    end

    -- 1. 扫描 Players
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local char = player.Character
            local tColor = player.Team and player.Team.TeamColor.Color or Color3.fromRGB(255, 255, 255)
            if char then ApplyESP(char, player.Name, tColor) end
        end
    end

    -- 2. 扫描 workspace.Characters (该游戏特有机制)
    local wsChars = workspace:FindFirstChild("Characters")
    if wsChars then
        for _, char in ipairs(wsChars:GetChildren()) do
            if char:IsA("Model") and char ~= localChar then
                local player = Players:FindFirstChild(char.Name)
                local tColor = player and player.Team and player.Team.TeamColor.Color or Color3.fromRGB(200, 200, 200)
                ApplyESP(char, char.Name, tColor)
            end
        end
    end

    -- 3. 清理不再需要绘制的 ESP
    for char, obj in pairs(State.ESPObjects) do
        if not drawnChars[char] or not char.Parent then
            if obj.Highlight then obj.Highlight:Destroy() end
            if obj.Billboard then obj.Billboard:Destroy() end
            State.ESPObjects[char] = nil
        end
    end
end

RunService.RenderStepped:Connect(UpdateESP)

-- 互动系统（已移除自动拾取，仅保留秒互动与全图互动）
local function ProcessPrompt(prompt)
    if not prompt:IsA("ProximityPrompt") then return end

    if not prompt:GetAttribute("KS_OrigMaxDist") then
        prompt:SetAttribute("KS_OrigMaxDist", prompt.MaxActivationDistance)
    end
    if not prompt:GetAttribute("KS_OrigHoldDur") then
        prompt:SetAttribute("KS_OrigHoldDur", prompt.HoldDuration)
    end

    if Config.GlobalInteract_Enabled then
        prompt.MaxActivationDistance = 9999
    else
        prompt.MaxActivationDistance = prompt:GetAttribute("KS_OrigMaxDist")
    end

    if Config.InstantInteract_Enabled then
        prompt.HoldDuration = 0
    else
        prompt.HoldDuration = prompt:GetAttribute("KS_OrigHoldDur")
    end
end

local function ScanAndProcessPrompts()
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("ProximityPrompt") then
            ProcessPrompt(obj)
        end
    end
end

workspace.DescendantAdded:Connect(function(d)
    if d:IsA("ProximityPrompt") then
        ProcessPrompt(d)
    end
end)

task.spawn(function()
    while true do
        if Config.InstantInteract_Enabled or Config.GlobalInteract_Enabled then
            pcall(ScanAndProcessPrompts)
            task.wait(1)
        else
            task.wait(2)
        end
    end
end)

-- ==========================================
-- [防御与生存系统 - 基于反编译事件协议]
-- 通过Hook RemoteEvent.OnClientEvent 监听服务器推送的特定事件
-- 并在事件触发后执行防御性反制操作
-- ==========================================

-- 远程事件监听Hook：拦截服务器推送的特定事件并执行防御逻辑
task.spawn(function()
    local remote = FetchRemote()
    if not remote then
        task.wait(3)
        remote = FetchRemote()
    end
    if not remote then
        warn("[KillSystem] 防御系统：未找到RemoteEvent，事件监听未启动")
        return
    end

    remote.OnClientEvent:Connect(function(eventName, ...)
        -- 永久免战模式：检测到服务器推送combatMode事件（战斗被触发）时发送一次false
        -- 修正：发送false后40秒内仍为战斗状态，40秒后才非战斗
        -- 所以不能频繁发送false（会重置计时），只在战斗被触发时发送一次
        if Config.PermanentAntiCombat_Enabled and not Config.PermanentCombat_Enabled and eventName == "combatMode" then
            local combatMsg = ...
            -- 服务器推送combatMode带字符串消息表示战斗开始，带nil/false表示战斗结束
            -- 只在战斗开始时发送false（取消战斗）
            if combatMsg then
                task.spawn(function()
                    task.wait(0.1)  -- 稍微延迟避免与服务器事件冲突
                    local r = FetchRemote()
                    if r then
                        pcall(function() r:FireServer("combatMode", false) end)
                        print("[战斗控制] 检测到战斗触发，已发送combatMode,false启动40秒倒计时")
                    end
                end)
            end
        end

        -- 反死亡视觉：拦截killedVisual事件，禁用KilledColorCorrection
        -- 游戏原始处理：启用KilledColorCorrection并Tween亮度/对比度/饱和度
        -- 我们的对策：延迟一帧后强制禁用并归零所有参数
        if Config.NoKilledVisual_Enabled and eventName == "killedVisual" then
            task.spawn(function()
                task.wait(0.05)
                local cc = game.Lighting:FindFirstChild("KilledColorCorrection")
                if cc then
                    cc.Enabled = false
                    cc.Brightness = 0
                    cc.Contrast = 0
                    cc.Saturation = 0
                end
            end)
        end

        -- 反强制Ragdoll：拦截ragdoll事件，自动调用GettingUp恢复
        -- 游戏原始处理：调用v_u_9.activate(char, p194, p195, true) 激活Ragdoll
        -- 我们的对策：延迟0.1秒后强制切换到GettingUp状态起身
        if Config.AntiRagdoll_Enabled and eventName == "ragdoll" then
            task.spawn(function()
                task.wait(0.1)
                local char = LocalPlayer.Character
                if char and char:FindFirstChild("Humanoid") then
                    char.Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
                end
            end)
        end

        -- 反强制弹出：拦截eject事件，等待禁用期后重新进入最近车辆
        -- 游戏原始处理：v_u_8.disabled(true, "eject") 禁用互动 Handcuffs.HoldDuration*2 秒
        -- 我们的对策：等待禁用期结束，寻找30 studs内最近车辆并触发ProximityPrompt
        if Config.AntiEject_Enabled and eventName == "eject" then
            task.spawn(function()
                -- 计算eject禁用时长（Handcuffs.HoldDuration.Value * 2 + 1秒缓冲）
                local waitTime = 5
                pcall(function()
                    local handcuffs = game.ReplicatedStorage:FindFirstChild("Gameplay")
                    if handcuffs then
                        handcuffs = handcuffs:FindFirstChild("Items")
                    end
                    if handcuffs then
                        handcuffs = handcuffs:FindFirstChild("Handcuffs")
                    end
                    if handcuffs then
                        local hd = handcuffs:FindFirstChild("HoldDuration")
                        if hd and (hd:IsA("NumberValue") or hd:IsA("IntValue")) then
                            waitTime = hd.Value * 2 + 1
                        end
                    end
                end)
                task.wait(waitTime)

                -- 寻找最近的车辆
                local char = LocalPlayer.Character
                if not char or not char:FindFirstChild("HumanoidRootPart") then return end
                local localPos = char.HumanoidRootPart.Position
                local nearestVehicle = nil
                local nearestDist = math.huge
                local vehicles = workspace:FindFirstChild("Gameplay") and workspace.Gameplay:FindFirstChild("Vehicles")
                if vehicles then
                    for _, car in ipairs(vehicles:GetChildren()) do
                        if car:IsA("Model") then
                            local primaryPart = car.PrimaryPart or car:FindFirstChild("HumanoidRootPart") or car:FindFirstChildWhichIsA("BasePart")
                            if primaryPart then
                                local dist = (primaryPart.Position - localPos).Magnitude
                                if dist < nearestDist and dist < 30 then
                                    nearestDist = dist
                                    nearestVehicle = car
                                end
                            end
                        end
                    end
                end

                -- 尝试通过ProximityPrompt进入车辆
                if nearestVehicle then
                    local promptFound = false
                    for _, desc in ipairs(nearestVehicle:GetDescendants()) do
                        if desc:IsA("ProximityPrompt") then
                            local txt = string.lower(desc.ActionText .. " " .. desc.ObjectText)
                            if string.find(txt, "enter") or string.find(txt, "sit") or string.find(txt, "drive") or string.find(txt, "seat") then
                                pcall(function() desc:InputHoldBegin() end)
                                task.wait(0.15)
                                pcall(function() desc:InputHoldEnd() end)
                                promptFound = true
                                break
                            end
                        end
                    end
                    -- 如果没找到进入Prompt，尝试走向车辆
                    if not promptFound and char:FindFirstChild("Humanoid") then
                        char.Humanoid:MoveTo(nearestVehicle.PrimaryPart.Position)
                    end
                end
            end)
        end

        -- 反强制隐藏：拦截characterHidden事件，恢复触控与装备权限
        -- 游戏原始处理：禁用TouchControls、禁用EquipSlot、停用Ragdoll
        -- 我们的对策：恢复TouchControlsEnabled，标记装备槽为可用
        if Config.AntiCharHidden_Enabled and eventName == "characterHidden" then
            local hidden = ...
            if hidden then
                -- 恢复触控
                pcall(function()
                    game:GetService("GuiService").TouchControlsEnabled = true
                end)
                -- 尝试通过Remote恢复装备权限
                local r = FetchRemote()
                if r then
                    pcall(function() r:FireServer("characterIsPhysicallyOccupied", false) end)
                end
            end
        end
    end)
end)

-- 快速起身循环：持续监控Humanoid状态，物理Ragdoll时立即起身
-- 与AntiRagdoll互补：AntiRagdoll只拦截服务器ragdoll事件，
-- FastGetUp能捕获所有进入Physics状态的Ragdoll（包括物理碰撞导致）
task.spawn(function()
    while true do
        if Config.FastGetUp_Enabled then
            local char = LocalPlayer.Character
            if char and char:FindFirstChild("Humanoid") then
                local hum = char.Humanoid
                local state = hum:GetState()
                -- Physics状态通常表示Ragdoll（包括被车撞、爆炸等物理触发）
                if state == Enum.HumanoidStateType.Physics then
                    hum:ChangeState(Enum.HumanoidStateType.GettingUp)
                end
            end
            task.wait(0.1)
        else
            task.wait(1)
        end
    end
end)

-- 持续清理视觉效果：移除游戏添加的非系统Lighting效果
-- 保留我们自己的BlurEffect（名为KillSystem_Blur）
-- 如果NoKilledVisual开启，则KilledColorCorrection由其管理
local CleanEffectsLastCheck = 0
task.spawn(function()
    while true do
        if Config.CleanLightingEffects_Enabled then
            -- 限频检查，避免每帧遍历
            if tick() - CleanEffectsLastCheck >= 1 then
                CleanEffectsLastCheck = tick()
                for _, child in ipairs(game.Lighting:GetChildren()) do
                    -- 跳过我们自己的BlurEffect
                    if child.Name == "KillSystem_Blur" then continue end
                    -- 如果NoKilledVisual开启，跳过KilledColorCorrection（由其管理）
                    if child.Name == "KilledColorCorrection" and Config.NoKilledVisual_Enabled then continue end
                    -- 禁用各种视觉效果
                    if child:IsA("ColorCorrectionEffect") or child:IsA("BloomEffect") or
                       child:IsA("DepthOfFieldEffect") or child:IsA("SunRaysEffect") or
                       child:IsA("BlurEffect") or child:IsA("Atmosphere") then
                        pcall(function() child.Enabled = false end)
                    end
                end
            end
            task.wait(0.5)
        else
            task.wait(2)
        end
    end
end)

print("[KillSystem v10.18] 防御系统扩展版已加载。")

-- ==========================================
-- [防御系统 v2 - 状态轮询双重保障]
-- 问题：v1基于OnClientEvent事件监听，但可能因为以下原因失效：
--   1. 游戏的Ragdoll模块（v_u_9）可能使用自定义机制，不依赖Humanoid状态
--   2. PlatformStand为true时ChangeState(GettingUp)无效
--   3. Motor6D被禁用后需要手动重新启用
--   4. 事件监听器可能被游戏的包装机制过滤
-- 解决：使用RunService.Heartbeat持续强制状态，不依赖事件
-- ==========================================

local Heartbeat = RunService.Heartbeat
local GuiService = game:GetService("GuiService")

-- 调试计数器（控制台输出频率限制）
local DefDebugCounter = {
    AntiRagdoll = 0,
    FastGetUp = 0,
    NoKilledVisual = 0,
    AntiCharHidden = 0,
    AntiEject = 0
}

-- 持续状态强制循环：每帧检查并强制防御状态
Heartbeat:Connect(function()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChild("Humanoid")

    -- 反强制Ragdoll：持续强制PlatformStand=false、重新启用Motor6D
    if Config.AntiRagdoll_Enabled and hum then
        if hum.PlatformStand then
            hum.PlatformStand = false
            DefDebugCounter.AntiRagdoll = DefDebugCounter.AntiRagdoll + 1
            if DefDebugCounter.AntiRagdoll % 30 == 1 then
                print("[防御] AntiRagdoll: 强制PlatformStand=false")
            end
        end
        -- 重新启用所有Motor6D（Ragdoll模块会禁用它们）
        if char then
            for _, motor in ipairs(char:GetDescendants()) do
                if motor:IsA("Motor6D") and not motor.Enabled then
                    motor.Enabled = true
                end
            end
        end
        -- 调用GettingUp状态（每60帧调一次，避免过度调用）
        if DefDebugCounter.AntiRagdoll % 60 == 0 then
            local state = hum:GetState()
            if state == Enum.HumanoidStateType.Physics or state == Enum.HumanoidStateType.FallingDown then
                hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            end
        end
        DefDebugCounter.AntiRagdoll = DefDebugCounter.AntiRagdoll + 1
    end

    -- 快速起身：检测多种Ragdoll状态，立即起身
    if Config.FastGetUp_Enabled and hum then
        local state = hum:GetState()
        local needGetUp = false
        if state == Enum.HumanoidStateType.Physics then
            needGetUp = true
        elseif state == Enum.HumanoidStateType.FallingDown then
            needGetUp = true
        elseif hum.PlatformStand then
            needGetUp = true
        end
        if needGetUp then
            hum.PlatformStand = false
            hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            DefDebugCounter.FastGetUp = DefDebugCounter.FastGetUp + 1
            if DefDebugCounter.FastGetUp % 30 == 1 then
                print("[防御] FastGetUp: 检测到Ragdoll状态，强制起身")
            end
        end
    end

    -- 反死亡视觉：持续监控KilledColorCorrection.Enabled
    if Config.NoKilledVisual_Enabled then
        local cc = game.Lighting:FindFirstChild("KilledColorCorrection")
        if cc and cc.Enabled then
            cc.Enabled = false
            cc.Brightness = 0
            cc.Contrast = 0
            cc.Saturation = 0
            DefDebugCounter.NoKilledVisual = DefDebugCounter.NoKilledVisual + 1
            if DefDebugCounter.NoKilledVisual % 10 == 1 then
                print("[防御] NoKilledVisual: 检测到死亡视觉启用，已强制禁用")
            end
        end
    end

    -- 反强制隐藏：持续监控TouchControlsEnabled
    if Config.AntiCharHidden_Enabled then
        if not GuiService.TouchControlsEnabled then
            GuiService.TouchControlsEnabled = true
            DefDebugCounter.AntiCharHidden = DefDebugCounter.AntiCharHidden + 1
            if DefDebugCounter.AntiCharHidden % 30 == 1 then
                print("[防御] AntiCharHidden: 检测到触控被禁用，已恢复")
            end
        end
        -- 尝试通过Remote恢复装备权限（限频，避免高频发包）
        if DefDebugCounter.AntiCharHidden % 60 == 0 then
            local r = FetchRemote()
            if r then
                pcall(function() r:FireServer("characterIsPhysicallyOccupied", false) end)
            end
        end
    end
end)

-- 反强制弹出增强版：事件驱动 + 重试机制 + 直接FireServer
-- v1问题：依赖ProximityPrompt可能找不到或触发失败
-- v2改进：1.增加直接FireServer('enterVehicle')备用方案 2.多次重试 3.增加等待时间
local EjectRetryThread = nil
task.spawn(function()
    local remote = FetchRemote()
    if not remote then
        task.wait(3)
        remote = FetchRemote()
    end
    if not remote then return end

    remote.OnClientEvent:Connect(function(eventName, ...)
        if Config.AntiEject_Enabled and eventName == "eject" then
            print("[防御] AntiEject: 检测到eject事件，启动反弹出序列")
            -- 取消之前的重试线程
            if EjectRetryThread then pcall(task.cancel, EjectRetryThread) end
            EjectRetryThread = task.spawn(function()
                -- 等待eject禁用期（默认Handcuffs.HoldDuration*2，备选5秒）
                local waitTime = 5
                pcall(function()
                    local handcuffs = game.ReplicatedStorage:FindFirstChild("Gameplay")
                    if handcuffs then handcuffs = handcuffs:FindFirstChild("Items") end
                    if handcuffs then handcuffs = handcuffs:FindFirstChild("Handcuffs") end
                    if handcuffs then
                        local hd = handcuffs:FindFirstChild("HoldDuration")
                        if hd and (hd:IsA("NumberValue") or hd:IsA("IntValue")) then
                            waitTime = hd.Value * 2 + 1
                        end
                    end
                end)
                task.wait(waitTime)

                -- 重试进入车辆（最多3次）
                for attempt = 1, 3 do
                    local char = LocalPlayer.Character
                    if not char or not char:FindFirstChild("HumanoidRootPart") then break end
                    local localPos = char.HumanoidRootPart.Position
                    local nearestVehicle = nil
                    local nearestDist = math.huge
                    local vehicles = workspace:FindFirstChild("Gameplay") and workspace.Gameplay:FindFirstChild("Vehicles")
                    if vehicles then
                        for _, car in ipairs(vehicles:GetChildren()) do
                            if car:IsA("Model") then
                                local primaryPart = car.PrimaryPart or car:FindFirstChildWhichIsA("BasePart")
                                if primaryPart then
                                    local dist = (primaryPart.Position - localPos).Magnitude
                                    if dist < nearestDist and dist < 50 then
                                        nearestDist = dist
                                        nearestVehicle = car
                                    end
                                end
                            end
                        end
                    end

                    if nearestVehicle then
                        print(string.format("[防御] AntiEject: 尝试 #%d 进入车辆 %s (距离%.1f studs)",
                            attempt, nearestVehicle.Name, nearestDist))

                        -- 方法1：直接通过RemoteEvent请求进入车辆
                        local r = FetchRemote()
                        if r then
                            pcall(function() r:FireServer("enterVehicle", nearestVehicle) end)
                        end

                        -- 方法2：触发ProximityPrompt
                        for _, desc in ipairs(nearestVehicle:GetDescendants()) do
                            if desc:IsA("ProximityPrompt") and desc.Enabled then
                                pcall(function() desc:InputHoldBegin() end)
                                task.wait(0.2)
                                pcall(function() desc:InputHoldEnd() end)
                                break
                            end
                        end

                        -- 方法3：走向车辆（如果还没进入）
                        task.wait(1)
                        local seat = char:FindFirstChild("Seat")
                        local isInVehicle = false
                        if seat and seat:IsA("Weld") and seat.Part1 then
                            isInVehicle = true
                        end
                        -- 检查是否还在车里（通过RootPart的Velocity或Seat属性）
                        if char:FindFirstChild("Humanoid") and char.Humanoid.Sit then
                            isInVehicle = true
                        end
                        if not isInVehicle and char:FindFirstChild("HumanoidRootPart") then
                            local vehiclePos = nearestVehicle.PrimaryPart and nearestVehicle.PrimaryPart.Position or nearestVehicle:GetPivot().Position
                            char.Humanoid:MoveTo(vehiclePos)
                        end
                        if isInVehicle then
                            print("[防御] AntiEject: 成功重新进入车辆")
                            return
                        end
                    else
                        print(string.format("[防御] AntiEject: 尝试 #%d 未找到附近车辆", attempt))
                    end
                    task.wait(1.5)
                end
                print("[防御] AntiEject: 反弹出序列结束")
            end)
        end
    end)
end)

-- ==========================================
-- [快捷键透明度同步系统]
-- 修复：快捷键透明度可能卡在0.5无法变回0.2
-- 原因：isDragging标志卡true、弹窗内Toggle切换后快捷键未同步
-- 解决：Heartbeat持续同步所有快捷键透明度到当前Config状态
-- ==========================================
RunService.Heartbeat:Connect(function()
    for _, shortcut in ipairs(State.Shortcuts) do
        if shortcut and shortcut.Parent then
            local key = shortcut:GetAttribute("ConfigKey")
            if key and Config[key] ~= nil then
                local targetTransparency = Config[key] and 0.2 or 0.5
                -- 只在透明度不一致时更新，避免每帧无意义写入
                if shortcut.BackgroundTransparency ~= targetTransparency then
                    shortcut.BackgroundTransparency = targetTransparency
                end
            end
        end
    end
end)

print("[KillSystem v10.21] 近战修复与快捷键同步版已加载。")

-- ==========================================
-- [战斗状态控制系统 - 基于combatMode协议]
-- 协议说明（修正版）：
--   combatMode, true  = 永久战斗状态（不会自动消失）
--   combatMode, false = 启动40秒倒计时，40秒内仍为战斗状态，40秒后才变为非战斗
--   重新发送false会重置40秒倒计时（导致永远无法变非战斗）
-- 实现策略（修正版）：
--   永久战斗模式：每30秒发送一次combatMode,true（保险，防止意外失效）
--   永久免战模式：事件驱动，检测到服务器推送combatMode事件（战斗被触发）时才发送一次false
--                 让40秒倒计时自然过期，不频繁发送避免重置计时
-- 互斥逻辑：两个模式同时开启时，永久战斗模式优先
-- ==========================================
local CombatControlLastSend = 0
task.spawn(function()
    while true do
        -- 永久战斗模式：每30秒发送一次true
        if Config.PermanentCombat_Enabled then
            if tick() - CombatControlLastSend >= 30 then
                CombatControlLastSend = tick()
                local remote = FetchRemote()
                if remote then
                    pcall(function() remote:FireServer("combatMode", true) end)
                end
            end
            task.wait(1)
        else
            -- 永久免战模式由OnClientEvent事件驱动，这里不需要循环发包
            task.wait(2)
        end
    end
end)

-- ==========================================
-- [自动装备武器系统 - 基于equipItem协议]
-- 协议说明：
--   equipItem, toolInstance = 装备指定工具实例
-- 实现策略：
--   当近战或远程攻击激活时，检测是否已装备武器
--   如果未装备，自动寻找背包中的第一个武器并发送equipItem
-- ==========================================
local function IsWeaponEquipped()
    local char = LocalPlayer.Character
    if not char then return false end
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Tool") then return true end
        if item:IsA("Model") and item:FindFirstChild("Handle") then return true end
    end
    return false
end

local function FindAndEquipWeapon()
    local char = LocalPlayer.Character
    if not char then return false end
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    if not backpack then return false end

    -- 优先寻找枪械类武器（有GUN配置）
    local weapons = {}
    for _, item in ipairs(backpack:GetChildren()) do
        if item:IsA("Tool") then
            table.insert(weapons, item)
        end
    end

    -- 如果背包没有，检查角色（可能已装备但检测失败）
    if #weapons == 0 then return false end

    -- 优先选择有Config且Config.GUN存在的武器
    local bestWeapon = nil
    for _, w in ipairs(weapons) do
        local cfg = w:FindFirstChild("Config")
        if cfg then
            local success, cfgData = pcall(require, cfg)
            if success and cfgData and cfgData.GUN then
                bestWeapon = w
                break
            end
        end
    end
    -- 没有枪械就选第一个工具
    if not bestWeapon then bestWeapon = weapons[1] end

    local remote = FetchRemote()
    if remote and bestWeapon then
        pcall(function() remote:FireServer("equipItem", bestWeapon) end)
        return true
    end
    return false
end

-- 自动装备检测循环：当攻击功能激活且未装备武器时自动装备
local AutoEquipLastCheck = 0
task.spawn(function()
    while true do
        if Config.AutoEquipWeapon_Enabled and (Config.Melee_Enabled or Config.Ranged_Enabled) then
            -- 每2秒检查一次，避免高频发包
            if tick() - AutoEquipLastCheck >= 2 then
                AutoEquipLastCheck = tick()
                if not IsWeaponEquipped() then
                    FindAndEquipWeapon()
                end
            end
            task.wait(1)
        else
            task.wait(2)
        end
    end
end)

print("[KillSystem v10.26] 攻击线性能优化版已加载。")

-- ==========================================
-- [攻击线绘制系统 - 3D Beam优化版]
-- 修复：2D GUI线绘制错误且每条线一个RenderStepped连接导致严重卡顿
-- 改进：1.改回3D Beam（位置准确，无需投影计算）
--       2.单一RenderStepped连接统一管理所有线的生命周期
--       3.限制最大数量20条，超过删除最老的
--       4.关闭开关时立即清理所有Beam实例
--       5.Beam挂在单一容器下，便于统一清理
-- ==========================================
local MAX_ATTACK_LINES = 20  -- 最大同时存在的攻击线数量
local AttackLineContainer = nil  -- Beam容器，延迟创建

-- 获取或创建Beam容器
local function GetAttackLineContainer()
    if AttackLineContainer and AttackLineContainer.Parent then return AttackLineContainer end
    AttackLineContainer = Instance.new("Folder")
    AttackLineContainer.Name = "KillSystem_AttackLines"
    AttackLineContainer.Parent = workspace
    return AttackLineContainer
end

ClearAttackLines = function()
    -- 立即清理所有活跃的攻击线实例
    for _, lineData in ipairs(State.AttackLines) do
        if lineData and lineData.beamPart then
            pcall(function() lineData.beamPart:Destroy() end)
        end
    end
    State.AttackLines = {}
end

DrawAttackLine = function(startPos, endPos, color, duration)
    duration = duration or 0.2
    local container = GetAttackLineContainer()

    -- 如果超过最大数量，删除最老的线
    if #State.AttackLines >= MAX_ATTACK_LINES then
        local oldest = table.remove(State.AttackLines, 1)
        if oldest and oldest.beamPart then
            pcall(function() oldest.beamPart:Destroy() end)
        end
    end

    -- 创建单一锚点Part挂载两个Attachment和Beam
    local beamPart = Instance.new("Part")
    beamPart.Anchored = true
    beamPart.CanCollide = false
    beamPart.CanQuery = false
    beamPart.CanTouch = false
    beamPart.Transparency = 1
    beamPart.Size = Vector3.new(0.1, 0.1, 0.1)
    beamPart.Position = startPos
    beamPart.Parent = container

    local att0 = Instance.new("Attachment")
    att0.Position = Vector3.new(0, 0, 0)
    att0.Parent = beamPart

    local att1 = Instance.new("Attachment")
    -- 相对位置 = endPos - startPos
    att1.Position = endPos - startPos
    att1.Parent = beamPart

    local beam = Instance.new("Beam")
    beam.Attachment0 = att0
    beam.Attachment1 = att1
    beam.Color = ColorSequence.new(color)
    beam.Transparency = NumberSequence.new(0.2)
    beam.Width0 = 0.3
    beam.Width1 = 0.3
    beam.FaceCamera = true
    beam.Parent = beamPart

    local lineData = {
        beamPart = beamPart,
        beam = beam,
        creationTime = tick(),
        duration = duration
    }
    table.insert(State.AttackLines, lineData)
end

-- 单一RenderStepped连接：统一管理所有攻击线的生命周期
-- 这样无论有多少条线，只有1个连接，不会卡顿
RunService.RenderStepped:Connect(function()
    if #State.AttackLines == 0 then return end

    -- 检查功能是否仍开启（都关闭则清理所有）
    local anyEnabled = Config.DrawMeleeLine_Enabled or Config.DrawRangedLine_Enabled
    if not anyEnabled then
        if #State.AttackLines > 0 then
            ClearAttackLines()
        end
        return
    end

    -- 遍历清理过期线（从后往前删除安全）
    local now = tick()
    for i = #State.AttackLines, 1, -1 do
        local lineData = State.AttackLines[i]
        if lineData and now - lineData.creationTime > lineData.duration then
            -- 过期，删除
            if lineData.beamPart then
                pcall(function() lineData.beamPart:Destroy() end)
            end
            table.remove(State.AttackLines, i)
        end
    end
end)

nt(endPos)

        -- 至少一个点在屏幕外时不绘制
        if not onScreen1 or not onScreen2 then
            lineFrame.Visible = false
            return
        end
        lineFrame.Visible = true

        -- 计算线的中点、长度、角度
        local dx = endScreenPos.X - startScreenPos.X
        local dy = endScreenPos.Y - startScreenPos.Y
        local length = math.sqrt(dx * dx + dy * dy)
        local angle = math.deg(math.atan2(dy, dx))

        lineFrame.Position = UDim2.fromOffset(startScreenPos.X, startScreenPos.Y)
        lineFrame.Size = UDim2.fromOffset(length, 2)
        lineFrame.Rotation = angle

        -- 随时间淡出透明度
        local progress = (tick() - lineData.creationTime) / duration
        lineFrame.BackgroundTransparency = progress * 0.7 + 0.1
    end)

    table.insert(State.AttackLines, lineData)
end
向向量并放大100倍（与游戏原始格式一致）
                local rotX = math.round(lookVec.X * 100)
                local rotZ = math.round(lookVec.Z * 100)
                return oldUnreliableFire(self, "charRot", Vector2.new(rotX, rotZ))
            end
        end
        return oldUnreliableFire(self, cmd, ...)
    end
    print("[KillSystem] UnreliableEvent.charRot Hook 已启动")
end)

-- ==========================================
-- [UI 构建逻辑]
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
local ActivePopup = nil

local function ToggleSideBar(show)
    isSideBarOut = show
    if show then
        TweenService:Create(SideBar, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Position = UDim2.new(1, -90, 0.5, -130)}):Play()
        if State.AutoHideThread then task.cancel(State.AutoHideThread) end
        State.AutoHideThread = task.delay(5, function()
            if isSideBarOut and not (ActivePopup and ActivePopup.Parent) then ToggleSideBar(false) end
        end)
    else
        TweenService:Create(SideBar, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Position = UDim2.new(1, 0, 0.5, -130)}):Play()
    end
end

-- 修复：弹窗打开时点击侧栏触发按钮应先关闭弹窗，避免UI状态混乱
SideBarTrigger.MouseButton1Click:Connect(function()
    if ActivePopup then ClosePopup() return end
    ToggleSideBar(not isSideBarOut)
end)

-- 修复：ClosePopup改为非yield，避免调用方时序问题；新增showSidebar参数控制是否回弹侧栏
ClosePopup = function(showSidebar)
    if not ActivePopup then return end
    local pop = ActivePopup
    ActivePopup = nil
    TweenService:Create(pop, TweenInfo.new(0.2), {Size = UDim2.new(0, 0, 0, 0)}):Play()
    TweenService:Create(BlurEffect, TweenInfo.new(0.2), {Size = 0}):Play()
    task.delay(0.2, function()
        if pop and pop.Parent then pop:Destroy() end
    end)
    if showSidebar ~= false then
        ToggleSideBar(true)
    end
end

-- 修复：快捷键放置函数，统一管理快捷键创建与注册
local function PlaceShortcutAt(pos, key, iconText)
    local shortcut = Instance.new("TextButton")
    shortcut.Size = UDim2.new(0, 50, 0, 50)
    shortcut.Position = UDim2.new(0, pos.X - 25, 0, pos.Y - 25)
    shortcut.BackgroundColor3 = Theme.Darker
    shortcut.BackgroundTransparency = Config[key] and 0.2 or 0.5
    shortcut.Text = iconText or "⚡"
    shortcut.TextColor3 = Theme.C1
    shortcut.Font = Enum.Font.GothamBold
    shortcut.TextSize = 20
    shortcut.Parent = ScreenGui
    Instance.new("UICorner", shortcut).CornerRadius = UDim.new(1, 0)
    shortcut:SetAttribute("ConfigKey", key)
    table.insert(State.Shortcuts, shortcut)
    if not State.ShortcutsByConfigKey[key] then State.ShortcutsByConfigKey[key] = {} end
    table.insert(State.ShortcutsByConfigKey[key], shortcut)

    local isPressing = false
    local isDragging = false
    local pressTime = 0
    local dragStartPos = nil
    local startUdimPos = nil

    shortcut.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            isPressing = true
            isDragging = false
            pressTime = tick()
            dragStartPos = inp.Position
            startUdimPos = shortcut.Position
        end
    end)

    shortcut.InputChanged:Connect(function(inp)
        if isPressing and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
            if dragStartPos and (inp.Position - dragStartPos).Magnitude > 15 then
                isDragging = true
                local dx = inp.Position.X - dragStartPos.X
                local dy = inp.Position.Y - dragStartPos.Y
                shortcut.Position = UDim2.new(startUdimPos.X.Scale, startUdimPos.X.Offset + dx, startUdimPos.Y.Scale, startUdimPos.Y.Offset + dy)
            end
        end
    end)

    shortcut.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            if not isPressing then return end
            isPressing = false

            local duration = tick() - pressTime
            if not isDragging then
                if duration >= 0.8 then
                    -- 长按删除
                    local k = shortcut:GetAttribute("ConfigKey")
                    shortcut:Destroy()
                    for i, sc in ipairs(State.Shortcuts) do if sc == shortcut then table.remove(State.Shortcuts, i) break end end
                    if k and State.ShortcutsByConfigKey[k] then
                        for i, sc in ipairs(State.ShortcutsByConfigKey[k]) do if sc == shortcut then table.remove(State.ShortcutsByConfigKey[k], i) break end end
                    end
                else
                    -- 短按切换
                    if ActivePopup then ClosePopup(false) end
                    Config[key] = not Config[key]
                    if State.GlobalCallbacks[key] then State.GlobalCallbacks[key](Config[key]) end
                    shortcut.BackgroundTransparency = Config[key] and 0.2 or 0.5
                end
            end
        end
    end)
end

-- 修复：快捷键放置模式改用全屏捕获按钮，避免点击穿透；增加视觉提示与ESC取消
local function StartPlacementMode(configKey, iconText)
    State.IsPlacingShortcut = true
    State.CurrentActionToBind = { configKey = configKey, icon = iconText }

    local capture = Instance.new("TextButton")
    capture.Size = UDim2.new(1, 0, 1, 0)
    capture.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    capture.BackgroundTransparency = 0.6
    capture.Text = "点击屏幕任意位置放置快捷键（ESC取消）"
    capture.TextColor3 = Color3.fromRGB(255, 255, 255)
    capture.TextStrokeTransparency = 0
    capture.Font = Enum.Font.GothamBold
    capture.TextSize = 22
    capture.ZIndex = 100
    capture.AutoButtonColor = false
    capture.Parent = ScreenGui
    State.PlacementCapture = capture

    capture.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            local pos = input.Position
            local bindAction = State.CurrentActionToBind
            State.IsPlacingShortcut = false
            State.CurrentActionToBind = nil
            State.PlacementCapture = nil
            capture:Destroy()
            if bindAction then
                PlaceShortcutAt(pos, bindAction.configKey, bindAction.icon)
            end
            ToggleSideBar(true)
        end
    end)
end

-- ESC取消放置模式
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if State.IsPlacingShortcut and input.KeyCode == Enum.KeyCode.Escape then
        State.IsPlacingShortcut = false
        State.CurrentActionToBind = nil
        if State.PlacementCapture then
            State.PlacementCapture:Destroy()
            State.PlacementCapture = nil
        end
        ToggleSideBar(true)
    end
end)

local function OpenPopup(TitleText, BuildContentFunc)
    -- 修复：打开弹窗时取消侧栏自动隐藏线程，避免无用残留
    if State.AutoHideThread then task.cancel(State.AutoHideThread) State.AutoHideThread = nil end
    if ActivePopup then ClosePopup(false) end
    Theme = GenerateNeonTheme()
    ToggleSideBar(false)

    SideBar.BackgroundColor3 = Theme.Darker
    ApplyGradient(sbStroke)
    ApplyGradient(SideBarTrigger)

    -- 修复：同步侧栏图标颜色至新主题
    for _, icon in ipairs(State.SideIcons) do
        icon.BackgroundColor3 = Theme.Dark
        icon.TextColor3 = Theme.C1
        for _, child in ipairs(icon:GetChildren()) do
            if child:IsA("UIStroke") then
                ApplyGradient(child)
            end
        end
    end

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
    CloseBtn.MouseButton1Click:Connect(function() ClosePopup() end)

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

local function CreateRow(parent, height)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, height)
    row.BackgroundColor3 = Theme.Darker
    row.Parent = parent
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)
    return row
end

-- 修复：CreateToggle增加wasLongPress标志，避免长按设置快捷键后误触开关切换；增加快捷键透明度同步
local function CreateToggle(parent, name, configKey, icon)
    local row = CreateRow(parent, 40)
    local state = Config[configKey]
    local wasLongPress = false

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

    local function SyncShortcuts()
        local shortcuts = State.ShortcutsByConfigKey[configKey]
        if shortcuts then
            for _, sc in ipairs(shortcuts) do
                sc.BackgroundTransparency = state and 0.2 or 0.5
            end
        end
    end

    local function ToggleState()
        -- 修复：如果是长按触发的释放，不切换状态
        if wasLongPress then
            wasLongPress = false
            return
        end
        state = not state
        Config[configKey] = state
        UpdateVisual()
        SyncShortcuts()  -- 修复：同步快捷键透明度
        if State.GlobalCallbacks[configKey] then State.GlobalCallbacks[configKey](state) end
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
                        -- 修复：检查弹窗是否仍然有效（防止弹窗已关闭后误触发）
                        if not ActivePopup or not ActivePopup.Parent then return end
                        wasLongPress = true
                        ClosePopup(false)
                        ToggleSideBar(false)
                        StartPlacementMode(configKey, icon)
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

local function CreateSlider(parent, name, minVal, maxVal, default, configKey, isFloat)
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
    valLabel.Text = isFloat and string.format("%.2f", default) or tostring(default)
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
        local val = isFloat and (minVal + (maxVal - minVal) * rel) or math.floor(minVal + (maxVal - minVal) * rel)
        fill.Size = UDim2.new(rel, 0, 1, 0)
        valLabel.Text = isFloat and string.format("%.2f", val) or tostring(val)
        Config[configKey] = val
    end

    barBg.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            update(input.Position)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then update(input.Position) end
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
        for _, child in ipairs(listContainer:GetChildren()) do if child:IsA("TextButton") then child:Destroy() end end
        local teams = getOptionsFunc()
        if #selectedTable == 0 then for _, team in ipairs(teams) do table.insert(selectedTable, team.Name) end end
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
            if table.find(selectedTable, team.Name) ~= nil then tBtn.BackgroundColor3 = Theme.C1 end
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
    table.insert(State.SideIcons, btn)  -- 新增：注册图标引用
    return btn
end

CreateSideIcon("⚔️", function()
    OpenPopup("近战杀戮", function(holder)
        CreateSlider(holder, "发包延迟 (0=极速)", 0, 1, Config.Melee_Delay, "Melee_Delay", true)
        CreateSlider(holder, "攻击范围", 5, 1000, Config.Melee_Range, "Melee_Range", false)
        CreateToggle(holder, "自动攻击", "Melee_Enabled", "⚔️")
        CreateToggle(holder, "高度多线程", "Melee_HyperThread", "🚀")
        CreateToggle(holder, "多部位打击", "Melee_MultiHit", "🎯")
        CreateToggle(holder, "强制战斗模式", "Melee_ForceCombatMode", "🔥")
        CreateToggle(holder, "自身免战斗模式", "Melee_SelfAntiCombatMode", "🛡️")
        CreateToggle(holder, "瞄准 NPC", "Melee_TargetNPC", "👾")
        CreateToggle(holder, "自动爆胎模式", "Melee_AutoPopTires", "🛞")
        CreateToggle(holder, "好友检测", "Melee_CheckFriends", "🤝")
        CreateToggle(holder, "可见性检测", "Melee_CheckVisibility", "👁️")
        local function GetTeams() local t = {} for _, team in ipairs(game:GetService("Teams"):GetTeams()) do table.insert(t, team) end return t end
        CreateMultiSelectList(holder, "队伍选择检测", GetTeams, "Melee_AllowedTeams", function(sel) end)
    end)
end)

CreateSideIcon("🔫", function()
    OpenPopup("远程杀戮", function(holder)
        CreateSlider(holder, "发包延迟 (0=极速)", 0, 1, Config.Ranged_Delay, "Ranged_Delay", true)
        CreateSlider(holder, "攻击范围", 100, 5000, Config.Ranged_Range, "Ranged_Range", false)
        CreateToggle(holder, "自动枪锁", "Ranged_Enabled", "🔫")
        CreateToggle(holder, "高度多线程", "Ranged_HyperThread", "🚀")
        CreateToggle(holder, "仅爆头(1.5倍率)", "Ranged_AutoHeadshot", "🧠")
        CreateToggle(holder, "散弹多发模拟", "Ranged_MultiBullet", "💥")
        CreateToggle(holder, "子弹穿墙", "Ranged_WallBang", "🧱")
        CreateToggle(holder, "瞄准 NPC", "Ranged_TargetNPC", "👾")
        CreateToggle(holder, "自动爆胎模式", "Ranged_AutoPopTires", "🛞")
        CreateToggle(holder, "激光无后座/无散射", "Ranged_NoRecoil", "🎯")
        CreateToggle(holder, "好友检测", "Ranged_CheckFriends", "🤝")
        CreateToggle(holder, "可见性检测", "Ranged_CheckVisibility", "👁️")
        local function GetTeams() local t = {} for _, team in ipairs(game:GetService("Teams"):GetTeams()) do table.insert(t, team) end return t end
        CreateMultiSelectList(holder, "队伍选择检测", GetTeams, "Ranged_AllowedTeams", function(sel) end)
    end)
end)

CreateSideIcon("👁️", function()
    OpenPopup("实用工具", function(holder)
        CreateToggle(holder, "玩家透视", "ESP_Enabled", "👻")
        CreateToggle(holder, "秒互动(防按住)", "InstantInteract_Enabled", "⚡")
        CreateToggle(holder, "工具无限耐久", "Tool_InfiniteDurability", "♾️")
        CreateToggle(holder, "全图超距互动", "GlobalInteract_Enabled", "🌐")
        CreateToggle(holder, "持续清理视觉效果", "CleanLightingEffects_Enabled", "✨")
    end)
end)

CreateSideIcon("🛡️", function()
    OpenPopup("防御系统", function(holder)
        CreateToggle(holder, "反死亡视觉", "NoKilledVisual_Enabled", "💀")
        CreateToggle(holder, "反强制Ragdoll", "AntiRagdoll_Enabled", "🤸")
        CreateToggle(holder, "快速起身", "FastGetUp_Enabled", "⬆️")
        CreateToggle(holder, "反强制弹出", "AntiEject_Enabled", "🚗")
        CreateToggle(holder, "反强制隐藏", "AntiCharHidden_Enabled", "👁️")
        CreateToggle(holder, "反强制转向", "AntiForceRotation_Enabled", "🔄")
        CreateToggle(holder, "面向锁定目标", "FaceLockedTarget_Enabled", "🎯")
    end)
end)

CreateSideIcon("⚙️", function()
    OpenPopup("设置", function(holder)
        CreateToggle(holder, "测试开关", "TestMode", "🧪")
    end)
end)

-- ==========================================
-- [核心视觉清理系统 - 深度扫描版]
-- ==========================================
function ClearLockVisuals(lockName)
    local mode = lockName == "KillSystem_MeleeLock" and "Melee" or "Ranged"
    local registry = State.VisualRegistry[mode]

    for char, hl in pairs(registry) do
        if hl then pcall(function() hl:Destroy() end) end
    end
    State.VisualRegistry[mode] = {}

    local function deepClean(parent)
        if not parent then return end
        for _, obj in ipairs(parent:GetDescendants()) do
            if obj:IsA("Highlight") and obj.Name == lockName then
                obj:Destroy()
            end
        end
    end
    pcall(deepClean, workspace)
    pcall(deepClean, Players)
end

local function SyncLockVisuals(activeChars, mode, lockName, color)
    -- 安全状态锁1：如果对应功能已被关闭，强行中断
    if not Config[mode .. "_Enabled"] then return end

    local registry = State.VisualRegistry[mode]
    local activeMap = {}

    for _, char in ipairs(activeChars) do
        if char and char.Parent then
            activeMap[char] = true
            if not registry[char] then
                -- 安全状态锁2：防止多线程并发在关闭瞬间强行创建
                if not Config[mode .. "_Enabled"] then return end
                local newHl = Instance.new("Highlight")
                newHl.Name = lockName
                newHl.FillColor = color
                newHl.OutlineColor = Color3.fromRGB(255, 255, 255)
                newHl.FillTransparency = 0.5
                newHl.Parent = char
                registry[char] = newHl
            end
        end
    end

    for char, hl in pairs(registry) do
        if not activeMap[char] or not char.Parent or not hl.Parent then
            if hl and hl.Parent then hl:Destroy() end
            registry[char] = nil
        end
    end
end

-- ==========================================
-- [核心公共逻辑：NPC与轮胎缓存扫描]
-- ==========================================
local npcCache = {}
local lastNpcScanTime = 0
local tireCache = {}
local lastTireScanTime = 0

local function UpdateNPCCache()
    if tick() - lastNpcScanTime < 0.5 then return end
    lastNpcScanTime = tick()
    table.clear(npcCache)
    for _, desc in ipairs(workspace:GetDescendants()) do
        if desc:IsA("Model") and not Players:GetPlayerFromCharacter(desc) then
            local hum = desc:FindFirstChildOfClass("Humanoid")
            local root = desc:FindFirstChild("HumanoidRootPart")
            if hum and root then
                table.insert(npcCache, {Char = desc, Humanoid = hum, Root = root})
            end
        end
    end
end

local function UpdateTireCache()
    if tick() - lastTireScanTime < 1 then return end
    lastTireScanTime = tick()
    table.clear(tireCache)
    local vehicles = workspace:FindFirstChild("Gameplay") and workspace.Gameplay:FindFirstChild("Vehicles")
    if vehicles then
        for _, car in ipairs(vehicles:GetChildren()) do
            for _, desc in ipairs(car:GetDescendants()) do
                if desc.Name == "WheelCollision" and not desc:GetAttribute("DontPuncture") then
                    table.insert(tireCache, desc)
                end
            end
        end
    end
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
    local targetNPC = Config[mode .. "_TargetNPC"]

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            if #allowedTeams > 0 and (not player.Team or not table.find(allowedTeams, player.Team.Name)) then continue end
            if checkFriends and LocalPlayer:IsFriendsWith(player.UserId) then continue end

            local targetChar = player.Character
            if targetChar and targetChar:FindFirstChild("HumanoidRootPart") and targetChar:FindFirstChild("Humanoid") and targetChar.Humanoid.Health > 0 then
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
                        table.insert(validTargets, {Player = player, Dist = dist, Char = targetChar, Root = targetRoot, IsNPC = false})
                    end
                end
            end
        end
    end

    if targetNPC then
        UpdateNPCCache()
        for _, npcData in ipairs(npcCache) do
            if npcData.Char ~= localChar and npcData.Humanoid.Health > 0 then
                local dist = (npcData.Root.Position - localRoot.Position).Magnitude
                if dist <= range then
                    local isVisible = true
                    if checkVis then
                        local params = RaycastParams.new()
                        params.FilterDescendantsInstances = {localChar}
                        params.FilterType = Enum.RaycastFilterType.Exclude
                        local hit = workspace:Raycast(localRoot.Position, (npcData.Root.Position - localRoot.Position), params)
                        if hit and not hit.Instance:IsDescendantOf(npcData.Char) then isVisible = false end
                    end
                    if isVisible then
                        table.insert(validTargets, {Player = {Name = npcData.Char.Name, UserId = 0}, Dist = dist, Char = npcData.Char, Root = npcData.Root, IsNPC = true})
                    end
                end
            end
        end
    end

    table.sort(validTargets, function(a, b) return a.Dist < b.Dist end)
    return validTargets
end

local function GetValidTires(rangeVal)
    local localChar = LocalPlayer.Character
    if not localChar or not localChar:FindFirstChild("HumanoidRootPart") then return {} end
    local localRoot = localChar.HumanoidRootPart
    local range = rangeVal
    local validTires = {}

    UpdateTireCache()
    for _, tire in ipairs(tireCache) do
        if tire.Parent and tire:GetAttribute("Durability") ~= 0 then
            local dist = (tire.Position - localRoot.Position).Magnitude
            if dist <= range then
                table.insert(validTires, {Tire = tire, Dist = dist, Pos = tire.Position})
            end
        end
    end
    table.sort(validTires, function(a, b) return a.Dist < b.Dist end)
    return validTires
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
    for _, t in ipairs(State.MeleeThreads) do pcall(task.cancel, t) end
    State.MeleeThreads = {}

    local threadCount = Config.Melee_HyperThread and 3 or 1

    for i = 1, threadCount do
        local t = task.spawn(function()
            while Config.Melee_Enabled do
                task.wait(Config.Melee_Delay > 0 and Config.Melee_Delay or 0.016)

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
                local activeChars = {}

                if #targets > 0 and localChar and localChar:FindFirstChild("HumanoidRootPart") then
                    local localRoot = localChar.HumanoidRootPart
                    local localPos = localRoot.Position

                    for _, targetData in ipairs(targets) do
                        local targetChar = targetData.Char
                        table.insert(activeChars, targetChar)

                        task.spawn(function()
                            local bodyPartsArr = Config.Melee_MultiHit and GetBodyPartsArray(targetChar) or {{ [1] = "HumanoidRootPart", [2] = 1 }}
                            local targetPos = targetData.Root.Position
                            local args = {
                                [1] = "damage",
                                [2] = {
                                    ["bodyParts"] = bodyPartsArr,
                                    ["shotCode"] = { [1] = targetPos, [2] = (localPos - targetPos).Unit },
                                    ["target"] = targetData.Player,
                                    ["pos"] = localPos
                                }
                            }
                            pcall(function() Remote:FireServer(unpack(args)) end)
                        end)
                    end
                end

                if Config.Melee_AutoPopTires then
                    local tires = GetValidTires(Config.Melee_Range)
                    for _, tireData in ipairs(tires) do
                        task.spawn(function()
                            if not localChar or not localChar:FindFirstChild("HumanoidRootPart") then return end
                            local localPos = localChar.HumanoidRootPart.Position
                            local shotCode = { localPos, (tireData.Pos - localPos).Unit }
                            pcall(function()
                                Remote:FireServer("damage", { shotCode = shotCode, pos = tireData.Pos, targetTire = tireData.Tire })
                            end)
                        end)
                    end
                end

                if i == 1 then
                    SyncLockVisuals(activeChars, "Melee", "KillSystem_MeleeLock", Color3.fromRGB(255, 0, 0))
                end
            end
        end)
        table.insert(State.MeleeThreads, t)
    end
end

-- ==========================================
-- [远程战斗逻辑]
-- ==========================================
local function GetEquippedWeaponName()
    local char = LocalPlayer.Character
    if not char then return "Unarmed" end
    for _, item in ipairs(char:GetChildren()) do if item:IsA("Tool") then return item.Name end end
    for _, item in ipairs(char:GetChildren()) do if item:IsA("Model") and item:FindFirstChild("Handle") then return item.Name end end
    return "Unarmed"
end

local function GetBarrelPos(char)
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Tool") then local barrel = item:FindFirstChild("Barrel") or item:FindFirstChild("Handle") if barrel then return barrel.Position end end
    end
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Model") and item:FindFirstChild("Handle") then local barrel = item:FindFirstChild("Barrel") or item:FindFirstChild("Handle") if barrel then return barrel.Position end end
    end
    return char.HumanoidRootPart.Position
end

function StartRangedLoop()
    for _, t in ipairs(State.RangedThreads) do pcall(task.cancel, t) end
    State.RangedThreads = {}

    local threadCount = Config.Ranged_HyperThread and 3 or 1

    for i = 1, threadCount do
        local t = task.spawn(function()
            while Config.Ranged_Enabled do
                task.wait(Config.Ranged_Delay > 0 and Config.Ranged_Delay or 0.016)

                local Remote = FetchRemote()
                if not Remote then task.wait(1) continue end

                local targets = GetValidTargets("Ranged")
                local localChar = LocalPlayer.Character
                local activeChars = {}

                if Config.Ranged_AutoPopTires then
                    local tires = GetValidTires(Config.Ranged_Range)
                    for _, tireData in ipairs(tires) do
                        task.spawn(function()
                            if not localChar or not localChar:FindFirstChild("HumanoidRootPart") then return end
                            local barrelPos = GetBarrelPos(localChar)
                            local shotCode = { barrelPos, (tireData.Pos - barrelPos).Unit }
                            pcall(function()
                                Remote:FireServer("damage", { shotCode = shotCode, pos = tireData.Pos, targetTire = tireData.Tire })
                            end)
                        end)
                    end
                end

                if #targets > 0 and localChar and localChar:FindFirstChild("HumanoidRootPart") then
                    for _, targetData in ipairs(targets) do
                        local targetChar = targetData.Char
                        table.insert(activeChars, targetChar)

                        task.spawn(function()
                            local hitPartName = Config.Ranged_AutoHeadshot and "Head" or "HumanoidRootPart"
                            local hitPart = targetChar:FindFirstChild(hitPartName) or targetChar:FindFirstChild("HumanoidRootPart")
                            if not hitPart then return end

                            local hitPos = hitPart.Position
                            local barrelPos = GetBarrelPos(localChar)
                            local shotCode = { barrelPos, (hitPos - barrelPos).Unit }
                            local weaponName = GetEquippedWeaponName()

                            for i = 1, (Config.Ranged_MultiBullet and 3 or 1) do
                                pcall(function() Remote:FireServer("bullet", { weaponName = weaponName, posDestroyX = hitPos.X + (i * 0.5), pos = hitPos }) end)
                            end

                            local damageArgs = {
                                [1] = "damage",
                                [2] = { bodyParts = { [1] = { [1] = hitPartName, [2] = 1 } }, shotCode = shotCode, target = targetData.Player, pos = hitPos }
                            }
                            if Config.Ranged_AutoHeadshot then damageArgs[2].damageFactor = 1.5 end
                            pcall(function() Remote:FireServer(unpack(damageArgs)) end)
                        end)
                    end
                end

                if i == 1 then
                    SyncLockVisuals(activeChars, "Ranged", "KillSystem_RangedLock", Color3.fromRGB(0, 0, 255))
                end
            end
        end)
        table.insert(State.RangedThreads, t)
    end
end

-- ==========================================
-- [ESP与实用工具逻辑 - 兼容workspace.Characters]
-- ==========================================
function ClearESP()
    for char, obj in pairs(State.ESPObjects) do
        if obj.Highlight then obj.Highlight:Destroy() end
        if obj.Billboard then obj.Billboard:Destroy() end
    end
    State.ESPObjects = {}
end

local function UpdateESP()
    if not Config.ESP_Enabled then return end

    local drawnChars = {}
    local localChar = LocalPlayer.Character

    local function ApplyESP(char, name, teamColor)
        if char == localChar then return end
        if not char or not char.Parent then return end

        local root = char:FindFirstChild("HumanoidRootPart")
        local hum = char:FindFirstChildOfClass("Humanoid")
        if not root or not hum or hum.Health <= 0 then return end

        drawnChars[char] = true
        local obj = State.ESPObjects[char]

        local needRebuild = false
        if not obj then
            needRebuild = true
        else
            if not obj.Highlight or not obj.Highlight.Parent or obj.Highlight.Parent ~= char then needRebuild = true end
            if not obj.Billboard or not obj.Billboard.Parent or obj.Billboard.Parent ~= root then needRebuild = true end
        end

        if needRebuild then
            if obj then
                if obj.Highlight then pcall(function() obj.Highlight:Destroy() end) end
                if obj.Billboard then pcall(function() obj.Billboard:Destroy() end) end
            end
            obj = {}
            obj.Highlight = Instance.new("Highlight")
            obj.Highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
            obj.Highlight.FillTransparency = 0.7
            obj.Highlight.Parent = char

            obj.Billboard = Instance.new("BillboardGui")
            obj.Billboard.Size = UDim2.new(0, 200, 0, 30)
            obj.Billboard.StudsOffset = Vector3.new(0, 3, 0)
            obj.Billboard.AlwaysOnTop = true
            obj.Billboard.Parent = root

            local lbl = Instance.new("TextLabel", obj.Billboard)
            lbl.Size = UDim2.new(1, 0, 1, 0)
            lbl.BackgroundTransparency = 1
            lbl.TextStrokeTransparency = 0
            lbl.Font = Enum.Font.GothamBold
            lbl.TextSize = 14
            obj.Label = lbl

            State.ESPObjects[char] = obj
        end

        obj.Highlight.FillColor = teamColor or Color3.fromRGB(255, 255, 255)

        local isMeleeLocked = State.VisualRegistry.Melee[char] ~= nil
        local isRangedLocked = State.VisualRegistry.Ranged[char] ~= nil

        local lockText, textColor = "", teamColor or Color3.fromRGB(255, 255, 255)
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
        obj.Label.Text = string.format("%s [%d/%d]%s", name, math.floor(hum.Health), hum.MaxHealth, lockText)
    end

    -- 1. 扫描 Players
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local char = player.Character
            local tColor = player.Team and player.Team.TeamColor.Color or Color3.fromRGB(255, 255, 255)
            if char then ApplyESP(char, player.Name, tColor) end
        end
    end

    -- 2. 扫描 workspace.Characters (该游戏特有机制)
    local wsChars = workspace:FindFirstChild("Characters")
    if wsChars then
        for _, char in ipairs(wsChars:GetChildren()) do
            if char:IsA("Model") and char ~= localChar then
                local player = Players:FindFirstChild(char.Name)
                local tColor = player and player.Team and player.Team.TeamColor.Color or Color3.fromRGB(200, 200, 200)
                ApplyESP(char, char.Name, tColor)
            end
        end
    end

    -- 3. 清理不再需要绘制的 ESP
    for char, obj in pairs(State.ESPObjects) do
        if not drawnChars[char] or not char.Parent then
            if obj.Highlight then obj.Highlight:Destroy() end
            if obj.Billboard then obj.Billboard:Destroy() end
            State.ESPObjects[char] = nil
        end
    end
end

RunService.RenderStepped:Connect(UpdateESP)

-- 互动系统（已移除自动拾取，仅保留秒互动与全图互动）
local function ProcessPrompt(prompt)
    if not prompt:IsA("ProximityPrompt") then return end

    if not prompt:GetAttribute("KS_OrigMaxDist") then
        prompt:SetAttribute("KS_OrigMaxDist", prompt.MaxActivationDistance)
    end
    if not prompt:GetAttribute("KS_OrigHoldDur") then
        prompt:SetAttribute("KS_OrigHoldDur", prompt.HoldDuration)
    end

    if Config.GlobalInteract_Enabled then
        prompt.MaxActivationDistance = 9999
    else
        prompt.MaxActivationDistance = prompt:GetAttribute("KS_OrigMaxDist")
    end

    if Config.InstantInteract_Enabled then
        prompt.HoldDuration = 0
    else
        prompt.HoldDuration = prompt:GetAttribute("KS_OrigHoldDur")
    end
end

local function ScanAndProcessPrompts()
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("ProximityPrompt") then
            ProcessPrompt(obj)
        end
    end
end

workspace.DescendantAdded:Connect(function(d)
    if d:IsA("ProximityPrompt") then
        ProcessPrompt(d)
    end
end)

task.spawn(function()
    while true do
        if Config.InstantInteract_Enabled or Config.GlobalInteract_Enabled then
            pcall(ScanAndProcessPrompts)
            task.wait(1)
        else
            task.wait(2)
        end
    end
end)

-- ==========================================
-- [防御与生存系统 - 基于反编译事件协议]
-- 通过Hook RemoteEvent.OnClientEvent 监听服务器推送的特定事件
-- 并在事件触发后执行防御性反制操作
-- ==========================================

-- 远程事件监听Hook：拦截服务器推送的特定事件并执行防御逻辑
task.spawn(function()
    local remote = FetchRemote()
    if not remote then
        task.wait(3)
        remote = FetchRemote()
    end
    if not remote then
        warn("[KillSystem] 防御系统：未找到RemoteEvent，事件监听未启动")
        return
    end

    remote.OnClientEvent:Connect(function(eventName, ...)
        -- 反死亡视觉：拦截killedVisual事件，禁用KilledColorCorrection
        -- 游戏原始处理：启用KilledColorCorrection并Tween亮度/对比度/饱和度
        -- 我们的对策：延迟一帧后强制禁用并归零所有参数
        if Config.NoKilledVisual_Enabled and eventName == "killedVisual" then
            task.spawn(function()
                task.wait(0.05)
                local cc = game.Lighting:FindFirstChild("KilledColorCorrection")
                if cc then
                    cc.Enabled = false
                    cc.Brightness = 0
                    cc.Contrast = 0
                    cc.Saturation = 0
                end
            end)
        end

        -- 反强制Ragdoll：拦截ragdoll事件，自动调用GettingUp恢复
        -- 游戏原始处理：调用v_u_9.activate(char, p194, p195, true) 激活Ragdoll
        -- 我们的对策：延迟0.1秒后强制切换到GettingUp状态起身
        if Config.AntiRagdoll_Enabled and eventName == "ragdoll" then
            task.spawn(function()
                task.wait(0.1)
                local char = LocalPlayer.Character
                if char and char:FindFirstChild("Humanoid") then
                    char.Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
                end
            end)
        end

        -- 反强制弹出：拦截eject事件，等待禁用期后重新进入最近车辆
        -- 游戏原始处理：v_u_8.disabled(true, "eject") 禁用互动 Handcuffs.HoldDuration*2 秒
        -- 我们的对策：等待禁用期结束，寻找30 studs内最近车辆并触发ProximityPrompt
        if Config.AntiEject_Enabled and eventName == "eject" then
            task.spawn(function()
                -- 计算eject禁用时长（Handcuffs.HoldDuration.Value * 2 + 1秒缓冲）
                local waitTime = 5
                pcall(function()
                    local handcuffs = game.ReplicatedStorage:FindFirstChild("Gameplay")
                    if handcuffs then
                        handcuffs = handcuffs:FindFirstChild("Items")
                    end
                    if handcuffs then
                        handcuffs = handcuffs:FindFirstChild("Handcuffs")
                    end
                    if handcuffs then
                        local hd = handcuffs:FindFirstChild("HoldDuration")
                        if hd and (hd:IsA("NumberValue") or hd:IsA("IntValue")) then
                            waitTime = hd.Value * 2 + 1
                        end
                    end
                end)
                task.wait(waitTime)

                -- 寻找最近的车辆
                local char = LocalPlayer.Character
                if not char or not char:FindFirstChild("HumanoidRootPart") then return end
                local localPos = char.HumanoidRootPart.Position
                local nearestVehicle = nil
                local nearestDist = math.huge
                local vehicles = workspace:FindFirstChild("Gameplay") and workspace.Gameplay:FindFirstChild("Vehicles")
                if vehicles then
                    for _, car in ipairs(vehicles:GetChildren()) do
                        if car:IsA("Model") then
                            local primaryPart = car.PrimaryPart or car:FindFirstChild("HumanoidRootPart") or car:FindFirstChildWhichIsA("BasePart")
                            if primaryPart then
                                local dist = (primaryPart.Position - localPos).Magnitude
                                if dist < nearestDist and dist < 30 then
                                    nearestDist = dist
                                    nearestVehicle = car
                                end
                            end
                        end
                    end
                end

                -- 尝试通过ProximityPrompt进入车辆
                if nearestVehicle then
                    local promptFound = false
                    for _, desc in ipairs(nearestVehicle:GetDescendants()) do
                        if desc:IsA("ProximityPrompt") then
                            local txt = string.lower(desc.ActionText .. " " .. desc.ObjectText)
                            if string.find(txt, "enter") or string.find(txt, "sit") or string.find(txt, "drive") or string.find(txt, "seat") then
                                pcall(function() desc:InputHoldBegin() end)
                                task.wait(0.15)
                                pcall(function() desc:InputHoldEnd() end)
                                promptFound = true
                                break
                            end
                        end
                    end
                    -- 如果没找到进入Prompt，尝试走向车辆
                    if not promptFound and char:FindFirstChild("Humanoid") then
                        char.Humanoid:MoveTo(nearestVehicle.PrimaryPart.Position)
                    end
                end
            end)
        end

        -- 反强制隐藏：拦截characterHidden事件，恢复触控与装备权限
        -- 游戏原始处理：禁用TouchControls、禁用EquipSlot、停用Ragdoll
        -- 我们的对策：恢复TouchControlsEnabled，标记装备槽为可用
        if Config.AntiCharHidden_Enabled and eventName == "characterHidden" then
            local hidden = ...
            if hidden then
                -- 恢复触控
                pcall(function()
                    game:GetService("GuiService").TouchControlsEnabled = true
                end)
                -- 尝试通过Remote恢复装备权限
                local r = FetchRemote()
                if r then
                    pcall(function() r:FireServer("characterIsPhysicallyOccupied", false) end)
                end
            end
        end
    end)
end)

-- 快速起身循环：持续监控Humanoid状态，物理Ragdoll时立即起身
-- 与AntiRagdoll互补：AntiRagdoll只拦截服务器ragdoll事件，
-- FastGetUp能捕获所有进入Physics状态的Ragdoll（包括物理碰撞导致）
task.spawn(function()
    while true do
        if Config.FastGetUp_Enabled then
            local char = LocalPlayer.Character
            if char and char:FindFirstChild("Humanoid") then
                local hum = char.Humanoid
                local state = hum:GetState()
                -- Physics状态通常表示Ragdoll（包括被车撞、爆炸等物理触发）
                if state == Enum.HumanoidStateType.Physics then
                    hum:ChangeState(Enum.HumanoidStateType.GettingUp)
                end
            end
            task.wait(0.1)
        else
            task.wait(1)
        end
    end
end)

-- 持续清理视觉效果：移除游戏添加的非系统Lighting效果
-- 保留我们自己的BlurEffect（名为KillSystem_Blur）
-- 如果NoKilledVisual开启，则KilledColorCorrection由其管理
local CleanEffectsLastCheck = 0
task.spawn(function()
    while true do
        if Config.CleanLightingEffects_Enabled then
            -- 限频检查，避免每帧遍历
            if tick() - CleanEffectsLastCheck >= 1 then
                CleanEffectsLastCheck = tick()
                for _, child in ipairs(game.Lighting:GetChildren()) do
                    -- 跳过我们自己的BlurEffect
                    if child.Name == "KillSystem_Blur" then continue end
                    -- 如果NoKilledVisual开启，跳过KilledColorCorrection（由其管理）
                    if child.Name == "KilledColorCorrection" and Config.NoKilledVisual_Enabled then continue end
                    -- 禁用各种视觉效果
                    if child:IsA("ColorCorrectionEffect") or child:IsA("BloomEffect") or
                       child:IsA("DepthOfFieldEffect") or child:IsA("SunRaysEffect") or
                       child:IsA("BlurEffect") or child:IsA("Atmosphere") then
                        pcall(function() child.Enabled = false end)
                    end
                end
            end
            task.wait(0.5)
        else
            task.wait(2)
        end
    end
end)

print("[KillSystem v10.18] 防御系统扩展版已加载。")

-- ==========================================
-- [防御系统 v2 - 状态轮询双重保障]
-- 问题：v1基于OnClientEvent事件监听，但可能因为以下原因失效：
--   1. 游戏的Ragdoll模块（v_u_9）可能使用自定义机制，不依赖Humanoid状态
--   2. PlatformStand为true时ChangeState(GettingUp)无效
--   3. Motor6D被禁用后需要手动重新启用
--   4. 事件监听器可能被游戏的包装机制过滤
-- 解决：使用RunService.Heartbeat持续强制状态，不依赖事件
-- ==========================================

local Heartbeat = RunService.Heartbeat
local GuiService = game:GetService("GuiService")

-- 调试计数器（控制台输出频率限制）
local DefDebugCounter = {
    AntiRagdoll = 0,
    FastGetUp = 0,
    NoKilledVisual = 0,
    AntiCharHidden = 0,
    AntiEject = 0
}

-- 持续状态强制循环：每帧检查并强制防御状态
Heartbeat:Connect(function()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChild("Humanoid")

    -- 反强制Ragdoll：持续强制PlatformStand=false、重新启用Motor6D
    if Config.AntiRagdoll_Enabled and hum then
        if hum.PlatformStand then
            hum.PlatformStand = false
            DefDebugCounter.AntiRagdoll = DefDebugCounter.AntiRagdoll + 1
            if DefDebugCounter.AntiRagdoll % 30 == 1 then
                print("[防御] AntiRagdoll: 强制PlatformStand=false")
            end
        end
        -- 重新启用所有Motor6D（Ragdoll模块会禁用它们）
        if char then
            for _, motor in ipairs(char:GetDescendants()) do
                if motor:IsA("Motor6D") and not motor.Enabled then
                    motor.Enabled = true
                end
            end
        end
        -- 调用GettingUp状态（每60帧调一次，避免过度调用）
        if DefDebugCounter.AntiRagdoll % 60 == 0 then
            local state = hum:GetState()
            if state == Enum.HumanoidStateType.Physics or state == Enum.HumanoidStateType.FallingDown then
                hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            end
        end
        DefDebugCounter.AntiRagdoll = DefDebugCounter.AntiRagdoll + 1
    end

    -- 快速起身：检测多种Ragdoll状态，立即起身
    if Config.FastGetUp_Enabled and hum then
        local state = hum:GetState()
        local needGetUp = false
        if state == Enum.HumanoidStateType.Physics then
            needGetUp = true
        elseif state == Enum.HumanoidStateType.FallingDown then
            needGetUp = true
        elseif hum.PlatformStand then
            needGetUp = true
        end
        if needGetUp then
            hum.PlatformStand = false
            hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            DefDebugCounter.FastGetUp = DefDebugCounter.FastGetUp + 1
            if DefDebugCounter.FastGetUp % 30 == 1 then
                print("[防御] FastGetUp: 检测到Ragdoll状态，强制起身")
            end
        end
    end

    -- 反死亡视觉：持续监控KilledColorCorrection.Enabled
    if Config.NoKilledVisual_Enabled then
        local cc = game.Lighting:FindFirstChild("KilledColorCorrection")
        if cc and cc.Enabled then
            cc.Enabled = false
            cc.Brightness = 0
            cc.Contrast = 0
            cc.Saturation = 0
            DefDebugCounter.NoKilledVisual = DefDebugCounter.NoKilledVisual + 1
            if DefDebugCounter.NoKilledVisual % 10 == 1 then
                print("[防御] NoKilledVisual: 检测到死亡视觉启用，已强制禁用")
            end
        end
    end

    -- 反强制隐藏：持续监控TouchControlsEnabled
    if Config.AntiCharHidden_Enabled then
        if not GuiService.TouchControlsEnabled then
            GuiService.TouchControlsEnabled = true
            DefDebugCounter.AntiCharHidden = DefDebugCounter.AntiCharHidden + 1
            if DefDebugCounter.AntiCharHidden % 30 == 1 then
                print("[防御] AntiCharHidden: 检测到触控被禁用，已恢复")
            end
        end
        -- 尝试通过Remote恢复装备权限（限频，避免高频发包）
        if DefDebugCounter.AntiCharHidden % 60 == 0 then
            local r = FetchRemote()
            if r then
                pcall(function() r:FireServer("characterIsPhysicallyOccupied", false) end)
            end
        end
    end
end)

-- 反强制弹出增强版：事件驱动 + 重试机制 + 直接FireServer
-- v1问题：依赖ProximityPrompt可能找不到或触发失败
-- v2改进：1.增加直接FireServer('enterVehicle')备用方案 2.多次重试 3.增加等待时间
local EjectRetryThread = nil
task.spawn(function()
    local remote = FetchRemote()
    if not remote then
        task.wait(3)
        remote = FetchRemote()
    end
    if not remote then return end

    remote.OnClientEvent:Connect(function(eventName, ...)
        if Config.AntiEject_Enabled and eventName == "eject" then
            print("[防御] AntiEject: 检测到eject事件，启动反弹出序列")
            -- 取消之前的重试线程
            if EjectRetryThread then pcall(task.cancel, EjectRetryThread) end
            EjectRetryThread = task.spawn(function()
                -- 等待eject禁用期（默认Handcuffs.HoldDuration*2，备选5秒）
                local waitTime = 5
                pcall(function()
                    local handcuffs = game.ReplicatedStorage:FindFirstChild("Gameplay")
                    if handcuffs then handcuffs = handcuffs:FindFirstChild("Items") end
                    if handcuffs then handcuffs = handcuffs:FindFirstChild("Handcuffs") end
                    if handcuffs then
                        local hd = handcuffs:FindFirstChild("HoldDuration")
                        if hd and (hd:IsA("NumberValue") or hd:IsA("IntValue")) then
                            waitTime = hd.Value * 2 + 1
                        end
                    end
                end)
                task.wait(waitTime)

                -- 重试进入车辆（最多3次）
                for attempt = 1, 3 do
                    local char = LocalPlayer.Character
                    if not char or not char:FindFirstChild("HumanoidRootPart") then break end
                    local localPos = char.HumanoidRootPart.Position
                    local nearestVehicle = nil
                    local nearestDist = math.huge
                    local vehicles = workspace:FindFirstChild("Gameplay") and workspace.Gameplay:FindFirstChild("Vehicles")
                    if vehicles then
                        for _, car in ipairs(vehicles:GetChildren()) do
                            if car:IsA("Model") then
                                local primaryPart = car.PrimaryPart or car:FindFirstChildWhichIsA("BasePart")
                                if primaryPart then
                                    local dist = (primaryPart.Position - localPos).Magnitude
                                    if dist < nearestDist and dist < 50 then
                                        nearestDist = dist
                                        nearestVehicle = car
                                    end
                                end
                            end
                        end
                    end

                    if nearestVehicle then
                        print(string.format("[防御] AntiEject: 尝试 #%d 进入车辆 %s (距离%.1f studs)",
                            attempt, nearestVehicle.Name, nearestDist))

                        -- 方法1：直接通过RemoteEvent请求进入车辆
                        local r = FetchRemote()
                        if r then
                            pcall(function() r:FireServer("enterVehicle", nearestVehicle) end)
                        end

                        -- 方法2：触发ProximityPrompt
                        for _, desc in ipairs(nearestVehicle:GetDescendants()) do
                            if desc:IsA("ProximityPrompt") and desc.Enabled then
                                pcall(function() desc:InputHoldBegin() end)
                                task.wait(0.2)
                                pcall(function() desc:InputHoldEnd() end)
                                break
                            end
                        end

                        -- 方法3：走向车辆（如果还没进入）
                        task.wait(1)
                        local seat = char:FindFirstChild("Seat")
                        local isInVehicle = false
                        if seat and seat:IsA("Weld") and seat.Part1 then
                            isInVehicle = true
                        end
                        -- 检查是否还在车里（通过RootPart的Velocity或Seat属性）
                        if char:FindFirstChild("Humanoid") and char.Humanoid.Sit then
                            isInVehicle = true
                        end
                        if not isInVehicle and char:FindFirstChild("HumanoidRootPart") then
                            local vehiclePos = nearestVehicle.PrimaryPart and nearestVehicle.PrimaryPart.Position or nearestVehicle:GetPivot().Position
                            char.Humanoid:MoveTo(vehiclePos)
                        end
                        if isInVehicle then
                            print("[防御] AntiEject: 成功重新进入车辆")
                            return
                        end
                    else
                        print(string.format("[防御] AntiEject: 尝试 #%d 未找到附近车辆", attempt))
                    end
                    task.wait(1.5)
                end
                print("[防御] AntiEject: 反弹出序列结束")
            end)
        end
    end)
end)

print("[KillSystem v10.20] charRot协议防御版已加载。")
e.new("UICorner", switch).CornerRadius = UDim.new(1, 0)

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
                  --[[
    杀戮系统 v10.20 [charRot协议防御版]
    更新：
    1. 继承 v10.19 所有防御与UI修复
    2. 新增Hook UnreliableEvent.FireServer，拦截charRot事件
    3. 新增"反强制转向"：用摄像机朝向覆盖charRot，防止被逮捕/手铐/物理占据时强制转向
    4. 新增"面向锁定目标"：当近战/远程锁定激活时，强制角色面向锁定目标
    5. FaceLockedTarget优先级高于AntiForceRotation（锁定时面向目标，未锁定时用摄像机朝向）
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

-- 前置声明核心函数
local StartMeleeLoop, StartRangedLoop, ClearLockVisuals, ClearESP, HookWeaponConfig
local ClosePopup  -- 前置声明，供侧栏触发按钮回调使用

-- 启动时强制清理可能残留的旧高亮实例
local function CleanupOrphanVisuals()
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Highlight") and (obj.Name == "KillSystem_MeleeLock" or obj.Name == "KillSystem_RangedLock") then
            obj:Destroy()
        end
    end
end
CleanupOrphanVisuals()

-- [全局统一配置]
local Config = {
    -- 近战
    Melee_Enabled = false,
    Melee_Range = 30,
    Melee_Delay = 0.03,
    Melee_HyperThread = false,
    Melee_MultiHit = true,
    Melee_ForceCombatMode = true,
    Melee_SelfAntiCombatMode = false,
    Melee_CheckFriends = false,
    Melee_CheckVisibility = false,
    Melee_TargetNPC = false,
    Melee_AutoPopTires = false,
    Melee_AllowedTeams = {},

    -- 远程
    Ranged_Enabled = false,
    Ranged_Range = 1000,
    Ranged_Delay = 0.05,
    Ranged_HyperThread = true,
    Ranged_AutoHeadshot = true,
    Ranged_MultiBullet = true,
    Ranged_WallBang = false,
    Ranged_CheckFriends = false,
    Ranged_CheckVisibility = false,
    Ranged_TargetNPC = false,
    Ranged_AutoPopTires = false,
    Ranged_NoRecoil = true,
    Ranged_AllowedTeams = {},

    -- 实用工具
    ESP_Enabled = false,
    InstantInteract_Enabled = false,
    Tool_InfiniteDurability = false,
    TestMode = false,

    -- 全图互动
    GlobalInteract_Enabled = false,

    -- 防御系统（基于反编译事件协议）
    NoKilledVisual_Enabled = false,      -- 反死亡视觉：禁用KilledColorCorrection
    AntiRagdoll_Enabled = false,         -- 反强制Ragdoll：拦截ragdoll事件
    FastGetUp_Enabled = false,           -- 快速起身：监控物理Ragdoll状态
    AntiEject_Enabled = false,           -- 反强制弹出：拦截eject事件后重新上车
    AntiCharHidden_Enabled = false,      -- 反强制隐藏：拦截characterHidden事件
    CleanLightingEffects_Enabled = false, -- 持续清理视觉效果

    -- 转向控制（基于charRot协议）
    AntiForceRotation_Enabled = false,   -- 反强制转向：用摄像机朝向覆盖charRot
    FaceLockedTarget_Enabled = false     -- 面向锁定目标：锁定时强制面向目标
}

-- [全局状态与回调中心]
local State = {
    RemoteEvent = nil,
    IsRemoteHooked = false,
    MeleeThreads = {},
    RangedThreads = {},
    AutoHideThread = nil,
    Shortcuts = {},
    ShortcutsByConfigKey = {},  -- 新增：按configKey索引快捷键，用于状态同步
    SideIcons = {},              -- 新增：侧栏图标引用，用于主题切换时同步颜色
    IsPlacingShortcut = false,
    CurrentActionToBind = nil,
    PlacementCapture = nil,     -- 新增：全屏捕获按钮引用
    CombatModeTick = 0,
    ESPObjects = {},
    VisualRegistry = { Melee = {}, Ranged = {} },
    Connections = {},

    GlobalCallbacks = {
        Melee_Enabled = function(val)
            if val then StartMeleeLoop() else
                for _, t in ipairs(State.MeleeThreads) do pcall(task.cancel, t) end
                State.MeleeThreads = {}
                ClearLockVisuals("KillSystem_MeleeLock")
            end
        end,
        Ranged_Enabled = function(val)
            if val then StartRangedLoop() else
                for _, t in ipairs(State.RangedThreads) do pcall(task.cancel, t) end
                State.RangedThreads = {}
                ClearLockVisuals("KillSystem_RangedLock")
            end
        end,
        TestMode = function(val) print("[System] 测试开关状态改变 ->", val) end,
        ESP_Enabled = function(val) if not val then ClearESP() end end,
        Ranged_NoRecoil = function(val)
            local char = LocalPlayer.Character
            if char then
                for _, tool in ipairs(char:GetChildren()) do
                    if tool:IsA("Tool") or (tool:IsA("Model") and tool:FindFirstChild("Handle")) then
                        HookWeaponConfig(tool)
                    end
                end
            end
        end
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

-- 修复：复用已存在的UIGradient，避免重复实例累积
local function ApplyGradient(guiObj)
    local grad = guiObj:FindFirstChildOfClass("UIGradient")
    if not grad then
        grad = Instance.new("UIGradient")
        grad.Parent = guiObj
    end
    grad.Color = ColorSequence.new(Theme.C1, Theme.C2)
    grad.Rotation = math.random(0, 360)
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "KillSystemUI_v10"
ScreenGui.ResetOnSpawn = false
ScreenGui.DisplayOrder = 999
pcall(function() ScreenGui.Parent = CoreGui end)
if not ScreenGui.Parent then ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local BlurEffect = Instance.new("BlurEffect")
BlurEffect.Name = "KillSystem_Blur"
BlurEffect.Size = 0
BlurEffect.Parent = Lighting

-- ==========================================
-- [原生协议Hook与武器系统]
-- ==========================================
function HookWeaponConfig(tool)
    if not tool then return end
    local cfgModule = tool:FindFirstChild("Config")
    if not cfgModule then return end

    local success, cfg = pcall(require, cfgModule)
    if success and cfg and cfg.GUN then
        if Config.Ranged_NoRecoil then
            cfg.RECOIL = 0
            cfg.TR_DIFF = 0
            cfg.ACCURACY = 0.001
        end
    end
end

LocalPlayer.CharacterAdded:Connect(function(char)
    char.ChildAdded:Connect(function(child)
        if child:IsA("Tool") or (child:IsA("Model") and child:FindFirstChild("Handle")) then
            task.wait(0.1)
            HookWeaponConfig(child)
        end
    end)
end)

task.spawn(function()
    local char = LocalPlayer.Character
    if char then
        for _, tool in ipairs(char:GetChildren()) do
            if tool:IsA("Tool") or (tool:IsA("Model") and tool:FindFirstChild("Handle")) then
                HookWeaponConfig(tool)
            end
        end
    end
end)

local function FetchRemote()
    if State.RemoteEvent then return State.RemoteEvent end
    local success, result = pcall(function() return ReplicatedStorage:WaitForChild("Remote", 3):WaitForChild("PlayerEvent", 3) end)
    if success and result then
        State.RemoteEvent = result
        return result
    end
    return nil
end

task.spawn(function()
    local remote = FetchRemote()
    if remote and not State.IsRemoteHooked then
        State.IsRemoteHooked = true
        local oldFireServer = remote.FireServer
        remote.FireServer = function(self, cmd, ...)
            if Config.Tool_InfiniteDurability and cmd == "degradeItem" then
                return
            end
            return oldFireServer(self, cmd, ...)
        end
    end
end)

-- Hook UnreliableEvent.FireServer：拦截charRot事件
-- 游戏每0.1秒发送charRot(Vector2)到服务器，用于同步角色朝向
-- 我们拦截后可以：1.用摄像机朝向覆盖（反强制转向）2.面向锁定目标
task.spawn(function()
    local success, unreliableRemote = pcall(function()
        return ReplicatedStorage:WaitForChild("Remote", 3):WaitForChild("UnreliableEvent", 3)
    end)
    if not success or not unreliableRemote then
        warn("[KillSystem] 未找到UnreliableEvent，charRot Hook未启动")
        return
    end

    local oldUnreliableFire = unreliableRemote.FireServer
    unreliableRemote.FireServer = function(self, cmd, ...)
        if cmd == "charRot" then
            local char = LocalPlayer.Character
            local camera = workspace.CurrentCamera

            -- 优先级1：面向锁定目标（当近战或远程锁定激活时）
            if Config.FaceLockedTarget_Enabled and char and char:FindFirstChild("HumanoidRootPart") then
                local localRoot = char.HumanoidRootPart
                local targetRoot = nil

                -- 检查近战锁定的目标
                if Config.Melee_Enabled then
                    for targetChar, _ in pairs(State.VisualRegistry.Melee) do
                        if targetChar and targetChar.Parent and targetChar:FindFirstChild("HumanoidRootPart") then
                            targetRoot = targetChar.HumanoidRootPart
                            break
                        end
                    end
                end

                -- 如果近战没锁定，检查远程锁定的目标
                if not targetRoot and Config.Ranged_Enabled then
                    for targetChar, _ in pairs(State.VisualRegistry.Ranged) do
                        if targetChar and targetChar.Parent and targetChar:FindFirstChild("HumanoidRootPart") then
                            targetRoot = targetChar.HumanoidRootPart
                            break
                        end
                    end
                end

                if targetRoot then
                    -- 计算朝向目标的方向向量（XZ平面）
                    local dir = (targetRoot.Position - localRoot.Position)
                    -- charRot是Vector2，根据反编译：SetAttribute("charRot", Vector2.new(X/100, Y/100))
                    -- 原始发送格式：Vector2.new(math.round(attr.X*100), math.round(attr.Y*100))
                    -- 所以服务器接收到的是放大100倍的值，存储时除以100
                    -- 这里我们直接构造方向向量并放大100倍
                    local rotX = math.clamp(dir.X * 100, -9999, 9999)
                    local rotZ = dir.Z * 100
                    -- 使用Vector2.new(X, Z)因为charRot的Y分量对应世界的Z轴（前后）
                    return oldUnreliableFire(self, "charRot", Vector2.new(math.round(rotX), math.round(rotZ)))
                end
            end

            -- 优先级2：反强制转向（用摄像机朝向覆盖）
            if Config.AntiForceRotation_Enabled and camera and char and char:FindFirstChild("HumanoidRootPart") then
                local localRoot = char.HumanoidRootPart
                -- 获取摄像机LookVector在XZ平面的投影
                local lookVec = camera.CFrame.LookVector
                -- 构造方向向量并放大100倍（与游戏原始格式一致）
                local rotX = math.round(lookVec.X * 100)
                local rotZ = math.round(lookVec.Z * 100)
                return oldUnreliableFire(self, "charRot", Vector2.new(rotX, rotZ))
            end
        end
        return oldUnreliableFire(self, cmd, ...)
    end
    print("[KillSystem] UnreliableEvent.charRot Hook 已启动")
end)

-- ==========================================
-- [UI 构建逻辑]
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
local ActivePopup = nil

local function ToggleSideBar(show)
    isSideBarOut = show
    if show then
        TweenService:Create(SideBar, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Position = UDim2.new(1, -90, 0.5, -130)}):Play()
        if State.AutoHideThread then task.cancel(State.AutoHideThread) end
        State.AutoHideThread = task.delay(5, function()
            if isSideBarOut and not (ActivePopup and ActivePopup.Parent) then ToggleSideBar(false) end
        end)
    else
        TweenService:Create(SideBar, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Position = UDim2.new(1, 0, 0.5, -130)}):Play()
    end
end

-- 修复：弹窗打开时点击侧栏触发按钮应先关闭弹窗，避免UI状态混乱
SideBarTrigger.MouseButton1Click:Connect(function()
    if ActivePopup then ClosePopup() return end
    ToggleSideBar(not isSideBarOut)
end)

-- 修复：ClosePopup改为非yield，避免调用方时序问题；新增showSidebar参数控制是否回弹侧栏
ClosePopup = function(showSidebar)
    if not ActivePopup then return end
    local pop = ActivePopup
    ActivePopup = nil
    TweenService:Create(pop, TweenInfo.new(0.2), {Size = UDim2.new(0, 0, 0, 0)}):Play()
    TweenService:Create(BlurEffect, TweenInfo.new(0.2), {Size = 0}):Play()
    task.delay(0.2, function()
        if pop and pop.Parent then pop:Destroy() end
    end)
    if showSidebar ~= false then
        ToggleSideBar(true)
    end
end

-- 修复：快捷键放置函数，统一管理快捷键创建与注册
local function PlaceShortcutAt(pos, key, iconText)
    local shortcut = Instance.new("TextButton")
    shortcut.Size = UDim2.new(0, 50, 0, 50)
    shortcut.Position = UDim2.new(0, pos.X - 25, 0, pos.Y - 25)
    shortcut.BackgroundColor3 = Theme.Darker
    shortcut.BackgroundTransparency = Config[key] and 0.2 or 0.5
    shortcut.Text = iconText or "⚡"
    shortcut.TextColor3 = Theme.C1
    shortcut.Font = Enum.Font.GothamBold
    shortcut.TextSize = 20
    shortcut.Parent = ScreenGui
    Instance.new("UICorner", shortcut).CornerRadius = UDim.new(1, 0)
    shortcut:SetAttribute("ConfigKey", key)
    table.insert(State.Shortcuts, shortcut)
    if not State.ShortcutsByConfigKey[key] then State.ShortcutsByConfigKey[key] = {} end
    table.insert(State.ShortcutsByConfigKey[key], shortcut)

    local isPressing = false
    local isDragging = false
    local pressTime = 0
    local dragStartPos = nil
    local startUdimPos = nil

    shortcut.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            isPressing = true
            isDragging = false
            pressTime = tick()
            dragStartPos = inp.Position
            startUdimPos = shortcut.Position
        end
    end)

    shortcut.InputChanged:Connect(function(inp)
        if isPressing and (inp.UserInputType == Enum.UserInputType.MouseMovement or inp.UserInputType == Enum.UserInputType.Touch) then
            if dragStartPos and (inp.Position - dragStartPos).Magnitude > 15 then
                isDragging = true
                local dx = inp.Position.X - dragStartPos.X
                local dy = inp.Position.Y - dragStartPos.Y
                shortcut.Position = UDim2.new(startUdimPos.X.Scale, startUdimPos.X.Offset + dx, startUdimPos.Y.Scale, startUdimPos.Y.Offset + dy)
            end
        end
    end)

    shortcut.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 or inp.UserInputType == Enum.UserInputType.Touch then
            if not isPressing then return end
            isPressing = false

            local duration = tick() - pressTime
            if not isDragging then
                if duration >= 0.8 then
                    -- 长按删除
                    local k = shortcut:GetAttribute("ConfigKey")
                    shortcut:Destroy()
                    for i, sc in ipairs(State.Shortcuts) do if sc == shortcut then table.remove(State.Shortcuts, i) break end end
                    if k and State.ShortcutsByConfigKey[k] then
                        for i, sc in ipairs(State.ShortcutsByConfigKey[k]) do if sc == shortcut then table.remove(State.ShortcutsByConfigKey[k], i) break end end
                    end
                else
                    -- 短按切换
                    if ActivePopup then ClosePopup(false) end
                    Config[key] = not Config[key]
                    if State.GlobalCallbacks[key] then State.GlobalCallbacks[key](Config[key]) end
                    shortcut.BackgroundTransparency = Config[key] and 0.2 or 0.5
                end
            end
        end
    end)
end

-- 修复：快捷键放置模式改用全屏捕获按钮，避免点击穿透；增加视觉提示与ESC取消
local function StartPlacementMode(configKey, iconText)
    State.IsPlacingShortcut = true
    State.CurrentActionToBind = { configKey = configKey, icon = iconText }

    local capture = Instance.new("TextButton")
    capture.Size = UDim2.new(1, 0, 1, 0)
    capture.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    capture.BackgroundTransparency = 0.6
    capture.Text = "点击屏幕任意位置放置快捷键（ESC取消）"
    capture.TextColor3 = Color3.fromRGB(255, 255, 255)
    capture.TextStrokeTransparency = 0
    capture.Font = Enum.Font.GothamBold
    capture.TextSize = 22
    capture.ZIndex = 100
    capture.AutoButtonColor = false
    capture.Parent = ScreenGui
    State.PlacementCapture = capture

    capture.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            local pos = input.Position
            local bindAction = State.CurrentActionToBind
            State.IsPlacingShortcut = false
            State.CurrentActionToBind = nil
            State.PlacementCapture = nil
            capture:Destroy()
            if bindAction then
                PlaceShortcutAt(pos, bindAction.configKey, bindAction.icon)
            end
            ToggleSideBar(true)
        end
    end)
end

-- ESC取消放置模式
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if State.IsPlacingShortcut and input.KeyCode == Enum.KeyCode.Escape then
        State.IsPlacingShortcut = false
        State.CurrentActionToBind = nil
        if State.PlacementCapture then
            State.PlacementCapture:Destroy()
            State.PlacementCapture = nil
        end
        ToggleSideBar(true)
    end
end)

local function OpenPopup(TitleText, BuildContentFunc)
    -- 修复：打开弹窗时取消侧栏自动隐藏线程，避免无用残留
    if State.AutoHideThread then task.cancel(State.AutoHideThread) State.AutoHideThread = nil end
    if ActivePopup then ClosePopup(false) end
    Theme = GenerateNeonTheme()
    ToggleSideBar(false)

    SideBar.BackgroundColor3 = Theme.Darker
    ApplyGradient(sbStroke)
    ApplyGradient(SideBarTrigger)

    -- 修复：同步侧栏图标颜色至新主题
    for _, icon in ipairs(State.SideIcons) do
        icon.BackgroundColor3 = Theme.Dark
        icon.TextColor3 = Theme.C1
        for _, child in ipairs(icon:GetChildren()) do
            if child:IsA("UIStroke") then
                ApplyGradient(child)
            end
        end
    end

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
    CloseBtn.MouseButton1Click:Connect(function() ClosePopup() end)

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

local function CreateRow(parent, height)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, height)
    row.BackgroundColor3 = Theme.Darker
    row.Parent = parent
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)
    return row
end

-- 修复：CreateToggle增加wasLongPress标志，避免长按设置快捷键后误触开关切换；增加快捷键透明度同步
local function CreateToggle(parent, name, configKey, icon)
    local row = CreateRow(parent, 40)
    local state = Config[configKey]
    local wasLongPress = false

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

    local function SyncShortcuts()
        local shortcuts = State.ShortcutsByConfigKey[configKey]
        if shortcuts then
            for _, sc in ipairs(shortcuts) do
                sc.BackgroundTransparency = state and 0.2 or 0.5
            end
        end
    end

    local function ToggleState()
        -- 修复：如果是长按触发的释放，不切换状态
        if wasLongPress then
            wasLongPress = false
            return
        end
        state = not state
        Config[configKey] = state
        UpdateVisual()
        SyncShortcuts()  -- 修复：同步快捷键透明度
        if State.GlobalCallbacks[configKey] then State.GlobalCallbacks[configKey](state) end
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
                        -- 修复：检查弹窗是否仍然有效（防止弹窗已关闭后误触发）
                        if not ActivePopup or not ActivePopup.Parent then return end
                        wasLongPress = true
                        ClosePopup(false)
                        ToggleSideBar(false)
                        StartPlacementMode(configKey, icon)
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

local function CreateSlider(parent, name, minVal, maxVal, default, configKey, isFloat)
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
    valLabel.Text = isFloat and string.format("%.2f", default) or tostring(default)
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
        local val = isFloat and (minVal + (maxVal - minVal) * rel) or math.floor(minVal + (maxVal - minVal) * rel)
        fill.Size = UDim2.new(rel, 0, 1, 0)
        valLabel.Text = isFloat and string.format("%.2f", val) or tostring(val)
        Config[configKey] = val
    end

    barBg.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            update(input.Position)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then update(input.Position) end
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
        for _, child in ipairs(listContainer:GetChildren()) do if child:IsA("TextButton") then child:Destroy() end end
        local teams = getOptionsFunc()
        if #selectedTable == 0 then for _, team in ipairs(teams) do table.insert(selectedTable, team.Name) end end
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
            if table.find(selectedTable, team.Name) ~= nil then tBtn.BackgroundColor3 = Theme.C1 end
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
    table.insert(State.SideIcons, btn)  -- 新增：注册图标引用
    return btn
end

CreateSideIcon("⚔️", function()
    OpenPopup("近战杀戮", function(holder)
        CreateSlider(holder, "发包延迟 (0=极速)", 0, 1, Config.Melee_Delay, "Melee_Delay", true)
        CreateSlider(holder, "攻击范围", 5, 1000, Config.Melee_Range, "Melee_Range", false)
        CreateToggle(holder, "自动攻击", "Melee_Enabled", "⚔️")
        CreateToggle(holder, "高度多线程", "Melee_HyperThread", "🚀")
        CreateToggle(holder, "多部位打击", "Melee_MultiHit", "🎯")
        CreateToggle(holder, "强制战斗模式", "Melee_ForceCombatMode", "🔥")
        CreateToggle(holder, "自身免战斗模式", "Melee_SelfAntiCombatMode", "🛡️")
        CreateToggle(holder, "瞄准 NPC", "Melee_TargetNPC", "👾")
        CreateToggle(holder, "自动爆胎模式", "Melee_AutoPopTires", "🛞")
        CreateToggle(holder, "好友检测", "Melee_CheckFriends", "🤝")
        CreateToggle(holder, "可见性检测", "Melee_CheckVisibility", "👁️")
        local function GetTeams() local t = {} for _, team in ipairs(game:GetService("Teams"):GetTeams()) do table.insert(t, team) end return t end
        CreateMultiSelectList(holder, "队伍选择检测", GetTeams, "Melee_AllowedTeams", function(sel) end)
    end)
end)

CreateSideIcon("🔫", function()
    OpenPopup("远程杀戮", function(holder)
        CreateSlider(holder, "发包延迟 (0=极速)", 0, 1, Config.Ranged_Delay, "Ranged_Delay", true)
        CreateSlider(holder, "攻击范围", 100, 5000, Config.Ranged_Range, "Ranged_Range", false)
        CreateToggle(holder, "自动枪锁", "Ranged_Enabled", "🔫")
        CreateToggle(holder, "高度多线程", "Ranged_HyperThread", "🚀")
        CreateToggle(holder, "仅爆头(1.5倍率)", "Ranged_AutoHeadshot", "🧠")
        CreateToggle(holder, "散弹多发模拟", "Ranged_MultiBullet", "💥")
        CreateToggle(holder, "子弹穿墙", "Ranged_WallBang", "🧱")
        CreateToggle(holder, "瞄准 NPC", "Ranged_TargetNPC", "👾")
        CreateToggle(holder, "自动爆胎模式", "Ranged_AutoPopTires", "🛞")
        CreateToggle(holder, "激光无后座/无散射", "Ranged_NoRecoil", "🎯")
        CreateToggle(holder, "好友检测", "Ranged_CheckFriends", "🤝")
        CreateToggle(holder, "可见性检测", "Ranged_CheckVisibility", "👁️")
        local function GetTeams() local t = {} for _, team in ipairs(game:GetService("Teams"):GetTeams()) do table.insert(t, team) end return t end
        CreateMultiSelectList(holder, "队伍选择检测", GetTeams, "Ranged_AllowedTeams", function(sel) end)
    end)
end)

CreateSideIcon("👁️", function()
    OpenPopup("实用工具", function(holder)
        CreateToggle(holder, "玩家透视", "ESP_Enabled", "👻")
        CreateToggle(holder, "秒互动(防按住)", "InstantInteract_Enabled", "⚡")
        CreateToggle(holder, "工具无限耐久", "Tool_InfiniteDurability", "♾️")
        CreateToggle(holder, "全图超距互动", "GlobalInteract_Enabled", "🌐")
        CreateToggle(holder, "持续清理视觉效果", "CleanLightingEffects_Enabled", "✨")
    end)
end)

CreateSideIcon("🛡️", function()
    OpenPopup("防御系统", function(holder)
        CreateToggle(holder, "反死亡视觉", "NoKilledVisual_Enabled", "💀")
        CreateToggle(holder, "反强制Ragdoll", "AntiRagdoll_Enabled", "🤸")
        CreateToggle(holder, "快速起身", "FastGetUp_Enabled", "⬆️")
        CreateToggle(holder, "反强制弹出", "AntiEject_Enabled", "🚗")
        CreateToggle(holder, "反强制隐藏", "AntiCharHidden_Enabled", "👁️")
        CreateToggle(holder, "反强制转向", "AntiForceRotation_Enabled", "🔄")
        CreateToggle(holder, "面向锁定目标", "FaceLockedTarget_Enabled", "🎯")
    end)
end)

CreateSideIcon("⚙️", function()
    OpenPopup("设置", function(holder)
        CreateToggle(holder, "测试开关", "TestMode", "🧪")
    end)
end)

-- ==========================================
-- [核心视觉清理系统 - 深度扫描版]
-- ==========================================
function ClearLockVisuals(lockName)
    local mode = lockName == "KillSystem_MeleeLock" and "Melee" or "Ranged"
    local registry = State.VisualRegistry[mode]

    for char, hl in pairs(registry) do
        if hl then pcall(function() hl:Destroy() end) end
    end
    State.VisualRegistry[mode] = {}

    local function deepClean(parent)
        if not parent then return end
        for _, obj in ipairs(parent:GetDescendants()) do
            if obj:IsA("Highlight") and obj.Name == lockName then
                obj:Destroy()
            end
        end
    end
    pcall(deepClean, workspace)
    pcall(deepClean, Players)
end

local function SyncLockVisuals(activeChars, mode, lockName, color)
    -- 安全状态锁1：如果对应功能已被关闭，强行中断
    if not Config[mode .. "_Enabled"] then return end

    local registry = State.VisualRegistry[mode]
    local activeMap = {}

    for _, char in ipairs(activeChars) do
        if char and char.Parent then
            activeMap[char] = true
            if not registry[char] then
                -- 安全状态锁2：防止多线程并发在关闭瞬间强行创建
                if not Config[mode .. "_Enabled"] then return end
                local newHl = Instance.new("Highlight")
                newHl.Name = lockName
                newHl.FillColor = color
                newHl.OutlineColor = Color3.fromRGB(255, 255, 255)
                newHl.FillTransparency = 0.5
                newHl.Parent = char
                registry[char] = newHl
            end
        end
    end

    for char, hl in pairs(registry) do
        if not activeMap[char] or not char.Parent or not hl.Parent then
            if hl and hl.Parent then hl:Destroy() end
            registry[char] = nil
        end
    end
end

-- ==========================================
-- [核心公共逻辑：NPC与轮胎缓存扫描]
-- ==========================================
local npcCache = {}
local lastNpcScanTime = 0
local tireCache = {}
local lastTireScanTime = 0

local function UpdateNPCCache()
    if tick() - lastNpcScanTime < 0.5 then return end
    lastNpcScanTime = tick()
    table.clear(npcCache)
    for _, desc in ipairs(workspace:GetDescendants()) do
        if desc:IsA("Model") and not Players:GetPlayerFromCharacter(desc) then
            local hum = desc:FindFirstChildOfClass("Humanoid")
            local root = desc:FindFirstChild("HumanoidRootPart")
            if hum and root then
                table.insert(npcCache, {Char = desc, Humanoid = hum, Root = root})
            end
        end
    end
end

local function UpdateTireCache()
    if tick() - lastTireScanTime < 1 then return end
    lastTireScanTime = tick()
    table.clear(tireCache)
    local vehicles = workspace:FindFirstChild("Gameplay") and workspace.Gameplay:FindFirstChild("Vehicles")
    if vehicles then
        for _, car in ipairs(vehicles:GetChildren()) do
            for _, desc in ipairs(car:GetDescendants()) do
                if desc.Name == "WheelCollision" and not desc:GetAttribute("DontPuncture") then
                    table.insert(tireCache, desc)
                end
            end
        end
    end
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
    local targetNPC = Config[mode .. "_TargetNPC"]

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            if #allowedTeams > 0 and (not player.Team or not table.find(allowedTeams, player.Team.Name)) then continue end
            if checkFriends and LocalPlayer:IsFriendsWith(player.UserId) then continue end

            local targetChar = player.Character
            if targetChar and targetChar:FindFirstChild("HumanoidRootPart") and targetChar:FindFirstChild("Humanoid") and targetChar.Humanoid.Health > 0 then
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
                        table.insert(validTargets, {Player = player, Dist = dist, Char = targetChar, Root = targetRoot, IsNPC = false})
                    end
                end
            end
        end
    end

    if targetNPC then
        UpdateNPCCache()
        for _, npcData in ipairs(npcCache) do
            if npcData.Char ~= localChar and npcData.Humanoid.Health > 0 then
                local dist = (npcData.Root.Position - localRoot.Position).Magnitude
                if dist <= range then
                    local isVisible = true
                    if checkVis then
                        local params = RaycastParams.new()
                        params.FilterDescendantsInstances = {localChar}
                        params.FilterType = Enum.RaycastFilterType.Exclude
                        local hit = workspace:Raycast(localRoot.Position, (npcData.Root.Position - localRoot.Position), params)
                        if hit and not hit.Instance:IsDescendantOf(npcData.Char) then isVisible = false end
                    end
                    if isVisible then
                        table.insert(validTargets, {Player = {Name = npcData.Char.Name, UserId = 0}, Dist = dist, Char = npcData.Char, Root = npcData.Root, IsNPC = true})
                    end
                end
            end
        end
    end

    table.sort(validTargets, function(a, b) return a.Dist < b.Dist end)
    return validTargets
end

local function GetValidTires(rangeVal)
    local localChar = LocalPlayer.Character
    if not localChar or not localChar:FindFirstChild("HumanoidRootPart") then return {} end
    local localRoot = localChar.HumanoidRootPart
    local range = rangeVal
    local validTires = {}

    UpdateTireCache()
    for _, tire in ipairs(tireCache) do
        if tire.Parent and tire:GetAttribute("Durability") ~= 0 then
            local dist = (tire.Position - localRoot.Position).Magnitude
            if dist <= range then
                table.insert(validTires, {Tire = tire, Dist = dist, Pos = tire.Position})
            end
        end
    end
    table.sort(validTires, function(a, b) return a.Dist < b.Dist end)
    return validTires
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
    for _, t in ipairs(State.MeleeThreads) do pcall(task.cancel, t) end
    State.MeleeThreads = {}

    local threadCount = Config.Melee_HyperThread and 3 or 1

    for i = 1, threadCount do
        local t = task.spawn(function()
            while Config.Melee_Enabled do
                task.wait(Config.Melee_Delay > 0 and Config.Melee_Delay or 0.016)

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
                local activeChars = {}

                if #targets > 0 and localChar and localChar:FindFirstChild("HumanoidRootPart") then
                    local localRoot = localChar.HumanoidRootPart
                    local localPos = localRoot.Position

                    for _, targetData in ipairs(targets) do
                        local targetChar = targetData.Char
                        table.insert(activeChars, targetChar)

                        task.spawn(function()
                            local bodyPartsArr = Config.Melee_MultiHit and GetBodyPartsArray(targetChar) or {{ [1] = "HumanoidRootPart", [2] = 1 }}
                            local targetPos = targetData.Root.Position
                            local args = {
                                [1] = "damage",
                                [2] = {
                                    ["bodyParts"] = bodyPartsArr,
                                    ["shotCode"] = { [1] = targetPos, [2] = (localPos - targetPos).Unit },
                                    ["target"] = targetData.Player,
                                    ["pos"] = localPos
                                }
                            }
                            pcall(function() Remote:FireServer(unpack(args)) end)
                        end)
                    end
                end

                if Config.Melee_AutoPopTires then
                    local tires = GetValidTires(Config.Melee_Range)
                    for _, tireData in ipairs(tires) do
                        task.spawn(function()
                            if not localChar or not localChar:FindFirstChild("HumanoidRootPart") then return end
                            local localPos = localChar.HumanoidRootPart.Position
                            local shotCode = { localPos, (tireData.Pos - localPos).Unit }
                            pcall(function()
                                Remote:FireServer("damage", { shotCode = shotCode, pos = tireData.Pos, targetTire = tireData.Tire })
                            end)
                        end)
                    end
                end

                if i == 1 then
                    SyncLockVisuals(activeChars, "Melee", "KillSystem_MeleeLock", Color3.fromRGB(255, 0, 0))
                end
            end
        end)
        table.insert(State.MeleeThreads, t)
    end
end

-- ==========================================
-- [远程战斗逻辑]
-- ==========================================
local function GetEquippedWeaponName()
    local char = LocalPlayer.Character
    if not char then return "Unarmed" end
    for _, item in ipairs(char:GetChildren()) do if item:IsA("Tool") then return item.Name end end
    for _, item in ipairs(char:GetChildren()) do if item:IsA("Model") and item:FindFirstChild("Handle") then return item.Name end end
    return "Unarmed"
end

local function GetBarrelPos(char)
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Tool") then local barrel = item:FindFirstChild("Barrel") or item:FindFirstChild("Handle") if barrel then return barrel.Position end end
    end
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Model") and item:FindFirstChild("Handle") then local barrel = item:FindFirstChild("Barrel") or item:FindFirstChild("Handle") if barrel then return barrel.Position end end
    end
    return char.HumanoidRootPart.Position
end

function StartRangedLoop()
    for _, t in ipairs(State.RangedThreads) do pcall(task.cancel, t) end
    State.RangedThreads = {}

    local threadCount = Config.Ranged_HyperThread and 3 or 1

    for i = 1, threadCount do
        local t = task.spawn(function()
            while Config.Ranged_Enabled do
                task.wait(Config.Ranged_Delay > 0 and Config.Ranged_Delay or 0.016)

                local Remote = FetchRemote()
                if not Remote then task.wait(1) continue end

                local targets = GetValidTargets("Ranged")
                local localChar = LocalPlayer.Character
                local activeChars = {}

                if Config.Ranged_AutoPopTires then
                    local tires = GetValidTires(Config.Ranged_Range)
                    for _, tireData in ipairs(tires) do
                        task.spawn(function()
                            if not localChar or not localChar:FindFirstChild("HumanoidRootPart") then return end
                            local barrelPos = GetBarrelPos(localChar)
                            local shotCode = { barrelPos, (tireData.Pos - barrelPos).Unit }
                            pcall(function()
                                Remote:FireServer("damage", { shotCode = shotCode, pos = tireData.Pos, targetTire = tireData.Tire })
                            end)
                        end)
                    end
                end

                if #targets > 0 and localChar and localChar:FindFirstChild("HumanoidRootPart") then
                    for _, targetData in ipairs(targets) do
                        local targetChar = targetData.Char
                        table.insert(activeChars, targetChar)

                        task.spawn(function()
                            local hitPartName = Config.Ranged_AutoHeadshot and "Head" or "HumanoidRootPart"
                            local hitPart = targetChar:FindFirstChild(hitPartName) or targetChar:FindFirstChild("HumanoidRootPart")
                            if not hitPart then return end

                            local hitPos = hitPart.Position
                            local barrelPos = GetBarrelPos(localChar)
                            local shotCode = { barrelPos, (hitPos - barrelPos).Unit }
                            local weaponName = GetEquippedWeaponName()

                            for i = 1, (Config.Ranged_MultiBullet and 3 or 1) do
                                pcall(function() Remote:FireServer("bullet", { weaponName = weaponName, posDestroyX = hitPos.X + (i * 0.5), pos = hitPos }) end)
                            end

                            local damageArgs = {
                                [1] = "damage",
                                [2] = { bodyParts = { [1] = { [1] = hitPartName, [2] = 1 } }, shotCode = shotCode, target = targetData.Player, pos = hitPos }
                            }
                            if Config.Ranged_AutoHeadshot then damageArgs[2].damageFactor = 1.5 end
                            pcall(function() Remote:FireServer(unpack(damageArgs)) end)
                        end)
                    end
                end

                if i == 1 then
                    SyncLockVisuals(activeChars, "Ranged", "KillSystem_RangedLock", Color3.fromRGB(0, 0, 255))
                end
            end
        end)
        table.insert(State.RangedThreads, t)
    end
end

-- ==========================================
-- [ESP与实用工具逻辑 - 兼容workspace.Characters]
-- ==========================================
function ClearESP()
    for char, obj in pairs(State.ESPObjects) do
        if obj.Highlight then obj.Highlight:Destroy() end
        if obj.Billboard then obj.Billboard:Destroy() end
    end
    State.ESPObjects = {}
end

local function UpdateESP()
    if not Config.ESP_Enabled then return end

    local drawnChars = {}
    local localChar = LocalPlayer.Character

    local function ApplyESP(char, name, teamColor)
        if char == localChar then return end
        if not char or not char.Parent then return end

        local root = char:FindFirstChild("HumanoidRootPart")
        local hum = char:FindFirstChildOfClass("Humanoid")
        if not root or not hum or hum.Health <= 0 then return end

        drawnChars[char] = true
        local obj = State.ESPObjects[char]

        local needRebuild = false
        if not obj then
            needRebuild = true
        else
            if not obj.Highlight or not obj.Highlight.Parent or obj.Highlight.Parent ~= char then needRebuild = true end
            if not obj.Billboard or not obj.Billboard.Parent or obj.Billboard.Parent ~= root then needRebuild = true end
        end

        if needRebuild then
            if obj then
                if obj.Highlight then pcall(function() obj.Highlight:Destroy() end) end
                if obj.Billboard then pcall(function() obj.Billboard:Destroy() end) end
            end
            obj = {}
            obj.Highlight = Instance.new("Highlight")
            obj.Highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
            obj.Highlight.FillTransparency = 0.7
            obj.Highlight.Parent = char

            obj.Billboard = Instance.new("BillboardGui")
            obj.Billboard.Size = UDim2.new(0, 200, 0, 30)
            obj.Billboard.StudsOffset = Vector3.new(0, 3, 0)
            obj.Billboard.AlwaysOnTop = true
            obj.Billboard.Parent = root

            local lbl = Instance.new("TextLabel", obj.Billboard)
            lbl.Size = UDim2.new(1, 0, 1, 0)
            lbl.BackgroundTransparency = 1
            lbl.TextStrokeTransparency = 0
            lbl.Font = Enum.Font.GothamBold
            lbl.TextSize = 14
            obj.Label = lbl

            State.ESPObjects[char] = obj
        end

        obj.Highlight.FillColor = teamColor or Color3.fromRGB(255, 255, 255)

        local isMeleeLocked = State.VisualRegistry.Melee[char] ~= nil
        local isRangedLocked = State.VisualRegistry.Ranged[char] ~= nil

        local lockText, textColor = "", teamColor or Color3.fromRGB(255, 255, 255)
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
        obj.Label.Text = string.format("%s [%d/%d]%s", name, math.floor(hum.Health), hum.MaxHealth, lockText)
    end

    -- 1. 扫描 Players
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local char = player.Character
            local tColor = player.Team and player.Team.TeamColor.Color or Color3.fromRGB(255, 255, 255)
            if char then ApplyESP(char, player.Name, tColor) end
        end
    end

    -- 2. 扫描 workspace.Characters (该游戏特有机制)
    local wsChars = workspace:FindFirstChild("Characters")
    if wsChars then
        for _, char in ipairs(wsChars:GetChildren()) do
            if char:IsA("Model") and char ~= localChar then
                local player = Players:FindFirstChild(char.Name)
                local tColor = player and player.Team and player.Team.TeamColor.Color or Color3.fromRGB(200, 200, 200)
                ApplyESP(char, char.Name, tColor)
            end
        end
    end

    -- 3. 清理不再需要绘制的 ESP
    for char, obj in pairs(State.ESPObjects) do
        if not drawnChars[char] or not char.Parent then
            if obj.Highlight then obj.Highlight:Destroy() end
            if obj.Billboard then obj.Billboard:Destroy() end
            State.ESPObjects[char] = nil
        end
    end
end

RunService.RenderStepped:Connect(UpdateESP)

-- 互动系统（已移除自动拾取，仅保留秒互动与全图互动）
local function ProcessPrompt(prompt)
    if not prompt:IsA("ProximityPrompt") then return end

    if not prompt:GetAttribute("KS_OrigMaxDist") then
        prompt:SetAttribute("KS_OrigMaxDist", prompt.MaxActivationDistance)
    end
    if not prompt:GetAttribute("KS_OrigHoldDur") then
        prompt:SetAttribute("KS_OrigHoldDur", prompt.HoldDuration)
    end

    if Config.GlobalInteract_Enabled then
        prompt.MaxActivationDistance = 9999
    else
        prompt.MaxActivationDistance = prompt:GetAttribute("KS_OrigMaxDist")
    end

    if Config.InstantInteract_Enabled then
        prompt.HoldDuration = 0
    else
        prompt.HoldDuration = prompt:GetAttribute("KS_OrigHoldDur")
    end
end

local function ScanAndProcessPrompts()
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("ProximityPrompt") then
            ProcessPrompt(obj)
        end
    end
end

workspace.DescendantAdded:Connect(function(d)
    if d:IsA("ProximityPrompt") then
        ProcessPrompt(d)
    end
end)

task.spawn(function()
    while true do
        if Config.InstantInteract_Enabled or Config.GlobalInteract_Enabled then
            pcall(ScanAndProcessPrompts)
            task.wait(1)
        else
            task.wait(2)
        end
    end
end)

-- ==========================================
-- [防御与生存系统 - 基于反编译事件协议]
-- 通过Hook RemoteEvent.OnClientEvent 监听服务器推送的特定事件
-- 并在事件触发后执行防御性反制操作
-- ==========================================

-- 远程事件监听Hook：拦截服务器推送的特定事件并执行防御逻辑
task.spawn(function()
    local remote = FetchRemote()
    if not remote then
        task.wait(3)
        remote = FetchRemote()
    end
    if not remote then
        warn("[KillSystem] 防御系统：未找到RemoteEvent，事件监听未启动")
        return
    end

    remote.OnClientEvent:Connect(function(eventName, ...)
        -- 反死亡视觉：拦截killedVisual事件，禁用KilledColorCorrection
        -- 游戏原始处理：启用KilledColorCorrection并Tween亮度/对比度/饱和度
        -- 我们的对策：延迟一帧后强制禁用并归零所有参数
        if Config.NoKilledVisual_Enabled and eventName == "killedVisual" then
            task.spawn(function()
                task.wait(0.05)
                local cc = game.Lighting:FindFirstChild("KilledColorCorrection")
                if cc then
                    cc.Enabled = false
                    cc.Brightness = 0
                    cc.Contrast = 0
                    cc.Saturation = 0
                end
            end)
        end

        -- 反强制Ragdoll：拦截ragdoll事件，自动调用GettingUp恢复
        -- 游戏原始处理：调用v_u_9.activate(char, p194, p195, true) 激活Ragdoll
        -- 我们的对策：延迟0.1秒后强制切换到GettingUp状态起身
        if Config.AntiRagdoll_Enabled and eventName == "ragdoll" then
            task.spawn(function()
                task.wait(0.1)
                local char = LocalPlayer.Character
                if char and char:FindFirstChild("Humanoid") then
                    char.Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
                end
            end)
        end

        -- 反强制弹出：拦截eject事件，等待禁用期后重新进入最近车辆
        -- 游戏原始处理：v_u_8.disabled(true, "eject") 禁用互动 Handcuffs.HoldDuration*2 秒
        -- 我们的对策：等待禁用期结束，寻找30 studs内最近车辆并触发ProximityPrompt
        if Config.AntiEject_Enabled and eventName == "eject" then
            task.spawn(function()
                -- 计算eject禁用时长（Handcuffs.HoldDuration.Value * 2 + 1秒缓冲）
                local waitTime = 5
                pcall(function()
                    local handcuffs = game.ReplicatedStorage:FindFirstChild("Gameplay")
                    if handcuffs then
                        handcuffs = handcuffs:FindFirstChild("Items")
                    end
                    if handcuffs then
                        handcuffs = handcuffs:FindFirstChild("Handcuffs")
                    end
                    if handcuffs then
                        local hd = handcuffs:FindFirstChild("HoldDuration")
                        if hd and (hd:IsA("NumberValue") or hd:IsA("IntValue")) then
                            waitTime = hd.Value * 2 + 1
                        end
                    end
                end)
                task.wait(waitTime)

                -- 寻找最近的车辆
                local char = LocalPlayer.Character
                if not char or not char:FindFirstChild("HumanoidRootPart") then return end
                local localPos = char.HumanoidRootPart.Position
                local nearestVehicle = nil
                local nearestDist = math.huge
                local vehicles = workspace:FindFirstChild("Gameplay") and workspace.Gameplay:FindFirstChild("Vehicles")
                if vehicles then
                    for _, car in ipairs(vehicles:GetChildren()) do
                        if car:IsA("Model") then
                            local primaryPart = car.PrimaryPart or car:FindFirstChild("HumanoidRootPart") or car:FindFirstChildWhichIsA("BasePart")
                            if primaryPart then
                                local dist = (primaryPart.Position - localPos).Magnitude
                                if dist < nearestDist and dist < 30 then
                                    nearestDist = dist
                                    nearestVehicle = car
                                end
                            end
                        end
                    end
                end

                -- 尝试通过ProximityPrompt进入车辆
                if nearestVehicle then
                    local promptFound = false
                    for _, desc in ipairs(nearestVehicle:GetDescendants()) do
                        if desc:IsA("ProximityPrompt") then
                            local txt = string.lower(desc.ActionText .. " " .. desc.ObjectText)
                            if string.find(txt, "enter") or string.find(txt, "sit") or string.find(txt, "drive") or string.find(txt, "seat") then
                                pcall(function() desc:InputHoldBegin() end)
                                task.wait(0.15)
                                pcall(function() desc:InputHoldEnd() end)
                                promptFound = true
                                break
                            end
                        end
                    end
                    -- 如果没找到进入Prompt，尝试走向车辆
                    if not promptFound and char:FindFirstChild("Humanoid") then
                        char.Humanoid:MoveTo(nearestVehicle.PrimaryPart.Position)
                    end
                end
            end)
        end

        -- 反强制隐藏：拦截characterHidden事件，恢复触控与装备权限
        -- 游戏原始处理：禁用TouchControls、禁用EquipSlot、停用Ragdoll
        -- 我们的对策：恢复TouchControlsEnabled，标记装备槽为可用
        if Config.AntiCharHidden_Enabled and eventName == "characterHidden" then
            local hidden = ...
            if hidden then
                -- 恢复触控
                pcall(function()
                    game:GetService("GuiService").TouchControlsEnabled = true
                end)
                -- 尝试通过Remote恢复装备权限
                local r = FetchRemote()
                if r then
                    pcall(function() r:FireServer("characterIsPhysicallyOccupied", false) end)
                end
            end
        end
    end)
end)

-- 快速起身循环：持续监控Humanoid状态，物理Ragdoll时立即起身
-- 与AntiRagdoll互补：AntiRagdoll只拦截服务器ragdoll事件，
-- FastGetUp能捕获所有进入Physics状态的Ragdoll（包括物理碰撞导致）
task.spawn(function()
    while true do
        if Config.FastGetUp_Enabled then
            local char = LocalPlayer.Character
            if char and char:FindFirstChild("Humanoid") then
                local hum = char.Humanoid
                local state = hum:GetState()
                -- Physics状态通常表示Ragdoll（包括被车撞、爆炸等物理触发）
                if state == Enum.HumanoidStateType.Physics then
                    hum:ChangeState(Enum.HumanoidStateType.GettingUp)
                end
            end
            task.wait(0.1)
        else
            task.wait(1)
        end
    end
end)

-- 持续清理视觉效果：移除游戏添加的非系统Lighting效果
-- 保留我们自己的BlurEffect（名为KillSystem_Blur）
-- 如果NoKilledVisual开启，则KilledColorCorrection由其管理
local CleanEffectsLastCheck = 0
task.spawn(function()
    while true do
        if Config.CleanLightingEffects_Enabled then
            -- 限频检查，避免每帧遍历
            if tick() - CleanEffectsLastCheck >= 1 then
                CleanEffectsLastCheck = tick()
                for _, child in ipairs(game.Lighting:GetChildren()) do
                    -- 跳过我们自己的BlurEffect
                    if child.Name == "KillSystem_Blur" then continue end
                    -- 如果NoKilledVisual开启，跳过KilledColorCorrection（由其管理）
                    if child.Name == "KilledColorCorrection" and Config.NoKilledVisual_Enabled then continue end
                    -- 禁用各种视觉效果
                    if child:IsA("ColorCorrectionEffect") or child:IsA("BloomEffect") or
                       child:IsA("DepthOfFieldEffect") or child:IsA("SunRaysEffect") or
                       child:IsA("BlurEffect") or child:IsA("Atmosphere") then
                        pcall(function() child.Enabled = false end)
                    end
                end
            end
            task.wait(0.5)
        else
            task.wait(2)
        end
    end
end)

print("[KillSystem v10.18] 防御系统扩展版已加载。")

-- ==========================================
-- [防御系统 v2 - 状态轮询双重保障]
-- 问题：v1基于OnClientEvent事件监听，但可能因为以下原因失效：
--   1. 游戏的Ragdoll模块（v_u_9）可能使用自定义机制，不依赖Humanoid状态
--   2. PlatformStand为true时ChangeState(GettingUp)无效
--   3. Motor6D被禁用后需要手动重新启用
--   4. 事件监听器可能被游戏的包装机制过滤
-- 解决：使用RunService.Heartbeat持续强制状态，不依赖事件
-- ==========================================

local Heartbeat = RunService.Heartbeat
local GuiService = game:GetService("GuiService")

-- 调试计数器（控制台输出频率限制）
local DefDebugCounter = {
    AntiRagdoll = 0,
    FastGetUp = 0,
    NoKilledVisual = 0,
    AntiCharHidden = 0,
    AntiEject = 0
}

-- 持续状态强制循环：每帧检查并强制防御状态
Heartbeat:Connect(function()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChild("Humanoid")

    -- 反强制Ragdoll：持续强制PlatformStand=false、重新启用Motor6D
    if Config.AntiRagdoll_Enabled and hum then
        if hum.PlatformStand then
            hum.PlatformStand = false
            DefDebugCounter.AntiRagdoll = DefDebugCounter.AntiRagdoll + 1
            if DefDebugCounter.AntiRagdoll % 30 == 1 then
                print("[防御] AntiRagdoll: 强制PlatformStand=false")
            end
        end
        -- 重新启用所有Motor6D（Ragdoll模块会禁用它们）
        if char then
            for _, motor in ipairs(char:GetDescendants()) do
                if motor:IsA("Motor6D") and not motor.Enabled then
                    motor.Enabled = true
                end
            end
        end
        -- 调用GettingUp状态（每60帧调一次，避免过度调用）
        if DefDebugCounter.AntiRagdoll % 60 == 0 then
            local state = hum:GetState()
            if state == Enum.HumanoidStateType.Physics or state == Enum.HumanoidStateType.FallingDown then
                hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            end
        end
        DefDebugCounter.AntiRagdoll = DefDebugCounter.AntiRagdoll + 1
    end

    -- 快速起身：检测多种Ragdoll状态，立即起身
    if Config.FastGetUp_Enabled and hum then
        local state = hum:GetState()
        local needGetUp = false
        if state == Enum.HumanoidStateType.Physics then
            needGetUp = true
        elseif state == Enum.HumanoidStateType.FallingDown then
            needGetUp = true
        elseif hum.PlatformStand then
            needGetUp = true
        end
        if needGetUp then
            hum.PlatformStand = false
            hum:ChangeState(Enum.HumanoidStateType.GettingUp)
            DefDebugCounter.FastGetUp = DefDebugCounter.FastGetUp + 1
            if DefDebugCounter.FastGetUp % 30 == 1 then
                print("[防御] FastGetUp: 检测到Ragdoll状态，强制起身")
            end
        end
    end

    -- 反死亡视觉：持续监控KilledColorCorrection.Enabled
    if Config.NoKilledVisual_Enabled then
        local cc = game.Lighting:FindFirstChild("KilledColorCorrection")
        if cc and cc.Enabled then
            cc.Enabled = false
            cc.Brightness = 0
            cc.Contrast = 0
            cc.Saturation = 0
            DefDebugCounter.NoKilledVisual = DefDebugCounter.NoKilledVisual + 1
            if DefDebugCounter.NoKilledVisual % 10 == 1 then
                print("[防御] NoKilledVisual: 检测到死亡视觉启用，已强制禁用")
            end
        end
    end

    -- 反强制隐藏：持续监控TouchControlsEnabled
    if Config.AntiCharHidden_Enabled then
        if not GuiService.TouchControlsEnabled then
            GuiService.TouchControlsEnabled = true
            DefDebugCounter.AntiCharHidden = DefDebugCounter.AntiCharHidden + 1
            if DefDebugCounter.AntiCharHidden % 30 == 1 then
                print("[防御] AntiCharHidden: 检测到触控被禁用，已恢复")
            end
        end
        -- 尝试通过Remote恢复装备权限（限频，避免高频发包）
        if DefDebugCounter.AntiCharHidden % 60 == 0 then
            local r = FetchRemote()
            if r then
                pcall(function() r:FireServer("characterIsPhysicallyOccupied", false) end)
            end
        end
    end
end)

-- 反强制弹出增强版：事件驱动 + 重试机制 + 直接FireServer
-- v1问题：依赖ProximityPrompt可能找不到或触发失败
-- v2改进：1.增加直接FireServer('enterVehicle')备用方案 2.多次重试 3.增加等待时间
local EjectRetryThread = nil
task.spawn(function()
    local remote = FetchRemote()
    if not remote then
        task.wait(3)
        remote = FetchRemote()
    end
    if not remote then return end

    remote.OnClientEvent:Connect(function(eventName, ...)
        if Config.AntiEject_Enabled and eventName == "eject" then
            print("[防御] AntiEject: 检测到eject事件，启动反弹出序列")
            -- 取消之前的重试线程
            if EjectRetryThread then pcall(task.cancel, EjectRetryThread) end
            EjectRetryThread = task.spawn(function()
                -- 等待eject禁用期（默认Handcuffs.HoldDuration*2，备选5秒）
                local waitTime = 5
                pcall(function()
                    local handcuffs = game.ReplicatedStorage:FindFirstChild("Gameplay")
                    if handcuffs then handcuffs = handcuffs:FindFirstChild("Items") end
                    if handcuffs then handcuffs = handcuffs:FindFirstChild("Handcuffs") end
                    if handcuffs then
                        local hd = handcuffs:FindFirstChild("HoldDuration")
                        if hd and (hd:IsA("NumberValue") or hd:IsA("IntValue")) then
                            waitTime = hd.Value * 2 + 1
                        end
                    end
                end)
                task.wait(waitTime)

                -- 重试进入车辆（最多3次）
                for attempt = 1, 3 do
                    local char = LocalPlayer.Character
                    if not char or not char:FindFirstChild("HumanoidRootPart") then break end
                    local localPos = char.HumanoidRootPart.Position
                    local nearestVehicle = nil
                    local nearestDist = math.huge
                    local vehicles = workspace:FindFirstChild("Gameplay") and workspace.Gameplay:FindFirstChild("Vehicles")
                    if vehicles then
                        for _, car in ipairs(vehicles:GetChildren()) do
                            if car:IsA("Model") then
                                local primaryPart = car.PrimaryPart or car:FindFirstChildWhichIsA("BasePart")
                                if primaryPart then
                                    local dist = (primaryPart.Position - localPos).Magnitude
                                    if dist < nearestDist and dist < 50 then
                                        nearestDist = dist
                                        nearestVehicle = car
                                    end
                                end
                            end
                        end
                    end

                    if nearestVehicle then
                        print(string.format("[防御] AntiEject: 尝试 #%d 进入车辆 %s (距离%.1f studs)",
                            attempt, nearestVehicle.Name, nearestDist))

                        -- 方法1：直接通过RemoteEvent请求进入车辆
                        local r = FetchRemote()
                        if r then
                            pcall(function() r:FireServer("enterVehicle", nearestVehicle) end)
                        end

                        -- 方法2：触发ProximityPrompt
                        for _, desc in ipairs(nearestVehicle:GetDescendants()) do
                            if desc:IsA("ProximityPrompt") and desc.Enabled then
                                pcall(function() desc:InputHoldBegin() end)
                                task.wait(0.2)
                                pcall(function() desc:InputHoldEnd() end)
                                break
                            end
                        end

                        -- 方法3：走向车辆（如果还没进入）
                        task.wait(1)
                        local seat = char:FindFirstChild("Seat")
                        local isInVehicle = false
                        if seat and seat:IsA("Weld") and seat.Part1 then
                            isInVehicle = true
                        end
                        -- 检查是否还在车里（通过RootPart的Velocity或Seat属性）
                        if char:FindFirstChild("Humanoid") and char.Humanoid.Sit then
                            isInVehicle = true
                        end
                        if not isInVehicle and char:FindFirstChild("HumanoidRootPart") then
                            local vehiclePos = nearestVehicle.PrimaryPart and nearestVehicle.PrimaryPart.Position or nearestVehicle:GetPivot().Position
                            char.Humanoid:MoveTo(vehiclePos)
                        end
                        if isInVehicle then
                            print("[防御] AntiEject: 成功重新进入车辆")
                            return
                        end
                    else
                        print(string.format("[防御] AntiEject: 尝试 #%d 未找到附近车辆", attempt))
                    end
                    task.wait(1.5)
                end
                print("[防御] AntiEject: 反弹出序列结束")
            end)
        end
    end)
end)

print("[KillSystem v10.20] charRot协议防御版已加载。")
