--[[
    圣奥里杀戮系统加载器 v1.0
    使用方式:
    loadstring(game:HttpGet("https://github.com/q121314q67/kill-/raw/main/main.lua", true))()
]]

local function LoadScript(url)
    local success, result = pcall(function()
        return game:HttpGet(url, true)
    end)
    
    if success and result then
        local scriptFunc, err = loadstring(result)
        if scriptFunc then
            return pcall(scriptFunc)
        else
            warn("[KillSystem] 脚本加载失败: " .. tostring(err))
            return false
        end
    else
        warn("[KillSystem] 网络请求失败: " .. tostring(result))
        return false
    end
end

-- 主脚本加载
print("[KillSystem v9.7] 正在初始化...")
LoadScript("https://github.com/q121314q67/kill-/raw/main/SaintAuri_KillSystem.lua")
