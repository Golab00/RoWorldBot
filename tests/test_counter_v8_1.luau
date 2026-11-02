local Auto = require("./_generated/bot_module/RoWorldAuto")
local WorldMap = require("../vendor/roworld/src/shared/Core/WorldMap")
local Sim = require("../vendor/roworld/src/shared/Core/Sim")
local Defs = require("../vendor/roworld/src/shared/Core/Defs")
local checks = 0
local function check(ok, message) assert(ok, message); checks += 1; print("PASS", message) end
local function fixture()
    local w, h = 300, 240
    local bytes = buffer.create(w * h); buffer.fill(bytes, 0, 128)
    local raw = Auto.mapFromBytes(bytes, {id = "counter", width = w, height = h, k_lin = 1}, w, h)
    local grid = buffer.create(w * h * 4)
    for y = 100, 159 do
        for x = 20, 79 do buffer.writei32(grid, (y * w + x) * 4, 1) end
        for x = 80, 139 do buffer.writei32(grid, (y * w + x) * 4, 2) end
        for x = 200, 259 do buffer.writei32(grid, (y * w + x) * 4, 3) end
    end
    local s = Auto.rawState({map_id = "counter", t = 1200, phase = 1, playing_since = 0, owner = grid, flags = buffer.create(w * h),
        owners = {{1, "Tester", 0, 2, 0, true, 3600, 400000, 0, 1000000, 0, 0, 130 * w + 50},
            {2, "Attacker", 0, 2, 0, true, 3600, 600000, 0, 1000000, 0, 0, 130 * w + 110},
            {3, "Other", 0, 2, 0, true, 3600, 200000, 0, 1000000, 0, 0, 130 * w + 220}}}, raw, 1)
    s.attacks[1] = {aid = 1, attacker = 2, target = 1, troops = 600000, anchor_tile = 130 * w + 79}
    return s
end
local cfg = Auto.settings({AutoBuild = false, AutoWarships = false, AutoBoats = false, AutoNukes = false, AutoDiplomacy = false})
local s = fixture()
local scan = Auto.scan(s); local ctx = Auto.context(s, scan, cfg); local memory = {}
check(ctx.available == 0, "fixture reproduces v8's cap-based reserve blocking all attack budget")
local command, why, bucket = Auto.counterPlan(s, scan, cfg, memory, ctx, 100)
check(command and bucket == "counter" and memory.counterDetails.amount == 180000,
    "defensive counter uses a share of current home troops even when cap-based reserve is larger than the army")
check(memory.counterDetails.homeReserve == 220000 and memory.counterDetails.partial,
    "partial counter preserves a separate home reserve and never exceeds incoming troops")
memory.counter = 100
check(not Auto.counterPlan(s, scan, cfg, memory, ctx, 101), "counter cooldown prevents repeated sends")
memory = {}
check(not Auto.counterPlan(s, scan, Auto.settings({AutoCounter = false}), memory, ctx, 100)
    and memory.counterText:find("OFF"), "disabled counter has a visible reason")
memory = {}
check(not Auto.counterPlan(s, scan, Auto.settings({AttackHumans = false}), memory, ctx, 100)
    and memory.counterText:find("graczy"), "player attack setting is respected with an explicit reason")
s.owners[1].troops = 100000; s.attacks[1].troops = 500
ctx = Auto.context(s, scan, cfg)
check(not Auto.counterPlan(s, scan, cfg, {}, ctx, 100), "do not overshoot the protocol's minimum 1 percent against a tiny incoming attack")
s.owners[1].troops, s.attacks[1].troops = 700000, 100000
s.structures[10] = {sid = 10, kind = 3, owner = 1, tile = 130 * s.W + 60, level = 1, active_tick = 0, shots = {}}
scan = Auto.scan(s); ctx = Auto.context(s, scan, cfg); memory = {}
check(not Auto.counterPlan(s, scan, cfg, memory, ctx, 100) and memory.counterText:find("fort"),
    "a fort holding a modest attack without territory loss can preserve troops")
local lost = {}; for x = 60, 69 do table.insert(lost, (130 * s.W + x) * 1024 + 2) end
s:apply_delta({t = 1201, tiles = lost}); scan = Auto.scan(s); ctx = Auto.context(s, scan, cfg)
command = Auto.counterPlan(s, scan, cfg, {}, ctx, 100)
check(command ~= nil, "a fort no longer suppresses a useful counter when territory is actually being lost")

local multi = fixture()
multi.attacks[2] = {aid = 2, attacker = 3, target = 1, troops = 200000, anchor_tile = 130 * multi.W + 79}
scan = Auto.scan(multi); ctx = Auto.context(multi, scan, cfg); memory = {}
command = Auto.counterPlan(multi, scan, cfg, memory, ctx, 100)
check(memory.counterDetails.target == 2 and memory.counterDetails.homeReserve == 220000,
    "multiple fronts preserve a larger reserve and prioritize the strongest active attack")
