local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local env = (getgenv and getgenv()) or _G

local TweenService = {}
TweenService.DefaultSpeed = 190
TweenService.NearDistance = 50 -- ใกล้กว่านี้ไม่บิน ใช้ teleport แทน
TweenService.IsTweening = false -- true เฉพาะตอนกำลังบิน
TweenService.CurrentSession = 0

-- ดึง Util.BodyMover ของเกม Blox Fruits
local Util = nil
pcall(function()
    Util = require(ReplicatedStorage:WaitForChild("Util", 5))
end)

-- ════════════════════════════════════════════════════════════
-- Helpers
-- ════════════════════════════════════════════════════════════

local function setTweening(state)
    TweenService.IsTweening = state
    env.isTweening = state
end

-- รองรับทั้ง Tween.func(...) และ Tween:func(...)
local function unpackArgs(...)
    local first = ...
    if first == TweenService then
        return select(2, ...)
    end
    return ...
end

local function toCFrame(target)
    if typeof(target) == "CFrame" then return target end
    if typeof(target) == "Vector3" then return CFrame.new(target) end
    return nil
end

local function getValidCharacter()
    local char = player.Character
    local hum = char and char:FindFirstChild("Humanoid")
    local hrp = char and char:FindFirstChild("HumanoidRootPart")

    if char and hum and hrp and hum.Health > 0 and hrp.Parent then
        return char, hum, hrp
    end
    return nil, nil, nil
end

local function zeroVelocity(hrp)
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
    hrp.Velocity = Vector3.zero
end

