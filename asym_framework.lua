--[[
  ASYM-FRAMEWORK v0.1  (Killer vs Survivor automation base)
  Target executors: Delta / Xeno   |   Load with loadstring(game:HttpGet(URL))()

  Modules (in this file, in order):
    1. Config     - all tunables + per-game "Resolvers" (hooks you override in an adapter)
    2. Telemetry  - reads the game API only (no screen reading): players, objectives, raycasts
    3. Decision   - state machine: updateDecision(role, telemetry) -> action table
    4. Actions    - executes an action: moveTo, dodge, useAbility, interact, attack
    5. Main       - loop Telemetry -> Decision -> Actions with toggle key + pcall

  This file DOES NOT auto-start. It returns the Framework table; an adapter script
  sets Config/Resolvers and then calls Framework.Start().
  Only Lua 5.1/Luau-compatible syntax is used on purpose.
]]

local Players    = game:GetService("Players")
local UIS        = game:GetService("UserInputService")
local Workspace  = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

-- Stop a previous instance if the script is executed twice
local env = (getgenv and getgenv()) or _G
if env.__ASYM_FW and env.__ASYM_FW.Stop then pcall(env.__ASYM_FW.Stop) end

-- =====================================================================
-- MODULE 1: CONFIG
-- =====================================================================
local Config = {
    Role = "Survivor",            -- "Survivor" | "Killer" | "Auto" (Auto uses Resolvers.GetRole(LocalPlayer))
    Debug = true,
    TickRate = 0.1,

    -- Keys (PC). On mobile use the on-screen button (ShowButton).
    ToggleKey = Enum.KeyCode.RightControl,
    UnloadKey = Enum.KeyCode.End,
    ShowButton = true,
    Keys = {
        Ability  = Enum.KeyCode.Q,   -- key pressed by useAbility()
        Interact = Enum.KeyCode.E,   -- key pressed by interact() when no ProximityPrompt is found
    },

    -- Distances (studs)
    FleeDistance = 45,        -- Survivor: killer closer than this -> ESCAPE
    FleeHysteresis = 10,      -- keep escaping until FleeDistance + this (avoids flicker)
    SafeDistance = 70,        -- Survivor: only REPAIR if the killer is farther than this
    FleeStep = 30,            -- base distance of flee goals (randomized 0.7x-1.5x)
    FleeCandidates = 8,       -- random safe points sampled per flee decision
    FleeGoalTTL = 3,          -- seconds before a flee goal is re-picked
    DodgeDistance = 14,       -- Survivor: killer closer than this and approaching -> dodge
    ApproachSpeed = 4,        -- studs/s toward me to count as "approaching"
    AbilityDistance = 20,     -- use ability when the enemy is within this distance
    AttackRange = 6,          -- Killer: within this -> ATTACK
    InteractDistance = 8,     -- Survivor: within this of an objective -> interact
    ObjectiveSearchRadius = 400,
    LosCheckRadius = 120,     -- only raycast for players closer than this (performance)

    -- Objective priority: name fragments, earlier = higher priority (default scanner only)
    ObjectivePriority = { "generator", "gen", "item", "key" },
    ObjectiveRefresh = 3,     -- seconds between full workspace scans (default scanner)

    -- Killer targeting: "nearest" | "lowest_health"
    KillerTargetMode = "nearest",
    PatrolReachDistance = 6,
    PatrolRadius = 60,        -- random patrol radius when there are no waypoints

    -- Cooldowns (seconds)
    AbilityCooldown = 3,
    DodgeCooldown = 0.8,
    AttackCooldown = 0.35,
    InteractCooldown = 0.4,

    -- Pathfinding (PathfindingService)
    Path = {
        AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, AgentCanClimb = false,
        WaypointSpacing = 4,
        WaypointReach = 3,      -- flat distance to count a waypoint as reached
        ReachDistance = 4,      -- distance to the final goal considered "arrived"
        RepathGoalDelta = 6,    -- recompute if the goal moved more than this (chasing)
        MinRecompute = 0.4,     -- min seconds between path computations
        RetryDelay = 1,         -- seconds before retrying after a failed path
        MaxPathAge = 6,         -- force a recompute after this many seconds
        StuckTime = 2,          -- seconds without moving -> jump + new route
        StuckDistance = 0.6,    -- studs that count as "moved"
        StuckMinGoal = 6,       -- ignore stuck check when this close to the goal
        FallbackDirect = true,  -- if no path exists, walk straight at the goal
    },

    -- Default role detection (used by the default GetRole resolver)
    RoleKeywords = {
        Killer   = { "killer", "monster", "murderer", "hunter", "seeker", "piggy" },
        Survivor = { "survivor", "runner", "innocent", "player" },
    },

    -- ===== Per-game hooks. Adapters override these. Any can stay nil. =====
    Resolvers = {
        -- (Player) -> "Killer" | "Survivor" | nil
        GetRole = nil,
        -- () -> { {instance=Instance, name=string?, priority=number?, position=Vector3?}, ... }
        GetObjectives = nil,
        -- (entry) -> true if the objective is finished / should be ignored
        IsObjectiveDone = nil,
        -- (telemetry) -> { Vector3, ... } patrol waypoints for the Killer
        GetPatrolPoints = nil,
        -- (telemetry, killerEntry) -> Vector3 custom escape point (exit, locker, ...)
        GetEscapePoint = nil,
        -- custom executors; return true if you handled it
        UseAbility = nil,   -- () -> boolean
        Attack = nil,       -- (targetEntry) -> boolean
        Interact = nil,     -- (objectiveEntry) -> boolean
    },
}