local full = fixture(); full.owners[1].troops = 700000; full.attacks[1].troops = 100000
scan = Auto.scan(full); ctx = Auto.context(full, scan, cfg); memory = {}
command, why, bucket = Auto.counterPlan(full, scan, cfg, memory, ctx, 100)
check(command and math.floor(command.ratio * full.owners[1].troops + 0.01) == 100000,
    "a full counter cancels exactly the incoming army without the old 1 percent offensive overshoot")
full.attacks[2] = {aid = 2, attacker = 1, target = 2, troops = 100000, anchor_tile = 130 * full.W + 80}
memory = {counter = 100}
command = Auto.decide(full, scan, cfg, memory, 101)
check(not command or command.type ~= "retreat", "defensive target is not immediately withdrawn by the emergency retreat rule")
local retreat = fixture()
retreat.owners[1].troops = 100
retreat.attacks[2] = {aid = 2, attacker = 1, target = 3, troops = 100000, anchor_tile = 130 * retreat.W + 200}
scan = Auto.scan(retreat)
command = Auto.decide(retreat, scan, cfg, {}, 100)
check(command and command.type == "retreat" and command.attack_id == 2,
    "unrelated expedition still retreats when there are insufficient troops to counter")

-- Execute the requested commands against the original server logic.
local map = WorldMap.new(full.W, full.H); map.id = "counter"; buffer.fill(map.tile_bytes, 0, 128); map:_derive()
local sim = Sim.new(map, {nations = false, tribes = 0, max_humans = 2, spawn_ticks = 10, seed = 9})
local me, enemy = sim:add_human("me", "Tester"), sim:add_human("enemy", "Attacker")
sim.o_ai[me], sim.o_ai[enemy], sim.o_spawned[me], sim.o_spawned[enemy] = 0, 0, 1, 1
sim.phase, sim.tick = Defs.PHASE_PLAYING, 1200
for t = 0, full.N - 1 do local id = buffer.readi32(full.owner, t * 4); if id == 1 or id == 2 then sim:set_owner(t, id) end end
sim.o_troops[me], sim.o_troops[enemy] = 700000, 700000
check(sim:intent_attack_troops(enemy, 130 * map.W + 79, 100000), "real server creates the incoming attack")
local tilesBefore, homeBefore = sim.o_tiles[me], sim.o_troops[me]
full.attacks[2] = nil; full.attacks[1].troops = 100000
scan = Auto.scan(full); ctx = Auto.context(full, scan, cfg)
command = Auto.counterPlan(full, scan, cfg, {}, ctx, 100)
check(sim:intent_attack(me, command.tile, command.ratio), "real server accepts the planned counter command")
check(sim:attack_between(enemy, me) == nil and sim:attack_between(me, enemy) == nil,
    "real counter deletes the incoming attack without needing to create an outgoing arrow")
check(sim.o_troops[me] == homeBefore - 100000 and sim.o_tiles[me] == tilesBefore,
    "real counter trades home troops 1 to 1 before territorial combat")
sim.o_troops[me] = 400000; sim.o_troops[enemy] = 700000
sim:intent_attack_troops(enemy, 130 * map.W + 79, 600000)
local partial = fixture(); scan = Auto.scan(partial); ctx = Auto.context(partial, scan, cfg)
command = Auto.counterPlan(partial, scan, cfg, {}, ctx, 100)
sim:intent_attack(me, command.tile, command.ratio)
check(sim:attack_between(enemy, me).troops == 420000 and sim.o_troops[me] == 220000,
    "real partial counter removes the predicted amount while preserving its home reserve")

-- Incoming landings can belong to a distant country without a shared land border.
local distant = fixture(); distant.attacks[1].attacker = 3; distant.attacks[1].troops = 150000
scan = Auto.scan(distant); ctx = Auto.context(distant, scan, cfg); memory = {}
command = Auto.counterPlan(distant, scan, cfg, memory, ctx, 100)
check(command and memory.counterDetails.target == 3 and not memory.counterDetails.border,
    "counter can identify the owner of an incoming landing without a shared border")
local existing = sim:attack_between(enemy, me); if existing then sim:end_attack(existing, false) end
for t = 0, map.N - 1 do if buffer.readi32(sim.owner, t * 4) == enemy then sim:set_owner(t, 0) end end
for y = 100, 159 do for x = 200, 259 do sim:set_owner(y * map.W + x, enemy) end end
sim.o_troops[me] = 400000
sim:start_attack(enemy, me, 150000, 130 * map.W + 79)
local remoteMirror = Auto.rawState(sim:snapshot(), full.map, me)
local remoteScan = Auto.scan(remoteMirror); local remoteCtx = Auto.context(remoteMirror, remoteScan, cfg)
memory = {}; command = Auto.counterPlan(remoteMirror, remoteScan, cfg, memory, remoteCtx, 100)
check(command and not memory.counterDetails.border, "real landing state can be countered without a shared frontier")
check(sim:intent_attack(me, command.tile, command.ratio) and sim:attack_between(enemy, me) == nil,
    "real server cancels the incoming landing with the planned counter")
print("TOTAL COUNTER V8.1 CHECKS", checks)
