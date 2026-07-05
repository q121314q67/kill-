--[[
    杀戮系统 v10.3 [移除圆环与队伍默认全选版]
    更新：
    1. 删除范围可视化圆环逻辑
    2. 队伍多选列表首次展开时默认全选所有队伍并高亮
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
    end
end

-- [系统初始化完成标记]
print("[Kill System v10.3] 初始化完成")