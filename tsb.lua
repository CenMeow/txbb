--[[
    Revenant 私人腳本
    - 鎖頭：精確的切換/按鍵綁定邏輯（AutoRotate + hrp.CFrame）
    - 反技能：完整虛擬碰撞箱系統
    - 技術衝刺：僅限本地玩家
    - 反彈飛 / 反虛空：Revenant 後端
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local LP               = Players.LocalPlayer
local Camera           = workspace.CurrentCamera

-- Library
local Library = loadstring(game:HttpGet('https://raw.githubusercontent.com/violin-suzutsuki/LinoriaLib/main/Library.lua'))()

-- ============================================================
-- STATE
-- ============================================================
local Loaded        = true
local Conns         = {}
local CamlockOn     = false
local enemy         = nil
local listeningKey  = false
local listenTarget  = nil
local currentHL     = nil
local fovCircle     = nil
pcall(function()
    fovCircle = Drawing.new("Circle")
    fovCircle.Visible     = false
    fovCircle.Thickness   = 1.5
    fovCircle.Color       = Color3.fromRGB(255, 200, 50)
    fovCircle.Filled      = false
    fovCircle.Transparency = 0.7
end)

-- Anti-Skill State
getgenv().DesyncActive = false
local ASConns        = {}
local ActiveHitboxes = {}

-- Counter animation IDs (local player playing these = skip dodge)
-- These are the "Counter" window animations in TSB
local COUNTER_ANIM_IDS = {
    ["10435118474"] = true, -- Generic counter
    ["10468516737"] = true, -- Saitama counter
    ["12272867895"] = true, -- Garou counter
    ["12534759925"] = true, -- Genos counter
    ["14299137407"] = true, -- Metal Bat counter
    ["16139147602"] = true, -- Tatsumaki counter
    ["13369677913"] = true, -- Sonic counter
    ["16082139744"] = true, -- Atomic Samurai counter
    ["17799245661"] = true, -- Suiryu counter
}

-- OPT A: isCountering - check if local player is in a counter window
-- Mirrors phontasm's `isCountering(u1092)` guard
local function isCountering()
    if not humanoid then return false end
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then return false end
    for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
        local id = t.Animation.AnimationId:gsub("rbxassetid://", "")
        if COUNTER_ANIM_IDS[id] and t.IsPlaying then
            return true
        end
    end
    return false
end

-- Character refs (updated on respawn)
local character = LP.Character or LP.CharacterAdded:Wait()
local humanoid  = character:WaitForChild("Humanoid")
local hrp       = character:WaitForChild("HumanoidRootPart")
local lastSafe  = hrp.CFrame

-- Dash
local dashLastTime = 0
local dashRunning  = false
local eventConns   = {}

-- Anti-Fling connections
local afConn, velConn, posConn  -- avConn removed: now handled by _avPlatformConn / _avRescueConn in EnableAV

-- ============================================================
-- KEY HELPERS (from Revenant)
-- ============================================================
local function StrToKey(s)
    local ok, v = pcall(function() return Enum.KeyCode[s] end)
    return (ok and v) or Enum.KeyCode.Unknown
end
local function KeyShort(kc)
    return tostring(kc):gsub("Enum%.KeyCode%.", "")
end

-- ============================================================
-- HIGHLIGHT HELPERS (from Revenant)
-- ============================================================
local function RemoveHighlight()
    if currentHL then pcall(function() currentHL:Destroy() end); currentHL = nil end
end
local function ApplyHighlight(char)
    if not char then return end
    if currentHL and currentHL.Parent == char then return end
    RemoveHighlight()
    local hl = Instance.new("Highlight")
    hl.FillTransparency    = 0.8
    hl.OutlineTransparency = 0
    hl.DepthMode           = Enum.HighlightDepthMode.AlwaysOnTop
    hl.FillColor           = Color3.fromRGB(255, 0, 0)
    hl.OutlineColor        = Color3.fromRGB(255, 0, 0)
    hl.Parent              = char
    currentHL = hl
end

-- ============================================================
-- FIND ENEMY (from Revenant - uses CFG via Options/Toggles)
-- ============================================================
local function FindEnemy()
    local bestDist, bestPart = math.huge, nil
    local mLoc = UserInputService:GetMouseLocation()
    local mx, my = mLoc.X, mLoc.Y
    local fovR = Options.FovRadius and Options.FovRadius.Value or 250
    local tPart = Options.TargetPart and Options.TargetPart.Value or "HumanoidRootPart"
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and p.Character then
            local part = p.Character:FindFirstChild(tPart)
            local hum  = p.Character:FindFirstChildOfClass("Humanoid")
            if part and hum and hum.Health > 0 then
                local sp, vis = Camera:WorldToViewportPoint(part.Position)
                if vis then
                    local d = math.sqrt((sp.X-mx)^2 + (sp.Y-my)^2)
                    if (fovR <= 0 or d < fovR) and d < bestDist then
                        bestDist = d; bestPart = part
                    end
                end
            end
        end
    end
    return bestPart
end

-- ============================================================
-- CAMLOCK TOGGLE (exact Revenant logic)
-- ============================================================
local function Toggle()
    if listeningKey then return end
    CamlockOn = not CamlockOn
    if CamlockOn then
        enemy = FindEnemy()
    else
        enemy = nil
        RemoveHighlight()
    end
    -- sync UI toggle if it exists
    pcall(function() Toggles.CamlockToggle:SetValue(CamlockOn) end)
end

-- ============================================================
-- CAMLOCK RENDER LOOP (AutoRotate + hrp.CFrame like Revenant)
-- ============================================================
table.insert(Conns, RunService.RenderStepped:Connect(function()
    -- FOV circle
    if fovCircle then
        pcall(function()
            fovCircle.Position = UserInputService:GetMouseLocation()
            fovCircle.Radius   = math.max(Options.FovRadius and Options.FovRadius.Value or 250, 1)
            fovCircle.Visible  = (Toggles.ShowFOV and Toggles.ShowFOV.Value or false)
                                  and (Options.FovRadius and Options.FovRadius.Value or 250) > 0
        end)
    end

    if not Loaded or not CamlockOn then
        RemoveHighlight()
        if humanoid and not dashRunning then pcall(function() humanoid.AutoRotate = true end) end
        return
    end

    -- Refresh dead/missing target
    if not enemy or not enemy.Parent then enemy = FindEnemy() end
    if not enemy then
        RemoveHighlight()
        if humanoid and not dashRunning then pcall(function() humanoid.AutoRotate = true end) end
        return
    end
    local eHum = enemy.Parent and enemy.Parent:FindFirstChildOfClass("Humanoid")
    if not eHum or eHum.Health <= 0 then
        enemy = FindEnemy()
        if not enemy then RemoveHighlight(); return end
    end

    ApplyHighlight(enemy.Parent)
    if humanoid and not dashRunning then pcall(function() humanoid.AutoRotate = false end) end

    local pred = enemy.Position + enemy.Velocity * (Options.Prediction and Options.Prediction.Value or 0.13)
    if hrp and character and not character:FindFirstChild("Ragdoll") and not dashRunning then
        local lookPos = Vector3.new(pred.X, hrp.Position.Y, pred.Z)
        hrp.CFrame = CFrame.new(hrp.Position, lookPos)
    end
end))

-- ============================================================
-- KEY INPUT (exact Revenant logic)
-- ============================================================
table.insert(Conns, UserInputService.InputBegan:Connect(function(input, _gp)
    if _gp then return end
    if listeningKey then
        if input.KeyCode == Enum.KeyCode.Escape then
            listeningKey = false; listenTarget = nil
            if _G.TSB_CancelBind then _G.TSB_CancelBind() end
        else
            local ks = KeyShort(input.KeyCode)
            if listenTarget == "aim" then
                getgenv()._TSB_AimKey = ks
            end
            listeningKey = false; listenTarget = nil
            if _G.TSB_FinishBind then _G.TSB_FinishBind(input.KeyCode) end
        end
        return
    end
    local keyName = getgenv()._TSB_AimKey or "C"
    if input.KeyCode == StrToKey(keyName) then Toggle() end
    -- Orbit key
    local orbitKey = getgenv()._TSB_OrbitKey or "X"
    if input.KeyCode == StrToKey(orbitKey) then
        pcall(function() toggleOrbit() end) -- toggled after orbit module defined
    end
end))


-- ============================================================
-- ANTI-SKILL: from `as` (Virtual Hitbox + Touched + Camera)
-- ============================================================
local SkillData = {
    -- Saitama
    ["10468665991"] = {char="Saitama", name="Anti Normal Punch",         hbSize=Vector3.new(5,5,12),   hbOffset=CFrame.new(0,0,-6),  duration=0.6},
    ["10466974800"] = {char="Saitama", name="Anti Consecutive Punches",  hbSize=Vector3.new(10,10,15), hbOffset=CFrame.new(0,0,-7),  duration=1.5},
    ["10471336737"] = {char="Saitama", name="Anti Shove",                hbSize=Vector3.new(6,6,8),    hbOffset=CFrame.new(0,0,-4),  duration=0.5},
    ["12510170988"] = {char="Saitama", name="Anti Uppercut",             hbSize=Vector3.new(6,6,8),    hbOffset=CFrame.new(0,0,-4),  duration=0.8},
    ["11365563255"] = {char="Saitama", name="Anti Table Flip",           hbSize=Vector3.new(25,25,25), hbOffset=CFrame.new(0,0,0),   duration=2.0},
    ["12983333733"] = {char="Saitama", name="Anti Serious Punch",         hbSize=Vector3.new(20,20,100), hbOffset=CFrame.new(0,0,-50), duration=2.5},
    ["13927612951"] = {char="Saitama", name="Anti Omni-Directional Punch", hbSize=Vector3.new(35,35,35), hbOffset=CFrame.new(0,0,0),   duration=3.0},
    ["11343318134"] = {char="Saitama", name="Anti Death Counter",        hbSize=Vector3.new(12,12,12), hbOffset=CFrame.new(0,0,0),   duration=1.0, delay=7.5},
    -- Garou
    ["12296882427"] = {char="Garou",   name="Anti Lethal Whirlwind Stream", hbSize=Vector3.new(15,10,15), hbOffset=CFrame.new(0,0,0),   duration=1.5},
    ["12307656616"] = {char="Garou",   name="Anti Hunters Grasp",        hbSize=Vector3.new(6,6,10),   hbOffset=CFrame.new(0,0,-5),  duration=1.2},
    ["13603396939"] = {char="Garou",   name="Anti Preys Peril",          hbSize=Vector3.new(8,8,12),   hbOffset=CFrame.new(0,0,-6),  duration=1.0},
    ["12272894215"] = {char="Garou",   name="Anti Flowing Water",        hbSize=Vector3.new(8,8,10),   hbOffset=CFrame.new(0,0,-5),  duration=1.2},
    ["12460977270"] = {char="Garou",   name="Anti Rock Smashing Fist",   hbSize=Vector3.new(12,5,12),  hbOffset=CFrame.new(0,0,-6),  duration=1.85},
    ["12463072679"] = {char="Garou",   name="Anti Final Hunt",           hbSize=Vector3.new(25,25,25), hbOffset=CFrame.new(0,0,0),   duration=0.75},
    ["14057231976"] = {char="Garou",   name="Anti Rock Splitting Fist",  hbSize=Vector3.new(10,10,10), hbOffset=CFrame.new(0,0,0),   duration=1.75},
    ["13630786846"] = {char="Garou",   name="Anti Crushed Rock",         hbSize=Vector3.new(25,10,75), hbOffset=CFrame.new(0,0,-37), duration=1.5},
    ["12342141464"] = {char="Garou",   name="Anti Garou Ult",            hbSize=Vector3.new(125,125,125), hbOffset=CFrame.new(0,0,0), duration=1.25, delay=3.5},
    -- Genos
    ["14721837245"] = {char="Genos",   name="Anti Thunder Kick",         hbSize=Vector3.new(25,25,25), hbOffset=CFrame.new(0,0,0),   duration=1.5},
    ["13083332742"] = {char="Genos",   name="Anti Flamewave Cannon",     hbSize=Vector3.new(12,5,1000), hbOffset=CFrame.new(0,0,-500), duration=4.0, delay=1.0},
    ["13146710762"] = {char="Genos",   name="Anti Incinerate",           hbSize=Vector3.new(100,75,400), hbOffset=CFrame.new(0,0,-200), duration=6.0, delay=3.25},
    -- Metal Bat
    ["14719290328"] = {char="Metal Bat", name="Anti Savage Tornado",     hbSize=Vector3.new(15,15,15), hbOffset=CFrame.new(0,0,0),   duration=2.5},
    ["15128849047"] = {char="Metal Bat", name="Anti Death Blow",         hbSize=Vector3.new(20,20,20), hbOffset=CFrame.new(0,0,0),   duration=1.5},
    -- Tatsumaki
    ["16515850153"] = {char="Tatsumaki", name="Anti Windstorm Fury",     hbSize=Vector3.new(25,25,25), hbOffset=CFrame.new(0,0,0),   duration=2.0},
    ["16431491215"] = {char="Tatsumaki", name="Anti Stone Grave",        hbSize=Vector3.new(15,15,15), hbOffset=CFrame.new(0,0,0),   duration=1.5},
    ["16597912086"] = {char="Tatsumaki", name="Anti Expulsive Push",      hbSize=Vector3.new(20,20,20), hbOffset=CFrame.new(0,0,0),   duration=1.2},
    ["17278415853"] = {char="Tatsumaki", name="Anti Terrible Tornado",    hbSize=Vector3.new(100,100,100), hbOffset=CFrame.new(0,0,0), duration=6.0, delay=11.0},
    ["16734584478"] = {char="Tatsumaki", name="Anti Tatsumaki Ult",      hbSize=Vector3.new(75,75,75), hbOffset=CFrame.new(0,0,0),   duration=5.75},
    -- Sonic
    ["13376869471"] = {char="Sonic",     name="Anti Flash Strike",       hbSize=Vector3.new(5,5,20),   hbOffset=CFrame.new(0,0,-10), duration=1.0},
    ["13294790250"] = {char="Sonic",     name="Anti Whirlwind Kick",     hbSize=Vector3.new(10,10,10), hbOffset=CFrame.new(0,0,-2.5), duration=0.75, delay=0.5},
    ["13632347366"] = {char="Sonic",     name="Anti Twinblade Rush",      hbSize=Vector3.new(75,75,75), hbOffset=CFrame.new(0,0,0),   duration=1.75},
    ["13881335713"] = {char="Sonic",     name="Anti Fourfold Flashstrike", hbSize=Vector3.new(35,5,60),  hbOffset=CFrame.new(0,0,-30), duration=0.75, delay=0.75},
    ["13723174078"] = {char="Sonic",     name="Anti Carnage",            hbSize=Vector3.new(35,50,250), hbOffset=CFrame.new(0,0,-125), duration=2.5, delay=0.5},
    -- Atomic Samurai
    ["16082123712"] = {char="Atomic Samurai", name="Anti Atomic Slash",  hbSize=Vector3.new(15,15,20), hbOffset=CFrame.new(0,0,-10), duration=2.5},
    ["15391323441"] = {char="Atomic Samurai", name="Anti Atomic Samurai Ult", hbSize=Vector3.new(125,125,125), hbOffset=CFrame.new(0,0,0), duration=1.0, delay=5.5},
    ["15520132233"] = {char="Atomic Samurai", name="Anti Sunset",           hbSize=Vector3.new(50,50,50),  hbOffset=CFrame.new(0,0,0),   duration=3.3},
    ["15676072469"] = {char="Atomic Samurai", name="Anti Solar Cleave",     hbSize=Vector3.new(50,10,150), hbOffset=CFrame.new(0,0,-75), duration=2.0},
    ["16057411888"] = {char="Atomic Samurai", name="Anti Atomic Slash Finisher", hbSize=Vector3.new(50,50,50), hbOffset=CFrame.new(0,0,0), duration=2.0, delay=4.25},
    -- Suiryu
    ["17857788598"] = {char="Suiryu",    name="Anti Whirlwind Drop",     hbSize=Vector3.new(35,100,35), hbOffset=CFrame.new(0,0,0),   duration=0.85, delay=0.65},
    ["18435535291"] = {char="Suiryu",    name="Anti Suiryu Ult",         hbSize=Vector3.new(100,100,100), hbOffset=CFrame.new(0,0,0), duration=1.25, delay=4.25},
    ["129651400898906"] = {char="Suiryu", name="Anti Grand Fissure",     hbSize=Vector3.new(75,75,75), hbOffset=CFrame.new(0,0,0),   duration=1.25, delay=0.5},
    ["18896229321"] = {char="Suiryu",    name="Anti Twin Fangs",         hbSize=Vector3.new(15,15,15), hbOffset=CFrame.new(0,0,0),   duration=3.5},
    ["18897119503"] = {char="Suiryu",    name="Anti Earth Splitting Strike", hbSize=Vector3.new(35,10,75), hbOffset=CFrame.new(0,0,-37), duration=2.5},
    ["106755459092436"] = {char="Suiryu", name="Anti Last Breath",        hbSize=Vector3.new(100,100,100), hbOffset=CFrame.new(0,0,0), duration=3.5, delay=3.0},
    -- KJ
    ["17141153099"] = {char="KJ",        name="Anti Stoic Bomb",         hbSize=Vector3.new(75,75,75), hbOffset=CFrame.new(0,0,0),   duration=1.5, delay=2.0},
    ["17354976067"] = {char="KJ",        name="Anti 20-20-20 Dropkick",   hbSize=Vector3.new(25,5,125), hbOffset=CFrame.new(0,0,-62), duration=5.0, delay=1.0},
    ["18462894593"] = {char="KJ",        name="Anti Five Seasons",       hbSize=Vector3.new(100,100,100), hbOffset=CFrame.new(0,0,0), duration=1.0, delay=6.75},
    -- Frozen Soul
    ["100558589307006"] = {char="Frozen Soul", name="Anti Permafrost",   hbSize=Vector3.new(45,25,85), hbOffset=CFrame.new(0,0,-42), duration=0.65, delay=0.35},
    ["137561511768861"] = {char="Frozen Soul", name="Anti Frost Forge",  hbSize=Vector3.new(150,150,150), hbOffset=CFrame.new(0,0,0), duration=0.75, delay=1.0},
    ["112620365240235"] = {char="Frozen Soul", name="Anti Freezing Path", hbSize=Vector3.new(20,10,35),  hbOffset=CFrame.new(0,0,-17), duration=4.0, delay=0.5},
    ["75547590335774"] = {char="Frozen Soul", name="Anti Judgement Chain", hbSize=Vector3.new(10,5,175),  hbOffset=CFrame.new(0,0,-87), duration=1.0, delay=0.35},
}


-- Camera-safe teleport
local function heartbeatTp(cf) if hrp then hrp.CFrame = cf end end

-- ============================================================
-- MULTI-STACK DODGE COUNTER
-- ============================================================
local DodgeCounter = 0
local function IsDodging() return DodgeCounter > 0 end

-- OPT D: TriggerAvoidance uses repeat..until with triple exit condition
-- (time expired OR attacker dead OR track stopped) - mirrors phontasm's structure
local function TriggerAvoidance(remainDuration, attackerHum, track)
    DodgeCounter = DodgeCounter + 1

    -- Safe originalCF
    local myPos = hrp and hrp.Position
    local originalCF
    if myPos and math.abs(myPos.Y) < 1000 and myPos.Magnitude < 100000 then
        originalCF = hrp.CFrame
    else
        originalCF = lastSafe
    end

    local oldSubject = Camera.CameraSubject
    Camera.CameraSubject = nil
    getgenv().DesyncActive = true

    local expire = tick() + math.max(remainDuration, 0.05)

    -- OPT D: repeat..until precision loop
    -- Exits when: time expired, OR attacker died, OR skill animation stopped
    repeat
        RunService.Heartbeat:Wait()
    until tick() >= expire
        or (attackerHum and (not attackerHum.Parent or attackerHum.Health <= 0))
        or (track and not track.IsPlaying)

    DodgeCounter = DodgeCounter - 1
    if DodgeCounter <= 0 then
        DodgeCounter = 0
        getgenv().DesyncActive = false
        heartbeatTp(originalCF)
        task.wait(0.08)
        Camera.CameraSubject = oldSubject
    end
end

-- Desync loop (write position every RenderStepped while active)
table.insert(ASConns, RunService.RenderStepped:Connect(function()
    if getgenv().DesyncActive and Toggles.DesyncSwitch.Value then
        heartbeatTp(CFrame.new(9e9, 9e9, 9e9))
    end
end))

-- Per-attacker per-skill dedup tables
local lastHitboxTime  = {}
local activeHitboxKey = {}
local HITBOX_COOLDOWN = 3.0

-- ============================================================
-- PRECISE SPATIAL QUERY HITBOX
-- OPT B: Magnitude pre-filter before hitbox scan (lightweight guard)
-- OPT C: data.delay now defers HITBOX CREATION, not dodge trigger
-- ============================================================
local function CreateHitbox(attacker, data, track)
    local attackerChar = attacker.Character
    local attackerRoot = attackerChar and attackerChar:FindFirstChild("HumanoidRootPart")
    local attackerHum  = attackerChar and attackerChar:FindFirstChildOfClass("Humanoid")
    if not attackerRoot then return end

    local key = attacker.Name .. "_" .. data.name
    if activeHitboxKey[key] then return end
    if lastHitboxTime[key] and tick() - lastHitboxTime[key] < HITBOX_COOLDOWN then return end

    activeHitboxKey[key] = true

    -- OPT C: Delay hitbox creation to match actual skill active frame
    -- (mirrors phontasm's `task.wait(N)` before building the Part hitbox)
    local startDelay = data.delay or 0
    if startDelay > 0 then
        local t0 = tick()
        repeat RunService.Heartbeat:Wait()
        until tick() - t0 >= startDelay
            or not track.IsPlaying
            or (attackerHum and attackerHum.Health <= 0)
        if not track.IsPlaying or (attackerHum and attackerHum.Health <= 0) then
            activeHitboxKey[key] = nil; return
        end
    end

    local startTime = tick()
    local duration  = data.duration
    local offset    = data.hbOffset or CFrame.new(0, 0, 0)
    local size      = data.hbSize   or Vector3.new(10, 10, 10)
    local triggered = false

    local params = OverlapParams.new()
    params.FilterType = Enum.RaycastFilterType.Include

    local loop
    loop = RunService.Heartbeat:Connect(function()
        -- Exit: animation stopped
        if track and not track.IsPlaying then
            activeHitboxKey[key] = nil; loop:Disconnect(); return
        end
        -- Exit: time window expired or attacker gone
        if tick() - startTime > duration or not attackerRoot or not attackerRoot.Parent then
            activeHitboxKey[key] = nil; loop:Disconnect(); return
        end
        -- Exit: attacker died mid-skill
        if attackerHum and attackerHum.Health <= 0 then
            activeHitboxKey[key] = nil; loop:Disconnect(); return
        end
        if triggered or IsDodging() then return end

        -- OPT A: Skip if local player is in counter window
        if isCountering() then return end

        local myChar = LP.Character
        if not myChar then return end
        local myRoot = myChar:FindFirstChild("HumanoidRootPart")
        if not myRoot then return end

        -- OPT B: Distance pre-filter (cheap magnitude check before expensive bounds query)
        -- Use the larger of hitbox size dimensions as max detection range
        local maxRange = math.max(size.X, size.Y, size.Z) + 20
        if (myRoot.Position - attackerRoot.Position).Magnitude > maxRange then return end

        params.FilterDescendantsInstances = {myChar}
        local checkCF = attackerRoot.CFrame * offset
        local hits = workspace:GetPartBoundsInBox(checkCF, size, params)

        if #hits > 0 then
            triggered = true
            lastHitboxTime[key] = tick()
            activeHitboxKey[key] = nil
            loop:Disconnect()
            -- Pass track + attackerHum for triple-exit condition in TriggerAvoidance
            task.spawn(TriggerAvoidance,
                duration - (tick() - startTime),
                attackerHum,
                track)
        end
    end)

    task.delay(duration + 0.5, function()
        activeHitboxKey[key] = nil
        pcall(function() loop:Disconnect() end)
    end)
end

-- Reverse Void (with attacker alive check)
local function TriggerReverseVoid(attacker)
    if IsDodging() then return end
    DodgeCounter = DodgeCounter + 1
    local attackerRoot = attacker.Character and attacker.Character:FindFirstChild("HumanoidRootPart")
    local attackerHum  = attacker.Character and attacker.Character:FindFirstChildOfClass("Humanoid")
    if attackerRoot then
        local startTime  = tick()
        local oldSubject = Camera.CameraSubject; Camera.CameraSubject = nil
        while tick() - startTime < 7.5 do
            RunService.Heartbeat:Wait()
            -- cancel if attacker already dead
            if not attackerHum or attackerHum.Health <= 0 then break end
            heartbeatTp(CFrame.new(0,-90000,0))
            attackerRoot.CFrame   = CFrame.new(0,-89995,0)
            pcall(function() attackerRoot.Velocity = Vector3.new(0,-5000,0) end)
        end
        Camera.CameraSubject = oldSubject
    end
    DodgeCounter = math.max(0, DodgeCounter - 1)
    if DodgeCounter == 0 then getgenv().DesyncActive = false end
end

-- Move Notification: animId -> display name
local MOVE_NOTIFY_IDS = {
    ["12273188754"] = "Death Counter",
    ["11365563255"] = "Table Flip",
    ["12983333733"] = "Serious Punch",
    ["13927612951"] = "Omni-Directional Punch",
    ["12447707844"] = "Saitama Ult",
    ["12296113986"] = "Death Blow",
    ["10397831167"] = "Last Breath",
    ["12981388367"] = "20-20-20 Dropkick",
    ["13188731002"] = "Serious Table Flip",
    ["16484268578"] = "Atomic Slash",
    ["10370118336"] = "Death Counter (victim)",
}

-- Invisible Moves: animIds whose tracks should be stopped to make them invisible
local INVIS_ANIM_IDS = {} -- populated by UI toggles at runtime

-- Skill Bring: local player anim -> {wait, tweenTime, area_key, optionalTPBack}
local SKILL_BRING_MAP = {
    ["12273188754"] = { prewait = 0.25, tweenTime = 0.75, defaultArea = "Death Counter" },
    ["12296113986"] = { prewait = 0,    tweenTime = 0.50, defaultArea = "Death Counter" },
    ["14048285180"] = { prewait = 0.35, tweenTime = 0.50, defaultArea = "Dark Domain"   },
    ["14046756619"] = { prewait = 0.35, tweenTime = 0.50, defaultArea = "Dark Domain"   },
}

-- ENEMY animation handler
local function onEnemyAnim(player, track)
    if not Toggles.MasterSwitch.Value then return end
    if not track.IsPlaying then return end
    local animId = track.Animation.AnimationId:gsub("rbxassetid://","")

    -- Move Notifications
    local notifyName = MOVE_NOTIFY_IDS[animId]
    if notifyName and Toggles.MoveNotifications and Toggles.MoveNotifications.Value then
        local sel = Options.MoveNotificationMoves and Options.MoveNotificationMoves.Value or {}
        if next(sel) == nil or sel[notifyName] then
            Library:Notify(player.DisplayName .. " used " .. notifyName, 4)
        end
    end

    local data = SkillData[animId]
    if not data then return end
    local opt = Options["AntiMoves_"..data.char:gsub(" ","")]
    if opt and opt.Value and opt.Value[data.name] then
        task.spawn(CreateHitbox, player, data, track)
    end
end


-- LOCAL PLAYER animation handler (Tech Dash + Invisible Moves + Skill Bring)
local function onLocalAnim(track)
    local animId = track.Animation.AnimationId:gsub("rbxassetid://","")

    -- Invisible Moves: stop animation track to hide it from others
    if Toggles.InvisibleMoves_Counter and Toggles.InvisibleMoves_Counter.Value then
        local COUNTER_IDS = { ["10470289916"]=true, ["10470294785"]=true, ["10568376050"]=true }
        if COUNTER_IDS[animId] then pcall(function() track:Stop(0) end); return end
    end
    if INVIS_ANIM_IDS[animId] then
        pcall(function() track:Stop(0) end)
    end

    -- Skill Bring: tween self to map area when using specific skill
    local bringData = SKILL_BRING_MAP[animId]
    if bringData and Toggles.SkillBring and Toggles.SkillBring.Value then
        task.spawn(function()
            if bringData.prewait > 0 then task.wait(bringData.prewait) end
            local areaKey = Options.SkillBringArea and Options.SkillBringArea.Value or bringData.defaultArea
            local destCF  = MAP_LOCATIONS[areaKey]
            if not destCF or not hrp then return end
            local savedCF = hrp.CFrame
            local ts = game:GetService("TweenService")
            local tw = ts:Create(hrp, TweenInfo.new(bringData.tweenTime, Enum.EasingStyle.Linear), { CFrame = destCF })
            tw:Play()
            task.wait(bringData.tweenTime + 0.1)
            if Toggles.SkillBringTPBack and Toggles.SkillBringTPBack.Value then
                pcall(function() animeTp(savedCF) end)
            end
        end)
    end

    -- Tech Dash
    if not Toggles.DashEnabled.Value then return end
    if animId ~= "10503381238" then return end
    local cd = Options.DashCooldown and Options.DashCooldown.Value or 0.35
    local dd = Options.DetectDelay  and Options.DetectDelay.Value  or 0.18
    if tick() - dashLastTime <= cd then return end
    dashLastTime = tick()
    task.delay(dd, function()
        local ok = pcall(function()  -- FIX: pcall ensures dashRunning always resets
            if dashRunning then return end
            local closest, bestD = nil, math.huge
            for _, p in pairs(Players:GetPlayers()) do
                if p ~= LP and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
                    local d = (hrp.Position - p.Character.HumanoidRootPart.Position).Magnitude
                    if d < bestD then bestD=d; closest=p.Character end
                end
            end
            if not closest then return end
            dashRunning = true
            local tHRP = closest:FindFirstChild("HumanoidRootPart")
            local sv_ws = humanoid.WalkSpeed; local sv_jp = humanoid.JumpPower
            humanoid.WalkSpeed=0; humanoid.JumpPower=0; humanoid.PlatformStand=true
            pcall(function() humanoid.AutoRotate=false end)
            pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Physics) end)
            hrp.CFrame = hrp.CFrame * CFrame.Angles(math.rad(85),0,0)
            local st = tick(); local dc
            dc = RunService.Heartbeat:Connect(function()
                if tick()-st >= 0.7 then dc:Disconnect(); return end
                if tHRP and tHRP.Parent then
                    hrp.CFrame = CFrame.new(tHRP.Position - tHRP.CFrame.LookVector*0.3)
                                 * CFrame.Angles(math.rad(85),0,0)
                end
            end)
            task.delay(0.3, function() pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end) end)
            task.delay(1.0, function()
                pcall(function()
                    humanoid.WalkSpeed=sv_ws; humanoid.JumpPower=sv_jp
                    humanoid.PlatformStand=false
                    humanoid.AutoRotate=true
                end)
                dashRunning=false
            end)
        end)
        if not ok then dashRunning = false end  -- reset on error
    end)
