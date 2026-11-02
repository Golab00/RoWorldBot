local Auto = require("./_generated/bot_module/RoWorldAuto")
local checks = 0
local function check(ok, message) assert(ok, message); checks += 1; print("PASS", message) end
local function fixture()
    local w, h = 300, 240
    local bytes = buffer.create(w * h); buffer.fill(bytes, 0, 128); buffer.fill(bytes, 0, 32, w * 100)
    local map = Auto.mapFromBytes(bytes, {id = "opening851", width = w, height = h, k_lin = 1}, w, h)
    local grid = buffer.create(w * h * 4)
    for y = 100, 159 do
        for x = 20, 79 do buffer.writei32(grid, (y * w + x) * 4, 1) end
        for x = 80, 139 do buffer.writei32(grid, (y * w + x) * 4, 2) end
    end
    local s = Auto.rawState({map_id = "opening851", t = 1200, phase = 1, playing_since = 0, owner = grid, flags = buffer.create(w * h),
        owners = {{1, "Tester", 0, 2, 0, true, 3600, 84500, 81400, 84900, 0, 0, 130 * w + 50},
            {2, "Neighbor", 0, 2, 0, true, 3600, 19000, 0, 200000, 0, 0, 130 * w + 110}}}, map, 1)
    s.structures[1] = {sid = 1, kind = 0, owner = 1, tile = 135 * w + 40, level = 1, active_tick = 0, shots = {}}
    s.structures[2] = {sid = 2, kind = 1, owner = 1, tile = 100 * w + 40, level = 1, active_tick = 0, shots = {}}
    return s
end
local cfg = Auto.settings({AutoBoats = false, AutoWarships = false, AutoDiplomacy = false, AutoNukes = false})
local s = fixture(); local scan = Auto.scan(s); local ctx = Auto.context(s, scan, cfg)
local allowed, reason, details, plan = Auto.newWarAllowed(s, scan, cfg, ctx, 2)
check(allowed and details and plan and reason:find("okazja"), "full army with city and port can exploit a much weaker neighbor before the first factory")
check(plan.goal <= 250 and plan.amount <= 84500 * 0.25 and details.projectedDefenders > 19000,
    "opening opportunity is a small first expedition and includes defender regeneration")
check(plan.amount <= ctx.available and 84500 - plan.amount >= 84500 * 0.75,
    "opening opportunity preserves the regular reserve and at least three quarters of current home troops")
scan.fronts[0] = nil; scan.falloutFronts[0] = nil
local memory = {}; local command, why = Auto.decide(s, scan, cfg, memory, 100)
check(command and command.type == "attack" and memory.armyDetails.openingOpportunity and command.ratio <= 0.25 and why:find("okazja"),
    "actual decision loop sends the limited opportunity attack and explains it")

s.owners[1].troops = 60000; ctx = Auto.context(s, scan, cfg)
check(not Auto.newWarAllowed(s, scan, cfg, ctx, 2), "a depleted home army still waits for economic development")
s.owners[1].troops = 84500; s.owners[2].troops = 70000; ctx = Auto.context(s, scan, cfg)
check(not Auto.newWarAllowed(s, scan, cfg, ctx, 2), "a comparable human opponent is not admitted through the new exception")
s.owners[2].troops = 19000
local front = scan.fronts[2]
s.structures[3] = {sid = 3, kind = 3, owner = 2, tile = front.tile, level = 1, active_tick = 0, shots = {}}
s.structureRevision += 1; ctx = Auto.context(s, scan, cfg)
check(not Auto.newWarAllowed(s, scan, cfg, ctx, 2), "an active enemy fort at the selected entry blocks the early opportunity")
s.structures[3] = nil; s.structureRevision += 1
s.structures[2] = nil; ctx = Auto.context(s, scan, cfg)
check(not Auto.newWarAllowed(s, scan, cfg, ctx, 2), "the exception still requires a first city and a port or factory")
s = fixture(); scan = Auto.scan(s); ctx = Auto.context(s, scan, cfg)
ctx.defending = true
check(not Auto.newWarAllowed(s, scan, cfg, ctx, 2), "new early opportunity is not opened during defense")
ctx.defending = false; s.observed_shield = {[2] = s.tick + 100}
check(not Auto.newWarAllowed(s, scan, cfg, ctx, 2), "known target protection still blocks the attack")
s.observed_shield = {}; s.owners[2].max_troops = 400000
scan.fronts[2].edges = 1
ctx = Auto.context(s, scan, cfg)
check(not Auto.newWarAllowed(s, scan, cfg, ctx, 2), "a narrow prolonged attack with too much projected defender recovery stays blocked")
print("TOTAL OPENING V8.5.1 CHECKS", checks)
