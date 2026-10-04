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

-- ════════════════════════════════════════════════════════════
-- ฟังก์ชันสำหรับเรือ: noclipBoatAndCharacter
-- ปิด CanCollide ทุกชิ้นส่วนของเรือและตัวละคร ป้องกันการติดหินหรือสิ่งกีดขวาง
-- รองรับการเรียกใช้ทั้งแบบ Method (:) และแบบ Function (.)
-- ════════════════════════════════════════════════════════════
function TweenService.noclipBoatAndCharacter(...)
    local args = {...}
    local boat = (args[1] == TweenService) and args[2] or args[1]

    local char = player.Character
    if char and char.Parent then
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") and part.CanCollide then
                part.CanCollide = false
            end
        end
    end
    if boat and boat.Parent then
        for _, part in ipairs(boat:GetDescendants()) do
            if part:IsA("BasePart") and part.CanCollide then
                part.CanCollide = false
            end
        end
    end
end

-- ════════════════════════════════════════════════════════════
-- ฟังก์ชันสำหรับเรือ: stopBoat
-- หยุดแรงขับเคลื่อนของเรืออย่างปลอดภัย ล้าง Velocity และคืนค่าฟิสิกส์เดิม
-- รองรับการเรียกใช้ทั้งแบบ Method (:) และแบบ Function (.)
-- ════════════════════════════════════════════════════════════
function TweenService.stopBoat(...)
    local args = {...}
    local boat = (args[1] == TweenService) and args[2] or args[1]

    local seat = boat and boat:FindFirstChild("VehicleSeat")
    if seat then
        local defaultBV = seat:FindFirstChild("BodyVelocity")
        if defaultBV then
            pcall(function()
                defaultBV.MaxForce = Vector3.new(589340032, 0, 589340032)
                defaultBV.Velocity = Vector3.zero
            end)
        end
        local defaultBP = seat:FindFirstChild("BodyPosition")
        if defaultBP then
            pcall(function()
                defaultBP.MaxForce = Vector3.new(0, 589340032, 0)
            end)
        end
        local defaultBG = seat:FindFirstChild("BodyGyro")
        if defaultBG then
            pcall(function()
                defaultBG.MaxTorque = Vector3.new(589340032, 589340032, 589340032)
                defaultBG.CFrame = seat.CFrame
            end)
        end
        pcall(function()
            seat.AssemblyLinearVelocity = Vector3.zero
            seat.AssemblyAngularVelocity = Vector3.zero
            seat.Velocity = Vector3.zero
        end)
    end
end

