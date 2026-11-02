local Auto = require("./_generated/bot_module/RoWorldAuto")
local checks = 0
local function check(ok, message) assert(ok, message); checks += 1; print("PASS", message) end
local function fixture()
    local w, h = 300, 240
    local bytes = buffer.create(w * h); buffer.fill(bytes, 0, 128); buffer.fill(bytes, 0, 32, w * 100)
    local map = Auto.mapFromBytes(bytes, {id = "recovery87", width = w, height = h, k_lin = 1}, w, h)
    local grid = buffer.create(w * h * 4)
    for y = 100, 159 do
        for x = 20, 79 do buffer.writei32(grid, (y * w + x) * 4, 1) end
        for x = 80, 139 do buffer.writei32(grid, (y * w + x) * 4, 2) end
    end
    local snap = {map_id = "recovery87", t = 3327, phase = 1, playing_since = 0, owner = grid, flags = buffer.create(w * h),
        owners = {{1, "Tester", 0, 2, 0, true, 20664, 2720397, 1449821, 3115229, 0, 0, 130 * w + 50},
            {2, "Opponent", 0, 2, 0, true, 62557, 3617430, 0, 7320416, 0, 0, 130 * w + 110}}}
    return Auto.rawState(snap, map, 1), snap
end
local cfg = Auto.settings({AutoBuild = false, AutoBoats = true, AutoWarships = false, AutoDiplomacy = false, AutoNukes = false, AutoArsenal = false})
local s = fixture()
s.attacks[1] = {aid = 1, attacker = 2, target = 1, troops = 223565, anchor_tile = 130 * s.W + 79}
local scan = Auto.scan(s); local ctx = Auto.context(s, scan, cfg); local memory = {}
local command = Auto.counterPlan(s, scan, cfg, memory, ctx, 100)
check(command and memory.counterDetails.amount == 223565 and not s.combatMemory.offensiveRecovery,
    "logged first counter is planned normally without committing a recovery period")
local recovery = Auto.commitCounter(s, memory.counterDetails, cfg)
check(recovery and recovery.untilTick == 3527 and recovery.spentShare > 0.08,
    "sent logged 223565 counter starts a bounded recovery period")
s.attacks[1] = nil
s.attacks[9] = {aid = 9, attacker = 1, target = 2, troops = 3007, anchor_tile = 130 * s.W + 80}
s.tick = 3335; s.owners[1].troops, s.owners[1].max_troops = 2514159, 3114875
ctx = Auto.context(s, scan, cfg)
check(not ctx.defending and ctx.recoveringOffense, "cancelled incoming army does not erase the separate recovery state")
memory = {}; command = Auto.decide(s, scan, cfg, memory, 104)
check(not command and memory.armyText:find("Odbudowa po kontrach") and memory.offenseBlocked.untilTick == 3527,
    "logged tick 3335 no longer immediately sends 195K more to the expedition")
check(not Auto.newWarAllowed(s, scan, cfg, ctx, 2), "new offensive selection respects recovery as well as expedition reinforcement")

-- Reproduce the later neutral landing after the much larger counter.
s.tick = 3476; s.combatMemory.counterWave = {resources = 3371511, spent = 752993, lastThreatTick = s.tick, startedTick = 3327}
recovery = Auto.commitCounter(s, {target = 2, amount = 1038922}, cfg)
s.tick = 3558; s.attacks = {}; s.owners[1].troops, s.owners[1].max_troops = 1863269, 2860004
ctx = Auto.context(s, scan, cfg)
check(ctx.recoveringOffense and recovery.untilTick == 3676, "large later counter refreshes recovery through the logged landing decision")
check(not Auto.landing(s, scan, cfg, {}, ctx), "direct sea planning does not start the unrelated 490K expedition during recovery")
memory = {}; command = Auto.decide(s, scan, cfg, memory, 130)
check(not command and memory.armyText:find("Odbudowa po kontrach"), "main loop also holds new neutral expansion during recovery")

