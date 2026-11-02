local Auto = require("./_generated/bot_module/RoWorldAuto")
local WorldMap = require("../vendor/roworld/src/shared/Core/WorldMap")
local Rules = require("../vendor/roworld/src/shared/Core/Rules")
local Sim = require("../vendor/roworld/src/shared/Core/Sim")
local Defs = require("../vendor/roworld/src/shared/Core/Defs")
local Protocol = require("../vendor/roworld/src/shared/Net/Protocol")
local checks = 0
local function check(ok, description) assert(ok, description); checks += 1; print("PASS", description) end
local function fixture(w, h, ocean, far)
    local map = WorldMap.new(w, h); map.id = "v7"
    buffer.fill(map.tile_bytes, 0, if ocean then 32 else 128)
    local x2 = if ocean then w - 80 elseif far then w - 140 else 80
    if ocean then
        for y = 100, 159 do for x = 20, 79 do buffer.writeu8(map.tile_bytes, y * w + x, 128) end end
        for y = 100, 159 do for x = x2, x2 + 59 do buffer.writeu8(map.tile_bytes, y * w + x, 128) end end
    end
    map:_derive()
    local grid = buffer.create(map.N * 4)
    for y = 100, 159 do
        for x = 20, 79 do buffer.writei32(grid, (y * w + x) * 4, 1) end
        for x = x2, x2 + 59 do buffer.writei32(grid, (y * w + x) * 4, 2) end
    end
    local raw = Auto.mapFromBytes(map.tile_bytes, {id = map.id, width = w, height = h, k_lin = 1}, w, h)
    local snap = {map_id = map.id, map_w = w, map_h = h, t = 1200, phase = 1, playing_since = 0,
        owner = grid, flags = buffer.create(map.N), owners = {
            {1, "Tester", 0xFFFFFFFF, 2, 0, true, 3600, 700000, 12000000, 1000000, 1000, 0, 130 * w + 50},
            {2, "M_RTL18", 0xFFFFFFFF, 2, 0, true, 3600, 500000, 100000, 800000, 1000, 0, 130 * w + x2 + 20},
            {3, "Remote", 0xFFFFFFFF, 2, 0, true, 0, 500000, 100000, 800000, 1000, 0, 30 * w + w - 20},
        }}
    return Auto.rawState(snap, raw, 1), map, snap
end
local function building(s, sid, kind, who, x, y, level)
    local b = {sid = sid, kind = kind, owner = who, tile = y * s.W + x, active_tick = 0, level = level or 1, shots = {}}
    s.structures[sid] = b
    return b
end
local function equip(s, keys)
    s.equipment = Auto.newEquipment(); Auto.applyInventory(s.equipment, {unlocks = keys}); return s.equipment
end
local cfg = Auto.settings({AutoBoats = false})
local eq = Auto.newEquipment()
local a = {equipment = eq}
check(not Auto.canUse(a, cfg, "railgun"), "unknown inventory does not pretend equipment is owned")
check(not Auto.applyInventory(eq, {owned = {"railgun"}}) and not eq.loaded, "cosmetic ownership is not mistaken for Arsenal unlocks")
check(Auto.applyInventory(eq, {unlocks = {"railgun", "reload2x"}, stars = 155}), "read unlock array from the real inventory payload")
check(Auto.canUse(a, cfg, "railgun") and not Auto.canUse(a, cfg, "mega") and eq.owned.reload2x, "activate only server-confirmed unlocks in AUTO")
check(not Auto.applyInventory(eq, {unlocks = {"railgun", "reload2x"}}), "identical inventory does not create repeated change records")
check(Auto.applyInventory(eq, {unlocks = {airfield = true}}) and eq.owned.airfield and not eq.owned.railgun, "refresh handles set payloads and replaces old ownership")
local off = Auto.settings({EquipmentModes = {airfield = "off", mega = "owned"}})
check(not Auto.canUse(a, off, "airfield") and Auto.canUse(a, off, "mega"), "manual OFF and MAM settings are independent")
off.EquipmentModes.airfield = "auto"
check(cfg.EquipmentModes.airfield == nil, "equipment mode tables do not leak between configurations")
eq.blocked.mega = true
check(not Auto.canUse(a, off, "mega"), "a server refusal blocks repeated attempts with an incorrect manual selection")
check(not Auto.canUse(a, Auto.settings({AutoArsenal = false, EquipmentModes = {mega = "owned"}}), "mega"), "master Arsenal setting is honored")

