local Auto = require("./_generated/bot_module/RoWorldAuto")
local checks = 0
local function check(ok, text) assert(ok, text); checks += 1; print("PASS", text) end
local function fixture()
    local w, h = 500, 260
    local bytes = buffer.create(w * h); buffer.fill(bytes, 0, 128)
    buffer.fill(bytes, 0, 32, w * 100)
    local map = Auto.mapFromBytes(bytes, {id = "regression84", width = w, height = h, k_lin = 1}, w, h)
    local owner = buffer.create(w * h * 4)
    for y = 100, 179 do
        for x = 20, 179 do buffer.writei32(owner, (y * w + x) * 4, 1) end
        for x = 180, 339 do buffer.writei32(owner, (y * w + x) * 4, 2) end
    end
    return Auto.rawState({map_id = "regression84", t = 1200, phase = 1, playing_since = 0, owner = owner, flags = buffer.create(w * h),
        owners = {{1, "Tester", 0, 2, 0, true, 12800, 700000, 400000, 1000000, 0, 0, 140 * w + 90},
            {2, "Neighbor", 0, 2, 0, true, 12800, 800000, 0, 1000000, 0, 0, 140 * w + 260}}}, map, 1)
end
local function add(s, sid, kind, who, x, y, level)
    local b = {sid = sid, kind = kind, owner = who, tile = y * s.W + x, level = level or 1, active_tick = 0, shots = {}}
    s.structures[sid] = b; s.structureRevision += 1
    s.built[who] = s.built[who] or {}; s.built[who][kind] = (s.built[who][kind] or 0) + b.level
    return b
end
local cfg = Auto.settings({AutoBoats = false, AutoWarships = false, AutoDiplomacy = false})

-- A recent aggressor's valuable target used to stop the entire economy queue while saving for a silo.
local s = fixture()
add(s, 1, 0, 1, 70, 145, 2); add(s, 2, 1, 1, 35, 100)
add(s, 3, 1, 2, 300, 100); add(s, 4, 5, 2, 300, 140)
Auto.rememberAggressor(s, 2)
local scan = Auto.scan(s); local ctx = Auto.context(s, scan, cfg)
local memory = {}; local silo = Auto.siloNeed(s, scan, cfg, memory, ctx)
check(silo and not silo.affordable and select(1, Auto.threatPriority(s, ctx, 2)) == 2,
    "reproduce recent aggressor and an unaffordable useful silo plan")
local economy = Auto.economyPriorities(s, scan, cfg, Auto.infrastructure(s))
check(economy.foundationReady and economy.needsFoundation, "peace-fort eligibility does not mean the first factory exists")
local command = Auto.buildPlan(s, scan, cfg, memory, ctx, false)
check(command and command.kind == "factory", "first factory is not blocked by saving for a retaliatory silo")
check(not memory.weaponText or not memory.weaponText:find("Oszczedza na silos"), "do not report silo savings as the priority while the economic foundation is missing")

-- The log's 1,316,320 / 1,580,534 army and a small losing front must not spend the factory money.
local r = fixture(); r.equipment = Auto.newEquipment(); Auto.applyInventory(r.equipment, {unlocks = {"reinforce"}})
local mine = r.owners[1]
mine.troops, mine.max_troops, mine.gold = 1316320, 1580534, 158250
local pressure = {losing = true, criticalLoss = false, totalIncoming = 88000, wars = {[2] = true}}
check(not Auto.reinforcementPlan(r, cfg, {}, pressure, 100), "do not buy reinforcements at 83 percent army capacity for a small attack")
mine.troops = 600000
check(not Auto.reinforcementPlan(r, cfg, {}, pressure, 100), "noncritical reinforcement preserves the economic cash reserve")
mine.gold = 350000
memory = {}; command = Auto.reinforcementPlan(r, cfg, memory, pressure, 100)
check(command and not memory.arsenalDetails.urgent, "a depleted wartime army may buy reinforcements with enough savings")
mine.gold, mine.troops = 158250, 1316320
pressure.criticalLoss = true
memory = {}; command = Auto.reinforcementPlan(r, cfg, memory, pressure, 100)
check(command and memory.arsenalDetails.urgent and memory.arsenalDetails.gain == 264214,
    "critical territorial losses still permit emergency reinforcements")
pressure.criticalLoss, pressure.totalIncoming = false, 1000000
check(Auto.reinforcementPlan(r, cfg, {}, pressure, 100) ~= nil, "a very large incoming army may also use emergency reinforcements")
mine.troops = 1560000
check(not Auto.reinforcementPlan(r, cfg, {}, pressure, 100), "tiny reinforcement gains are not bought even under pressure")