end

-- Setup: LP -> Tech Dash only | Enemies -> Anti-Skill only
-- FIX: Also connect Animator.AnimationPlayed (some games use this)
local function connectEnemy(p, c)
    local hum2 = c:WaitForChild("Humanoid", 10); if not hum2 then return end
    table.insert(ASConns, hum2.AnimationPlayed:Connect(function(t) onEnemyAnim(p,t) end))
    local anim2 = hum2:FindFirstChildOfClass("Animator")
    if anim2 then
        table.insert(ASConns, anim2.AnimationPlayed:Connect(function(t) onEnemyAnim(p,t) end))
    end
end
local function setupEnemyPlayer(p)
    table.insert(ASConns, p.CharacterAdded:Connect(function(c) connectEnemy(p,c) end))
    if p.Character then connectEnemy(p, p.Character) end
end
local function setupLocalPlayer()
    local function connectChar(c)
        local hum2 = c:WaitForChild("Humanoid", 10); if not hum2 then return end
        table.insert(ASConns, hum2.AnimationPlayed:Connect(function(t) onLocalAnim(t) end))
    end
    table.insert(ASConns, LP.CharacterAdded:Connect(connectChar))
    if LP.Character then connectChar(LP.Character) end
end

-- FIX: Clean up per-player tables when player leaves (prevent memory leak)
table.insert(ASConns, Players.PlayerRemoving:Connect(function(p)
    local prefix = p.Name .. "_"
    for k in pairs(lastHitboxTime)  do if k:sub(1, #prefix) == prefix then lastHitboxTime[k]  = nil end end
    for k in pairs(activeHitboxKey) do if k:sub(1, #prefix) == prefix then activeHitboxKey[k] = nil end end
end))

for _, p in pairs(Players:GetPlayers()) do
    if p ~= LP then setupEnemyPlayer(p) end
end
setupLocalPlayer()
table.insert(ASConns, Players.PlayerAdded:Connect(function(p)
    if p ~= LP then setupEnemyPlayer(p) end
end))


-- ============================================================
-- ANTI-FLING (Revenant backend)
-- ============================================================
local function EnableAF()
    afConn = RunService.Heartbeat:Connect(function()
        for _, p in pairs(character:GetChildren()) do
            if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then p.CanCollide = false end
        end
    end)
    velConn = RunService.Stepped:Connect(function()
        if hrp.Velocity.Magnitude > 50    then hrp.Velocity    = Vector3.zero end
        if hrp.RotVelocity.Magnitude > 50 then hrp.RotVelocity = Vector3.zero end
    end)
    posConn = RunService.Heartbeat:Connect(function()
        if hrp.Velocity.Magnitude < 50 and hrp.RotVelocity.Magnitude < 50 then lastSafe = hrp.CFrame end
    end)
    pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false) end)
