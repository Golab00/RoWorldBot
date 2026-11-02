local Auto = require("./_generated/bot_module/RoWorldAuto")
local WorldMap = require("../vendor/roworld/src/shared/Core/WorldMap")
local Sim = require("../vendor/roworld/src/shared/Core/Sim")
local Defs = require("../vendor/roworld/src/shared/Core/Defs")
local checks = 0
local function check(ok, text) assert(ok, text); checks += 1; print("PASS", text) end
local function fixture(sea)
    local w, h = 300, 240
    local bytes = buffer.create(w * h); buffer.fill(bytes, 0, 128)
    if sea then buffer.fill(bytes, 0, 32, w * 100) end
    local map = Auto.mapFromBytes(bytes, {id = "economy", width = w, height = h, k_lin = 1}, w, h)
    local owner = buffer.create(w * h * 4)
    for y = 100, 159 do
        for x = 20, 79 do buffer.writei32(owner, (y * w + x) * 4, 1) end
        for x = 80, 139 do buffer.writei32(owner, (y * w + x) * 4, 2) end
    end
    local s = Auto.rawState({map_id = "economy", t = 1200, phase = 1, playing_since = 0, owner = owner, flags = buffer.create(w * h),
        owners = {{1, "Tester", 0, 2, 0, true, 3600, 700000, 3000000, 1000000, 0, 0, 130 * w + 50},
            {2, "Neighbor", 0, 2, 0, true, 3600, 800000, 0, 1000000, 0, 0, 130 * w + 110}}}, map, 1)
    return s, bytes
end
local function add(s, sid, kind, who, x, y, level)
    local b = {sid = sid, kind = kind, owner = who, tile = y * s.W + x, level = level or 1, active_tick = 0, shots = {}}
    s.structures[sid] = b; s.structureRevision += 1
    s.built[who] = s.built[who] or {}; s.built[who][kind] = (s.built[who][kind] or 0) + b.level
    return b
end
local cfg = Auto.settings({AutoBoats = false, AutoWarships = false, AutoNukes = false, AutoDiplomacy = false})
local s = fixture(true)
add(s, 99, 1, 2, 110, 100)
local scan = Auto.scan(s); local ctx = Auto.context(s, scan, cfg)
check(not Auto.buildPlan(s, scan, cfg, {}, ctx, true), "no peacetime fort is treated as an emergency ahead of economic development")
local memory = {}; local command = Auto.buildPlan(s, scan, cfg, memory, ctx, false)
check(command and command.kind == "city", "first city precedes forts and optional weapons")
check(memory.buildDetails.economy.cities == 0 and memory.buildDetails.priority == "pierwsze miasto",
    "build log explains the economic foundation priority")
