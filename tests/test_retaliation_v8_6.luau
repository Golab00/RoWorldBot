local Auto = require("./_generated/bot_module/RoWorldAuto")
local checks = 0
local function check(ok, message) assert(ok, message); checks += 1; print("PASS", message) end
local function fixture()
    local w, h = 440, 320
    local bytes = buffer.create(w * h); buffer.fill(bytes, 0, 128)
    local map = Auto.mapFromBytes(bytes, {id = "retaliation86", width = w, height = h, k_lin = 1}, w, h)
    local grid = buffer.create(w * h * 4)
    for y = 50, 269 do
        for x = 50, 249 do buffer.writei32(grid, (y * w + x) * 4, 1) end
        for x = 250, 419 do buffer.writei32(grid, (y * w + x) * 4, 2) end
        for x = 0, 49 do buffer.writei32(grid, (y * w + x) * 4, 3) end
    end
    return Auto.rawState({map_id = "retaliation86", t = 3500, phase = 1, playing_since = 0, owner = grid, flags = buffer.create(w * h),
        owners = {{1, "Tester", 0, 2, 0, true, 44000, 700000, 3000000, 1000000, 0, 0, 150 * w + 100},
            {2, "ActualAttacker", 0, 2, 0, true, 37400, 800000, 0, 1000000, 0, 0, 150 * w + 320},
            {3, "QuietPower", 0, 2, 0, true, 11000, 4000000, 0, 5000000, 0, 0, 150 * w + 25}}}, map, 1)
end
local function add(s, sid, kind, who, x, y, level)
    s.structures[sid] = {sid = sid, kind = kind, owner = who, tile = y * s.W + x, level = level or 1, active_tick = 0, shots = {}}
    s.structureRevision += 1
    s.built[who] = s.built[who] or {}; s.built[who][kind] = (s.built[who][kind] or 0) + (level or 1)
end
local cfg = Auto.settings({AutoBuild = false, AutoBoats = false, AutoWarships = false, AutoDiplomacy = false, AutoNukes = false, AutoSAM = false})
local s = fixture(); add(s, 1, 0, 1, 100, 150, 2); add(s, 2, 2, 1, 130, 150)
s.owners[1].tiles, s.owners[1].troops, s.owners[1].max_troops, s.owners[1].gold = 18122, 1269223, 1788092, 1049285
s.owners[2].tiles, s.owners[2].troops, s.owners[2].max_troops = 51253, 603431, 7099666
s.owners[3].alive = false
local scan = Auto.scan(s); scan.fronts[0] = nil; local ctx = Auto.context(s, scan, cfg)
local safe, reason, risk = Auto.offensiveRisk(s, cfg, 2)
check(not safe and reason:find("odwetu") and risk.theirCap == 7099666,
    "logged tick 3496 does not treat depleted 603431 home troops as the whole strength of a 7.1M-cap country")
check(not Auto.newWarAllowed(s, scan, cfg, ctx, 2), "economic foundations alone cannot open the logged disproportionate war")
ctx.wars[2] = true
check(not Auto.newWarAllowed(s, scan, cfg, ctx, 2), "remembering an existing war does not bypass offensive retaliation risk")
local memory = {}; local command = Auto.decide(s, scan, cfg, memory, 100)
check(not command and memory.offenseBlocked and memory.offenseBlocked.risk.theirCap == 7099666,
    "actual decision loop records why the dominant player was skipped")
s.owners[1].tiles, s.owners[1].troops, s.owners[1].max_troops = 12520, 1199001, 1601423
s.owners[2].tiles, s.owners[2].troops, s.owners[2].max_troops = 58072, 4501631, 7236696
check(not Auto.offensiveRisk(s, cfg, 2), "logged tick 4115 does not reopen the same vastly stronger opponent after a short quiet period")
s.attacks[10] = {aid = 10, attacker = 1, target = 2, troops = 481, anchor_tile = 150 * s.W + 250}
command = Auto.decide(s, scan, cfg, {}, 100)
check(command and command.type == "retreat" and command.attack_id == 10,
    "a nearly exhausted expedition is recalled instead of feeding the larger defender again")
s.attacks = {}
s.owners[1].troops, s.owners[1].max_troops = 1198601, 1794259
s.attacks[11] = {aid = 11, attacker = 2, target = 1, troops = 633325, anchor_tile = 150 * s.W + 249}
command, reason, safe = Auto.decide(s, scan, cfg, {}, 100)
check(command and command.type == "attack" and safe == "counter",
    "retaliation caution still permits the real defensive cancellation against that opponent")
