local Auto = require("./_generated/bot_module/RoWorldAuto")
local checks = 0
local function check(ok, text) assert(ok, text); checks += 1; print("PASS", text) end
local function fixture()
    local w, h = 400, 240
    local bytes = buffer.create(w * h); buffer.fill(bytes, 0, 128); buffer.fill(bytes, 0, 32, w * 20)
    local map = Auto.mapFromBytes(bytes, {id = "map8", width = w, height = h, k_lin = 1}, w, h)
    local owners = buffer.create(w * h * 4)
    for y = 50, 189 do
        for x = 20, 179 do buffer.writei32(owners, (y * w + x) * 4, 1) end
        for x = 180, 319 do buffer.writei32(owners, (y * w + x) * 4, 2) end
        for x = 330, 389 do buffer.writei32(owners, (y * w + x) * 4, 3) end
    end
    local snapshot = {map_id = "map8", t = 1000, phase = 1, playing_since = 0, owner = owners, flags = buffer.create(w * h),
        owners = {{1, "Tester", 0, 2, 0, true, 22400, 700000, 16000000, 1000000, 0, 0, 120 * w + 70},
            {2, "NationBot", 0, 0, 0, true, 19600, 1500000, 100000, 2000000, 0, 0, 120 * w + 250},
            {3, "RemotePlayer", 0, 2, 0, true, 8400, 1000000, 100000, 2000000, 0, 0, 120 * w + 350}}}
    return Auto.rawState(snapshot, map, 1), snapshot
end
local function add(s, sid, kind, who, x, y, active, level)
    local b = {sid = sid, kind = kind, owner = who, tile = y * s.W + x, level = level or 1, active_tick = active or 0, shots = {}}
    s.structures[sid] = b; s.structureRevision += 1; return b
end
local cfg = Auto.settings()
local s = fixture()
local city = add(s, 1, 0, 1, 100, 100)
local fort = add(s, 2, 3, 1, 115, 100)
local sam = add(s, 3, 4, 1, 100, 125, s.tick + 100)
local row = Auto.describeTile(s, city.tile)
check(row.owner == 1 and row.relation == "own" and row.controlledBy == "player" and row.structures[1].sid == city.sid,
    "exact tile query identifies own land, controller and building coordinates")
check(#row.forts == 1 and row.forts[1].protectsOwner and #row.sams == 1 and not row.sams[1].active and row.sams[1].ready == 0,
    "tile query distinguishes active fort coverage from a SAM under construction")