-- ════════════════════════════════════════════════════════════
-- ฟังก์ชันสำหรับเรือ: cruiseBoatForMirage
-- ขับเคลื่อนเรือวนหาเกาะ Mirage แบบต่อเนื่องสมูท (Continuous Cruise)
-- รองรับการเรียกใช้ทั้งแบบ Method (:) และแบบ Function (.)
-- พารามิเตอร์: boat, direction, speed, center, targetY, shouldStopCallback
-- ════════════════════════════════════════════════════════════
function TweenService.cruiseBoatForMirage(...)
    local args = {...}
    local boat, direction, speed, center, targetY, shouldStop
    if args[1] == TweenService then
        boat = args[2]
        direction = args[3]
        speed = args[4]
        center = args[5]
        targetY = args[6]
        shouldStop = args[7]
    else
        boat = args[1]
        direction = args[2]
        speed = args[3]
        center = args[4]
        targetY = args[5]
        shouldStop = args[6]
    end

    local seat = boat and boat:FindFirstChild("VehicleSeat")
    local char = player.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not seat or not hum or not hum.Sit then return end

    -- Concurrency control ผ่าน Session
    TweenService.stop()
    local mySession = TweenService.CurrentSession
    TweenService.IsTweening = true
    getgenv().isTweening = true

    -- ค่าพารามิเตอร์ศูนย์กลาง, ความสูง, และความเร็ว
    local centerPos = Vector3.new(-6122.65576171875, 16.447032928466797, -2250.19921875)
    if typeof(center) == "CFrame" then
        centerPos = center.Position
    elseif typeof(center) == "Vector3" then
        centerPos = center
    end

    local heightY = targetY or 150
    local radius = 40000
    local dir = (direction == -1) and -1 or 1

    local gameMaxSpeed = (seat:IsA("VehicleSeat") and seat.MaxSpeed) or 0
    local boatSpeed = math.max(speed or TweenService.DefaultSpeed or 190, gameMaxSpeed)
    if seat:IsA("VehicleSeat") and seat.MaxSpeed < boatSpeed then
        pcall(function() seat.MaxSpeed = boatSpeed end)
    end

    -- ปิดฟิสิกส์เดิมของเกม เพื่อไม่ให้หน่วงหรือโยกเยก
    local defaultBV = seat:FindFirstChild("BodyVelocity")
    if defaultBV then pcall(function() defaultBV.MaxForce = Vector3.zero end) end
    local defaultBP = seat:FindFirstChild("BodyPosition")
    if defaultBP then pcall(function() defaultBP.MaxForce = Vector3.zero end) end
    local defaultBG = seat:FindFirstChild("BodyGyro")
    if defaultBG then pcall(function() defaultBG.MaxTorque = Vector3.zero end) end

    -- Noclip แบบต่อเนื่องทั้งตัวละครและเรือ
    local noclipConn = RunService.Stepped:Connect(function()
        TweenService.noclipBoatAndCharacter(boat)
    end)

    local initialCirclePos = Vector3.new(centerPos.X + radius, heightY, centerPos.Z)
    local startDist = Vector3.new(seat.Position.X - centerPos.X, 0, seat.Position.Z - centerPos.Z).Magnitude
    local hasReachedCircle = (startDist >= radius - 500)
    local currentAngleRad = hasReachedCircle and math.atan2(seat.Position.Z - centerPos.Z, seat.Position.X - centerPos.X) or 0

    local mapFolder = Workspace:FindFirstChild("Map")
    local locationsFolder = Workspace:FindFirstChild("_WorldOrigin") and Workspace._WorldOrigin:FindFirstChild("Locations")

    while (mySession == TweenService.CurrentSession) do
        local dt = RunService.Heartbeat:Wait()

        if not hum or hum.Health <= 0 or not hum.Sit then break end
        if shouldStop and shouldStop() then break end

        -- ตรวจสอบการเกิดของเกาะ Mirage หรือ MysticIsland
        local mysticIsland = mapFolder and mapFolder:FindFirstChild("MysticIsland")
        local hasMirageLoc = locationsFolder and locationsFolder:FindFirstChild("Mirage Island", true)
        if mysticIsland or hasMirageLoc or player:GetAttribute("ExactLocation") == "Mirage Island" then
            break
        end

        local nextPos, headingDir
        local step = boatSpeed * dt

        if not hasReachedCircle then
            -- [ช่วงที่ 1 - มุ่งหน้าสู่รัศมีวงกลม]: บินตรงไปยังจุดเริ่มต้น (angle = 0) เต็มสปีด
            local delta = initialCirclePos - seat.Position
            if delta.Magnitude <= step then
                nextPos = initialCirclePos
                hasReachedCircle = true
                currentAngleRad = 0
            else
                nextPos = seat.Position + delta.Unit * step
            end
            local horiz = Vector3.new(delta.X, 0, delta.Z)
            headingDir = (horiz.Magnitude > 0) and horiz.Unit or Vector3.new(seat.CFrame.LookVector.X, 0, seat.CFrame.LookVector.Z).Unit
        else
            -- [ช่วงที่ 2 - แล่นวนรอบวงกลม]: กวาดมุมตามความเร็วเต็มสปีดเท่ากับช่วงที่ 1
            local dAngleRad = (boatSpeed * dt / radius) * dir
            currentAngleRad = currentAngleRad + dAngleRad

            local targetX = centerPos.X + radius * math.cos(currentAngleRad)
            local targetZ = centerPos.Z + radius * math.sin(currentAngleRad)
            nextPos = Vector3.new(targetX, heightY, targetZ)

            headingDir = Vector3.new(
                -math.sin(currentAngleRad) * dir,
                0,
                math.cos(currentAngleRad) * dir
            ).Unit
        end

        -- ปรับระดับความสูงแกน Y อย่างนุ่มนวล
        local yDiff = math.abs(seat.Position.Y - heightY)
        local nextY = (yDiff < 1) and heightY or (seat.Position.Y + math.sign(heightY - seat.Position.Y) * math.min(yDiff, 150 * dt))
        nextPos = Vector3.new(nextPos.X, nextY, nextPos.Z)

        seat.CFrame = CFrame.lookAt(nextPos, nextPos + headingDir)
        seat.AssemblyLinearVelocity = headingDir * boatSpeed
        seat.AssemblyAngularVelocity = Vector3.zero
    end

    if noclipConn then noclipConn:Disconnect() end
    TweenService.stopBoat(boat)
    TweenService.IsTweening = false
    getgenv().isTweening = false
end

return TweenService