-- Guard only an opening land attack on a substantial human country, never the existing counter path.
ctx = Auto.context(s, scan, cfg)
local allowed, reason = Auto.newWarAllowed(s, scan, cfg, ctx, 2)
check(not allowed and reason:find("zaplecza"), "do not start a comparable human war before economic foundations")
ctx.wars[2] = true
check(Auto.newWarAllowed(s, scan, cfg, ctx, 2), "economic opening guard does not block an existing war or defense")
ctx.wars[2] = nil; s.owners[2].tiles = 1000
check(Auto.newWarAllowed(s, scan, cfg, ctx, 2), "allow finishing a small enemy remnant")
s.owners[2].tiles, s.owners[2].kind = 12800, 0
check(Auto.newWarAllowed(s, scan, cfg, ctx, 2), "the human opening guard does not block fighting nation AI")
s.owners[2].kind = 2
check(Auto.newWarAllowed(s, scan, Auto.settings({ProtectEconomicOpening = false}), ctx, 2), "economic opening guard can be disabled explicitly")
add(s, 5, 2, 1, 95, 145)
check(Auto.newWarAllowed(s, scan, cfg, ctx, 2), "completed foundations and savings allow a new human war")
s.owners[1].gold = 27250
check(not Auto.newWarAllowed(s, scan, cfg, ctx, 2), "do not open a comparable human war with almost no cash")

local opening = fixture(); opening.owners[1].gold = 0
scan = Auto.scan(opening)
scan.fronts[0] = nil; scan.falloutFronts[0] = nil
memory = {}; command = Auto.decide(opening, scan, cfg, memory, 100)
check(not command and memory.offenseBlocked and memory.offenseBlocked.target == 2,
    "the actual decision loop waits instead of opening the blocked human war")

-- A newly observed attack has insufficient loss history for a slow front assumption.
local f = fixture(); f.owners[1].troops = 724000
f:apply_delta({t = 1201, ev = {{14, 1, 2, 1, 690398, 140 * f.W + 179, false}}})
check(f.attacks[1].first_seen_tick == 1201, "record when an attack is first observed")
f:apply_delta({t = 1221, ev = {{14, 1, 2, 1, 680000, 140 * f.W + 179, false}}})
check(f.attacks[1].first_seen_tick == 1201, "normal attack updates preserve observation age")
scan = Auto.scan(f); ctx = Auto.context(f, scan, cfg)
local speed = Auto.frontSpeed(f, scan, ctx, 2, 140 * f.W + 179)
check(speed > 0.5, "fresh strong attack uses a conservative source-based speed before sufficient loss history")
check(Auto.frontArrival(f, scan, ctx, 140 * f.W + 167) < 50,
    "a site just twelve fields behind a fresh strong front is unsafe for a fort")
memory = {}; command = Auto.buildPlan(f, scan, cfg, memory, ctx, true)
check(not command or command.kind ~= "defense" or memory.buildDetails.estimatedFrontArrivalTicks > 62.5,
    "a newly chosen fort must finish with a margin or be skipped")
check(not command or memory.buildDetails.frontModel == "observed_plus_source_speed", "construction telemetry identifies the changed front model")
f:apply_delta({t = 1231, ev = {{14, 1, 2, 1, 900000, 140 * f.W + 179, false}}})
check(f.attacks[1].first_seen_tick == 1231, "large reinforcement resets the attack's uncertainty window")

-- Preserve numeric kind zero and immutable decision snapshots in Roblox-compatible log objects.
local log = Auto.newLog(100)
local infra = Auto.infrastructure(s)
log:add("infrastructure", infra, 1200)
local stored = log.entries[1].data
check(stored.levels["0"] == 2 and stored.levels["1"] == 1 and stored.levels["2"] == 1 and stored.levels[0] == nil,
    "zero-based building kinds are exported as explicit string keys")
check(stored.cityBuildings == 1 and stored.cityLevels == 2 and stored.portBuildings == 1 and stored.factoryBuildings == 1,
    "flat fields retain both building counts and total levels")
infra.levels[0] = 99
check(stored.levels["0"] == 2, "later mutations cannot rewrite historical log data")
local list = Auto.logValue({{tile = 10}, {tile = 20}})
check(#list == 2 and list[1].tile == 10 and list["1"] == nil, "ordinary one-based lists remain JSON arrays")
local cycle = {}; cycle.self = cycle
check(Auto.logValue(cycle).self == "[cycle]", "accidental cyclic diagnostics cannot break log export")
local fortOnly = fixture(); add(fortOnly, 1, 3, 1, 60, 140)
local fortLog = Auto.logValue(Auto.infrastructure(fortOnly))
check(fortLog.levels["0"] == 0 and fortLog.levels["3"] == 1, "building-kind keys remain explicit even after every city is lost")
print("TOTAL REGRESSION V8.4 CHECKS", checks)