-- เก็บ BasePart ครั้งเดียว แล้วใช้ซ้ำใน Stepped (ไม่วน GetDescendants ทุกเฟรม)
local function collectParts(list, ...)
    for i = 1, select("#", ...) do
        local root = select(i, ...)
        if root then
            for _, p in ipairs(root:GetDescendants()) do
                if p:IsA("BasePart") and p.Name ~= "_SafeLandingPad" then
                    list[#list + 1] = p
                end
            end
        end
    end
    return list
end

local function connectNoclip(parts)
    return RunService.Stepped:Connect(function()
        for i = 1, #parts do
            parts[i].CanCollide = false
        end
    end)
end

-- สร้าง BodyVelocity (ใช้ Util.BodyMover ของเกมถ้ามี ไม่งั้นใช้ของ Roblox ตรงๆ)
local function createBodyVelocity(char, hrp)
    if Util and Util.BodyMover then
        local ok, wrapper = pcall(function()
            local bm = Util.BodyMover.new(char)
            return bm:Create("BodyVelocity", { Velocity = Vector3.zero })
        end)
        if ok and wrapper then
            return wrapper
        end
    end

    local nativeBv = Instance.new("BodyVelocity")
    nativeBv.Name = "LightFlightBV"
    nativeBv.MaxForce = Vector3.new(300000, 300000, 300000)
    nativeBv.P = 15000
    nativeBv.Velocity = Vector3.zero
    nativeBv.Parent = hrp

    return {
        Set = function(_, vel) nativeBv.Velocity = vel end,
        Destroy = function(_) nativeBv:Destroy() end,
    }
end

-- ════════════════════════════════════════════════════════════
-- Hover (ภายใน): BodyVelocity ความเร็วศูนย์ค้างไว้ที่ตัวละคร
-- ตั้งอัตโนมัติเมื่อ tweenTo/teleport ถึงเป้า กันฟิสิกส์ดึงตัวละครลง
-- ปลดเมื่อ: tweenTo รอบถัดไปต้องบิน, เรียก stop()/releaseHover()
-- ════════════════════════════════════════════════════════════
local hover = nil -- { bv = wrapper, hrp = HumanoidRootPart }

local function releaseHover()
    if hover then
        local bv = hover.bv
        hover = nil
        pcall(function() bv:Destroy() end)
    end
end

local function engageHover(char, hrp)
    if hover and hover.hrp == hrp and hrp.Parent then
        pcall(function() hover.bv:Set(Vector3.zero) end) -- มีอยู่แล้ว ไม่สร้างซ้ำ
        return
    end
    releaseHover() -- ตัวเก่าของตัวละครก่อนหน้า (รีสปอว์น)

    local bv = createBodyVelocity(char, hrp)
    bv:Set(Vector3.zero)
    hover = { bv = bv, hrp = hrp }
end

-- ════════════════════════════════════════════════════════════
-- Session control
-- ════════════════════════════════════════════════════════════
local flightBV = nil

-- ยกเลิกการบินที่ค้างอยู่ (ไม่แตะ hover)
local function cancelTween()
    TweenService.CurrentSession += 1
    setTweening(false)
    -- เบรกเธรดบินเก่าทันที ไม่รอให้มันตื่นมา cleanup เอง (กันลอยเลยเป้าอีก 1 เฟรม)
    if flightBV then
        local bv = flightBV
        pcall(function() bv:Set(Vector3.zero) end)
    end
end

-- หยุดทุกอย่าง: ยกเลิกการบิน + ปลด hover
function TweenService.stop()
    cancelTween()
    releaseHover()
end

function TweenService.releaseHover()
    releaseHover()
end

-- ════════════════════════════════════════════════════════════
-- teleport: วาร์ปทันที แล้ว hover ที่จุดหมาย
-- ════════════════════════════════════════════════════════════
function TweenService.teleport(...)
    local target = unpackArgs(...)
    local targetCF = toCFrame(target)
    if not targetCF then return false end

    cancelTween()

    local char, hum, hrp = getValidCharacter()
    if not char then
        releaseHover()
        return false
    end

    engageHover(char, hrp)
    hrp.CFrame = targetCF
    zeroVelocity(hrp)

    RunService.Heartbeat:Wait()
    if hrp.Parent then zeroVelocity(hrp) end
    return true
end

-- ════════════════════════════════════════════════════════════
-- tweenTo(target, customSpeed)
-- target: CFrame หรือ Vector3
-- customSpeed: (ตัวเลือก) ค่าเริ่มต้น = DefaultSpeed
-- - ใกล้กว่า NearDistance: teleport
-- - ไกล: บินด้วย BodyVelocity + noclip (block จนถึง)
-- ถึงเป้าแล้วจะ hover ค้างไว้เอง คืน true เมื่อถึง, false เมื่อไม่สำเร็จ
-- ════════════════════════════════════════════════════════════
function TweenService.tweenTo(...)
    local target, customSpeed = unpackArgs(...)
    local targetCF = toCFrame(target)
    if not targetCF then return false end

    local char, hum, hrp = getValidCharacter()
    if not char then
        TweenService.stop()
        return false
    end

    local startPos = hrp.Position
    local targetPos = targetCF.Position
    local totalDist = (targetPos - startPos).Magnitude

    if totalDist < TweenService.NearDistance then
        return TweenService.teleport(targetCF)
    end

    -- เริ่ม session ใหม่ + ปลด hover (กัน BodyVelocity สองตัวสู้กันระหว่างบิน)
    cancelTween()
    releaseHover()
    local mySession = TweenService.CurrentSession
    setTweening(true)

    local speed = customSpeed or TweenService.DefaultSpeed
    local bv = createBodyVelocity(char, hrp)
    flightBV = bv
    hum.PlatformStand = true
    local noclipConn = connectNoclip(collectParts({}, char))

    -- cleanup ปลอดภัยต่อ session: ไม่ทับสถานะของ session ใหม่ที่เข้ามาแทน
    local function cleanup()
        noclipConn:Disconnect()
        bv:Destroy()
        if flightBV == bv then flightBV = nil end

        local owns = (mySession == TweenService.CurrentSession)
        if owns then
            setTweening(false)
        end
        if hum.Parent and (owns or not TweenService.IsTweening) then
            hum.PlatformStand = false
        end
    end

    local initialDir = (targetPos - startPos).Unit -- totalDist >= NearDistance จึงไม่เป็นศูนย์
    local t0 = os.clock()
    local timeout = math.max((totalDist / speed) * 2.5, 25)

    -- Flight loop: ใช้ dt จริงจำกัดก้าวสูงสุด กันพุ่งข้ามเป้าตอน FPS ต่ำ
    -- (ถ้า timeout จะหลุดลูปแล้วตรึงที่เป้าใน drain phase เหมือนเดิม)
    while mySession == TweenService.CurrentSession and (os.clock() - t0 < timeout) do
        local dt = RunService.Heartbeat:Wait()

        if hum.Health <= 0 or not hrp.Parent then
            cleanup()
            return false
        end

        local delta = targetPos - hrp.Position
        local dist = delta.Magnitude

        -- ถึงแล้ว / ก้าวถัดไปจะถึง / บินเลยเป้าไปแล้ว
        if dist <= 3 or dist <= speed * dt or delta:Dot(initialDir) <= 0 then
            break
        end

        local safeSpeed = math.min(speed, dist / math.max(dt, 0.001))
        bv:Set(delta.Unit * safeSpeed)
    end

    if mySession ~= TweenService.CurrentSession then
        cleanup()
        return false
    end

    -- Drain phase (0.1 วินาที): ตรึงที่จุดหมายและล้าง velocity โดยยังเปิด noclip
    bv:Set(Vector3.zero)
    zeroVelocity(hrp)

    local drainStart = os.clock()
    while os.clock() - drainStart < 0.1 and mySession == TweenService.CurrentSession do
        RunService.Heartbeat:Wait()
        if hum.Health <= 0 or not hrp.Parent then
            cleanup()
            return false
        end
        hrp.CFrame = targetCF
        zeroVelocity(hrp)
        bv:Set(Vector3.zero)
    end

    -- ถูกยกเลิกระหว่าง drain -> ห้ามรายงานว่าสำเร็จ และห้าม hover ทับ session ใหม่
    if mySession ~= TweenService.CurrentSession then
        cleanup()
        return false
    end

    -- ถึงเป้าจริง: คืนสถานะ Humanoid แล้ว hover ค้างไว้ทันที (ไม่มีช่วงว่างให้ตก)
    cleanup()
    engageHover(char, hrp)
    pcall(function()
        hum:ChangeState(Enum.HumanoidStateType.GettingUp)
    end)
    return true
end

-- ════════════════════════════════════════════════════════════
-- เรือ
-- ════════════════════════════════════════════════════════════

-- ปิด CanCollide ของตัวละครและเรือ (ครั้งเดียว)
function TweenService.noclipBoatAndCharacter(...)
    local boat = unpackArgs(...)
    local char = player.Character

    local parts = collectParts({},
        (char and char.Parent) and char or nil,
        (typeof(boat) == "Instance" and boat.Parent) and boat or nil)
    for i = 1, #parts do
        parts[i].CanCollide = false
    end
end

-- หยุดแรงขับเคลื่อนของเรือและคืนค่าฟิสิกส์เดิม
function TweenService.stopBoat(...)
    local boat = unpackArgs(...)
    if not boat or typeof(boat) ~= "Instance" then return end

    local seat = boat:FindFirstChild("VehicleSeat")
    if not seat then return end

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

-- cruiseBoatForMirage(boat, direction, speed, center, targetY, shouldStop)
function TweenService.cruiseBoatForMirage(...)
    local boat, direction, speed, center, targetY, shouldStop = unpackArgs(...)
    if not boat or typeof(boat) ~= "Instance" then return end

    local seat = boat:FindFirstChild("VehicleSeat")
    local char = player.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not seat or not hum or not hum.Sit then return end

    -- stop() ปลด hover ด้วย (ตัวละครนั่งเรืออยู่ ไม่ควรมี BodyVelocity ค้าง)
    TweenService.stop()
    local mySession = TweenService.CurrentSession
    setTweening(true)

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

    -- ปิดฟิสิกส์เดิมของเกม ไม่ให้หน่วงหรือโยกเยก
    local defaultBV = seat:FindFirstChild("BodyVelocity")
    if defaultBV then pcall(function() defaultBV.MaxForce = Vector3.zero end) end
    local defaultBP = seat:FindFirstChild("BodyPosition")
    if defaultBP then pcall(function() defaultBP.MaxForce = Vector3.zero end) end
    local defaultBG = seat:FindFirstChild("BodyGyro")
    if defaultBG then pcall(function() defaultBG.MaxTorque = Vector3.zero end) end

    local noclipConn = connectNoclip(collectParts({}, char, boat))

    local initialCirclePos = Vector3.new(centerPos.X + radius, heightY, centerPos.Z)
    local startDist = Vector3.new(seat.Position.X - centerPos.X, 0, seat.Position.Z - centerPos.Z).Magnitude
    local hasReachedCircle = (startDist >= radius - 500)
    local currentAngleRad = hasReachedCircle
        and math.atan2(seat.Position.Z - centerPos.Z, seat.Position.X - centerPos.X)
        or 0

    while mySession == TweenService.CurrentSession do
        local dt = RunService.Heartbeat:Wait()

        if not hum.Parent or not seat.Parent or hum.Health <= 0 or not hum.Sit then break end
        if shouldStop and shouldStop() then break end

        -- ตรวจการเกิดของเกาะ Mirage / MysticIsland
        local mapFolder = Workspace:FindFirstChild("Map")
        local worldOrigin = Workspace:FindFirstChild("_WorldOrigin")
        local locationsFolder = worldOrigin and worldOrigin:FindFirstChild("Locations")

        local mysticIsland = mapFolder and mapFolder:FindFirstChild("MysticIsland")
        local hasMirageLoc = locationsFolder and locationsFolder:FindFirstChild("Mirage Island", true)
        if mysticIsland or hasMirageLoc or player:GetAttribute("ExactLocation") == "Mirage Island" then
            break
        end

        local nextPos, headingDir
        local step = boatSpeed * dt

        if not hasReachedCircle then
            -- ช่วงที่ 1: บินตรงไปยังจุดเริ่มวงกลม (angle = 0)
            local delta = initialCirclePos - seat.Position
            if delta.Magnitude <= step then
                nextPos = initialCirclePos
                hasReachedCircle = true
                currentAngleRad = 0
            else
                nextPos = seat.Position + delta.Unit * step
            end
            local horiz = Vector3.new(delta.X, 0, delta.Z)
            headingDir = (horiz.Magnitude > 0) and horiz.Unit
                or Vector3.new(seat.CFrame.LookVector.X, 0, seat.CFrame.LookVector.Z).Unit
        else
            -- ช่วงที่ 2: แล่นวนรอบวงกลมด้วยความเร็วเท่าเดิม
            currentAngleRad = currentAngleRad + (boatSpeed * dt / radius) * dir

            nextPos = Vector3.new(
                centerPos.X + radius * math.cos(currentAngleRad),
                heightY,
                centerPos.Z + radius * math.sin(currentAngleRad)
            )
            headingDir = Vector3.new(
                -math.sin(currentAngleRad) * dir,
                0,
                math.cos(currentAngleRad) * dir
            ).Unit
        end

        -- ปรับความสูงแกน Y อย่างนุ่มนวล
        local yDiff = math.abs(seat.Position.Y - heightY)
        local nextY = (yDiff < 1) and heightY
            or (seat.Position.Y + math.sign(heightY - seat.Position.Y) * math.min(yDiff, 150 * dt))
        nextPos = Vector3.new(nextPos.X, nextY, nextPos.Z)

        seat.CFrame = CFrame.lookAt(nextPos, nextPos + headingDir)
        seat.AssemblyLinearVelocity = headingDir * boatSpeed
        seat.AssemblyAngularVelocity = Vector3.zero
    end

    noclipConn:Disconnect()
    TweenService.stopBoat(boat)
    if mySession == TweenService.CurrentSession then
        setTweening(false)
    end
end

return TweenService
