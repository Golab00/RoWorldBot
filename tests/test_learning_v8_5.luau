local Auto = require("./_generated/bot_module/RoWorldAuto")
local checks = 0
local function check(ok, text) assert(ok, text); checks += 1; print("PASS", text) end
local function fixture()
    local w, h = 500, 300
    local bytes = buffer.create(w * h); buffer.fill(bytes, 0, 128)
    local map = Auto.mapFromBytes(bytes, {id = "learning85", width = w, height = h, k_lin = 1}, w, h)
    local grid = buffer.create(w * h * 4)
    for y = 50, 249 do
        for x = 20, 259 do buffer.writei32(grid, (y * w + x) * 4, 1) end
        for x = 260, 459 do buffer.writei32(grid, (y * w + x) * 4, 2) end
    end
    return Auto.rawState({map_id = "learning85", t = 1000, phase = 1, playing_since = 0, owner = grid, flags = buffer.create(w * h),
        owners = {{1, "Tester", 0, 2, 0, true, 48000, 700000, 939572, 1000000, 0, 0, 150 * w + 100},
            {2, "Neighbor", 0, 2, 0, true, 40000, 800000, 0, 1000000, 0, 0, 150 * w + 350}}}, map, 1)
end
local function add(s, sid, kind, x, y, who, level, active)
    local b = {sid = sid, kind = kind, owner = who or 1, tile = y * s.W + x, level = level or 1, active_tick = active or 0, shots = {}}
    s.structures[sid] = b; s.structureRevision += 1
    s.built[b.owner] = s.built[b.owner] or {}; s.built[b.owner][kind] = (s.built[b.owner][kind] or 0) + b.level
    return b
end
local cfg = Auto.settings({AutoBoats = false, AutoWarships = false, AutoDiplomacy = false})
local s = fixture()
add(s, 1, 0, 80, 130, 1, 2); add(s, 2, 2, 100, 160); add(s, 3, 5, 400, 150, 2)
local losses = {}; for y = 60, 64 do for x = 20, 219 do table.insert(losses, (y * s.W + x) * 1024) end end
s:apply_delta({t = 1001, tiles = losses}); s.ownNuclearHit = s.tick
local scan = Auto.scan(s); local ctx = Auto.context(s, scan, cfg)
check(ctx.neutralizedLost == 1000 and ctx.groundLost == 0 and ctx.criticalLoss and not ctx.groundLosing,
    "bomb-neutralized land retains strategic loss without inventing an invading land front")
check(ctx.nuclearDefense and ctx.nuclearDefense.needed and ctx.nuclearDefense.cost == 1500000,
    "recent bombing plans real SAM coverage with its actual price")
local memory = {}; local command = Auto.buildPlan(s, scan, cfg, memory, ctx, true)
check(not command and memory.weaponText:find("SAM"), "blast loss alone does not spend the SAM savings on an emergency fort")
check(not Auto.arsenalBuildPlan(s, scan, cfg, {}, ctx, false), "optional arsenal spending cannot take the SAM reserve")
s.owners[1].gold = 1600000
ctx = Auto.context(s, scan, cfg); memory = {}; command = Auto.buildPlan(s, scan, cfg, memory, ctx, true)
check(command and command.kind == "sam" and memory.buildDetails.priority:find("trafieniu"),
    "funded replacement SAM is selected before another fort or offensive weapon")
local place = s.rules.placement(s, 1, "sam", command.tile)
check(place.ok and s.map.range_d2(command.tile, s.structures[1].tile) <= 70^2,
    "reserved SAM site is legal and covers the valuable city")
