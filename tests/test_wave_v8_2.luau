local Auto = require("./_generated/bot_module/RoWorldAuto")
local checks = 0
local function check(ok, text) assert(ok, text); checks += 1; print("PASS", text) end
local function fixture(home, force)
    local w, h = 300, 240
    local bytes = buffer.create(w * h); buffer.fill(bytes, 0, 128)
    local map = Auto.mapFromBytes(bytes, {id = "wave", width = w, height = h, k_lin = 1}, w, h)
    local owner = buffer.create(w * h * 4)
    for y = 100, 159 do
        for x = 20, 79 do buffer.writei32(owner, (y * w + x) * 4, 1) end
        for x = 80, 139 do buffer.writei32(owner, (y * w + x) * 4, 2) end
    end
    local snap = {map_id = "wave", t = 2907, phase = 1, playing_since = 0, owner = owner, flags = buffer.create(w * h),
        owners = {{1, "Tester", 0, 2, 0, true, 3600, home, 0, 1000000, 0, 0, 130 * w + 50},
            {2, "Smukin", 0, 2, 0, true, 3600, 119692, 0, 1000000, 0, 0, 130 * w + 110},
            {3, "Other", 0, 2, 0, true, 0, 100000, 0, 1000000, 0, 0, -1}}}
    local s = Auto.rawState(snap, map, 1)
    s.attacks[1] = {aid = 1, attacker = 2, target = 1, troops = force, anchor_tile = 130 * w + 79}
    return s, snap
end
local cfg = Auto.settings({AutoBuild = false, AutoBoats = false, AutoWarships = false, AutoNukes = false, AutoDiplomacy = false})
local s, snap = fixture(192399, 332573)
local lost = {}; for y = 100, 102 do for x = 20, 64 do table.insert(lost, (y * s.W + x) * 1024 + 2) end end
s:apply_delta({t = 2908, tiles = lost})
local scan = Auto.scan(s); local ctx = Auto.context(s, scan, cfg); local memory = {}
local command = Auto.counterPlan(s, scan, cfg, memory, ctx, 100)
check(command and memory.counterDetails.amount == math.floor(192399 * 0.55),
    "logged invasion scenario caps the first partial counter at the emergency wave budget")
check(memory.counterDetails.amount < 153919 and memory.counterDetails.homeReserve >= 192399 * 0.35,
    "logged scenario preserves a stable reserve instead of the old 80 percent spend")
check(s.combatMemory.counterWave.spent == 0, "planning alone does not consume the wave budget")
Auto.commitCounter(s, memory.counterDetails)
local spent = s.combatMemory.counterWave.spent
check(spent == memory.counterDetails.amount, "only a sent counter commits the wave budget")
s.owners[1].troops -= spent; s.attacks[1].troops -= spent; s.tick += 35
ctx = Auto.context(s, scan, cfg); memory = {}
command = Auto.counterPlan(s, scan, cfg, memory, ctx, 104)
check(not command and memory.counterText:find("budzet"), "next partial counter cannot spend the same wave allocation again")
s.owners[1].troops = 50054; s.attacks[1].troops = 139454; s.tick += 35
ctx = Auto.context(s, scan, cfg)
command = Auto.counterPlan(s, scan, cfg, memory, ctx, 108)
check(not command, "replay of the logged shrinking army no longer triggers another percentage drain")
local floorBefore = s.combatMemory.counterWave.resources * cfg.CounterWaveReserve
s.attacks[1].attacker = 3; s.attacks[1].troops = 191504
ctx = Auto.context(s, scan, cfg); Auto.counterPlan(s, scan, cfg, {}, ctx, 112)
check(s.combatMemory.counterWave.spent == spent and s.combatMemory.counterWave.resources * cfg.CounterWaveReserve == floorBefore,
    "switching aggressors does not reset the wave limit or shrink the remembered reserve")

