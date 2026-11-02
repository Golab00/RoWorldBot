local Auto = require("./_generated/bot_module/RoWorldAuto")
local WorldMap = require("../vendor/roworld/src/shared/Core/WorldMap")
local GameState = require("../vendor/roworld/src/shared/Core/GameState")
local Rules = require("../vendor/roworld/src/shared/Core/Rules")
local Sim = require("../vendor/roworld/src/shared/Core/Sim")
local Defs = require("../vendor/roworld/src/shared/Core/Defs")
local count = 0
local function check(ok, text) assert(ok, text); count += 1; print("PASS", text) end
local log = Auto.newLog(50)
for i = 1, 70 do log:add("decision", {value = i}, i) end
check(#log.entries == 50 and log.dropped == 20 and log.entries[1].seq == 21, "logs keep a bounded chronological history")
local encoded = {}
local report = log:export(function(row) table.insert(encoded, row); return if row.schema then "metadata" else tostring(row.seq) end, {test = true}, 10)
check(#encoded == 11 and encoded[1].schema == 1 and encoded[2].seq == 61 and encoded[11].seq == 70,
    "log export includes configuration and the requested latest records")
check(report:find("RoWorldBot v", 1, true) and report:find("metadata", 1, true), "export has a recognizable version header")
local function fixture(w, h, ocean)
    local map = WorldMap.new(w, h); map.id = "strategy"
    buffer.fill(map.tile_bytes, 0, if ocean then 32 else 128)
    if ocean then
        for y = 100, 159 do for x = 20, 79 do buffer.writeu8(map.tile_bytes, y * w + x, 128) end end
        for y = 100, 159 do for x = w - 80, w - 21 do buffer.writeu8(map.tile_bytes, y * w + x, 128) end end
    end
    map:_derive()
    local grid = buffer.create(map.N * 4)
    local x2 = if ocean then w - 80 else 80
    for y = 100, 159 do
        for x = 20, 79 do buffer.writei32(grid, (y * w + x) * 4, 1) end
        for x = x2, x2 + 59 do buffer.writei32(grid, (y * w + x) * 4, 2) end
    end
    local raw = Auto.mapFromBytes(map.tile_bytes, {id = map.id, width = w, height = h, k_lin = 1}, w, h)
    local snap = {map_id = map.id, map_w = w, map_h = h, t = 1200, phase = 1, playing_since = 0,
        owner = grid, flags = buffer.create(map.N), owners = {
            {1, "Tester", 0xFFFFFFFF, 2, 0, true, 3600, 700000, 100000, 1000000, 1000, 0, 130 * w + 50},
            {2, "Neighbor", 0xFFFFFFFF, 2, 0, true, 3600, 500000, 100000, 800000, 1000, 0, 130 * w + x2 + 20},
        }}
    return Auto.rawState(snap, raw, 1), map
end
local s = fixture(300, 240, false)
local cfg = Auto.settings({AutoBoats = false})
local scan = Auto.scan(s)
local ctx = Auto.context(s, scan, cfg)
local made = s.tick
s.requests[2049] = made
local command, why = Auto.diplomacy(s, scan, cfg, {}, ctx, 100)
check(command and command.type == "ally_reply" and command.accept and command.target == 2, "accept a useful neighboring power")
check(type(why) == "string" and #why > 10, "alliance decision has a visible reason")
s.recentBetrayal[2] = s.tick - 10
command = Auto.diplomacy(s, scan, cfg, {}, ctx, 100)
check(command and not command.accept, "decline a recent betrayer")
s.recentBetrayal[2] = nil
s.owners[2].troops, s.owners[2].tiles = 1000, 100
command = Auto.diplomacy(s, scan, cfg, {}, ctx, 100)
check(command and not command.accept, "decline a weak small country offering no strategic benefit")
s.owners[2].troops, s.owners[2].tiles = 500000, 3600
check(Auto.diplomacy(s, scan, Auto.settings({AutoDiplomacy = false}), {}, ctx, 100) == nil, "manual diplomacy setting leaves offers alone")
s.requests = {}
s.alliances[1026], s.alliance_expires[1026], s.alliance_ext[1026] = true, s.tick + 200, 0
scan = Auto.scan(s); ctx = Auto.context(s, scan, cfg)
command = Auto.diplomacy(s, scan, cfg, {}, ctx, 100)
check(command and command.type == "ally_extend", "renew a useful expiring alliance")
s.alliance_ext[1026] = 1
check(Auto.diplomacy(s, scan, cfg, {}, ctx, 100) == nil, "do not repeat our renewal request")
s.alliances[1026] = nil; s.alliance_expires[1026] = nil; s.alliance_ext[1026] = nil
s:apply_delta({t = 1201, ev = {{16, 2, 1, 1201}}})
check(s.requests[2049] == 1201, "incoming proposal message updates pending offers")
s:apply_delta({t = 1202, ev = {{17, 1, 2, 4202}}})
check(s.alliances[1026] and not s.requests[2049] and s.alliance_expires[1026] == 4202, "accepted alliance clears the proposal and records expiration")
s:apply_delta({t = 1203, ev = {{18, 1, 2, 2, false}, {22, 2, 1503}}})
check(not s.alliances[1026] and s.recentBetrayal[2] == 1203 and s.owners[2].traitor_until == 1503, "betrayal events update trust and combat state")
s:apply_delta({t = 1204, ev = {{19, 1, 2, "Your Atom Bomb was intercepted by Neighbor"}}})
check(s.weaponBackoff == 1304 and #s.recentMessages == 1, "interception notice causes a short pause in nuclear firing")
s:apply_delta({t = 1205, ev = {{19, 2, 2, "Not enough gold for a city"}}})
check(#s.recentMessages == 1, "ignore system notices addressed to another country")

s.owners[2].traitor_until = 0; s.recentBetrayal = {}; scan = Auto.scan(s)
ctx = Auto.context(s, scan, cfg)
local front = scan.fronts[2]
s.owners[2].troops = 10000
local low = Auto.attackPlan(s, front, 2, cfg, ctx)
s.owners[2].troops = 300000
local high = Auto.attackPlan(s, front, 2, cfg, ctx)
check(low and high and high.amount > low.amount, "send more troops against a stronger defender")
check(s.owners[1].troops - high.amount >= ctx.reserve, "calculated attack preserves the home reserve")
local guarded = table.clone(front); guarded.coverage = 1
local fort = Auto.attackPlan(s, guarded, 2, cfg, ctx)
check(not fort or fort.amount > high.amount, "fortified land needs more troops or is skipped")
s.structures[1] = {sid = 1, kind = 3, owner = 2, tile = 130 * s.W + 90, level = 1, active_tick = s.tick + 50}
check(not Auto.defenseAt(s, 2, 130 * s.W + 80), "unfinished fortification provides no active combat bonus")
s.structures[1].active_tick = s.tick
check(Auto.defenseAt(s, 2, 130 * s.W + 80), "finished fortification protects within its 30-tile radius")
check(not Auto.defenseAt(s, 2, 130 * s.W + 130), "fortification does not protect outside its radius")
scan = Auto.scan(s)
check(not Auto.defenseAt(s, 2, scan.fronts[2].tile), "prefer an unfortified entrance on the enemy border")
s.structures = {}; s.owners[2].troops = 1000000
scan = Auto.scan(s); ctx = Auto.context(s, scan, cfg)
command = Auto.buildPlan(s, scan, cfg, {}, ctx, true)
check(not command, "a strong neighbor in peacetime does not enter the emergency building queue")
s.attacks[15] = {aid = 15, attacker = 2, target = 1, troops = 300000, anchor_tile = 130 * s.W + 79}
ctx = Auto.context(s, scan, cfg)
command = Auto.buildPlan(s, scan, cfg, {}, ctx, true)
check(command and command.kind == "defense" and s:are_allies(1, 2) == false, "fortify a threatening border")
check(s.map.range_d2(command.tile, scan.borders[2].ownTile) <= 65^2, "defense site is near the threatened frontier")

-- Fallout is deliberately reclaimable, with the source's increased troop cost.
local f = fixture(180, 200, false)
for t = 0, f.N - 1 do if buffer.readi32(f.owner, t * 4) == 0 then buffer.writeu8(f.flags, t, 1); f.fallout_count += 1 end end
f.owners[2].troops = 10000000
local fs = Auto.scan(f)
check(not fs.fronts[0] and fs.falloutFronts[0], "retain radioactive neutral land as a separate expansion option")
local fc = Auto.context(f, fs, cfg)
local fall = Auto.attackPlan(f, fs.falloutFronts[0], 0, cfg, fc)
local cleanFront = table.clone(fs.falloutFronts[0]); cleanFront.fallout = false
local plain = Auto.attackPlan(f, cleanFront, 0, cfg, fc)
check(fall and plain and fall.goal / fall.amount < plain.goal / plain.amount, "fallout captures fewer tiles for the same troops")
command = Auto.decide(f, fs, Auto.settings({AutoBuild = false, AutoBoats = false, AutoDiplomacy = false, AutoNukes = false}), {}, 100)
check(command and command.type == "attack" and bit32.band(buffer.readu8(f.flags, command.tile), 1) == 1, "actually reclaim fallout when other expansion is unavailable")

local sea = fixture(900, 260, true)
local route = Auto.waterPath(sea, 130 * sea.W + 79, 130 * sea.W + 820)
check(route and #route > 700, "predict a water route between owned and target shores")
sea.units[1] = {uid = 1, kind = 1, owner = 2, path = {130 * sea.W + 450}, start_tick = sea.tick, ticks_per_tile_x100 = 100}
sea.units[2] = {uid = 2, kind = 0, owner = 2, path = {130 * sea.W + 450}, start_tick = sea.tick, ticks_per_tile_x100 = 100}
local navy = Auto.navy(sea)
check(#navy.trade == 1 and #navy.transports == 1 and #navy.warships == 0, "distinguish trade ships, transports and warships")
check(Auto.routeRisk(sea, route, navy) == 0, "noncombat ships do not create a fictitious firing zone")
sea.units[3] = {uid = 3, kind = 2, owner = 2, path = {130 * sea.W + 450}, start_tick = sea.tick, ticks_per_tile_x100 = 100}
check(Auto.routeRisk(sea, route, Auto.navy(sea)) > 0, "reject a landing route covered by an enemy warship")
sea.alliances[1026] = true
check(Auto.routeRisk(sea, route, Auto.navy(sea)) == 0, "allied warships do not block our landing")
sea.alliances[1026] = nil
local moving = {}; for y = 259, 130, -1 do table.insert(moving, y * sea.W + 450) end
sea.units[3].path, sea.units[3].start_tick = moving, sea.tick
check(Auto.routeRisk(sea, route, Auto.navy(sea)) > 0, "consider a warship moving into the route during the voyage")
sea:apply_delta({t = sea.tick + 1, ev = {{10, 3, 150 * sea.W + 460}, {25, 3, 700, 1200}, {26, 3, 1}, {27, 3, 1, 150 * sea.W + 460}}})
check(sea.units[3].hp == 700 and sea.units[3].veterancy == 1 and sea.units[3].state == 1 and sea.units[3].prev_tile >= 0,
    "ship messages preserve movement, health, veterancy and retreat state")

local n, map = fixture(420, 240, false)
-- Move the enemy inland, far enough from friendly land for a useful nuclear target.
for t = 0, n.N - 1 do if buffer.readi32(n.owner, t * 4) == 2 then buffer.writei32(n.owner, t * 4, 0) end end
for y = 70, 170 do for x = 260, 380 do buffer.writei32(n.owner, (y * n.W + x) * 4, 2) end end
n.owners[2].tiles, n.owners[2].spawn_tile = 12221, 120 * n.W + 320
n.owners[1].gold = 12000000
n.structures[1] = {sid = 1, kind = 5, owner = 1, tile = 125 * n.W + 50, level = 2, active_tick = 0, shots = {}}
n.structures[2] = {sid = 2, kind = 4, owner = 2, tile = 125 * n.W + 320, level = 1, active_tick = 0, shots = {}}
n.structures[3] = {sid = 3, kind = 0, owner = 2, tile = 125 * n.W + 300, level = 1, active_tick = 0, shots = {}}
n.structures[4] = {sid = 4, kind = 5, owner = 2, tile = 125 * n.W + 340, level = 1, active_tick = 0, shots = {}}
n.attacks[1] = {aid = 1, attacker = 2, target = 1, troops = 1000, anchor_tile = 0}
local sam = n.structures[2]
sam.shots = {n.tick}
check(Auto.readyMissiles(n, sam) == 0 and Auto.readyMissiles(n, sam, n.tick + 89) == 0 and Auto.readyMissiles(n, sam, n.tick + 90) == 1,
    "each SAM missile reloads after exactly 90 ticks (9 seconds)")
sam.shots = {}
local path, flight = Auto.bombPath(n, n.structures[1].tile, sam.tile, 0)
local arc = Rules.for_map(map).nuke_arc(n.W, n.H, n.structures[1].tile, sam.tile)
check(math.abs(path[#path].length - arc.length) < 1e-8 and flight == Rules.for_map(map).nuke_arc_ticks(arc, 0), "missile arc and flight time match source rules")
local screen = Auto.samScreen(n, n.structures[1].tile, sam.tile, 0)
check(screen.sites == 1 and screen.capacity == 1, "one loaded level-one SAM can stop one bomb in this interception window")
local ns = Auto.scan(n); local nc = Auto.context(n, ns, cfg); local mem = {}
command = Auto.nukePlan(n, ns, cfg, mem, nc)
check(command and command.kind == "atom" and command.amount == 2, "use two simultaneous atoms to pass one loaded SAM")
check(mem.nukeDetails and mem.nukeDetails.interceptCapacity == 1 and mem.nukeDetails.cost == 1500000,
    "record the planned cost and predicted interceptions for later tuning")
local originalSamTile = sam.tile
sam.tile = 80 * n.W + 80
local launchShield = Auto.samScreen(n, n.structures[1].tile, originalSamTile, 0)
check(launchShield.sites == 1, "detect SAM coverage near the launch end as well as near the target")
sam.tile = originalSamTile
sam.shots = {n.tick}
screen = Auto.samScreen(n, n.structures[1].tile, sam.tile, 0)
check(screen.readyNow == 0 and screen.capacity == 0, "recognize a SAM that cannot reload before this short flight arrives")
sam.shots = {n.tick - 80}
screen = Auto.samScreen(n, n.structures[1].tile, sam.tile, 0)
check(screen.readyNow == 0 and screen.capacity == 1, "do not mistake empty now for empty when the bomb arrives")
sam.shots, sam.level = {}, 2
mem = {}; command = Auto.nukePlan(n, ns, cfg, mem, nc)
check(not command and mem.wantSiloUpgrade == 1, "upgrade the silo instead of launching an insufficient salvo")
sam.level = 1
buffer.writei32(n.owner, (125 * n.W + 319) * 4, 1)
check(Auto.nukePlan(n, ns, cfg, {}, nc) == nil, "do not choose a blast that would hit a tiny patch of friendly land")
buffer.writei32(n.owner, (125 * n.W + 319) * 4, 2)
n.structures[5] = {sid = 5, kind = 0, owner = 1, tile = 135 * n.W + 50, level = 2, active_tick = 0, shots = {}}
n.nukes[99] = {uid = 99, kind = 0, owner = 2, from_tile = sam.tile, to_tile = n.structures[5].tile, launch_tick = n.tick, flight_ticks = 400}
local defenseCtx = Auto.context(n, ns, cfg)
command = Auto.buildPlan(n, ns, cfg, {}, defenseCtx, true)
check(command and command.kind == "sam", "build a SAM to cover valuable threatened infrastructure")
check(n.map.range_d2(command.tile, n.structures[5].tile) <= 70^2, "SAM placement actually covers the threatened city")
n.nukes[99] = nil; n.structures[5] = nil

-- Execute the planned salvo using the real simulator's SAM and nuke processing.
buffer.writei32(n.owner, (125 * n.W + 319) * 4, 2)
local sim = Sim.new(map, {nations = false, tribes = 0, max_humans = 2, spawn_ticks = 10, seed = 31})
local a, b = sim:add_human("a", "Tester"), sim:add_human("b", "Neighbor")
sim.o_ai[a], sim.o_ai[b], sim.o_spawned[a], sim.o_spawned[b] = 0, 0, 1, 1
sim.phase, sim.tick = Defs.PHASE_PLAYING, n.tick
for t = 0, n.N - 1 do local id = buffer.readi32(n.owner, t * 4); if id > 0 then sim:set_owner(t, id) end end
sim.o_gold[a], sim.o_troops[a], sim.o_troops[b] = 12000000, 700000, 500000
local silo = sim:add_struct(5, a, n.structures[1].tile)
silo.level, silo.active, silo.active_tick, silo.shots = 2, true, sim.tick, {}
local realSam = sim:add_struct(4, b, sam.tile)
realSam.active, realSam.active_tick, realSam.shots = true, sim.tick, {}
local city = sim:add_struct(0, b, n.structures[3].tile); city.active, city.active_tick = true, sim.tick
local enemySilo = sim:add_struct(5, b, n.structures[4].tile); enemySilo.active, enemySilo.active_tick = true, sim.tick
command = Auto.nukePlan(n, ns, cfg, {}, nc)
assert(command and command.amount == 2)
sim:submit(a, command)
local interceptions, impacts = 0, 0
for _ = 1, 150 do
    local d = sim:step()
    for _, e in ipairs(d.ev or {}) do if e[1] == 13 and e[3] == 0 then if e[5] == 0 then interceptions += 1 else impacts += 1 end end end
end
check(interceptions == 1 and impacts == 1, "actual server simulation: one bomb intercepted and one hits")
check(realSam.dead == true, "the surviving bomb destroys the enemy SAM")
print("TOTAL V6 CHECKS", count)