end
local function DisableAF()
    for _, c in pairs({afConn, velConn, posConn}) do if c then pcall(function() c:Disconnect() end) end end
    afConn=nil; velConn=nil; posConn=nil
    pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, true) end)
end

-- ============================================================
-- ANTI VOID — Phontasm-exact implementation
-- Source: phontasm.txt lines 2016-2019
--   _Workspace.FallenPartsDestroyHeight = 0 / 0
--   _Workspace:GetPropertyChangedSignal('FallenPartsDestroyHeight'):Connect(function()
--       _Workspace.FallenPartsDestroyHeight = 0 / 0
--   end)
--
-- How it works:
--   Setting FallenPartsDestroyHeight to NaN (0/0) makes Roblox's engine
--   evaluate every "y < NaN" as false, so parts are never auto-deleted.
--   The AttributeChanged guard re-applies NaN if the game resets the property.
--   A transparent anchored Platform Part follows the player as a physical floor.
-- ============================================================
local _avFallenConn   = nil
local _avPlatformConn = nil
local _avPlatform     = nil
local _avNaNGuard     = false
local _avOrigDestroyH = nil  -- 啟用前存住原始値，關閉時還原
local AV_Y_MIN        = -490
local AV_Y_MAX        = 1500
local AV_VEL_THRESH   = 500
local _avFallingTicks = 0

local function createAVPlatform()
    if _avPlatform then pcall(function() _avPlatform:Destroy() end) end
    local p = Instance.new("Part")
    p.Name         = "_AVFloor"
    p.Anchored     = true
    p.CanCollide   = true
    p.CanTouch     = false
    p.CastShadow   = false
    -- 虛空地板：和 phontasm 一樣放在 Y=-10008
    -- 玩家傳送到 Y=-10000 後掉落 8 studs 落在此平台上站立
    p.Size         = Vector3.new(9e8, 10, 9e8)
    p.Transparency = 0.5
    p.Material     = Enum.Material.SmoothPlastic
    p.CFrame       = CFrame.new(0, -10008, 0)
    p.Parent       = workspace
    _avPlatform    = p
end

local function EnableAV()
    -- 存住原始值（關閉時還原）
    if _avOrigDestroyH == nil then
        pcall(function() _avOrigDestroyH = workspace.FallenPartsDestroyHeight end)
    end

    -- 關鍵：不用 NaN！Console 裡的 "nan" 輸出就是 TSB 偵測到 NaN 後的反作弊 log
    -- 改用 -10500（普通大負數）：讓玩家能到 Y=-10000 且不觸發 NaN 偵測
    local SAFE_HEIGHT = -10500
    pcall(function() workspace.FallenPartsDestroyHeight = SAFE_HEIGHT end)

    -- 建立虛空平台（Y=-10008，玩家在此站立）
    createAVPlatform()

    _avPlatformConn = RunService.Heartbeat:Connect(function()
        if not hrp then return end
        if not (_avPlatform and _avPlatform.Parent) then createAVPlatform() end

        -- 每幀檢查：若 TSB 重設回 -500，立即恢復為 -10500
        -- 不用 NaN，純簹普通數字，繞過 NaN 偵測
        local h = workspace.FallenPartsDestroyHeight
        if h ~= h or h > -10000 then  -- NaN 或被重設為較高值
            pcall(function() workspace.FallenPartsDestroyHeight = -10500 end)
        end

        if _flingBusy then return end

        local pos = hrp.Position
        local vel = hrp.Velocity

        -- 記錄安全位置
        if vel.Magnitude < 50 and pos.Y > AV_Y_MIN and pos.Y < AV_Y_MAX then
            lastSafe = hrp.CFrame
            _avFallingTicks = 0
        end

        -- 高 Y 或極端速度：傳送回 lastSafe
        if pos.Y > AV_Y_MAX or vel.Magnitude > AV_VEL_THRESH then
            _avFallingTicks = _avFallingTicks + 1
            if _avFallingTicks >= 3 then
                _avFallingTicks = 0
                pcall(function()
                    hrp.Velocity    = Vector3.zero
                    hrp.RotVelocity = Vector3.zero
                    hrp.CFrame      = lastSafe
                end)
            end
        else
            _avFallingTicks = 0
        end
    end)
