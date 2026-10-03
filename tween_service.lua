local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

local TweenService = {}
TweenService.DefaultSpeed = 190
TweenService.IsTweening = false
TweenService.CurrentSession = 0

-- ดึง Util.BodyMover ของเกม Blox Fruits
local Util = nil
pcall(function()
    Util = require(ReplicatedStorage:WaitForChild("Util", 5))
end)

-- ฟังก์ชันหยุด Tween ปัจจุบัน (Concurrency Control)
function TweenService.stop()
    TweenService.CurrentSession = TweenService.CurrentSession + 1
    TweenService.IsTweening = false
    getgenv().isTweening = false
end

-- ฟังก์ชันตรวจสอบตัวละคร
local function getValidCharacter()
    local char = player.Character
    local hum = char and char:FindFirstChild("Humanoid")
    local hrp = char and char:FindFirstChild("HumanoidRootPart")

    if char and hum and hrp and hum.Health > 0 and hrp.Parent then
        return char, hum, hrp
    end
    return nil, nil, nil
end

-- ฟังก์ชันสร้าง BodyVelocity ตามแบบผลแสง
local function createBodyVelocity(char, hrp)
    local bvWrapper
    local nativeBv

    if Util and Util.BodyMover then
        local bm = Util.BodyMover.new(char)
        bvWrapper = bm:Create("BodyVelocity", {
            Velocity = Vector3.new()
        })
    else
        nativeBv = Instance.new("BodyVelocity")
        nativeBv.Name = "LightFlightBV"
        nativeBv.MaxForce = Vector3.new(300000, 300000, 300000)
        nativeBv.P = 15000
        nativeBv.Velocity = Vector3.new()
        nativeBv.Parent = hrp

        bvWrapper = {
            Set = function(_, vel) nativeBv.Velocity = vel end,
            Destroy = function(_) nativeBv:Destroy() end
        }
    end

    return bvWrapper
end

function TweenService.teleport(target)
    TweenService.stop()
    local targetCF = typeof(target) == "Vector3" and CFrame.new(target) or target
    local char, hum, hrp = getValidCharacter()
    if char and hum and hrp and hum.Health > 0 then
        local bv = createBodyVelocity(char, hrp)
        bv:Set(Vector3.zero)
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        hrp.Velocity = Vector3.zero

        hrp.CFrame = targetCF
        RunService.Heartbeat:Wait()

        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        hrp.Velocity = Vector3.zero
        if bv then bv:Destroy() end
    elseif char and char:FindFirstChild("HumanoidRootPart") then
        char.HumanoidRootPart.CFrame = targetCF
    end
end