local s = fixture(400, 240, false)
local scan, ctx = Auto.scan(s), nil
ctx = Auto.context(s, scan, cfg)
s:apply_delta({t = 1201, ev = {{18, 2, 3, 2, false}, {22, 2, 1501}}})
s.tick = 10000
local score, why = Auto.allianceScore(s, scan, 2, cfg, Auto.context(s, scan, cfg))
check(score < -50 and why:find("zdradzil"), "reject betrayal against a third party long after its badge expired")
s.requests[2049] = s.tick
local command = Auto.diplomacy(s, scan, cfg, {}, Auto.context(s, scan, cfg), 100)
check(command and command.type == "ally_reply" and not command.accept, "never accept an offer from a known betrayer")
s.requests = {}; command = Auto.diplomacy(s, scan, cfg, {}, Auto.context(s, scan, cfg), 100)
check(not command, "never propose to a known betrayer")

local r, _, snapshot = fixture(400, 240, false)
r:apply_delta({t = 1201, ev = {{14, 71, 2, 1, 50000, 130 * r.W + 79, false}, {15, 71}}})
check(r.aggressors[2] == 1201, "remember an attack even when it ended before the next decision")
score, why = Auto.allianceScore(r, Auto.scan(r), 2, cfg, Auto.context(r, Auto.scan(r), cfg))
check(score < -50 and why:find("zaatakowal"), "previous aggressor is excluded from alliances")
local history = Auto.bindHistory(r)
snapshot.t = 1202
local resumed = Auto.rawState(snapshot, r.map, 1)
history = Auto.bindHistory(resumed, history)
check(resumed.aggressors[2] == 1201, "a resync preserves past aggression in the same match")
snapshot.t = 1
local newMatch = Auto.rawState(snapshot, r.map, 1)
Auto.bindHistory(newMatch, history)
check(not newMatch.aggressors[2], "a new match clears the old blacklist")
Auto.gameMessage(newMatch, 1, 3, "M_RTL18 is counter-attacking you!")
check(newMatch.aggressors[2] ~= nil, "the displayed counterattack notice also updates aggression")

local m = fixture(400, 240, false)
local edits = {}
for y = 100, 109 do for x = 20, 79 do table.insert(edits, (y * m.W + x) * 1024 + 2) end end
-- An unrelated conquest on the opposite end of the map must also be recorded.
local remoteTile = 20 * m.W + 380
table.insert(edits, remoteTile * 1024 + 3)
m:apply_delta({t = 1201, tiles = edits})
local trend = Auto.mapTrend(m, 50)
check(trend.lost == 600 and trend.changed == 601 and m.owners[1].tiles == 3000, "count actual lost tiles from deltas rather than waiting for UI warnings")
check(trend.actors[3].gained == 1 and #trend.hotspots >= 2 and buffer.readi32(m.owner, remoteTile * 4) == 3,
    "maintain the full map and regional activity at its far end")
scan = Auto.scan(m); ctx = Auto.context(m, scan, cfg)
check(ctx.losing and ctx.criticalLoss and ctx.defending and ctx.reserve >= m.owners[1].max_troops * 0.70, "rapid losses activate a higher home reserve")
check(Auto.buildPlan(m, scan, cfg, {}, ctx, false) == nil, "round regression: do not spend 500K or 1M on economic buildings during invasion")
local beforeCap = m.owners[1].max_troops
m.attacks[99] = {aid = 99, attacker = 1, target = 3, troops = 100000, anchor_tile = remoteTile}
command = Auto.decide(m, scan, Auto.settings({AutoBuild = false, AutoWarships = false, AutoDiplomacy = false, AutoNukes = false}), {}, 100)
check(command and command.type == "retreat" and command.attack_id == 99, "recall an expedition when the country is collapsing")
m.tick += 60; ctx = Auto.context(m, scan, cfg)
check(not ctx.losing and ctx.defending, "hold defensive posture briefly after a sudden loss instead of immediately launching another expedition")
m.tick += 250
check(Auto.mapTrend(m, 50).changed == 0, "old changes expire from the short observation window")