end

local function DisableAV()
    if _avFallenConn   then pcall(function() _avFallenConn:Disconnect()   end); _avFallenConn   = nil end
    if _avPlatformConn then pcall(function() _avPlatformConn:Disconnect() end); _avPlatformConn = nil end
    if _avPlatform     then pcall(function() _avPlatform:Destroy()        end); _avPlatform     = nil end
    _avFallingTicks = 0
    _avNaNGuard     = false
    if _avOrigDestroyH ~= nil then
        pcall(function() workspace.FallenPartsDestroyHeight = _avOrigDestroyH end)
        _avOrigDestroyH = nil
    end
end

-- ============================================================
-- ORBIT SYSTEM — State (declared early for CharacterAdded scope)
-- ============================================================
local OrbitEnabled   = false
local OrbitAngle     = 0
local OrbitDirection = 1     -- 1 = CCW, -1 = CW
local OrbitConn      = nil
local _orbitPrevPos  = nil
local _orbitPrevVel  = Vector3.zero
local _orbitVelBuf   = {}
local ORBIT_VEL_N    = 6
local _orbitPrevVelDir  = nil
local _orbitSmoothedPos = nil
local _orbitTangentVel  = Vector3.zero

-- 智能鎖定系統
local _orbitLockedPlayer  = nil
local _orbitLockName      = ""
local ORBIT_SWITCH_RATIO  = 1.5
local ORBIT_MAX_DIST      = 350

-- Forward declarations (defined after anti-fling section)
local startOrbit, stopOrbit, toggleOrbit


-- Refresh on respawn
LP.CharacterAdded:Connect(function(c)
    character = c; humanoid = c:WaitForChild("Humanoid")
    hrp = c:WaitForChild("HumanoidRootPart"); lastSafe = hrp.CFrame
    if Toggles.AntiFling and Toggles.AntiFling.Value then DisableAF(); EnableAF() end
    if Toggles.AntiVoid  and Toggles.AntiVoid.Value  then
        -- Rebuild platform Part after respawn (old one destroyed with old character)
        if _avPlatformConn then pcall(function() _avPlatformConn:Disconnect() end); _avPlatformConn = nil end
        if _avPlatform     then pcall(function() _avPlatform:Destroy() end);        _avPlatform     = nil end
        EnableAV()
    end
    -- Restart orbit on respawn if it was active
    if OrbitEnabled and startOrbit then
        _orbitPrevPos = nil; _orbitPrevVel = Vector3.zero; _orbitVelBuf = {}
        startOrbit()
    end
    enemy = nil; RemoveHighlight()
end)

-- ============================================================
-- ORBIT SYSTEM — Implementation
-- Dual mode: Classic circular OR Predictive Intercept
-- ============================================================
local function _smoothVel(pos, dt)
    if not _orbitPrevPos then _orbitPrevPos = pos; return Vector3.zero end
    local raw = (pos - _orbitPrevPos) / math.max(dt, 0.001)
    table.insert(_orbitVelBuf, raw)
    if #_orbitVelBuf > ORBIT_VEL_N then table.remove(_orbitVelBuf, 1) end
    local sum = Vector3.zero
    for _, v in ipairs(_orbitVelBuf) do sum = sum + v end
    return sum / #_orbitVelBuf
end

-- Target lock: once detected, never release
local function getOrbitTarget()
    if not hrp then return nil end

    -- [1] Camlock enemy: highest priority
    if enemy and enemy.Parent then
        local ec = enemy.Parent
        local eh = ec and ec:FindFirstChildOfClass("Humanoid")
        if eh and eh.Health > 0 then
            local r = ec:FindFirstChild("HumanoidRootPart")
            if r then return r end
        end
    end

    -- [2] Permanent lock: never release while player is in the game
    if _orbitLockedPlayer then
        if not _orbitLockedPlayer.Parent then
            Library:Notify("Orbit: " .. _orbitLockName .. " left game", 2)
            _orbitLockedPlayer = nil
            _orbitLockName     = ""
        else
            local char = _orbitLockedPlayer.Character
            local r    = char and char:FindFirstChild("HumanoidRootPart")
            local h    = char and char:FindFirstChildOfClass("Humanoid")
            if r and h and h.Health > 0 then
                return r      -- alive, keep tracking
            else
                return nil    -- dead/respawning, pause (lock preserved)
            end
        end
    end

    -- [3] No lock: first-time acquisition (distance + camera + HP weighted)
    local cam    = workspace.CurrentCamera
    local camFwd = cam and cam.CFrame.LookVector or Vector3.new(0, 0, -1)
    local best, bestScore, bestPlayer = nil, -math.huge, nil

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and p.Character then
            local r = p.Character:FindFirstChild("HumanoidRootPart")
            local h = p.Character:FindFirstChildOfClass("Humanoid")
            if r and h and h.Health > 0 then
                local d         = (hrp.Position - r.Position).Magnitude
                local distScore = 100 / (d + 1)
                local toTarget  = (r.Position - hrp.Position)
                local camScore  = toTarget.Magnitude > 0
                    and math.max(0, toTarget.Unit:Dot(camFwd)) * 40 or 0
                local hpScore   = h.MaxHealth > 0
                    and (1 - h.Health / h.MaxHealth) * 20 or 0
                local total = distScore + camScore + hpScore
                if total > bestScore then
                    bestScore  = total
                    best       = r
                    bestPlayer = p
                end
            end
        end
    end

    if bestPlayer then
        _orbitLockedPlayer = bestPlayer
        _orbitLockName     = bestPlayer.DisplayName
        Library:Notify("Orbit locked: " .. _orbitLockName .. " (permanent)", 3)
    end
    return best
end


-- ============================================================
-- PING COMPENSATION — Utilities
-- ============================================================
local _Stats         = game:GetService("Stats")
local _targetPingEst = 0.080   -- rolling estimate of target one-way ping (seconds)
local _tpLastPos     = nil     -- last observed target position
local _tpLastTime    = 0       -- tick() when position last changed

-- Read OUR round-trip ping from Roblox Stats API (reliable)
local function getMyPingSeconds()
    local ok, val = pcall(function()
        return _Stats.Network.ServerStatsItem["Data Ping"].Value
    end)
    return (ok and type(val) == "number" and val > 0) and (val / 1000) or 0.080
end

-- Estimate TARGET's one-way ping from how often their position visibly updates.
-- Roblox replicates remote chars at ~1/(2*targetPing) Hz →
-- average interval between position jumps ≈ targetPing (one-way).
-- Uses exponential moving average (α=0.12) for stability against noise.
local function updateTargetPingEst(pos, now)
    if _tpLastPos and (pos - _tpLastPos).Magnitude > 0.05 then
        local interval = now - _tpLastTime
        if interval > 0.010 and interval < 0.500 then
            _targetPingEst = _targetPingEst * 0.88 + interval * 0.12
            _targetPingEst = math.clamp(_targetPingEst, 0.010, 0.300)
        end
        _tpLastTime = now
    elseif not _tpLastPos then
        _tpLastTime = now
    end
    _tpLastPos = pos
end


startOrbit = function()
    if OrbitConn then OrbitConn:Disconnect() end

    _orbitPrevPos = nil; _orbitPrevVel = Vector3.zero; _orbitVelBuf = {}
    _orbitPrevVelDir = nil; _orbitSmoothedPos = nil; _orbitTangentVel = Vector3.zero



    OrbitConn = RunService.RenderStepped:Connect(function(dt)
        if not OrbitEnabled then return end
        if not hrp or not humanoid or humanoid.Health <= 0 then return end

        local targetRoot = getOrbitTarget()
        if not targetRoot or not targetRoot.Parent then return end

        local radius    = Options.OrbitRadius   and Options.OrbitRadius.Value   or 10
        local speed     = Options.OrbitSpeed    and Options.OrbitSpeed.Value    or 1.5
        local heightOff = Options.OrbitHeight   and Options.OrbitHeight.Value   or 0
        local mode      = Options.OrbitMode     and Options.OrbitMode.Value     or "Classic"

        local targetPos = targetRoot.Position
        local newPos

        if mode == "Predictive" then
            -- ================================================================
            -- ENHANCED PREDICTIVE INTERCEPT — 3-Tier Adaptive System
            -- + Curvature tracking (handles arc/circular movement)
            -- + Bounding box tolerance (reduces jitter, looser but valid)
            -- ================================================================

            -- STEP 1: Full 3D velocity + acceleration
            local vel = _smoothVel(targetPos, dt)
            local acc = (vel - _orbitPrevVel) / math.max(dt, 0.001)
            _orbitPrevVel = vel
            _orbitPrevPos = targetPos

            local horizVel   = Vector3.new(vel.X, 0, vel.Z)
            local horizSpeed = horizVel.Magnitude
            local speed3D    = vel.Magnitude

            -- STEP 2: Adaptive prediction window (scales with target speed)
            local basePredT = Options.OrbitPredTime and Options.OrbitPredTime.Value or 0.3
            local predT     = math.clamp(basePredT * (1 + speed3D / 50), basePredT, basePredT * 5)

            -- STEP 2b: Ping Compensation
            -- ----------------------------------------------------------------
            -- Latency chain: observer → server → target's display
            --
            --  myPing      = our RTT ÷ 2  → how long until our CFrame hits server
            --  targetPing  = target's RTT ÷ 2  → extra delay before they see us
            --  totalDelay  = myPing + targetPingEst * 0.5
            --
            -- Adding totalDelay to predT shifts our position to where the target
            -- will actually BE by the time everything propagates end-to-end.
            -- ----------------------------------------------------------------
            local pingEnabled = Toggles.OrbitPingComp and Toggles.OrbitPingComp.Value
            if pingEnabled then
                updateTargetPingEst(targetPos, tick())
                local myPing     = getMyPingSeconds()
                local totalDelay = myPing + _targetPingEst * 0.5
                -- Cap added compensation at 0.5s to prevent extreme overshoot
                predT = math.min(predT + totalDelay, predT + 0.5)
            end

            -- STEP 3: Curvature estimation (angular velocity of horizontal movement)
            -- Enables accurate prediction of arc/circular movement patterns
            local angVel = 0
            if horizSpeed > 0.5 then
                local curDir = horizVel.Unit
                if _orbitPrevVelDir then
                    -- Cross product Y component = signed turn rate (rad/s)
                    local cross = _orbitPrevVelDir:Cross(curDir)
                    angVel = math.clamp(cross.Y / math.max(dt, 0.001), -15, 15)
                end
                _orbitPrevVelDir = curDir
            else
                _orbitPrevVelDir = nil
            end

            -- STEP 4: Curved kinematic prediction
            -- If target is turning, rotate predicted velocity direction by angVel * predT
            local predPos
            if math.abs(angVel) > 0.3 and horizSpeed > 1 then
                -- Arc prediction: rotate horizVel direction by expected turn
                local pa      = angVel * predT
                local cosA, sinA = math.cos(pa), math.sin(pa)
                local curDir  = horizVel.Unit
                local curvedX = curDir.X * cosA - curDir.Z * sinA
                local curvedZ = curDir.X * sinA + curDir.Z * cosA
                local curvedVel = Vector3.new(
                    curvedX * horizSpeed,
                    vel.Y,
                    curvedZ * horizSpeed
                )
                predPos = targetPos + curvedVel * predT
            else
                -- Linear prediction (straight-line mover)
                predPos = targetPos + vel * predT + 0.5 * acc * predT^2
            end

            -- STEP 5: Bounding box tolerance
            -- Treat target as a rectangle — any point within bbox counts as hit.
            -- This loosens required precision → less micro-adjustments → less jitter.
            local hitTol = 2.0  -- default: ~half of a normal humanoid width
            pcall(function()
                local char = targetRoot.Parent
                if char then
                    local bb = char:GetExtentsSize()
                    -- Half of the wider horizontal dimension
                    hitTol = math.max(bb.X, bb.Z) * 0.5
                end
            end)
            -- Effective orbit radius: pull inward by half hitTol so we're solidly inside bbox
            local effectiveR = math.max(radius - hitTol * 0.5, 4)

            -- Detect flying
            local isFlying = math.abs(vel.Y) > 8

            -- ── TIER 1: Stationary ──────────────────────────────────────
            if speed3D < 2 then
                OrbitAngle = OrbitAngle + speed * OrbitDirection * dt
                newPos = Vector3.new(
                    targetPos.X + math.cos(OrbitAngle) * effectiveR,
                    targetPos.Y + heightOff,
                    targetPos.Z + math.sin(OrbitAngle) * effectiveR
                )

            -- ── TIER 2: Medium speed (2~35 st/s) ────────────────────────
            -- Forward lead intercept + curvature correction
            elseif speed3D <= 35 then
                if horizSpeed > 1 then
                    local moveDir = horizVel.Unit
                    local sideDir = Vector3.new(-moveDir.Z * OrbitDirection, 0, moveDir.X * OrbitDirection)
                    -- 70% forward (ping lead) + 30% perpendicular (avoid direct head-on)
                    local combinedDir = (moveDir + sideDir * 0.3).Unit
                    local targetY = isFlying and (predPos.Y + heightOff) or (targetPos.Y + heightOff)
                    newPos = Vector3.new(
                        predPos.X + combinedDir.X * effectiveR,
                        targetY,
                        predPos.Z + combinedDir.Z * effectiveR
                    )
                else
                    OrbitAngle = OrbitAngle + speed * OrbitDirection * dt
                    local targetY = isFlying and (predPos.Y + heightOff) or (targetPos.Y + heightOff)
                    newPos = Vector3.new(
                        targetPos.X + math.cos(OrbitAngle) * effectiveR,
                        targetY,
                        targetPos.Z + math.sin(OrbitAngle) * effectiveR
                    )
                end

            -- ── TIER 3: High speed / Flying (>35 st/s) ──────────────────
            -- Closest-approach-point ballistic intercept
            else
                local relPos = predPos - hrp.Position
                local vDotV  = vel:Dot(vel)
                local t_ca   = vDotV > 0.001
                    and math.clamp(-relPos:Dot(vel) / vDotV, 0, predT) or 0
                local closestPt = predPos + vel * t_ca
                local offsetDir = vel.Magnitude > 0.1 and (-vel.Unit) or Vector3.new(0,0,-1)
                local rawPos    = closestPt + offsetDir * effectiveR
                local targetY   = isFlying and (closestPt.Y + heightOff) or (targetPos.Y + heightOff)
                newPos = Vector3.new(rawPos.X, targetY, rawPos.Z)
            end

        else
            -- CLASSIC CIRCULAR ORBIT
            _orbitPrevPos = targetPos
            local prevAngle = OrbitAngle
            OrbitAngle    = OrbitAngle + speed * OrbitDirection * dt
            newPos = Vector3.new(
                targetPos.X + math.cos(OrbitAngle) * radius,
                targetPos.Y + heightOff,
                targetPos.Z + math.sin(OrbitAngle) * radius
            )
            -- Tangent velocity for this frame (helps Roblox dead-reckoning on other clients)
            -- dpos/dθ = (-sin θ, 0, cos θ) · R, then multiply by ω
            local omega = speed * OrbitDirection
            _orbitTangentVel = Vector3.new(
                -math.sin(OrbitAngle) * radius * omega,
                0,
                 math.cos(OrbitAngle) * radius * omega
            )
        end

        -- ── REPLICATION FIX: Snap-then-Smooth ──────────────────────────────
        -- If we're more than 8 studs from the intended position (just enabled orbit
        -- or target teleported), snap immediately instead of crawling there via lerp.
        -- Otherwise apply smooth low-pass filter to eliminate per-frame jitter.
        local smooth    = Options.OrbitSmooth and Options.OrbitSmooth.Value or 0.75
        local lerpAlpha = 1 - smooth
        if not _orbitSmoothedPos then
            _orbitSmoothedPos = newPos  -- first frame: instant
        else
            local gap = (newPos - _orbitSmoothedPos).Magnitude
            if gap > 8 then
                _orbitSmoothedPos = newPos  -- large gap → snap (avoid slow crawl)
            else
                _orbitSmoothedPos = _orbitSmoothedPos:Lerp(newPos, lerpAlpha)
            end
        end

        -- ── VELOCITY HINT: helps Roblox dead-reckoning on other clients ──────
        -- Other clients interpolate our position between network packets using velocity.
        -- Setting it to the orbital tangent makes their prediction match our actual orbit.
        local tangVel = _orbitTangentVel or Vector3.zero
        pcall(function() hrp.Velocity = tangVel end)

        -- Always face current target (Y-locked)
        local lookAt = Vector3.new(targetPos.X, _orbitSmoothedPos.Y, targetPos.Z)
        hrp.CFrame = CFrame.new(_orbitSmoothedPos, lookAt)
        pcall(function() humanoid.AutoRotate = false end)

    end)