-- ════════════════════════════════════════════════════════════
-- ฟังก์ชันหลัก: tweenTo(target, customSpeed)
-- target: CFrame หรือ Vector3
-- customSpeed: (ตัวเลือก) ความเร็วที่ต้องการ (ค่าเริ่มต้น 190)
-- ════════════════════════════════════════════════════════════
function TweenService.tweenTo(target, customSpeed)
    local targetCF = typeof(target) == "Vector3" and CFrame.new(target) or target
    if typeof(targetCF) ~= "CFrame" then
        -- warn("[TweenService] target ต้องเป็น CFrame หรือ Vector3!")
        return false
    end

    local char, hum, hrp = getValidCharacter()

    -- ถ้าตัวละครไม่มีอยู่ หรือตายแล้ว ให้ Cancel ทันที
    if not (char and hum and hrp and hum.Health > 0) then
        TweenService.stop()
        return false
    end

    local success, distance = pcall(function ()
        return (targetCF.Position - hrp.Position).Magnitude
    end)

    -- เงื่อนไขระยะใกล้ (< 50 studs): ถ้าตรงเงื่อนไขให้ใช้ teleport (ซึ่งมีระบบ BodyMover และล้าง Velocity ภายใน)
    if success and distance < 50 then
        TweenService.teleport(targetCF)
        return
    end

    -- ยกเลิก Tween เดิมทันที
    TweenService.stop()
    local mySession = TweenService.CurrentSession
    TweenService.IsTweening = true
    getgenv().isTweening = true

    local speed = customSpeed or TweenService.DefaultSpeed

    local startPos = hrp.Position
    local targetPos = targetCF.Position
    local totalDist = (targetPos - startPos).Magnitude

    -- ถ้าอยู่ใกล้มากแล้ว (<= 3 studs)
    if totalDist <= 3 then
        hrp.CFrame = targetCF
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        hrp.Velocity = Vector3.zero
        TweenService.IsTweening = false
        getgenv().isTweening = false
        return true
    end

    -- 2. สร้าง BodyVelocity
    local bv = createBodyVelocity(char, hrp)

    -- 3. ปรับสถานะ Humanoid (PlatformStand = true)
    hum.PlatformStand = true

    -- 4. Noclip ขณะเดินทาง
    local noclipConn = RunService.Stepped:Connect(function()
        if TweenService.IsTweening and player.Character then
            for _, p in ipairs(player.Character:GetDescendants()) do
                if p:IsA("BasePart") and p.CanCollide and p.Name ~= "_SafeLandingPad" then
                    p.CanCollide = false
                end
            end
        end
    end)

    -- 5. ตรวจจับการตายระหว่างทาง -> Cancel การ Tween ทันที
    local charDied = false
    local diedConn
    local function cleanupDied()
        charDied = true
        if diedConn then diedConn:Disconnect() end
        if noclipConn then noclipConn:Disconnect() end
        if bv then bv:Destroy() end
        if hum then
            hum.PlatformStand = false
        end
        TweenService.IsTweening = false
        getgenv().isTweening = false
    end

    diedConn = hum.Died:Connect(cleanupDied)

    local initialDelta = targetPos - startPos
    local initialDir = initialDelta.Magnitude > 0 and initialDelta.Unit or Vector3.new(0, 1, 0)

    local t0 = os.clock()
    local timeout = math.max((totalDist / speed) * 2.5, 25)

    -- 6. Direct Flight Loop (ดึงค่า dt จริงมาคำนวณ maxStep ป้องกันการพุ่งข้ามเป้าหมายเมื่อ FPS ต่ำ)
    while not charDied and (mySession == TweenService.CurrentSession) and (os.clock() - t0 < timeout) do
        local dt = RunService.Heartbeat:Wait()

        if hum.Health <= 0 then
            cleanupDied()
            return false
        end

        local curPos = hrp.Position
        local delta = targetPos - curPos
        local dist = delta.Magnitude

        -- ดึง dt จริงมาคำนวณระยะก้าวสูงสุดของเฟรมนี้: local maxStep = speed * dt
        local maxStep = speed * dt

        -- ถ้าใกล้มากแล้ว หรือระยะทางที่เหลือจะถึง/เลยเป้าหมายในเฟรมนี้ (dist <= maxStep)
        if dist <= 3.0 or dist <= maxStep then
            break
        end

        -- ตรวจสอบว่าตัวละครบินข้ามจุดหมายไปแล้วหรือไม่ (Dot Product <= 0) ป้องกันการบินย้อนไปมา
        if delta:Dot(initialDir) <= 0 then
            break
        end

        -- บินเต็มสปีด พร้อมจำกัดความเร็วสูงสุดไม่ให้เกิน dist / dt เพื่อป้องกันการพุ่งข้ามเป้าหมาย
        local dir = delta.Unit
        local safeSpeed = math.min(speed, dist / math.max(dt, 0.001))
        local flightVel = dir * safeSpeed
        bv:Set(flightVel)
    end

    -- ถ้าตัวละครตาย หรือ Session ถูกยกเลิก ให้ Cancel ทันที
    if charDied or hum.Health <= 0 then
        cleanupDied()
        return false
    end

    if mySession ~= TweenService.CurrentSession then
        if diedConn then diedConn:Disconnect() end
        if noclipConn then noclipConn:Disconnect() end
        if bv then bv:Destroy() end
        if hum then hum.PlatformStand = false end
        return false
    end

    -- 7. Authoritative Drain Phase (0.1 วินาที) ที่จุดหมาย โดยยังคง Noclip ไว้
    bv:Set(Vector3.new())
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
    hrp.Velocity = Vector3.zero

    local drainStart = os.clock()
    while (os.clock() - drainStart < 0.1) and (mySession == TweenService.CurrentSession) do
        RunService.Heartbeat:Wait()
        if hum.Health <= 0 then
            cleanupDied()
            return false
        end
        hrp.CFrame = targetCF
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
        hrp.Velocity = Vector3.zero
        bv:Set(Vector3.new())
    end

    -- คืนค่าสถานะ Humanoid
    hum.PlatformStand = false
    pcall(function()
        hum:ChangeState(Enum.HumanoidStateType.GettingUp)
    end)

    if bv then bv:Destroy() end

    -- ปิด Noclip และ Died Listener หลังจากคืนค่าสถานะเรียบร้อยแล้ว
    if noclipConn then noclipConn:Disconnect() end
    if diedConn then diedConn:Disconnect() end

    TweenService.IsTweening = false
    getgenv().isTweening = false
    return true
end

return TweenService
