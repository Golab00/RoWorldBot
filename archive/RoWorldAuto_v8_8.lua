--!nocheck
-- RoWorld v8.8: evaluate the whole map and select a start during the final countdown second.
-- Source reviewed: lukechatton/roworld @ 7919eeba500e473b842e2e11e3c62dee585b39c2.
-- No remote downloads. Uses the current Session, GameState and normal intent API.
-- The optional rewards probe DOES change the connected account's Stars and match stats.

local Auto = {}
Auto.Defaults = {
    DirectReader = true,
    AutoSpawn = true, AutoBuild = true, AutoBoats = true, AttackHumans = true,
    Reserve = 0.35, Ready = 0.50, ExpandRatio = 0.20, WarRatio = 0.35,
    AttackGap = 4, BuildGap = 6, BoatGap = 20, ScanGap = 2,
    MaxCityLevels = 12, ProbeCycles = 10, ProbeGap = 0.60, ProbeTimeout = 15,
    AutoDiplomacy = true, MaxAllies = 3, AllowFallout = true,
    MaxAttackShare = 0.65, AttackSafety = 1.20, MaxDefensePosts = 8,
    AutoNukes = true, AutoSAM = true, AllowHydrogen = true, WeaponGap = 9,
    NukeBudgetShare = 0.45, GoldReserve = 250000, MaxNukeSalvo = 6,
    AutoArsenal = true, EquipmentModes = {}, AutoWarships = true, MaxWarships = 8,
    WarshipGap = 8, StrikeGap = 2, MaxArtillery = 4, MaxAirfields = 2, MaxRailguns = 2,
    OwnSamples = 700, BorderSamples = 128, WeaponCandidates = 28,
    NukeShips = true, MinimumShipValue = 900000,
    MinFortNewCoverage = 0.35, MinFortOwnLand = 0.55, MinFortInland = 12, FortifyPeace = true,
    MaxPeaceDefensePosts = 4, PeaceFortsPerCivilLevel = 0.5, MinCityLevelsBeforePeaceFort = 2, PeaceFortBudgetShare = 0.25,
    ReinforcementReadyRatio = 0.65, ReinforcementUrgentPressure = 0.65, ProtectEconomicOpening = true,
    NuclearDefenseMemoryTicks = 900, MaxSAMLevels = 6, ConstructionCommandLagTicks = 15,
    AdaptiveLearning = true,
    AvoidStrongerEconomies = true,
    AutoCounterRecovery = true, CounterRecoveryTicks = 200, CounterRecoveryShare = 0.075,
    AutoCounter = true, CounterGap = 2.5, CounterReserve = 0.35, CounterEmergencyReserve = 0.20, CounterMaxShare = 0.80,
    CounterWaveShare = 0.45, CounterEmergencyWaveShare = 0.55, CounterWaveReserve = 0.35,
    CounterWaveRestTicks = 100, CounterMinPartialShare = 0.20,
    LogCapacity = 6000, LogExportEntries = 1500,
}

function Auto.parseCycles(text)
    local str = tostring(text):match("^%s*(.-)%s*$")
    if not str:match("^%d+$") then return nil end
    local n = tonumber(str)
    -- The only bound is exact integer representation in Luau's number type.
    if not n or n < 1 or n > 9007199254740991 or n ~= math.floor(n) then return nil end
    return n
end

function Auto.isProbeReply(payload)
    if type(payload) ~= "table" or payload.mode ~= "solo2" or type(payload.total) ~= "number"
        or payload.total <= 0 or type(payload.lines) ~= "table" then return false end
    local played = false
    for _, line in ipairs(payload.lines) do
        if type(line) ~= "table" then return false end
        if line[1] == "played" and line[2] == 100 then played = true
        elseif line[1] ~= "double" and line[1] ~= "general" then return false end
    end
    return played
end

function Auto.settings(overrides)
    local result = table.clone(Auto.Defaults)
    for key, value in pairs(overrides or {}) do result[key] = value end
    result.EquipmentModes = table.clone(result.EquipmentModes or {})
    return result
end

Auto.EquipmentItems = {
    {key = "mega", title = "Mega Nuke"}, {key = "scatter", title = "Scattershot"},
    {key = "reinforce", title = "Reinforcements"}, {key = "artillery", title = "Artillery"},
    {key = "airfield", title = "Air Strike"}, {key = "railgun", title = "Railgun"},
    {key = "reload2x", title = "Rapid Reload", passive = true},
    {key = "stars2x", title = "2x Stars", passive = true},
}
function Auto.newEquipment() return {loaded = false, owned = {}, blocked = {}, revision = 0} end
function Auto.applyInventory(eq, payload)
    if type(payload) ~= "table" or type(payload.unlocks) ~= "table" then return false end
    local owned = {}
    for key, value in pairs(payload.unlocks) do
        if type(key) == "number" and type(value) == "string" then owned[value] = true
        elseif type(key) == "string" and value == true then owned[key] = true end
    end
    local changed = not eq.loaded
    for _, item in ipairs(Auto.EquipmentItems) do
        if (eq.owned[item.key] == true) ~= (owned[item.key] == true) then changed = true end
        if owned[item.key] then eq.blocked[item.key] = nil end
    end
    eq.owned, eq.loaded, eq.stars = owned, true, payload.stars
    if changed then eq.revision += 1 end
    return changed
end
function Auto.canUse(s, cfg, key)
    if not cfg.AutoArsenal then return false end
    local eq, mode = s.equipment, cfg.EquipmentModes[key] or "auto"
    if mode == "off" or eq and eq.blocked[key] then return false end
    if mode == "owned" then return true end
    return eq ~= nil and eq.loaded and eq.owned[key] == true
end

-- Roblox JSON treats mixed zero/one-based numeric tables as arrays; preserve map keys explicitly.
function Auto.logValue(value, path)
    if type(value) ~= "table" then return value end
    path = path or {}
    if path[value] then return "[cycle]" end
    path[value] = true
    local out, zeroBased = {}, rawget(value, 0) ~= nil
    for key, child in pairs(value) do
        out[if zeroBased then tostring(key) else key] = Auto.logValue(child, path)
    end
    path[value] = nil
    return out