end

stopOrbit = function()
    if OrbitConn then OrbitConn:Disconnect(); OrbitConn = nil end
    _orbitLockedPlayer = nil
    _orbitLockName     = ""
    pcall(function() if humanoid then humanoid.AutoRotate = true end end)
end

toggleOrbit = function()
    OrbitEnabled = not OrbitEnabled
    if OrbitEnabled then startOrbit() else stopOrbit() end
    pcall(function() Toggles.OrbitEnabled:SetValue(OrbitEnabled) end)
end



-- ============================================================
-- UI (LinoriaLib)
-- ============================================================
local Window = Library:CreateWindow({ Title = 'Revenant private script', Center = true, AutoShow = true })
local Tabs = {
    Combat = Window:AddTab('戰鬥'),
    Anti   = Window:AddTab('反技能'),
    Orbit  = Window:AddTab('環繞'),
    Player = Window:AddTab('玩家'),
    Misc   = Window:AddTab('雜項'),
    Tech   = Window:AddTab('技術'),
}






-- ============================================================
-- Fling System  (phontasm port, v3 — 3 bug fixes)
-- Bug1: +AssemblyLinearVelocity (Velocity deprecated in new Roblox)
-- Bug2: restore loop runs forever like phontasm (no early break)
-- Bug3: stop when target Y > 100 or 3D dist > 100
-- ============================================================
local _flingBusy      = false
local _flingActive    = false
local _measuringVel   = false
local _flingLoopFlags = {}   -- required by stopFling()

local FLING_Y_OFFSETS = {
    ["Anti-Fling"] = -0.75,
    ["Normal"]     = 0,
    ["Void"]       = 1,
}

local function measureTargetVel(targetRP)
    if _measuringVel then return Vector3.zero end
    _measuringVel = true
    local p1 = targetRP.Position
    local t1 = tick()
    task.wait()
    local p2 = targetRP.Position
    local t2 = tick()
    _measuringVel = false
    local dt = t2 - t1
    if dt <= 0 then return Vector3.zero end
    return (p2 - p1) / dt
end

local function _doFlingImpl(targetPlayer, yOffset, speed, timeout)
    local myChar = LP.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    local myHum  = myChar:FindFirstChildOfClass("Humanoid")
    if not (myRoot and myHum) then return end

    local targetChar = targetPlayer.Character
    if not targetChar then return end
    local targetRP = targetChar:FindFirstChild("HumanoidRootPart")
    local targetHm = targetChar:FindFirstChildOfClass("Humanoid")
    if not (targetRP and targetHm) then return end

    -- Save position before fling; use lastSafe if current pos is bad
    local rawSavedCF = myRoot.CFrame
    local savedCF = (rawSavedCF.Position.Y > AV_Y_MIN + 10)
                    and rawSavedCF or (lastSafe or rawSavedCF)

    local angle     = 0
    local startTime = tick()
    local startPos  = targetRP.Position
    local targetVel = Vector3.zero

    local orbitWasEnabled = OrbitEnabled
    local orbitRadius = (Options.OrbitRadius and Options.OrbitRadius.Value) or 0
    if orbitWasEnabled and stopOrbit then pcall(stopOrbit) end

    local cam        = workspace.CurrentCamera
    local oldSubject = cam and cam.CameraSubject

    -- Main fling loop (mirrors phontasm 11354-11419)
    while true do
        if myRoot and myHum then
            if cam and cam.CameraSubject ~= targetHm then
                pcall(function() cam.CameraSubject = targetHm end)
            end

            task.spawn(function()
                if targetRP and targetRP.Parent then
                    targetVel = measureTargetVel(targetRP)
                end
            end)

            pcall(function() myHum.PlatformStand = true end)

            local spinCF  = CFrame.new(0, yOffset, 0) * CFrame.Angles(math.rad(90), 0, math.rad(angle))
            local snapPos = targetRP.Position
            angle = angle + speed

            local radX = orbitWasEnabled and math.cos(math.rad(angle)) * orbitRadius or 0
            local radZ = orbitWasEnabled and math.sin(math.rad(angle)) * orbitRadius or 0
            local orbitOffset = Vector3.new(radX, 0, radZ)
            local innerExpire = tick() + 0.01
            repeat
                pcall(function()
                    -- Fix Bug1: set both old+new velocity API
                    local flingVel = Vector3.new(0, -9e9, 0)
                    myRoot.Velocity = flingVel
                    pcall(function() myRoot.AssemblyLinearVelocity = flingVel end)
                    myRoot.CFrame = CFrame.new(snapPos + orbitOffset) * spinCF
                                  + targetHm.MoveDirection
                                  * (targetRP.Velocity.Magnitude / 1.25)
                end)
                task.wait()
            until tick() >= innerExpire

            pcall(function()
                myRoot.CFrame = CFrame.new(snapPos + orbitOffset) * spinCF
                              + targetHm.MoveDirection
                              * ((targetRP.Position - snapPos).Magnitude * 30)
            end)
        end

        task.wait()

        -- Exit conditions (phontasm 11387 + Bug3 fix)
        local tY      = targetRP and targetRP.CFrame.Y or 0
        local tDis    = targetRP and (targetRP.Position - startPos).Magnitude or 0
        local elapsed = tick() - startTime

        local shouldStop = false
        if tY > startPos.Y + 80 or tY <= -500    then shouldStop = true end  -- airborne: >80 above start, or in void
        if tDis >= 100                            then shouldStop = true end
        if targetVel.Magnitude >= 250          then shouldStop = true end
        if elapsed >= timeout                  then shouldStop = true end
        if not targetPlayer.Character or
           targetPlayer.Character ~= targetChar then shouldStop = true end
        if targetHm and targetHm.Health <= 0   then shouldStop = true end
        if not myChar or not LP.Character      then shouldStop = true end
        if not _flingActive                    then shouldStop = true end

        if shouldStop then
            if cam then
                local newHum = LP.Character and LP.Character:FindFirstChildWhichIsA("Humanoid")
                pcall(function() cam.CameraSubject = newHum or oldSubject end)
            end

            -- Fix Bug2: phontasm-style infinite restore loop (no timeout, no break)
            -- Keeps you pinned at savedCF until server syncs
            local myCharRef = LP.Character
            while true do
                if LP.Character ~= myCharRef then break end  -- respawned
                if myRoot then
                    pcall(function()
                        myRoot.CFrame      = savedCF
                        myRoot.Velocity    = Vector3.zero
                        myRoot.RotVelocity = Vector3.zero
                        pcall(function() myRoot.AssemblyLinearVelocity = Vector3.zero end)
                    end)
                end
                if myHum then
                    pcall(function()
                        myHum.PlatformStand = false
                        myHum:ChangeState(Enum.HumanoidStateType.GettingUp)
                    end)
                end
                task.wait()
                -- Once stable, clear busy flag and exit
                local posDiff = myRoot and (myRoot.Position - savedCF.Position).Magnitude or 999
                local velMag  = myRoot and myRoot.Velocity.Magnitude or 999
                if (posDiff <= 10 and velMag <= 500 and myHum and not myHum.PlatformStand)
                   or (LP.Character and LP.Character ~= myCharRef) then
                    _flingBusy = false
                    break
                end
            end

            pcall(function() if cam then cam.CameraSubject = oldSubject end end)
            if orbitWasEnabled and startOrbit then pcall(startOrbit) end
            return
        end
    end
end

local function doFling(targetPlayer, yOffset, speed, timeout)
    if _flingBusy then return end
    _flingBusy = true
    local ok, err = pcall(_doFlingImpl, targetPlayer, yOffset, speed, timeout)
    if _flingBusy then  -- pcall exited abnormally
        _flingBusy = false
        pcall(function()
            local c = LP.Character
            local h = c and c:FindFirstChildOfClass("Humanoid")
            local r = c and c:FindFirstChild("HumanoidRootPart")
            if h then h.PlatformStand = false; h:ChangeState(Enum.HumanoidStateType.GettingUp) end
            if r then r.Velocity = Vector3.zero; r.RotVelocity = Vector3.zero end
        end)
    end