s.attacks[2] = {aid = 2, attacker = 2, target = 1, troops = 355706, anchor_tile = 130 * s.W + 79}
memory = {}; local bucket
command, _, bucket = Auto.decide(s, scan, cfg, memory, 134)
check(command and command.type == "attack" and bucket == "counter", "new incoming armies can still be countered while offense recovers")
s.attacks = {}
local buildCfg = Auto.settings({AutoBoats = true, AutoWarships = false, AutoDiplomacy = false, AutoNukes = false, AutoArsenal = false})
command = Auto.decide(s, scan, buildCfg, {}, 138)
check(command and command.type == "build" and command.kind == "city", "safe economic development is not blocked by offensive recovery")
s.structures[1] = {sid = 1, kind = 0, owner = 1, tile = 130 * s.W + 35, level = 2, active_tick = 0, shots = {}}
s.structures[2] = {sid = 2, kind = 2, owner = 1, tile = 130 * s.W + 60, level = 1, active_tick = 0, shots = {}}
s.structures[3] = {sid = 3, kind = 5, owner = 2, tile = 130 * s.W + 110, level = 1, active_tick = 0, shots = {}}
s.structureRevision += 1; s.owners[1].gold = 3000000
command = Auto.decide(s, scan, buildCfg, {}, 140)
check(command and command.type == "build" and command.kind == "sam", "needed SAM coverage can still be purchased during offensive recovery")

s.tick = 3677; ctx = Auto.context(s, scan, cfg)
check(not ctx.recoveringOffense and not s.combatMemory.offensiveRecovery, "recovery expires rather than freezing attacks indefinitely")
local early = fixture()
early.combatMemory = {counterWave = {resources = 1000000, spent = 0}}
early.owners[1].troops, early.owners[1].max_troops = 950000, 1000000
Auto.commitCounter(early, {target = 2, amount = 100000}, cfg)
early.tick += 49; ctx = Auto.context(early, Auto.scan(early), cfg)
check(ctx.recoveringOffense, "a full army still waits briefly after a costly counter")
early.tick += 1; ctx = Auto.context(early, Auto.scan(early), cfg)
check(not ctx.recoveringOffense, "85 percent army fill after five quiet seconds permits an early return to offense")
local depleted = fixture(); depleted.combatMemory = {counterWave = {resources = 1000000, spent = 0}}
depleted.owners[1].troops, depleted.owners[1].max_troops = 600000, 1000000
Auto.commitCounter(depleted, {target = 2, amount = 100000}, cfg); depleted.tick += 50
check(Auto.context(depleted, Auto.scan(depleted), cfg).recoveringOffense, "a still depleted army retains its recovery period after the initial quiet interval")

local small = fixture(); small.combatMemory = {counterWave = {resources = 1000000, spent = 0}}
check(not Auto.commitCounter(small, {target = 2, amount = 20000}, cfg), "one tiny cancellation does not trigger recovery")
check(not Auto.commitCounter(small, {target = 2, amount = 40000}, cfg), "small cumulative spending below the threshold does not trigger recovery")
check(Auto.commitCounter(small, {target = 2, amount = 20000}, cfg) ~= nil, "meaningful cumulative spending within the wave eventually triggers recovery")
local npc = fixture(); npc.owners[2].kind = 0; npc.combatMemory = {counterWave = {resources = 1000000, spent = 0}}
check(not Auto.commitCounter(npc, {target = 2, amount = 200000}, cfg), "nation AI counters do not impose the human-war recovery period")
local disabled = fixture(); disabled.combatMemory = {counterWave = {resources = 1000000, spent = 0}}
check(not Auto.commitCounter(disabled, {target = 2, amount = 200000}, Auto.settings({AutoCounterRecovery = false}))
    and disabled.combatMemory.counterWave.spent == 200000, "disabling recovery leaves counter budget accounting intact")

local original, snap = fixture(); original.combatMemory = {counterWave = {resources = 1000000, spent = 0}}
Auto.commitCounter(original, {target = 2, amount = 100000}, cfg)
local hist = Auto.bindHistory(original, nil); snap.t = original.tick + 1
local resynced = Auto.rawState(snap, original.map, 1); Auto.bindHistory(resynced, hist)
check(resynced.combatMemory.offensiveRecovery.untilTick == original.combatMemory.offensiveRecovery.untilTick,
    "same-match synchronization preserves the recovery deadline")
snap.t = 1
local fresh = Auto.rawState(snap, original.map, 1); Auto.bindHistory(fresh, hist)
check(not fresh.combatMemory.offensiveRecovery, "new match does not inherit the last match's recovery deadline")
print("TOTAL RECOVERY V8.7 CHECKS", checks)
