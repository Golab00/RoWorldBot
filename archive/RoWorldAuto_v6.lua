--!nocheck
-- RoWorld v6: game strategy, independent Xeno reader and optional owner test panel.
-- Source reviewed: lukechatton/roworld @ 7919eeba500e473b842e2e11e3c62dee585b39c2.
-- No remote downloads. Uses the current Session, GameState and normal intent API.
-- The optional rewards probe DOES change the connected account's Stars and match stats.

local Auto = {}
Auto.Defaults = {
    DirectReader = true,
    AutoSpawn = true, AutoBuild = true, AutoBoats = true, AttackHumans = true,
    Reserve = 0.35, Ready = 0.50, ExpandRatio = 0.20, WarRatio = 0.35,
    AttackGap = 4, BuildGap = 6, BoatGap = 20, ScanGap = 5,
    MaxCityLevels = 12, ProbeCycles = 10, ProbeGap = 0.60, ProbeTimeout = 15,
    AutoDiplomacy = true, MaxAllies = 3, AllowFallout = true,
    MaxAttackShare = 0.65, AttackSafety = 1.20, MaxDefensePosts = 8,
    AutoNukes = true, AutoSAM = true, AllowHydrogen = true, WeaponGap = 9,
    NukeBudgetShare = 0.45, GoldReserve = 250000, MaxNukeSalvo = 6,
    LogCapacity = 900, LogExportEntries = 250,
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
    return result
end

function Auto.newLog(capacity)
    local log = {entries = {}, sequence = 0, started = os.clock(), capacity = math.max(50, capacity or 900), dropped = 0}
    function log:add(kind, data, tick)
        self.sequence += 1
        local row = {seq = self.sequence, seconds = math.floor((os.clock() - self.started) * 1000) / 1000,
            kind = kind, tick = tick, data = data or {}}
        table.insert(self.entries, row)
        if #self.entries > self.capacity then table.remove(self.entries, 1); self.dropped += 1 end
        return row.seq
    end
    function log:export(encode, settings, limit)
        local lines = {"RoWorldBot v6 | log schema 1 | JSON Lines"}
        table.insert(lines, encode({schema = 1, version = 6, config = settings, totalEvents = self.sequence, dropped = self.dropped}))
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
    return other == id or (other > 0 and s:are_allies(id, other))
end
local function neighbors(s, t, visit)
    local x = t % s.W
    if x > 0 then visit(t - 1) end
    if x < s.W - 1 then visit(t + 1) end
    if t >= s.W then visit(t - s.W) end
    if t < s.N - s.W then visit(t + s.W) end
end

-- Chunked scan; yieldFn may cancel by returning false. No per-frame whole-map scans.
function Auto.scan(s, yieldFn)
    local me, map = s.local_owner, s.map
    local result = { own = {}, coast = {}, fronts = {}, falloutFronts = {}, borders = {}, foreignPorts = {} }
    local info = s.owners[me]
    local stride = math.max(1, math.floor((info and info.tiles or 0) / 320))
    local count, coastCount = 0, 0
    local landCount = map.land_count
    for k = 0, landCount - 1 do
        if k % 20000 == 0 and yieldFn and yieldFn() == false then return nil end
        local t = buffer.readi32(map.land_list, k * 4)
        if owner(s, t) == me then
            count += 1
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
                    if #border.ownPoints < 64 then table.insert(border.ownPoints, t) end
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
                if #f.points < 64 then table.insert(f.points, n)
                else local slot = ((f.edges * 48271) % 2147483647) % f.edges + 1; if slot <= 64 then f.points[slot] = n end end
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
        if p.kind == 1 and p.owner ~= me and p.active_tick <= s.tick then
            local water = buffer.readu16(map.coast_body, p.tile * 2)
            result.foreignPorts[water] = true
        end
    end
    return result
end

function Auto.spawnSite(s)
    local map = s.map
    if map.land_count == 0 then return nil end
    local best, bestScore = nil, -math.huge
    local samples = math.min(350, map.land_count)
    local r = math.max(4, math.ceil(14 / s.rules.K_LIN))
    for k = 0, samples - 1 do
        local index = math.floor(k * map.land_count / samples)
        local t = buffer.readi32(map.land_list, index * 4)
        if owner(s, t) ~= 0 or not clean(s, t) then continue end
        local score, free = 0, true
        local x, y = t % s.W, t // s.W
        for dx = -r, r, r do
            for dy = -r, r, r do
                local nx, ny = x + dx, y + dy
                if nx < 0 or nx >= s.W or ny < 0 or ny >= s.H then free = false; continue end
                local n = ny * s.W + nx
                if owner(s, n) ~= 0 then free = false end
                if buffer.readu8(map.land, n) == 1 then score += 2 end
                if buffer.readu8(map.terrain, n) == 2 then score += 1 end
                if buffer.readu8(map.coastal, n) == 1 then score += 0.25 end
            end
        end
        if free and score > bestScore then best, bestScore = t, score end
    end
    return best
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
    for _, fired in ipairs(b.shots or {}) do if fired + 90 > atTick then busy += 1 end end
    return math.max(0, b.level - busy)
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
function Auto.context(s, scan, cfg)
    local me, info = s.local_owner, s.owners[s.local_owner]
    local ctx = {outgoing = {}, incoming = {}, totalIncoming = 0, wars = {}, navy = Auto.navy(s),
        hostileNeighbors = 0, strongestNeighbor = 0, nuclearThreat = false, incomingNukes = {}, reserve = 0}
    for _, a in pairs(s.attacks) do
        if a.attacker == me then ctx.outgoing[a.target] = a; if a.target > 0 then ctx.wars[a.target] = true end end
        if a.target == me and not a.retreating then
            ctx.incoming[a.attacker] = a; ctx.totalIncoming += a.troops; ctx.wars[a.attacker] = true
        end
    end
    for enemy in pairs(scan.borders or scan.fronts) do
        local o = s.owners[enemy]
        if o and o.alive and not friendly(s, me, enemy) and o.kind ~= 1 then
            ctx.hostileNeighbors += 1
            ctx.strongestNeighbor = math.max(ctx.strongestNeighbor, o.troops)
        end
    end
    local radii = {[0] = 30, 100, 0, 18, 60, 30, 1.5, 15, 5}
    for _, n in pairs(s.nukes) do
        if friendly(s, me, n.owner) or not onMap(s, n.to_tile) then continue end
        local radius = (radii[n.kind] or 30) / s.rules.K_LIN
        local threatens = owner(s, n.to_tile) == me
        if not threatens then
            for _, b in pairs(s.structures) do
                if b.owner == me and distance(s, b.tile, n.to_tile) <= radius^2 then threatens = true; break end
            end
        end
        if threatens then ctx.nuclearThreat = true; table.insert(ctx.incomingNukes, n); ctx.wars[n.owner] = true end
    end
    local reserveFraction = cfg.Reserve
    if ctx.hostileNeighbors >= 2 then reserveFraction = math.max(reserveFraction, 0.42) end
    if ctx.strongestNeighbor > info.troops * 1.4 then reserveFraction = math.max(reserveFraction, 0.48) end
    ctx.reserve = math.min(info.max_troops * 0.72,
        math.max(info.max_troops * reserveFraction, ctx.totalIncoming * 0.65))
    ctx.available = math.max(0, info.troops - ctx.reserve)
    return ctx
end

function Auto.allianceScore(s, scan, other, cfg, ctx)
    local me, mine, theirs = s.local_owner, s.owners[s.local_owner], s.owners[other]
    if not theirs or not theirs.alive or not theirs.spawned or theirs.kind == 1 then return -100, "brak korzysci strategicznej" end
    if (theirs.traitor_until or 0) > s.tick or (s.recentBetrayal or {})[other]
        and s.tick - s.recentBetrayal[other] < 1200 then return -100, "niedawna zdrada" end
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
    if shared then score += 3; reason = "wspolny przeciwnik" end
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
                .. (s.owners[from] and s.owners[from].name or tostring(from)) .. ": " .. reason
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
        memory.diplomacyText = "Proponuje " .. s.owners[best].name .. ": " .. reason
        return {type = "ally_request", target = best}, memory.diplomacyText, "diplomacy"
    end
    return nil
end

-- Estimates the minimum useful force by integrating the game's per-tile loss formula.
function Auto.attackPlan(s, front, target, cfg, ctx)
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
-- Predict a shortest water route. The server chooses the final route itself.
function Auto.waterPath(s, from, to, limit)
    local body = buffer.readu16(s.map.coast_body, to * 2)
    local function water(t)
        if t < 0 then return false end
        return buffer.readu16(s.map.water_body, t * 2) == body and buffer.readu8(s.map.terrain, t) <= 1
    end
    local start, finish
    neighbors(s, from, function(n) if not start and water(n) then start = n end end)
    neighbors(s, to, function(n) if not finish and water(n) then finish = n end end)
    if not start or not finish then return nil end
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
    if #scan.coast == 0 or ctx.navy.unknownWarships > 0 then return nil end
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
            if o.troops > ctx.available * 0.6 then continue end
        end
        local from, nearest = nil, math.huge
        local body = buffer.readu16(s.map.coast_body, t * 2)
        for _, c in ipairs(scan.coast) do
            if buffer.readu16(s.map.coast_body, c * 2) == body then
                local d = distance(s, c, t); if d < nearest then from, nearest = c, d end
            end
        end
        if from then table.insert(candidates, {tile = t, from = from, d = nearest, target = target}) end
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
local function blastSafe(s, tile, radius)
    for _, b in pairs(s.structures) do
        if friendly(s, s.local_owner, b.owner) and distance(s, tile, b.tile) <= radius^2 then return false end
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
function Auto.nukePlan(s, scan, cfg, memory, ctx)
    if not cfg.AutoNukes or s.tick < (s.weaponBackoff or 0) then return nil end
    local me, mine = s.local_owner, s.owners[s.local_owner]
    local silos, slots = {}, 0
    for _, b in pairs(s.structures) do
        if b.owner == me and b.kind == 5 and Auto.readyMissiles(s, b) > 0 then table.insert(silos, b); slots += Auto.readyMissiles(s, b) end
    end
    memory.wantSiloUpgrade = nil
    if slots == 0 then memory.weaponText = "Atomowki: brak zaladowanego silosu"; return nil end
    local budget = math.max(0, math.min(mine.gold * cfg.NukeBudgetShare, mine.gold - cfg.GoldReserve))
    if budget < 750000 then memory.weaponText = "Atomowki: oszczedza zloto na gospodarke i obrone"; return nil end
    local best, bestValue, candidates = nil, nil, {}
    local targetWeights = {[0] = 5, 4, 4, 2, 7, 7, 4, 5, 6}
    for _, b in pairs(s.structures) do
        if not friendly(s, me, b.owner) then
            local rough = (targetWeights[b.kind] or 2) * math.sqrt(b.level)
            if ctx.wars[b.owner] then rough += 5 end
            table.insert(candidates, {site = b, value = rough})
        end
    end
    table.sort(candidates, function(a, b) return if a.value == b.value then a.site.sid < b.site.sid else a.value > b.value end)
    for index = 1, math.min(18, #candidates) do
        local target = candidates[index].site
        local enemy = s.owners[target.owner]
        if not enemy or not enemy.alive or owner(s, target.tile) ~= target.owner then continue end
        if enemy.kind == 2 and not cfg.AttackHumans then continue end
        if not ctx.wars[target.owner] and enemy.tiles < mine.tiles * 1.5 then continue end
        if (s.observed_shield or {})[target.owner] and s.observed_shield[target.owner] > s.tick then continue end
        local nearest, d = silos[1], math.huge
        for _, b in ipairs(silos) do local dd = distance(s, b.tile, target.tile); if dd < d then nearest, d = b, dd end end
        local inFlight = false
        for _, n in pairs(s.nukes) do
            if n.owner == me and distance(s, n.to_tile, target.tile) < (40 / s.rules.K_LIN)^2 then inFlight = true; break end
        end
        if inFlight then continue end
        for _, kind in ipairs(if cfg.AllowHydrogen then {0, 1} else {0}) do
            local radius = (if kind == 0 then 30 else 100) / s.rules.K_LIN
            if not blastSafe(s, target.tile, radius) then continue end
            local screen = Auto.samScreen(s, nearest.tile, target.tile, kind)
            local amount = if kind == 0 then screen.capacity + 1 else 1
            local price = if kind == 0 then 750000 else 5000000
            if kind == 1 and screen.capacity > 0 then continue end
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
                if b.owner == target.owner and distance(s, target.tile, b.tile) <= radius^2 then value += (targetWeights[b.kind] or 2) * math.sqrt(b.level) end
            end
            value += math.min(6, enemy.troops / math.max(fullArea(s, enemy.tiles), 1) * math.pi * (radius * s.rules.K_LIN)^2 / 80000)
            if value < (if kind == 0 then 5 else 18) then continue end
            local efficiency = value / (price * amount / 750000)
            if not bestValue or efficiency > bestValue then
                bestValue = efficiency
                best = {type = "nuke", kind = if kind == 0 then "atom" else "hydrogen", tile = target.tile, amount = amount}
                memory.nukeDetails = {target = target.owner, tile = target.tile, kind = best.kind, amount = amount,
                    cost = price * amount, samSites = screen.sites, interceptCapacity = screen.capacity,
                    readyNow = screen.readyNow, cooldownTicks = 90, flightTicks = screen.flight, silo = nearest.sid, value = value}
                memory.weaponText = "Cel " .. enemy.name .. ": " .. amount .. " pocisk(i), oslon SAM: " .. screen.sites
                    .. ", przewidywane przechwycenia: " .. screen.capacity
            end
        end
    end
    return best, memory.weaponText, "weapon"
end

function Auto.buildPlan(s, scan, cfg, memory, ctx, urgentOnly)
    if not cfg.AutoBuild or s.tick < (s.buildBackoff or 0) then return nil end
    local me, mine, levels, count = s.local_owner, s.owners[s.local_owner], {}, {}
    for _, b in pairs(s.structures) do
        if b.owner == me then levels[b.kind] = (levels[b.kind] or 0) + b.level; count[b.kind] = (count[b.kind] or 0) + 1 end
    end
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
            table.insert(threats, {front = front, value = strength})
        end
    end
    table.sort(threats, function(a, b) return a.value > b.value end)
    local plans = {}
    if cfg.AutoSAM and (ctx.nuclearThreat or s.nuclearAlert and s.tick - s.nuclearAlert < 1200) then table.insert(plans, "sam") end
    if #threats > 0 and threats[1].value >= 0.8 and (count[3] or 0) < cfg.MaxDefensePosts then table.insert(plans, "defense") end
    if not urgentOnly then
        if cfg.AutoNukes and memory.wantSiloUpgrade then table.insert(plans, "silo") end
        if (levels[0] or 0) == 0 or mine.troops / math.max(mine.max_troops, 1) > 0.65 then table.insert(plans, "city") end
        if (levels[1] or 0) < 3 then table.insert(plans, "port") end
        if (levels[0] or 0) > 0 and (levels[2] or 0) < 3 then table.insert(plans, "factory") end
        local enemySilo = false
        for _, b in pairs(s.structures) do if b.kind == 5 and not friendly(s, me, b.owner) then enemySilo = true; break end end
        if cfg.AutoSAM and enemySilo and (levels[4] or 0) < 3 and mine.gold >= 1800000 then table.insert(plans, "sam") end
        if cfg.AutoNukes and next(ctx.wars) and (levels[5] or 0) < 3 and mine.gold >= 2600000 then table.insert(plans, "silo") end
        if (levels[0] or 0) < cfg.MaxCityLevels and mine.troops > mine.max_troops * 0.40 then table.insert(plans, "city") end
    end
    for _, kind in ipairs(plans) do
        if kind == "city" and (levels[0] or 0) >= cfg.MaxCityLevels then continue end
        local cost = s.rules.cost_of(s, me, kind)
        if cost < 0 or mine.gold < cost then continue end
        local sites = if kind == "port" then scan.coast else scan.own
        local best, bestScore
        for index, tile in ipairs(sites) do
            if #sites > 600 and index % math.ceil(#sites / 600) ~= 0 then continue end
            if owner(s, tile) ~= me or not clean(s, tile) then continue end
            local preview = s.rules.placement(s, me, kind, tile)
            if not preview.ok then continue end
            local score = 0
            if kind == "defense" then
                local protected = 0
                for _, threat in ipairs(threats) do
                    local points = threat.front.ownPoints or {threat.front.ownTile}
                    for _, p in ipairs(points) do
                        if p and not Auto.defenseAt(s, me, p, true) and distance(s, preview.tile, p) <= (30 / s.rules.K_LIN)^2 then
                            protected += threat.value
                        end
                    end
                end
                if protected == 0 then continue end
                score = protected
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
                if kind == "silo" and preview.upgrade_sid == memory.wantSiloUpgrade then score += 100 end
            end
            if not bestScore or score > bestScore then best, bestScore = preview.tile, score end
        end
        if best then
            memory.buildText = "Buduje " .. kind .. (if kind == "defense" then ": nieoslonieta granica" elseif kind == "sam" then ": ochrona infrastruktury" else "")
            memory.buildDetails = {kind = kind, tile = best, cost = cost, score = bestScore,
                buildTicks = if kind == "sam" then 300 elseif kind == "silo" then 100 elseif kind == "defense" or kind == "port" then 50 else 20}
            return {type = "build", kind = kind, tile = best}, memory.buildText, "build"
        end
    end
    return nil
end

function Auto.decide(s, scan, cfg, memory, now)
    local me, info = s.local_owner, s.owners[s.local_owner]
    if not info or not info.alive or not info.spawned or s.phase ~= 1 then return nil end
    memory.armyDetails, memory.buildDetails, memory.nukeDetails, memory.navalDetails = nil, nil, nil, nil
    local ctx = Auto.context(s, scan, cfg)
    memory.analysis = ctx
    memory.navalText = "Morze: " .. #ctx.navy.warships .. " bojowych, " .. #ctx.navy.transports .. " transportow, " .. #ctx.navy.trade .. " handlowych"
    local ready = now - (memory.attack or -math.huge) >= cfg.AttackGap
    if ready and ctx.totalIncoming > info.troops * 0.25 then
        for enemy, a in pairs(ctx.incoming) do
            local front = scan.fronts[enemy]
            if not front or Auto.defenseAt(s, me, (scan.borders or {})[enemy] and scan.borders[enemy].ownTile or front.tile) then continue end
            local amount = math.floor(math.min(a.troops * 1.01, ctx.available))
            if amount >= math.max(1000, info.troops * 0.01) then
                memory.armyDetails = {amount = amount, counter = true, incoming = a.troops}
                return {type = "attack", tile = front.tile, ratio = amount / info.troops}, "Kontratak: " .. amount .. " wojska", "attack"
            end
        end
    end
    local command, why, bucket = Auto.diplomacy(s, scan, cfg, memory, ctx, now)
    if command then return command, why, bucket end
    if now - (memory.build or -math.huge) >= cfg.BuildGap then
        command, why, bucket = Auto.buildPlan(s, scan, cfg, memory, ctx, true)
        if command then return command, why, bucket end
    end
    if now - (memory.weapon or -math.huge) >= cfg.WeaponGap and now - (memory.weaponAnalysis or -math.huge) >= 3 then
        memory.weaponAnalysis = now
        command, why, bucket = Auto.nukePlan(s, scan, cfg, memory, ctx)
        if command then return command, why, bucket end
    end
    if ready and ctx.totalIncoming == 0 then
        for target, current in pairs(ctx.outgoing) do
            local front = scan.fronts[target]
            if target > 0 and front and not current.retreating then
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
    if ready and info.troops >= info.max_troops * cfg.Ready and ctx.totalIncoming == 0 then
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
                local plan = Auto.attackPlan(s, front, enemy, cfg, ctx)
                if not plan then continue end
                local value = plan.goal / math.max(plan.amount, 1) * (if plan.protected then 0.7 else 1)
                if not bestValue or value > bestValue then best, bestPlan, bestValue = front, plan, value end
            end
            if best then
                memory.armyText = "Atak: " .. bestPlan.amount .. ", rezerwa " .. math.floor(ctx.reserve)
                    .. (if bestPlan.protected then "; uwzgledniono fortyfikacje" else "")
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
    if now - (memory.build or -math.huge) >= cfg.BuildGap then
        command, why, bucket = Auto.buildPlan(s, scan, cfg, memory, ctx, false)
        if command then return command, why, bucket end
    end
    if cfg.AutoBoats and not next(ctx.outgoing) and ctx.totalIncoming == 0 and not scan.fronts[0]
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
    local kinds = {city = 0, port = 1, factory = 2, defense = 3, sam = 4, silo = 5}
    function R.nuke_cost(kind, launched) return if kind == "atom" then 750000 elseif kind == "hydrogen" then 5000000 else 25000000 + 15000000 * (launched or 0) end
    function R.cost_of(s, id, name)
        local wanted, count = kinds[name], 0
        local levels = {}
        for _, b in pairs(s.structures) do
            if b.owner == id then levels[b.kind] = (levels[b.kind] or 0) + b.level end
        end
        local built = s.built[id] or {}
        if wanted == 1 or wanted == 2 then
            count = math.min(levels[1] or 0, built[1] or 0) + math.min(levels[2] or 0, built[2] or 0)
        else count = math.min(levels[wanted] or 0, built[wanted] or 0) end
        if wanted == 3 then return math.min(250000, 50000 * (count + 1)) end
        if wanted == 4 then return math.min(3000000, 1500000 * (count + 1)) end
        if wanted == 5 then return 1000000 end
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
        if kind ~= 3 and closest and closest.owner == id and closest.active_tick <= s.tick then
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
    s.attacks[a.aid] = a
    return a
end
local function rawNuke(s, row, offset)
    local n = {uid = row[offset + 1], kind = row[offset + 2], owner = row[offset + 3],
        from_tile = row[offset + 4], to_tile = row[offset + 5], launch_tick = row[offset + 6], flight_ticks = row[offset + 7]}
    s.nukes[n.uid] = n
    return n
end
local function rawUnit(s, row, offset)
    local u = {uid = row[offset + 1], kind = row[offset + 2], owner = row[offset + 3],
        path = row[offset + 4] or {}, start_tick = row[offset + 5] or s.tick,
        ticks_per_tile_x100 = row[offset + 6] or 100, troops = row[offset + 7] or 0,
        hp = row[offset + 8] or 0, max_hp = row[offset + 9] or 0, veterancy = row[offset + 10] or 0,
        state = row[offset + 11] or 0, patrol_tile = row[offset + 12] or -1, prev_tile = -1, move_tick = s.tick}
    s.units[u.uid] = u
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
        recentMessages = {}, units = {}, attacks = {}, nukes = {}, fallout_count = 0, mirvs_launched = snap.mirvs_launched or 0}
    s.rules = rawRules(map)
    for _, key in ipairs({"owner_spawned", "phase_changed", "attack_started", "nuke_launched"}) do s[key] = event() end
    for _, row in ipairs(snap.owners or {}) do
        local o = rawOwner(row[1], row[2], row[4], row[5])
        o.alive, o.troops, o.gold, o.max_troops = row[6] == true, row[8], row[9], row[10]
        o.spawn_tile, o.spawned = row[13], row[13] >= 0
        o.traitor_until = row[12] or 0
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
    for _, row in ipairs(snap.structs or {}) do rawStruct(s, row, 0) end
    for _, row in ipairs(snap.attacks or {}) do rawAttack(s, row, 0) end
    for _, row in ipairs(snap.nukes or {}) do rawNuke(s, row, 0) end
    for _, row in ipairs(snap.units or {}) do rawUnit(s, row, 0) end
    for _, row in ipairs(snap.allies or {}) do
        local key = math.min(row[1], row[2]) * 1024 + math.max(row[1], row[2])
        s.alliances[key], s.alliance_expires[key], s.alliance_ext[key] = true, row[3] or (s.tick + 3000), row[4] or 0
    end
    for _, row in ipairs(snap.requests or {}) do s.requests[row[1] * 1024 + row[2]] = row[3] end
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
        for _, packed in ipairs(delta.tiles or {}) do
            local t, id = packed // 1024, packed % 1024
            local old = owner(self, t)
            if id > 0 and not self.owners[id] then self.owners[id] = rawOwner(id) end
            if self.owners[old] then self.owners[old].tiles -= 1 end
            if self.owners[id] then self.owners[id].tiles += 1 end
            buffer.writei32(self.owner, t * 4, id)
        end
        for _, packed in ipairs(delta.flags or {}) do
            local tile, flags = packed // 256, packed % 256
            local before = bit32.band(buffer.readu8(self.flags, tile), 1) ~= 0
            local after = bit32.band(flags, 1) ~= 0
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
                if id == 1 and self.playing_since < 0 then self.playing_since = self.tick end
                self.phase_changed:Fire(id, e[3])
            elseif kind == 3 then
                local o = self.owners[id]
                if o then o.spawned, o.spawn_tile = true, e[3] end
                self.owner_spawned:Fire(id, e[3])
            elseif kind == 4 then
                local b = rawStruct(self, {e[2], e[3], e[4], e[5], 1, self.tick}, 0)
                builtAdd(self, b.owner, b.kind)
            elseif kind == 5 then if self.structures[id] then self.structures[id].owner = e[3] end
            elseif kind == 6 then self.structures[id] = nil
            elseif kind == 9 then rawUnit(self, e, 1)
            elseif kind == 10 then
                local u = self.units[id]
                if u then u.prev_tile = u.path[1] or -1; u.path = {e[3]}; u.move_tick = self.tick end
            elseif kind == 11 then self.units[id] = nil
            elseif kind == 12 then
                local n = rawNuke(self, e, 1)
                if n.kind == 2 then self.mirvs_launched += 1 end
                if not friendly(self, self.local_owner, n.owner) then self.nuclearAlert = self.tick end
                self.nuke_launched:Fire(id)
            elseif kind == 13 then self.nukes[id] = nil
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
                if (e[4] or 0) > 0 then self.recentBetrayal[e[4]] = self.tick end
            elseif kind == 19 then Auto.gameMessage(self, id, e[3], e[4])
            elseif kind == 20 then self.phase = 2
            elseif kind == 21 then self.requests[id * 1024 + e[3]] = nil
            elseif kind == 22 then if self.owners[id] then self.owners[id].traitor_until = e[3] end
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
            end
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
local controller = {
    Config = cfg, Enabled = false, Alive = true, Probe = false, LastProbe = nil,
    DonationEnabled = false, DonationSent = 0, TargetId = nil,
}
local log = Auto.newLog(cfg.LogCapacity)
controller.Log = log
log:add("start", {version = 6, source = "7919eeba500e473b842e2e11e3c62dee585b39c2"})
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
    return if o then {tick = s.tick, phase = s.phase, map = s.map_id, owner = s.local_owner,
        troops = o.troops, cap = o.max_troops, gold = o.gold, tiles = o.tiles,
        reserve = scanState == s and memory.analysis and math.floor(memory.analysis.reserve) or nil} else {}
end
local function watchState(s)
    if not s or s == observedState then return end
    for _, c in ipairs(stateConnections) do c:Disconnect() end
    table.clear(stateConnections); table.clear(shieldUntil)
    observedState = s
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
        if kind == 14 and e[3] == s.local_owner then
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
            log:add("attack_ended", {aid = id, target = a.target, durationTicks = s.tick - a.started, lastTroops = a.troops,
                preexisting = a.preexisting, ownTilesChange = s.owners[s.local_owner].tiles - a.tiles}, s.tick)
            trackedAttacks[id] = nil
        elseif kind == 9 and e[4] == s.local_owner then
            trackedUnits[id] = {kind = e[3], troops = e[8]}
            log:add("unit_created", {uid = id, kind = e[3], troops = e[8]}, s.tick)
        elseif kind == 11 and trackedUnits[id] then
            log:add("unit_removed", {uid = id, kind = trackedUnits[id].kind, troops = trackedUnits[id].troops, reason = e[3]}, s.tick)
            trackedUnits[id] = nil
        elseif kind == 12 then
            trackedNukes[id] = {kind = e[3], owner = e[4], from = e[5], to = e[6], launchTick = e[7], flightTicks = e[8]}
            if e[3] ~= 3 then log:add("missile_launched", trackedNukes[id], s.tick) end
        elseif kind == 13 then
            local n = trackedNukes[id]
            if e[3] ~= 3 then log:add(if e[5] == 0 then "missile_intercepted" else "missile_impact",
                {uid = id, kind = e[3], tile = e[4], radius = e[5], owner = e[6], intendedTarget = n and n.to}, s.tick) end
            trackedNukes[id] = nil
        elseif kind == 19 and (id == -1 or id == s.local_owner) then
            log:add("game_message", {category = e[3], text = tostring(e[4])}, s.tick)
        elseif kind == 16 or kind == 17 or kind == 18 or kind == 21 or kind == 22 or kind == 30 then
            log:add("diplomacy_event", {event = kind, a = id, b = e[3], value = e[4], extra = e[5]}, s.tick)
        elseif kind == 4 or kind == 5 or kind == 6 or kind == 23 then
            local b = s.structures[id]
            local old = trackedStructures[id]
            if old or b and b.owner == s.local_owner then
                log:add("structure_event", {event = kind, sid = id, kind = b and b.kind or old and old.kind,
                    owner = b and b.owner, tile = b and b.tile or old and old.tile,
                    level = b and b.level, activeTick = b and b.active_tick}, s.tick)
            end
            trackedStructures[id] = if b and b.owner == s.local_owner then {kind = b.kind, tile = b.tile, level = b.level} else nil
        elseif kind == 29 then log:add("sam_fired", {sam = id, missile = e[3], fire = e[4], intercept = e[5]}, s.tick)
        elseif kind == 20 then log:add("game_over", {winner = id, reason = e[3], state = smallState(s)}, s.tick)
        end
    end
    s.observed_shield = shieldUntil
    if s.message and s.message.Connect then
        table.insert(stateConnections, s.message:Connect(function(to, category, text) Auto.gameMessage(s, to, category, text) end))
    end
    local function markInitial()
        for id, o in pairs(s.owners) do
            if o.kind == 2 and o.spawned then shieldUntil[id] = s.playing_since + 300 end
        end
    end
    if s.phase == 1 and s.tick - s.playing_since < 300 then markInitial() end
    table.insert(stateConnections, s.owner_spawned:Connect(function(id)
        if s.phase == 1 then shieldUntil[id] = s.tick + 300 end
    end))
    table.insert(stateConnections, s.phase_changed:Connect(function(phase)
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
frame.CanvasSize = UDim2.fromOffset(0, 930)
frame.ScrollBarThickness = 6
frame.ScrollingDirection = Enum.ScrollingDirection.Y
frame.Position = UDim2.new(1, -385, 0, 90)
frame.BackgroundColor3 = Color3.fromRGB(18, 23, 39)
frame.BorderSizePixel = 0
frame.Parent = gui
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10); corner.Parent = frame
local function label(text, y, height)
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
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -24, 0, 32); b.Position = UDim2.fromOffset(12, y)
    b.BackgroundColor3 = Color3.fromRGB(40, 57, 84)
    b.TextColor3 = Color3.new(1, 1, 1); b.TextSize = 13; b.Font = Enum.Font.Gotham
    b.Text = text; b.Parent = frame
    table.insert(connections, b.Activated:Connect(callback))
    return b
end
label("RoWorld v6 | BOT + STRATEGIA", 8, 26)
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
label("Liczba wyplat:", 484, 30)
local cyclesBox = Instance.new("TextBox")
cyclesBox.Name = "ProbeCycles"
cyclesBox.Size = UDim2.fromOffset(160, 30)
cyclesBox.Position = UDim2.new(1, -172, 0, 484)
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
controller.ExportLog = function()
    local service = game:GetService("HttpService")
    log:add("export", {state = smallState(session and session.state), lastError = controller.LastError})
    return log:export(function(row) return service:JSONEncode(row) end, table.clone(cfg), cfg.LogExportEntries)
end
controller.CopyLog = function()
    local ok, report = pcall(controller.ExportLog)
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
        table.clear(mirrorQueue); mirrorHead, mirrorTail = 1, 0
    end
end))

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
                    detached.state = state
                    mirrorError = nil
                elseif packet[1] == OP.DELTA and detached.state then
                    local delta = Protocol.decode_delta(packet[2], packet[3])
                    if (delta.t or 0) > detached.state.tick then
                        assert(delta.t == detached.state.tick + 1, "Brak aktualizacji; ponowna synchronizacja")
                        detached.state:apply_delta(delta)
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
            weaponStatus.Text = memory.weaponText or "Bron: SAM przeladowuje kazdy slot przez 9 sekund"
            local displayState = session and session.state
            local notices = displayState and displayState.recentMessages
            if notices and #notices > 0 then messageStatus.Text = "Gra: " .. notices[#notices].text end
            if displayState then
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
            if cfg.AutoSpawn and not info.spawned and s.phase ~= 2 and not memory.spawn then
                local t = Auto.spawnSite(s)
                if t then session:send_intent({ type = "spawn", tile = t }); memory.spawn = now; lastAction = "Wybor startu" end
                return
            end
            if s.phase ~= 1 or not info.alive or not info.spawned then lastAction = "Czekam na gre / koniec"; return end
            if not scan or now - lastScan >= cfg.ScanGap then
                local result = Auto.scan(s, function()
                    task.wait()
                    return controller.Alive and controller.Enabled and not controller.Probe and session.state == s
                end)
                if not result then return end
                scan, lastScan = result, os.clock()
            end
            local intent, why, bucket = Auto.decide(s, scan, cfg, memory, os.clock())
            if intent and intent.type == "attack" then
                local target = owner(s, intent.tile)
                if friendly(s, s.local_owner, target) or not s:borders_tile(s.local_owner, intent.tile) then
                    scan = nil; return
                end
            end
            if intent then
                local target = intent.target or (intent.tile and owner(s, intent.tile))
                local foe = target and s.owners[target]
                local before = smallState(s)
                local details = if bucket == "weapon" then memory.nukeDetails elseif bucket == "build" then memory.buildDetails else memory.armyDetails
                local seq = log:add("command", {intent = table.clone(intent), reason = why, before = before,
                    target = foe and {id = foe.id, name = foe.name, troops = foe.troops, tiles = foe.tiles, cap = foe.max_troops},
                    sentTroops = intent.ratio and math.floor(info.troops * math.clamp(intent.ratio, 0.01, 1)),
                    plan = details, naval = bucket == "boat" and memory.navalDetails or nil}, s.tick)
                session:send_intent(intent)
                table.insert(observations, {seq = seq, due = s.tick + 80, before = before})
                memory[bucket] = os.clock()
                lastAction = why
            else
                lastAction = "Rezerwa / czekam na okazje"
                if os.clock() - (memory.lastWaitLog or -math.huge) >= 12 then
                    memory.lastWaitLog = os.clock()
                    log:add("waiting", {state = smallState(s), army = memory.armyText, weapons = memory.weaponText,
                        navy = memory.navalText, diplomacy = memory.diplomacyText}, s.tick)
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
        task.wait(0.75)
    end
end)
print("[RoWorldAuto] Panel gotowy. F8: bot, F9: stop. Test nagrod uruchamiasz osobnym przyciskiem.")
return controller