add(s, 4, 4, command.tile % s.W, command.tile // s.W, 1, 1, s.tick + 300)
ctx = Auto.context(s, scan, cfg)
check(not ctx.nuclearDefense, "a pending launcher already reserves its planned coverage instead of spawning a duplicate")

local proactive = fixture()
add(proactive, 1, 0, 80, 130, 1, 2); add(proactive, 2, 2, 100, 160); add(proactive, 3, 5, 400, 150, 2)
scan = Auto.scan(proactive); ctx = Auto.context(proactive, scan, cfg)
check(ctx.nuclearDefense and ctx.nuclearDefense.needed and not ctx.nuclearThreat,
    "a developed unshielded economy can save for coverage before the first observed impact")
check(not Auto.context(proactive, scan, Auto.settings({AutoSAM = false})).nuclearDefense,
    "manual SAM disable also disables automatic SAM saving")
proactive.structures[3] = nil; proactive.structureRevision += 1
check(not Auto.context(proactive, scan, cfg).nuclearDefense, "no SAM reserve is invented without a relevant threat or known silo")
add(proactive, 4, 5, 400, 150, 2)
proactive.attacks[1] = {aid = 1, attacker = 2, target = 1, troops = 3000000, anchor_tile = 150 * proactive.W + 259}
ctx = Auto.context(proactive, scan, cfg)
check(ctx.nuclearDefense and not ctx.nuclearDefense.needed and ctx.nuclearDefense.reserve == 0,
    "no long-term SAM reserve freezes the budget when no site can survive its construction")

local ground = fixture()
add(ground, 1, 0, 80, 130, 1, 2); add(ground, 2, 2, 100, 160)
ground.owners[1].gold = 250000
ground.attacks[1] = {aid = 1, attacker = 2, target = 1, troops = 300000, anchor_tile = 150 * ground.W + 259}
scan = Auto.scan(ground); ctx = Auto.context(ground, scan, cfg)
ctx.nuclearDefense = {needed = true, cost = 3000000, reserve = 3000000, tile = 150 * ground.W + 60}
memory = {}; command = Auto.buildPlan(ground, scan, cfg, memory, ctx, true)
check(command and command.kind == "defense", "real ground invasion can still buy an emergency fort despite longer-term SAM savings")
check(memory.buildDetails.estimatedFrontArrivalTicks > Auto.constructionWindow(cfg, 50),
    "emergency fort includes dispatch latency and a larger survival margin")
check(Auto.constructionWindow(cfg, 50) > 73.4945, "the logged 73-tick fort estimate is no longer accepted for a 50-tick build")

-- Averages show losses moving away, while the leading part of a narrow breakthrough approaches.
local edgeState = fixture()
local point = 150 * edgeState.W + 200
local edgeContext = {territory = {lossPoints = {}, attackers = {}}, incoming = {}}
for _ = 1, 10 do
    table.insert(edgeContext.territory.lossPoints, {tile = 150 * edgeState.W + 100, tick = 960, to = 2})
    table.insert(edgeContext.territory.lossPoints, {tile = 150 * edgeState.W + 190, tick = 960, to = 2})
    table.insert(edgeContext.territory.lossPoints, {tile = 150 * edgeState.W + 60, tick = 990, to = 2})
    table.insert(edgeContext.territory.lossPoints, {tile = point, tick = 990, to = 2})
end
check(Auto.frontSpeed(edgeState, {}, edgeContext, 2, point) > 0.4,
    "approaching leading edge is not hidden by simultaneous sideways losses in the average")
local unlearned = Auto.frontSpeed(edgeState, {}, edgeContext, 2, point)
edgeState.learningProfile = Auto.newLearning({schema = 1, frontMultiplier = 2})
edgeContext.frontSpeedCache = nil
check(Auto.frontSpeed(edgeState, {}, edgeContext, 2, point) == unlearned * 2,
    "learned front caution actually changes future construction arrival forecasts")

local saved = Auto.newLearning({schema = 1, frontMultiplier = 200, commandLagTicks = -5, failures = 10, successes = 0/0})
check(saved.frontMultiplier == 4 and saved.commandLagTicks == 15 and saved.successes == 0,
    "imported learning values are finite, validated and bounded")
check(Auto.newLearning({schema = 99, frontMultiplier = 4}).frontMultiplier == 1,
    "an incompatible saved profile falls back to known defaults")

local learner = fixture(); learner.learningProfile = Auto.newLearning()
local tile = 150 * learner.W + 100
Auto.trackConstruction(learner, {type = "build", kind = "defense", tile = tile}, {buildTicks = 50, estimatedFrontArrivalTicks = 73.4945}, 1, cfg)
learner.tick = 1020; add(learner, 100, 3, 100, 150, 1, 1, 1070)
local events = Auto.updateLearning(learner, cfg)
check(#events == 1 and events[1].outcome == "command_delay" and learner.learningProfile.commandLagTicks == 25,
    "server confirmation delay increases the learned construction dispatch allowance")
learner.tick = 1021; learner.structures[100] = nil; buffer.writei32(learner.owner, tile * 4, 2)
events = Auto.updateLearning(learner, cfg)
check(#events == 1 and events[1].outcome == "captured" and events[1].unfinished and learner.learningProfile.frontMultiplier == 2,
    "a confirmed fort captured before completion increases front caution using its prediction error")
check(learner.learningProfile.failures == 1 and Auto.constructionBlocked(learner, tile),
    "failed construction is counted and its local area temporarily excluded")
check(#Auto.updateLearning(learner, cfg) == 0 and learner.learningProfile.failures == 1,
    "the same loss is learned exactly once")
check(Auto.constructionWindow(cfg, 50, learner) == 112.5,
    "future construction uses the learned delay instead of only the default")
learner.tick = 1700; Auto.updateLearning(learner, cfg)
check(not Auto.constructionBlocked(learner, tile), "temporary failed-site memory expires")

local weapon = fixture(); weapon.learningProfile = Auto.newLearning()
Auto.trackConstruction(weapon, {type = "build", kind = "sam", tile = tile}, {buildTicks = 300, estimatedFrontArrivalTicks = 600}, 2, cfg)
weapon.tick = 1005; add(weapon, 2, 4, 100, 150, 1, 1, 1305); Auto.updateLearning(weapon, cfg)
weapon.tick = 1020; weapon.structures[2] = nil; buffer.writei32(weapon.owner, tile * 4, 0)
weapon.explosions = {{status = "impact", tick = 1020, tile = tile, radius = 30}}
events = Auto.updateLearning(weapon, cfg)
check(events[1].outcome == "weapon_loss" and weapon.learningProfile.frontMultiplier == 1,
    "a bomb-destroyed launcher does not falsely teach that the land front moved faster")
weapon.learningProfile.frontMultiplier = 3.8; weapon.tick = 1100
buffer.writei32(weapon.owner, tile * 4, 1)
Auto.trackConstruction(weapon, {type = "build", kind = "defense", tile = tile}, {buildTicks = 50, estimatedFrontArrivalTicks = 200}, 5, cfg)
weapon.tick = 1105; add(weapon, 5, 3, 100, 150, 1, 1, 1155); Auto.updateLearning(weapon, cfg)
weapon.tick = 1110; weapon.structures[5] = nil; buffer.writei32(weapon.owner, tile * 4, 2); Auto.updateLearning(weapon, cfg)
check(weapon.learningProfile.frontMultiplier == 4, "repeated prediction errors cannot push learned caution beyond its defined bound")

local uncertain = fixture(); uncertain.learningProfile = Auto.newLearning()
Auto.trackConstruction(uncertain, {type = "build", kind = "defense", tile = tile}, {buildTicks = 50}, 3, cfg)
uncertain.tick = 1081; events = Auto.updateLearning(uncertain, cfg)
check(events[1].outcome == "unconfirmed_command" and uncertain.learningProfile.failures == 0,
    "an unconfirmed command is logged separately from an observed defeat")
local existing = add(uncertain, 3, 4, 100, 150)
Auto.trackConstruction(uncertain, {type = "build", kind = "sam", tile = tile}, {buildTicks = 300}, 4, cfg)
check(not uncertain.combatMemory.constructionLearning.pending[4], "upgrades are not mistaken for a new building lifecycle")

local successful = fixture(); successful.learningProfile = Auto.newLearning({schema = 1, frontMultiplier = 2})
for i = 1, 12 do
    local t = 150 * successful.W + 50 + i * 5
    Auto.trackConstruction(successful, {type = "build", kind = "defense", tile = t}, {buildTicks = 50}, i, cfg)
    add(successful, i, 3, 50 + i * 5, 150, 1, 1, 1050)
end
successful.tick = 1005; Auto.updateLearning(successful, cfg)
successful.tick = 1150; events = Auto.updateLearning(successful, cfg)
check(#events == 12 and successful.learningProfile.successes == 12 and successful.learningProfile.frontMultiplier == 1.96,
    "many buildings surviving construction allow only a gradual reduction in learned caution")
check(not next(successful.combatMemory.constructionLearning.pending), "settled construction records do not accumulate forever")
successful.tick = 1200; local resumed = fixture(); resumed.tick = 1200
local history = Auto.bindHistory(successful, nil); Auto.bindHistory(resumed, history)
check(resumed.combatMemory == successful.combatMemory, "same-match synchronization preserves the construction learning ledger")
local freshMatch = fixture(); freshMatch.map_id = "different-match"
Auto.bindHistory(freshMatch, history)
check(not freshMatch.combatMemory.constructionLearning, "a new match does not inherit obsolete blocked coordinates or pending construction")
check(cfg.LogCapacity == 6000 and cfg.LogExportEntries == 6000, "defaults retain and export the whole bounded history of a long match")
print("TOTAL LEARNING V8.5 CHECKS", checks)