end

local function execFling(looping)
    local modeOpt    = Options.FlingMode and Options.FlingMode.Value or "Void"
    local speedOpt   = Options.FlingSpd  and Options.FlingSpd.Value  or 15
    local timeoutOpt = Options.FlingTime and Options.FlingTime.Value or 3
    local yOff = FLING_Y_OFFSETS[modeOpt] or 1

    local selMap = Options.FlingTargets and Options.FlingTargets.Value or {}
    local targets = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP then
            if next(selMap) == nil or selMap[p.Name] then
                table.insert(targets, p)
            end
        end
    end
    if #targets == 0 then Library:Notify("Fling: no targets found", 2); return end

    _flingActive = true
    task.spawn(function()
        repeat
            for _, p in ipairs(targets) do
                if not _flingActive then break end
                if p and p.Character then
                    doFling(p, yOff, speedOpt, timeoutOpt)
                    if looping and _flingActive then task.wait(0.15) end
                end
            end
        until not looping or not _flingActive
        _flingActive = false
    end)
end

local function stopFling()
    _flingActive = false
    _flingBusy   = false   -- force release if stuck
    Library:Notify("Fling stopped", 2)
end


-- ============================================================
-- ANTI DEATH CUTSCENE — from provided script
-- Creates a giant anchored platform at Y=-501 (below map void).
-- When the game's death cutscene camera becomes active:
--   1. Wait 2 seconds
--   2. Teleport player to the safe platform
--   3. Fix camera back to humanoid
--   4. Teleport back to original position
-- This prevents the death animation from killing the player.
-- ============================================================
local _antiDeathConn    = nil
local _antiDeathChecking = false
local _antiDeathPart    = nil
local DEATH_SAFE_CF     = CFrame.new(-363.407135, -501.227661, 643.748657)

local function EnableAntiDeath()
    -- Create giant safe platform (matches provided script: 9e9 x 1.5 x 9e9)
    if _antiDeathPart then pcall(function() _antiDeathPart:Destroy() end) end
    local vp = Instance.new("Part")
    vp.Name         = "_AntiDeathFloor"
    vp.Size         = Vector3.new(9e4, 1.5, 9e4)  -- large enough to catch any fall position
    vp.Anchored     = true
    vp.CanCollide   = true
    vp.CanTouch     = false
    vp.CastShadow   = false
    vp.Material     = Enum.Material.Plastic
    vp.Transparency = 1               -- invisible
    vp.CFrame       = DEATH_SAFE_CF
    vp.Parent       = workspace
    _antiDeathPart  = vp

    local cam = workspace.CurrentCamera
    _antiDeathConn = RunService.RenderStepped:Connect(function()
        if _antiDeathChecking then return end
        if not (Toggles.AntiDeathCutscene and Toggles.AntiDeathCutscene.Value) then return end
        local cutscenes = workspace:FindFirstChild("Cutscenes")
        local deathScene = cutscenes and cutscenes:FindFirstChild("Death Cutscene")
        local deathCam  = deathScene and deathScene:FindFirstChild("Camm")
        if deathCam and cam.CameraSubject == deathCam then
            _antiDeathChecking = true
            task.spawn(function()
                if hrp then
                    local origCF = hrp.CFrame
                    task.wait(2)
                    if cam.CameraSubject == deathCam then
                        -- Teleport to safe platform to avoid death
                        pcall(function() hrp.CFrame = DEATH_SAFE_CF + Vector3.new(0, 5, 0) end)
                        cam.CameraSubject = humanoid
                        task.wait(0.1)
                        -- Return to original position
                        pcall(function() hrp.CFrame = origCF end)
                    end
                end
                _antiDeathChecking = false
            end)
        end
    end)
end

local function DisableAntiDeath()
    if _antiDeathConn then pcall(function() _antiDeathConn:Disconnect() end); _antiDeathConn = nil end
    if _antiDeathPart then pcall(function() _antiDeathPart:Destroy() end); _antiDeathPart = nil end
    _antiDeathChecking = false
end

-- 戰鬥頁籤
local AimBox = Tabs.Combat:AddLeftGroupbox('鎖定設定')
AimBox:AddToggle('CamlockToggle', { Text = '啟用目標鎖定', Default = false })
    :OnChanged(function(v) if v ~= CamlockOn then Toggle() end end)
AimBox:AddLabel('切換按鍵'):AddKeyPicker('CamlockKey', {
    Default = 'C', NoUI = false, Text = '鎖定按鍵',
    ChangedCallback = function(kc) getgenv()._TSB_AimKey = KeyShort(kc) end
})
AimBox:AddSlider('FovRadius',  { Text = 'FOV 半徑',  Default = 250,  Min = 0,   Max = 1000, Rounding = 0 })
AimBox:AddSlider('Prediction', { Text = '預測值',    Default = 0.13, Min = 0,   Max = 1,    Rounding = 2 })
AimBox:AddDropdown('TargetPart', { Text = '目標部位', Default = 'HumanoidRootPart', Values = {'Head','HumanoidRootPart','UpperTorso'} })
AimBox:AddToggle('ShowFOV', { Text = '顯示 FOV 圓圈', Default = false })

-- 甩飛面板（右側）
local FlingBox = Tabs.Combat:AddRightGroupbox('甩飛 (Fling)')

-- 玩家清單自動刷新邏輯
local _lastFlingNames = {}   -- 上次的玩家名單，用於比對是否需要更新

local function refreshFlingList()
    local names = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP then table.insert(names, p.Name) end
    end
    -- 只在清單有變化時才更新（避免不必要的 UI 重繪）
    local changed = #names ~= #_lastFlingNames
    if not changed then
        for i, n in ipairs(names) do
            if _lastFlingNames[i] ~= n then changed = true; break end
        end
    end
    if changed then
        _lastFlingNames = names
        if Options.FlingTargets then
            pcall(function() Options.FlingTargets:SetValues(names) end)
        end
    end
end

FlingBox:AddDropdown('FlingTargets', {
    Values    = {},
    Multi     = true,
    Text      = '選擇目標玩家（自動更新）',
    AllowNull = true,
})
FlingBox:AddLabel('清單每 3 秒自動刷新')
FlingBox:AddButton('全選', function()
    local t = {}
    if Options.FlingTargets then
        for _, v in pairs(Options.FlingTargets.Values) do t[v] = true end
        Options.FlingTargets:SetValue(t)
    end
end)
FlingBox:AddButton('全取消', function()
    if Options.FlingTargets then Options.FlingTargets:SetValue({}) end
end)
FlingBox:AddDivider()
FlingBox:AddDropdown('FlingMode', {
    Text    = '甩飛模式',
    Default = 'Void',
    Values  = { 'Anti-Fling', 'Normal', 'Void' },
})
FlingBox:AddLabel('Anti-Fling=向下壓  Normal=旋轉  Void=甩虛空')
FlingBox:AddSlider('FlingSpd', {
    Text = '旋轉速度', Default = 15, Min = 5, Max = 90, Rounding = 0,
})
FlingBox:AddSlider('FlingTime', {
    Text = '持續時間(秒)', Default = 3, Min = 1, Max = 10, Rounding = 0,
})
FlingBox:AddDivider()
FlingBox:AddButton('甩飛 (單次)', function() execFling(false) end)
FlingBox:AddButton('循環甩飛',   function() execFling(true)  end)
FlingBox:AddButton('停止甩飛',   stopFling)

-- 自動刷新：PlayerAdded/Removing 即時更新
table.insert(Conns, Players.PlayerAdded:Connect(function()
    task.wait(0.5); refreshFlingList()
end))
table.insert(Conns, Players.PlayerRemoving:Connect(function()
    task.wait(0.5); refreshFlingList()
end))

-- 自動刷新：Heartbeat 每 3 秒掃描一次（補漏網之魚）
do
    local _flingRefreshTick = 0
    table.insert(Conns, RunService.Heartbeat:Connect(function()
        if tick() - _flingRefreshTick >= 3 then
            _flingRefreshTick = tick()
            refreshFlingList()
        end
    end))
end

-- 初始填入清單
task.defer(refreshFlingList)


-- 反技能頁籤
local AntiGen = Tabs.Anti:AddLeftGroupbox('全域控制')
AntiGen:AddToggle('MasterSwitch', { Text = '主開關',    Default = true })
AntiGen:AddToggle('DesyncSwitch', { Text = '啟用位移同步', Default = true })
AntiGen:AddDivider()
AntiGen:AddToggle('AntiDeathCutscene', { Text = '反死拳(沒做好)', Default = false })
    :OnChanged(function(v)
        if v then EnableAntiDeath() else DisableAntiDeath() end
    end)
AntiGen:AddLabel('防止死亡動畫將你殺死')
AntiGen:AddDivider()
AntiGen:AddButton('全部開啟', function()
    local chars = {"Saitama","Garou","Genos","Metal Bat","Tatsumaki","Sonic","Atomic Samurai","Suiryu","KJ","Frozen Soul"}
    for _, name in pairs(chars) do
        local d = Options["AntiMoves_"..name:gsub(" ","")]
        if d then local t = {}; for _,v in pairs(d.Values) do t[v]=true end; d:SetValue(t) end
    end
end)
AntiGen:AddButton('全部關閉', function()
    local chars = {"Saitama","Garou","Genos","Metal Bat","Tatsumaki","Sonic","Atomic Samurai","Suiryu","KJ","Frozen Soul"}
    for _, name in pairs(chars) do
        local d = Options["AntiMoves_"..name:gsub(" ","")]; if d then d:SetValue({}) end
    end
end)
-- 重新初始化：重新連接所有動畫監聽器（修復玩家重新加入後失效的連線）
AntiGen:AddButton('重新初始化反技能連線', function()
    for _, c in ipairs(ASConns) do pcall(function() c:Disconnect() end) end
    table.clear(ASConns)
    for _, p in pairs(Players:GetPlayers()) do
        if p ~= LP then setupEnemyPlayer(p) end
    end
    setupLocalPlayer()
    Library:Notify("反技能連線已重新初始化。", 3)
end)


local function createAntiBox(charName, side)
    local box = side == "Left" and Tabs.Anti:AddLeftGroupbox('Anti '..charName)
                                or Tabs.Anti:AddRightGroupbox('Anti '..charName)
    local list = {}
    for _, d in pairs(SkillData) do if d.char == charName then table.insert(list, d.name) end end
    table.sort(list)
    box:AddDropdown('AntiMoves_'..charName:gsub(" ",""), {
        Values = list, Multi = true, Text = charName..' Moves', AllowNull = true
    })
end
createAntiBox("Saitama",        "Left")
createAntiBox("Garou",          "Right")
createAntiBox("Genos",          "Left")
createAntiBox("Metal Bat",      "Right")
createAntiBox("Tatsumaki",      "Left")
createAntiBox("Sonic",          "Right")
createAntiBox("Atomic Samurai", "Left")
createAntiBox("Suiryu",         "Right")
createAntiBox("KJ",             "Left")
createAntiBox("Frozen Soul",    "Right")


-- Misc Tab
local MiscBox = Tabs.Misc:AddLeftGroupbox('Exploit Protections')
MiscBox:AddToggle('AntiFling', { Text = 'Anti Fling', Default = false })
    :OnChanged(function(v) if v then EnableAF() else DisableAF() end end)

-- Anti Void — 4-layer system (phontasm reference, Void Y = -10000)
MiscBox:AddToggle('AntiVoid', { Text = 'Anti Void', Default = false })
    :OnChanged(function(v)
        if v then
            if Options.AVYMin then AV_Y_MIN     = Options.AVYMin.Value end
            if Options.AVYMax then AV_Y_MAX      = Options.AVYMax.Value end
            if Options.AVVelT then AV_VEL_THRESH = Options.AVVelT.Value end
            EnableAV()
        else
            DisableAV()
        end
    end)
MiscBox:AddSlider('AVYMin', {
    Text = 'Rescue Y Min', Default = -10000, Min = -10000, Max = -10, Rounding = 0,
    Callback = function(v) AV_Y_MIN = v end,
})
MiscBox:AddSlider('AVYMax', {
    Text = 'Rescue Y Max', Default = 1500, Min = 500, Max = 5000, Rounding = 0,
    Callback = function(v) AV_Y_MAX = v end,
})
MiscBox:AddSlider('AVVelT', {
    Text = 'Fling Speed Threshold', Default = 500, Min = 100, Max = 2000, Rounding = 0,
    Callback = function(v) AV_VEL_THRESH = v end,
})