row = Auto.describeTile(s, 100 * s.W + 250)
check(row.owner == 2 and row.controlledBy == "bot" and row.relation == "enemy", "nation AI is identified by its server kind")
row = Auto.describeTile(s, 100 * s.W + 350)
check(row.owner == 3 and row.controlledBy == "player", "a player country is distinguished from nation AI")
row = Auto.describeTile(s, 10 * s.W + 30)
check(not row.land and row.owner == 0 and row.terrain == 0 and row.waterBody > 0, "unowned ocean is distinguished from neutral land")
check(Auto.describeTile(s, -1) == nil and Auto.describeTile(s, s.N) == nil, "map query never reads outside the map")
local hot, hotSnapshot = fixture()
hotSnapshot.attacks = {{50, 2, 1, 1500000, 120 * hot.W + 179, false}}
hotSnapshot.nukes = {{51, 0, 2, 120 * hot.W + 250, 120 * hot.W + 150, 990, 20}}
hotSnapshot.units = {{52, 0, 2, {120 * hot.W + 179}, 990, 100, 10000}}
local hotState = Auto.rawState(hotSnapshot, hot.map, 1)
check(hotState.attacks[50] and hotState.nukes[51] and hotState.aggressors[2], "injecting into an ongoing battle loads attacks, missiles and aggression before event methods are bound")
s:apply_delta({t = 1001, ev = {{5, 1, 2}}})
check(Auto.describeTile(s, city.tile).structures[1].owner == 2, "building ownership changes invalidate the spatial index")
s:apply_delta({t = 1002, ev = {{6, 1}}})
check(#Auto.describeTile(s, city.tile).structures == 0, "destroyed structures disappear from spatial queries")
s:apply_delta({t = 1003, tiles = {city.tile * 1024 + 2}})
check(Auto.describeTile(s, city.tile).owner == 2, "territory queries use the current grid after conquest")

local b, snap = fixture()
local target = 120 * b.W + 150
add(b, 1, 0, 1, 150, 120)
b.units[4] = {uid = 4, kind = 0, owner = 1, path = {target}, start_tick = b.tick, ticks_per_tile_x100 = 100}
local edits, flags = {}, {}
for y = 118, 122 do for x = 148, 152 do
    local t = y * b.W + x; table.insert(edits, t * 1024); table.insert(flags, t * 256 + 1)
end end
b:apply_delta({t = 1001, tiles = edits, flags = flags, ev = {
    {12, 20, 0, 2, 120 * b.W + 250, target, 990, 11}, {6, 1}, {11, 4, 0}, {13, 20, 0, target, 10, 2}}})
local blast = b.explosions[1]
check(blast and blast.status == "impact" and blast.x == 150 and blast.y == 120 and blast.owner == 2,
    "remember exact confirmed impact coordinates and shooter after removing the missile")
check(blast.ownLost == 25 and blast.falloutAdded == 25 and blast.changes[1].lost == 25,
    "impact remembers pre-change ownership and newly irradiated tiles in the same area")
check(#blast.structures == 1 and blast.structures[1].owner == 1 and #blast.units == 1 and blast.units[1].uid == 4,
    "impact records removed own structures and units before their state is discarded")
check(blast.affectedUs and b.ownNuclearHit == 1001 and b.aggressors[2], "damage to us enters nuclear defense and aggression history")
row = Auto.describeTile(b, target)
check(row.owner == 0 and row.fallout and #row.blasts == 1, "the current tile and its historical impact remain independently queryable")
b:apply_delta({t = 1002, ev = {{12, 21, 0, 2, 120 * b.W + 250, target, 990, 30}, {13, 21, 0, target, 0, 2}}})
check(b.lastExplosion.status == "intercepted" and b.lastExplosion.ownLost == 0 and not b.lastExplosion.affectedUs,
    "SAM interception is not counted as ground damage")
b:apply_delta({t = 1003, ev = {{13, 22, 2, target, -1, 2}}})
check(b.lastExplosion.status == "split" and not b.lastExplosion.affectedUs, "MIRV carrier split is not misreported as an impact")
local overlap = fixture()
overlap:apply_delta({t = 1001, ev = {{13, 70, 0, target, 10, 2}, {13, 71, 0, target + 1, 10, 3}}})
check(overlap.explosions[1].overlapping and overlap.explosions[2].overlapping,
    "simultaneous overlapping blasts are marked ambiguous rather than assigning exclusive damage")
local history = Auto.bindHistory(b)
snap.t = 1004
local resumed = Auto.rawState(snap, b.map, 1); Auto.bindHistory(resumed, history)
check(#resumed.explosions == 3 and resumed.ownNuclearHit == 1001, "a same-match resync preserves blast locations and defensive memory")
snap.t = 1
local restarted = Auto.rawState(snap, b.map, 1); Auto.bindHistory(restarted, history)
check(#restarted.explosions == 0, "new match does not inherit previous bomb locations")

local distant = fixture()
add(distant, 1, 0, 1, 70, 120)
distant:apply_delta({t = 1001, ev = {{12, 30, 0, 3, 120 * distant.W + 360, 120 * distant.W + 350, 1001, 30}}})
local scan = Auto.scan(distant); local ctx = Auto.context(distant, scan, cfg)
check(not ctx.nuclearThreat and distant.nuclearAlert == nil, "remote bombing does not create a false emergency for our country")
local command = Auto.buildPlan(distant, scan, cfg, {}, ctx, true)
check(not command or command.kind ~= "sam", "an explosion elsewhere is not a reason for an urgent SAM purchase")
local nearEdge = 120 * distant.W + 185
distant:apply_delta({t = 1002, ev = {{12, 31, 0, 2, 120 * distant.W + 250, nearEdge, 1002, 60}}})
check(Auto.nukeThreatensUs(distant, distant.nukes[31]), "a bomb aimed at enemy land can still threaten our adjacent territory")
check(Auto.siteBombRisk(distant, 120 * distant.W + 170, 50).uid == 31, "planned blast footprint blocks an unfinished building at that location")
check(Auto.siteBombRisk(distant, 120 * distant.W + 100, 50) == nil, "a safe distant building is not excluded by that bomb")

local f = fixture()
check(Auto.hostileLandWithin(f, 120 * f.W + 175, 12), "fort clearance checks every actual nearby hostile tile, not sampled frontier points")
check(not Auto.hostileLandWithin(f, 120 * f.W + 150, 12), "inland clearance allows a genuinely safe distance from hostile terrain")
f.owners[2].troops = 2000000
add(f, 90, 0, 1, 60, 100, 0, 2)
add(f, 91, 2, 1, 85, 100)
f.owners[1].troops = 200000
scan = Auto.scan(f); ctx = Auto.context(f, scan, cfg)
local memory = {}; command = Auto.buildPlan(f, scan, cfg, memory, ctx, false)
check(command and command.kind == "defense", "peace fortification remains available for a strong bordering neighbor")
local minD = math.huge
for _, p in ipairs(scan.borders[2].ownPoints) do minD = math.min(minD, math.sqrt(f.map.range_d2(command.tile, p))) end
check(minD >= cfg.MinFortInland and memory.buildDetails.newFortCoverage.ownLandShare >= cfg.MinFortOwnLand,
    "peace fort stands inland and most of its land coverage is our territory")
local chosen = command.tile
add(f, 1, 3, 1, chosen % f.W, chosen // f.W, f.tick + 50)
local cover = Auto.fortCoverage(f, chosen)
check(cover.share == 0, "a fort under construction already counts against redundant future coverage")

-- Replay a fast inward-moving front: old losses are farther from today's border.
local fast = fixture()
for y = 80, 159 do for x = 180, 219 do buffer.writei32(fast.owner, (y * fast.W + x) * 4, 1) end end
local function lose(at, lo, hi)
    local tiles = {}; for y = 80, 159 do for x = lo, hi do table.insert(tiles, (y * fast.W + x) * 1024 + 2) end end
    fast:apply_delta({t = at, tiles = tiles})
end
lose(1001, 201, 219); lose(1026, 181, 200); lose(1045, 171, 180)
fast.attacks[1] = {aid = 1, attacker = 2, target = 1, troops = 1500000, anchor_tile = 120 * fast.W + 171}
scan = Auto.scan(fast); ctx = Auto.context(fast, scan, cfg)
local speed = Auto.frontSpeed(fast, scan, ctx, 2, 120 * fast.W + 170)
check(speed > 0.4, "front speed is inferred from the spatial progression of actual lost tiles")
check(Auto.frontArrival(fast, scan, ctx, 120 * fast.W + 160) < 50, "a fort just behind the advancing border would fall before construction")
memory = {}; command = Auto.buildPlan(fast, scan, cfg, memory, ctx, true)
check(not command or memory.buildDetails.estimatedFrontArrivalTicks == nil
    or memory.buildDetails.estimatedFrontArrivalTicks > memory.buildDetails.buildTicks * 1.25,
    "selected construction must survive its build duration with a margin, or be skipped")
if command then
    local mark = memory.buildDetails
    check(mark.newFortCoverage and mark.newFortCoverage.share >= cfg.MinFortNewCoverage,
        "a selected fort provides enough new coverage rather than stacking the same bonus")
end
check(Auto.frontArrival(fast, scan, ctx, 120 * fast.W + 120) < 300, "the same advancing front is unsafe for a 30-second SAM")

local weapons = fixture()
weapons.equipment = Auto.newEquipment(); Auto.applyInventory(weapons.equipment, {unlocks = {"railgun"}})
local equipmentState = Auto.equipmentStatus(weapons, weapons.equipment, cfg, "railgun")
check(equipmentState.unlocked and equipmentState.buildings == 0 and equipmentState.nextCost == 2500000,
    "equipment status separates an unlocked Railgun from having a gun built")
weapons.owners[1].gold = 19000
check(not Auto.equipmentStatus(weapons, weapons.equipment, cfg, "railgun").affordable,
    "equipment status explains a budget too low for the first launcher")
weapons.owners[1].gold = 16000000
add(weapons, 1, 8, 1, 80, 120)
check(Auto.equipmentStatus(weapons, weapons.equipment, cfg, "railgun").ready == 1,
    "equipment status distinguishes a loaded launcher from the account unlock")
add(weapons, 2, 0, 2, 250, 120)
add(weapons, 3, 8, 3, 350, 120)
weapons.attacks[1] = {aid = 1, attacker = 2, target = 1, troops = 500000, anchor_tile = 120 * weapons.W + 179}
scan = Auto.scan(weapons); ctx = Auto.context(weapons, scan, cfg)
memory = {}; command = Auto.strikePlan(weapons, cfg, memory, ctx)
check(command and command.tile == weapons.structures[2].tile and memory.arsenalDetails.threatPriority == 3,
    "Railgun prioritizes a current aggressor's city over an unrelated enemy's more valuable Railgun")
add(weapons, 4, 5, 1, 80, 80, 0, 3)
weapons.nukes = {}; memory = {}
command = Auto.nukePlan(weapons, scan, cfg, memory, ctx)
check(command and memory.nukeDetails.target == 2, "nuclear target selection also prioritizes a current aggressor")
weapons.attacks = {}; Auto.rememberAggressor(weapons, 2)
ctx = Auto.context(weapons, scan, cfg)
local priority = Auto.threatPriority(weapons, ctx, 2)
check(priority == 2 and select(1, Auto.threatPriority(weapons, ctx, 3)) == 0, "recent aggression has priority over unrelated countries")
weapons.tick += 400
check(select(1, Auto.threatPriority(weapons, Auto.context(weapons, scan, cfg), 2)) == 1, "historical aggression stays remembered after its recent window")
local farScan = {borders = {}, fronts = {}}
local score, reason = Auto.allianceScore(weapons, farScan, 2, cfg, ctx)
check(score < 0, "an aggressive nation AI is still excluded from alliances")
weapons.aggressors = {}; weapons.lastAggression = {}; weapons.betrayers = {}
score, reason = Auto.allianceScore(weapons, farScan, 2, cfg, ctx)
check(score < 0 and reason:find("bot"), "do not seek a remote bot ally on the assumption it will donate troops")
-- Use the actual simulator to check the footprint bookkeeping on a real nuclear delta.
local WorldMap = require("../vendor/roworld/src/shared/Core/WorldMap")
local Sim = require("../vendor/roworld/src/shared/Core/Sim")
local Defs = require("../vendor/roworld/src/shared/Core/Defs")
local map = WorldMap.new(180, 160); map.id = "real_blast"; buffer.fill(map.tile_bytes, 0, 128); map:_derive()
local sim = Sim.new(map, {nations = false, tribes = 0, max_humans = 2, spawn_ticks = 10, seed = 19})
local me, enemy = sim:add_human("one", "Tester"), sim:add_human("two", "Enemy")
sim.o_spawned[me], sim.o_spawned[enemy], sim.o_ai[me], sim.o_ai[enemy] = 1, 1, 0, 0
sim.phase, sim.tick = Defs.PHASE_PLAYING, 1000
for y = 50, 110 do for x = 50, 110 do sim:set_owner(y * map.W + x, me) end end
sim.o_troops[me], sim.o_gold[enemy] = 500000, 1000000
local destroyed = sim:add_struct(0, me, 80 * map.W + 80)
local snapReal = sim:snapshot()
local realMap = Auto.mapFromBytes(map.tile_bytes, {id = map.id, width = map.W, height = map.H, k_lin = 1}, map.W, map.H)
local mirror = Auto.rawState(snapReal, realMap, me)
sim._events = sim._events or {}
-- Clear the snapshot's already represented owner/structure deltas using the simulator's step.
local before = mirror.owners[me].tiles
local n = sim:_spawn_nuke(0, enemy, 80 * map.W + 150, destroyed.tile, 1)
n.target_owner = me
local delta = sim:step()
mirror:apply_delta(delta)
local last = mirror.lastExplosion
check(last and last.affectedUs and last.ownLost == before - mirror.owners[me].tiles and last.ownLost > 0,
    "real simulator detonation: blast report matches the exact own-tile loss in the replicated map")
check(last.structures[1] and last.structures[1].sid == destroyed.sid and destroyed.dead,
    "real simulator detonation: destroyed city is preserved in blast history")
print("TOTAL MAP V8 CHECKS", checks)
