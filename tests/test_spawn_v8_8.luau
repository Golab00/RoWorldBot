local Auto = require("./_generated/bot_module/RoWorldAuto")
local WorldMap = require("../vendor/roworld/src/shared/Core/WorldMap")
local Sim = require("../vendor/roworld/src/shared/Core/Sim")
local GameState = require("../vendor/roworld/src/shared/Core/GameState")
local checks = 0
local function check(ok, text) assert(ok, text); checks += 1; print("PASS", text) end
local function fixture(w, h, fill)
    local map = WorldMap.new(w, h); map.id = "spawn88"
    buffer.fill(map.tile_bytes, 0, fill or 128); map:_derive()
    local raw = Auto.mapFromBytes(map.tile_bytes, {id = map.id, width = w, height = h, k_lin = 1}, w, h)
    local snap = {map_id = map.id, t = 100, phase = 0, phase_left = 100, playing_since = -1,
        owner = buffer.create(w * h * 4), flags = buffer.create(w * h),
        owners = {{1, "Tester", 0, 2, 0, true, 0, 25000, 0, 0, 0, 0, -1}}}
    return Auto.rawState(snap, raw, 1), map, snap
end
local s, map, snap = fixture(180, 140)
check(Auto.spawnTicksLeft(s) == 100, "snapshot exposes the server countdown")
s:apply_delta({t = 107})
check(Auto.spawnTicksLeft(s) == 93, "countdown advances between the once-per-second PHASE events")
s:apply_delta({t = 110, ev = {{2, 0, 90}}})
check(Auto.spawnTicksLeft(s) == 90 and s.spawnDeadline == 200, "PHASE updates retain the same absolute deadline")
local tile, result = Auto.spawnSite(s)
check(tile and result.evaluated == s.map.land_count and result.evaluated > 350, "every free land tile is evaluated instead of 350 samples")
check(buffer.readi32(s.owner, tile * 4) == 0 and result.ranked[1].expansionTiles == s.N,
    "selected start belongs to the full reachable neutral land component")
local yields = 0
local cancel = Auto.spawnSite(s, function() yields += 1; return false end)
check(cancel == nil and yields == 1, "full-map analysis can be cancelled at a chunk boundary")
local memory = {}
local function decide(state, mem, now)
    for _ = 1, 2000 do
        local command, why, details = Auto.spawnPlan(state, mem, now, 0)
        if command or not mem.spawnPlan or mem.spawnPlan.result then return command, why, details end
    end
    error("spawn analysis did not finish")
end
local command, why = decide(s, memory, 0)
check(not command and why:find("wybieram przy 1 s"), "completed whole-map analysis does not submit an early start")
s:apply_delta({t = 189})
check(not Auto.spawnPlan(s, memory, 1, 0), "11 ticks remaining still waits")
s:apply_delta({t = 190, ev = {{2, 0, 10}}})
local details
command, _, details = Auto.spawnPlan(s, memory, 2, 0)
check(command and command.type == "spawn" and details.ticksLeft == 10 and details.evaluated == s.N,
    "start is selected at the beginning of the last server second")
memory.spawnPlan.sentTick = s.tick
s:apply_delta({t = 192})
check(not Auto.spawnPlan(s, memory, 2.2, 0), "unconfirmed start does not resend every poll")
s:apply_delta({t = 193})
check(Auto.spawnPlan(s, memory, 2.3, 0) ~= nil, "missing confirmation permits a bounded retry during the last second")
s:apply_delta({t = 194, ev = {{3, 1, command.tile}}})
check(not Auto.spawnPlan(s, memory, 2.4, 0) and not memory.spawnPlan, "confirmation stops selection and frees the analysis workspace")

-- Changes during the wait must affect the eventual choice.
local changed = fixture(180, 140); local m = {}; decide(changed, m, 0)
local original = m.spawnPlan.result.ranked[1].tile
changed:apply_delta({t = 190, tiles = {original * 1024 + 2}, ev = {{0, 2, "Late player", 0, 2, 0}, {3, 2, original}, {2, 0, 10}}})
command = Auto.spawnPlan(changed, m, 1, 0)
check(command and command.tile ~= original and buffer.readi32(changed.owner, command.tile * 4) == 0,
    "final revalidation never sends a start on the newly occupied best tile")