local p = fixture(400, 240, false)
p.attacks[1] = {aid = 1, attacker = 1, target = 2, troops = 10000}
equip(p, {"reinforce"}); p.owners[1].troops = 300000
scan = Auto.scan(p); ctx = Auto.context(p, scan, cfg)
local memory = {}
command = Auto.reinforcementPlan(p, cfg, memory, ctx, 100)
check(command and command.type == "reinforce" and memory.arsenalDetails.gain == 200000, "buy meaningful reinforcements in a war")
p:apply_delta({t = 1201, ev = {{33, 1, 200000, 1501}}})
check(p.reinforceReady == 1501 and not Auto.reinforcementPlan(p, cfg, {}, ctx, 100), "honor the server's reinforcement cooldown event")
Auto.gameMessage(p, 1, 0, "Reinforcements are ready in 17 s")
check(p.reinforceReady == p.tick + 170, "recover a pre-existing cooldown from the game message")
Auto.gameMessage(p, 1, 0, "Unlock Reinforcements in the Arsenal first")
check(not Auto.canUse(p, cfg, "reinforce"), "stop a locked ability after its server message")

local ar = fixture(400, 240, false)
ar.attacks[1] = {aid = 1, attacker = 1, target = 2, troops = 10000}
local fort = building(ar, 2, 3, 2, 95, 130)
equip(ar, {"artillery"})
scan = Auto.scan(ar); ctx = Auto.context(ar, scan, cfg)
command = Auto.arsenalBuildPlan(ar, scan, cfg, {}, ctx)
check(command and command.kind == "artillery" and ar.map.range_d2(command.tile, fort.tile) <= 45^2, "put owned artillery where an actual enemy structure is in range")
check(not Auto.arsenalBuildPlan(ar, scan, Auto.settings({AttackHumans = false}), {}, ctx), "do not place automatic artillery to shoot humans when that setting is off")
check(#scan.enemyForts == 1 and scan.enemyForts[1].sid == fort.sid, "the map scan explicitly identifies enemy forts")
local airfield = building(ar, 3, 7, 1, 45, 130)
equip(ar, {"airfield"})
memory = {}; command = Auto.strikePlan(ar, cfg, memory, ctx)
check(command and command.kind == "airstrike" and memory.arsenalDetails.samInterceptable == false,
    "use a free air strike from an unlocked airfield against infrastructure")
airfield.shots = {ar.tick}
check(Auto.readyMissiles(ar, airfield, ar.tick + 299) == 0 and Auto.readyMissiles(ar, airfield, ar.tick + 300) == 1,
    "airfields reload for 300 ticks rather than silo/SAM's 90")
airfield.shots = {ar.tick - 150}
check(Auto.readyMissiles(ar, airfield, ar.tick + 150) == 1, "honor Rapid Reload timestamps without applying the bonus twice")
airfield.tile = 130 * ar.W + 300; airfield.shots = {}
check(not Auto.strikePlan(ar, cfg, {}, ctx), "respect the airfield's 156-tile range")
local railgun = building(ar, 4, 8, 1, 30, 130)
equip(ar, {"railgun"})
command = Auto.strikePlan(ar, cfg, {}, ctx)
check(command and command.kind == "slug", "use an owned railgun from its separate launcher")
railgun.shots = {ar.tick}
check(Auto.readyMissiles(ar, railgun, ar.tick + 249) == 0 and Auto.readyMissiles(ar, railgun, ar.tick + 250) == 1,
    "railgun reload is 250 ticks")
for _, name in ipairs({"artillery", "airfield", "railgun"}) do
    check(ar.rules.cost_of(ar, 1, name) == Rules.cost_of(ar, 1, name), "independent " .. name .. " price agrees with source")
end
check(not ar.rules.placement(ar, 1, "railgun", railgun.tile).ok, "Arsenal structures cannot be upgraded as if they were silos")
ar:apply_delta({t = ar.tick + 1, ev = {{12, 80, 7, 2, fort.tile, airfield.tile, ar.tick + 1, 20}}})
check(ar.nuclearAlert == nil, "an uninterceptable Air Strike does not provoke spending on a useless SAM")

local nu = fixture(520, 240, false, true)
nu.attacks[1] = {aid = 1, attacker = 1, target = 2, troops = 10000}
building(nu, 2, 5, 2, 400, 130)
scan = Auto.scan(nu); ctx = Auto.context(nu, scan, cfg)
memory = {}; local need = Auto.siloNeed(nu, scan, cfg, memory, ctx)
check(need and need.first and need.affordable and need.required == 1, "buy the first silo for a valuable feasible target")
building(nu, 10, 0, 1, 25, 110, 2)
building(nu, 11, 2, 1, 50, 110)
command = Auto.buildPlan(nu, scan, cfg, {}, ctx, false)
check(command and command.kind == "silo", "a justified silo takes priority over another city")
nu.owners[1].gold = 2000000
need = Auto.siloNeed(nu, scan, cfg, {}, ctx)
check(need and not need.affordable and need.total > 2600000, "silo budget includes the ammunition share and reserves")
local silo = building(nu, 1, 5, 1, 45, 130, 1)
nu.owners[1].gold = 12000000
check(not Auto.siloNeed(nu, scan, cfg, {}, ctx), "do not buy surplus silos when the existing one has enough capacity")
silo.shots = {nu.tick}
check(not Auto.siloNeed(nu, scan, cfg, {}, ctx), "wait for a reloading silo instead of replacing it")
silo.shots = {}
for _, key in ipairs({"mega", "scatter"}) do check(nu.rules.nuke_cost(key) == Rules.nuke_cost(key), "correct ammunition price: " .. key) end
-- Wide clusters make different unlocks useful; ordinary atoms should not always win by default.
local special = fixture(700, 300, false, true)
special.owners[1].gold = 30000000
special.attacks[1] = {aid = 1, attacker = 1, target = 2, troops = 10000}
building(special, 1, 5, 1, 50, 130)
local function enemyStructure(id, x, y)
    local b = building(special, id, 5, 2, x, y)
    buffer.writei32(special.owner, b.tile * 4, 2)
end
enemyStructure(2, 580, 130)
for i = 0, 7 do
    local angle = i * math.pi / 4
    enemyStructure(3 + i, math.floor(580 + math.cos(angle) * 42), math.floor(130 + math.sin(angle) * 42))
end
equip(special, {"mega"})
local specialScan = Auto.scan(special)
local specialCtx = Auto.context(special, specialScan, cfg)
command = Auto.nukePlan(special, specialScan, cfg, {}, specialCtx)
check(command and command.kind == "mega" and command.amount == 1, "choose a Mega Nuke for a sufficiently wide valuable cluster")
equip(special, {"scatter"})
building(special, 20, 4, 2, 580, 130)
memory = {}; command = Auto.nukePlan(special, specialScan, cfg, memory, Auto.context(special, specialScan, cfg))
check(command and command.kind == "scatter" and memory.nukeDetails.randomSpread,
    "use unlocked Scattershot when a single silo cannot beat SAM with ordinary atoms, recording its uncertain spread")
equip(special, {})
command = Auto.nukePlan(special, specialScan, cfg, {}, Auto.context(special, specialScan, cfg))
check(not command, "the same SAM target does not trigger locked Mega or Scattershot ammunition")

local sea, seaMap = fixture(900, 260, true)
local port = building(sea, 1, 1, 1, 79, 130)
sea.owners[1].gold = 3000000
sea.units[20] = {uid = 20, kind = 0, owner = 2, path = {130 * sea.W + 120, 130 * sea.W + 80},
    start_tick = sea.tick, ticks_per_tile_x100 = 100, troops = 200000}
scan = Auto.scan(sea); ctx = Auto.context(sea, scan, cfg); memory = {}
command = Auto.warshipPlan(sea, scan, cfg, memory, ctx, 100, true)
check(command and command.type == "build" and command.kind == "warship" and memory.navalDetails.port == port.sid,
    "build a warship from a real port to intercept a transport heading for our coast")
check(sea.rules.cost_of(sea, 1, "warship") == 250000, "first warship has the real 250K price")
sea.units[21] = {uid = 21, kind = 2, owner = 1, path = {130 * sea.W + 90}, hp = 600, max_hp = 1000, state = 1}
ctx = Auto.context(sea, scan, cfg)
command = Auto.warshipPlan(sea, scan, Auto.settings({AutoBuild = false}), {}, ctx, 100, false)
check(not command, "do not cancel a damaged warship's automatic retreat to its port")
sea.units[21].hp, sea.units[21].state = 1000, 0
sea.units[20].path = {130 * sea.W + 400, 130 * sea.W + 300}
sea.units[22] = {uid = 22, kind = 2, owner = 2, path = {130 * sea.W + 280}, hp = 500, max_hp = 1000, state = 0}
ctx = Auto.context(sea, scan, cfg)
command = Auto.warshipPlan(sea, scan, Auto.settings({AutoBuild = false}), {}, ctx, 100, false)
check(command and command.type == "move_warship" and command.uid == 21, "give a healthy available warship a useful patrol order")
sea.structures = {}; ctx = Auto.context(sea, scan, cfg)
check(not Auto.warshipPlan(sea, scan, cfg, {}, ctx, 100, false), "never pretend a warship can be built without a finished port")
local enemyPort = building(sea, 70, 1, 2, 820, 130)
local docked = {uid = 90, kind = 2, owner = 2, path = {130 * sea.W + 819}, hp = 400, max_hp = 1000, state = 2}
check(Auto.shipHealthAt(sea, docked, sea.tick + 50) == 700, "estimate passive and docked repair before a future engagement")
check(Auto.shipHealthAt(sea, docked, sea.tick + 200) == 1000, "predicted repair never exceeds maximum warship health")
sea.structures[70] = nil
sea.structures[1] = port
sea:apply_delta({t = 1201, ev = {{9, 25, 2, 1, {130 * sea.W + 80}, 1201, 100, 0, 1000, 1000, 0, 0, 130 * sea.W + 80}}})
check(sea.built[1][15] == 1 and sea.rules.cost_of(sea, 1, "warship") == Rules.cost_of(sea, 1, "warship"), "warship events update escalating build costs")

sea.units = {}; sea.tick = 2000; sea.owners[1].gold = 12000000
silo = building(sea, 2, 5, 1, 50, 130)
for uid = 30, 32 do
    local path = {}; for x = 250 + (uid - 30) * 4, 500 do table.insert(path, 130 * sea.W + x) end
    sea.units[uid] = {uid = uid, kind = 2, owner = 2, path = path, start_tick = sea.tick,
        ticks_per_tile_x100 = 100, hp = 1000, max_hp = 1000, state = 0, veterancy = 0}
end
local intercept = Auto.shipIntercept(sea, sea.units[30], silo.tile, 0)
local x = intercept.tile % sea.W
check(intercept.knownPath and x > 250 and x < 320 and intercept.uncertainty == 0, "lead a moving ship using both its replicated route and the missile's curved flight time")
scan = Auto.scan(sea); ctx = Auto.context(sea, scan, cfg); memory = {}
command = Auto.nukePlan(sea, scan, cfg, memory, ctx)
check(command and command.kind == "atom" and memory.nukeDetails.movingShips and #memory.nukeDetails.movingShips == 3,
    "a valuable moving fleet is a valid nuclear target on water")
sea.units[31] = nil; sea.units[32] = nil
check(not Auto.nukePlan(sea, scan, cfg, {}, Auto.context(sea, scan, cfg)), "skip an uneconomic nuclear shot at a single ordinary warship")
for uid = 31, 32 do sea.units[uid] = table.clone(sea.units[30]); sea.units[uid].uid = uid end
sea.units[40] = table.clone(sea.units[30]); sea.units[40].owner = 1; sea.units[40].uid = 40
check(not Auto.nukePlan(sea, scan, cfg, {}, Auto.context(sea, scan, cfg)), "do not nuke our own ship's predicted arrival position")
sea.units[40] = nil
for _, u in pairs(sea.units) do u.path = {130 * sea.W + 250}; u.state = 0 end
check(not Auto.nukePlan(sea, scan, cfg, {}, Auto.context(sea, scan, cfg)), "skip ships whose future route is too uncertain for the blast radius")

-- Check actual server mechanics, beyond the bot's own arithmetic.
local sim = Sim.new(seaMap, {nations = false, tribes = 0, max_humans = 2, spawn_ticks = 10, seed = 7})
local me, them = sim:add_human("a", "Tester"), sim:add_human("b", "Enemy")
sim.o_ai[me], sim.o_ai[them], sim.o_spawned[me], sim.o_spawned[them] = 0, 0, 1, 1
sim.phase, sim.tick = Defs.PHASE_PLAYING, 2000
for t = 0, sea.N - 1 do local id = buffer.readi32(sea.owner, t * 4); if id > 0 then sim:set_owner(t, id) end end
sim.o_gold[me], sim.o_troops[me], sim.o_cap[me] = 12000000, 300000, 1000000
check(not sim:reinforce(me), "real server rejects locked Reinforcements")
sim.o_unlock[me] = Defs.UNLOCK.reinforce
check(sim:reinforce(me) and sim.o_troops[me] == 500000 and sim.o_gold[me] == 11900000, "real server buys exactly the planned amount of Reinforcements")
check(not sim:reinforce(me), "real server refuses a second call during cooldown")
local actualPort = sim:add_struct(1, me, port.tile); actualPort.active, actualPort.active_tick = true, sim.tick
-- Ports normally discover adjacent water during activation; initialize it through the source hook.
sim:_activate(actualPort)
local targetWater = 130 * sea.W + 100
check(sim:build_warship(me, targetWater), "real server builds the requested warship through an owned port")
local ship = sim.warship_list[#sim.warship_list]
check(ship and ship.path[1] == actualPort.water, "warship actually spawns at port water rather than the clicked patrol destination")
ship.hp = 500; ship.path = {actualPort.water}; ship.state = 2; ship.retreat_port = actualPort.sid
local hpBefore = ship.hp
sim:_warship_tick(ship)
check(ship.hp > hpBefore, "real warship heals at an owned port")
local n = {uid = 9999, kind = 0, owner = them, from_tile = 130 * sea.W + 820, to_tile = actualPort.water, target_owner = 0}
sim:_detonate(n)
check(ship.dead, "real nuclear blast destroys a warship in its radius, including at port")

local land = fixture(400, 240, false)
local landSim = Sim.new(select(2, fixture(400, 240, false)), {nations = false, tribes = 0, max_humans = 2, spawn_ticks = 10, seed = 5})
local a1, b1 = landSim:add_human("aa", "Tester"), landSim:add_human("bb", "Enemy")
landSim.o_ai[a1], landSim.o_ai[b1], landSim.o_spawned[a1], landSim.o_spawned[b1] = 0, 0, 1, 1
landSim.phase, landSim.tick = Defs.PHASE_PLAYING, 1200
for t = 0, land.N - 1 do local id = buffer.readi32(land.owner, t * 4); if id > 0 then landSim:set_owner(t, id) end end
landSim.o_gold[a1] = 12000000
local af = landSim:add_struct(7, a1, 130 * land.W + 40); af.active_tick = landSim.tick; landSim:_activate(af)
local rg = landSim:add_struct(8, a1, 150 * land.W + 40); rg.active_tick = landSim.tick; landSim:_activate(rg)
local enemySam = landSim:add_struct(4, b1, 130 * land.W + 110); enemySam.active_tick = landSim.tick; landSim:_activate(enemySam)
local enemyFort = landSim:add_struct(3, b1, 130 * land.W + 90); enemyFort.active_tick = landSim.tick; landSim:_activate(enemyFort)
check(not landSim:launch_nuke(a1, "airstrike", enemyFort.tile), "real server requires the Air Strike unlock")
landSim.o_unlock[a1] = bit32.bor(Defs.UNLOCK.airfield, Defs.UNLOCK.railgun, Defs.UNLOCK.reload2x)
local previousGold = landSim.o_gold[a1]
check(landSim:launch_nuke(a1, "airstrike", enemyFort.tile) and landSim.o_gold[a1] == previousGold,
    "real unlocked Air Strike uses its airfield with no ammunition charge")
check(af.shots[1] == landSim.tick - 150, "real Rapid Reload sends the backdated airfield timestamp used by the reader")
check(landSim:launch_nuke(a1, "slug", enemySam.tile) and rg.shots[1] == landSim.tick - 125,
    "real railgun accepts its distinct command and backdates its own cooldown")
local intercepted = 0
for _ = 1, 25 do
    local delta = landSim:step()
    for _, e in ipairs(delta.ev or {}) do if e[1] == 13 and (e[3] == 7 or e[3] == 8) and e[5] == 0 then intercepted += 1 end end
end
check(enemyFort.dead and enemySam.dead and intercepted == 0, "actual server: Air Strike destroys the fort and Railgun destroys the SAM without interception")
print("TOTAL V7 CHECKS", checks)