local function log(...)
    if Config.Debug then print("[ASYM]", ...) end
end

-- =====================================================================
-- MODULE 2: TELEMETRY (reads the game API; no screen reading)
-- =====================================================================
local Telemetry = {}

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
pcall(function() rayParams.RespectCanCollide = true end)

-- true if nothing solid lies between the two points
function Telemetry.rayClear(from, to, ignore)
    rayParams.FilterDescendantsInstances = ignore or {}
    return Workspace:Raycast(from, to - from, rayParams) == nil
end

-- Ground position under/near `pos`, scanning down from just above refY (nil if none)
function Telemetry.groundAt(pos, refY, ignore)
    rayParams.FilterDescendantsInstances = ignore or {}
    local r = Workspace:Raycast(Vector3.new(pos.X, refY + 6, pos.Z), Vector3.new(0, -40, 0), rayParams)
    return r and r.Position or nil
end

-- Line of sight between two characters (walls between them -> false)
function Telemetry.hasLineOfSight(fromChar, toChar)
    local a = fromChar and fromChar:FindFirstChild("HumanoidRootPart")
    local b = toChar and toChar:FindFirstChild("HumanoidRootPart")
    if not (a and b) then return false end
    return Telemetry.rayClear(a.Position, b.Position, { fromChar, toChar })
end

local function defaultGetRole(player)
    local label = ""
    if player.Team then label = player.Team.Name:lower() end
    local attr = player:GetAttribute("Role") or player:GetAttribute("Team")
    if attr then label = label .. " " .. tostring(attr):lower() end
    for _, role in ipairs({ "Killer", "Survivor" }) do
        for _, word in ipairs(Config.RoleKeywords[role]) do
            if label:find(word, 1, true) then return role end
        end
    end
    return nil
end

function Telemetry.getRole(player)
    local fn = Config.Resolvers.GetRole or defaultGetRole
    local ok, res = pcall(fn, player)
    if ok then return res end
    return nil
end

-- ---- objectives -----------------------------------------------------
local objCache = { list = {}, t = -1e9 }

local function entryPosition(entry)
    local inst = entry.instance
    if inst and inst.Parent then
        if inst:IsA("Model") then return inst:GetPivot().Position end
        if inst:IsA("BasePart") then return inst.Position end
    end
    return entry.position
end