check(Auto.offensiveRisk(s, Auto.settings({AvoidStrongerEconomies = false}), 2), "offensive retaliation protection can be disabled explicitly")
s.owners[2].kind = 0
check(Auto.offensiveRisk(s, cfg, 2), "new human retaliation rule does not indiscriminately block nation AI")
s.owners[2].kind = 2
s.owners[1].tiles, s.owners[1].troops, s.owners[1].max_troops = 12299, 815741, 1093436
s.owners[2].tiles, s.owners[2].troops, s.owners[2].max_troops = 4477, 4004, 755048
check(Auto.offensiveRisk(s, cfg, 2), "the previously fixed overwhelming Rick opportunity is retained")

local buildCfg = Auto.settings({AutoNukes = false, AutoSAM = false, AutoDiplomacy = false, AutoWarships = false})
local f = fixture(); add(f, 1, 0, 1, 100, 150, 2); add(f, 2, 2, 1, 130, 150)
f.attacks[1] = {aid = 1, attacker = 2, target = 1, troops = 300000, anchor_tile = 160 * f.W + 249}
scan = Auto.scan(f); ctx = Auto.context(f, scan, buildCfg)
check(Auto.activeFrontPoint(f, ctx, 2, 160 * f.W + 249), "actual incoming attack activates its border segment")
check(not Auto.activeFrontPoint(f, ctx, 3, 160 * f.W + 50), "a stronger quiet neighbor does not create a fictitious active fighting front")
check(not Auto.activeFrontPoint(f, ctx, 2, 50 * f.W + 249), "remote part of the same country's border is not automatically the current fight")
ctx.territory.lossPoints = {{to = 2, tick = f.tick, tile = 55 * f.W + 245}}; ctx.activeFrontCache = nil
check(Auto.activeFrontPoint(f, ctx, 2, 50 * f.W + 249), "recent actual territorial losses activate a distant breakthrough independently of the old anchor")
ctx = Auto.context(f, scan, buildCfg); memory = {}; command = Auto.buildPlan(f, scan, buildCfg, memory, ctx, true)
check(command and command.kind == "defense" and memory.buildDetails.defenseAgainst == 2 and command.tile % f.W > 150,
    "emergency fort protects the actual attacker despite a much stronger quiet neighbor elsewhere")

local minor = fixture(); add(minor, 1, 0, 1, 100, 150, 2); add(minor, 2, 2, 1, 130, 150); add(minor, 3, 3, 1, 120, 100)
minor.owners[1].tiles, minor.owners[1].troops, minor.owners[1].max_troops, minor.owners[1].gold = 11612, 1484453, 1818271, 220209
minor.attacks[1] = {aid = 1, attacker = 2, target = 1, troops = 13730, anchor_tile = 100 * minor.W + 249}
local losses = {}; for x = 210, 249 do table.insert(losses, (100 * minor.W + x) * 1024 + 2) end
minor:apply_delta({t = 3501, tiles = losses}); scan = Auto.scan(minor); ctx = Auto.context(minor, scan, buildCfg)
check(ctx.groundLosing and not ctx.groundCritical, "small logged-style pressure is distinguished from a collapsing ground front")
check(not Auto.buildPlan(minor, scan, buildCfg, {}, ctx, true), "minor pressure cannot repeatedly buy emergency forts using the economic reserve")

local artillery = fixture(); artillery.owners[1].troops, artillery.owners[1].gold = 69453, 594892
artillery.equipment = Auto.newEquipment(); Auto.applyInventory(artillery.equipment, {unlocks = {"artillery"}})
add(artillery, 1, 3, 2, 260, 150)
Auto.rememberAggressor(artillery, 2)
scan = Auto.scan(artillery); ctx = Auto.context(artillery, scan, buildCfg)
check(Auto.arsenalBuildPlan(artillery, scan, buildCfg, {}, ctx) ~= nil, "a legal affordable artillery position remains available in a stable country")
ctx.criticalLoss, ctx.landTimeLeft = true, 4
memory = {}
check(not Auto.arsenalBuildPlan(artillery, scan, buildCfg, memory, ctx, true) and memory.buildText:find("traci teren"),
    "logged collapse does not spend another 150K on a battery needing 80 ticks to finish")
print("TOTAL RETALIATION V8.6 CHECKS", checks)