MiscBox:AddButton('Unload Script', function()
    Loaded = false; CamlockOn = false; enemy = nil
    getgenv().DesyncActive = false
    OrbitEnabled = false; stopOrbit()
    for _, c in ipairs(Conns)   do pcall(function() c:Disconnect() end) end
    for _, c in ipairs(ASConns) do pcall(function() c:Disconnect() end) end
    DisableAF(); DisableAV(); DisableAntiDeath()
    for _, h in pairs(ActiveHitboxes) do pcall(function() h:Destroy() end) end
    if fovCircle then pcall(function() fovCircle:Remove() end) end
    RemoveHighlight()
    Library:Unload()
end)


-- 技術頁籤
local TechBox = Tabs.Tech:AddLeftGroupbox('技術衝刺設定')
TechBox:AddToggle('DashEnabled',  { Text = '啟用衝刺',   Default = true })
TechBox:AddSlider('DetectDelay',  { Text = '偵測延遲',   Default = 0.18, Min = 0,    Max = 1, Rounding = 2 })
TechBox:AddSlider('DashCooldown', { Text = '衝刺冷卻時間', Default = 0.35, Min = 0.05, Max = 2, Rounding = 2 })

-- ============================================================
-- 環繞頁籤 UI（按鍵觸發方式與自瞄相同）
-- ============================================================
local OrbBox = Tabs.Orbit:AddLeftGroupbox('環繞控制')
-- Toggle 與 Key 雙向同步（如同 CamlockToggle 的設計）
OrbBox:AddToggle('OrbitEnabled', { Text = '啟用環繞', Default = false })
    :OnChanged(function(v)
        if v ~= OrbitEnabled then toggleOrbit() end
    end)
-- 按鍵同自瞄：按鍵直接觸發 toggleOrbit()，並同步 UI Toggle 狀態
OrbBox:AddLabel('切換按鍵'):AddKeyPicker('OrbitKey', {
    Default = 'X', NoUI = false, Text = '環繞按鍵',
    Callback = function(v)
        -- 按下時直接觸發（和 camlock C 鍵一樣）
        if v then
            toggleOrbit()
        end
    end,
    ChangedCallback = function(kc) getgenv()._TSB_OrbitKey = KeyShort(kc) end,
})
OrbBox:AddDropdown('OrbitMode', {
    Text    = '模式',
    Default = 'Classic',
    Values  = { 'Classic', 'Predictive' },
})
OrbBox:AddButton('翻轉方向', function()
    OrbitDirection = OrbitDirection * -1
end)

local OrbParamsL = Tabs.Orbit:AddLeftGroupbox('參數')
OrbParamsL:AddSlider('OrbitRadius', {
    Text = '半徑 (studs)', Default = 10, Min = -40, Max = 40, Rounding = 1
})
OrbParamsL:AddSlider('OrbitSpeed', {
    Text = '速度 (rad/s)',  Default = 1.5, Min = 0, Max = 100, Rounding = 1
})
OrbParamsL:AddSlider('OrbitHeight', {
    Text = '高度',  Default = 0, Min = -10, Max = 20, Rounding = 1
})

local OrbParamsR = Tabs.Orbit:AddRightGroupbox('預測設定')
OrbParamsR:AddLabel('(僅在預測模式下使用)')
OrbParamsR:AddSlider('OrbitSmooth', {
    Text    = '平滑度(視覺)',
    Default = 0.75,
    Min     = 0,
    Max     = 0.95,
    Rounding = 2,
})
OrbParamsR:AddLabel('0 = instant/raw  0.95 = very stable')
OrbParamsR:AddLabel('Higher = less visual jitter')
OrbParamsR:AddSlider('OrbitPredTime', {
    Text    = '預測時間',
    Default = 0.01,
    Min     = 0.001,
    Max     = 1.0,
    Rounding = 4,
})
OrbParamsR:AddLabel('調低比較好')
OrbParamsR:AddToggle('OrbitPingComp', { Text = '補償延遲', Default = true })
OrbParamsR:AddLabel('如果偏移嚴重就關掉')

-- Init key from KeyPicker default
getgenv()._TSB_AimKey   = "C"
getgenv()._TSB_OrbitKey = "X"

-- ============================================================
-- PLAYER FEATURES — Flying, Speed, Invisibility, Anime TP
-- ============================================================

-- Flying state
local _flyConn   = nil
local _flySavedCF = nil

local function startFly()
    if _flyConn then _flyConn:Disconnect() end
    _flySavedCF = hrp and hrp.CFrame or CFrame.new()
    _flyConn = RunService.Heartbeat:Connect(function(dt)
        if not (hrp and humanoid) then return end
        if not (Toggles.FlyEnabled and Toggles.FlyEnabled.Value) then return end
        local cam   = workspace.CurrentCamera
        if not cam then return end
        local spd   = (Options.FlySpeed and Options.FlySpeed.Value or 80)
        local lv    = cam.CFrame.LookVector
        local rv    = cam.CFrame.RightVector
        local mv    = humanoid.MoveDirection
        local fwd   = Vector3.new(lv.X, 0, lv.Z).Unit
        local right = Vector3.new(rv.X, 0, rv.Z).Unit
        local dot_f = math.round(mv:Dot(fwd))
        local dot_r = math.round(mv:Dot(right))
        local vel   = Vector3.zero
        if dot_f  ==  1 then vel = vel + lv * spd end
        if dot_f  == -1 then vel = vel - lv * spd end
        if dot_r  ==  1 then vel = vel + rv * spd end
        if dot_r  == -1 then vel = vel - rv * spd end
        if vel.Magnitude > 0 then
            pcall(function() hrp.Velocity = vel end)
            _flySavedCF = hrp.CFrame
        else
            pcall(function() hrp.Velocity = Vector3.zero end)
            pcall(function() hrp.CFrame   = _flySavedCF  end)
        end
        pcall(function() hrp.RotVelocity = Vector3.zero end)
    end)
end
local function stopFly()
    if _flyConn then _flyConn:Disconnect(); _flyConn = nil end
    pcall(function() hrp.Velocity = Vector3.zero end)
end

-- Invisibility
local function applyInvisibility(on)
    local c = LP.Character; if not c then return end
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart"
            and not p.Name:lower():find("hitbox") then
            pcall(function() p.LocalTransparencyModifier = on and 1 or 0 end)
        end
    end
end

-- Anti Invisibility state
local _antiInvisConns = {}
local function setupAntiInvis(player)
    local c = player.Character; if not c then return end
    local h = c:FindFirstChildOfClass("Humanoid"); if not h then return end
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") then
            local savedT = p.Transparency
            table.insert(_antiInvisConns, p:GetPropertyChangedSignal("Transparency"):Connect(function()
                if p.Transparency == 1 and p ~= c:FindFirstChild("HumanoidRootPart") then
                    p.Transparency = savedT
                end
                savedT = p.Transparency
            end))
        end
    end
end
local function enableAntiInvis()
    for _, c in ipairs(_antiInvisConns) do pcall(function() c:Disconnect() end) end
    _antiInvisConns = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP then setupAntiInvis(p) end
    end
end

-- Anime Teleport (click-to-teleport with Heartbeat CFrame)
local function animeTp(targetCF)
    if not hrp then return end
    RunService.Heartbeat:Once(function()
        hrp.CFrame    = targetCF
        hrp.Velocity  = Vector3.zero
    end)
end

-- Anticheat detector state
local _acConn = nil

-- Auto Frozen Soul state
local _autoFSConn = nil

-- ============================================================
-- MAP TELEPORTS
-- ============================================================
local MAP_LOCATIONS = {
    ["Arena"]         = CFrame.new(-130, 440, -373),
    ["Middle"]        = CFrame.new(150, 441, 32),
    ["Jail"]          = CFrame.new(440, 440, -395),
    ["Bigger Jail"]   = CFrame.new(290, 440, 465),
    ["Dark Domain"]   = CFrame.new(-80, 84, 20395),
    ["Death Counter"] = CFrame.new(-66, 29, 20383),
    ["Mountain 1"]    = CFrame.new(9, 653, -363),
    ["Mountain 2"]    = CFrame.new(-1, 653, -354),
    ["Mountain Edge"] = CFrame.new(-297, 594, -336),
    ["Baseplate"]     = CFrame.new(1073, 406, 22984),
    ["Atomic Slash"]  = CFrame.new(1064, 131, 23007),
    ["Void"]          = CFrame.new(0, -10000, 0),
}
local MAP_LOCATION_NAMES = {}
for k in pairs(MAP_LOCATIONS) do table.insert(MAP_LOCATION_NAMES, k) end
table.sort(MAP_LOCATION_NAMES)


-- ============================================================
-- PLAYER TAB UI
-- ============================================================

-- Movement Groupbox
local PlrMoveBox = Tabs.Player:AddLeftGroupbox("Movement")

PlrMoveBox:AddToggle("FlyEnabled", { Text = "飛", Default = false })
    :OnChanged(function(v)
        if v then startFly() else stopFly() end
    end)
PlrMoveBox:AddSlider("FlySpeed", {
    Text = "飛行速度",  Default = 80, Min = 10, Max = 500, Rounding = 0,
})
PlrMoveBox:AddDivider()

PlrMoveBox:AddToggle("SpeedHackEnabled", { Text = "Speed", Default = false })
PlrMoveBox:AddSlider("SpeedHackValue", {
    Text = "速度倍率", Default = 2, Min = 1, Max = 20, Rounding = 1,
})

-- Speed hack runner
RunService.Heartbeat:Connect(function()
    if not (Toggles.SpeedHackEnabled and Toggles.SpeedHackEnabled.Value) then return end
    if not humanoid then return end
    pcall(function()
        humanoid.WalkSpeed = 16 * Options.SpeedHackValue.Value
    end)
end)

PlrMoveBox:AddDivider()
PlrMoveBox:AddToggle("AnimeTpEnabled", { Text = "瞬移", Default = false })
PlrMoveBox:AddLabel("按下 T 傳送到滑鼠游標位置")

-- Anime TP key handler
table.insert(Conns, UserInputService.InputBegan:Connect(function(inp, gp)
    if gp then return end
    if inp.KeyCode ~= Enum.KeyCode.Q then return end
    if not (Toggles.AnimeTpEnabled and Toggles.AnimeTpEnabled.Value) then return end
    local mouse = LP:GetMouse()
    if not mouse then return end
    local hitPos = mouse.Hit
    if not hitPos then return end
    if not hrp then return end
    local dest = CFrame.new(hitPos.Position)
                 * CFrame.new(0, 3, 0)
    animeTp(dest)
end))

-- Character Groupbox
local PlrCharBox = Tabs.Player:AddRightGroupbox("角色功能")
PlrCharBox:AddToggle("NoDashCooldown", {
    Text = "無dash冷卻", Default = false,
}):OnChanged(function(v)
    -- 使用延遲設定，降低快速切換被偵測的風险
    task.delay(0.5, function()
        if Toggles.NoDashCooldown and Toggles.NoDashCooldown.Value == v then
            pcall(function() workspace:SetAttribute("NoDashCooldown", v or nil) end)
        end
    end)
end)
PlrCharBox:AddToggle("NoFatigue", {
    Text = "無疲勞", Default = false,
}):OnChanged(function(v)
    task.delay(0.5, function()
        if Toggles.NoFatigue and Toggles.NoFatigue.Value == v then
            pcall(function() workspace:SetAttribute("NoFatigue", v or nil) end)
        end
    end)
end)
PlrCharBox:AddDivider()
PlrCharBox:AddToggle("InvisibilityEnabled", {
    Text = "隱身(沒用)", Default = false,
}):OnChanged(function(v)
    applyInvisibility(v)
end)
PlrCharBox:AddDivider()
PlrCharBox:AddToggle("RagdollHide", {
    Text = "倒地隱身(沒用)", Default = false,
})

-- 重生時：停止所有甩飛、清理 PlatformStand、重置甩飛旗標
LP.CharacterAdded:Connect(function(c)
    -- #3 重置甩飛鎖（防止死亡時 _flingBusy 卡住）
    _flingBusy   = false
    _flingActive = false

    task.wait(0.5)

    local newHum = c:FindFirstChildOfClass("Humanoid")
    if newHum then
        pcall(function()
            newHum.PlatformStand = false
            newHum:ChangeState(Enum.HumanoidStateType.GettingUp)
        end)
    end

    if Toggles.InvisibilityEnabled and Toggles.InvisibilityEnabled.Value then
        applyInvisibility(true)
    end
end)