local function defaultScan()
    local out, matched = {}, {}
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("Model") or inst:IsA("BasePart") then
            if inst.Parent and matched[inst.Parent] then
                matched[inst] = true -- child of an already matched objective
            elseif not inst:FindFirstChildOfClass("Humanoid") then
                local lname = inst.Name:lower()
                for idx, pat in ipairs(Config.ObjectivePriority) do
                    if lname:find(pat, 1, true) then
                        matched[inst] = true
                        out[#out + 1] = { instance = inst, name = inst.Name, priority = idx }
                        break
                    end
                end
            end
        end
    end
    return out
end

local function getObjectives(myPos)
    local now = os.clock()
    if now - objCache.t >= Config.ObjectiveRefresh then
        local fn = Config.Resolvers.GetObjectives or defaultScan
        local ok, res = pcall(fn)
        objCache.list = ok and res or {}
        objCache.t = now
    end
    local out = {}
    for _, e in ipairs(objCache.list) do
        local pos = entryPosition(e)
        local gone = e.instance ~= nil and e.instance.Parent == nil
        if pos and not gone then
            local done = false
            if Config.Resolvers.IsObjectiveDone then
                local ok, res = pcall(Config.Resolvers.IsObjectiveDone, e)
                done = ok and res or false
            end
            local dist = (pos - myPos).Magnitude
            if not done and dist <= Config.ObjectiveSearchRadius then
                out[#out + 1] = {
                    instance = e.instance, name = e.name or (e.instance and e.instance.Name) or "?",
                    priority = e.priority or 1, position = pos, distance = dist,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.distance < b.distance
    end)
    return out
end

function Telemetry.invalidateObjectives() objCache.t = -1e9 end

-- ---- snapshot -------------------------------------------------------
-- Returns nil while I am dead / not spawned.
function Telemetry.snapshot()
    local char = LocalPlayer.Character
    if not char then return nil end
    local root = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not (root and hum) or hum.Health <= 0 then return nil end

    local me = {
        character = char, root = root, humanoid = hum,
        position = root.Position, velocity = root.AssemblyLinearVelocity,
        health = hum.Health, maxHealth = hum.MaxHealth, walkSpeed = hum.WalkSpeed,
    }
    local snap = {
        time = os.clock(), me = me, api = Telemetry,
        players = {}, killers = {}, survivors = {}, objectives = {},
    }

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character then
            local c = p.Character
            local r = c:FindFirstChild("HumanoidRootPart")
            local h = c:FindFirstChildOfClass("Humanoid")
            if r and h and h.Health > 0 then
                local dist = (r.Position - me.position).Magnitude
                local entry = {
                    player = p, name = p.Name, character = c, role = Telemetry.getRole(p),
                    position = r.Position, velocity = r.AssemblyLinearVelocity,
                    health = h.Health, maxHealth = h.MaxHealth, distance = dist,
                    visible = nil,
                }
                if dist <= Config.LosCheckRadius then
                    entry.visible = Telemetry.rayClear(me.position, r.Position, { char, c })
                end
                snap.players[#snap.players + 1] = entry
                if entry.role == "Killer" then snap.killers[#snap.killers + 1] = entry end
                if entry.role == "Survivor" then snap.survivors[#snap.survivors + 1] = entry end
            end
        end
    end

    local byDist = function(a, b) return a.distance < b.distance end
    table.sort(snap.players, byDist)
    table.sort(snap.killers, byDist)
    table.sort(snap.survivors, byDist)
    snap.nearestKiller = snap.killers[1]
    snap.nearestSurvivor = snap.survivors[1]
    snap.objectives = getObjectives(me.position)
    return snap
end

-- =====================================================================
-- MODULE 3: DECISION (state machine)
-- Action table: { state, target?, position?, stop?, dodge?, useAbility?, interact?, attack? }
-- =====================================================================
local Decision = { memory = { state = "IDLE", since = 0, patrolTarget = nil } }

local function setState(name)
    local m = Decision.memory
    if m.state ~= name then
        m.state = name
        m.since = os.clock()
        if name ~= "ESCAPE" then m.fleeGoal = nil end
        log("state ->", name)
    end
end

-- Random safe flee GOAL (the Pathfinding module routes around walls to reach it).
-- Samples points in the half-plane away from the killer, snaps them to the ground,
-- and picks randomly among the 3 farthest from the killer.
local function pickFleePoint(t, killer)
    if Config.Resolvers.GetEscapePoint then
        local ok, p = pcall(Config.Resolvers.GetEscapePoint, t, killer)
        if ok and p then return p end
    end
    local m = Decision.memory
    local now = os.clock()
    local me, kp = t.me.position, killer.position

    -- keep the current goal while it is valid, unreachable-free and still away from the killer
    if m.fleeGoal and not t.navFailed and now - (m.fleeSince or 0) < Config.FleeGoalTTL
        and (m.fleeGoal - me).Magnitude > Config.Path.ReachDistance
        and (m.fleeGoal - kp).Magnitude > (me - kp).Magnitude then
        return m.fleeGoal
    end

    local away = Vector3.new(me.X - kp.X, 0, me.Z - kp.Z)
    if away.Magnitude < 0.1 then away = Vector3.new(1, 0, 0) end
    away = away.Unit

    local cands = {}
    for _ = 1, Config.FleeCandidates do
        local rad = math.rad(math.random(-100, 100))
        local c, s = math.cos(rad), math.sin(rad)
        local dir = Vector3.new(away.X * c - away.Z * s, 0, away.X * s + away.Z * c)
        local dist = Config.FleeStep * (0.7 + math.random() * 0.8)
        local g = t.api.groundAt(me + dir * dist, me.Y, { t.me.character })
        if g then cands[#cands + 1] = { pos = g, score = (g - kp).Magnitude + math.random() * 10 } end
    end
    table.sort(cands, function(a, b) return a.score > b.score end)

    local goal = me + away * Config.FleeStep
    if #cands > 0 then goal = cands[math.random(1, math.min(3, #cands))].pos end
    m.fleeGoal, m.fleeSince = goal, now
    return goal
end

local function decideSurvivor(t)
    local m = Decision.memory
    local k = t.nearestKiller
    local fleeD = Config.FleeDistance + (m.state == "ESCAPE" and Config.FleeHysteresis or 0)

    if k and k.distance <= fleeD then
        setState("ESCAPE")
        local approaching = false
        if k.distance > 0.01 then
            local toMe = (t.me.position - k.position).Unit
            approaching = k.velocity:Dot(toMe) > Config.ApproachSpeed
        end
        return {
            state = "ESCAPE", target = k, position = pickFleePoint(t, k),
            dodge = approaching and k.distance <= Config.DodgeDistance,
            useAbility = k.distance <= Config.AbilityDistance,
        }
    end

    local obj = t.objectives[1]
    if obj and (not k or k.distance > Config.SafeDistance) then
        setState("REPAIR")
        if obj.distance <= Config.InteractDistance then
            return { state = "REPAIR", target = obj, stop = true, interact = true }
        end
        return { state = "REPAIR", target = obj, position = obj.position }
    end

    setState("IDLE")
    return { state = "IDLE" } -- hands off: user keeps control
end

local function pickKillerTarget(t)
    if Config.KillerTargetMode == "lowest_health" then
        local best
        for _, s in ipairs(t.survivors) do
            if not best or s.health < best.health then best = s end
        end
        return best
    end
    return t.nearestSurvivor
end

local function nextPatrolPoint(t)
    local m = Decision.memory
    local me = t.me.position
    if m.patrolTarget then
        local flat = Vector3.new(m.patrolTarget.X - me.X, 0, m.patrolTarget.Z - me.Z)
        if flat.Magnitude > Config.PatrolReachDistance then return m.patrolTarget end
    end
    local pts = {}
    if Config.Resolvers.GetPatrolPoints then
        local ok, res = pcall(Config.Resolvers.GetPatrolPoints, t)
        if ok and res then pts = res end
    else
        for _, o in ipairs(t.objectives) do pts[#pts + 1] = o.position end
    end
    if #pts > 0 then
        m.patrolTarget = pts[math.random(1, #pts)]
    else
        local a = math.rad(math.random(0, 359))
        m.patrolTarget = me + Vector3.new(math.cos(a), 0, math.sin(a)) * Config.PatrolRadius
    end
    return m.patrolTarget
end

local function decideKiller(t)
    local m = Decision.memory
    local s = pickKillerTarget(t)
    if s then
        local range = Config.AttackRange + (m.state == "ATTACK" and 1 or 0)
        if s.distance <= range then
            setState("ATTACK")
            return { state = "ATTACK", target = s, position = s.position, attack = true }
        end
        setState("CHASE")
        -- light lead prediction (max 0.5 s)
        local speed = math.max(t.me.walkSpeed, 1)
        local lead = math.min(s.distance / speed, 0.5)
        return {
            state = "CHASE", target = s, position = s.position + s.velocity * lead,
            useAbility = s.distance <= Config.AbilityDistance,
        }
    end
    setState("PATROL")
    return { state = "PATROL", position = nextPatrolPoint(t) }
end

-- Public entry point
function Decision.update(role, telemetry)
    if not telemetry then return nil end
    if role == "Killer" then return decideKiller(telemetry) end
    return decideSurvivor(telemetry)
end
Decision.updateDecision = Decision.update -- alias with the requested name

-- =====================================================================
-- MODULE 4: ACTIONS
-- =====================================================================
local Actions = {}
local cooldowns = {}
local dodgeSide = 1
local PathService = game:GetService("PathfindingService")

-- ---- Pathfinding module ---------------------------------------------
-- Non-blocking: paths are computed in a background thread; moveTo() is called every
-- tick and just follows the current waypoints, repathing when needed.
local Nav = {
    waypoints = {}, idx = 1, goal = nil,
    computing = false, failed = false, invalid = false,
    lastCompute = -1e9, lastCall = 0,
    lastPos = nil, lastMoveT = 0,
    bias = 0,        -- extra agent radius: changes the route after getting stuck
    conn = nil,      -- Path.Blocked connection
}
Actions.Nav = Nav

local function navReset()
    Nav.waypoints, Nav.idx, Nav.goal = {}, 1, nil
    Nav.failed, Nav.invalid, Nav.lastPos, Nav.bias = false, false, nil, 0
    if Nav.conn then
        pcall(function() Nav.conn:Disconnect() end)
        Nav.conn = nil
    end
end
Actions.resetPath = navReset

local function flatDist(a, b)
    return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function computePath(goal, root)
    if Nav.computing then return end
    Nav.computing = true
    Nav.goal = goal
    Nav.lastCompute = os.clock()
    local bias = Nav.bias
    task.spawn(function()
        local ok, err = pcall(function()
            local c = Config.Path
            local path = PathService:CreatePath({
                AgentRadius = c.AgentRadius + bias, AgentHeight = c.AgentHeight,
                AgentCanJump = c.AgentCanJump, AgentCanClimb = c.AgentCanClimb,
                WaypointSpacing = c.WaypointSpacing,
            })
            path:ComputeAsync(root.Position, goal)
            if path.Status == Enum.PathStatus.Success then
                local wps = path:GetWaypoints()
                Nav.waypoints = wps
                Nav.idx = (#wps > 1) and 2 or 1 -- waypoint 1 is the start position
                Nav.failed, Nav.invalid = false, false
                if Nav.conn then pcall(function() Nav.conn:Disconnect() end) end
                Nav.conn = path.Blocked:Connect(function(blockedIdx)
                    if blockedIdx >= Nav.idx then Nav.invalid = true end
                end)
            else
                Nav.waypoints, Nav.failed = {}, true
            end
        end)
        if not ok then
            Nav.waypoints, Nav.failed = {}, true
            log("path error:", err)
        end
        Nav.computing = false
    end)
end

local VIM
pcall(function() VIM = game:GetService("VirtualInputManager") end)

local function ready(name, cd)
    local now = os.clock()
    if cooldowns[name] and now - cooldowns[name] < cd then return false end
    cooldowns[name] = now
    return true
end

-- Fallback for executors exposing keypress(): letters map to their uppercase ASCII VK code
local function vkFromKeyCode(kc)
    local n = kc.Name
    if #n == 1 then return string.byte(n:upper()) end
    return nil
end

-- Simulate a key press (non-blocking)
function Actions.pressKey(kc, hold)
    hold = hold or 0.05
    task.spawn(function()
        if VIM then
            local ok = pcall(function() VIM:SendKeyEvent(true, kc, false, game) end)
            if ok then
                task.wait(hold)
                pcall(function() VIM:SendKeyEvent(false, kc, false, game) end)
                return
            end
        end
        if keypress and keyrelease then
            local vk = vkFromKeyCode(kc)
            if vk then
                pcall(keypress, vk)
                task.wait(hold)
                pcall(keyrelease, vk)
            end
        end
    end)
end

-- Simulate a left click at the screen center (non-blocking)
function Actions.click()
    task.spawn(function()
        local cam = Workspace.CurrentCamera
        local c = cam and (cam.ViewportSize / 2) or Vector2.new(300, 300)
        if VIM then
            local ok = pcall(function() VIM:SendMouseButtonEvent(c.X, c.Y, 0, true, game, 0) end)
            if ok then
                task.wait(0.03)
                pcall(function() VIM:SendMouseButtonEvent(c.X, c.Y, 0, false, game, 0) end)
                return
            end
        end
        if mouse1click then pcall(mouse1click) end
    end)
end

-- Walk to `goal` along a PathfindingService route (called every tick).
function Actions.moveTo(goal, t)
    local c = Config.Path
    local hum, root, now = t.me.humanoid, t.me.root, os.clock()
    local pos = root.Position

    -- if we were not driving the character for a while, forget the old route/stuck state
    if now - Nav.lastCall > 1 then
        Nav.waypoints, Nav.idx, Nav.lastPos, Nav.bias = {}, 1, nil, 0
        Nav.goal = nil
    end
    Nav.lastCall = now

    -- stuck detection: no real movement for StuckTime -> jump + different route
    if not Nav.lastPos then
        Nav.lastPos, Nav.lastMoveT = pos, now
    elseif (pos - Nav.lastPos).Magnitude > c.StuckDistance then
        Nav.lastPos, Nav.lastMoveT = pos, now
    elseif now - Nav.lastMoveT >= c.StuckTime and (goal - pos).Magnitude > c.StuckMinGoal then
        hum.Jump = true
        Nav.bias = (Nav.bias + 1) % 4
        Nav.invalid = true
        Nav.lastMoveT = now
        log("stuck -> jump + repath (bias", Nav.bias, ")")
    end

    -- (re)compute when needed
    local needs = Nav.invalid
        or Nav.goal == nil
        or (Nav.goal - goal).Magnitude > c.RepathGoalDelta
        or (Nav.failed and (Nav.goal - goal).Magnitude > 2)
        or (#Nav.waypoints == 0 and Nav.failed and now - Nav.lastCompute > c.RetryDelay)
        or now - Nav.lastCompute > c.MaxPathAge
    if needs and now - Nav.lastCompute >= c.MinRecompute then
        computePath(goal, root)
    end

    -- follow waypoints
    local wp = Nav.waypoints[Nav.idx]
    if wp and flatDist(wp.Position, pos) < c.WaypointReach then
        if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
        Nav.idx = Nav.idx + 1
        wp = Nav.waypoints[Nav.idx]
    end
    if wp then
        hum:MoveTo(wp.Position)
        if wp.Action == Enum.PathWaypointAction.Jump and flatDist(wp.Position, pos) < 4 then
            hum.Jump = true
        end
    elseif Nav.failed and not c.FallbackDirect then
        hum:MoveTo(pos) -- no route and no fallback: stand still
    else
        hum:MoveTo(goal) -- final approach / route still computing / fallback
    end
end

function Actions.stop(t)
    navReset()
    t.me.humanoid:MoveTo(t.me.position)
end

function Actions.useAbility()
    if not ready("ability", Config.AbilityCooldown) then return end
    if Config.Resolvers.UseAbility then
        local ok, handled = pcall(Config.Resolvers.UseAbility)
        if ok and handled then return end
    end
    Actions.pressKey(Config.Keys.Ability, 0.1)
end

-- Basic auto-dodge: sidestep perpendicular to the killer's approach + jump
function Actions.dodge(killerPos, t)
    if not ready("dodge", Config.DodgeCooldown) then return end
    local me = t.me.position
    local dir = Vector3.new(me.X - killerPos.X, 0, me.Z - killerPos.Z)
    if dir.Magnitude < 0.1 then return end
    dir = dir.Unit
    dodgeSide = -dodgeSide
    local side = Vector3.new(-dir.Z, 0, dir.X) * dodgeSide
    local goal = me + side * 8
    if not t.api.rayClear(me, goal, { t.me.character }) then
        goal = me - side * 8 -- other side if blocked
    end
    t.me.humanoid:MoveTo(goal)
    t.me.humanoid.Jump = true
end

function Actions.interact(obj)
    if not ready("interact", Config.InteractCooldown) then return end
    if Config.Resolvers.Interact then
        local ok, handled = pcall(Config.Resolvers.Interact, obj)
        if ok and handled then return end
    end
    local inst = obj and obj.instance
    if inst and fireproximityprompt then
        for _, d in ipairs(inst:GetDescendants()) do
            if d:IsA("ProximityPrompt") and d.Enabled then
                pcall(fireproximityprompt, d)
                return
            end
        end
    end
    Actions.pressKey(Config.Keys.Interact, 0.15)
end

function Actions.attack(target)
    if not ready("attack", Config.AttackCooldown) then return end
    if Config.Resolvers.Attack then
        local ok, handled = pcall(Config.Resolvers.Attack, target)
        if ok and handled then return end
    end
    Actions.click()
end

-- Dispatches an action table produced by Decision
function Actions.execute(d, t)
    if not d then return end
    if d.stop then Actions.stop(t) elseif d.position then Actions.moveTo(d.position, t) end
    if d.dodge and d.target then Actions.dodge(d.target.position, t) end
    if d.useAbility then Actions.useAbility() end
    if d.interact then Actions.interact(d.target) end
    if d.attack then Actions.attack(d.target) end
end

-- =====================================================================
-- MODULE 5: MAIN
-- =====================================================================
local Framework = {
    Config = Config, Telemetry = Telemetry, Decision = Decision, Actions = Actions,
    Enabled = false, Running = false, LastDecision = nil,
}
local connections, gui, button = {}, nil, nil

local function refreshButton()
    if button then
        button.Text = Framework.Enabled and "ASYM: ON" or "ASYM: OFF"
        button.BackgroundColor3 = Framework.Enabled and Color3.fromRGB(40, 160, 70) or Color3.fromRGB(160, 50, 50)
    end
end

function Framework.SetEnabled(v)
    Framework.Enabled = v and true or false
    refreshButton()
    log("enabled =", Framework.Enabled)
end

function Framework.Toggle() Framework.SetEnabled(not Framework.Enabled) end

local function currentRole()
    if Config.Role == "Auto" then
        return Telemetry.getRole(LocalPlayer) or "Survivor"
    end
    return Config.Role
end

local function step()
    local t = Telemetry.snapshot()
    if not t then
        navReset() -- dead/respawning: drop the old route
        return
    end
    t.navFailed = Nav.failed -- lets Decision re-pick an unreachable flee goal
    local d = Decision.update(currentRole(), t)
    Framework.LastDecision = d
    Actions.execute(d, t)
end

local function buildButton()
    local ok = pcall(function()
        gui = Instance.new("ScreenGui")
        gui.Name = "ASYM_FW"
        gui.ResetOnSpawn = false
        local parent = (gethui and gethui()) or game:GetService("CoreGui")
        gui.Parent = parent
        button = Instance.new("TextButton")
        button.Size = UDim2.new(0, 110, 0, 34)
        button.Position = UDim2.new(1, -120, 0, 60)
        button.TextColor3 = Color3.new(1, 1, 1)
        button.Font = Enum.Font.GothamBold
        button.TextSize = 14
        button.Parent = gui
        button.MouseButton1Click:Connect(Framework.Toggle)
        refreshButton()
    end)
    if not ok then gui, button = nil, nil end
end

function Framework.Start()
    if Framework.Running then return end
    Framework.Running = true

    connections[#connections + 1] = UIS.InputBegan:Connect(function(input, gpe)
        if gpe then return end
        if input.KeyCode == Config.ToggleKey then Framework.Toggle() end
        if input.KeyCode == Config.UnloadKey then Framework.Stop() end
    end)
    if Config.ShowButton then buildButton() end

    task.spawn(function()
        while Framework.Running do
            if Framework.Enabled then
                local ok, err = pcall(step)
                if not ok then warn("[ASYM] step error:", err) end
            end
            task.wait(Config.TickRate)
        end
    end)
    log("started. Toggle with", Config.ToggleKey.Name, "or the on-screen button")
end

function Framework.Stop()
    Framework.Running = false
    Framework.Enabled = false
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    connections = {}
    navReset()
    if gui then pcall(function() gui:Destroy() end) gui, button = nil, nil end
    env.__ASYM_FW = nil
    log("stopped")
end

env.__ASYM_FW = Framework
return Framework