s.attacks[1].attacker = 2; s.attacks[1].troops = 100000; s.owners[1].troops = 180000
ctx = Auto.context(s, scan, cfg); memory = {}
command = Auto.counterPlan(s, scan, cfg, memory, ctx, 116)
check(s.combatMemory.counterWave.resources == 180000 + spent,
    "actual army recovery grows the available resource estimate")
check(command and memory.counterDetails.amount <= memory.counterDetails.waveRemaining
    and memory.counterDetails.homeReserve >= memory.counterDetails.rememberedReserve,
    "a renewed partial counter respects both remaining budget and the remembered reserve")
local hist = Auto.bindHistory(s)
snap.t = s.tick + 1
local afterSync = Auto.rawState(snap, s.map, 1); Auto.bindHistory(afterSync, hist)
check(afterSync.combatMemory.counterWave.spent == spent and afterSync.combatMemory.counterWave.resources == s.combatMemory.counterWave.resources,
    "resync does not grant a fresh counter budget")
snap.t = 1
local newMatch = Auto.rawState(snap, s.map, 1); Auto.bindHistory(newMatch, hist)
check(newMatch.combatMemory.counterWave == nil, "a new match starts without a previous wave budget")

local exact = fixture(200000, 40000)
exact.combatMemory = {counterWave = {resources = 400000, spent = 200000, startedTick = 2800, lastThreatTick = exact.tick}}
scan = Auto.scan(exact); ctx = Auto.context(exact, scan, cfg); memory = {}
command = Auto.counterPlan(exact, scan, cfg, memory, ctx, 100)
check(command and memory.counterDetails.amount == 40000 and memory.counterDetails.waveLimitException,
    "a full safe cancellation can finish an attack even after the partial-counter budget is exhausted")
Auto.commitCounter(exact, memory.counterDetails); exact.owners[1].troops -= 40000; exact.attacks[1].troops = 20000; exact.tick += 30
ctx = Auto.context(exact, scan, cfg); memory = {}; command = Auto.counterPlan(exact, scan, cfg, memory, ctx, 104)
check(command and memory.counterDetails.homeReserve == 140000, "full cancellation still honors the original wave reserve floor")
Auto.commitCounter(exact, memory.counterDetails); exact.owners[1].troops -= 20000; exact.tick += 30
ctx = Auto.context(exact, scan, cfg)
check(not Auto.counterPlan(exact, scan, cfg, {}, ctx, 108), "even repeated full stops cannot drain the remembered reserve")

local tooSmall = fixture(200000, 2000000)
scan = Auto.scan(tooSmall); ctx = Auto.context(tooSmall, scan, cfg); memory = {}
check(not Auto.counterPlan(tooSmall, scan, cfg, memory, ctx, 100) and memory.counterText:find("za mala"),
    "skip a partial counter too small to meaningfully reduce a vastly stronger attack")

local calm = fixture(400000, 600000)
scan = Auto.scan(calm); ctx = Auto.context(calm, scan, cfg); Auto.counterPlan(calm, scan, cfg, {}, ctx, 100)
local oldWave = calm.combatMemory.counterWave
calm.attacks = {}; calm.tick += 50; ctx = Auto.context(calm, scan, cfg)
Auto.counterPlan(calm, scan, cfg, {}, ctx, 105)
check(calm.combatMemory.counterWave == oldWave, "a short pause in attacks does not reset the wave")
calm.tick += cfg.CounterWaveRestTicks + 1; ctx = Auto.context(calm, scan, cfg)
Auto.counterPlan(calm, scan, cfg, {}, ctx, 120)
check(calm.combatMemory.counterWave == nil, "a quiet period closes the combat wave")
memory = {armyText = "OBRONA: old", buildText = "Pomija defense: front dotrze przed koncem budowy"}
Auto.decide(calm, scan, cfg, memory, 122)
check(not memory.armyText:find("OBRONA", 1, true) and not memory.buildText:find("front dotrze", 1, true),
    "fresh calm decisions clear stale defense and construction warnings")
print("TOTAL WAVE V8.2 CHECKS", checks)
