--[[
    tween_service.lua (rewrite)

    แนวคิด: ตัวขับเคลื่อนเดียว (single driver) + state เดียว
      state = nil                 -> idle (ไม่มี connection)
      state = tween / track / boat -> กำลังเคลื่อนที่ (IsTweening = true)
      state = hold                -> ถึงเป้าแล้ว ตรึงตำแหน่ง (แทน hover)

    API
      Tween.tweenTo(target, speed?)        blocking, คืน true เมื่อถึง / false, reason
      Tween.teleport(target)               ย้ายทันที แล้ว hold
      Tween.trackTo(subject, opts?)        non-blocking, opts = {offset = Vector3, speed = number}
      Tween.stop()                         ยกเลิกทุกอย่าง กลับ idle
      Tween.noclipBoatAndCharacter(boat)
      Tween.stopBoat(boat)
      Tween.cruiseBoatForMirage(boat, direction, speed, center, targetY, shouldStop)

    target = Vector3 หรือ CFrame | subject = Model หรือ BasePart
    เรียกได้ทั้ง Tween.func(...) และ Tween:func(...)
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local env = (getgenv and getgenv()) or _G

local Tween = {}
Tween.DefaultSpeed = 190
Tween.MaxSpeed = 1000
Tween.Noclip = true  -- ปิดชนตัวละคร (และเรือตอน cruise) ระหว่างมี state
Tween.Debug = false  -- true = warn เหตุผลที่ method ปฏิเสธ
Tween.IsTweening = false -- true เฉพาะตอนเคลื่อนที่ (ไม่รวม hold)

local MAX_DT = 0.1 -- จำกัดก้าวต่อเฟรม กันพุ่งตอนแล็ก
local DEFAULT_MIRAGE_CENTER = Vector3.new(-6122.65576171875, 16.447032928466797, -2250.19921875)

-- ════════════════════════════════════════════════════════════
-- กันรันซ้ำ: ถ้าสคริปต์ถูก execute อีกรอบ ให้ปลด driver ตัวเก่าก่อน
-- ════════════════════════════════════════════════════════════
local generation = (tonumber(env.__TweenGen) or 0) + 1
env.__TweenGen = generation
if env.__TweenDriverConn then
    pcall(function() env.__TweenDriverConn:Disconnect() end)
    env.__TweenDriverConn = nil
end

-- ════════════════════════════════════════════════════════════
-- Helpers
-- ════════════════════════════════════════════════════════════
local function warnf(...)
    if Tween.Debug then warn("[Tween]", ...) end
end

local function fail(reason)
    warnf(reason)
    return false, reason
end

-- รองรับทั้ง Tween.func(...) และ Tween:func(...)
local function unpackArgs(...)
    local first = ...
    if first == Tween then
        return select(2, ...)
    end
    return ...
end

local function isFinite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function validVector(v)
    return typeof(v) == "Vector3" and isFinite(v.X) and isFinite(v.Y) and isFinite(v.Z)
end

-- คืน (position, cframe หรือ nil) | nil ถ้าไม่ถูกต้อง
local function parseTarget(target)
    if typeof(target) == "CFrame" then
        if validVector(target.Position) then
            return target.Position, target
        end
    elseif validVector(target) then
        return target, nil
    end
    return nil
end

local function parseSpeed(speed)
    if speed == nil then return Tween.DefaultSpeed end
    if isFinite(speed) and speed > 0 then
        return math.min(speed, Tween.MaxSpeed)
    end
    warnf("invalid speed, using default")
    return Tween.DefaultSpeed
end

local function getCharacter()
    local char = player.Character
    if not char then return nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if hum and hrp and hrp:IsA("BasePart") and hrp.Parent and hum.Health > 0 then
        return char, hum, hrp
    end
    return nil
end

local function zeroVelocity(hrp)
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
end

-- เปลี่ยนเฉพาะตำแหน่ง คง orientation เดิมไว้
local function setPos(hrp, pos)
    hrp.CFrame = CFrame.new(pos) * hrp.CFrame.Rotation
end

-- ขยับ "ตำแหน่งเสมือน" (mover.cur) เข้าหา goal ตามความเร็ว แล้วเขียนทับ HRP ทุกเฟรม
-- ไม่อ่านตำแหน่งจริงมาสะสมต่อ จึงไม่โดนแรงโน้มถ่วงกัดกินความสูงทีละเฟรม
-- ถ้าตัวละครถูกดึงห่างจากตำแหน่งเสมือนเกิน RESYNC_DISTANCE (เกมวาร์ป/knockback) ให้ sync จากตำแหน่งจริง
-- คืน true เมื่อถึงเป้า
local RESYNC_DISTANCE = 10

local function stepToward(mover, root, goal, speed, dt)
    local actual = root.Position
    local cur = mover.cur
    if not cur or (actual - cur).Magnitude > RESYNC_DISTANCE then
        cur = actual
    end

    local delta = goal - cur
    local dist = delta.Magnitude
    local step = speed * dt
    local arrived = dist <= step

    cur = arrived and goal or (cur + delta / dist * step)
    mover.cur = cur

    setPos(root, cur)
    zeroVelocity(root)
    return arrived
end

local function collectParts(list, root)
    if root then
        for _, p in ipairs(root:GetDescendants()) do
            if p:IsA("BasePart") and p.Name ~= "_SafeLandingPad" then
                list[#list + 1] = p
            end
        end
    end
    return list
end

-- resolve subject (Model/BasePart) -> BasePart หรือ nil
local function resolvePart(subject)
    if typeof(subject) ~= "Instance" then return nil end
    if subject:IsA("BasePart") then return subject end
    if subject:IsA("Model") then
        return subject.PrimaryPart
            or subject:FindFirstChild("HumanoidRootPart")
            or subject:FindFirstChildWhichIsA("BasePart", true)
    end
    return nil
end

-- ════════════════════════════════════════════════════════════
-- Driver
-- ════════════════════════════════════════════════════════════
local state = nil
local conn = nil
local onStep -- forward declaration

-- noclip: cache parts ของตัวละครครั้งเดียวต่อ character (Humanoid คืนค่า CanCollide เองเมื่อเราหยุด)
local cachedChar = nil
local charParts = {}

local function applyNoclip(char, extraParts)
    if cachedChar ~= char then
        cachedChar = char
        charParts = collectParts({}, char)
    end
    for i = 1, #charParts do
        charParts[i].CanCollide = false
    end
    if extraParts then
        for i = 1, #extraParts do
            extraParts[i].CanCollide = false
        end
    end
end

local function ensureDriver()
    if conn then return end
    conn = RunService.PreSimulation:Connect(function(dt)
        onStep(dt)
    end)
    env.__TweenDriverConn = conn
end

local function dropDriver()
    if conn then
        conn:Disconnect()
        conn = nil
        env.__TweenDriverConn = nil
    end
end

local function finish(st, ok, reason)
    if st.done then return end
    st.done = true
    st.ok = ok == true
    st.reason = reason
    if st.onEnd then
        local success, err = pcall(st.onEnd)
        if not success then warnf("onEnd error:", err) end
    end
end

-- เปลี่ยน state: state เก่าถูกปิด (ok/reason บอกผลของมัน) แล้วเริ่มอันใหม่
local function replaceState(newState, oldOk, oldReason)
    local old = state
    state = newState
    if old then
        finish(old, oldOk, oldReason or "cancelled")
    end

    local moving = (newState ~= nil and newState.moving == true)
    Tween.IsTweening = moving
    env.isTweening = moving

    if newState then ensureDriver() else dropDriver() end
end

local function newHold(pos, owner)
    return {
        moving = false,
        owner = owner,
        update = function(dt, char, hum, hrp)
            setPos(hrp, pos)
            zeroVelocity(hrp)
        end,
    }
end

onStep = function(dt)
    local st = state
    if not st then
        dropDriver()
        return
    end

    local char, hum, hrp = getCharacter()
    if not char or hrp ~= st.owner then
        replaceState(nil, false, "character unavailable")
        return
    end

    if Tween.Noclip then
        applyNoclip(char, st.extraParts)
    end

    local ok, status, nextState = pcall(st.update, math.min(dt, MAX_DT), char, hum, hrp)
    if not ok then
        warn("[Tween] update error:", status)
        replaceState(nil, false, "internal error")
        return
    end

    -- status: nil = ทำต่อ | true = สำเร็จ | false = ล้มเหลว (nextState = state ถัดไป หรือ nil)
    if status ~= nil then
        replaceState(nextState, status, status and nil or "lost target")
    end
end

local function waitFor(st)
    while not st.done do
        if env.__TweenGen ~= generation then
            return false, "module reloaded"
        end
        RunService.Heartbeat:Wait()
    end
    if st.ok then return true end
    return false, st.reason or "cancelled"
end

-- ════════════════════════════════════════════════════════════
-- Public: stop / teleport / tweenTo / trackTo
-- ════════════════════════════════════════════════════════════
function Tween.stop()
    replaceState(nil, false, "stopped")
end

function Tween.teleport(...)
    local target = unpackArgs(...)
    local pos, cf = parseTarget(target)
    if not pos then
        return fail("teleport: target must be a finite Vector3 or CFrame")
    end

    local char, hum, hrp = getCharacter()
    if not char then
        replaceState(nil, false, "character unavailable")
        return fail("teleport: character not ready")
    end

    hrp.CFrame = cf or (CFrame.new(pos) * hrp.CFrame.Rotation)
    zeroVelocity(hrp)
    replaceState(newHold(pos, hrp), false)
    return true
end

function Tween.tweenTo(...)
    local target, customSpeed = unpackArgs(...)
    local goal, goalCF = parseTarget(target)
    if not goal then
        return fail("tweenTo: target must be a finite Vector3 or CFrame")
    end

    local char, hum, hrp = getCharacter()
    if not char then
        replaceState(nil, false, "character unavailable")
        return fail("tweenTo: character not ready")
    end

    local speed = parseSpeed(customSpeed)

    local mover = {}
    local st = {
        moving = true,
        owner = hrp,
        update = function(dt, _, _, root)
            if stepToward(mover, root, goal, speed, dt) then
                if goalCF then root.CFrame = goalCF end
                zeroVelocity(root)
                return true, newHold(goal, root) -- ถึงแล้ว -> hold
            end
        end,
    }

    replaceState(st)
    return waitFor(st)
end

-- subject: Model/BasePart | opts: { offset = Vector3, speed = number }
-- non-blocking: ตามต่อไปเรื่อยๆ จนกว่าจะเรียก stop() / คำสั่งอื่น
-- ถ้า subject หายไป จะ hold ที่ตำแหน่งล่าสุด
function Tween.trackTo(...)
    local subject, opts = unpackArgs(...)

    if opts ~= nil and type(opts) ~= "table" then
        return fail("trackTo: opts must be a table")
    end
    opts = opts or {}

    local offset = opts.offset
    if offset == nil then
        offset = Vector3.zero
    elseif not validVector(offset) then
        return fail("trackTo: offset must be a finite Vector3")
    end

    local char, hum, hrp = getCharacter()
    if not char then
        replaceState(nil, false, "character unavailable")
        return fail("trackTo: character not ready")
    end

    local part = resolvePart(subject)
    if not part then
        return fail("trackTo: subject must be a Model/BasePart with a BasePart")
    end
    if not part:IsDescendantOf(game) then
        return fail("trackTo: subject has been destroyed")
    end
    if part:IsDescendantOf(char) then
        return fail("trackTo: subject cannot be your own character")
    end

    local speed = parseSpeed(opts.speed)

    local mover = {}
    local st = {
        moving = true,
        owner = hrp,
        update = function(dt, _, _, root)
            -- อ่านตำแหน่งจริงของ subject ใหม่ทุกเฟรม
            -- (ยอมรับ subject ที่ถูกย้ายไป container อื่น เช่น ReplicatedStorage; หลุดก็ต่อเมื่อถูก destroy)
            local target = resolvePart(subject)
            if not target or not target:IsDescendantOf(game) then
                return false, newHold(root.Position, root)
            end

            local tp = target.Position
            if not validVector(tp) then return end -- ข้ามเฟรมนี้

            stepToward(mover, root, tp + offset, speed, dt)
        end,
    }

    replaceState(st)
    return true
end

-- ════════════════════════════════════════════════════════════
-- เรือ
-- ════════════════════════════════════════════════════════════

-- ปิด CanCollide ของตัวละครและเรือ (ครั้งเดียว)
function Tween.noclipBoatAndCharacter(...)
    local boat = unpackArgs(...)
    local char = player.Character

    local parts = {}
    if char and char.Parent then collectParts(parts, char) end
    if typeof(boat) == "Instance" and boat.Parent then collectParts(parts, boat) end

    for i = 1, #parts do
        parts[i].CanCollide = false
    end
end

-- หยุดแรงขับเคลื่อนของเรือและคืนค่าฟิสิกส์เดิม
function Tween.stopBoat(...)
    local boat = unpackArgs(...)
    if typeof(boat) ~= "Instance" then return end

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
    end)
end

local function mirageSpawned()
    local mapFolder = Workspace:FindFirstChild("Map")
    if mapFolder and mapFolder:FindFirstChild("MysticIsland") then
        return true
    end

    local worldOrigin = Workspace:FindFirstChild("_WorldOrigin")
    local locations = worldOrigin and worldOrigin:FindFirstChild("Locations")
    if locations and locations:FindFirstChild("Mirage Island", true) then
        return true
    end

    return player:GetAttribute("ExactLocation") == "Mirage Island"
end

-- cruiseBoatForMirage(boat, direction, speed, center, targetY, shouldStop)
-- blocking: คืน true เมื่อจบปกติ (เจอ Mirage / shouldStop) | false, reason เมื่อถูกยกเลิก/ล้มเหลว
function Tween.cruiseBoatForMirage(...)
    local boat, direction, speed, center, targetY, shouldStop = unpackArgs(...)

    if typeof(boat) ~= "Instance" or not boat.Parent then
        return fail("cruiseBoatForMirage: boat is invalid")
    end
    local seat = boat:FindFirstChild("VehicleSeat")
    if not seat or not seat:IsA("BasePart") then
        return fail("cruiseBoatForMirage: boat has no VehicleSeat")
    end

    local char, hum, hrp = getCharacter()
    if not char then
        replaceState(nil, false, "character unavailable")
        return fail("cruiseBoatForMirage: character not ready")
    end
    if not hum.Sit then
        return fail("cruiseBoatForMirage: character is not seated")
    end
    if shouldStop ~= nil and type(shouldStop) ~= "function" then
        return fail("cruiseBoatForMirage: shouldStop must be a function")
    end

    local centerPos = DEFAULT_MIRAGE_CENTER
    if center ~= nil then
        local p = parseTarget(center)
        if not p then
            return fail("cruiseBoatForMirage: center must be a finite Vector3 or CFrame")
        end
        centerPos = p
    end

    local heightY = 150
    if targetY ~= nil then
        if not isFinite(targetY) then
            return fail("cruiseBoatForMirage: targetY must be a finite number")
        end
        heightY = targetY
    end

    local radius = 40000
    local dir = (direction == -1) and -1 or 1

    local gameMaxSpeed = (seat:IsA("VehicleSeat") and seat.MaxSpeed) or 0
    local boatSpeed = math.max(parseSpeed(speed), gameMaxSpeed)

    local initialCirclePos = Vector3.new(centerPos.X + radius, heightY, centerPos.Z)
    local startDist = Vector3.new(seat.Position.X - centerPos.X, 0, seat.Position.Z - centerPos.Z).Magnitude
    local hasReachedCircle = (startDist >= radius - 500)
    local currentAngleRad = hasReachedCircle
        and math.atan2(seat.Position.Z - centerPos.Z, seat.Position.X - centerPos.X)
        or 0

    local st = {
        moving = true,
        owner = hrp,
        extraParts = collectParts({}, boat),
        onEnd = function()
            Tween.stopBoat(boat) -- คืนฟิสิกส์เรือทุกกรณี (จบปกติ/ถูกยกเลิก/ตัวละครตาย)
        end,
        update = function(dt, _, humanoid, _)
            if not seat.Parent or not humanoid.Sit then
                return false
            end
            if shouldStop and shouldStop() then
                return true
            end
            if mirageSpawned() then
                return true
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
        end,
    }

    -- เปลี่ยน state ก่อน แล้วค่อยแก้ฟิสิกส์เรือ (กัน onEnd ของ state เก่าคืนค่าทับ)
    replaceState(st)

    if seat:IsA("VehicleSeat") and seat.MaxSpeed < boatSpeed then
        pcall(function() seat.MaxSpeed = boatSpeed end)
    end
    local defaultBV = seat:FindFirstChild("BodyVelocity")
    if defaultBV then pcall(function() defaultBV.MaxForce = Vector3.zero end) end
    local defaultBP = seat:FindFirstChild("BodyPosition")
    if defaultBP then pcall(function() defaultBP.MaxForce = Vector3.zero end) end
    local defaultBG = seat:FindFirstChild("BodyGyro")
    if defaultBG then pcall(function() defaultBG.MaxTorque = Vector3.zero end) end

    return waitFor(st)
end

return Tween