-- Ragdoll hide runner
RunService.Heartbeat:Connect(function()
    if not (Toggles.RagdollHide and Toggles.RagdollHide.Value) then return end
    local c = LP.Character; if not c then return end
    local isRagdoll = c:FindFirstChild("Ragdoll") ~= nil
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then
            pcall(function()
                p.LocalTransparencyModifier = isRagdoll and 1 or 0
            end)
        end
    end
end)

-- ============================================================
-- MISC TAB UI
-- ============================================================
local MiscAntiCheatBox = Tabs.Misc:AddLeftGroupbox("Anticheat")
MiscAntiCheatBox:AddToggle("AnticheatDetector", {
    Text = "Anticheat Detector",
    Default = false,
}):OnChanged(function(v)
    if _acConn then _acConn:Disconnect(); _acConn = nil end
    if not v then return end
    local rep = game:GetService("ReplicatedStorage")
    local ev  = rep:FindFirstChild("Replication")
    if not ev then
        Library:Notify("[Anticheat] Replication event not found.", 4)
        return
    end
    _acConn = ev.OnClientEvent:Connect(function(data)
        if type(data) == "table" and tostring(data.Effect):lower() == "hicheck" then
            Library:Notify("[Anticheat] ⚠ A1 Flagged — You were flagged!", 10)
            if Options.AvoidBanMethod and Options.AvoidBanMethod.Value == "Auto Leave" then
                LP:Kick("[Revenant] Anticheat triggered — auto left for safety.")
            end
        end
    end)
end)
MiscAntiCheatBox:AddDropdown("AvoidBanMethod", {
    Text    = "On Detection",
    Default = "None",
    Values  = { "None", "Auto Leave" },
})
MiscAntiCheatBox:AddDivider()

-- Auto Frozen Soul
MiscAntiCheatBox:AddToggle("AutoFrozenSoul", {
    Text = "Auto Frozen Soul Escape",
    Default = false,
}):OnChanged(function(v)
    if _autoFSConn then _autoFSConn:Disconnect(); _autoFSConn = nil end
    if not v then return end
    local thrown = workspace:FindFirstChild("Thrown")
    if not thrown then return end
    local function handleFrozenLock(obj)
        if obj.Name ~= "Frozen Lock" then return end
        task.spawn(function()
            local root = obj:FindFirstChild("Root")
            if not root then return end
            local expire = tick() + 10
            while tick() < expire and obj.Parent and (Toggles.AutoFrozenSoul and Toggles.AutoFrozenSoul.Value) do
                RunService.Heartbeat:Wait()
                if hrp then
                    hrp.CFrame = root.CFrame * CFrame.new(0, 3, 0)
                end
            end
        end)
    end
    if thrown:FindFirstChild("Frozen Lock") then
        handleFrozenLock(thrown["Frozen Lock"])
    end
    _autoFSConn = thrown.ChildAdded:Connect(handleFrozenLock)
end)

-- Map Teleports
local MiscMapBox = Tabs.Misc:AddRightGroupbox("Map Teleports")
MiscMapBox:AddDropdown("MapTpLocation", {
    Text       = "Location",
    Default    = "Middle",
    Values     = MAP_LOCATION_NAMES,
    Searchable = true,
})
MiscMapBox:AddButton("Teleport", function()
    local loc = Options.MapTpLocation and Options.MapTpLocation.Value or "Middle"
    local cf  = MAP_LOCATIONS[loc]
    if cf and hrp then
        animeTp(cf * CFrame.new(0, 3, 0))
        Library:Notify("→ Teleport: " .. loc, 2)
    end
end)

-- ============================================================
-- ANTI TAB: Anti Invisibility (added to existing Anti tab)
-- ============================================================
local AntiExBox = Tabs.Anti:AddRightGroupbox("Anti Exploits")
AntiExBox:AddToggle("AntiInvisibility", {
    Text = "Anti Invisibility",
    Default = false,
}):OnChanged(function(v)
    if v then
        enableAntiInvis()
        -- Also hook new players
        table.insert(ASConns, Players.PlayerAdded:Connect(function(p)
            if Toggles.AntiInvisibility and Toggles.AntiInvisibility.Value then
                p.CharacterAdded:Connect(function()
                    task.wait(1)
                    setupAntiInvis(p)
                end)
                setupAntiInvis(p)
            end
        end))
    else
        for _, c in ipairs(_antiInvisConns) do pcall(function() c:Disconnect() end) end
        _antiInvisConns = {}
    end
end)
AntiExBox:AddLabel("Forces enemy characters visible")
AntiExBox:AddLabel("even if they use an invisibility hack")

local MiscExtraBox = Tabs.Misc:AddLeftGroupbox("Extra")
MiscExtraBox:AddToggle("DisableMessaging", {
    Text    = "Disable Messaging (self)",
    Default = false,
    Tooltip = "Prevents you from sending chat messages accidentally.",
})

-- Workspace attribute guard
local _attrGuardCD = {}
workspace.AttributeChanged:Connect(function(attr)
    local now = tick()
    if attr == "NoDashCooldown" then
        if not Toggles.NoDashCooldown or not Toggles.NoDashCooldown.Value then return end
        if (_attrGuardCD[attr] or 0) + 2 > now then return end
        _attrGuardCD[attr] = now
        task.delay(0.3, function()
            pcall(function() workspace:SetAttribute("NoDashCooldown", true) end)
        end)
    elseif attr == "NoFatigue" then
        if not Toggles.NoFatigue or not Toggles.NoFatigue.Value then return end
        if (_attrGuardCD[attr] or 0) + 2 > now then return end
        _attrGuardCD[attr] = now
        task.delay(0.3, function()
            pcall(function() workspace:SetAttribute("NoFatigue", true) end)
        end)
    end
end)


-- ============================================================
-- WALL COMBO ANYWHERE
-- Triggers when local character's Combo attribute reaches 5.
-- Sets desync to overlap target, then to wall combo area.
-- ============================================================
local _wallComboConn = nil

local function setupWallCombo(char)
    if _wallComboConn then pcall(function() _wallComboConn:Disconnect() end) end
    _wallComboConn = char.AttributeChanged:Connect(function(attr)
        if attr ~= "Combo" then return end
        if not Toggles.WallComboAnywhere or not Toggles.WallComboAnywhere.Value then return end
        local combo = char:GetAttribute("Combo")
        if combo ~= 5 then return end

        -- Get target root
        local tgt = getOrbitTarget()
        if not tgt or not tgt.Parent then return end

        task.spawn(function()
            local destKey = Options.WallComboArea and Options.WallComboArea.Value or "Arena"
            local destCF  = MAP_LOCATIONS[destKey]
            if not destCF then return end

            getgenv().DesyncActive = true
            local expire = tick() + 0.6
            repeat
                pcall(function()
                    heartbeatTp(tgt.CFrame * CFrame.new(0, -0.5, 0) * CFrame.Angles(math.rad(-90), 0, 0))
                end)
                task.wait()
            until tick() >= expire

            getgenv().DesyncActive = false

            -- Now teleport to wall combo area
            local savedCF = hrp and hrp.CFrame
            pcall(function() heartbeatTp(destCF) end)
            task.wait(0.2)

            if Toggles.WallComboTPBack and Toggles.WallComboTPBack.Value and savedCF then
                task.wait(0.8)
                pcall(function() animeTp(savedCF) end)
            end
        end)
    end)
end

-- Hook Wall Combo into CharacterAdded
local _origCharConn = LP.CharacterAdded:Connect(function(c)
    if Toggles.WallComboAnywhere and Toggles.WallComboAnywhere.Value then
        task.spawn(function()
            task.wait(1)
            setupWallCombo(c)
        end)
    end
end)
if LP.Character then
    task.spawn(function()
        task.wait(1)
        pcall(function() setupWallCombo(LP.Character) end)
    end)
end

-- ============================================================
-- BLOCK INVISIBILITY: AttributeChanged on local character
-- ============================================================
local function setupBlockInvis(char)
    table.insert(ASConns, char.AttributeChanged:Connect(function(attr)
        if attr == "Blocking" and char:GetAttribute("Blocking") then
            if Toggles.InvisibleMoves_Block and Toggles.InvisibleMoves_Block.Value then
                pcall(function() char:SetAttribute("Blocking", false) end)
            end
        end
    end))
end
LP.CharacterAdded:Connect(function(c) task.spawn(setupBlockInvis, c) end)
if LP.Character then pcall(function() setupBlockInvis(LP.Character) end) end

-- ============================================================
-- UI — New features tab (appended to Misc tab)
-- ============================================================

-- Skill Bring
local SkillBringBox = Tabs.Misc:AddLeftGroupbox("Skill Bring")
SkillBringBox:AddToggle("SkillBring", {
    Text    = "Skill Bring",
    Default = false,
    Tooltip = "Auto-tween self to target area when using specific skills",
})
SkillBringBox:AddToggle("SkillBringTPBack", {
    Text    = "TP Back After Bring",
    Default = false,
})
SkillBringBox:AddDropdown("SkillBringArea", {
    Text    = "Bring Area",
    Values  = MAP_LOCATION_NAMES,
    Default = "Death Counter",
    Multi   = false,
})
SkillBringBox:AddButton("Goto Area", function()
    local cf = MAP_LOCATIONS[Options.SkillBringArea and Options.SkillBringArea.Value or "Middle"]
    if cf and hrp then animeTp(cf) end
end)

-- Wall Combo Anywhere
local WallComboBox = Tabs.Misc:AddRightGroupbox("Wall Combo Anywhere")
WallComboBox:AddToggle("WallComboAnywhere", {
    Text    = "Wall Combo Anywhere",
    Default = false,
    Tooltip = "When Combo=5, desync to target then tp to wall area",
})
WallComboBox:AddToggle("WallComboTPBack", {
    Text    = "TP Back After Combo",
    Default = true,
})
WallComboBox:AddDropdown("WallComboArea", {
    Text    = "Wall Area",
    Values  = MAP_LOCATION_NAMES,
    Default = "Arena",
    Multi   = false,
})

-- Move Notifications (under Anti tab)
local MoveNotifBox = Tabs.Anti:AddLeftGroupbox("Move Notifications")
MoveNotifBox:AddToggle("MoveNotifications", {
    Text    = "Move Notifications",
    Default = false,
    Tooltip = "Notify when an enemy uses a specific move",
})
local _allMoveNames = {}
for _, v in pairs(MOVE_NOTIFY_IDS) do
    if not table.find(_allMoveNames, v) then table.insert(_allMoveNames, v) end
end
table.sort(_allMoveNames)
MoveNotifBox:AddDropdown("MoveNotificationMoves", {
    Text    = "Moves to track (empty=all)",
    Values  = _allMoveNames,
    Default = {},
    Multi   = true,
})

-- Invisible Moves (under Anti tab)
local InvisMovesBox = Tabs.Anti:AddRightGroupbox("Invisible Moves")
InvisMovesBox:AddToggle("InvisibleMoves_Block", {
    Text    = "Invisible Block",
    Default = false,
    Tooltip = "Remove Blocking attribute — others see no block anim",
})
InvisMovesBox:AddToggle("InvisibleMoves_Counter", {
    Text    = "Invisible Counter",
    Default = false,
    Tooltip = "Stop counter animation track — invisible counter",
})
-- Per-character invisible moves dropdowns
local INVIS_CHAR_ANIMS = {
    Saitama = {
        ["Invisible Table Flip"]             = "11365563255",
        ["Invisible Serious Punch"]           = "12983333733",
        ["Invisible Omni-Directional Punch"]  = "13927612951",
        ["Invisible Ult"]                     = "12447707844",
    },
    Garou = {
        ["Invisible Death Blow"]  = "12296113986",
        ["Invisible Last Breath"] = "10397831167",
    },
}
for charName, moves in pairs(INVIS_CHAR_ANIMS) do
    local vals = {}
    for k in pairs(moves) do table.insert(vals, k) end
    table.sort(vals)
    InvisMovesBox:AddDropdown("InvisMoves_" .. charName, {
        Text    = charName .. " Invisible Moves",
        Values  = vals,
        Default = {},
        Multi   = true,
    }):OnChanged(function()
        -- Rebuild INVIS_ANIM_IDS from all character dropdowns
        for id in pairs(INVIS_ANIM_IDS) do INVIS_ANIM_IDS[id] = nil end
        for cn, mv in pairs(INVIS_CHAR_ANIMS) do
            local opt = Options["InvisMoves_" .. cn]
            if opt and opt.Value then
                for moveName, animId in pairs(mv) do
                    if opt.Value[moveName] then
                        INVIS_ANIM_IDS[animId] = true
                    end
                end
            end
        end
    end)
end

Library:Notify('Revenant private script已載入！')