add(s, 1, 0, 1, command.tile % s.W, command.tile // s.W)
scan = Auto.scan(s); ctx = Auto.context(s, scan, cfg)
command = Auto.buildPlan(s, scan, cfg, {}, ctx, false)
check(command and command.kind == "port", "first useful trade port follows the first city")
add(s, 2, 1, 1, command.tile % s.W, command.tile // s.W)
scan = Auto.scan(s); ctx = Auto.context(s, scan, cfg)
command = Auto.buildPlan(s, scan, cfg, {}, ctx, false)
check(command and command.kind == "factory", "first factory is prioritized before a wall of forts")
local city = s.structures[1]
check(s.map.range_d2(command.tile, city.tile) <= 110^2 or s.map.range_d2(command.tile, s.structures[2].tile) <= 110^2,
    "factory placement can actually connect to owned city or port")
add(s, 3, 2, 1, command.tile % s.W, command.tile // s.W)
scan = Auto.scan(s); ctx = Auto.context(s, scan, cfg)
command = Auto.buildPlan(s, scan, cfg, {}, ctx, false)
check(command and command.kind == "city", "second city level is developed before discretionary fortification")
check(command.tile ~= s.structures[1].tile, "second city prefers a separate safe site over concentrating all capacity in one building")
city.level = 2; s.built[1][0] = 2; s.structureRevision += 1
scan = Auto.scan(s); ctx = Auto.context(s, scan, cfg)
local infra = Auto.infrastructure(s)
local economy = Auto.economyPriorities(s, scan, cfg, infra)
check(economy.foundationReady and economy.peaceFortLimit == 2, "two city levels plus port and factory support at most two peacetime forts")
check(infra.counts[0] == 1 and infra.cityLevels == 2, "infrastructure separates city buildings from total city levels")
command = Auto.buildPlan(s, scan, cfg, {}, ctx, false)
check(command and command.kind == "defense", "peace fortification remains possible after basic development")

local empty = fixture(false); empty.owners[1].gold = 100000
scan = Auto.scan(empty); ctx = Auto.context(empty, scan, cfg)
check(not Auto.buildPlan(empty, scan, cfg, {}, ctx, false), "do not spend a cheap fort's price while still saving for the first city")
local mature = fixture(false)
add(mature, 1, 0, 1, 35, 135, 2); add(mature, 2, 2, 1, 55, 135)
mature.owners[1].troops = 200000; mature.owners[1].gold = 100000
scan = Auto.scan(mature); ctx = Auto.context(mature, scan, cfg)
check(not Auto.buildPlan(mature, scan, cfg, {}, ctx, false), "peacetime fort cannot empty the economic cash reserve")
local manual = Auto.infrastructure(mature)
manual.counts[3], manual.forts = 8, 8
economy = Auto.economyPriorities(mature, scan, cfg, manual)
check(manual.forts > economy.peaceFortLimit, "an already over-fortified country has no permission for more discretionary forts")
mature.owners[1].gold = 3000000
mature.owners[1].tiles = 20000; mature.owners[1].troops = 800000
economy = Auto.economyPriorities(mature, scan, cfg, Auto.infrastructure(mature))
check(economy.targetCities > 2 and economy.plans[1].kind == "city", "large territory and a filled army limit prioritize additional cities")
local largeInfra = {cityLevels = 12, portLevels = 3, factoryLevels = 3, civilLevels = 18, forts = 0}
check(Auto.economyPriorities(mature, scan, cfg, largeInfra).peaceFortLimit == cfg.MaxPeaceDefensePosts,
    "even a developed economy does not build the full wartime fort cap in peacetime")

local war = fixture(false)
war.owners[1].gold = 50000
war.attacks[1] = {aid = 1, attacker = 2, target = 1, troops = 300000, anchor_tile = 130 * war.W + 79}
scan = Auto.scan(war); ctx = Auto.context(war, scan, cfg)
command = Auto.buildPlan(war, scan, cfg, {}, ctx, true)
check(command and command.kind == "defense", "actual invasion still permits an emergency fort before economic foundations")
local loss = {}; for y = 100, 109 do for x = 20, 79 do table.insert(loss, (y * war.W + x) * 1024 + 2) end end
war:apply_delta({t = 1201, tiles = loss}); scan = Auto.scan(war); ctx = Auto.context(war, scan, cfg)
check(not Auto.buildPlan(war, scan, cfg, {}, ctx, false), "economic change does not reintroduce city purchases during a collapsing front")
local mild = fixture(false)
mild.attacks[1] = {aid = 1, attacker = 2, target = 1, troops = 5000, anchor_tile = 130 * mild.W + 79}
scan = Auto.scan(mild); ctx = Auto.context(mild, scan, cfg)
command = Auto.buildPlan(mild, scan, cfg, {}, ctx, false)
check(command and command.kind == "city", "a minor probe without losses does not indefinitely freeze safe economic development")

-- Verify the reason for buying a city with the actual original economy code.
local raw, bytes = fixture(false)
local world = WorldMap.new(raw.W, raw.H); world.id = "economy"; buffer.copy(world.tile_bytes, 0, bytes); world:_derive()
local sim = Sim.new(world, {nations = false, tribes = 0, max_humans = 2, spawn_ticks = 10, seed = 12})
local me = sim:add_human("me", "Tester")
sim.o_ai[me], sim.o_spawned[me], sim.phase, sim.tick = 0, 1, Defs.PHASE_PLAYING, 1209
for t = 0, raw.N - 1 do if buffer.readi32(raw.owner, t * 4) == 1 then sim:set_owner(t, me) end end
sim.o_troops[me], sim.o_gold[me] = 200000, 2000000
sim:_economy_tick()
local capBefore, incomeBefore = sim.o_cap[me], sim.o_income[me]
local built = sim:add_struct(0, me, 130 * raw.W + 50)
sim.tick = built.active_tick; sim:construction_tick(); sim:_economy_tick()
check(sim.o_cap[me] == capBefore + 250000, "real city adds 250K troop capacity")
check(sim.o_income[me] == incomeBefore, "city is not misrepresented as passive gold income")
print("TOTAL ECONOMY V8.3 CHECKS", checks)