end
function Auto.newLog(capacity)
    local log = {entries = {}, sequence = 0, started = os.clock(), capacity = math.max(50, capacity or 900), dropped = 0}
    function log:add(kind, data, tick)
        self.sequence += 1
        local row = {seq = self.sequence, seconds = math.floor((os.clock() - self.started) * 1000) / 1000,
            kind = kind, tick = tick, data = Auto.logValue(data or {})}
        table.insert(self.entries, row)
        if #self.entries > self.capacity then table.remove(self.entries, 1); self.dropped += 1 end
        return row.seq
    end
    function log:export(encode, settings, limit)
        local lines = {"RoWorldBot v8.8 | log schema 1 | JSON Lines"}
        table.insert(lines, encode({schema = 1, version = "8.8", config = Auto.logValue(settings), totalEvents = self.sequence, dropped = self.dropped}))
        for i = math.max(1, #self.entries - (limit or 250) + 1), #self.entries do
            table.insert(lines, encode(self.entries[i]))
        end
        return table.concat(lines, "\n")
    end
    return log
end

local function owner(s, t) return buffer.readi32(s.owner, t * 4) end
local function clean(s, t) return bit32.band(buffer.readu8(s.flags, t), 1) == 0 end
local function distance(s, a, b)
    local dx, dy = a % s.W - b % s.W, a // s.W - b // s.W
    return dx * dx + dy * dy
end
local function friendly(s, id, other)
    if other == id then return true end
    if other <= 0 then return false end
    if s.are_allies then return s:are_allies(id, other) end
    local a, b = s.owners[id], s.owners[other]
    return (s.alliances or {})[math.min(id, other) * 1024 + math.max(id, other)] == true
        or a ~= nil and b ~= nil and (a.team or 0) > 0 and a.team == b.team
end
local function neighbors(s, t, visit)
    local x = t % s.W
    if x > 0 then visit(t - 1) end
    if x < s.W - 1 then visit(t + 1) end
    if t >= s.W then visit(t - s.W) end
    if t < s.N - s.W then visit(t + s.W) end
end

-- Chunked scan; yieldFn may cancel by returning false. No per-frame whole-map scans.
function Auto.scan(s, yieldFn, cfg)
    local me, map = s.local_owner, s.map
    cfg = cfg or Auto.Defaults
    local result = { own = {}, coast = {}, fronts = {}, falloutFronts = {}, borders = {}, foreignPorts = {}, enemyForts = {},
        ownRegions = {}, revision = s.mapRevision or 0 }
    local info = s.owners[me]
    local stride = math.max(1, math.floor((info and info.tiles or 0) / cfg.OwnSamples))
    local pointLimit = cfg.BorderSamples
    local count, coastCount = 0, 0
    local landCount = map.land_count
    for k = 0, landCount - 1 do
        if k % 20000 == 0 and yieldFn and yieldFn() == false then return nil end
        local t = buffer.readi32(map.land_list, k * 4)
        if owner(s, t) == me then
            count += 1
            local region = (t // s.W // 64) * math.ceil(s.W / 64) + (t % s.W // 64)
            result.ownRegions[region] = (result.ownRegions[region] or 0) + 1
            if count % stride == 0 and clean(s, t) then table.insert(result.own, t) end
            if buffer.readu8(map.coastal, t) == 1 then
                coastCount += 1
                table.insert(result.coast, t)
            end
            neighbors(s, t, function(n)
                if buffer.readu8(map.land, n) == 0 then return end
                local target = owner(s, n)
                local border = result.borders[target]
                if target ~= me then
                    if not border then border = {tile = n, ownTile = t, edges = 0, ownPoints = {}}; result.borders[target] = border end
                    border.edges += 1
                    if #border.ownPoints < pointLimit then table.insert(border.ownPoints, t)
                    else
                        local slot = ((border.edges * 48271) % 2147483647) % border.edges + 1
                        if slot <= pointLimit then border.ownPoints[slot] = t end
                    end
                end
                if friendly(s, me, target) then return end
                local terrain = buffer.readu8(map.terrain, n)
                local collection = if clean(s, n) then result.fronts else result.falloutFronts
                local f = collection[target]
                if not f then
                    f = { tile = n, edges = 0, terrain = terrain, points = {}, fallout = not clean(s, n) }
                    collection[target] = f
                end
                f.edges += 1
                if #f.points < pointLimit then table.insert(f.points, n)
                else local slot = ((f.edges * 48271) % 2147483647) % f.edges + 1; if slot <= pointLimit then f.points[slot] = n end end
                if terrain < f.terrain then f.tile, f.terrain = n, terrain end
            end)
        end
    end
    for _, collection in ipairs({result.fronts, result.falloutFronts}) do
        for target, f in pairs(collection) do
            local defended, best, score = 0, nil, math.huge
            for _, t in ipairs(f.points) do
                local fort = target > 0 and Auto.defenseAt(s, target, t)
                if fort then defended += 1 end
                local code = buffer.readu8(map.terrain, t)
                local value = (if code == 4 then 120 elseif code == 3 or code == 5 then 100 else 80) * (if fort then 5 else 1)
                if value < score then best, score = t, value end
            end
            f.tile = best or f.tile; f.terrain = buffer.readu8(map.terrain, f.tile)
            f.coverage = defended / math.max(#f.points, 1)
        end
    end
    for _, p in pairs(s.structures) do
        if p.kind == 3 and not friendly(s, me, p.owner) then table.insert(result.enemyForts, p) end
        if p.kind == 1 and p.owner ~= me and p.active_tick <= s.tick then
            local water = buffer.readu16(map.coast_body, p.tile * 2)
            result.foreignPorts[water] = true
        end
    end
    return result
end

function Auto.observeSpawnPhase(s, phase, ticksLeft)
    s.phase_ticks_left = ticksLeft
    s.spawnDeadline = if phase == 0 and type(ticksLeft) == "number" and ticksLeft >= 0 then s.tick + ticksLeft else nil
end
function Auto.spawnTicksLeft(s)
    if s.phase ~= 0 then return 0 end
    if s.spawnDeadline ~= nil then return math.max(0, s.spawnDeadline - s.tick) end
    return s.phase_ticks_left -- -1: solo waits for the first pick; nil: countdown not received yet
end
local function spawnOpen(s, t)
    return t >= 0 and t < s.N and buffer.readu8(s.map.land, t) == 1 and owner(s, t) == 0 and clean(s, t)
end
local function spawnBox(sum, stride, w, h, x, y, r)
    local x0, y0, x1, y1 = math.max(0, x - r), math.max(0, y - r), math.min(w, x + r + 1), math.min(h, y + r + 1)
    return buffer.readu32(sum, (y1 * stride + x1) * 4) - buffer.readu32(sum, (y0 * stride + x1) * 4)
        - buffer.readu32(sum, (y1 * stride + x0) * 4) + buffer.readu32(sum, (y0 * stride + x0) * 4)
end
-- All contestable free tiles are scored. Prefix sums, components and a distance transform
-- avoid a separate flood fill or an owners loop for each candidate. Work can yield in chunks.
function Auto.spawnSite(s, yieldFn, workspace)
    local map, w, h, n, scale = s.map, s.W, s.H, s.N, s.rules.K_LIN
    workspace = workspace or {}
    local stride, revision, startedTick = w + 1, (s.mapRevision or 0) + (s.spawnRevision or 0), s.tick
    if workspace.n ~= n or workspace.w ~= w then
        table.clear(workspace); workspace.n, workspace.w = n, w
        workspace.open, workspace.components = buffer.create(n), buffer.create(n * 4)
        workspace.queue, workspace.humanDistance = buffer.create(n * 4), buffer.create(n * 2)
        local size = (w + 1) * (h + 1) * 4
        for _, key in ipairs({"free", "easy", "coast", "occupied"}) do workspace[key] = buffer.create(size) end
    end
    local free, easy, coast, occupied = workspace.free, workspace.easy, workspace.coast, workspace.occupied
    local open, components, queue, humanDistance = workspace.open, workspace.components, workspace.queue, workspace.humanDistance
    buffer.fill(components, 0, 0)
    local function progress(stage, done, total)
        if yieldFn and yieldFn({stage = stage, done = done, total = total}) == false then return false end
        return true
    end
    local far = math.min(60000, math.max(w + h, math.ceil(180 / scale)))
    for y = 0, h - 1 do
        local rf, re, rc, ro = 0, 0, 0, 0
        for x = 0, w - 1 do
            local t, id = y * w + x, owner(s, y * w + x)
            local available = buffer.readu8(map.land, t) == 1 and id == 0 and clean(s, t)
            buffer.writeu8(open, t, if available then 1 else 0)
            if available then
                rf += 1
                if buffer.readu8(map.terrain, t) == 2 then re += 1 end
                if buffer.readu8(map.coastal, t) == 1 then rc += 1 end
            end
            if id > 0 and id ~= s.local_owner then ro += 1 end
            local source = id > 0 and id ~= s.local_owner and s.owners[id] and s.owners[id].kind == 2
            buffer.writeu16(humanDistance, t * 2, if source then 0 else far)
            local at, above = ((y + 1) * stride + x + 1) * 4, (y * stride + x + 1) * 4
            buffer.writeu32(free, at, buffer.readu32(free, above) + rf)
            buffer.writeu32(easy, at, buffer.readu32(easy, above) + re)
            buffer.writeu32(coast, at, buffer.readu32(coast, above) + rc)
            buffer.writeu32(occupied, at, buffer.readu32(occupied, above) + ro)
        end
        if y % 16 == 0 and not progress("geography", y * w, n) then return nil end
    end
    for t = 0, n - 1 do
        local d = buffer.readu16(humanDistance, t * 2)
        if t % w > 0 then d = math.min(d, buffer.readu16(humanDistance, (t - 1) * 2) + 1) end
        if t >= w then d = math.min(d, buffer.readu16(humanDistance, (t - w) * 2) + 1) end
        buffer.writeu16(humanDistance, t * 2, d)
        if t % 16384 == 0 and not progress("players_forward", t, n) then return nil end
    end
    for t = n - 1, 0, -1 do
        local d = buffer.readu16(humanDistance, t * 2)
        if t % w < w - 1 then d = math.min(d, buffer.readu16(humanDistance, (t + 1) * 2) + 1) end
        if t < n - w then d = math.min(d, buffer.readu16(humanDistance, (t + w) * 2) + 1) end
        buffer.writeu16(humanDistance, t * 2, d)
        if t % 16384 == 0 and not progress("players_backward", n - t, n) then return nil end
    end
    local sizes, visited = {}, 0
    for k = 0, map.land_count - 1 do
        if k % 16384 == 0 and not progress("expansion_index", k, map.land_count) then return nil end
        local t = buffer.readi32(map.land_list, k * 4)
        if buffer.readu8(open, t) == 0 or buffer.readu32(components, t * 4) ~= 0 then continue end
        local component, first, last = #sizes + 1, 0, 1
        buffer.writei32(queue, 0, t); buffer.writeu32(components, t * 4, component)
        local function add(cell)
            if buffer.readu8(open, cell) == 1 and buffer.readu32(components, cell * 4) == 0 then
                buffer.writeu32(components, cell * 4, component); buffer.writei32(queue, last * 4, cell); last += 1
            end
        end
        while first < last do
            local cell = buffer.readi32(queue, first * 4); first += 1; visited += 1
            if cell % w > 0 then add(cell - 1) end
            if cell % w < w - 1 then add(cell + 1) end
            if cell >= w then add(cell - w) end
            if cell < n - w then add(cell + w) end
            if visited % 8192 == 0 and not progress("expansion", visited, map.land_count) then return nil end
        end
        sizes[component] = last
    end
    local nearR, wideR, diskR = math.max(1, math.ceil(24 / scale)), math.max(1, math.ceil(70 / scale)), math.max(1, math.ceil(4 / scale))
    local regionSize, evaluated, regions = math.max(8, math.ceil(48 / scale)), 0, {}
    local columns = math.ceil(w / regionSize)
    for k = 0, map.land_count - 1 do
        local t = buffer.readi32(map.land_list, k * 4)
        if buffer.readu8(open, t) == 1 then
            evaluated += 1
            local x, y = t % w, t // w
            local localFree = spawnBox(free, stride, w, h, x, y, nearR)
            local wideFree = spawnBox(free, stride, w, h, x, y, wideR)
            local plains = spawnBox(easy, stride, w, h, x, y, nearR) / math.max(1, localFree)
            local coastal = spawnBox(coast, stride, w, h, x, y, nearR)
            local blocked = spawnBox(occupied, stride, w, h, x, y, diskR)
            local area = sizes[buffer.readu32(components, t * 4)] or 1
            local playerDistance = buffer.readu16(humanDistance, t * 2) * scale
            local score = localFree / (2 * nearR + 1)^2 * 30 + wideFree / (2 * wideR + 1)^2 * 20
                + plains * 12 + math.log(1 + area * scale^2) * 3 + math.min(playerDistance, 160) / 160 * 25
                + (if coastal > 0 then 6 else 0) - math.max(0, 35 - playerDistance) * 1.5
                - blocked / (2 * diskR + 1)^2 * 80
            local region = (y // regionSize) * columns + x // regionSize
            local old = regions[region]
            if not old or score > old.score then
                regions[region] = {tile = t, score = score, expansionTiles = area, nearbyFree = localFree,
                    plainsShare = plains, humanDistance = playerDistance, coast = coastal > 0, nearbyOccupied = blocked}
            end
        end
        if k % 4096 == 0 and not progress("scoring", k, map.land_count) then return nil end
    end
    local ranked = {}; for _, candidate in pairs(regions) do table.insert(ranked, candidate) end
    table.sort(ranked, function(a, b) return if a.score == b.score then a.tile < b.tile else a.score > b.score end)
    local result = {ranked = ranked, evaluated = evaluated, landTiles = map.land_count, tick = s.tick,
        startedTick = startedTick, revision = revision, changedDuringScan = revision ~= (s.mapRevision or 0) + (s.spawnRevision or 0)}
    return ranked[1] and ranked[1].tile, result
end
function Auto.spawnPlan(s, memory, now, budget)
    local info = s.owners[s.local_owner]
    if not info or not info.alive or info.spawned or s.phase == 2 then memory.spawnPlan = nil; return nil end
    local plan = memory.spawnPlan
    if not plan or plan.state ~= s or s.tick < (plan.lastTick or -1) then
        plan = {state = s, workspace = {}}; memory.spawnPlan = plan
    end
    plan.lastTick = s.tick
    local left = Auto.spawnTicksLeft(s)
    if not plan.job and (not plan.result or plan.result.revision ~= (s.mapRevision or 0) + (s.spawnRevision or 0) or plan.result.changedDuringScan)
        and (not plan.completedAt or now - plan.completedAt >= 0.25) then
        plan.job = coroutine.create(function()
            return Auto.spawnSite(s, function(p) plan.progress = p; coroutine.yield() end, plan.workspace)
        end)
    end
    local deadline = os.clock() + (budget or (if left and left >= 0 and left <= 20 then 0.05 else 0.012))
    while plan.job do
        local ok, tile, result = coroutine.resume(plan.job)
        if not ok then plan.job = nil; error(tile) end
        if coroutine.status(plan.job) == "dead" then
            plan.job, plan.result, plan.completedAt = nil, result, now
            break
        end
        if os.clock() >= deadline then break end
    end
    local ready = s.phase == 1 or left == -1 or left ~= nil and left <= 10
    if not ready then return nil, if left then "Start: analiza calej mapy; wybieram przy 1 s (zostalo " .. math.ceil(left / 10) .. " s)"
        else "Start: czekam na licznik serwera; analizuje cala mape" end
    if not plan.result then return nil, "Start: koncze analize calej mapy" end
    if plan.sentTick and s.tick - plan.sentTick < 3 then return nil, "Start: czekam na potwierdzenie wyboru" end
    local best, bestScore, bestDistance
    local r, scale = math.max(1, math.ceil(4 / s.rules.K_LIN)), s.rules.K_LIN
    local humans = {}
    for id, o in pairs(s.owners) do
        if id ~= s.local_owner and o.alive and o.spawned and o.kind == 2 and type(o.spawn_tile) == "number"
            and o.spawn_tile >= 0 and o.spawn_tile < s.N then table.insert(humans, o.spawn_tile) end
    end
    for _, candidate in ipairs(plan.result.ranked) do
        if spawnOpen(s, candidate.tile) then
            local x, y, occupiedNow, nearest = candidate.tile % s.W, candidate.tile // s.W, 0, candidate.humanDistance
            for ny = math.max(0, y - r), math.min(s.H - 1, y + r) do
                for nx = math.max(0, x - r), math.min(s.W - 1, x + r) do
                    local id = owner(s, ny * s.W + nx)
                    if id > 0 and id ~= s.local_owner then occupiedNow += 1 end
                end
            end
            for _, t in ipairs(humans) do nearest = math.min(nearest, math.max(0, (math.abs(x - t % s.W) + math.abs(y - t // s.W)) * scale - 8)) end
            local score = candidate.score - (occupiedNow - candidate.nearbyOccupied) / (2 * r + 1)^2 * 80
                + (math.min(nearest, 160) - math.min(candidate.humanDistance, 160)) / 160 * 25
                - (math.max(0, 35 - nearest) - math.max(0, 35 - candidate.humanDistance)) * 1.5
            if not bestScore or score > bestScore then best, bestScore, bestDistance = candidate, score, nearest end
        end
    end
    if best then
        plan.selected = best
        return {type = "spawn", tile = best.tile}, "Start: najlepsze ocenione wolne miejsce", {
            tile = best.tile, x = best.tile % s.W, y = best.tile // s.W, score = bestScore,
            evaluated = plan.result.evaluated, landTiles = plan.result.landTiles, analysisTick = plan.result.tick,
            ticksLeft = left, lateJoin = s.phase == 1, soloWaiting = left == -1,
            expansionTiles = best.expansionTiles, nearbyFree = best.nearbyFree,
            plainsShare = best.plainsShare, humanDistance = bestDistance, coast = best.coast}
    end
    plan.result = nil
    return nil, "Start: miejsca zajete, ponawiam analize"
end

-- Strategy reads structured game events; display names and message text are never code.
local function pairKey(a, b) return math.min(a, b) * 1024 + math.max(a, b) end
local function clamp(v, lo, hi) return math.clamp(v, lo, hi) end
local function onMap(s, t) return type(t) == "number" and t >= 0 and t < s.N end
local function fullArea(s, n) return n * s.rules.K_LIN ^ 2 end
local function largeBonus(tiles, depth)
    local q = (math.max(tiles, 1) / 300000)^2.5
    return 1 - depth * q / (1 + q)
end
local function terrainMag(code) return if code == 4 then 120 elseif code == 3 or code == 5 then 100 else 80 end
local function troopRate(o)
    local cap = math.max(o.max_troops or 1, 1)
    return math.max(0, (10 + math.max(o.troops or 0, 0)^0.73 / 4) * (1 - (o.troops or 0) / cap))
        * (if o.kind == 1 then 0.5 else 1)
end
function Auto.defenseAt(s, id, tile, includeBuilding)
    local r2 = (30 / s.rules.K_LIN)^2
    for _, b in pairs(s.structures) do
        if b.owner == id and b.kind == 3 and (includeBuilding or b.active_tick <= s.tick)
            and distance(s, tile, b.tile) <= r2 then return true end
    end
    return false
end
function Auto.readyMissiles(s, b, atTick)
    atTick = atTick or s.tick
    if b.active_tick > atTick then return 0 end
    local busy = 0
    local reload = if b.kind == 7 then 300 elseif b.kind == 8 then 250 else 90
    -- Rapid Reload is already encoded by the server in backdated shot timestamps.
    for _, fired in ipairs(b.shots or {}) do if fired + reload > atTick then busy += 1 end end
    return math.max(0, b.level - busy)
end
function Auto.equipmentStatus(s, eq, cfg, key)
    local result = {unlocked = eq.loaded and eq.owned[key] == true, known = eq.loaded, buildings = 0, active = 0, ready = 0}
    if not s or not s.owners[s.local_owner] then return result end
    local launcher = ({artillery = 6, airfield = 7, railgun = 8, mega = 5, scatter = 5})[key]
    for _, b in pairs(s.structures) do
        if b.owner == s.local_owner and b.kind == launcher then
            result.buildings += 1
            if b.active_tick <= s.tick then result.active += 1; if launcher ~= 6 then result.ready += Auto.readyMissiles(s, b) end end
        end
    end
    local mine = s.owners[s.local_owner]
    result.gold = mine.gold
    result.nextCost = if key == "reinforce" then 100000 elseif key == "mega" or key == "scatter" then s.rules.nuke_cost(key)
        elseif launcher then s.rules.cost_of(s, s.local_owner, key) else 0
    result.affordable = result.nextCost >= 0 and mine.gold >= result.nextCost
    if key == "reinforce" then result.cooldownTicks = s.reinforceReady and math.max(0, s.reinforceReady - s.tick) or nil end
    return result
end
function Auto.samRange(s, b, atTick)
    local level = b.level
    if b.range_ready_tick and (atTick or s.tick) < b.range_ready_tick then level = math.max(1, level - 1) end
    return (150 - 480 / (level + 5)) / s.rules.K_LIN
end
function Auto.unitPosition(s, u, tick)
    tick = tick or s.tick
    local path = u.path or {}
    if #path == 0 then return nil end
    if u.kind == 2 and (u.prev_tile or -1) >= 0 then
        local f = clamp((tick - (u.move_tick or tick)) / 10, 0, 1)
        local a, b = u.prev_tile, path[1]
        return a % s.W + (b % s.W - a % s.W) * f + 0.5,
            a // s.W + (b // s.W - a // s.W) * f + 0.5
    end
    local done = math.max(0, (tick - (u.start_tick or tick)) * 100 / math.max(u.ticks_per_tile_x100 or 100, 1))
    local i = math.min(math.floor(done) + 1, #path)
    local a, b = path[i], path[math.min(i + 1, #path)]
    local f = if i == #path then 0 else done % 1
    return a % s.W + (b % s.W - a % s.W) * f + 0.5,
        a // s.W + (b // s.W - a // s.W) * f + 0.5
end
function Auto.navy(s)
    local result = {warships = {}, transports = {}, trade = {}, ownWarships = {}, unknownWarships = 0}
    for _, u in pairs(s.units) do
        if u.kind == 3 then continue end
        local x, y = Auto.unitPosition(s, u)
        if friendly(s, s.local_owner, u.owner) then
            if u.owner == s.local_owner and u.kind == 2 and x then
                table.insert(result.ownWarships, {unit = u, x = x, y = y})
            end
        elseif u.kind == 2 then
            if x then table.insert(result.warships, {unit = u, x = x, y = y}) else result.unknownWarships += 1 end
        elseif u.kind == 0 and x then table.insert(result.transports, {unit = u, x = x, y = y})
        elseif u.kind == 1 and x then table.insert(result.trade, {unit = u, x = x, y = y}) end
    end
    return result
end
function Auto.shipHealthAt(s, u, atTick)
    local hp = if (u.hp or 0) > 0 then u.hp else 1000
    local maximum = if (u.max_hp or 0) > 0 then u.max_hp else 1000 * (1 + (u.veterancy or 0) * 0.2)
    local span = math.max(0, atTick - s.tick)
    for sample = 1, 10 do
        local x, y = Auto.unitPosition(s, u, s.tick + span * sample / 10)
        if not x then break end
        local heal, dock = 0, 0
        for _, b in pairs(s.structures) do
            if b.kind ~= 1 or b.owner ~= u.owner or b.active_tick > s.tick then continue end
            local d2 = (x - (b.tile % s.W + 0.5))^2 + (y - (b.tile // s.W + 0.5))^2
            if d2 <= (150 / s.rules.K_LIN)^2 then heal = 1 end
            if (u.state == 1 or u.state == 2) and d2 <= (5 / s.rules.K_LIN)^2 then
                local sharing = 1
                for _, other in pairs(s.units) do
                    if other.uid == u.uid or other.owner ~= u.owner or other.kind ~= 2 or other.state ~= 2 then continue end
                    local ox, oy = Auto.unitPosition(s, other)
                    if ox and (ox - (b.tile % s.W + 0.5))^2 + (oy - (b.tile // s.W + 0.5))^2 <= (5 / s.rules.K_LIN)^2 then sharing += 1 end
                end
                dock = math.max(dock, b.level * 5 / sharing)
            end
        end
        hp = math.min(maximum, hp + (heal + dock) * span / 10)
    end
    return hp
end

function Auto.newLearning(saved)
    local out = {schema = 1, frontMultiplier = 1, commandLagTicks = 15, successes = 0, failures = 0, successWindow = 0}
    if type(saved) ~= "table" or saved.schema ~= 1 then return out end
    for key, bounds in pairs({frontMultiplier = {1, 4}, commandLagTicks = {15, 40}, successes = {0, 1000000},
        failures = {0, 1000000}, successWindow = {0, 11}}) do
        local n = saved[key]
        if type(n) == "number" and n == n and math.abs(n) < math.huge then out[key] = math.clamp(n, bounds[1], bounds[2]) end
    end
    return out
end
function Auto.learningRegion(s, tile)
    return tile // s.W // 16 * math.ceil(s.W / 16) + tile % s.W // 16
end
function Auto.constructionBlocked(s, tile)
    if not s.learningProfile then return false end
    local ledger = s.combatMemory and s.combatMemory.constructionLearning
    return ledger ~= nil and (ledger.blocked[Auto.learningRegion(s, tile)] or 0) > s.tick
end
function Auto.trackConstruction(s, intent, details, seq, cfg)
    if not cfg.AdaptiveLearning or not s.learningProfile or intent.type ~= "build" or not details then return end
    local kinds = {defense = 3, sam = 4, artillery = 6, airfield = 7, railgun = 8}
    local kind = kinds[intent.kind]
    if not kind then return end
    for _, b in pairs(s.structures) do if b.tile == intent.tile then return end end -- upgrades are not new construction
    s.combatMemory = s.combatMemory or {}
    local ledger = s.combatMemory.constructionLearning or {pending = {}, blocked = {}}
    s.combatMemory.constructionLearning = ledger
    ledger.pending[seq] = {tile = intent.tile, kind = kind, submittedTick = s.tick,
        predictedArrival = details.estimatedFrontArrivalTicks, buildTicks = details.buildTicks or 80}
end
function Auto.updateLearning(s, cfg)
    local events, profile = {}, s.learningProfile
    local ledger = s.combatMemory and s.combatMemory.constructionLearning
    if not cfg.AdaptiveLearning or not profile or not ledger then return events end
    for region, untilTick in pairs(ledger.blocked) do if untilTick <= s.tick then ledger.blocked[region] = nil end end
    for seq, p in pairs(ledger.pending) do
        local structure
        for _, b in pairs(s.structures) do
            if b.owner == s.local_owner and b.kind == p.kind and b.tile == p.tile then structure = b; break end
        end
        if structure and not p.confirmedTick then
            p.confirmedTick, p.activeTick = s.tick, structure.active_tick
            local before = profile.commandLagTicks
            profile.commandLagTicks = math.max(before, math.min(40, math.ceil((s.tick - p.submittedTick) * 1.25)))
            if profile.commandLagTicks ~= before then table.insert(events, {command = seq, outcome = "command_delay", before = before, after = profile.commandLagTicks}) end
        end
        local outcome
        if p.confirmedTick and (not structure or owner(s, p.tile) ~= s.local_owner) then
            local ground = owner(s, p.tile) > 0 and not friendly(s, s.local_owner, owner(s, p.tile))
            outcome = if ground then "captured" else "destroyed_unknown"
            for _, blast in ipairs(s.explosions or {}) do
                if blast.status == "impact" and s.tick - blast.tick < 20 and distance(s, blast.tile, p.tile) <= blast.radius^2 then outcome = "weapon_loss"; break end
            end
            local before = profile.frontMultiplier
            local elapsed = math.max(1, s.tick - p.submittedTick)
            if outcome == "captured" and s.tick < p.activeTick then
                local ratio = if p.predictedArrival then p.predictedArrival / elapsed else 1.25
                profile.frontMultiplier = math.min(4, before * math.clamp(ratio, 1.1, 2))
            end
            profile.failures += 1; profile.successWindow = 0
            ledger.blocked[Auto.learningRegion(s, p.tile)] = s.tick + 600
            table.insert(events, {command = seq, outcome = outcome, before = before, after = profile.frontMultiplier,
                tile = p.tile, elapsedTicks = elapsed, predictedArrivalTicks = p.predictedArrival, unfinished = s.tick < p.activeTick})
        elseif structure and s.tick >= structure.active_tick + 100 then
            outcome = "survived_construction"
            profile.successes += 1; profile.successWindow += 1
            local before = profile.frontMultiplier
            if profile.successWindow >= 12 then profile.frontMultiplier = math.max(1, before * 0.98); profile.successWindow = 0 end
            table.insert(events, {command = seq, outcome = outcome, tile = p.tile, before = before, after = profile.frontMultiplier})
        elseif not p.confirmedTick and s.tick - p.submittedTick > 80 then
            outcome = "unconfirmed_command"
            ledger.blocked[Auto.learningRegion(s, p.tile)] = s.tick + 120
            table.insert(events, {command = seq, outcome = outcome, tile = p.tile})
        end
        if outcome then ledger.pending[seq] = nil end
    end
    return events
end

-- These ledgers last for the match, including a resync and an expired Traitor badge.
function Auto.bindHistory(s, previous)
    local same = previous and previous.map == s.map_id and previous.owner == s.local_owner
        and s.tick >= previous.lastTick and (previous.started < 0 or s.playing_since < 0 or previous.started == s.playing_since)
    local history = if same then previous else {map = s.map_id, owner = s.local_owner, started = s.playing_since,
        betrayers = {}, aggressors = {}, territory = {buckets = {}, gained = 0, lost = 0}, explosions = {}}
    history.explosions = history.explosions or {}
    if s.playing_since >= 0 then history.started = s.playing_since end
    history.lastTick = s.tick
    for id, at in pairs(s.betrayers or {}) do history.betrayers[id] = history.betrayers[id] or at end
    for id, at in pairs(s.aggressors or {}) do history.aggressors[id] = history.aggressors[id] or at end
    history.lastAggression = history.lastAggression or {}
    for id, at in pairs(s.lastAggression or {}) do history.lastAggression[id] = math.max(history.lastAggression[id] or 0, at) end
    for id, o in pairs(s.owners) do
        if (o.traitor_until or 0) > 0 then history.betrayers[id] = history.betrayers[id] or math.max(0, o.traitor_until - 300) end
    end
    if s.territory and s.territory ~= history.territory then
        for slot, row in pairs(s.territory.buckets) do
            local old = history.territory.buckets[slot]
            if not old or row.tick > old.tick then history.territory.buckets[slot] = row end
        end
    end
    s.betrayers, s.aggressors, s.territory = history.betrayers, history.aggressors, history.territory
    s.lastAggression = history.lastAggression
    history.combatMemory = history.combatMemory or s.combatMemory or {}
    s.combatMemory = history.combatMemory
    if s.explosions and s.explosions ~= history.explosions then
        for _, blast in ipairs(s.explosions) do
            local found = false
            for _, existing in ipairs(history.explosions) do if existing.uid == blast.uid and existing.tick == blast.tick then found = true; break end end
            if not found then table.insert(history.explosions, blast) end
        end
    end
    while #history.explosions > 240 do table.remove(history.explosions, 1) end
    s.explosions = history.explosions
    for _, blast in ipairs(s.explosions) do
        if blast.affectedUs and blast.status == "impact" and blast.kind < 6 and not friendly(s, s.local_owner, blast.owner) then
            s.ownNuclearHit = math.max(s.ownNuclearHit or 0, blast.tick)
        end
    end
    return history
end
function Auto.rememberAggressor(s, id)
    if id and id > 0 and not friendly(s, s.local_owner, id) then
        s.aggressors = s.aggressors or {}; s.aggressors[id] = s.aggressors[id] or s.tick
        s.lastAggression = s.lastAggression or {}; s.lastAggression[id] = s.tick
    end
end
function Auto.recordMapChange(s, tile, before, after)
    if before == after then return end
    s.mapRevision = (s.mapRevision or 0) + 1
    local ledger = s.territory
    if not ledger then ledger = {buckets = {}, gained = 0, lost = 0}; s.territory = ledger end
    local slot = s.tick % 300
    local row = ledger.buckets[slot]
    if not row or row.tick ~= s.tick then
        row = {tick = s.tick, gained = 0, lost = 0, changed = 0, attackers = {}, actors = {}, regions = {}, samples = {},
            lossPoints = {}, lossRegions = {}}
        ledger.buckets[slot] = row
    end
    row.changed += 1
    for _, change in ipairs({{before, "lost"}, {after, "gained"}}) do
        if change[1] > 0 then
            local actor = row.actors[change[1]] or {gained = 0, lost = 0}
            actor[change[2]] += 1; row.actors[change[1]] = actor
        end
    end
    local region = (tile // s.W // 64) * math.ceil(s.W / 64) + (tile % s.W // 64)
    row.regions[region] = (row.regions[region] or 0) + 1
    if #row.samples < 12 then table.insert(row.samples, {tile, before, after}) end
    if after == s.local_owner then row.gained += 1; ledger.gained += 1 end
    if before == s.local_owner then
        row.lost += 1; ledger.lost += 1; ledger.lastLossTick = s.tick
        row.attackers[after] = (row.attackers[after] or 0) + 1
        row.lossRegions[region] = (row.lossRegions[region] or 0) + 1
        if #row.lossPoints < 20 then table.insert(row.lossPoints, {tile = tile, to = after, tick = s.tick})
        else local slot = ((row.lost * 48271) % 2147483647) % row.lost + 1
            if slot <= 20 then row.lossPoints[slot] = {tile = tile, to = after, tick = s.tick} end end
        Auto.rememberAggressor(s, after)
    end
end
function Auto.mapTrend(s, ticks)
    local out = {gained = 0, lost = 0, changed = 0, attackers = {}, actors = {}, regions = {}, hotspots = {}, lossPoints = {}, lossRegions = {}}
    for _, row in pairs(s.territory and s.territory.buckets or {}) do
        if row.tick > s.tick - (ticks or 50) and row.tick <= s.tick then
            out.gained += row.gained; out.lost += row.lost; out.changed += row.changed
            for id, n in pairs(row.attackers) do out.attackers[id] = (out.attackers[id] or 0) + n end
            for id, change in pairs(row.actors or {}) do
                local actor = out.actors[id] or {gained = 0, lost = 0}
                actor.gained += change.gained; actor.lost += change.lost; out.actors[id] = actor
            end
            for id, n in pairs(row.regions or {}) do out.regions[id] = (out.regions[id] or 0) + n end
            for id, n in pairs(row.lossRegions or {}) do out.lossRegions[id] = (out.lossRegions[id] or 0) + n end
            for _, point in ipairs(row.lossPoints or {}) do table.insert(out.lossPoints, point) end
        end
    end
    out.net = out.gained - out.lost
    for id, n in pairs(out.regions) do table.insert(out.hotspots, {region = id, changes = n}) end
    table.sort(out.hotspots, function(a, b) return a.changes > b.changes end)
    while #out.hotspots > 5 do table.remove(out.hotspots) end
    return out
end

-- Coordinates and ownership come directly from the latest complete server grid.
function Auto.structuresNear(s, tile, radius)
    if not onMap(s, tile) then return {} end
    local revision = s.structureRevision or 0
    if not s.spatial or s.spatial.revision ~= revision then
        local index = {revision = revision, cells = {}, width = math.ceil(s.W / 64)}
        for _, b in pairs(s.structures) do
            local key = b.tile // s.W // 64 * index.width + b.tile % s.W // 64
            index.cells[key] = index.cells[key] or {}; table.insert(index.cells[key], b)
        end
        s.spatial = index
    end
    local result, index = {}, s.spatial
    local x, y = tile % s.W, tile // s.W
    for cy = math.max(0, math.floor((y - radius) / 64)), math.min(math.ceil(s.H / 64) - 1, math.floor((y + radius) / 64)) do
        for cx = math.max(0, math.floor((x - radius) / 64)), math.min(index.width - 1, math.floor((x + radius) / 64)) do
            for _, b in ipairs(index.cells[cy * index.width + cx] or {}) do
                if distance(s, tile, b.tile) <= radius^2 then table.insert(result, b) end
            end
        end
    end
    return result
end
local blastRadii = {[0] = 30, 100, 1500, 18, 60, 64, 1.5, 15, 5}
function Auto.blastFootprint(s, tile, radius)
    local out = {owners = {}, land = 0, water = 0, own = 0, allied = 0}
    if not onMap(s, tile) then return out end
    local x0, y0 = tile % s.W, tile // s.W
    for y = math.max(0, math.floor(y0 - radius)), math.min(s.H - 1, math.ceil(y0 + radius)) do
        for x = math.max(0, math.floor(x0 - radius)), math.min(s.W - 1, math.ceil(x0 + radius)) do
            local t = y * s.W + x
            if distance(s, tile, t) > radius^2 then continue end
            if buffer.readu8(s.map.land, t) == 0 then out.water += 1; continue end
            local id = owner(s, t)
            out.land += 1; out.owners[id] = (out.owners[id] or 0) + 1
            if id == s.local_owner then out.own += 1
            elseif friendly(s, s.local_owner, id) then out.allied += 1 end
        end
    end
    return out
end
function Auto.nukeThreatensUs(s, n)
    if not onMap(s, n.to_tile) or friendly(s, s.local_owner, n.owner) then return false end
    local radius = (blastRadii[n.kind] or 30) / s.rules.K_LIN
    local cache = n.footprintCache
    if not cache or cache.revision ~= (s.mapRevision or 0) or cache.owner ~= s.local_owner then
        cache = {revision = s.mapRevision or 0, owner = s.local_owner, footprint = Auto.blastFootprint(s, n.to_tile, radius)}
        n.footprintCache = cache
    end
    if cache.footprint.own > 0 then return true end
    for _, b in ipairs(Auto.structuresNear(s, n.to_tile, radius)) do if b.owner == s.local_owner then return true end end
    for _, u in pairs(s.units) do
        if u.owner ~= s.local_owner then continue end
        local x, y = Auto.unitPosition(s, u, (n.launch_tick or s.tick) + (n.flight_ticks or 0))
        if x and (x - (n.to_tile % s.W + 0.5))^2 + (y - (n.to_tile // s.W + 0.5))^2 <= radius^2 then return true end
    end
    return false
end
function Auto.siteBombRisk(s, tile, buildTicks)
    for _, n in pairs(s.nukes) do
        if n.kind == 2 then continue end -- the carrier's eventual warhead targets are still unknown
        if n.kind >= 6 and friendly(s, s.local_owner, n.owner) then continue end
        local eta = (n.launch_tick or s.tick) + (n.flight_ticks or 0) - s.tick
        local radius = (blastRadii[n.kind] or 30) / s.rules.K_LIN
        if eta >= 0 and eta <= buildTicks + 20 and distance(s, tile, n.to_tile) <= radius^2 then
            return {uid = n.uid, owner = n.owner, eta = eta, kind = n.kind, possibleSpread = n.kind == 5}
        end
    end
    return nil
end
function Auto.recordExplosion(s, e, frame)
    local radius, n = e[5], s.nukes[e[2]]
    local blast = {uid = e[2], kind = e[3], tile = e[4], x = e[4] % s.W, y = e[4] // s.W,
        radius = radius, owner = e[6], tick = s.tick,
        status = if radius == 0 then "intercepted" elseif radius < 0 then "split" else "impact",
        from = n and n.from_tile, intendedTarget = n and n.to_tile, changes = {}, falloutAdded = 0,
        ownLost = 0, structures = {}, units = {}, attribution = "same_tick_and_area", affectedUs = false}
    if radius > 0 then
        for _, change in ipairs(frame and frame.tiles or {}) do
            if distance(s, blast.tile, change.tile) > radius^2 then continue end
            local from, to = change.from, change.to
            blast.changes[from] = blast.changes[from] or {lost = 0, gained = 0}
            blast.changes[to] = blast.changes[to] or {lost = 0, gained = 0}
            blast.changes[from].lost += 1; blast.changes[to].gained += 1
            if from == s.local_owner then blast.ownLost += 1; blast.affectedUs = true end
        end
        for _, change in ipairs(frame and frame.flags or {}) do
            if not change.before and change.after and distance(s, blast.tile, change.tile) <= radius^2 then blast.falloutAdded += 1 end
        end
        for _, b in ipairs(frame and frame.structures or {}) do
            if distance(s, blast.tile, b.tile) <= radius^2 then
                table.insert(blast.structures, b)
                if b.owner == s.local_owner then blast.affectedUs = true end
            end
        end
        for _, u in ipairs(frame and frame.units or {}) do
            if onMap(s, u.tile) and distance(s, blast.tile, u.tile) <= radius^2 then
                table.insert(blast.units, u); if u.owner == s.local_owner then blast.affectedUs = true end
            end
        end
        local overlapping = 0
        for _, other in ipairs(frame and frame.booms or {}) do
            if other[5] > 0 and distance(s, blast.tile, other[4]) <= (radius + other[5])^2 then overlapping += 1 end
        end
        blast.overlapping = overlapping > 1
        if blast.affectedUs then
            Auto.rememberAggressor(s, blast.owner)
            if blast.kind < 6 and not friendly(s, s.local_owner, blast.owner) then s.ownNuclearHit = s.tick end
        end
    end
    s.explosions = s.explosions or {}; table.insert(s.explosions, blast)
    while #s.explosions > 240 do table.remove(s.explosions, 1) end
    s.lastExplosion = blast
    return blast
end
function Auto.describeTile(s, tile)
    if not onMap(s, tile) or tile % 1 ~= 0 then return nil end
    local id, land = owner(s, tile), buffer.readu8(s.map.land, tile) == 1
    local out = {tile = tile, x = tile % s.W, y = tile // s.W, tick = s.tick, owner = id,
        ownerName = s.owners[id] and s.owners[id].name or (if land then "Neutral" else "Water"),
        relation = if id == s.local_owner then "own" elseif friendly(s, s.local_owner, id) then "ally" elseif id > 0 then "enemy" else "neutral",
        controlledBy = s.owners[id] and (if s.owners[id].kind == 2 then "player" elseif s.owners[id].kind == 1 then "tribe" else "bot") or "none",
        land = land, terrain = buffer.readu8(s.map.terrain, tile), fallout = not clean(s, tile),
        coastal = buffer.readu8(s.map.coastal, tile) == 1, structures = {}, forts = {}, sams = {}, ships = {}, blasts = {},
        waterBody = buffer.readu16(if land then s.map.coast_body else s.map.water_body, tile * 2),
        pendingBlast = Auto.siteBombRisk(s, tile, 300)}
    for _, b in ipairs(Auto.structuresNear(s, tile, 150 / s.rules.K_LIN)) do
        local d2 = distance(s, b.tile, tile)
        local row = {sid = b.sid, tile = b.tile, x = b.tile % s.W, y = b.tile // s.W, kind = b.kind, owner = b.owner,
            level = b.level, active = b.active_tick <= s.tick, activeTick = b.active_tick, distance = math.sqrt(d2),
            protectsOwner = b.kind == 3 and b.owner == id and b.active_tick <= s.tick}
        if b.tile == tile then table.insert(out.structures, row) end
        if b.kind == 3 and d2 <= (30 / s.rules.K_LIN)^2 then table.insert(out.forts, row) end
        if b.kind == 4 and d2 <= Auto.samRange(s, b)^2 then row.ready = Auto.readyMissiles(s, b); table.insert(out.sams, row) end
    end
    for _, u in pairs(s.units) do
        if u.kind == 3 then continue end
        local x, y = Auto.unitPosition(s, u)
        if x and (x - (tile % s.W + 0.5))^2 + (y - (tile // s.W + 0.5))^2 <= (130 / s.rules.K_LIN)^2 then
            table.insert(out.ships, {uid = u.uid, kind = u.kind, owner = u.owner, x = x, y = y,
                hp = u.hp, maxHP = u.max_hp, state = u.state, position = "route_at_tick"})
        end
    end
    for _, blast in ipairs(s.explosions or {}) do
        if blast.radius > 0 and distance(s, blast.tile, tile) <= blast.radius^2 then
            table.insert(out.blasts, {uid = blast.uid, tick = blast.tick, owner = blast.owner, kind = blast.kind})
        end
    end
    return out
end
function Auto.frontSpeed(s, scan, ctx, enemy, point)
    ctx.frontSpeedCache = ctx.frontSpeedCache or {}
    local region = point // s.W // 32 * math.ceil(s.W / 32) + point % s.W // 32
    local key = enemy * (s.N + 1) + region
    if ctx.frontSpeedCache[key] then return ctx.frontSpeedCache[key] end
    local oldD, oldT, oldN, newD, newT, newN = 0, 0, 0, 0, 0, 0
    local oldDistances, newDistances = {}, {}
    for _, loss in ipairs(ctx.territory.lossPoints) do
        if loss.to ~= enemy or distance(s, point, loss.tile) > (150 / s.rules.K_LIN)^2 then continue end
        local d = math.sqrt(distance(s, point, loss.tile))
        if s.tick - loss.tick > 25 then oldD += d; oldT += loss.tick; oldN += 1; table.insert(oldDistances, d)
        else newD += d; newT += loss.tick; newN += 1; table.insert(newDistances, d) end
    end
    local measured = 0
    if oldN > 0 and newN > 0 and newT / newN > oldT / oldN then
        measured = math.max(0, (oldD / oldN - newD / newN) / (newT / newN - oldT / oldN))
        if oldN >= 5 and newN >= 5 then
            table.sort(oldDistances); table.sort(newDistances)
            -- Track the approaching edge too; distant sideways losses can hide a fast narrow breakthrough.
            local oldEdge = oldDistances[math.max(1, math.ceil(oldN * 0.2))]
            local newEdge = newDistances[math.max(1, math.ceil(newN * 0.2))]
            measured = math.max(measured, (oldEdge - newEdge) / (newT / newN - oldT / oldN))
        end
    end
    local border = (scan.borders or {})[enemy]
    local lost = ctx.territory.attackers[enemy] or 0
    local densitySpeed = lost / 50 / math.max(1, border and border.edges or 1)
    local incoming = ctx.incoming[enemy]
    local fallback = 0
    if incoming then
        local mine, foe = s.owners[s.local_owner], s.owners[enemy]
        local ratio = mine.troops / math.max(incoming.troops, 1)
        local modifiers = largeBonus(fullArea(s, foe and foe.tiles or 0), 0.73) * largeBonus(fullArea(s, mine.tiles), 0.3)
        local trait = if (mine.traitor_until or 0) > s.tick then 0.8 else 1
        -- Open plains are the fast route. Do not count on an existing fort surviving the build.
        local ruleSpeed = 8.55 / (clamp(ratio, 0.82, 7.5) * clamp(ratio / 20, 1, 50) * 16.5 * modifiers * trait * s.rules.K_LIN)
        -- The mean observed front is not an upper bound on a local breakthrough.
        fallback = ruleSpeed * 1.75
    end
    local speed = math.max(measured * 1.35, densitySpeed * 1.5, fallback) * (s.learningProfile and s.learningProfile.frontMultiplier or 1)
    ctx.frontSpeedCache[key] = speed
    return speed
end
function Auto.fortCoverage(s, tile)
    local r, total, added, land = 30 / s.rules.K_LIN, 0, 0, 0
    local existing = {}
    for _, b in ipairs(Auto.structuresNear(s, tile, r * 2)) do if b.kind == 3 and b.owner == s.local_owner then table.insert(existing, b) end end
    for y = math.max(0, math.floor(tile // s.W - r)), math.min(s.H - 1, math.ceil(tile // s.W + r)) do
        for x = math.max(0, math.floor(tile % s.W - r)), math.min(s.W - 1, math.ceil(tile % s.W + r)) do
            local t = y * s.W + x
            if distance(s, tile, t) > r^2 then continue end
            if buffer.readu8(s.map.land, t) == 1 then land += 1 end
            if owner(s, t) ~= s.local_owner then continue end
            total += 1
            local covered = false
            for _, b in ipairs(existing) do if distance(s, b.tile, t) <= r^2 then covered = true; break end end
            if not covered then added += 1 end
        end
    end
    return {added = added, total = total, share = added / math.max(total, 1), ownLandShare = total / math.max(land, 1)}
end
function Auto.hostileLandWithin(s, tile, radius)
    local x0, y0 = tile % s.W, tile // s.W
    for y = math.max(0, math.floor(y0 - radius)), math.min(s.H - 1, math.ceil(y0 + radius)) do
        for x = math.max(0, math.floor(x0 - radius)), math.min(s.W - 1, math.ceil(x0 + radius)) do
            local t = y * s.W + x
            if distance(s, tile, t) < radius^2 and buffer.readu8(s.map.land, t) == 1 then
                local id = owner(s, t)
                if id > 0 and not friendly(s, s.local_owner, id) then return true end
            end
        end
    end
    return false
end
function Auto.frontArrival(s, scan, ctx, tile)
    local safeTicks = math.huge
    for enemy, border in pairs(scan.borders or {}) do
        local foe = s.owners[enemy]
        if not foe or foe.kind == 1 or friendly(s, s.local_owner, enemy) then continue end
        local nearestPoint, nearestD
        for _, p in ipairs(border.ownPoints or {border.ownTile}) do
            local d = math.sqrt(distance(s, tile, p))
            if not nearestD or d < nearestD then nearestPoint, nearestD = p, d end
        end
        if nearestPoint then
            local speed = Auto.frontSpeed(s, scan, ctx, enemy, nearestPoint)
            if speed > 0.005 then safeTicks = math.min(safeTicks, math.max(0, nearestD - 3 / s.rules.K_LIN) / speed) end
        end
    end
    return safeTicks
end
function Auto.activeFrontPoint(s, ctx, enemy, tile)
    ctx.activeFrontCache = ctx.activeFrontCache or {}
    local key = enemy * (s.N + 1) + tile
    if ctx.activeFrontCache[key] ~= nil then return ctx.activeFrontCache[key] end
    local incoming = ctx.incoming[enemy]
    local active = incoming ~= nil and not onMap(s, incoming.anchor_tile)
    if incoming and onMap(s, incoming.anchor_tile) and distance(s, tile, incoming.anchor_tile) <= (100 / s.rules.K_LIN)^2 then active = true end
    if not active then
        for _, loss in ipairs(ctx.territory.lossPoints or {}) do
            if loss.to == enemy and distance(s, tile, loss.tile) <= (75 / s.rules.K_LIN)^2 then active = true; break end
        end
    end
    ctx.activeFrontCache[key] = active
    return active
end
function Auto.buildCandidates(s, scan, kind, ctx)
    local out, seen = {}, {}
    local function add(t)
        if onMap(s, t) and not seen[t] and owner(s, t) == s.local_owner and clean(s, t) then seen[t] = true; table.insert(out, t) end
    end
    for _, t in ipairs(scan.own) do add(t) end
    local function around(point, radii)
        add(point)
        for _, r in ipairs(radii) do
            for _, direction in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {0.707, 0.707}, {-0.707, 0.707}, {0.707, -0.707}, {-0.707, -0.707}}) do
                local x, y = math.floor(point % s.W + direction[1] * r + 0.5), math.floor(point // s.W + direction[2] * r + 0.5)
                if x >= 0 and x < s.W and y >= 0 and y < s.H then add(y * s.W + x) end
            end
        end
    end
    if kind == "defense" or kind == "artillery" then
        for enemy, border in pairs(scan.borders or {}) do
            local foe = s.owners[enemy]
            if not foe or foe.kind == 1 or friendly(s, s.local_owner, enemy) then continue end
            local points = border.ownPoints or {border.ownTile}
            for i = 1, #points, math.max(1, math.ceil(#points / 32)) do
                local point = points[i]
                local radii = {12 / s.rules.K_LIN, 18 / s.rules.K_LIN, 24 / s.rules.K_LIN}
                if ctx.defending then
                    local retreat = Auto.frontSpeed(s, scan, ctx, enemy, point) * (if kind == "defense" then 50 else 80) * 1.4 + 8 / s.rules.K_LIN
                    if retreat < 250 / s.rules.K_LIN then table.insert(radii, retreat); table.insert(radii, retreat + 12 / s.rules.K_LIN) end
                end
                around(point, radii)
            end
        end
    elseif kind == "sam" or kind == "factory" then
        for _, b in pairs(s.structures) do
            if b.owner == s.local_owner and (kind ~= "factory" or b.kind == 0 or b.kind == 1) then
                around(b.tile, {25 / s.rules.K_LIN, 45 / s.rules.K_LIN, 60 / s.rules.K_LIN})
            end
        end
    end
    return out
end
function Auto.context(s, scan, cfg)
    local me, info = s.local_owner, s.owners[s.local_owner]
    local ctx = {outgoing = {}, incoming = {}, totalIncoming = 0, wars = {}, navy = Auto.navy(s),
        hostileNeighbors = 0, strongestNeighbor = 0, nuclearThreat = false, incomingNukes = {}, reserve = 0,
        territory = Auto.mapTrend(s, 50), worldAttacks = 0}
    for _, a in pairs(s.attacks) do
        if a.attacker == me then ctx.outgoing[a.target] = a; if a.target > 0 then ctx.wars[a.target] = true end end
        if a.target == me and not a.retreating then
            ctx.incoming[a.attacker] = a; ctx.totalIncoming += a.troops; ctx.wars[a.attacker] = true
            Auto.rememberAggressor(s, a.attacker)
        end
        if not a.retreating then ctx.worldAttacks += 1 end
    end
    for enemy in pairs(scan.borders or scan.fronts) do
        local o = s.owners[enemy]
        if o and o.alive and not friendly(s, me, enemy) and o.kind ~= 1 then
            ctx.hostileNeighbors += 1
            ctx.strongestNeighbor = math.max(ctx.strongestNeighbor, o.troops)
        end
    end
    for _, n in pairs(s.nukes) do
        if Auto.nukeThreatensUs(s, n) then
            Auto.rememberAggressor(s, n.owner)
            -- Air strikes / railgun shots cannot be intercepted by a SAM.
            if n.kind < 6 then ctx.nuclearThreat = true; table.insert(ctx.incomingNukes, n) end
            ctx.wars[n.owner] = true
        end
    end
    ctx.groundLost, ctx.neutralizedLost = 0, ctx.territory.attackers[0] or 0
    for enemy, lost in pairs(ctx.territory.attackers) do
        if enemy > 0 then ctx.wars[enemy] = true; ctx.groundLost += lost end
    end
    ctx.groundLosing = ctx.groundLost >= math.max(5, info.tiles * 0.002)
    ctx.groundCritical = ctx.groundLost - ctx.territory.gained > math.max(25, info.tiles * 0.015)
    ctx.losing = ctx.territory.lost >= math.max(5, info.tiles * 0.002)
    ctx.criticalLoss = ctx.territory.net < -math.max(25, info.tiles * 0.015)
    ctx.landTimeLeft = if ctx.territory.net < 0 then info.tiles * 50 / -ctx.territory.net else math.huge
    if ctx.criticalLoss then s.defenseUntil = s.tick + 200 end
    ctx.defending = ctx.losing or ctx.totalIncoming > 0 or s.tick < (s.defenseUntil or 0)
    local reserveFraction = cfg.Reserve
    if ctx.hostileNeighbors >= 2 then reserveFraction = math.max(reserveFraction, 0.42) end
    if ctx.strongestNeighbor > info.troops * 1.4 then reserveFraction = math.max(reserveFraction, 0.48) end
    if ctx.losing then reserveFraction = math.max(reserveFraction, 0.58) end
    if ctx.criticalLoss then reserveFraction = math.max(reserveFraction, 0.70) end
    ctx.reserve = math.min(info.max_troops * 0.72,
        math.max(info.max_troops * reserveFraction, ctx.totalIncoming * 0.65))
    ctx.available = math.max(0, info.troops - ctx.reserve)
    local recovery = s.combatMemory and s.combatMemory.offensiveRecovery
    ctx.recoveringOffense = cfg.AutoCounterRecovery and recovery ~= nil and s.tick < recovery.untilTick
        and (info.troops < info.max_troops * 0.85 or s.tick - recovery.lastCounterTick < 50)
    if recovery and not ctx.recoveringOffense then s.combatMemory.offensiveRecovery = nil; recovery = nil end
    ctx.offensiveRecovery = recovery
    ctx.nuclearDefense = Auto.nuclearDefensePlan(s, scan, cfg, ctx)
    return ctx
end
function Auto.threatPriority(s, ctx, id)
    local mine, troops, bombs = s.owners[s.local_owner], 0, 0
    for _, attack in pairs(s.attacks) do
        if attack.attacker == id and attack.target == s.local_owner and not attack.retreating then troops += attack.troops end
    end
    for _, n in pairs(s.nukes) do if n.owner == id and Auto.nukeThreatensUs(s, n) then bombs += 1 end end
    local taken = ctx.territory.attackers[id] or 0
    local score = troops / math.max(mine.troops, 1) + taken / math.max(mine.tiles, 1) * 20 + bombs * 3
    if troops > 0 or taken > 0 or bombs > 0 then return 3, score end
    local last = (s.lastAggression or {})[id]
    if last and s.tick - last < 300 then return 2, score end
    if (s.aggressors or {})[id] ~= nil then return 1, score end
    return 0, 0
end

function Auto.allianceScore(s, scan, other, cfg, ctx)
    local me, mine, theirs = s.local_owner, s.owners[s.local_owner], s.owners[other]
    if not theirs or not theirs.alive or not theirs.spawned then return -100, "brak korzysci strategicznej" end
    if theirs.kind ~= 2 then return -100, "bot: sojusze tylko z graczami" end
    if (theirs.traitor_until or 0) > 0 or (s.betrayers or {})[other] ~= nil or (s.recentBetrayal or {})[other] ~= nil then
        return -100, "zdradzil panstwo w tym meczu"
    end
    if (s.aggressors or {})[other] ~= nil then return -100, "wczesniej nas zaatakowal" end
    for _, attack in pairs(s.attacks) do
        if attack.attacker == other and attack.target == me then return -100, "zaatakowal nas" end
    end
    local border = (scan.borders or scan.fronts)[other]
    local strength = theirs.troops
    for _, a in pairs(s.attacks) do if a.attacker == other then strength += a.troops * 0.7 end end
    local ratio = strength / math.max(mine.troops, 1)
    local score = if border then 2.5 else 0.5
    local reason = if border then "zabezpieczenie granicy" else "wspolny interes"
    if ratio >= 0.65 then score += 1.5; reason = "silny partner" end
    if ratio < 0.25 and theirs.tiles < mine.tiles * 0.7 then score -= 2.5 end
    local shared = false
    for _, a in pairs(s.attacks) do
        if (a.attacker == other and ctx.wars[a.target]) or (a.target == other and ctx.wars[a.attacker]) then shared = true end
    end
    if shared then
        score += 3
        reason = "wspolny przeciwnik"
    end
    if ctx.totalIncoming > 0 and border then score += 1.5; reason = "ograniczenie liczby frontow" end
    local mineAttack = ctx.outgoing[other]
    if mineAttack and theirs.troops < mineAttack.troops * 0.65 then return -20, "trwa korzystny podboj" end
    local maxTiles = s.map.contestable_count or s.map.land_count or 1
    if (theirs.tiles + mine.tiles) / maxTiles > 0.80 and theirs.tiles < mine.tiles * 0.45 then
        score -= 4; reason = "sojusz utrudnilby osiagniecie celu meczu"
    end
    if not border and not shared then score -= 1 end
    return score, reason
end
function Auto.diplomacy(s, scan, cfg, memory, ctx, now)
    if not cfg.AutoDiplomacy or now - (memory.diplomacy or -math.huge) < 1 then return nil end
    local me, allies = s.local_owner, 0
    for key in pairs(s.alliances or {}) do if key // 1024 == me or key % 1024 == me then allies += 1 end end
    memory.handledOffers, memory.proposed = memory.handledOffers or {}, memory.proposed or {}
    for key, made in pairs(s.requests or {}) do
        local from, to = key // 1024, key % 1024
        if to == me and s.tick - made <= 200 and memory.handledOffers[key] ~= made then
            local score, reason = Auto.allianceScore(s, scan, from, cfg, ctx)
            local accept = score >= 2 and allies < cfg.MaxAllies
            if allies >= cfg.MaxAllies then reason = "wystarczajaco duzo sojusznikow" end
            memory.handledOffers[key] = made
            memory.diplomacyText = (if accept then "Przyjmuje " else "Odrzuca ")
                .. (s.owners[from] and s.owners[from].name or tostring(from))
                .. (if s.owners[from] and s.owners[from].kind == 2 then " [gracz]" else " [bot]") .. ": " .. reason
            return {type = "ally_reply", target = from, accept = accept}, memory.diplomacyText, "diplomacy"
        end
    end
    for key, expires in pairs(s.alliance_expires or {}) do
        if not s.alliances[key] or expires <= s.tick or expires - s.tick > 300 then continue end
        local a, b = key // 1024, key % 1024
        if a ~= me and b ~= me then continue end
        local other = if a == me then b else a
        local mineBit = if a == me then 1 else 2
        if bit32.band((s.alliance_ext or {})[key] or 0, mineBit) ~= 0 then continue end
        local score, reason = Auto.allianceScore(s, scan, other, cfg, ctx)
        if score >= 2 and now - (memory.proposed["extend:" .. key] or -math.huge) > 12 then
            memory.proposed["extend:" .. key] = now
            memory.diplomacyText = "Odnawia sojusz: " .. reason
            return {type = "ally_extend", target = other}, memory.diplomacyText, "diplomacy"
        end
    end
    if allies >= cfg.MaxAllies or now - (memory.proposal or -math.huge) < 30 then return nil end
    local best, value, reason
    for other in pairs(scan.borders or scan.fronts) do
        if other <= 0 or friendly(s, me, other) or (s.requests or {})[me * 1024 + other] then continue end
        if now - (memory.proposed[other] or -math.huge) < 90 then continue end
        local score, why = Auto.allianceScore(s, scan, other, cfg, ctx)
        if score >= 3.5 and (not value or score > value) then best, value, reason = other, score, why end
    end
    if best then
        memory.proposed[best], memory.proposal = now, now
        memory.diplomacyText = "Proponuje " .. s.owners[best].name .. (if s.owners[best].kind == 2 then " [gracz]" else " [bot]") .. ": " .. reason
        return {type = "ally_request", target = best}, memory.diplomacyText, "diplomacy"
    end
    return nil
end

-- Estimates the minimum useful force by integrating the game's per-tile loss formula.
function Auto.attackPlan(s, front, target, cfg, ctx, goalLimit)
    local mine, foe = s.owners[s.local_owner], s.owners[target]
    local k2 = s.rules.K_LIN^2
    local mag = terrainMag(front.terrain or 2)
    local available = math.floor(math.min(ctx.available, mine.troops * cfg.MaxAttackShare))
    local minimum = math.max(1000, math.ceil(mine.troops * 0.01))
    if available < minimum then return nil end
    local fallout = if front.fallout then 5 - 2 * (s.fallout_count or 0) / math.max(s.map.contestable_count or s.map.land_count, 1) else 1
    if target == 0 then
        local desired = math.max(2000, mine.troops - mine.max_troops * 0.43)
        if front.fallout then desired = math.max(3000, desired * 0.65) end
        local amount = math.floor(math.min(available, math.max(minimum, desired)))
        return {amount = amount, losses = amount, protected = false, fallout = front.fallout == true,
            goal = amount / (mag / 5 * fallout), seconds = 0}
    end
    if not foe or not foe.alive or friendly(s, s.local_owner, target) then return nil end
    if foe.kind == 2 and (not cfg.AttackHumans or s.tick - s.playing_since < 350
        or (s.observed_shield or {})[target] and s.observed_shield[target] > s.tick) then return nil end
    local total = math.max(1, fullArea(s, foe.tiles))
    local goal = if foe.kind == 1 then total else math.min(total, math.max(100, math.min(1500, total * 0.22)))
    if goalLimit then goal = math.min(goal, goalLimit) end
    local guarded = front.coverage or (if Auto.defenseAt(s, target, front.tile) then 1 else 0)
    local defendMult = 1 + 4 * guarded
    local speedMult = 1 + 2 * guarded
    local ldb = largeBonus(total, 0.3)
    local base = 0.463 * largeBonus(fullArea(s, mine.tiles), 0.7) * ldb
    local blood = mag * defendMult * fallout * (if foe.kind == 1 then 0.7 else 1)
        * (if (foe.traitor_until or 0) > s.tick then 0.5 else 1)
    local border = math.max((front.edges or 1) * s.rules.K_LIN, 1)
    local seconds = clamp(goal * 0.82 * 20 * speedMult / (8.55 * border) / 10, 1, 35)
    local defenders = foe.troops + math.min(foe.max_troops * 0.12, troopRate(foe) * seconds * 10 * 0.55)
    local function survive(force)
        local a, d, tiles = force, defenders, total
        local steps = 48
        for _ = 1, steps do
            local step = goal / steps
            local density = d / math.max(tiles, 1)
            a -= step * blood * clamp(d / math.max(a, 1), 0.6, 2) * (base + 0.0039 * density)
            if a < math.max(500, force * 0.12) then return false end
            d = math.max(0, d - step * density); tiles = math.max(1, tiles - step)
        end
        return true
    end
    if not survive(available) then return nil end
    local lo, hi = minimum, available
    for _ = 1, 14 do local mid = (lo + hi) / 2; if survive(mid) then hi = mid else lo = mid end end
    local amount = math.min(available, math.ceil(hi * cfg.AttackSafety))
    return {amount = amount, losses = hi * 0.88, goal = goal, seconds = seconds,
        protected = guarded > 0, fallout = front.fallout == true}
end

local function pointSegmentDistance2(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local f = clamp(((px - ax) * dx + (py - ay) * dy) / math.max(dx * dx + dy * dy, 1e-9), 0, 1)
    return (px - ax - dx * f)^2 + (py - ay - dy * f)^2
end
function Auto.routeRisk(s, path, navy)
    if navy.unknownWarships > 0 then return math.huge end
    local danger, radius = 0, 145 / s.rules.K_LIN
    for _, ship in ipairs(navy.warships) do
        local best = math.huge
        local eta = #path * s.rules.K_LIN
        for _, ahead in ipairs({0, eta * 0.5, eta}) do
            local x, y = Auto.unitPosition(s, ship.unit, s.tick + ahead)
            x, y = x or ship.x, y or ship.y
            for i = 1, #path - 1 do
                local a, b = path[i], path[i + 1]
                best = math.min(best, pointSegmentDistance2(x, y, a % s.W + 0.5, a // s.W + 0.5, b % s.W + 0.5, b // s.W + 0.5))
            end
        end
        if #path == 1 then best = (ship.x - path[1] % s.W - 0.5)^2 + (ship.y - path[1] // s.W - 0.5)^2 end
        if best < radius^2 then danger += 1 + (1 - math.sqrt(best) / radius) end
    end
    return danger
end
function Auto.waterEndpoint(s, tile, body)
    -- Same preference order as SimNav.water_next_to, including diagonal water at corners.
    for _, n in ipairs({tile - 1, tile + 1, tile - s.W, tile - s.W - 1, tile - s.W + 1,
        tile + s.W, tile + s.W - 1, tile + s.W + 1}) do
        if onMap(s, n) and math.abs(n % s.W - tile % s.W) <= 1
            and buffer.readu16(s.map.water_body, n * 2) == body and buffer.readu8(s.map.terrain, n) <= 1 then return n end
    end
    return nil
end
-- Predict a shortest water route. The server chooses the final route itself.
function Auto.waterPath(s, from, to, limit)
    local body = buffer.readu16(s.map.coast_body, to * 2)
    local function water(t)
        if t < 0 then return false end
        return buffer.readu16(s.map.water_body, t * 2) == body and buffer.readu8(s.map.terrain, t) <= 1
    end
    local start, finish = Auto.waterEndpoint(s, from, body), Auto.waterEndpoint(s, to, body)
    if not start or not finish or start == finish then return nil end -- server requires at least two route points
    local heap, parent, cost = {}, {}, {[start] = 0}
    local function h(t) return math.abs(t % s.W - finish % s.W) + math.abs(t // s.W - finish // s.W) end
    local function push(t, f)
        local n = #heap + 1; heap[n] = {t, f}
        while n > 1 do local p = n // 2; if heap[p][2] <= f then break end; heap[n], heap[p] = heap[p], heap[n]; n = p end
    end
    local function pop()
        local value, last = heap[1], table.remove(heap)
        if #heap > 0 then
            heap[1] = last; local i = 1
            while i * 2 <= #heap do
                local c = i * 2; if c < #heap and heap[c + 1][2] < heap[c][2] then c += 1 end
                if heap[i][2] <= heap[c][2] then break end
                heap[i], heap[c] = heap[c], heap[i]; i = c
            end
        end
        return value[1]
    end
    push(start, h(start))
    local visited, closed = 0, {}
    while #heap > 0 and visited < (limit or 18000) do
        local t = pop()
        if closed[t] then continue end
        closed[t] = true; visited += 1
        if t == finish then
            local path = {t}
            while parent[t] do t = parent[t]; table.insert(path, t) end
            local ordered = {}; for i = #path, 1, -1 do table.insert(ordered, path[i]) end
            return ordered
        end
        neighbors(s, t, function(n)
            local value = cost[t] + 1
            if water(n) and (not cost[n] or value < cost[n]) then cost[n], parent[n] = value, t; push(n, value + h(n)) end
        end)
    end
    return nil
end
function Auto.landing(s, scan, cfg, memory, ctx)
    if ctx.recoveringOffense or #scan.coast == 0 or ctx.navy.unknownWarships > 0 then return nil end
    local candidates, bodies = {}, {}
    for _, t in ipairs(scan.coast) do bodies[buffer.readu16(s.map.coast_body, t * 2)] = true end
    local total, limit = s.map.coast_count, math.min(s.map.coast_count, 1600)
    for k = 0, limit - 1 do
        local t = buffer.readi32(s.map.coast_list, math.floor(k * total / limit) * 4)
        local target = owner(s, t)
        if not bodies[buffer.readu16(s.map.coast_body, t * 2)] or friendly(s, s.local_owner, target) then continue end
        if not clean(s, t) and not cfg.AllowFallout then continue end
        if target > 0 then
            local o = s.owners[target]
            if not o or o.kind == 2 and not cfg.AttackHumans then continue end
            if not Auto.offensiveRisk(s, cfg, target) then continue end
            if o.troops > ctx.available * 0.6 then continue end
        end
        local from, nearest = nil, math.huge
        local body = buffer.readu16(s.map.coast_body, t * 2)
        for _, c in ipairs(scan.coast) do
            if buffer.readu16(s.map.coast_body, c * 2) == body then
                local d = distance(s, c, t); if d < nearest then from, nearest = c, d end
            end
        end
        if from then
            local start, finish = Auto.waterEndpoint(s, from, body), Auto.waterEndpoint(s, t, body)
            if start and finish and start ~= finish then table.insert(candidates, {tile = t, from = from, d = nearest, target = target}) end
        end
    end
    table.sort(candidates, function(a, b) return a.d * (if a.target == 0 then 1 else 2) < b.d * (if b.target == 0 then 1 else 2) end)
    for i = 1, math.min(5, #candidates) do
        local c = candidates[i]
        local path = Auto.waterPath(s, c.from, c.tile)
        if not path or Auto.routeRisk(s, path, ctx.navy) > 0 then continue end
        local f = {tile = c.tile, terrain = buffer.readu8(s.map.terrain, c.tile), edges = 1,
            fallout = not clean(s, c.tile), coverage = if Auto.defenseAt(s, c.target, c.tile) then 1 else 0}
        local plan = Auto.attackPlan(s, f, c.target, cfg, ctx)
        if plan and plan.amount >= 3000 then
            memory.navalText = "Desant: trasa bez wykrytych okretow bojowych"
            memory.armyDetails = plan
            memory.navalDetails = {from = c.from, to = c.tile, pathLength = #path, risk = 0,
                warships = #ctx.navy.warships, transports = #ctx.navy.transports, trade = #ctx.navy.trade}
            return {type = "boat", tile = c.tile, ratio = plan.amount / s.owners[s.local_owner].troops}, memory.navalText, "boat"
        end
    end
    memory.navalText = "Desant wstrzymany: okrety lub brak pewnej trasy"
    return nil
end

-- Match the source's curved missile path; interception may happen near either end, not just above the target.
function Auto.bombPath(s, from, to, kind)
    local ax, ay, bx, by = from % s.W + 0.5, from // s.W + 0.5, to % s.W + 0.5, to // s.W + 0.5
    local dx, dy = bx - ax, by - ay
    local dist = math.sqrt(dx * dx + dy * dy)
    local height = math.max(50 / s.rules.K_LIN, dist / 3)
    local c1x, c1y = ax + dx / 4, clamp(ay + dy / 4 - height, 0, s.H - 1)
    local c2x, c2y = ax + dx * 3 / 4, clamp(ay + dy * 3 / 4 - height, 0, s.H - 1)
    local path, length, px, py = {}, 0, ax, ay
    for i = 0, 96 do
        local f = i / 96
        local u = 1 - f
        local x = u^3 * ax + 3 * u^2 * f * c1x + 3 * u * f^2 * c2x + f^3 * bx
        local y = u^3 * ay + 3 * u^2 * f * c1y + 3 * u * f^2 * c2y + f^3 * by
        if i > 0 then length += math.sqrt((x - px)^2 + (y - py)^2) end
        table.insert(path, {x = x, y = y, length = length}); px, py = x, y
    end
    local speed = (if kind == 2 then 15 else 10) / s.rules.K_LIN
    return path, math.max(1, math.ceil(length / speed))
end
function Auto.samScreen(s, from, to, kind)
    if kind == 2 then return {capacity = 0, readyNow = 0, sites = 0, flight = 0} end
    local path, flight = Auto.bombPath(s, from, to, kind)
    local out = {capacity = 0, readyNow = 0, sites = 0, flight = flight, cooldown = 90, reloadIn = math.huge}
    local zone2 = (150 / s.rules.K_LIN)^2
    for _, b in pairs(s.structures) do
        if b.kind ~= 4 or friendly(s, s.local_owner, b.owner) or b.active_tick > s.tick + flight then continue end
        local earliest, latest
        for _, p in ipairs(path) do
            local t = math.floor(p.y) * s.W + math.floor(p.x)
            local at = s.tick + math.floor(flight * p.length / math.max(path[#path].length, 1))
            local r = (150 - 480 / (b.level + 5)) / s.rules.K_LIN
            local samTime = math.ceil((math.abs(b.tile % s.W - t % s.W) + math.abs(b.tile // s.W - t // s.W)) * s.rules.K_LIN / 12)
            if (distance(s, from, t) < zone2 or distance(s, to, t) < zone2)
                and distance(s, b.tile, t) <= r^2 and at - s.tick >= samTime then
                earliest = earliest or at - samTime; latest = at - samTime
            end
        end
        if earliest then
            out.sites += 1; out.readyNow += Auto.readyMissiles(s, b)
            -- Conservative saturation budget: the same launcher can reload while a long volley passes.
            local first = math.max(s.tick, earliest, b.active_tick)
            if first > latest then continue end
            local capacity = 0
            for slot = 1, b.level do
                local fired = (b.shots or {})[slot]
                local loaded = if fired then math.max(s.tick, fired + 90) else s.tick
                out.reloadIn = math.min(out.reloadIn, math.max(0, loaded - s.tick))
                local fire = math.max(first, loaded)
                if fire <= latest then capacity += 1 + math.floor((latest - fire) / 90) end
            end
            out.capacity += capacity
        end
    end
    return out
end
local function blastSafe(s, tile, radius, impactTick)
    for _, b in pairs(s.structures) do
        if friendly(s, s.local_owner, b.owner) and distance(s, tile, b.tile) <= radius^2 then return false end
    end
    for _, u in pairs(s.units) do
        if friendly(s, s.local_owner, u.owner) then
            for _, tick in ipairs({s.tick, impactTick or s.tick}) do
                local x, y = Auto.unitPosition(s, u, tick)
                if x and (x - (tile % s.W + 0.5))^2 + (y - (tile // s.W + 0.5))^2 <= radius^2 then return false end
            end
        end
    end
    local cx, cy = tile % s.W, tile // s.W
    for y = math.max(0, cy - math.ceil(radius)), math.min(s.H - 1, cy + math.ceil(radius)) do
        for x = math.max(0, cx - math.ceil(radius)), math.min(s.W - 1, cx + math.ceil(radius)) do
            local t = y * s.W + x
            if distance(s, tile, t) <= radius^2 and friendly(s, s.local_owner, owner(s, t)) then return false end
        end
    end
    return true
end

local targetWeights = {[0] = 5, 4, 4, 4, 8, 8, 5, 6, 9}
local function targetAllowed(s, cfg, ctx, id)
    local o, mine = s.owners[id], s.owners[s.local_owner]
    if not o or not o.alive or friendly(s, s.local_owner, id) then return false end
    if o.kind == 2 and (not cfg.AttackHumans or s.tick - s.playing_since < 300) then return false end
    if (s.observed_shield or {})[id] and s.observed_shield[id] > s.tick then return false end
    return ctx.wars[id] or (s.aggressors or {})[id] ~= nil or o.tiles >= mine.tiles * 1.5
end
local function nearestLauncher(s, kind, tile, reach)
    local best, value
    for _, b in pairs(s.structures) do
        if b.owner ~= s.local_owner or b.kind ~= kind or Auto.readyMissiles(s, b) == 0 then continue end
        if reach and distance(s, b.tile, tile) > reach^2 then continue end
        local d = math.abs(b.tile % s.W - tile % s.W) + math.abs(b.tile // s.W - tile // s.W)
        if not value or d < value or d == value and b.sid < best.sid then best, value = b, d end
    end
    return best
end
local function duplicateShot(s, tile, radius)
    for _, n in pairs(s.nukes) do
        if n.owner == s.local_owner and distance(s, n.to_tile, tile) < radius^2 then return true end
    end
    return false
end
function Auto.reinforcementPlan(s, cfg, memory, ctx, now)
    local mine = s.owners[s.local_owner]
    if not Auto.canUse(s, cfg, "reinforce") or s.tick < (s.reinforceReady or 0)
        or now - (memory.reinforce or -math.huge) < 3 then return nil end
    local gain = math.min(math.floor(mine.max_troops * 0.20), math.floor(mine.max_troops - mine.troops))
    local urgent = ctx.criticalLoss or ctx.totalIncoming > mine.troops * cfg.ReinforcementUrgentPressure
    if not urgent and mine.troops > mine.max_troops * cfg.ReinforcementReadyRatio then return nil end
    local saving = if urgent then 0 else math.max(cfg.GoldReserve, ctx.nuclearDefense and ctx.nuclearDefense.reserve or 0)
    if gain < math.max(3000, mine.max_troops * 0.10) or mine.gold < 100000 + saving then return nil end
    if not urgent and ctx.totalIncoming == 0 and not next(ctx.wars) then return nil end
    memory.arsenalDetails = {kind = "reinforce", gain = gain, cost = 100000, cooldownTicks = 300, urgent = urgent}
    return {type = "reinforce"}, "Posilki: +" .. gain .. " wojska za 100K", "reinforce"
end
function Auto.strikePlan(s, cfg, memory, ctx)
    local best, bestValue, details, bestPriority, bestThreat
    for _, kind in ipairs({8, 7}) do
        local key, name = if kind == 8 then "railgun" else "airfield", if kind == 8 then "slug" else "airstrike"
        if not Auto.canUse(s, cfg, key) then continue end
        local radius = (if kind == 8 then 5 else 15) / s.rules.K_LIN
        for _, target in pairs(s.structures) do
            if not targetAllowed(s, cfg, ctx, target.owner) or duplicateShot(s, target.tile, radius) then continue end
            local launcher = nearestLauncher(s, kind, target.tile, if kind == 7 then 156 / s.rules.K_LIN else nil)
            if not launcher then continue end
            local priority, threat = Auto.threatPriority(s, ctx, target.owner)
            local value = 0
            for _, b in pairs(s.structures) do
                if targetAllowed(s, cfg, ctx, b.owner) and distance(s, target.tile, b.tile) <= radius^2 then
                    value += (targetWeights[b.kind] or 2) * (if kind == 8 then 1 else 0.6)
                end
            end
            if not bestValue or priority > bestPriority or priority == bestPriority and (threat > bestThreat or threat == bestThreat and value > bestValue) then
                bestValue, bestPriority, bestThreat = value, priority, threat
                best = {type = "nuke", kind = name, tile = target.tile}
                details = {kind = name, target = target.owner, launcher = launcher.sid, value = value,
                    cost = 0, samInterceptable = false, reloadTicks = if kind == 8 then 250 else 300, threatPriority = priority, threatScore = threat}
            end
        end
    end
    if best then
        memory.arsenalDetails = details
        memory.strikeText = (if best.kind == "slug" then "Railgun" else "Air Strike") .. ": " .. s.owners[details.target].name
            .. " (" .. best.tile % s.W .. ", " .. best.tile // s.W .. ")"
            .. (if details.threatPriority >= 2 then "; priorytet: agresor" else "; infrastruktura")
        return best, memory.strikeText, "strike"
    end
    return nil
end

-- A fixed-point intercept: flight time changes when the aim point moves.
function Auto.shipIntercept(s, u, from, kind)
    local x, y = Auto.unitPosition(s, u)
    if not x then return nil end
    local tile = math.clamp(math.floor(y), 0, s.H - 1) * s.W + math.clamp(math.floor(x), 0, s.W - 1)
    local flight, path
    for _ = 1, 8 do
        path, flight = Auto.bombPath(s, from, tile, kind)
        x, y = Auto.unitPosition(s, u, s.tick + flight)
        local nextTile = math.clamp(math.floor(y), 0, s.H - 1) * s.W + math.clamp(math.floor(x), 0, s.W - 1)
        if nextTile == tile then break end
        tile = nextTile
    end
    local _, exactFlight = Auto.bombPath(s, from, tile, kind)
    local pathTicks = math.max(0, (#(u.path or {}) - 1) * (u.ticks_per_tile_x100 or 100) / 100 - (s.tick - (u.start_tick or s.tick)))
    local uncertain = math.max(0, exactFlight - pathTicks) / s.rules.K_LIN
    if u.state == 2 then uncertain = math.max(3 / s.rules.K_LIN, uncertain * 0.35) end
    return {tile = tile, flight = exactFlight, uncertainty = uncertain, pathRemaining = pathTicks,
        knownPath = pathTicks >= exactFlight, docked = u.state == 2}
end
function Auto.shipNukePlan(s, cfg, memory, ctx, budget)
    if not cfg.NukeShips then return nil end
    local best, bestValue, details, bestPriority
    for _, row in ipairs(ctx.navy.warships) do
        local u, enemy = row.unit, s.owners[row.unit.owner]
        if not enemy or enemy.kind == 2 and not cfg.AttackHumans then continue end
        local current = math.clamp(math.floor(row.y), 0, s.H - 1) * s.W + math.clamp(math.floor(row.x), 0, s.W - 1)
        local silo = nearestLauncher(s, 5, current)
        if not silo then continue end
        local prediction = Auto.shipIntercept(s, u, silo.tile, 0)
        if not prediction or prediction.uncertainty > 18 / s.rules.K_LIN then continue end
        local aim, radius = prediction.tile, 30 / s.rules.K_LIN
        if duplicateShot(s, aim, radius) or not blastSafe(s, aim, radius, s.tick + prediction.flight) then continue end
        local screen = Auto.samScreen(s, silo.tile, aim, 0)
        local amount = screen.capacity + 1
        if amount > math.min(Auto.readyMissiles(s, silo), cfg.MaxNukeSalvo) or amount * 750000 > budget then continue end
        local worth, hits, healing = 0, {}, false
        for _, ship in ipairs(ctx.navy.warships) do
            local o = s.owners[ship.unit.owner]
            if o and o.kind == 2 and not cfg.AttackHumans then continue end
                local x, y = Auto.unitPosition(s, ship.unit, s.tick + prediction.flight)
                local remaining = math.max(0, (#(ship.unit.path or {}) - 1) * (ship.unit.ticks_per_tile_x100 or 100) / 100
                    - (s.tick - (ship.unit.start_tick or s.tick)))
                local uncertainty = math.max(0, prediction.flight - remaining) / s.rules.K_LIN
                if ship.unit.state == 2 then uncertainty *= 0.35 end
                local predicted = x and math.clamp(math.floor(y), 0, s.H - 1) * s.W + math.clamp(math.floor(x), 0, s.W - 1)
                if predicted and distance(s, predicted, aim) <= math.max(0, radius - uncertainty)^2 then
                worth += 350000 * (1 + (ship.unit.veterancy or 0) * 0.4)
                table.insert(hits, ship.unit.uid)
            end
        end
        for _, b in pairs(s.structures) do
            if not friendly(s, s.local_owner, b.owner) and distance(s, aim, b.tile) <= radius^2 then
                worth += (targetWeights[b.kind] or 2) * 100000
                if b.kind == 1 then healing = true end
            end
        end
        if worth < math.max(cfg.MinimumShipValue, amount * 750000 * 1.15) then continue end
        local value = worth / (amount * 750000) * 5
        local priority, threat = Auto.threatPriority(s, ctx, u.owner)
        if not bestValue or priority > bestPriority or priority == bestPriority and value > bestValue then
            best, bestValue, bestPriority = {type = "nuke", kind = "atom", tile = aim, amount = amount}, value, priority
            details = {kind = "atom", movingShips = hits, predictedTile = aim, flightTicks = prediction.flight,
                uncertaintyTiles = prediction.uncertainty, knownPath = prediction.knownPath, portInBlast = healing,
                cost = amount * 750000, interceptCapacity = screen.capacity, silo = silo.sid, threatPriority = priority, threatScore = threat}
        end
    end
    if best then memory.shipNukeDetails = details end
    return best, bestValue, details
end

function Auto.siloNeed(s, scan, cfg, memory, ctx)
    if not cfg.AutoNukes or ctx.criticalLoss or ctx.nuclearDefense and ctx.nuclearDefense.needed then return nil end
    local mine, levels, unfinished = s.owners[s.local_owner], 0, false
    for _, b in pairs(s.structures) do
        if b.owner == s.local_owner and b.kind == 5 then
            levels += b.level; if b.active_tick > s.tick then unfinished = true end
        end
    end
    if unfinished then return nil end
    local origin = scan.own[math.max(1, #scan.own // 2)]
    if not origin then return nil end
    local best
    for _, target in pairs(s.structures) do
        if not targetAllowed(s, cfg, ctx, target.owner) or not blastSafe(s, target.tile, 30 / s.rules.K_LIN) then continue end
        local silo = nearestLauncher(s, 5, target.tile)
        -- A reloading silo is a reason to wait, rather than to buy another building.
        if levels > 0 and not silo then continue end
        local screen = Auto.samScreen(s, silo and silo.tile or origin, target.tile, 0)
        local required = screen.capacity + 1
        if required > cfg.MaxNukeSalvo then continue end
        local value = 0
        for _, b in pairs(s.structures) do
            if b.owner == target.owner and distance(s, target.tile, b.tile) <= (30 / s.rules.K_LIN)^2 then value += targetWeights[b.kind] or 2 end
        end
        if value < required * 5 then continue end
        local current = silo and silo.level or 0
        local extra = math.max(0, required - current)
        if extra == 0 then continue end
        local ammunition = required * 750000
        local total = extra * 1000000 + math.max(ammunition / math.max(cfg.NukeBudgetShare, 0.05), ammunition + cfg.GoldReserve)
        local candidate = {sid = silo and silo.sid, required = required, extra = extra, total = total,
            target = target.owner, value = value, first = levels == 0, affordable = mine.gold >= total}
        if not best or value / total > best.value / best.total then best = candidate end
    end
    if best then
        memory.siloDetails = best
        memory.wantSiloUpgrade = best.sid
    end
    return best
end
function Auto.nukePlan(s, scan, cfg, memory, ctx)
    if not cfg.AutoNukes or s.tick < (s.weaponBackoff or 0) then return nil end
    local me, mine = s.local_owner, s.owners[s.local_owner]
    local silos, slots = {}, 0
    for _, b in pairs(s.structures) do
        if b.owner == me and b.kind == 5 and Auto.readyMissiles(s, b) > 0 then table.insert(silos, b); slots += Auto.readyMissiles(s, b) end
    end
    memory.wantSiloUpgrade = nil
    if slots == 0 then memory.weaponText = "Atomowki: brak zaladowanego silosu"; return nil end
    local defenseReserve = ctx.nuclearDefense and ctx.nuclearDefense.reserve or 0
    local budget = math.max(0, math.min(mine.gold * cfg.NukeBudgetShare, mine.gold - math.max(cfg.GoldReserve, defenseReserve)))
    if budget < 750000 then memory.weaponText = "Atomowki: oszczedza zloto na gospodarke i obrone"; return nil end
    local best, bestValue, candidates, bestPriority, bestThreat = nil, nil, {}, nil, nil
    for _, b in pairs(s.structures) do
        if not friendly(s, me, b.owner) then
            local rough = (targetWeights[b.kind] or 2) * math.sqrt(b.level)
            if ctx.wars[b.owner] then rough += 5 end
            local priority, threat = Auto.threatPriority(s, ctx, b.owner)
            rough += priority * 1000 + math.min(threat, 50)
            table.insert(candidates, {site = b, value = rough})
        end
    end
    table.sort(candidates, function(a, b) return if a.value == b.value then a.site.sid < b.site.sid else a.value > b.value end)
    for index = 1, math.min(cfg.WeaponCandidates, #candidates) do
        local target = candidates[index].site
        local enemy = s.owners[target.owner]
        if not enemy or not enemy.alive or owner(s, target.tile) ~= target.owner then continue end
        if enemy.kind == 2 and not cfg.AttackHumans then continue end
        if not targetAllowed(s, cfg, ctx, target.owner) then continue end
        if (s.observed_shield or {})[target.owner] and s.observed_shield[target.owner] > s.tick then continue end
        local nearest = nearestLauncher(s, 5, target.tile)
        local inFlight = false
        for _, n in pairs(s.nukes) do
            if n.owner == me and distance(s, n.to_tile, target.tile) < (40 / s.rules.K_LIN)^2 then inFlight = true; break end
        end
        if inFlight then continue end
        local kinds = {0}
        if cfg.AllowHydrogen then table.insert(kinds, 1) end
        if Auto.canUse(s, cfg, "mega") then table.insert(kinds, 4) end
        if Auto.canUse(s, cfg, "scatter") then table.insert(kinds, 5) end
        for _, kind in ipairs(kinds) do
            local radius = (if kind == 0 or kind == 5 then 30 elseif kind == 4 then 60 else 100) / s.rules.K_LIN
            local screen = Auto.samScreen(s, nearest.tile, target.tile, kind)
            local safetyRadius = if kind == 5 then 65 / s.rules.K_LIN else radius
            if not blastSafe(s, target.tile, safetyRadius, s.tick + screen.flight) then continue end
            local amount = if kind == 0 then screen.capacity + 1 else 1
            local price = if kind == 0 then 750000 elseif kind == 1 then 5000000 elseif kind == 4 then 2500000 else 3750000
            if (kind == 1 or kind == 4) and screen.capacity > 0 or kind == 5 and screen.capacity > 2 then continue end
            local loadedHere = Auto.readyMissiles(s, nearest)
            if amount > math.min(loadedHere, cfg.MaxNukeSalvo) or price * amount > budget then
                if kind == 0 and screen.sites > 0 then
                    memory.weaponText = "Cel " .. enemy.name .. ": SAM " .. screen.sites .. ", potrzeba " .. amount
                        .. " pociskow; gotowe " .. loadedHere .. ", cooldown SAM 9 s"
                    if amount <= cfg.MaxNukeSalvo and price * amount <= budget and nearest.level < amount then
                        memory.wantSiloUpgrade = nearest.sid
                    end
                end
                continue
            end
            local value = 0
            for _, b in pairs(s.structures) do
                if b.owner == target.owner then
                    local d2 = distance(s, target.tile, b.tile)
                    local p = if d2 <= radius^2 then (if kind == 5 and screen.capacity > 0 then 0.2 else 1)
                        elseif kind == 5 and d2 <= (64 / s.rules.K_LIN)^2 then 0.32 else 0
                    value += (targetWeights[b.kind] or 2) * math.sqrt(b.level) * p
                end
            end
            value += math.min(6, enemy.troops / math.max(fullArea(s, enemy.tiles), 1) * math.pi * (radius * s.rules.K_LIN)^2 / 80000)
            if value < (if kind == 0 then 5 elseif kind == 1 then 18 elseif kind == 4 then 13 else 17) then continue end
            local efficiency = value / (price * amount / 750000)
            local priority, threat = Auto.threatPriority(s, ctx, target.owner)
            if not bestValue or priority > bestPriority or priority == bestPriority and (threat > bestThreat or threat == bestThreat and efficiency > bestValue) then
                bestValue, bestPriority, bestThreat = efficiency, priority, threat
                best = {type = "nuke", kind = if kind == 0 then "atom" elseif kind == 1 then "hydrogen" elseif kind == 4 then "mega" else "scatter", tile = target.tile, amount = amount}
                memory.nukeDetails = {target = target.owner, tile = target.tile, kind = best.kind, amount = amount,
                    cost = price * amount, samSites = screen.sites, interceptCapacity = screen.capacity,
                    readyNow = screen.readyNow, cooldownTicks = 90, flightTicks = screen.flight, silo = nearest.sid, value = value,
                    randomSpread = kind == 5, threatPriority = priority, threatScore = threat}
                memory.weaponText = "Cel " .. enemy.name .. ": " .. amount .. " pocisk(i), oslon SAM: " .. screen.sites
                    .. ", przewidywane przechwycenia: " .. screen.capacity
            end
        end
    end
    local shipCommand, shipValue, shipDetails = Auto.shipNukePlan(s, cfg, memory, ctx, budget)
    if shipCommand and (not bestValue or shipDetails.threatPriority > bestPriority
        or shipDetails.threatPriority == bestPriority and shipValue > bestValue) then
        best, memory.nukeDetails = shipCommand, shipDetails
        memory.weaponText = "Atom na przewidywana pozycje " .. #shipDetails.movingShips .. " okretow; lot "
            .. shipDetails.flightTicks / 10 .. " s; niepewnosc " .. math.floor(shipDetails.uncertaintyTiles)
    end
    return best, memory.weaponText, "weapon"
end

function Auto.arsenalBuildPlan(s, scan, cfg, memory, ctx, urgentOnly, spendingFloor)
    if ctx.criticalLoss or ctx.landTimeLeft and ctx.landTimeLeft < 120 then
        memory.buildText = "Arsenal czeka: kraj zbyt szybko traci teren"
        return nil
    end
    local mine, best, bestValue = s.owners[s.local_owner], nil, nil
    spendingFloor = math.max(spendingFloor or 0, ctx.nuclearDefense and ctx.nuclearDefense.reserve or 0)
    local counts, ownByKind, targets = {}, {}, {}
    for _, b in pairs(s.structures) do
        if b.owner == s.local_owner then
            counts[b.kind] = (counts[b.kind] or 0) + 1
            ownByKind[b.kind] = ownByKind[b.kind] or {}; table.insert(ownByKind[b.kind], b)
        elseif targetAllowed(s, cfg, ctx, b.owner) then table.insert(targets, b) end
    end
    table.sort(targets, function(a, b) return (targetWeights[a.kind] or 2) > (targetWeights[b.kind] or 2) end)
    while #targets > cfg.WeaponCandidates * 2 do table.remove(targets) end
    local choices = {{6, "artillery", cfg.MaxArtillery, 45}, {7, "airfield", cfg.MaxAirfields, 156}, {8, "railgun", cfg.MaxRailguns, 0}}
    for _, choice in ipairs(choices) do
        local kind, key, limit, range = unpack(choice)
        if urgentOnly and kind ~= 6 then continue end
        if not Auto.canUse(s, cfg, key) or (counts[kind] or 0) >= limit then continue end
        local cost = s.rules.cost_of(s, s.local_owner, key)
        if mine.gold - cost < math.max(cfg.GoldReserve, spendingFloor or 0)
            or cost > mine.gold * (if kind == 6 and ctx.groundLosing then 0.65 else 0.40) then continue end
        local checked = 0
        for _, tile in ipairs(Auto.buildCandidates(s, scan, key, ctx)) do
            local placement = s.rules.placement(s, s.local_owner, key, tile)
            if not placement.ok or placement.upgrade_sid ~= 0 or Auto.constructionBlocked(s, placement.tile) then continue end
            local buildTicks = if kind == 6 then 80 elseif kind == 7 then 100 else 150
            if Auto.siteBombRisk(s, placement.tile, buildTicks) or ctx.defending and Auto.frontArrival(s, scan, ctx, placement.tile) <= Auto.constructionWindow(cfg, buildTicks, s) then continue end
            local value = 0
            for _, b in ipairs(targets) do
                if range == 0 or distance(s, b.tile, tile) <= (range / s.rules.K_LIN)^2 then
                    local covered = false
                    for _, own in ipairs(ownByKind[kind] or {}) do
                        if range == 0 or distance(s, own.tile, b.tile) <= (range / s.rules.K_LIN)^2 then covered = true; break end
                    end
                    value += (targetWeights[b.kind] or 2) * (if covered then 0.15 else 1)
                end
            end
            if value < 4 then continue end
            -- A battery chooses targets by itself. Do not put human land in range when that option is off.
            if kind == 6 and not cfg.AttackHumans then
                local humanNearby = false
                local r, x0, y0 = math.ceil(45 / s.rules.K_LIN), tile % s.W, tile // s.W
                for y = math.max(0, y0 - r), math.min(s.H - 1, y0 + r) do
                    for x = math.max(0, x0 - r), math.min(s.W - 1, x0 + r) do
                        local t = y * s.W + x; local id = owner(s, t); local o = s.owners[id]
                        if o and o.kind == 2 and not friendly(s, s.local_owner, id) and distance(s, tile, t) <= r^2 then humanNearby = true; break end
                    end
                    if humanNearby then break end
                end
                if humanNearby then continue end
            end
            local danger = 0
            for _, border in pairs(scan.borders) do
                if border.ownTile and distance(s, tile, border.ownTile) < (20 / s.rules.K_LIN)^2 then danger += 0.4 end
            end
            local score = value / (cost / 150000) - danger
            if not bestValue or score > bestValue then best, bestValue = {type = "build", kind = key, tile = placement.tile}, score end
            checked += 1
            if range == 0 and checked >= 30 then break end
        end
    end
    if best then
        memory.buildDetails = {kind = best.kind, tile = best.tile, cost = s.rules.cost_of(s, s.local_owner, best.kind), score = bestValue, unlocked = true}
        return best, "Buduje " .. best.kind .. ": wartosciowe cele w zasiegu", "build"
    end
    return nil
end

local function waterTile(s, row)
    return math.clamp(math.floor(row.y), 0, s.H - 1) * s.W + math.clamp(math.floor(row.x), 0, s.W - 1)
end
local function coastDistance(s, scan, tile)
    local best = math.huge
    local step = math.max(1, math.ceil(#scan.coast / 500))
    for i = 1, #scan.coast, step do best = math.min(best, distance(s, tile, scan.coast[i])) end
    return math.sqrt(best)
end
function Auto.warshipPlan(s, scan, cfg, memory, ctx, now, urgentOnly)
    if not cfg.AutoWarships then return nil end
    local me, mine, k = s.local_owner, s.owners[s.local_owner], s.rules.K_LIN
    local ports, candidates = {}, {}
    for _, b in pairs(s.structures) do
        if b.owner == me and b.kind == 1 and b.active_tick <= s.tick then
            local water
            neighbors(s, b.tile, function(t) if not water and buffer.readu8(s.map.land, t) == 0 then water = t end end)
            if water then table.insert(ports, {site = b, water = water, body = buffer.readu16(s.map.water_body, water * 2)}) end
        end
    end
    if #ports == 0 then memory.warshipText = "Okrety: potrzebny gotowy port nad odpowiednim morzem"; return nil end
    for _, collection in ipairs({ctx.navy.transports, ctx.navy.warships, ctx.navy.trade}) do
        for _, row in ipairs(collection) do
            local u, o, tile = row.unit, s.owners[row.unit.owner], waterTile(s, row)
            if o and o.kind == 2 and not cfg.AttackHumans then continue end
            local d, value = coastDistance(s, scan, tile), 0
            if u.kind == 0 then
                local destination = u.path[#u.path] or tile
                local towardsUs = false
                neighbors(s, destination, function(t) if owner(s, t) == me then towardsUs = true end end)
                value = if towardsUs then 25 elseif d < 180 / k then 9 else 0
                if towardsUs then Auto.rememberAggressor(s, u.owner) end
            elseif u.kind == 2 and d < 220 / k then value = 10 + (u.veterancy or 0)
            elseif u.kind == 1 and d < 200 / k and mine.gold > 1500000 then
                local huggingShore = false
                neighbors(s, tile, function(t) if buffer.readu8(s.map.land, t) == 1 then huggingShore = true end end)
                if not huggingShore then value = 2 end
            end
            if value > 0 and (not urgentOnly or value >= 20) then
                table.insert(candidates, {tile = tile, body = buffer.readu16(s.map.water_body, tile * 2), value = value, unit = u})
            end
        end
    end
    table.sort(candidates, function(a, b) return a.value > b.value end)
    for _, target in ipairs(candidates) do
        local port
        for _, p in ipairs(ports) do
            if p.body == target.body and (not port or distance(s, p.water, target.tile) < distance(s, port.water, target.tile)) then port = p end
        end
        if not port then continue end
        local hostilePower, ownPower, ownCount, movable = 0, 0, 0, nil
        for _, row in ipairs(ctx.navy.warships) do
            if distance(s, waterTile(s, row), target.tile) <= (150 / k)^2 then
                local arrival = s.tick + math.sqrt(distance(s, port.water, target.tile)) * k
                local hp = Auto.shipHealthAt(s, row.unit, arrival)
                hostilePower += hp / 1000 * (1 + (row.unit.veterancy or 0) * 0.2)
            end
        end
        for _, row in ipairs(ctx.navy.ownWarships) do
            local u, tile = row.unit, waterTile(s, row)
            if buffer.readu16(s.map.water_body, tile * 2) ~= target.body then continue end
            ownCount += 1
            local health = if (u.max_hp or 0) > 0 then u.hp / u.max_hp else 1
            if distance(s, tile, target.tile) <= (160 / k)^2 then ownPower += health * (1 + (u.veterancy or 0) * 0.4) end
            -- Manual moves suppress automatic retreat for 5 s. Leave repairs entirely to the game.
            if health >= 0.85 and (u.state or 0) == 0 and distance(s, tile, target.tile) > (110 / k)^2
                and now - ((memory.shipMoves or {})[u.uid] or -math.huge) >= 10 then movable = row end
        end
        local desired = math.min(cfg.MaxWarships, math.max(1, math.ceil(hostilePower * 1.35)))
        local cost = s.rules.cost_of(s, me, "warship")
        local canBuild = cfg.AutoBuild and #ctx.navy.ownWarships < cfg.MaxWarships and ownCount < desired
            and now - (memory.warship or -math.huge) >= cfg.WarshipGap
            and mine.gold - cost >= math.max(cfg.GoldReserve, ctx.nuclearDefense and ctx.nuclearDefense.reserve or 0)
            and cost <= mine.gold * (if target.value >= 20 then 0.65 else 0.35)
        if canBuild and (target.value >= 9 or mine.gold > 3000000) then
            memory.navalDetails = {kind = "warship", port = port.site.sid, tile = target.tile, cost = cost,
                hostilePower = hostilePower, ownPower = ownPower, desired = desired, reason = target.value >= 20 and "incoming_transport" or "sea_control"}
            memory.warshipText = "Okret z portu: " .. (if target.value >= 20 then "przechwycenie desantu" else "ochrona morza i handlu")
            return {type = "build", kind = "warship", tile = target.tile}, memory.warshipText, "warship"
        end
        if movable and (hostilePower == 0 or ownPower + 1 >= hostilePower * 1.15) then
            memory.shipMoves = memory.shipMoves or {}; memory.shipMoves[movable.unit.uid] = now
            memory.navalDetails = {kind = "patrol", uid = movable.unit.uid, target = target.unit.uid, tile = target.tile,
                hostilePower = hostilePower, ownPower = ownPower, automaticRepair = true}
            memory.warshipText = "Patrol: przesuwa zdrowy okret ku zagrozeniu; uszkodzone wracaja do portu"
            return {type = "move_warship", uid = movable.unit.uid, tile = target.tile}, memory.warshipText, "navalMove"
        end
    end
    return nil
end

function Auto.infrastructure(s)
    local out = {levels = {[0] = 0}, counts = {[0] = 0}, activeLevels = {[0] = 0}}
    for _, b in pairs(s.structures) do
        if b.owner ~= s.local_owner then continue end
        out.levels[b.kind] = (out.levels[b.kind] or 0) + b.level
        out.counts[b.kind] = (out.counts[b.kind] or 0) + 1
        if b.active_tick <= s.tick then out.activeLevels[b.kind] = (out.activeLevels[b.kind] or 0) + b.level end
    end
    out.cityLevels, out.portLevels, out.factoryLevels, out.forts = out.levels[0] or 0, out.levels[1] or 0, out.levels[2] or 0, out.counts[3] or 0
    out.cityBuildings, out.portBuildings, out.factoryBuildings = out.counts[0] or 0, out.counts[1] or 0, out.counts[2] or 0
    out.civilLevels = out.cityLevels + out.portLevels + out.factoryLevels
    return out
end
function Auto.economyPriorities(s, scan, cfg, infra)
    local mine = s.owners[s.local_owner]
    local trade = #scan.coast > 0 and next(scan.foreignPorts) ~= nil
    local out = {plans = {}, trade = trade, targetCities = math.min(cfg.MaxCityLevels, math.max(2, 1 + math.floor(fullArea(s, mine.tiles) / 4000)))}
    out.targetCitySites = math.min(out.targetCities, math.max(2, 1 + math.floor(fullArea(s, mine.tiles) / 10000)))
    out.targetPorts = if trade then math.min(3, 1 + math.floor(fullArea(s, mine.tiles) / 16000)) else 0
    out.targetFactories = math.min(3, 1 + math.floor(infra.cityLevels / 6))
    out.foundationReady = infra.cityLevels >= cfg.MinCityLevelsBeforePeaceFort and (infra.factoryLevels >= 1 or infra.portLevels >= 1)
    out.needsFoundation = infra.cityLevels < cfg.MinCityLevelsBeforePeaceFort or infra.factoryLevels == 0 or (trade and infra.portLevels == 0)
    local seen = {}
    local function add(kind, why)
        if seen[kind] then return end
        seen[kind] = true; table.insert(out.plans, {kind = kind, why = why})
    end
    if infra.cityLevels == 0 then add("city", "pierwsze miasto") end
    if trade and infra.portLevels == 0 then add("port", "pierwszy port i handel") end
    if infra.cityLevels > 0 and infra.factoryLevels == 0 then add("factory", "pierwsza fabryka przy miescie lub porcie") end
    if infra.cityLevels < cfg.MinCityLevelsBeforePeaceFort then add("city", "podstawowy limit armii") end
    local saturation = mine.troops / math.max(mine.max_troops, 1)
    if infra.cityLevels < out.targetCities and saturation >= 0.60 then add("city", "armia zbliza sie do limitu") end
    if infra.portLevels < out.targetPorts then add("port", "rozwoj handlu") end
    if infra.cityLevels > 0 and infra.factoryLevels < out.targetFactories then add("factory", "rozwoj sieci dochodu") end
    if infra.cityLevels < out.targetCities and saturation >= 0.45 then add("city", "limit armii wzgledem terytorium") end
    out.peaceFortLimit = math.min(cfg.MaxDefensePosts, cfg.MaxPeaceDefensePosts, math.floor(infra.civilLevels * cfg.PeaceFortsPerCivilLevel))
    out.savings = cfg.GoldReserve
    if out.plans[1] then out.savings = math.max(out.savings, s.rules.cost_of(s, s.local_owner, out.plans[1].kind)) end
    return out
end

function Auto.constructionWindow(cfg, buildTicks, s)
    local lag = math.max(cfg.ConstructionCommandLagTicks, s and s.learningProfile and s.learningProfile.commandLagTicks or 0)
    return (buildTicks + lag) * 1.5
end

function Auto.nuclearDefensePlan(s, scan, cfg, ctx)
    if not cfg.AutoBuild or not cfg.AutoSAM then return nil end
    local recent = s.ownNuclearHit ~= nil and s.tick - s.ownNuclearHit < cfg.NuclearDefenseMemoryTicks
    local infra = Auto.infrastructure(s)
    if (infra.levels[4] or 0) >= cfg.MaxSAMLevels then return nil end
    local enemySilo = false
    if infra.cityLevels >= 2 and infra.factoryLevels > 0 then
        for _, b in pairs(s.structures) do
            if b.kind == 5 and not friendly(s, s.local_owner, b.owner) then enemySilo = true; break end
        end
    end
    if not recent and not ctx.nuclearThreat and not enemySilo then return nil end
    local sams, targets = {}, {}
    for _, b in pairs(s.structures) do
        -- A launcher under construction already reserves coverage for the next 30 seconds.
        if b.owner == s.local_owner and b.kind == 4 then table.insert(sams, b) end
    end
    for _, b in pairs(s.structures) do
        if b.owner ~= s.local_owner or b.kind == 3 or b.kind == 4 then continue end
        local covered = false
        for _, sam in ipairs(sams) do
            if distance(s, sam.tile, b.tile) <= Auto.samRange(s, sam)^2 then covered = true; break end
        end
        if not covered then table.insert(targets, b) end
    end
    if #targets == 0 then return nil end
    local plan = {needed = false, reserve = 0, cost = s.rules.cost_of(s, s.local_owner, "sam"),
        reason = if recent then "odbudowa oslony po trafieniu" elseif ctx.nuclearThreat then "nadlatujace pociski" else "wrogie silosy i nieosloniete zaplecze",
        uncovered = #targets, value = 0, buildTicks = 300}
    local candidates = Auto.buildCandidates(s, scan, "sam", ctx)
    for i, tile in ipairs(candidates) do
        if #candidates > 600 and i % math.ceil(#candidates / 600) ~= 0 then continue end
        local p = s.rules.placement(s, s.local_owner, "sam", tile)
        if not p.ok or p.upgrade_sid ~= 0 or Auto.siteBombRisk(s, p.tile, 300) or Auto.constructionBlocked(s, p.tile) then continue end
        local arrival = Auto.frontArrival(s, scan, ctx, p.tile)
        if arrival <= Auto.constructionWindow(cfg, 300, s) then continue end
        local value = 0
        for _, b in ipairs(targets) do
            if distance(s, p.tile, b.tile) <= (70 / s.rules.K_LIN)^2 then
                value += (targetWeights[b.kind] or 2) * math.min(b.level, 4)
            end
        end
        if value > plan.value then plan.tile, plan.value, plan.estimatedFrontArrivalTicks = p.tile, value, arrival < math.huge and arrival or nil end
    end
    if plan.tile then plan.needed, plan.reserve = true, plan.cost else plan.blocked = "brak miejsca z czasem na budowe SAM" end
    return plan
end

function Auto.buildPlan(s, scan, cfg, memory, ctx, urgentOnly)
    if not cfg.AutoBuild or s.tick < (s.buildBackoff or 0) then return nil end
    local me, mine = s.local_owner, s.owners[s.local_owner]
    local infra = Auto.infrastructure(s)
    local levels, count = infra.levels, infra.counts
    local economy = Auto.economyPriorities(s, scan, cfg, infra)
    local nuclear = ctx.nuclearDefense
    memory.nuclearDefense = nuclear
    if nuclear and nuclear.needed then
        if mine.gold >= nuclear.cost then
            memory.buildDetails = {kind = "sam", tile = nuclear.tile, cost = nuclear.cost, buildTicks = 300,
                estimatedFrontArrivalTicks = nuclear.estimatedFrontArrivalTicks, priority = nuclear.reason, nuclearDefense = nuclear,
                frontModel = "observed_plus_source_speed", frontPolicy = "local_edge_and_learning"}
            memory.buildText = "Buduje SAM: " .. nuclear.reason
            return {type = "build", kind = "sam", tile = nuclear.tile}, memory.buildText, "build"
        end
        memory.weaponText = "Oslona SAM: oszczedza " .. math.floor(mine.gold / 1000) .. "K / " .. math.ceil(nuclear.cost / 1000) .. "K"
    end
    memory.economyDetails = {cities = infra.cityLevels, cityBuildings = count[0] or 0, ports = infra.portLevels, factories = infra.factoryLevels, forts = infra.forts,
        cityGoal = economy.targetCities, peaceFortLimit = economy.peaceFortLimit, savings = economy.savings}
    local ownSams, uncovered = {}, {}
    for _, b in pairs(s.structures) do if b.owner == me and b.kind == 4 and b.active_tick <= s.tick then table.insert(ownSams, b) end end
    for _, b in pairs(s.structures) do
        if b.owner ~= me or b.kind == 3 then continue end
        local covered = false
        for _, sam in ipairs(ownSams) do if distance(s, sam.tile, b.tile) <= Auto.samRange(s, sam)^2 then covered = true; break end end
        if not covered then table.insert(uncovered, b) end
    end
    local threats = {}
    for enemy, front in pairs(scan.borders or scan.fronts) do
        local o = s.owners[enemy]
        if o and o.kind ~= 1 and not friendly(s, me, enemy) then
            local strength = o.troops / math.max(mine.troops, 1) + (if ctx.incoming[enemy] then 3 else 0)
            table.insert(threats, {front = front, value = strength, id = enemy})
        end
    end
    table.sort(threats, function(a, b) return a.value > b.value end)
    local plans, planReasons = {}, {}
    local activeGroundThreat = ctx.groundCritical or ctx.totalIncoming > math.max(1000, mine.troops * 0.15)
    local mildPressure = not ctx.losing and ctx.totalIncoming <= mine.troops * 0.15
    if not urgentOnly and ctx.defending and not mildPressure then return nil end
    if cfg.AutoSAM and (ctx.nuclearThreat or s.ownNuclearHit and s.tick - s.ownNuclearHit < 300) then table.insert(plans, "sam") end
    if #threats > 0 and threats[1].value >= 0.8 and (count[3] or 0) < cfg.MaxDefensePosts
        and activeGroundThreat then table.insert(plans, "defense") end
    if not urgentOnly then
        -- Civilian foundations are considered before discretionary weapons and border forts.
        for _, plan in ipairs(economy.plans) do table.insert(plans, plan.kind); planReasons[plan.kind] = plan.why end
        local silo = if infra.cityLevels >= cfg.MinCityLevelsBeforePeaceFort then Auto.siloNeed(s, scan, cfg, memory, ctx) else nil
        if silo and silo.affordable then table.insert(plans, "silo") end
        local saveForSilo = silo and not silo.affordable and economy.foundationReady and not economy.needsFoundation and silo.total <= 8000000
        if saveForSilo then
            memory.weaponText = "Oszczedza na silos i amunicje: " .. math.floor(mine.gold / 1000) .. "K / " .. math.ceil(silo.total / 1000) .. "K"
            local priority = Auto.threatPriority(s, ctx, silo.target)
            if priority >= 2 then return nil end
        end
        if economy.foundationReady and not saveForSilo then table.insert(plans, "arsenal") end
        if not activeGroundThreat and cfg.FortifyPeace and economy.foundationReady
            and infra.forts < economy.peaceFortLimit and #threats > 0 and threats[1].value >= 0.8 and not saveForSilo then
            table.insert(plans, "defense"); planReasons.defense = "dodatkowa osłona po rozwoju gospodarki"
        end
        local enemySilo = false
        for _, b in pairs(s.structures) do if b.kind == 5 and not friendly(s, me, b.owner) then enemySilo = true; break end end
        if cfg.AutoSAM and enemySilo and (levels[4] or 0) < 3 and mine.gold >= 1800000 then table.insert(plans, "sam") end
    end
    for _, kind in ipairs(plans) do
        if kind == "arsenal" then
            local command, why, bucket = Auto.arsenalBuildPlan(s, scan, cfg, memory, ctx, false, economy.savings)
            if command then return command, why, bucket end
            continue
        end
        if kind == "city" and (levels[0] or 0) >= cfg.MaxCityLevels then continue end
        local cost = s.rules.cost_of(s, me, kind)
        if cost < 0 or mine.gold < cost then continue end
        if kind ~= "sam" and nuclear and nuclear.needed and mine.gold - cost < nuclear.reserve
            and not (kind == "defense" and activeGroundThreat) then continue end
        if kind == "defense" and not activeGroundThreat and (cost > mine.gold * cfg.PeaceFortBudgetShare or mine.gold - cost < economy.savings) then
            memory.buildText = "Fort w pokoju czeka: oszczedza na miasta i dochod"; continue
        end
        if ctx.defending and mildPressure and (kind == "city" or kind == "port" or kind == "factory")
            and (mine.gold - cost < cfg.GoldReserve or cost > mine.gold * 0.35) then continue end
        local sites = if kind == "port" then scan.coast else Auto.buildCandidates(s, scan, kind, ctx)
        local best, bestScore, bestSafety, bestCoverage, bestEnemy
        local buildTicks = if kind == "sam" then 300 elseif kind == "silo" then 100 elseif kind == "defense" or kind == "port" then 50 else 20
        for index, tile in ipairs(sites) do
            if kind ~= "defense" and kind ~= "sam" and #sites > 600 and index % math.ceil(#sites / 600) ~= 0 then continue end
            if owner(s, tile) ~= me or not clean(s, tile) then continue end
            local preview = s.rules.placement(s, me, kind, tile)
            if not preview.ok or Auto.constructionBlocked(s, preview.tile) then continue end
            if Auto.siteBombRisk(s, preview.tile, buildTicks) then memory.buildText = "Pomija miejsce budowy: zapowiedziany wybuch"; continue end
            local safeTicks = if ctx.defending then Auto.frontArrival(s, scan, ctx, preview.tile) else math.huge
            if ctx.defending and safeTicks <= Auto.constructionWindow(cfg, buildTicks, s) then
                memory.buildText = "Pomija " .. kind .. ": front dotrze przed koncem budowy"
                continue
            end
            local score, siteEnemy = 0, nil
            if kind == "defense" then
                if Auto.hostileLandWithin(s, preview.tile, cfg.MinFortInland / s.rules.K_LIN) then continue end
                local borderDistance = math.huge
                for _, threat in ipairs(threats) do
                    for _, point in ipairs(threat.front.ownPoints or {threat.front.ownTile}) do
                        borderDistance = math.min(borderDistance, math.sqrt(distance(s, preview.tile, point)))
                    end
                end
                if borderDistance < cfg.MinFortInland / s.rules.K_LIN then continue end
                local protected = 0
                for _, threat in ipairs(threats) do
                    local points = threat.front.ownPoints or {threat.front.ownTile}
                    for _, p in ipairs(points) do
                        if not p then continue end
                        if activeGroundThreat and not Auto.activeFrontPoint(s, ctx, threat.id, p) then continue end
                        local d = math.sqrt(distance(s, preview.tile, p))
                        local advance = Auto.frontSpeed(s, scan, ctx, threat.id, p) * buildTicks
                        if d == 0 or math.abs(d - advance) > 27 / s.rules.K_LIN then continue end
                        local px, py = p % s.W, p // s.W
                        local fx = math.clamp(math.floor(px + (preview.tile % s.W - px) * math.min(advance / d, 1)), 0, s.W - 1)
                        local fy = math.clamp(math.floor(py + (preview.tile // s.W - py) * math.min(advance / d, 1)), 0, s.H - 1)
                        if not Auto.defenseAt(s, me, fy * s.W + fx, true) then protected += threat.value; siteEnemy = siteEnemy or threat.id end
                    end
                end
                if protected == 0 then continue end
                score = protected
                if safeTicks < math.huge then score *= math.min(1.5, safeTicks / math.max(buildTicks, 1)) end
            elseif kind == "sam" then
                for _, b in ipairs(uncovered) do
                    if distance(s, preview.tile, b.tile) <= (70 / s.rules.K_LIN)^2 then score += 2 + b.level end
                end
                for _, n in ipairs(ctx.incomingNukes) do if distance(s, preview.tile, n.to_tile) <= (70 / s.rules.K_LIN)^2 then score += 10 end end
                if preview.upgrade_sid ~= 0 and ctx.nuclearThreat then score += 6 end
                if score == 0 then continue end
            elseif kind == "port" then
                local body = buffer.readu16(s.map.coast_body, preview.tile * 2)
                if not scan.foreignPorts[body] then continue end
                score = 3
                for _, w in ipairs(ctx.navy.warships) do if (w.x - tile % s.W)^2 + (w.y - tile // s.W)^2 < (145 / s.rules.K_LIN)^2 then score -= 8 end end
                if score < 0 then continue end
            elseif kind == "factory" then
                for _, b in pairs(s.structures) do
                    if b.owner == me and (b.kind == 0 or b.kind == 1) and b.active_tick <= s.tick
                        and distance(s, preview.tile, b.tile) <= (110 / s.rules.K_LIN)^2 then score += 3 end
                end
                if score == 0 then continue end
            else
                local separation = math.huge
                for _, threat in ipairs(threats) do separation = math.min(separation, distance(s, tile, threat.front.tile)) end
                score = if separation < math.huge then math.min(10, math.sqrt(separation) / 10) else 1
                if preview.upgrade_sid ~= 0 then score += 0.5 end
                if kind == "city" and (count[0] or 0) < economy.targetCitySites and preview.upgrade_sid == 0 then
                    local spacing = math.huge
                    for _, b in pairs(s.structures) do
                        if b.owner == me and b.kind == 0 then spacing = math.min(spacing, distance(s, preview.tile, b.tile)) end
                    end
                    score += 5 + (if spacing < math.huge then math.min(4, math.sqrt(spacing) * s.rules.K_LIN / 40) else 0)
                end
                if kind == "silo" then
                    if memory.wantSiloUpgrade and preview.upgrade_sid ~= memory.wantSiloUpgrade then continue end
                    if not memory.wantSiloUpgrade and preview.upgrade_sid ~= 0 then continue end
                    score += 100
                end
            end
            if not bestScore or score > bestScore then
                local coverage = if kind == "defense" then Auto.fortCoverage(s, preview.tile) else nil
                if coverage and (coverage.share < cfg.MinFortNewCoverage or coverage.ownLandShare < cfg.MinFortOwnLand) then
                    memory.buildText = "Pomija fort: zbyt mala nowa ochrona (premie nie sumuja sie)"
                    continue
                end
                best, bestScore, bestSafety, bestCoverage, bestEnemy = preview.tile, score, safeTicks, coverage, siteEnemy
            end
        end
        if best then
            memory.buildText = "Buduje " .. kind .. (if kind == "defense" then ": nieoslonieta granica" elseif kind == "sam" then ": ochrona infrastruktury" else "")
            if planReasons[kind] then memory.buildText = "Buduje " .. kind .. ": " .. planReasons[kind] end
            if kind == "silo" and memory.siloDetails then
                memory.buildText = "Buduje silos: cel " .. tostring(memory.siloDetails.target) .. ", potrzeba " .. memory.siloDetails.required .. " slotow"
            end
            memory.buildDetails = {kind = kind, tile = best, cost = cost, score = bestScore,
                buildTicks = buildTicks, estimatedFrontArrivalTicks = bestSafety < math.huge and bestSafety or nil,
                newFortCoverage = bestCoverage, silo = kind == "silo" and memory.siloDetails or nil,
                economy = memory.economyDetails, priority = planReasons[kind] or (urgentOnly and "realne zagrozenie" or "plan strategiczny"),
                frontModel = (kind == "defense" or kind == "sam") and "observed_plus_source_speed" or nil,
                frontPolicy = "local_edge_and_learning", defenseAgainst = kind == "defense" and bestEnemy or nil}
            return {type = "build", kind = kind, tile = best}, memory.buildText, "build"
        end
    end
    if urgentOnly and activeGroundThreat then return Auto.arsenalBuildPlan(s, scan, cfg, memory, ctx, true) end
    return nil
end

function Auto.counterWave(s, cfg, ctx)
    s.combatMemory = s.combatMemory or {}
    local wave = s.combatMemory.counterWave
    if ctx.totalIncoming <= 0 then
        if wave and s.tick - wave.lastThreatTick > cfg.CounterWaveRestTicks then s.combatMemory.counterWave = nil end
        return s.combatMemory.counterWave
    end
    local home = s.owners[s.local_owner].troops
    if not wave then
        wave = {resources = home, spent = 0, startedTick = s.tick, lastThreatTick = s.tick}
        s.combatMemory.counterWave = wave
    end
    -- Recoveries add capacity only when the current army plus prior counter spending grows.
    -- Ground losses never shrink the remembered reserve floor for this attack wave.
    wave.resources = math.max(wave.resources, home + wave.spent)
    wave.lastThreatTick = s.tick
    return wave
end
function Auto.commitCounter(s, details, cfg)
    local wave = s.combatMemory and s.combatMemory.counterWave
    if not wave or not details then return nil end
    wave.spent += details.amount
    cfg = cfg or Auto.Defaults
    local foe = s.owners[details.target]
    if cfg.AutoCounterRecovery and foe and foe.kind == 2 and wave.spent >= math.max(1000, wave.resources * cfg.CounterRecoveryShare) then
        local old = s.combatMemory.offensiveRecovery
        local recovery = {untilTick = math.max(old and old.untilTick or 0, s.tick + cfg.CounterRecoveryTicks),
            lastCounterTick = s.tick, target = details.target, spentShare = wave.spent / math.max(wave.resources, 1),
            reason = "kosztowne kontry; odbudowa armii"}
        s.combatMemory.offensiveRecovery = recovery
        return recovery
    end
    return nil
end
function Auto.counterPlan(s, scan, cfg, memory, ctx, now)
    memory.counterDetails = nil
    if ctx.totalIncoming <= 0 then Auto.counterWave(s, cfg, ctx); memory.counterText = nil; return nil end
    if not cfg.AutoCounter then memory.counterText = "Kontra OFF w ustawieniach"; return nil end
    local wave = Auto.counterWave(s, cfg, ctx)
    if now - (memory.counter or -math.huge) < cfg.CounterGap then
        memory.counterText = "Kontra: krotka przerwa po rozkazie"; return nil
    end
    local me, mine = s.local_owner, s.owners[s.local_owner]
    local incomingCount = 0; for _ in pairs(ctx.incoming) do incomingCount += 1 end
    local reserveFraction = if ctx.criticalLoss then cfg.CounterEmergencyReserve else cfg.CounterReserve
    if incomingCount > 1 then reserveFraction = math.max(reserveFraction, 0.45) end
    local reserve = math.ceil(math.max(mine.troops * reserveFraction, wave.resources * cfg.CounterWaveReserve))
    local available = math.max(0, math.floor(math.min(mine.troops - reserve, mine.troops * cfg.CounterMaxShare)))
    local waveShare = if ctx.criticalLoss then cfg.CounterEmergencyWaveShare else cfg.CounterWaveShare
    local waveLimit = math.floor(wave.resources * waveShare)
    local waveRemaining = math.max(0, waveLimit - wave.spent)
    local best, details, bestScore, blocked
    for enemy, a in pairs(ctx.incoming) do
        local foe = s.owners[enemy]
        if not foe or not foe.alive or friendly(s, me, enemy) then continue end
        if foe.kind == 2 and not cfg.AttackHumans then blocked = "wylaczone atakowanie graczy"; continue end
        if (s.observed_shield or {})[enemy] and s.observed_shield[enemy] > s.tick then blocked = "ochrona celu"; continue end
        local border = (scan.borders or {})[enemy]
        local attackPoint = if onMap(s, a.anchor_tile) then a.anchor_tile elseif border then border.ownTile else nil
        local covered = attackPoint and Auto.defenseAt(s, me, attackPoint)
        if covered and not ctx.losing and a.troops <= mine.troops * 0.75 then
            blocked = "fort trzyma front, nie tracimy pol"; continue
        end
        -- A counter spends home troops cancelling the incoming attack 1:1 before creating a new attack.
        -- Do not deliberately overshoot: that would leave a separate offensive expedition.
        local fullStop = a.troops <= available
        local budget = if fullStop then available else math.min(available, waveRemaining)
        local amount = math.floor(math.min(a.troops, budget))
        local minimum = math.max(1000, math.ceil(mine.troops * 0.01))
        if amount < minimum then
            blocked = if waveRemaining < minimum then "wykorzystany budzet tej fali; odbudowa armii" else "chroni rezerwe zapamietana dla tej fali"
            continue
        end
        if not fullStop and amount < a.troops * cfg.CounterMinPartialShare then
            blocked = "czesciowa kontra bylaby za mala; zachowuje wojsko"; continue
        end
        local front = scan.fronts[enemy] or (scan.falloutFronts or {})[enemy]
        local tile = front and owner(s, front.tile) == enemy and front.tile or nil
        if not tile and onMap(s, foe.spawn_tile) and owner(s, foe.spawn_tile) == enemy then tile = foe.spawn_tile end
        if not tile then for _, b in pairs(s.structures) do if b.owner == enemy and owner(s, b.tile) == enemy then tile = b.tile; break end end end
        if not tile then
            for i = 0, s.map.land_count - 1 do
                local t = buffer.readi32(s.map.land_list, i * 4)
                if owner(s, t) == enemy then tile = t; break end
            end
        end
        if not tile then blocked = "brak aktualnego pola przeciwnika"; continue end
        local score = a.troops / math.max(mine.troops, 1) + (ctx.territory.attackers[enemy] or 0) / math.max(mine.tiles, 1) * 20
        if not bestScore or score > bestScore then
            bestScore = score; best = {type = "attack", tile = tile, ratio = amount / mine.troops}
            details = {amount = amount, counter = true, target = enemy, incoming = a.troops, expectedCancelled = amount,
                homeReserve = mine.troops - amount, reserveFraction = reserveFraction, partial = amount < a.troops,
                border = front ~= nil, mechanism = "cancel_incoming_1_to_1", waveResources = wave.resources,
                waveSpentBefore = wave.spent, waveLimit = waveLimit, waveRemaining = waveRemaining,
                rememberedReserve = reserve, fullStop = fullStop, waveLimitException = fullStop and amount > waveRemaining}
        end
    end
    if best then
        memory.counterDetails, memory.armyDetails = details, details
        memory.counterText = "Kontra " .. s.owners[details.target].name .. ": kasuje do " .. details.amount .. " atakujacych, rezerwa " .. math.floor(details.homeReserve)
        return best, memory.counterText, "counter"
    end
    memory.counterText = "Kontra wstrzymana: " .. (blocked or "brak aktywnego przeciwnika")
    return nil
end

function Auto.offensiveRisk(s, cfg, enemy)
    local mine, foe = s.owners[s.local_owner], s.owners[enemy]
    if not cfg.AvoidStrongerEconomies or not foe or foe.kind ~= 2 then return true end
    -- A depleted home army can hide a much larger country's ability to return troops and retaliate.
    if foe.max_troops >= mine.max_troops * 2.5 and foe.tiles >= mine.tiles * 1.75 and foe.max_troops >= mine.troops * 3 then
        return false, "przeciwnik ma znacznie wieksze zaplecze do odwetu", {
            ourCap = mine.max_troops, theirCap = foe.max_troops, ourTiles = mine.tiles, theirTiles = foe.tiles,
            ourHome = mine.troops, theirHome = foe.troops}
    end
    return true
end
function Auto.newWarAllowed(s, scan, cfg, ctx, enemy)
    local mine, foe = s.owners[s.local_owner], s.owners[enemy]
    if ctx.recoveringOffense then return false, "odbudowa armii po kosztownych kontrach" end
    local safe, reason, risk = Auto.offensiveRisk(s, cfg, enemy)
    if not safe then return false, reason, nil, nil, risk end
    if not cfg.ProtectEconomicOpening or not foe or foe.kind ~= 2 or ctx.wars[enemy] then return true end
    if foe.tiles < mine.tiles * 0.25 or foe.troops < mine.troops * 0.35 and foe.max_troops < mine.max_troops * 0.60 then return true end
    local infra = Auto.infrastructure(s)
    local economy = Auto.economyPriorities(s, scan, cfg, infra)
    local front = scan.fronts and scan.fronts[enemy]
    if economy.needsFoundation and front and not ctx.defending and infra.cityLevels >= 1 and (infra.portLevels > 0 or infra.factoryLevels > 0)
        and mine.troops >= mine.max_troops * cfg.Ready and foe.troops < mine.troops * 0.35
        and not Auto.defenseAt(s, enemy, front.tile) then
        local plan = Auto.attackPlan(s, front, enemy, cfg, ctx, 200)
        if plan and plan.seconds <= 8 and plan.amount <= mine.troops * 0.25 then
            local growth = math.min(math.max(0, foe.max_troops - foe.troops), troopRate(foe) * plan.seconds * 10)
            local fullArmy = mine.troops >= mine.max_troops * 0.90 and foe.troops + growth <= mine.troops * 0.50
            local overwhelming = foe.troops + growth <= mine.troops * 0.15 and plan.amount <= mine.troops * 0.15
            if fullArmy or overwhelming then
                return true, (if overwhelming then "krotka okazja: duza przewaga" else "krotka okazja przy pelnej armii"), {projectedDefenders = foe.troops + growth,
                    sentShare = plan.amount / mine.troops, expectedSeconds = plan.seconds, overwhelming = overwhelming}, plan
            end
        end
    end
    if economy.needsFoundation then return false, "brakuje podstawowego zaplecza; najpierw gospodarka" end
    if mine.gold < cfg.GoldReserve and foe.troops >= mine.troops * 0.75 then return false, "za malo zlota na nowa duza wojne" end
    return true
end
function Auto.decide(s, scan, cfg, memory, now)
    local me, info = s.local_owner, s.owners[s.local_owner]
    if not info or not info.alive or not info.spawned or s.phase ~= 1 then return nil end
    memory.armyDetails, memory.buildDetails, memory.nukeDetails, memory.navalDetails, memory.arsenalDetails = nil, nil, nil, nil, nil
    local ctx = Auto.context(s, scan, cfg)
    memory.analysis = ctx
    local infra = Auto.infrastructure(s)
    local economy = Auto.economyPriorities(s, scan, cfg, infra)
    memory.infrastructure = infra
    memory.offenseBlocked = nil
    memory.navalText = "Morze: " .. #ctx.navy.warships .. " wrogich bojowych; nasze " .. #ctx.navy.ownWarships .. "; " .. #ctx.navy.transports .. " transportow"
    memory.worldText = "Mapa / 5 s: +" .. ctx.territory.gained .. " / -" .. ctx.territory.lost .. "; swiat " .. ctx.territory.changed .. " zmian"
        .. "\nMiasta " .. (infra.counts[0] or 0) .. " (lvl " .. infra.cityLevels .. "), porty " .. infra.portLevels .. ", fabryki " .. infra.factoryLevels
        .. ", forty " .. infra.forts .. " (pokoj: max " .. economy.peaceFortLimit .. ")"
    if ctx.defending then
        memory.armyText = if ctx.totalIncoming > 0 or ctx.losing then
            "OBRONA: -" .. ctx.territory.lost .. " pol / 5 s, atakuje " .. math.floor(ctx.totalIncoming) .. "; rezerwa " .. math.floor(ctx.reserve)
            else "Gotowosc po stratach: odbudowa armii, brak aktywnego ataku"
    else
        memory.armyText = (if info.troops < ctx.reserve then "Odbudowa armii: " else "Armia: ")
            .. math.floor(info.troops) .. " / " .. math.floor(info.max_troops) .. "; rezerwa " .. math.floor(ctx.reserve)
    end
    if ctx.recoveringOffense then
        memory.offenseBlocked = {target = ctx.offensiveRecovery.target, reason = ctx.offensiveRecovery.reason,
            untilTick = ctx.offensiveRecovery.untilTick}
        if not ctx.defending then memory.armyText = "Odbudowa po kontrach: do " .. math.ceil((ctx.offensiveRecovery.untilTick - s.tick) / 10)
            .. " s; armia " .. math.floor(info.troops) .. " / " .. math.floor(info.max_troops) end
    end
    memory.buildText = if now - (memory.build or -math.huge) < cfg.BuildGap then "Budowa: przerwa po rozkazie" else "Budowa: ocena potrzeb i budzetu"
    local command, why, bucket = Auto.reinforcementPlan(s, cfg, memory, ctx, now)
    if command then return command, why, bucket end
    command, why, bucket = Auto.counterPlan(s, scan, cfg, memory, ctx, now)
    if command then memory.armyText = why; return command, why, bucket end
    if memory.counterText then memory.armyText = memory.counterText end
    if ctx.criticalLoss or ctx.totalIncoming > info.troops * 0.65 then
        memory.retreats = memory.retreats or {}
        for _, attack in pairs(ctx.outgoing) do
            local defendingTarget = ctx.incoming[attack.target] ~= nil
                or (memory.defensiveTargets or {})[attack.target] and s.tick - memory.defensiveTargets[attack.target] < 100
            if not attack.retreating and not defendingTarget and now - (memory.retreats[attack.aid] or -math.huge) > 4 then
                memory.retreats[attack.aid] = now
                return {type = "retreat", attack_id = attack.aid}, "Wycofuje wyprawe: kraj traci teren, potrzebna obrona", "retreat"
            end
        end
    end
    local ready = now - (memory.attack or -math.huge) >= cfg.AttackGap
    if now - (memory.build or -math.huge) >= cfg.BuildGap then
        command, why, bucket = Auto.buildPlan(s, scan, cfg, memory, ctx, true)
        if command then return command, why, bucket end
    end
    command, why, bucket = Auto.warshipPlan(s, scan, cfg, memory, ctx, now, true)
    if command then return command, why, bucket end
    if now - (memory.strike or -math.huge) >= cfg.StrikeGap then
        command, why, bucket = Auto.strikePlan(s, cfg, memory, ctx)
        if command then return command, why, bucket end
    end
    command, why, bucket = Auto.diplomacy(s, scan, cfg, memory, ctx, now)
    if command then return command, why, bucket end
    if now - (memory.weapon or -math.huge) >= cfg.WeaponGap and now - (memory.weaponAnalysis or -math.huge) >= 3 then
        memory.weaponAnalysis = now
        command, why, bucket = Auto.nukePlan(s, scan, cfg, memory, ctx)
        if command then return command, why, bucket end
    end
    if ready and not ctx.defending and not ctx.recoveringOffense then
        for target, current in pairs(ctx.outgoing) do
            local front = scan.fronts[target]
            if target > 0 and front and not current.retreating then
                local safe, blocked, risk = Auto.offensiveRisk(s, cfg, target)
                if not safe then
                    memory.offenseBlocked = {target = target, reason = blocked, risk = risk}
                    memory.retreats = memory.retreats or {}
                    if now - (memory.retreats[current.aid] or -math.huge) >= 4 then
                        memory.retreats[current.aid] = now
                        return {type = "retreat", attack_id = current.aid}, "Wycofuje wyprawe: " .. blocked, "retreat"
                    end
                    continue
                end
                local plan = Auto.attackPlan(s, front, target, cfg, ctx)
                local extra = plan and math.floor(plan.amount - current.troops) or 0
                if extra >= math.max(1500, info.troops * 0.01, current.troops * 0.35) then
                    memory.armyText = "Uzupelnia atak: +" .. extra .. " wojska"
                    memory.armyDetails = {amount = extra, reinforce = true, attack = current.aid, current = current.troops, needed = plan.amount}
                    return {type = "attack", tile = front.tile, ratio = extra / info.troops}, memory.armyText, "attack"
                end
            end
        end
    end
    if ready and info.troops >= info.max_troops * cfg.Ready and not ctx.defending and not ctx.recoveringOffense then
        if not next(ctx.outgoing) and scan.fronts[0] then
            local plan = Auto.attackPlan(s, scan.fronts[0], 0, cfg, ctx)
            if plan then
                memory.armyText = "Ekspansja: " .. plan.amount .. ", rezerwa " .. math.floor(ctx.reserve)
                memory.armyDetails = plan
                return {type = "attack", tile = scan.fronts[0].tile, ratio = plan.amount / info.troops}, memory.armyText, "attack"
            end
        end
        if not next(ctx.outgoing) then
            local best, bestPlan, bestValue
            for enemy, front in pairs(scan.fronts) do
                if enemy == 0 then continue end
                local allowed, blocked, opening, openingPlan, risk = Auto.newWarAllowed(s, scan, cfg, ctx, enemy)
                if not allowed then memory.offenseBlocked = {target = enemy, reason = blocked, risk = risk}; memory.armyText = "Nowa wojna wstrzymana: " .. blocked; continue end
                local plan = openingPlan or Auto.attackPlan(s, front, enemy, cfg, ctx)
                if not plan then continue end
                plan.openingOpportunity = opening
                local activity = ctx.territory.actors[enemy]
                local busy = activity and activity.lost > activity.gained + 10
                local value = plan.goal / math.max(plan.amount, 1) * (if plan.protected then 0.7 else 1) * (if busy then 1.12 else 1)
                if not bestValue or value > bestValue then best, bestPlan, bestValue = front, plan, value end
            end
            if best then
                memory.armyText = "Atak: " .. bestPlan.amount .. ", rezerwa " .. math.floor(ctx.reserve)
                    .. (if bestPlan.protected then "; uwzgledniono fortyfikacje" else "")
                    .. (if bestPlan.openingOpportunity then (if bestPlan.openingOpportunity.overwhelming then "; krotka okazja: duza przewaga" else "; krotka okazja przy pelnej armii") else "")
                memory.armyDetails = bestPlan
                return {type = "attack", tile = best.tile, ratio = bestPlan.amount / info.troops}, memory.armyText, "attack"
            end
        end
        if not next(ctx.outgoing) and cfg.AllowFallout and scan.falloutFronts and scan.falloutFronts[0] then
            local front = scan.falloutFronts[0]
            local plan = Auto.attackPlan(s, front, 0, cfg, ctx)
            if plan then
                memory.armyText = "Odzyskuje fallout: " .. plan.amount .. " wojska (wyzszy koszt)"
                memory.armyDetails = plan
                return {type = "attack", tile = front.tile, ratio = plan.amount / info.troops}, memory.armyText, "attack"
            end
        end
    end
    if not ctx.criticalLoss then
        command, why, bucket = Auto.warshipPlan(s, scan, cfg, memory, ctx, now, false)
        if command then return command, why, bucket end
    end
    if now - (memory.build or -math.huge) >= cfg.BuildGap then
        command, why, bucket = Auto.buildPlan(s, scan, cfg, memory, ctx, false)
        if command then return command, why, bucket end
    end
    if cfg.AutoBoats and not next(ctx.outgoing) and not ctx.defending and not ctx.recoveringOffense and not scan.fronts[0]
        and info.troops >= info.max_troops * 0.60 and now - (memory.boat or -math.huge) >= cfg.BoatGap
        and s.tick >= (s.boatBackoff or 0) then
        local own = 0; for _, u in pairs(s.units) do if u.owner == me and u.kind == 0 then own += 1 end end
        if own < 2 then return Auto.landing(s, scan, cfg, memory, ctx) end
    end
    return nil
end


-- Kept here so the exact client request pair can also be tested offline against Rewards.
function Auto.rewardRequests(send, op, mapId)
    send(op.ANALYTICS, "match_start", "solo2", mapId or "World")
end
function Auto.rewardResult(send, op)
    send(op.SOLO_RESULT, {
        spawned = true, left = false, won = false, minutes = 0,
        shares = 0, kills = 0, place = 1, field = 1,
    })
end
function Auto.endRewardReport(send, op)
    send(op.ANALYTICS, "left", 0)
end

function Auto.donationRequest(target)
    return { type = "donate", target = target, troops = 2000000000 }
end

-- Independent Xeno reader: no Core.GameState, Core.WorldMap or Core.Rules require.
local function adjacent(m, t, d)
    if d == 1 then return if t % m.W > 0 then t - 1 else -1 end
    if d == 2 then return if t % m.W < m.W - 1 then t + 1 else -1 end
    if d == 3 then return if t >= m.W then t - m.W else -1 end
    return if t < m.N - m.W then t + m.W else -1
end
function Auto.mapFromBytes(raw, meta, w, h, yieldFn)
    local m = {W = w, H = h, N = w * h, id = meta.id, k_lin = (meta.k_lin or 1) * meta.width / w}
    local N = m.N
    local bytes = buffer.create(N)
    for y = 0, h - 1 do
        if y % 64 == 0 and yieldFn then yieldFn() end
        local sy = math.min(meta.height - 1, math.floor((y + 0.5) * meta.height / h))
        for x = 0, w - 1 do
            local sx = math.min(meta.width - 1, math.floor((x + 0.5) * meta.width / w))
            buffer.writeu8(bytes, y * w + x, buffer.readu8(raw, sy * meta.width + sx))
        end
    end
    m.tile_bytes, m.land, m.terrain = bytes, buffer.create(N), buffer.create(N)
    m.coastal, m.coast_body, m.water_body = buffer.create(N), buffer.create(N * 2), buffer.create(N * 2)
    local landCount = 0
    for t = 0, N - 1 do
        if t % 65536 == 0 and yieldFn then yieldFn() end
        local b, terrain = buffer.readu8(bytes, t), 0
        if b < 128 then terrain = if bit32.band(b, 32) ~= 0 then 0 else 1
        elseif b == 159 then terrain = 6
        else
            local mag = bit32.band(b, 31)
            terrain = if mag < 10 then 2 elseif mag < 20 then 3 else 4
            buffer.writeu8(m.land, t, 1); landCount += 1
        end
        buffer.writeu8(m.terrain, t, terrain)
    end
    local queue, nextBody, ocean = buffer.create(N * 4), 2, false
    for t = 0, N - 1 do
        if t % 65536 == 0 and yieldFn then yieldFn() end
        if buffer.readu8(bytes, t) >= 128 or buffer.readu16(m.water_body, t * 2) ~= 0 then continue end
        local body = nextBody
        if not ocean and bit32.band(buffer.readu8(bytes, t), 32) ~= 0 then body, ocean = 1, true
        else nextBody += 1 end
        assert(body <= 65535, "Za duzo akwenow")
        local first, last = 0, 1
        buffer.writei32(queue, 0, t); buffer.writeu16(m.water_body, t * 2, body)
        while first < last do
            if first % 65536 == 0 and yieldFn then yieldFn() end
            local cell = buffer.readi32(queue, first * 4); first += 1
            for d = 1, 4 do
                local n = adjacent(m, cell, d)
                if n >= 0 and buffer.readu8(bytes, n) < 128 and buffer.readu16(m.water_body, n * 2) == 0 then
                    buffer.writeu16(m.water_body, n * 2, body)
                    buffer.writei32(queue, last * 4, n); last += 1
                end
            end
        end
    end
    m.land_list = buffer.create(landCount * 4)
    local li, nc = 0, 0
    for t = 0, N - 1 do
        if t % 65536 == 0 and yieldFn then yieldFn() end
        if buffer.readu8(m.land, t) == 0 then continue end
        buffer.writei32(m.land_list, li * 4, t); li += 1
        for d = 1, 4 do
            local n = adjacent(m, t, d)
            if n >= 0 and buffer.readu8(bytes, n) < 128 then
                buffer.writeu8(m.coastal, t, 1)
                buffer.writeu16(m.coast_body, t * 2, buffer.readu16(m.water_body, n * 2))
                buffer.writei32(queue, nc * 4, t); nc += 1; break
            end
        end
    end
    m.coast_list = buffer.create(nc * 4)
    buffer.copy(m.coast_list, 0, queue, 0, nc * 4)
    m.land_count, m.coast_count, m.contestable_count = landCount, nc, landCount
    m.range_d2 = function(a, b)
        return (a % w - b % w)^2 + (a // w - b // w)^2
    end
    return m
end

local function event()
    local e = {listeners = {}}
    function e:Connect(fn)
        local c = {Connected = true}
        function c:Disconnect() self.Connected = false end
        self.listeners[c] = fn
        return c
    end
    function e:Fire(...)
        for c, fn in pairs(self.listeners) do
            if c.Connected then fn(...) else self.listeners[c] = nil end
        end
    end
    return e
end
local function rawRules(map)
    local R = {K_LIN = map.k_lin, ROAD_MAX_TILES = 110 / map.k_lin, SILO_COOLDOWN_TICKS = 90}
    local kinds = {city = 0, port = 1, factory = 2, defense = 3, sam = 4, silo = 5, artillery = 6, airfield = 7, railgun = 8}
    function R.nuke_cost(kind, launched)
        local price = {atom = 750000, hydrogen = 5000000, mega = 2500000, scatter = 3750000, airstrike = 0, slug = 0}
        return price[kind] or (if kind == "mirv" then 25000000 + 15000000 * (launched or 0) else -1)
    end
    function R.cost_of(s, id, name)
        local wanted, count = kinds[name], 0
        local levels = {}
        for _, b in pairs(s.structures) do
            if b.owner == id then levels[b.kind] = (levels[b.kind] or 0) + b.level end
        end
        local built = s.built[id] or {}
        if name == "warship" then
            local ships = 0; for _, u in pairs(s.units) do if u.owner == id and u.kind == 2 then ships += 1 end end
            return math.min(1000000, 250000 * (math.min(ships, built[15] or 0) + 1))
        elseif wanted == nil then return -1
        elseif wanted == 1 or wanted == 2 then
            count = math.min(levels[1] or 0, built[1] or 0) + math.min(levels[2] or 0, built[2] or 0)
        else count = math.min(levels[wanted] or 0, built[wanted] or 0) end
        if wanted == 3 then return math.min(250000, 50000 * (count + 1)) end
        if wanted == 4 then return math.min(3000000, 1500000 * (count + 1)) end
        if wanted == 5 then return 1000000 end
        if wanted == 6 then return math.min(750000, 150000 * (count + 1)) end
        if wanted == 7 then return math.min(1500000, 500000 * (count + 1)) end
        if wanted == 8 then return math.min(7500000, 2500000 * (count + 1)) end
        return math.min(1000000, 125000 * 2 ^ math.min(count, 4))
    end
    function R.placement(s, id, name, t)
        local no = {ok = false, tile = -1}
        if t < 0 or t >= s.N or owner(s, t) ~= id then return no end
        local kind, radius2 = kinds[name], (15 / map.k_lin)^2
        local closest, closestD = nil, math.huge
        for _, b in pairs(s.structures) do
            local d = map.range_d2(t, b.tile)
            if b.kind == kind and d <= radius2 and d < closestD then closest, closestD = b, d end
        end
        if kind == nil then return no end
        if kind ~= 3 and kind < 6 and closest and closest.owner == id and closest.active_tick <= s.tick then
            return {ok = true, tile = closest.tile, upgrade_sid = closest.sid}
        end
        if kind == 1 and buffer.readu8(map.coastal, t) == 0 then return no end
        for _, b in pairs(s.structures) do if map.range_d2(t, b.tile) < radius2 then return no end end
        return {ok = true, tile = t, upgrade_sid = 0}
    end
    return R
end

local function rawOwner(id, name, kind, team)
    return {id = id, name = name or "?", kind = kind or 0, team = team or 0, alive = true,
        spawned = false, spawn_tile = -1, troops = 0, gold = 0, max_troops = 0, tiles = 0, traitor_until = 0}
end
local function rawStruct(s, row, offset)
    local b = {sid = row[offset + 1], kind = row[offset + 2], owner = row[offset + 3],
        tile = row[offset + 4], level = row[offset + 5] or 1, active_tick = row[offset + 6] or s.tick,
        shots = row[offset + 7] or {}}
    s.structures[b.sid] = b
    return b
end
local function rawAttack(s, row, offset)
    local a = {aid = row[offset + 1], attacker = row[offset + 2], target = row[offset + 3],
        troops = row[offset + 4], anchor_tile = row[offset + 5], retreating = row[offset + 6] == true}
    local old = s.attacks[a.aid]
    a.first_seen_tick = old and old.first_seen_tick or s.tick
    if old and a.troops > old.troops * 1.2 and a.troops - old.troops > 10000 then a.first_seen_tick = s.tick end
    s.attacks[a.aid] = a
    if a.target == s.local_owner then Auto.rememberAggressor(s, a.attacker) end
    return a
end
local function rawNuke(s, row, offset)
    local n = {uid = row[offset + 1], kind = row[offset + 2], owner = row[offset + 3],
        from_tile = row[offset + 4], to_tile = row[offset + 5], launch_tick = row[offset + 6], flight_ticks = row[offset + 7]}
    s.nukes[n.uid] = n
    if onMap(s, n.to_tile) and owner(s, n.to_tile) == s.local_owner then Auto.rememberAggressor(s, n.owner) end
    return n
end
local function rawUnit(s, row, offset)
    local u = {uid = row[offset + 1], kind = row[offset + 2], owner = row[offset + 3],
        path = row[offset + 4] or {}, start_tick = row[offset + 5] or s.tick,
        ticks_per_tile_x100 = row[offset + 6] or 100, troops = row[offset + 7] or 0,
        hp = row[offset + 8] or 0, max_hp = row[offset + 9] or 0, veterancy = row[offset + 10] or 0,
        state = row[offset + 11] or 0, patrol_tile = row[offset + 12] or -1, prev_tile = -1, move_tick = s.tick}
    s.units[u.uid] = u
    if u.kind == 0 then
        local last = u.path[#u.path]
        if last and onMap(s, last) then
            neighbors(s, last, function(t) if owner(s, t) == s.local_owner then Auto.rememberAggressor(s, u.owner) end end)
        end
    end
end
function Auto.gameMessage(s, to, category, message)
    if to ~= -1 and to ~= s.local_owner then return end
    local text = tostring(message)
    s.recentMessages = s.recentMessages or {}
    table.insert(s.recentMessages, {tick = s.tick, category = category, text = text})
    if #s.recentMessages > 20 then table.remove(s.recentMessages, 1) end
    if text:find("was intercepted by", 1, true) then s.weaponBackoff = s.tick + 100 end
    if text == "Too many transports at sea" or text == "No sea route to that coast" then s.boatBackoff = s.tick + 100 end
    if text:find("Not enough gold for ", 1, true) == 1 then s.buildBackoff = s.tick + 30 end
    if text == "You can only build on your own land" then s.mapRevision = (s.mapRevision or 0) + 1; s.buildBackoff = s.tick + 5 end
    local attackerName = text:match("^(.-) is attacking you!") or text:match("^(.-) is counter%-attacking you!")
        or text:match("^(.-) landed troops on your coast!") or text:match("^(.-)'s warships are capturing your trade ships")
    if attackerName then
        for id, o in pairs(s.owners) do if o.name == attackerName then Auto.rememberAggressor(s, id) end end
    end
    local wait = text:match("Reinforcements are ready in (%d+) s")
    if wait then s.reinforceReady = s.tick + tonumber(wait) * 10 end
    if text:find("Unlock ", 1, true) == 1 and s.equipment then
        for _, item in ipairs(Auto.EquipmentItems) do
            if text:find(item.title, 1, true) or item.key == "airfield" and text:find("Airfield", 1, true) then
                s.equipment.blocked[item.key] = true
            end
        end
    end
end
local function builtAdd(s, id, kind, n)
    s.built[id] = s.built[id] or {}
    s.built[id][kind] = (s.built[id][kind] or 0) + (n or 1)
end
function Auto.rawState(snap, map, localId, yieldFn)
    local s = {map = map, map_id = snap.map_id, W = map.W, H = map.H, N = map.N,
        local_owner = localId, tick = snap.t or 0, phase = snap.phase or 0, playing_since = snap.playing_since or -1,
        loaded = true, owner = snap.owner, flags = snap.flags, owners = {}, structures = {},
        built = {}, alliances = {}, alliance_expires = {}, alliance_ext = {}, requests = {}, recentBetrayal = {},
        betrayers = {}, aggressors = {}, territory = {buckets = {}, gained = 0, lost = 0}, mapRevision = 0,
        structureRevision = 0, explosions = {},
        recentMessages = {}, units = {}, attacks = {}, nukes = {}, fallout_count = 0, mirvs_launched = snap.mirvs_launched or 0}
    Auto.observeSpawnPhase(s, s.phase, snap.phase_left)
    s.rules = rawRules(map)
    for _, key in ipairs({"owner_spawned", "phase_changed", "attack_started", "nuke_launched"}) do s[key] = event() end
    for _, row in ipairs(snap.owners or {}) do
        local o = rawOwner(row[1], row[2], row[4], row[5])
        o.alive, o.troops, o.gold, o.max_troops = row[6] == true, row[8], row[9], row[10]
        o.spawn_tile, o.spawned = row[13], row[13] >= 0
        o.traitor_until = row[12] or 0
        if o.traitor_until > 0 then s.betrayers[o.id] = math.max(0, o.traitor_until - 300) end
        s.owners[o.id] = o
    end
    for t = 0, s.N - 1 do
        if t % 65536 == 0 and yieldFn then yieldFn() end
        local o = s.owners[owner(s, t)]
        if o then o.tiles += 1 end
        if bit32.band(buffer.readu8(s.flags, t), 1) ~= 0 then s.fallout_count += 1 end
    end
    for _, row in ipairs(snap.built or {}) do
        s.built[row[1]] = {}
        for k = 0, 15 do s.built[row[1]][k] = row[k + 2] or 0 end
    end
    for _, row in ipairs(snap.allies or {}) do
        local key = math.min(row[1], row[2]) * 1024 + math.max(row[1], row[2])
        s.alliances[key], s.alliance_expires[key], s.alliance_ext[key] = true, row[3] or (s.tick + 3000), row[4] or 0
    end
    for _, row in ipairs(snap.structs or {}) do rawStruct(s, row, 0) end
    for _, row in ipairs(snap.attacks or {}) do rawAttack(s, row, 0) end
    for _, row in ipairs(snap.nukes or {}) do rawNuke(s, row, 0) end
    for _, row in ipairs(snap.units or {}) do rawUnit(s, row, 0) end
    for _, row in ipairs(snap.requests or {}) do s.requests[row[1] * 1024 + row[2]] = row[3] end
    function s:built_count(id, kind) return (self.built[id] or {})[kind] or 0 end
    function s:struct_level_sum(id, kind)
        local n = 0; for _, b in pairs(self.structures) do if b.owner == id and b.kind == kind then n += b.level end end
        return n
    end
    function s:count_units(id, kind)
        local n = 0; for _, u in pairs(self.units) do if u.owner == id and u.kind == kind then n += 1 end end
        return n
    end
    function s:are_allies(a, b)
        local oa, ob = self.owners[a], self.owners[b]
        return self.alliances[math.min(a, b) * 1024 + math.max(a, b)] == true
            or (oa and ob and oa.team > 0 and oa.team == ob.team) or false
    end
    function s:borders_tile(id, t)
        for d = 1, 4 do local n = adjacent(self.map, t, d); if n >= 0 and owner(self, n) == id then return true end end
        return false
    end
    function s:apply_delta(delta)
        self.tick = delta.t
        -- Preserve the pre-change values before deltas remove buildings or change land ownership.
        local frame = {tiles = {}, flags = {}, structures = {}, units = {}, booms = {}}
        for _, e in ipairs(delta.ev or {}) do if e[1] == 13 then table.insert(frame.booms, e) end end
        local keepEffects = #frame.booms > 0
        if keepEffects then
            for _, e in ipairs(delta.ev or {}) do
                local b, u = self.structures[e[2]], self.units[e[2]]
                if b and (e[1] == 5 or e[1] == 6 or e[1] == 23 and e[3] < b.level) then
                    table.insert(frame.structures, {sid = b.sid, tile = b.tile, kind = b.kind, owner = b.owner, level = b.level,
                        event = e[1], newOwner = e[1] == 5 and e[3] or nil, newLevel = e[1] == 23 and e[3] or nil})
                elseif u and e[1] == 11 then
                    local path = u.path or {}
                    local index = math.clamp(math.floor(math.max(0, self.tick - (u.start_tick or self.tick)) * 100 / math.max(1, u.ticks_per_tile_x100 or 100)) + 1, 1, math.max(1, #path))
                    table.insert(frame.units, {uid = u.uid, kind = u.kind, owner = u.owner,
                        tile = if u.kind == 2 and (u.prev_tile or -1) >= 0 then path[1] or -1 else path[index] or -1, reason = e[3]})
                end
            end
        end
        for _, packed in ipairs(delta.tiles or {}) do
            local t, id = packed // 1024, packed % 1024
            local old = owner(self, t)
            if keepEffects and old ~= id then table.insert(frame.tiles, {tile = t, from = old, to = id}) end
            Auto.recordMapChange(self, t, old, id)
            if id > 0 and not self.owners[id] then self.owners[id] = rawOwner(id) end
            if self.owners[old] then self.owners[old].tiles -= 1 end
            if self.owners[id] then self.owners[id].tiles += 1 end
            buffer.writei32(self.owner, t * 4, id)
        end
        for _, packed in ipairs(delta.flags or {}) do
            local tile, flags = packed // 256, packed % 256
            local before = bit32.band(buffer.readu8(self.flags, tile), 1) ~= 0
            local after = bit32.band(flags, 1) ~= 0
            if keepEffects and before ~= after then table.insert(frame.flags, {tile = tile, before = before, after = after}) end
            if before ~= after then self.fallout_count += if after then 1 else -1 end
            buffer.writeu8(self.flags, tile, flags)
        end
        local stats = delta.stats or {}
        for i = 1, #stats, 6 do
            local o = self.owners[stats[i]]
            if o then o.troops, o.gold, o.max_troops = stats[i + 2], stats[i + 3], stats[i + 4] end
        end
        for _, e in ipairs(delta.ev or {}) do
            local kind, id = e[1], e[2]
            if kind == 0 then
                local o = self.owners[id] or rawOwner(id)
                o.name, o.kind, o.team, o.alive = e[3], e[5], e[6] or 0, true
                self.owners[id] = o
            elseif kind == 1 then if self.owners[id] then self.owners[id].alive = false end
            elseif kind == 2 then
                self.phase = id
                Auto.observeSpawnPhase(self, id, e[3])
                if id == 1 and self.playing_since < 0 then self.playing_since = self.tick end
                self.phase_changed:Fire(id, e[3])
            elseif kind == 3 then
                local o = self.owners[id]
                if o then o.spawned, o.spawn_tile = true, e[3] end
                self.spawnRevision = (self.spawnRevision or 0) + 1
                self.owner_spawned:Fire(id, e[3])
            elseif kind == 4 then
                local b = rawStruct(self, {e[2], e[3], e[4], e[5], 1, self.tick}, 0)
                builtAdd(self, b.owner, b.kind)
            elseif kind == 5 then if self.structures[id] then self.structures[id].owner = e[3] end
            elseif kind == 6 then self.structures[id] = nil
            elseif kind == 9 then rawUnit(self, e, 1); if e[3] == 2 then builtAdd(self, e[4], 15) end
            elseif kind == 10 then
                local u = self.units[id]
                if u then u.prev_tile = u.path[1] or -1; u.path = {e[3]}; u.move_tick = self.tick end
            elseif kind == 11 then self.units[id] = nil
            elseif kind == 12 then
                local n = rawNuke(self, e, 1)
                if n.kind == 2 then self.mirvs_launched += 1 end
                if n.kind < 6 and Auto.nukeThreatensUs(self, n) then self.nuclearAlert = self.tick end
                self.nuke_launched:Fire(id)
            elseif kind == 13 then Auto.recordExplosion(self, e, frame); self.nukes[id] = nil
            elseif kind == 14 then
                local existed = self.attacks[id] ~= nil
                rawAttack(self, e, 1)
                if not existed then self.attack_started:Fire(id) end
            elseif kind == 15 then self.attacks[id] = nil
            elseif kind == 16 then self.requests[id * 1024 + e[3]] = e[4] or self.tick
            elseif kind == 17 then
                local key = math.min(id, e[3]) * 1024 + math.max(id, e[3])
                self.alliances[key], self.alliance_expires[key], self.alliance_ext[key] = true, e[4] or self.tick + 3000, 0
                self.requests[id * 1024 + e[3]], self.requests[e[3] * 1024 + id] = nil, nil
            elseif kind == 18 then
                self.alliances[math.min(id, e[3]) * 1024 + math.max(id, e[3])] = nil
                if (e[4] or 0) > 0 then self.recentBetrayal[e[4]], self.betrayers[e[4]] = self.tick, self.tick end
            elseif kind == 19 then Auto.gameMessage(self, id, e[3], e[4])
            elseif kind == 20 then self.phase = 2
            elseif kind == 21 then self.requests[id * 1024 + e[3]] = nil
            elseif kind == 22 then
                if self.owners[id] then self.owners[id].traitor_until = e[3] end
                if e[3] > 0 then self.betrayers[id] = self.betrayers[id] or self.tick end
            elseif kind == 23 then
                local b = self.structures[id]
                if b then
                    if e[3] > b.level then
                        builtAdd(self, b.owner, b.kind, e[3] - b.level)
                        if b.kind == 4 then b.range_ready_tick = self.tick + 45 end
                    end
                    b.level, b.active_tick = e[3], e[4]
                end
            elseif kind == 25 then if self.units[id] then self.units[id].hp, self.units[id].max_hp = e[3], e[4] end
            elseif kind == 26 then if self.units[id] then self.units[id].veterancy = e[3] end
            elseif kind == 27 then if self.units[id] then self.units[id].state, self.units[id].patrol_tile = e[3], e[4] end
            elseif kind == 28 then
                local u = self.units[id]
                if u then u.path, u.start_tick, u.ticks_per_tile_x100, u.prev_tile = e[3], e[4], e[5], -1 end
            elseif kind == 30 then
                local key = math.min(id, e[3]) * 1024 + math.max(id, e[3])
                self.alliance_expires[key], self.alliance_ext[key] = e[4], e[5] or 0
            elseif kind == 32 then if self.structures[id] then self.structures[id].shots = e[3] end
            elseif kind == 33 and id == self.local_owner then self.reinforceReady = e[4]
            end
            if kind == 4 or kind == 5 or kind == 6 or kind == 23 then self.mapRevision += 1; self.structureRevision += 1 end
            if self.eventObserver then self.eventObserver(e) end
        end
    end
    return s
end

-- In the Luau CLI this file exports the pure policy for offline regression tests.
if game == nil then return Auto end

local env = if type(getgenv) == "function" then getgenv() else getfenv(0)
local previous = env.RoWorldAuto
local recoverOldReport = type(previous) == "table" and previous.LastProbe ~= nil
if type(env.RoWorldAuto) == "table" and type(env.RoWorldAuto.Stop) == "function" then
    pcall(env.RoWorldAuto.Stop)
end
local cfg = Auto.settings(env.RoWorldAutoConfig)
if type(env.RoWorldEquipmentModes) == "table" then
    for key, mode in pairs(env.RoWorldEquipmentModes) do cfg.EquipmentModes[key] = mode end
end
local equipment = Auto.newEquipment()
local matchHistory = type(previous) == "table" and previous.MatchHistory or nil
local controller = {
    Config = cfg, Enabled = false, Alive = true, Probe = false, LastProbe = nil,
    DonationEnabled = false, DonationSent = 0, TargetId = nil, Equipment = equipment,
}
local log = Auto.newLog(cfg.LogCapacity)
controller.Log = log
local learningProfile = Auto.newLearning(env.RoWorldLearningProfile or (type(previous) == "table" and previous.LearningProfile))
if type(env.RoWorldLearningProfile) ~= "table" and type(readfile) == "function" then
    local ok, loaded = pcall(function() return game:GetService("HttpService"):JSONDecode(readfile("RoWorldLearning_v1.json")) end)
    if ok then learningProfile = Auto.newLearning(loaded) end
end
controller.LearningProfile = learningProfile
local learningDirty, lastLearningSave = false, -math.huge
controller.SaveLearning = function(force)
    env.RoWorldLearningProfile = Auto.newLearning(learningProfile)
    if not force and (not learningDirty or os.clock() - lastLearningSave < 30) then return true end
    if type(writefile) ~= "function" then return false, "session_only" end
    lastLearningSave = os.clock()
    local ok, err = pcall(function() writefile("RoWorldLearning_v1.json", game:GetService("HttpService"):JSONEncode(learningProfile)) end)
    if ok then learningDirty = false else log:add("learning_save_error", {message = tostring(err)}) end
    return ok, err
end
log:add("start", {version = "8.8", source = "7919eeba500e473b842e2e11e3c62dee585b39c2", learning = learningProfile,
    learningStorage = type(writefile) == "function" and "file_available" or "session_only"})
env.RoWorldAuto = controller
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local player = Players.LocalPlayer
if not player then error("RoWorldAuto: uruchom skrypt po stronie klienta") end
local net = RS:WaitForChild("AirfrontNet", 15)
local sharedRoot = RS:WaitForChild("Airfront", 15)
if not net or not sharedRoot then error("RoWorldAuto: brak modulow RoWorld w tej grze") end
local remote = net:WaitForChild("ToServer", 10)
local replies = net:WaitForChild("ToClient", 10)
local protocolNode = sharedRoot:FindFirstChild("Net") and sharedRoot.Net:FindFirstChild("Protocol")
if not remote or not replies or not protocolNode then error("RoWorldAuto: niezgodny protokol gry") end
local protocolOK, Protocol = pcall(require, protocolNode)
if not protocolOK or type(Protocol) ~= "table" or type(Protocol.OP) ~= "table" then
    error("RoWorldAuto: require(Protocol) niedostepny")
end
local OP = Protocol.OP
local function wire(op, ...) remote:FireServer(op, ...) end
local inventoryAt = -math.huge
function controller.RefreshEquipment()
    if os.clock() - inventoryAt < 3 then return end
    inventoryAt = os.clock(); wire(OP.HELLO)
    log:add("inventory_requested", {})
end
local rewardReportOpen = false
local function closeRewardReport(force)
    if rewardReportOpen or force then
        rewardReportOpen = false
        pcall(Auto.endRewardReport, wire, OP)
    end
end
if recoverOldReport then closeRewardReport(true) end
local session, scan, scanState, memory = nil, nil, nil, {}
local lastScan, lastDiscover, lastTick, tickAt = -math.huge, -math.huge, nil, os.clock()
local lastAction, probeAck, probeWaiting, connections = "Gotowy", nil, false, {}
local detached = { Detached = true, mode = 2, state = nil, paused = false }
function detached:send_intent(intent)
    if self.state and self.state.loaded and self.state.local_owner > 0 then
        local packet = Protocol.encode_intent(intent)
        if packet then wire(OP.INTENT, packet) end
    end
end
local mirrorQueue, mirrorHead, mirrorTail, syncAt = {}, 1, 0, -math.huge
local mirrorError, mirrorBusy = nil, false
local gameMessage = "Wybierz panstwo do testow w meczu."
local shieldUntil, observedState, stateConnections, missileTest = {}, nil, {}, nil
local trackedAttacks, trackedUnits, trackedNukes, trackedStructures, observations = {}, {}, {}, {}, {}
local function smallState(s)
    local o = s and s.owners[s.local_owner]
    return if o then {tick = s.tick, phase = s.phase, map = s.map_id, width = s.W, height = s.H, owner = s.local_owner,
        troops = o.troops, cap = o.max_troops, gold = o.gold, tiles = o.tiles,
        spawnTicksLeft = Auto.spawnTicksLeft(s),
        reserve = scanState == s and memory.analysis and math.floor(memory.analysis.reserve) or nil} else {}
end
local function watchState(s)
    if not s or s == observedState and matchHistory and matchHistory.owner == s.local_owner then return end
    for _, c in ipairs(stateConnections) do c:Disconnect() end
    table.clear(stateConnections); table.clear(shieldUntil)
    observedState = s
    if s.spawnDeadline == nil and s.phase_ticks_left ~= nil then Auto.observeSpawnPhase(s, s.phase, s.phase_ticks_left) end
    matchHistory = Auto.bindHistory(s, matchHistory)
    controller.MatchHistory = matchHistory
    s.equipment = equipment
    s.learningProfile = if cfg.AdaptiveLearning then learningProfile else nil
    trackedAttacks, trackedUnits, trackedNukes, trackedStructures, observations = {}, {}, {}, {}, {}
    for uid, u in pairs(s.units) do if u.owner == s.local_owner then trackedUnits[uid] = {kind = u.kind, troops = u.troops} end end
    for sid, b in pairs(s.structures) do if b.owner == s.local_owner then trackedStructures[sid] = {kind = b.kind, tile = b.tile, level = b.level} end end
    for uid, n in pairs(s.nukes) do trackedNukes[uid] = {kind = n.kind, owner = n.owner, to = n.to_tile} end
    for aid, a in pairs(s.attacks) do
        if a.attacker == s.local_owner then
            trackedAttacks[aid] = {target = a.target, troops = a.troops, started = s.tick,
                tiles = s.owners[s.local_owner].tiles, lastLog = s.tick, preexisting = true}
        end
    end
    log:add("state_bound", smallState(s), s.tick)
    s.eventObserver = function(e)
        if not controller.Alive then return end
        local kind, id = e[1], e[2]
        if kind == 14 and e[3] ~= s.local_owner then
            if not trackedAttacks[id] then
                trackedAttacks[id] = {foreign = true, target = e[4], attacker = e[3]}
                if e[4] == s.local_owner then
                    log:add("incoming_attack", {aid = id, attacker = e[3], target = e[4], troops = e[5], anchor = e[6], targetsUs = true}, s.tick)
                end
            end
        elseif kind == 14 and e[3] == s.local_owner then
            local previous = trackedAttacks[id]
            if not previous then
                trackedAttacks[id] = {target = e[4], troops = e[5], started = s.tick, tiles = s.owners[s.local_owner].tiles, lastLog = s.tick}
                log:add("attack_started", {aid = id, target = e[4], troops = e[5]}, s.tick)
            else
                if s.tick - previous.lastLog >= 40 then
                    log:add("attack_progress", {aid = id, troops = e[5], target = e[4]}, s.tick); previous.lastLog = s.tick
                end
                previous.troops = e[5]
            end
        elseif kind == 15 and trackedAttacks[id] then
            local a = trackedAttacks[id]
            if a.foreign then
                if a.target == s.local_owner then log:add("incoming_attack_ended", {aid = id, attacker = a.attacker}, s.tick) end
            else
                log:add("attack_ended", {aid = id, target = a.target, durationTicks = s.tick - a.started, lastTroops = a.troops,
                    preexisting = a.preexisting, ownTilesChange = s.owners[s.local_owner].tiles - a.tiles}, s.tick)
            end
            trackedAttacks[id] = nil
        elseif kind == 9 and e[4] == s.local_owner then
            trackedUnits[id] = {kind = e[3], troops = e[8]}
            if e[3] == 0 or e[3] == 2 then log:add("unit_created", {uid = id, kind = e[3], troops = e[8]}, s.tick) end
        elseif kind == 11 and trackedUnits[id] then
            if trackedUnits[id].kind == 0 or trackedUnits[id].kind == 2 then
                log:add("unit_removed", {uid = id, kind = trackedUnits[id].kind, troops = trackedUnits[id].troops, reason = e[3]}, s.tick)
            end
            trackedUnits[id] = nil
        elseif kind == 12 then
            trackedNukes[id] = {kind = e[3], owner = e[4], from = e[5], to = e[6], launchTick = e[7], flightTicks = e[8]}
            if e[3] ~= 3 then log:add("missile_launched", trackedNukes[id], s.tick) end
        elseif kind == 13 then
            local n = trackedNukes[id]
            local blast = s.lastExplosion
            if e[3] ~= 3 or blast and blast.affectedUs then
                log:add(if e[5] == 0 then "missile_intercepted" elseif e[5] < 0 then "missile_split" else "missile_impact",
                    blast and blast.uid == id and blast or {uid = id, kind = e[3], tile = e[4], radius = e[5], owner = e[6], intendedTarget = n and n.to}, s.tick)
            end
            trackedNukes[id] = nil
            if blast and blast.affectedUs and blast.radius > 0 then
                gameMessage = "Wybuch (" .. blast.x .. ", " .. blast.y .. "), utracone pola w obszarze: " .. blast.ownLost .. ". Szczegoly w MAPA."
            end
        elseif kind == 19 and (id == -1 or id == s.local_owner) then
            log:add("game_message", {category = e[3], text = tostring(e[4])}, s.tick)
        elseif kind == 16 or kind == 17 or kind == 18 or kind == 21 or kind == 22 or kind == 30 then
            log:add("diplomacy_event", {event = kind, a = id, b = e[3], value = e[4], extra = e[5]}, s.tick)
        elseif kind == 4 or kind == 5 or kind == 6 or kind == 23 then
            local b = s.structures[id]
            local old = trackedStructures[id]
            if old or b and (b.owner == s.local_owner or b.kind >= 3) then
                log:add("structure_event", {event = kind, sid = id, kind = b and b.kind or old and old.kind,
                    owner = b and b.owner, tile = b and b.tile or old and old.tile,
                    level = b and b.level, activeTick = b and b.active_tick}, s.tick)
            end
            trackedStructures[id] = if b and b.owner == s.local_owner then {kind = b.kind, tile = b.tile, level = b.level} else nil
        elseif kind == 29 then log:add("sam_fired", {sam = id, missile = e[3], fire = e[4], intercept = e[5]}, s.tick)
        elseif kind == 33 and id == s.local_owner then log:add("reinforcements_received", {troops = e[3], readyTick = e[4]}, s.tick)
        elseif kind == 20 then log:add("game_over", {winner = id, reason = e[3], state = smallState(s)}, s.tick)
        end
    end
    s.observed_shield = shieldUntil
    if s.message and s.message.Connect then
        table.insert(stateConnections, s.message:Connect(function(to, category, text) Auto.gameMessage(s, to, category, text) end))
    end
    if s.snapshot_loaded and s.snapshot_loaded.Connect then
        table.insert(stateConnections, s.snapshot_loaded:Connect(function()
            Auto.observeSpawnPhase(s, s.phase, s.phase_ticks_left)
            s.spawnRevision = (s.spawnRevision or 0) + 1
            if scanState == s then memory.spawnPlan = nil end
        end))
    end
    local function markInitial()
        for id, o in pairs(s.owners) do
            if o.kind == 2 and o.spawned then shieldUntil[id] = s.playing_since + 300 end
        end
    end
    if s.phase == 1 and s.tick - s.playing_since < 300 then markInitial() end
    table.insert(stateConnections, s.owner_spawned:Connect(function(id)
        if s.snapshot_loaded then s.spawnRevision = (s.spawnRevision or 0) + 1 end
        if s.phase == 1 then shieldUntil[id] = s.tick + 300 end
    end))
    table.insert(stateConnections, s.phase_changed:Connect(function(phase, ticksLeft)
        Auto.observeSpawnPhase(s, phase, ticksLeft)
        if phase == 1 then markInitial() end
    end))
    table.insert(stateConnections, s.attack_started:Connect(function(aid)
        local a = s.attacks[aid]
        local target = a and s.owners[a.target]
        if a and target and target.kind ~= 1 then shieldUntil[a.attacker] = 0 end
    end))
    table.insert(stateConnections, s.nuke_launched:Connect(function(uid)
        local n = s.nukes[uid]
        if missileTest and n and n.owner == s.local_owner and n.kind == 0 and n.to_tile == missileTest.tile then
            gameMessage = "Serwer potwierdzil odpalenie atomowki na chroniony start."
            missileTest = nil
        end
    end))
end
local function requestSync()
    if os.clock() - syncAt >= 8 then wire(OP.RESYNC); syncAt = os.clock() end
end
local function queueMirror(op, ...)
    if mirrorTail - mirrorHead > 500 then
        table.clear(mirrorQueue); mirrorHead, mirrorTail = 1, 0
        detached.state = nil; mirrorError = "Kolejka pelna; potrzebna synchronizacja"
        requestSync()
    end
    mirrorTail += 1
    mirrorQueue[mirrorTail] = table.pack(op, ...)
end

local function isSession(v)
    if type(v) ~= "table" or type(rawget(v, "mode")) ~= "number" or not rawget(v, "env") then return false end
    local ok, valid = pcall(function() return type(v.send_intent) == "function" and v.state_ready ~= nil end)
    return ok and valid
end
local function discover()
    if cfg.DirectReader then return nil end
    local scripts = player:FindFirstChild("PlayerScripts")
    local client = scripts and scripts:FindFirstChild("AirfrontClient")
    local mainNode = client and client:FindFirstChild("Main")
    if mainNode then
        local ok, main = pcall(require, mainNode)
        if ok and type(main) == "table" and isSession(main.session) then return main.session end
    end
    if type(getgc) == "function" then
        local ok, objects = pcall(getgc, true)
        if ok and type(objects) == "table" then
            local candidate
            for _, obj in pairs(objects) do
                if isSession(obj) then
                    local st = rawget(obj, "state")
                    if st and st.loaded and st.local_owner > 0 and (obj.mode == 1 or obj.mode == 2) then return obj end
                    candidate = candidate or obj
                end
            end
            return candidate
        end
    end
    return nil
end

local gui = Instance.new("ScreenGui")
gui.Name = "RoWorldAutoPanel"
gui.ResetOnSpawn = false
gui.DisplayOrder = 500
gui.Parent = player:WaitForChild("PlayerGui")
local frame = Instance.new("ScrollingFrame")
local viewportHeight = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize.Y or 900
frame.Size = UDim2.fromOffset(370, math.max(360, math.min(760, viewportHeight - 130)))
frame.CanvasSize = UDim2.fromOffset(0, 1026)
frame.ScrollBarThickness = 6
frame.ScrollingDirection = Enum.ScrollingDirection.Y
frame.Position = UDim2.new(1, -385, 0, 90)
frame.BackgroundColor3 = Color3.fromRGB(18, 23, 39)
frame.BorderSizePixel = 0
frame.Parent = gui
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10); corner.Parent = frame
local function label(text, y, height)
    if y >= 275 then y += 94 end
    local x = Instance.new("TextLabel")
    x.Size = UDim2.new(1, -24, 0, height)
    x.Position = UDim2.fromOffset(12, y)
    x.BackgroundTransparency = 1
    x.TextColor3 = Color3.fromRGB(225, 231, 245)
    x.TextSize = 14; x.Font = Enum.Font.Gotham
    x.TextWrapped = true; x.TextXAlignment = Enum.TextXAlignment.Left
    x.Text = text; x.Parent = frame
    return x
end
local function button(text, y, callback)
    if y >= 275 then y += 94 end
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -24, 0, 32); b.Position = UDim2.fromOffset(12, y)
    b.BackgroundColor3 = Color3.fromRGB(40, 57, 84)
    b.TextColor3 = Color3.new(1, 1, 1); b.TextSize = 13; b.Font = Enum.Font.Gotham
    b.Text = text; b.Parent = frame
    table.insert(connections, b.Activated:Connect(callback))
    return b
end
label("RoWorld v8.8 | START + PAMIEC + OBRONA SAM", 8, 26)
local status = label("Szukam biezacej sesji...", 39, 40)
local botButton, rewardButton, humanButton
local function toggle()
    if controller.Probe then return end
    controller.Enabled = not controller.Enabled
    log:add("bot_toggle", {enabled = controller.Enabled})
    lastAction = if controller.Enabled then "Bot wlaczony" else "Bot zatrzymany"
end
botButton = button("BOT: OFF  [F8]", 85, toggle)
humanButton = button("Atakowanie graczy: " .. (if cfg.AttackHumans then "ON" else "OFF"), 123, function()
    cfg.AttackHumans = not cfg.AttackHumans
    humanButton.Text = "Atakowanie graczy: " .. (if cfg.AttackHumans then "ON" else "OFF")
end)
local allianceButton, nukeButton, samButton
allianceButton = button("SOJUSZE: " .. (if cfg.AutoDiplomacy then "AUTO" else "RECZNIE"), 161, function()
    cfg.AutoDiplomacy = not cfg.AutoDiplomacy
    allianceButton.Text = "SOJUSZE: " .. (if cfg.AutoDiplomacy then "AUTO" else "RECZNIE")
end)
nukeButton = button("ATOMOWKI: " .. (if cfg.AutoNukes then "AUTO" else "OFF"), 199, function()
    cfg.AutoNukes = not cfg.AutoNukes
    nukeButton.Text = "ATOMOWKI: " .. (if cfg.AutoNukes then "AUTO" else "OFF")
end)
samButton = button("SAM: " .. (if cfg.AutoSAM then "AUTO" else "OFF"), 237, function()
    cfg.AutoSAM = not cfg.AutoSAM
    samButton.Text = "SAM: " .. (if cfg.AutoSAM then "AUTO" else "OFF")
end)
local armyStatus = label("Wojsko: czekam na dane", 275, 38)
local navyStatus = label("Morze: czekam na dane", 314, 30)
local allianceStatus = label("Sojusze: ocena ofert po wlaczeniu bota", 345, 40)
local weaponStatus = label("Bron: ocena oslony SAM i kosztow", 386, 40)
local messageStatus = label("Komunikaty gry: brak nowych", 427, 42)
local worldStatus = label("Mapa: aktualizuje wszystkie pola otrzymane z serwera", 275, 54)
worldStatus.Position = UDim2.fromOffset(12, 313)
local equipmentPopup, equipmentRows, equipmentInfo, equipmentSelection = nil, {}, nil, nil
local function updateEquipmentUI()
    if not equipmentPopup then return end
    local owned = 0
    for _, item in ipairs(Auto.EquipmentItems) do
        if equipment.owned[item.key] then owned += 1 end
        local mode = cfg.EquipmentModes[item.key] or "auto"
        local detected = if not equipment.loaded then "czekam" elseif equipment.owned[item.key] then "posiadane" else "brak"
        if equipment.blocked[item.key] then detected = "serwer odmowil" end
        local summary = Auto.equipmentStatus(session and session.state, equipment, cfg, item.key)
        local extra = if item.passive then "" elseif item.key == "reinforce" then
            (if summary.cooldownTicks and summary.cooldownTicks > 0 then " / " .. math.ceil(summary.cooldownTicks / 10) .. "s" else "")
            else " / bud:" .. summary.buildings
        equipmentRows[item.key].Text = item.title .. " | " .. (if item.passive then detected
            else (if mode == "auto" then "AUTO" elseif mode == "owned" then "MAM" else "OFF") .. " | " .. detected .. extra)
    end
    if equipmentSelection then
        local state = Auto.equipmentStatus(session and session.state, equipment, cfg, equipmentSelection)
        equipmentInfo.Text = equipmentSelection .. ": odblokowane " .. tostring(state.unlocked) .. "; budynki " .. state.buildings
            .. "; gotowe " .. state.active .. (if state.gold then "; zloto " .. math.floor(state.gold / 1000) .. "K; kolejny koszt " .. math.floor(state.nextCost / 1000) .. "K." else "; czekam na mecz.")
    else
        equipmentInfo.Text = "Wykryto " .. owned .. " / " .. #Auto.EquipmentItems .. ". AUTO czyta konto; MAM to reczne wskazanie; OFF wyklucza uzycie. Odblokowanie nadal sprawdza serwer."
    end
end
local function openEquipment()
    if equipmentPopup then equipmentPopup:Destroy(); equipmentPopup = nil; return end
    equipmentPopup = Instance.new("ScrollingFrame")
    equipmentPopup.Name = "ArsenalSettings"; equipmentPopup.Size = UDim2.fromOffset(390, math.min(630, viewportHeight - 100))
    equipmentPopup.Position = UDim2.new(0.5, -195, 0.5, -math.min(315, (viewportHeight - 100) / 2))
    equipmentPopup.BackgroundColor3 = Color3.fromRGB(18, 23, 39); equipmentPopup.BorderSizePixel = 0
    equipmentPopup.CanvasSize = UDim2.fromOffset(0, 972); equipmentPopup.ScrollBarThickness = 6; equipmentPopup.ZIndex = 60; equipmentPopup.Parent = gui
    local function popupLabel(text, y, height)
        local l = label(text, 0, height); l.Parent = equipmentPopup; l.Position = UDim2.fromOffset(12, y); l.ZIndex = 61; return l
    end
    local function popupButton(text, y, fn)
        local b = button(text, 0, fn); b.Parent = equipmentPopup; b.Position = UDim2.fromOffset(12, y); b.ZIndex = 62; return b
    end
    popupLabel("ARSENAL / USTAWIENIA", 8, 26)
    equipmentInfo = popupLabel("Czekam na wyposazenie z serwera", 38, 70)
    for i, item in ipairs(Auto.EquipmentItems) do
        local key = item.key
        equipmentRows[key] = popupButton(item.title, 116 + (i - 1) * 39, function()
            if item.passive then return end
            equipmentSelection = key
            local mode = cfg.EquipmentModes[key] or "auto"
            cfg.EquipmentModes[key] = if mode == "auto" then "owned" elseif mode == "owned" then "off" else "auto"
            equipment.blocked[key] = nil
            env.RoWorldEquipmentModes = table.clone(cfg.EquipmentModes)
            log:add("equipment_mode", {key = key, mode = cfg.EquipmentModes[key]})
            updateEquipmentUI()
        end)
    end
    popupButton("ODSWIEZ WYPOSAZENIE Z KONTA", 433, controller.RefreshEquipment)
    local navyToggle
    navyToggle = popupButton("OKRETY WOJENNE: " .. (if cfg.AutoWarships then "AUTO" else "OFF"), 472, function()
        cfg.AutoWarships = not cfg.AutoWarships
        navyToggle.Text = "OKRETY WOJENNE: " .. (if cfg.AutoWarships then "AUTO" else "OFF")
        log:add("navy_toggle", {enabled = cfg.AutoWarships})
    end)
    local deepToggle
    deepToggle = popupButton("ANALIZA: " .. (if cfg.DeepAnalysis then "DOKLADNIEJSZA" else "STANDARD"), 511, function()
        cfg.DeepAnalysis = not cfg.DeepAnalysis
        cfg.OwnSamples, cfg.BorderSamples, cfg.WeaponCandidates, cfg.ScanGap = if cfg.DeepAnalysis then 1200 else 700,
            if cfg.DeepAnalysis then 256 else 128, if cfg.DeepAnalysis then 48 else 28, if cfg.DeepAnalysis then 1 else 2
        deepToggle.Text = "ANALIZA: " .. (if cfg.DeepAnalysis then "DOKLADNIEJSZA" else "STANDARD")
        scan = nil; log:add("analysis_mode", {deep = cfg.DeepAnalysis})
    end)
    popupLabel("Cala mapa jest aktualizowana w obu trybach. Dokladniejszy tryb zwieksza liczbe ocenianych miejsc i czestosc analizy. Nie kupuje rzeczy za Stars ani Robux.", 549, 55)
    popupButton("ZAMKNIJ USTAWIENIA", 608, function() equipmentPopup:Destroy(); equipmentPopup = nil end)
    popupButton("MAPA / OSTATNIE WYBUCHY", 647, function() if controller.OpenMap then controller.OpenMap() end end)
    local counterToggle
    counterToggle = popupButton("KONTRATAKI: " .. (if cfg.AutoCounter then "AUTO" else "OFF"), 686, function()
        cfg.AutoCounter = not cfg.AutoCounter
        counterToggle.Text = "KONTRATAKI: " .. (if cfg.AutoCounter then "AUTO" else "OFF")
        log:add("counter_toggle", {enabled = cfg.AutoCounter})
    end)
    popupButton("KOPIUJ PELNY ZACHOWANY LOG", 725, function() if controller.CopyLog then controller.CopyLog(true) end end)
    local learningToggle
    learningToggle = popupButton("UCZENIE: " .. (if cfg.AdaptiveLearning then "ON" else "OFF"), 764, function()
        cfg.AdaptiveLearning = not cfg.AdaptiveLearning
        local s = session and session.state
        if s then
            s.learningProfile = if cfg.AdaptiveLearning then learningProfile else nil
            if s.combatMemory then s.combatMemory.constructionLearning = nil end
        end
        learningToggle.Text = "UCZENIE: " .. (if cfg.AdaptiveLearning then "ON" else "OFF")
        scan = nil; log:add("learning_toggle", {enabled = cfg.AdaptiveLearning})
    end)
    popupButton("RESET PAMIECI UCZENIA", 803, function()
        learningProfile = Auto.newLearning(); controller.LearningProfile = learningProfile
        local s = session and session.state
        if s then
            s.learningProfile = if cfg.AdaptiveLearning then learningProfile else nil
            if s.combatMemory then s.combatMemory.constructionLearning = nil end
        end
        learningDirty = true; controller.SaveLearning(true); scan = nil
        log:add("learning_reset", {profile = learningProfile})
    end)
    popupLabel("Uczy sie czasu budowy i ryzyka frontu. Profil: mnoznik " .. string.format("%.2f", learningProfile.frontMultiplier)
        .. ", udane " .. learningProfile.successes .. ", straty " .. learningProfile.failures
        .. ". " .. (type(writefile) == "function" and "Zapis pliku dostepny." or "Pamiec tej sesji; profil jest w logu."), 842, 70)
    local recoveryToggle
    recoveryToggle = popupButton("ODBUDOWA PO KONTRACH: " .. (if cfg.AutoCounterRecovery then "AUTO" else "OFF"), 921, function()
        cfg.AutoCounterRecovery = not cfg.AutoCounterRecovery
        local s = session and session.state
        if not cfg.AutoCounterRecovery and s and s.combatMemory then s.combatMemory.offensiveRecovery = nil end
        recoveryToggle.Text = "ODBUDOWA PO KONTRACH: " .. (if cfg.AutoCounterRecovery then "AUTO" else "OFF")
        log:add("counter_recovery_toggle", {enabled = cfg.AutoCounterRecovery})
    end)
    controller.RefreshEquipment(); updateEquipmentUI()
end
local equipmentButton = button("WYPOSAZENIE / USTAWIENIA", 275, openEquipment)
equipmentButton.Position = UDim2.fromOffset(12, 275)
label("Liczba wyplat:", 484, 30)
local cyclesBox = Instance.new("TextBox")
cyclesBox.Name = "ProbeCycles"
cyclesBox.Size = UDim2.fromOffset(160, 30)
cyclesBox.Position = UDim2.new(1, -172, 0, 578)
cyclesBox.BackgroundColor3 = Color3.fromRGB(28, 38, 57)
cyclesBox.TextColor3 = Color3.new(1, 1, 1)
cyclesBox.TextSize = 15; cyclesBox.Font = Enum.Font.Gotham
cyclesBox.ClearTextOnFocus = false
cyclesBox.PlaceholderText = "Wpisz liczbe wyplat"
cyclesBox.Text = tostring(cfg.ProbeCycles)
cyclesBox.Parent = frame
local function startProbe()
    if controller.Probe then
        controller.Probe = false; controller.ProbeSerial = nil
        closeRewardReport()
        probeWaiting = false; lastAction = "Zatrzymano test"; return
    end
    local cycles = Auto.parseCycles(cyclesBox.Text)
    if not cycles then lastAction = "Wpisz dodatnia calkowita liczbe wyplat"; return end
    cfg.ProbeCycles = cycles
    controller.Enabled = false
    controller.Probe = true
    local serial = {}
    controller.ProbeSerial = serial
    task.spawn(function()
        local result = { attempts = 0, confirmed = 0, paid = 0, balance = nil }
        controller.LastProbe = result
        for attempt = 1, cycles do
            if not controller.Alive or not controller.Probe or controller.ProbeSerial ~= serial then break end
            probeAck, probeWaiting = nil, false
            local s = session and session.state
            -- The server allows four payouts per reported solo match, and two credit
            -- operations a second. Reuse each reported match four times, without bursts.
            if (attempt - 1) % 4 == 0 then
                Auto.rewardRequests(wire, OP, s and s.map_id)
                rewardReportOpen = true
                task.wait(0.10)
            end
            if not controller.Alive or not controller.Probe or controller.ProbeSerial ~= serial then break end
            result.attempts += 1
            probeWaiting = true
            local sentAt = os.clock()
            Auto.rewardResult(wire, OP)
            local deadline = os.clock() + math.clamp(cfg.ProbeTimeout, 2, 20)
            lastAction = "Test " .. attempt .. "/" .. cycles .. ": czekam na serwer"
            while controller.Alive and controller.Probe and controller.ProbeSerial == serial
                and probeAck == nil and os.clock() < deadline do task.wait(0.03) end
            if controller.ProbeSerial ~= serial then break end
            probeWaiting = false
            if probeAck == nil then lastAction = "Brak wyplaty z serwera; test zakonczony"; break end
            result.confirmed += 1
            result.paid += probeAck.total
            result.balance = probeAck.balance
            log:add("reward_test_confirmed", {attempt = attempt, paid = probeAck.total, balance = probeAck.balance})
            lastAction = result.confirmed .. "/" .. cycles .. " | Serwer: +" .. result.paid .. " Stars"
            print("[RoWorld test]", attempt, "paid", probeAck.total, "server balance", probeAck.balance)
            local untilTime = sentAt + math.clamp(cfg.ProbeGap, 0.60, 30)
            while controller.Alive and controller.Probe and controller.ProbeSerial == serial
                and os.clock() < untilTime do task.wait(0.03) end
        end
        if controller.ProbeSerial == serial then
            controller.Probe = false; probeWaiting = false
            closeRewardReport()
        end
    end)
end
rewardButton = button("START TESTU - SZYBKI (0.6 s)", 522, startProbe)
label("Test zmienia prawdziwe saldo Stars\ni licznik meczow konta.", 560, 36)
local targetButton, donationButton
local targetList = Instance.new("ScrollingFrame")
targetList.Name = "TargetList"
targetList.Size = UDim2.new(1, -24, 0, 190)
targetList.Position = UDim2.fromOffset(12, 410)
targetList.BackgroundColor3 = Color3.fromRGB(22, 32, 51)
targetList.BorderSizePixel = 0; targetList.ScrollBarThickness = 7
targetList.ZIndex = 20; targetList.Visible = false; targetList.Parent = frame
local function currentMatch()
    local current = if session and not session.Detached then session else detached
    local s = current and current.state
    if not s or not s.loaded or s.local_owner <= 0 or s.phase ~= 1 then
        requestSync(); gameMessage = "Dolacz do meczu publicznego i poczekaj na dane."
        return nil
    end
    watchState(s)
    return current, s
end
local function selectedTarget(s)
    local id = controller.TargetId
    local o = id and s.owners[id]
    if not o or not o.alive or not o.spawned or friendly(s, s.local_owner, id) then
        gameMessage = "Wybierz zywe panstwo, z ktorym nie masz sojuszu."
        return nil
    end
    return id, o
end
targetButton = button("WYBIERZ PANSTWO  v", 601, function()
    if targetList.Visible then targetList.Visible = false; return end
    local _, s = currentMatch()
    if not s then return end
    for _, child in ipairs(targetList:GetChildren()) do child:Destroy() end
    local owners = {}
    for id, o in pairs(s.owners) do
        if o.alive and o.spawned and not friendly(s, s.local_owner, id) then table.insert(owners, o) end
    end
    table.sort(owners, function(a, b) return a.name:lower() < b.name:lower() end)
    for index, o in ipairs(owners) do
        local item = Instance.new("TextButton")
        item.Size = UDim2.new(1, -8, 0, 28)
        item.Position = UDim2.fromOffset(0, (index - 1) * 28)
        item.BackgroundColor3 = Color3.fromRGB(31, 46, 69)
        item.TextColor3 = Color3.new(1, 1, 1); item.TextSize = 13
        item.Font = Enum.Font.Gotham; item.ZIndex = 21
        item.Text = tostring(o.id) .. " | " .. o.name; item.Parent = targetList
        item.Activated:Connect(function()
            controller.DonationEnabled = false
            controller.TargetId = o.id
            targetButton.Text = "CEL: " .. tostring(o.id) .. " | " .. o.name
            targetList.Visible = false
            gameMessage = "Wybrano: " .. o.name
        end)
    end
    targetList.CanvasSize = UDim2.fromOffset(0, #owners * 28)
    targetList.Visible = true
    if #owners == 0 then gameMessage = "Brak dostepnych celow w tym meczu." end
end)
donationButton = button("DAROWIZNY CELU: TEST OFF", 639, function()
    if controller.DonationEnabled then
        controller.DonationEnabled = false; gameMessage = "Zatrzymano komendy darowizn."; return
    end
    local current, s = currentMatch()
    if not current then return end
    if current.mode ~= 2 then gameMessage = "Ten blad dotyczy serwera meczu publicznego."; return end
    local id = selectedTarget(s)
    if not id then return end
    controller.DonationEnabled = true; controller.DonationSent = 0
    gameMessage = "Proba zaklocania darowizn; efekt zalezy od kolejnosci komend."
end)
button("ATOMOWKA A OCHRONA STARTU (1x)", 677, function()
    local current, s = currentMatch()
    if not current then return end
    local id, o = selectedTarget(s)
    if not id then return end
    if (shieldUntil[id] or 0) <= s.tick then
        gameMessage = "Nie widze aktywnej ochrony tego celu. Wybierz nowy start."; return
    end
    local cost = s.rules.nuke_cost("atom", s.mirvs_launched)
    if s.owners[s.local_owner].gold < cost then
        gameMessage = "Test wymaga " .. cost .. " zlota i gotowego silosu."; return
    end
    local ready = false
    for _, b in pairs(s.structures) do
        if b.owner == s.local_owner and b.kind == 5 and b.active_tick <= s.tick then
            local busy = 0
            for _, t in ipairs(b.shots or {}) do if t + s.rules.SILO_COOLDOWN_TICKS > s.tick then busy += 1 end end
            if busy < b.level then ready = true; break end
        end
    end
    if not ready then gameMessage = "Brak gotowego silosu."; return end
    local tile = o.spawn_tile
    if owner(s, tile) ~= id then gameMessage = "Cel utracil swoje miejsce startu."; return end
    missileTest = {tile = tile}
    current:send_intent({type = "nuke", kind = "atom", tile = tile})
    gameMessage = "Wyslano komende; czekam na potwierdzenie odpalenia."
end)
button("PREMIA SAMOUCZKA (JEDNORAZOWA)", 715, function()
    local tutorialNode = sharedRoot.Data:FindFirstChild("Tutorial")
    local ok, data = pcall(require, tutorialNode)
    if not ok or type(data) ~= "table" then gameMessage = "Brak danych samouczka."; return end
    wire(OP.ANALYTICS, "tutorial", #data.FUNNEL)
    gameMessage = "Wyslano ostatni krok; premia tylko raz na konto."
end)
local gameStatus = label(gameMessage, 753, 42)
controller.Start = function() if controller.Alive and not controller.Probe then controller.Enabled = true end end
controller.Pause = function() controller.Enabled = false end
controller.TestRewards = startProbe
controller.Stop = function()
    controller.SaveLearning(true)
    controller.Alive = false; controller.Enabled = false; controller.Probe = false
    controller.DonationEnabled = false
    controller.ProbeSerial = nil
    closeRewardReport()
    log:add("stop", {state = smallState(session and session.state)})
    for _, c in ipairs(connections) do c:Disconnect() end
    for _, c in ipairs(stateConnections) do c:Disconnect() end
    gui:Destroy()
end
button("ODBLOKUJ DOLACZANIE (WORLD)", 801, function()
    controller.Enabled = false; controller.Probe = false; controller.ProbeSerial = nil
    controller.DonationEnabled = false; probeWaiting = false
    closeRewardReport(true)
    gameMessage = "Zamknieto zgloszenie solo; ponawiam dolaczenie do World."
    task.delay(0.25, function() if controller.Alive then wire(OP.JOIN_PUBLIC, "world") end end)
end)
controller.ExportLog = function(full)
    local service = game:GetService("HttpService")
    local s, blasts = session and session.state, {}
    for i = math.max(1, #(s and s.explosions or {}) - 7), #(s and s.explosions or {}) do table.insert(blasts, s.explosions[i]) end
    log:add("export", {state = smallState(s), lastError = controller.LastError, recentBlasts = blasts,
        scope = full == true and "retained_history" or "latest", counterWave = s and s.combatMemory and s.combatMemory.counterWave,
        offensiveRecovery = s and s.combatMemory and s.combatMemory.offensiveRecovery,
        infrastructure = s and Auto.infrastructure(s),
        learning = learningProfile,
        equipment = equipment.owned, inventoryLoaded = equipment.loaded,
        betrayers = matchHistory and matchHistory.betrayers, aggressors = matchHistory and matchHistory.aggressors})
    return log:export(function(row) return service:JSONEncode(row) end, table.clone(cfg), full == true and cfg.LogCapacity or cfg.LogExportEntries)
end
controller.InspectTile = function(x, y)
    local s = session and session.state
    x, y = tonumber(x), tonumber(y)
    if not s or not s.loaded then return nil, "Czekam na mape" end
    if not x or not y or x ~= x or y ~= y or x < 0 or y < 0 or x >= s.W or y >= s.H or x % 1 ~= 0 or y % 1 ~= 0 then
        return nil, "Podaj calkowite wspolrzedne: x 0.." .. s.W - 1 .. ", y 0.." .. s.H - 1
    end
    return Auto.describeTile(s, y * s.W + x)
end
local mapPopup
controller.OpenMap = function()
    if mapPopup then mapPopup:Destroy(); mapPopup = nil; return end
    mapPopup = Instance.new("Frame"); mapPopup.Name = "MapInspector"
    mapPopup.Size = UDim2.fromOffset(520, math.min(650, viewportHeight - 100))
    mapPopup.Position = UDim2.new(0.5, -260, 0.5, -math.min(325, (viewportHeight - 100) / 2))
    mapPopup.BackgroundColor3 = Color3.fromRGB(18, 23, 39); mapPopup.ZIndex = 80; mapPopup.Parent = gui
    local title = label("MAPA: DOKLADNE POLE I HISTORIA WYBUCHOW", 0, 38)
    title.Parent = mapPopup; title.Position = UDim2.fromOffset(12, 8); title.ZIndex = 81
    local fields = {}
    for i, axis in ipairs({"x", "y"}) do
        local field = Instance.new("TextBox"); field.Name = "Map" .. axis; field.Size = UDim2.fromOffset(105, 32)
        field.Position = UDim2.fromOffset(12 + (i - 1) * 117, 50); field.Text = "0"; field.PlaceholderText = axis .. " (od 0)"
        field.TextSize = 15; field.ZIndex = 82; field.ClearTextOnFocus = false; field.Parent = mapPopup; fields[i] = field
    end
    local output = Instance.new("TextBox"); output.Name = "MapReport"; output.MultiLine = true; output.TextEditable = false
    output.ClearTextOnFocus = false; output.TextWrapped = true; output.TextSize = 13; output.Font = Enum.Font.Code
    output.TextXAlignment = Enum.TextXAlignment.Left; output.TextYAlignment = Enum.TextYAlignment.Top
    output.Size = UDim2.new(1, -24, 1, -185); output.Position = UDim2.fromOffset(12, 132)
    output.BackgroundColor3 = Color3.fromRGB(10, 16, 29); output.TextColor3 = Color3.new(1, 1, 1); output.ZIndex = 81; output.Parent = mapPopup
    local function show()
        local row, err = controller.InspectTile(fields[1].Text, fields[2].Text)
        local lines = {err or ("Pole (" .. row.x .. ", " .. row.y .. ") / tick " .. row.tick)}
        if row then
            table.insert(lines, "Wlasciciel: " .. row.ownerName .. " [" .. row.owner .. "] / " .. row.relation .. " / " .. row.controlledBy)
            table.insert(lines, "Teren: " .. row.terrain .. " / " .. (if row.land then "lad" else "woda") .. "; fallout: " .. tostring(row.fallout))
            table.insert(lines, "Budynki na polu: " .. #row.structures .. "; forty obejmujace pole: " .. #row.forts .. "; SAM: " .. #row.sams)
            for _, b in ipairs(row.structures) do table.insert(lines, "  budynek " .. b.kind .. " / owner " .. b.owner .. " / poziom " .. b.level .. " / gotowy " .. tostring(b.active)) end
            if row.pendingBlast then table.insert(lines, "NADLATUJE: typ " .. row.pendingBlast.kind .. ", za " .. row.pendingBlast.eta / 10 .. " s") end
            log:add("map_inspection", row, row.tick)
        end
        table.insert(lines, "\nOstatnie zdarzenia (x, y):")
        local s = session and session.state
        local blasts = s and s.explosions or {}
        for i = #blasts, math.max(1, #blasts - 7), -1 do
            local b = blasts[i]
            table.insert(lines, b.status .. " (" .. b.x .. ", " .. b.y .. "), typ " .. b.kind .. ", owner " .. b.owner
                .. ", tick " .. b.tick .. ", nasze straty w obszarze " .. b.ownLost)
        end
        output.Text = table.concat(lines, "\n")
    end
    local function mapButton(text, x, y, width, fn)
        local b = button(text, 0, fn); b.Parent = mapPopup; b.Position = UDim2.fromOffset(x, y); b.Size = UDim2.fromOffset(width, 32); b.ZIndex = 82
    end
    mapButton("SPRAWDZ POLE", 246, 50, 260, show)
    mapButton("POKAZ OSTATNI WYBUCH", 12, 91, 494, function()
        local s = session and session.state; local selected
        for _, b in ipairs(s and s.explosions or {}) do if b.radius > 0 then selected = b end end
        if selected then fields[1].Text, fields[2].Text = tostring(selected.x), tostring(selected.y) end
        show()
    end)
    local close = Instance.new("TextButton"); close.Size = UDim2.new(1, -24, 0, 32); close.Position = UDim2.new(0, 12, 1, -42)
    close.Text = "ZAMKNIJ MAPE"; close.ZIndex = 82; close.Parent = mapPopup
    table.insert(connections, close.Activated:Connect(function() mapPopup:Destroy(); mapPopup = nil end))
    show()
end
controller.CopyLog = function(full)
    local ok, report = pcall(controller.ExportLog, full == true)
    if not ok then gameMessage = "Nie mozna zapisac logu: " .. tostring(report); return end
    local copy = if type(setclipboard) == "function" then setclipboard elseif type(toclipboard) == "function" then toclipboard else nil
    if copy and pcall(copy, report) then gameMessage = "Log skopiowany. Mozesz wkleic go do czatu."; return end
    local popup = Instance.new("Frame")
    popup.Size = UDim2.fromScale(0.78, 0.68)
    popup.AnchorPoint = Vector2.new(0.5, 0.5); popup.Position = UDim2.fromScale(0.5, 0.5)
    popup.BackgroundColor3 = Color3.fromRGB(17, 24, 39); popup.ZIndex = 50; popup.Parent = gui
    local field = Instance.new("TextBox")
    field.Size = UDim2.new(1, -20, 1, -55); field.Position = UDim2.fromOffset(10, 10)
    field.MultiLine = true; field.ClearTextOnFocus = false; field.TextWrapped = false
    field.TextXAlignment = Enum.TextXAlignment.Left; field.TextYAlignment = Enum.TextYAlignment.Top
    field.Font = Enum.Font.Code; field.TextSize = 12; field.TextColor3 = Color3.new(1, 1, 1)
    field.BackgroundColor3 = Color3.fromRGB(10, 16, 29); field.Text = report; field.ZIndex = 51; field.Parent = popup
    local close = Instance.new("TextButton")
    close.Size = UDim2.new(1, -20, 0, 30); close.Position = UDim2.new(0, 10, 1, -38)
    close.Text = "Ctrl+A, Ctrl+C aby skopiowac / ZAMKNIJ"; close.ZIndex = 52; close.Parent = popup
    close.Activated:Connect(function() popup:Destroy() end)
    field:CaptureFocus(); field.SelectionStart = 1; field.CursorPosition = #report + 1
    gameMessage = "Log otwarty do recznego skopiowania."
end
button("KOPIUJ LOGI DO CZATU", 839, controller.CopyLog)
button("ZAMKNIJ / STOP  [F9]", 877, controller.Stop)
table.insert(connections, UIS.InputBegan:Connect(function(input, processed)
    if processed or UIS:GetFocusedTextBox() then return end
    if input.KeyCode == Enum.KeyCode.F8 then toggle() end
    if input.KeyCode == Enum.KeyCode.F9 then controller.Stop() end
end))
table.insert(connections, replies.OnClientEvent:Connect(function(op, payload, extra)
    if op == OP.INVENTORY then
        if Auto.applyInventory(equipment, payload) then
            log:add("inventory", {owned = table.clone(equipment.owned), source = "server", revision = equipment.revision})
        end
        updateEquipmentUI()
    elseif op == OP.UNLOCK_RESULT and extra == true then
        task.delay(3, function() if controller.Alive then controller.RefreshEquipment() end end)
    end
    if op == OP.PUBLIC_STATE and (payload == "joining" or payload == "going") then
        controller.Enabled = false; controller.Probe = false; controller.ProbeSerial = nil
        controller.DonationEnabled = false; probeWaiting = false
        closeRewardReport()
        gameMessage = "Trwa dolaczanie. Po wejsciu mozesz wlaczyc bota F8."
    end
    if controller.Probe and probeWaiting and op == OP.STARS and Auto.isProbeReply(payload) and probeAck == nil then
        probeAck = payload
    end
    if op == OP.SNAPSHOT or op == OP.DELTA then
        if not session or session.Detached then queueMirror(op, payload, extra) end
        if op == OP.DELTA and (not session or session.Detached) and not detached.state and not mirrorBusy then requestSync() end
    elseif op == OP.OWNER_CHANGED and detached.state then
        detached.state.local_owner = payload
    elseif op == OP.MATCH_CLOSED then
        log:add("match_closed", {reason = tostring(payload)})
        detached.state = nil
        matchHistory, controller.MatchHistory = nil, nil
        table.clear(mirrorQueue); mirrorHead, mirrorTail = 1, 0
    end
end))
controller.RefreshEquipment()

-- Xeno may not expose the running Session's tables. Maintain our own read-only mirror
-- from the same server snapshot/deltas the normal multiplayer client receives instead.
task.spawn(function()
    local cachedMap, cachedKey
    local function mapFor(snap)
        local key = tostring(snap.map_id) .. ":" .. tostring(snap.map_w) .. ":" .. tostring(snap.map_h)
        if cachedMap and cachedKey == key then return cachedMap end
        local rf = net:WaitForChild("GetMap", 10)
        assert(rf, "Brak AirfrontNet.GetMap")
        local base = (snap.map_id or "world"):match("^(.-)@%d+$") or snap.map_id or "world"
        local first = rf:InvokeServer(base, 0)
        assert(type(first) == "table" and typeof(first.chunk) == "buffer", "Serwer nie zwrocil mapy: " .. base)
        local compressed = buffer.create(first.zsize)
        buffer.copy(compressed, 0, first.chunk, 0, buffer.len(first.chunk))
        local offset = buffer.len(first.chunk)
        for k = 1, first.chunks - 1 do
            assert(controller.Alive, "Przerwano pobieranie mapy")
            local part = rf:InvokeServer(base, k)
            assert(type(part) == "table" and typeof(part.chunk) == "buffer", "Niepelna mapa: czesc " .. k)
            buffer.copy(compressed, offset, part.chunk, 0, buffer.len(part.chunk))
            offset += buffer.len(part.chunk)
        end
        assert(offset == first.zsize, "Niepelna mapa")
        local encoding = game:GetService("EncodingService")
        local raw = encoding:DecompressBuffer(compressed, Enum.CompressionAlgorithm.Zstd)
        assert(buffer.len(raw) == first.width * first.height, "Niezgodny rozmiar terenu")
        local w, h = snap.map_w or first.width, snap.map_h or first.height
        cachedMap = Auto.mapFromBytes(raw, first, w, h, function()
            task.wait(); assert(controller.Alive, "Przerwano odczyt mapy")
        end)
        cachedKey = key
        return cachedMap
    end
    while controller.Alive do
        if mirrorHead <= mirrorTail then
            local packet = mirrorQueue[mirrorHead]
            mirrorQueue[mirrorHead] = nil; mirrorHead += 1
            mirrorBusy = true
            local ok, err = pcall(function()
                if packet[1] == OP.SNAPSHOT then
                    local ownerId, encoded = packet[2], packet[3]
                    local snap = Protocol.decode_snapshot(encoded)
                    local map = mapFor(snap)
                    local state = Auto.rawState(snap, map, ownerId, function()
                        task.wait(); assert(controller.Alive, "Przerwano wczytywanie")
                    end)
                    matchHistory = Auto.bindHistory(state, matchHistory)
                    state.equipment = equipment; controller.MatchHistory = matchHistory
                    detached.state = state
                    mirrorError = nil
                elseif packet[1] == OP.DELTA and detached.state then
                    local delta = Protocol.decode_delta(packet[2], packet[3])
                    if (delta.t or 0) > detached.state.tick then
                        assert(delta.t == detached.state.tick + 1, "Brak aktualizacji; ponowna synchronizacja")
                        detached.state:apply_delta(delta)
                        if matchHistory then matchHistory.lastTick = delta.t end
                    end
                end
            end)
            mirrorBusy = false
            if not ok then
                mirrorError = tostring(err):sub(1, 180)
                controller.LastError = tostring(err)
                log:add("reader_error", {message = tostring(err)})
                detached.state = nil
                table.clear(mirrorQueue); mirrorHead, mirrorTail = 1, 0
                warn("[RoWorldAuto mirror]", err)
            elseif mirrorHead > mirrorTail then
                table.clear(mirrorQueue); mirrorHead, mirrorTail = 1, 0
            end
        else task.wait(0.05) end
    end
end)

task.spawn(function()
    local tick, seenAt = nil, os.clock()
    while controller.Alive do
        if controller.DonationEnabled then
            local ok, err = pcall(function()
                local current, s = currentMatch()
                if not current or current.mode ~= 2 then controller.DonationEnabled = false; return end
                local id = selectedTarget(s)
                if not id then controller.DonationEnabled = false; return end
                if tick ~= s.tick then tick, seenAt = s.tick, os.clock() end
                if os.clock() - seenAt > 3 then
                    controller.DonationEnabled = false; gameMessage = "Brak swiezego stanu; zatrzymano test."; return
                end
                current:send_intent(Auto.donationRequest(id))
                controller.DonationSent += 1
            end)
            if not ok then
                controller.DonationEnabled = false; gameMessage = "Darowizny: " .. tostring(err):sub(1, 120)
                log:add("donation_test_error", {message = tostring(err)})
            end
            task.wait(0.08) -- ~12.5 intents/s; the server's limit is 30 for all gameplay intents.
        else tick, seenAt = nil, os.clock(); task.wait(0.15) end
    end
end)

task.spawn(function()
    while controller.Alive do
        local ok, err = pcall(function()
            local now = os.clock()
            updateEquipmentUI()
            if not equipment.loaded and now - inventoryAt > 5 then controller.RefreshEquipment() end
            if (not session or session.Detached) and now - lastDiscover >= 8 then
                session = discover() or detached; lastDiscover = now
            end
            controller.Session = session
            if session and session.state then watchState(session.state) end
            botButton.Text = "BOT: " .. (if controller.Enabled then "ON" else "OFF") .. "  [F8]"
            rewardButton.Text = if controller.Probe then "TEST W TOKU - KLIKNIJ STOP" else "START TESTU - SZYBKI (0.6 s)"
            local connectionText = if session and not session.Detached then "Sesja lokalna"
                elseif detached.state then "Xeno: stan z serwera"
                elseif mirrorBusy then "Xeno: wczytuje mape"
                else "Xeno: dolacz do publicznego meczu"
            status.Text = connectionText .. " | " .. (mirrorError or lastAction)
            donationButton.Text = if controller.DonationEnabled then "DAROWIZNY: TEST ON / STOP (" .. controller.DonationSent .. ")"
                else "DAROWIZNY CELU: TEST OFF"
            gameStatus.Text = gameMessage
            armyStatus.Text = memory.armyText or "Wojsko: rezerwa i koszt ataku liczone z aktualnego stanu"
            navyStatus.Text = memory.navalText or "Morze: czekam na dane"
            allianceStatus.Text = memory.diplomacyText or "Sojusze: ocena sily, granicy i wspolnego przeciwnika"
            weaponStatus.Text = memory.strikeText or memory.weaponText or "Bron: SAM przeladowuje kazdy slot przez 9 sekund"
            worldStatus.Text = memory.worldText or "Mapa: pelna siatka pol, teren, morza i zdarzenia serwera"
            local displayState = session and session.state
            if displayState then
                local learned = Auto.updateLearning(displayState, cfg)
                for _, event in ipairs(learned) do log:add("learning_update", event, displayState.tick) end
                if #learned > 0 then learningDirty = true; controller.SaveLearning(false); scan = nil end
                if learningDirty then controller.SaveLearning(false) end
            end
            local notices = displayState and displayState.recentMessages
            if notices and #notices > 0 then messageStatus.Text = "Gra: " .. notices[#notices].text end
            if displayState then
                if matchHistory then matchHistory.lastTick = displayState.tick end
                local trend = Auto.mapTrend(displayState, 50)
                if now - (memory.lastMapLog or -math.huge) >= (if trend.lost > 0 then 3 else 10) then
                    memory.lastMapLog = now
                    log:add("map_activity", {gained = trend.gained, lost = trend.lost, changedWorld = trend.changed,
                        attackers = trend.attackers, owners = trend.actors, hotspots = trend.hotspots,
                        tiles = displayState.owners[displayState.local_owner] and displayState.owners[displayState.local_owner].tiles}, displayState.tick)
                end
                for i = #observations, 1, -1 do
                    local observation = observations[i]
                    if displayState.tick >= observation.due then
                        log:add("observation_after_command", {command = observation.seq, before = observation.before,
                            after = smallState(displayState)}, displayState.tick)
                        table.remove(observations, i)
                    end
                end
            end
            if not controller.Enabled or controller.Probe or not session then return end
            if session.mode ~= 1 and session.mode ~= 2 then lastAction = "Dolacz do meczu"; return end
            if session.paused or session.state_is_resync and session._resync_pending then return end
            local s = session.state
            if session.Detached and not mirrorBusy and not s then requestSync() end
            if not s or not s.loaded or s.local_owner <= 0 then lastAction = "Czekam na stan gracza"; return end
            if scanState ~= s or memory.owner ~= s.local_owner then
                scanState, scan, memory = s, nil, { owner = s.local_owner }
                lastScan, lastTick, tickAt = -math.huge, s.tick, now
            end
            if lastTick ~= s.tick then lastTick, tickAt = s.tick, now end
            if s.phase == 1 and now - tickAt > 3 then lastAction = "Stan gry nie odswieza sie"; return end
            local info = s.owners[s.local_owner]
            if not info then return end
            if cfg.AutoSpawn and not info.spawned and s.phase ~= 2 then
                local intent, why, details = Auto.spawnPlan(s, memory, now)
                lastAction, memory.armyText = why or "Start: oceniam mape", why
                local plan = memory.spawnPlan
                if plan and plan.result then
                    local best = plan.result.ranked[1]
                    memory.worldText = "Start: oceniono " .. plan.result.evaluated .. " wolnych pol z " .. plan.result.landTiles .. " ladowych"
                        .. (if best then "\nKandydat: x=" .. best.tile % s.W .. ", y=" .. best.tile // s.W else "\nBrak wolnego miejsca")
                elseif plan and plan.progress then
                    memory.worldText = "Start: analiza calej mapy " .. math.floor(plan.progress.done * 100 / math.max(1, plan.progress.total)) .. "% etapu"
                end
                if plan and plan.result and plan.loggedResult ~= plan.result then
                    plan.loggedResult = plan.result
                    log:add("spawn_analysis", {evaluated = plan.result.evaluated, landTiles = plan.result.landTiles,
                        startedTick = plan.result.startedTick, changedDuringScan = plan.result.changedDuringScan,
                        best = plan.result.ranked[1], ticksLeft = Auto.spawnTicksLeft(s)}, s.tick)
                end
                if intent then
                    session:send_intent(intent); plan.sentTick = s.tick
                    log:add("spawn_selected", details, s.tick)
                end
                return
            end
            memory.spawnPlan = nil
            if s.phase ~= 1 or not info.alive or not info.spawned then lastAction = "Czekam na gre / koniec"; return end
            local urgentMap = (s.mapRevision or 0) ~= (scan and scan.revision or -1)
                and (Auto.mapTrend(s, 20).lost > 0 or next(s.attacks) ~= nil)
            if not scan or now - lastScan >= cfg.ScanGap or urgentMap and now - lastScan >= 0.7 then
                local result = Auto.scan(s, function()
                    task.wait()
                    return controller.Alive and controller.Enabled and not controller.Probe and session.state == s
                end, cfg)
                if not result then return end
                scan, lastScan = result, os.clock()
            end
            local intent, why, bucket = Auto.decide(s, scan, cfg, memory, os.clock())
            if intent and intent.type == "attack" then
                local target = owner(s, intent.tile)
                local counterValid = bucket == "counter" and memory.counterDetails and memory.counterDetails.target == target
                    and memory.analysis and memory.analysis.incoming[target] ~= nil
                if friendly(s, s.local_owner, target) or (not counterValid and not s:borders_tile(s.local_owner, intent.tile)) then
                    scan = nil; return
                end
            end
            if intent and intent.type == "build" and intent.kind ~= "warship" then
                local preview = s.rules.placement(s, s.local_owner, intent.kind, intent.tile)
                if not preview.ok or owner(s, intent.tile) ~= s.local_owner or not clean(s, intent.tile) then
                    log:add("stale_build_cancelled", {kind = intent.kind, tile = intent.tile}, s.tick)
                    scan = nil; return
                end
                intent.tile = preview.tile
            elseif intent and (intent.type == "boat" or intent.type == "nuke") then
                if friendly(s, s.local_owner, owner(s, intent.tile)) then scan = nil; return end
            end
            if intent then
                local target = intent.target or (intent.tile and owner(s, intent.tile))
                local foe = target and s.owners[target]
                local before = smallState(s)
                local details = if bucket == "weapon" then memory.nukeDetails elseif bucket == "build" then memory.buildDetails
                    elseif bucket == "strike" or bucket == "reinforce" then memory.arsenalDetails
                    elseif bucket == "warship" or bucket == "navalMove" then memory.navalDetails else memory.armyDetails
                local seq = log:add("command", {intent = table.clone(intent), reason = why, before = before,
                    target = foe and {id = foe.id, name = foe.name, troops = foe.troops, tiles = foe.tiles, cap = foe.max_troops},
                    sentTroops = intent.ratio and math.floor(info.troops * math.clamp(intent.ratio, 0.01, 1)),
                    plan = details, naval = bucket == "boat" and memory.navalDetails or nil}, s.tick)
                session:send_intent(intent)
                Auto.trackConstruction(s, intent, details, seq, cfg)
                if bucket == "counter" then
                    local recovery = Auto.commitCounter(s, memory.counterDetails, cfg)
                    if recovery then log:add("offense_recovery", recovery, s.tick) end
                    memory.defensiveTargets = memory.defensiveTargets or {}
                    memory.defensiveTargets[target] = s.tick
                end
                if intent.type == "build" then memory.build = os.clock() end
                table.insert(observations, {seq = seq, due = s.tick + 80, before = before})
                memory[bucket] = os.clock()
                lastAction = why
            else
                lastAction = if memory.analysis and memory.analysis.defending then "OBRONA: " .. (memory.armyText or "zagrozenie kraju") else "Rezerwa / czekam na okazje"
                if os.clock() - (memory.lastWaitLog or -math.huge) >= 12 then
                    memory.lastWaitLog = os.clock()
                    log:add("waiting", {state = smallState(s), army = memory.armyText, weapons = memory.weaponText,
                        navy = memory.navalText, diplomacy = memory.diplomacyText, build = memory.buildText, counter = memory.counterText,
                        infrastructure = memory.infrastructure, economy = memory.economyDetails, offenseBlocked = memory.offenseBlocked,
                        nuclearDefense = memory.analysis and memory.analysis.nuclearDefense,
                        offensiveRecovery = memory.analysis and memory.analysis.offensiveRecovery,
                        lossTypes = memory.analysis and {ground = memory.analysis.groundLost, neutralized = memory.analysis.neutralizedLost},
                        learning = learningProfile}, s.tick)
                end
            end
        end)
        if not ok then
            controller.Enabled = false
            controller.LastError = tostring(err)
            log:add("bot_error", {message = tostring(err), state = smallState(session and session.state)})
            lastAction = "Blad: " .. tostring(err):sub(1, 130)
            warn("[RoWorldAuto]", err)
        end
        local waitingForStart = cfg.AutoSpawn and session and session.state and session.state.phase == 0
            and session.state.owners[session.state.local_owner] and not session.state.owners[session.state.local_owner].spawned
        task.wait(if waitingForStart then 0.05 elseif cfg.DeepAnalysis then 0.4 else 0.65)
    end
end)
print("[RoWorldAuto] Panel gotowy. F8: bot, F9: stop. Test nagrod uruchamiasz osobnym przyciskiem.")
return controller