check(math.abs(command.tile % changed.W - original % changed.W) + math.abs(command.tile // changed.W - original // changed.W) > 10,
    "late human spawn also changes the proximity assessment")
local recomputed, recomputedResult = Auto.spawnSite(changed)
check(recomputed and recomputedResult.evaluated == changed.N - 1, "refreshed whole-map scoring accounts for the new occupation")
local ws = {}; Auto.spawnSite(changed, nil, ws)
buffer.writei32(changed.owner, 0, 3)
local _, reused = Auto.spawnSite(changed, nil, ws)
check(reused.evaluated == changed.N - 2, "reused buffers do not retain old free-land sums or components")

-- Build a fresh derived map: two separate islands with very different growth space.
local bytes = buffer.create(220 * 140); buffer.fill(bytes, 0, 32)
for y = 40, 59 do for x = 20, 39 do buffer.writeu8(bytes, y * 220 + x, 128) end end
for y = 20, 119 do for x = 80, 209 do buffer.writeu8(bytes, y * 220 + x, 128) end end
local raw = Auto.mapFromBytes(bytes, {id = "islands", width = 220, height = 140, k_lin = 1}, 220, 140)
snap.map_id, snap.owner, snap.flags = "islands", buffer.create(raw.N * 4), buffer.create(raw.N)
local islands = Auto.rawState(snap, raw, 1)
tile, result = Auto.spawnSite(islands)
check(tile % islands.W >= 80 and result.ranked[1].expansionTiles == 13000, "small isolated island loses to usable space on the larger landmass")
buffer.fill(islands.flags, 0, 1)
check(not Auto.spawnSite(islands), "fallout-only terrain is not selected for a fresh start")
local water = fixture(40, 40, 32)
check(not Auto.spawnSite(water), "map without contestable land has no fabricated start")

local solo = fixture(100, 80); Auto.observeSpawnPhase(solo, 0, -1)
command, _, details = decide(solo, {}, 0)
check(command and details.soloWaiting and details.ticksLeft == -1, "solo waiting for its first pick does not deadlock on a nonexistent countdown")
local late = fixture(100, 80); late.phase = 1
command, _, details = decide(late, {}, 0)
check(command and details.lateJoin, "late join without a countdown can still select a start")
local unknown = fixture(100, 80); unknown.spawnDeadline, unknown.phase_ticks_left = nil, nil
check(not decide(unknown, {}, 0), "missing countdown is not guessed as an immediate final second")
local dead = fixture(100, 80); dead.phase = 2
check(not Auto.spawnPlan(dead, {}, 0), "finished match never receives a start command")
local restarted = fixture(100, 80); local oldMemory = {}; decide(restarted, oldMemory, 0)
oldMemory.spawnPlan.sentTick = 190; restarted.tick = 0; Auto.observeSpawnPhase(restarted, 0, 100)
decide(restarted, oldMemory, 1)
check(not oldMemory.spawnPlan.sentTick and oldMemory.spawnPlan.result.startedTick == 0,
    "tick rollback discards the previous round's selection job and retry timer")

-- Verify timing and acceptance through the original server simulator and client mirror.
local sim = Sim.new(map, {nations = false, tribes = 0, max_humans = 2, spawn_ticks = 40, seed = 88})
local id = sim:add_human("tester", "Tester")
local rawMap = Auto.mapFromBytes(map.tile_bytes, {id = map.id, width = map.W, height = map.H, k_lin = 1}, map.W, map.H)
local mirror = Auto.rawState(sim:snapshot(), rawMap, id)
local real = GameState.new(map); real:load_snapshot(sim:snapshot())
Auto.observeSpawnPhase(real, real.phase, real.phase_ticks_left)
real.phase_changed:Connect(function(phase, left) Auto.observeSpawnPhase(real, phase, left) end)
local mem, submittedAt, autoPlaced = {}, nil, false
for _ = 1, 40 do
    local it = decide(mirror, mem, sim.tick / 10)
    if it and not submittedAt then sim:submit(id, it); submittedAt = sim.spawn_left; mem.spawnPlan.sentTick = mirror.tick end
    local delta = sim:step(); mirror:apply_delta(delta); real:apply_delta(delta)
    for _, e in ipairs(delta.ev) do if e[1] == 19 and tostring(e[4]):find("didn't pick", 1, true) then autoPlaced = true end end
end
check(submittedAt == 10, "real server simulation receives the first start exactly with ten ticks remaining")
check(sim.o_spawned[id] == 1 and sim.o_tiles[id] > 0 and not autoPlaced, "server accepts the selected start before automatic placement")
check(real.phase == 1 and Auto.spawnTicksLeft(real) == 0, "original GameState PHASE handler remains compatible with countdown tracking")
print("TOTAL SPAWN V8.8 CHECKS", checks)
