local Auto = require("./_generated/bot_module/RoWorldAuto")
local WorldMap = require("../vendor/roworld/src/shared/Core/WorldMap")
local SimNav = require("../vendor/roworld/src/shared/Core/SimNav")
local checks = 0
local function check(ok, message) assert(ok, message); checks += 1; print("PASS", message) end
local function landFixture()
    local w, h = 300, 240
    local bytes = buffer.create(w * h); buffer.fill(bytes, 0, 128); buffer.fill(bytes, 0, 32, w * 100)
    local map = Auto.mapFromBytes(bytes, {id = "rick852", width = w, height = h, k_lin = 1}, w, h)
    local grid = buffer.create(w * h * 4)
    for y = 100, 159 do
        for x = 20, 79 do buffer.writei32(grid, (y * w + x) * 4, 1) end
        for x = 80, 139 do buffer.writei32(grid, (y * w + x) * 4, 2) end
    end
    local s = Auto.rawState({map_id = "rick852", t = 1565, phase = 1, playing_since = 200, owner = grid, flags = buffer.create(w * h),
        owners = {{1, "Tester", 0, 2, 0, true, 12299, 815741, 127250, 1093436, 0, 0, 130 * w + 50},
            {2, "Rick", 0, 2, 0, true, 4477, 4004, 0, 755048, 0, 0, 130 * w + 110}}}, map, 1)
    s.structures[1] = {sid = 1, kind = 0, owner = 1, tile = 135 * w + 40, level = 1, active_tick = 0, shots = {}}
    s.structures[2] = {sid = 2, kind = 1, owner = 1, tile = 100 * w + 40, level = 1, active_tick = 0, shots = {}}
    return s
end
local cfg = Auto.settings({AutoBoats = false, AutoWarships = false, AutoDiplomacy = false, AutoNukes = false})
local s = landFixture(); local scan = Auto.scan(s); scan.fronts[0] = nil
local ctx = Auto.context(s, scan, cfg)
local allowed, _, details, plan = Auto.newWarAllowed(s, scan, cfg, ctx, 2)
check(allowed and details.overwhelming and s.owners[1].troops < s.owners[1].max_troops * 0.9,
    "logged 815741 versus 4004 case can open a small land attack below 90 percent army fill")
check(plan.amount <= s.owners[1].troops * 0.15 and details.projectedDefenders <= s.owners[1].troops * 0.15,
    "overwhelming exception bounds both expedition cost and enemy recovery")
local memory = {}; local command, reason = Auto.decide(s, scan, cfg, memory, 100)
check(command and command.type == "attack" and memory.armyDetails.openingOpportunity.overwhelming and reason:find("duza przewaga"),
    "real decision loop sends and explains the overwhelming land opportunity")
s.owners[1].troops = 400000; ctx = Auto.context(s, scan, cfg)
check(not Auto.newWarAllowed(s, scan, cfg, ctx, 2), "overwhelming exception still respects the normal readiness floor")
s.owners[1].troops, s.owners[2].troops = 815741, 200000; ctx = Auto.context(s, scan, cfg)
check(not Auto.newWarAllowed(s, scan, cfg, ctx, 2), "a merely weaker enemy does not get the overwhelming exception below 90 percent fill")
s.owners[2].troops = 4004; s.alliances[1026] = true; ctx = Auto.context(s, scan, cfg)
check(not Auto.newWarAllowed(s, scan, cfg, ctx, 2), "an actual alliance continues to exclude Rick from the new exception")

local w, h = 12, 12
local bytes = buffer.create(w * h); buffer.fill(bytes, 0, 128)
local waterTile = 4 * w + 4; buffer.writeu8(bytes, waterTile, 32)
local map = Auto.mapFromBytes(bytes, {id = "one-point", width = w, height = h, k_lin = 1}, w, h)
local water = {map = map, W = w, H = h, N = w * h}
local from, target = 4 * w + 3, 3 * w + 4
local body = buffer.readu16(map.coast_body, target * 2)
check(Auto.waterEndpoint(water, from, body) == waterTile and Auto.waterEndpoint(water, target, body) == waterTile,
    "corner shores can share exactly one water endpoint")
check(not Auto.waterPath(water, from, target), "one-point routes seen in the log are rejected locally")
local world = WorldMap.new(w, h); world.id = "one-point"; buffer.copy(world.tile_bytes, 0, bytes); world:_derive()
local nav = SimNav.shared(world)
local start, finish = nav:water_next_to(from, body), nav:water_next_to(target, body)
check(start == finish and #nav:find_path(start, finish) == 1,
    "original navigation returns the single point rejected by the server's two-point minimum")
local endpointMatches = true
for t = 0, w * h - 1 do
    if buffer.readu8(map.coastal, t) == 1 then
        local b = buffer.readu16(map.coast_body, t * 2)
        if (Auto.waterEndpoint(water, t, b) or -1) ~= nav:water_next_to(t, b) then endpointMatches = false end
    end
end
check(endpointMatches, "client endpoint priority matches original navigation on all shores around the corner")
for x = 5, 8 do buffer.writeu8(bytes, 4 * w + x, 32) end
map = Auto.mapFromBytes(bytes, {id = "real-route", width = w, height = h, k_lin = 1}, w, h)
water.map = map
local path = Auto.waterPath(water, from, 3 * w + 8)
check(path and #path >= 2, "valid multi-point sea routes remain available")
print("TOTAL RICK V8.5.2 CHECKS", checks)
