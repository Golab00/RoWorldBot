local Auto = require("./_generated/bot_module/RoWorldAuto")
local WorldMap = require("../vendor/roworld/src/shared/Core/WorldMap")
local GameState = require("../vendor/roworld/src/shared/Core/GameState")
local Protocol = require("../vendor/roworld/src/shared/Net/Protocol")
local Rewards = require("../vendor/roworld/src/server/Rewards")
local Sim = require("../vendor/roworld/src/shared/Core/Sim")
local MatchServer = require("../vendor/roworld/src/server/MatchServer")
local Defs = require("../vendor/roworld/src/shared/Core/Defs")
local Analytics = require("../vendor/roworld/src/server/Analytics")
local Purchases = require("../vendor/roworld/src/server/Purchases")
local Tutorial = require("../vendor/roworld/src/shared/Data/Tutorial")
local cases = 0
local function check(value, message)
    assert(value, message)
    cases += 1
    print("PASS", message)
end

check(Auto.parseCycles("1000") == 1000 and Auto.parseCycles("999999") == 999999, "user count has no 5/10 cap")
check(Auto.parseCycles("0") == nil and Auto.parseCycles("-1") == nil
    and Auto.parseCycles("1.5") == nil and Auto.parseCycles("nan") == nil, "invalid counts rejected")

local terrainMap = WorldMap.new(90, 60)
terrainMap.id = "mixed"
for y = 0, 59 do
    for x = 0, 89 do
        local byte = if x < 10 then 32 elseif x >= 35 and x < 45 and y >= 20 and y < 30 then 0
            elseif x > 70 then 150 elseif x > 55 then 142 else 128
        if x == 50 and y == 10 then byte = 159 end
        buffer.writeu8(terrainMap.tile_bytes, y * 90 + x, byte)
    end
end
terrainMap:_derive()
local meta = {id = "mixed", width = 90, height = 60, k_lin = 1.5, terrain = terrainMap.tile_bytes}
local nativeMap = WorldMap.from_terrain(meta, 0.8)
local independent = Auto.mapFromBytes(terrainMap.tile_bytes, meta, nativeMap.W, nativeMap.H)
for _, key in ipairs({"land", "terrain", "coastal", "coast_body", "water_body", "land_list", "coast_list"}) do
    check(buffer.tostring(nativeMap[key]) == buffer.tostring(independent[key]), "independent map matches original: " .. key)
end
check(math.abs(independent.k_lin - nativeMap.k_lin) < 1e-12, "map scaling matches original rules")

local map = WorldMap.new(80, 50)
map.id = "offline"
buffer.fill(map.tile_bytes, 0, 128)
map:_derive()
local ownerGrid = buffer.create(map.N * 4)
for y = 15, 34 do for x = 15, 34 do buffer.writei32(ownerGrid, (y * map.W + x) * 4, 1) end end
for y = 15, 34 do buffer.writei32(ownerGrid, (y * map.W + 35) * 4, 2) end
local snap = {
    map_id = "offline", map_w = map.W, map_h = map.H,
    t = 1000, phase = 1, playing_since = 0, owner = ownerGrid,
    flags = buffer.create(map.N),
    owners = {
        {1, "Me", 0xFFFFFFFF, 2, 0, true, 400, 600000, 300000, 1000000, 1000, 0, 20 * map.W + 20},
        {2, "Other", 0xFFFFFFFF, 1, 0, true, 20, 5000, 0, 100000, 500, 0, 20 * map.W + 35},
    },
}
local mirror = GameState.new(map)
mirror:load_snapshot(Protocol.decode_snapshot(Protocol.encode_snapshot(snap)))
mirror.local_owner = 1
check(mirror.loaded and mirror.owners[1].tiles == 400 and mirror.owners[1].troops == 600000,
    "actual snapshot codec and GameState load the multiplayer mirror")
local changedTile = 20 * map.W + 36
mirror:apply_delta(Protocol.decode_delta(Protocol.encode_delta({t = 1001, tiles = {changedTile * 1024 + 1}})))
check(mirror.tick == 1001 and mirror:tile_owner(changedTile) == 1 and mirror.owners[1].tiles == 401,
    "actual delta codec updates the independent mirror")
local scanned = Auto.scan(mirror)
check(scanned.fronts[0] ~= nil and scanned.fronts[2] ~= nil and #scanned.own > 0, "frontiers found from replicated map data")
local cfg = Auto.settings({AutoBuild = false, AutoBoats = false})
local intent, _, bucket = Auto.decide(mirror, scanned, cfg, {}, 100)
check(intent and intent.type == "attack" and mirror:tile_owner(intent.tile) == 0 and bucket == "attack",
    "bot expands into neutral land first")
check(mirror.owners[1].troops * (1 - intent.ratio) >= mirror.owners[1].max_troops * cfg.Reserve,
    "expansion keeps the configured reserve")
local oldTroops = mirror.owners[1].troops
mirror.owners[1].troops = 250000
check(Auto.decide(mirror, scanned, cfg, {}, 100) == nil, "depleted army waits")
mirror.owners[1].troops = oldTroops
check(Auto.decide(mirror, scanned, cfg, {attack = 99}, 100) == nil, "attack interval prevents repeated sends on stale state")
scanned.fronts[0] = nil
intent = Auto.decide(mirror, scanned, cfg, {}, 100)
check(intent and mirror:tile_owner(intent.tile) == 2, "weak neighbor selected when neutral expansion ends")
mirror.owners[2].kind = 2
cfg.AttackHumans = false
check(Auto.decide(mirror, scanned, cfg, {}, 100) == nil, "player-attack switch is honored")
cfg.AttackHumans = true
mirror.alliances[1026] = true
scanned = Auto.scan(mirror)
check(scanned.fronts[2] == nil, "allies are excluded from frontier targets")
mirror.alliances[1026] = nil
local scannedCanceled = Auto.scan(mirror, function() return false end)
check(scannedCanceled == nil, "stopping during a map scan cancels its work")

local clock, balance = 1000, 0
local player = {UserId = 123}
Rewards.reset()
Rewards.configure({
    now = function() return clock end,
    add_stars = function(_, n) balance += n; return true, balance end,
    double = function() return false end, general = function() return false end,
})
local starts, payouts = 0, 0
local function send(op, a, b)
    if op == Protocol.OP.ANALYTICS then
        assert(a == "match_start")
        starts += 1; Rewards.solo_started(player, b)
    elseif op == Protocol.OP.SOLO_RESULT then
        payouts += 1
        check(Rewards.solo_result(player, a) == 100, "exact injected result pays 100 at fixed clock, request " .. payouts)
    else error("unexpected op") end
end
for attempt = 1, 12 do
    if (attempt - 1) % 4 == 0 then Auto.rewardRequests(send, Protocol.OP, "World") end
    Auto.rewardResult(send, Protocol.OP)
end
check(starts == 3 and payouts == 12 and balance == 1200, "four results per start: 12 confirmed payouts, no elapsed time")
check(Auto.isProbeReply({mode = "solo2", total = 100, lines = {{"played", 100}}}), "minimal server reward is recognized")
check(not Auto.isProbeReply({mode = "solo2", total = 150, lines = {{"played", 100}, {"territory", 50}}}),
    "ordinary match reward is not mistaken for test acknowledgement")

-- Construct the real simulation, with no network or persistence services.
local sim = Sim.new(map, {nations = false, tribes = 0, max_humans = 3, spawn_ticks = 10, seed = 9})
local a = sim:add_human("a", "Tester")
local b = sim:add_human("b", "Target")
local c = sim:add_human("c", "Ally")
sim.o_ai[a], sim.o_ai[b], sim.o_ai[c] = 0, 0, 0
for id, cx in pairs({[a] = 15, [b] = 40, [c] = 65}) do
    sim.o_spawned[id] = 1
    for y = 15, 25 do for x = cx - 4, cx + 4 do sim:set_owner(y * map.W + x, id) end end
end
sim.phase = Defs.PHASE_PLAYING
sim.tick = 100
sim.o_troops[a], sim.o_troops[b], sim.o_troops[c] = 1000, 1000, 20000
sim.o_cap[a], sim.o_cap[b], sim.o_cap[c] = 100000, 100000, 100000
sim:form_alliance(b, c)
local pending = {}
local bogus = {type = "donate", target = b, troops = 99000}
MatchServer.cap_donation(sim, bogus, pending)
local bogusOK = sim:donate(a, bogus.target, bogus.troops)
local real = {type = "donate", target = b, troops = 10000}
MatchServer.cap_donation(sim, real, pending)
local realOK = sim:donate(c, real.target, real.troops)
check(not bogusOK and real.troops == 0 and not realOK,
    "invalid donation reserves target capacity and blocks a valid ally donation in the same tick")
print("Donation details: invalid accepted", bogusOK, "pending", pending[b], "valid capped to", real.troops)
sim.tick += 1
real.troops = 10000
MatchServer.cap_donation(sim, real, pending)
check(sim:donate(c, b, real.troops) and sim.o_troops[b] == 11000,
    "valid donation works again on the next tick (issue is limited to that tick)")

-- Observe the difference between ground attacks and missile launches under the spawn shield.
sim.o_shield_until[b] = sim.tick + 300
sim.o_gold[a] = 10000000
local silo = sim:add_struct(Defs.S_SILO, a, 20 * map.W + 15)
silo.active, silo.active_tick, silo.shots = true, sim.tick, {}
local groundOK = sim:intent_attack(a, 20 * map.W + 40, 0.2)
local missileOK = sim:launch_nuke(a, "atom", 20 * map.W + 40)
check(not groundOK and missileOK, "shield blocks ground command but accepts an atom launch (behavior difference)")
print("Shield details: ground", groundOK, "missile", missileOK, "shielded", sim:shielded(b))

Analytics.reset()
Analytics.report(player, "match_start", "solo2", "World")
check(Analytics.in_solo(player), "reward test leaves a reported solo match open until explicitly closed")
Auto.endRewardReport(function(op, ...) assert(op == Protocol.OP.ANALYTICS); Analytics.report(player, ...) end, Protocol.OP)
check(not Analytics.in_solo(player), "cleanup removes the state which blocks public_group from admitting the player")

local records = {}
local store = {}
function store:UpdateAsync(key, transform)
    local updated = transform(records[key])
    if updated ~= nil then records[key] = updated end
    return records[key]
end
Purchases.reset()
Purchases.configure({datastore = store, notify = function() end})
check(Purchases.tutorial_bonus(player, Tutorial.STARS) and Purchases.stars(player) == 1000,
    "tutorial bonus pays from final-step handler with no match or earlier steps")
check(not Purchases.tutorial_bonus(player, Tutorial.STARS) and Purchases.stars(player) == 1000,
    "tutorial bonus remains one-time per account")

-- End-to-end ordinary bot flow through the actual simulator and binary protocol.
local live = Sim.new(map, {nations = false, tribes = 0, max_humans = 2, spawn_ticks = 10, seed = 17})
local selfId = live:add_human("bot", "OfflineBot")
local otherId = live:add_human("other", "OfflineOther")
live.o_ai[selfId], live.o_ai[otherId] = 0, 0
assert(live:human_start(selfId, 20 * map.W + 15))
assert(live:human_start(otherId, 20 * map.W + 60))
for _ = 1, 12 do live:step() end
local client = GameState.new(map)
client:load_snapshot(Protocol.decode_snapshot(Protocol.encode_snapshot(live:snapshot())))
client.local_owner = selfId
local rawMap = Auto.mapFromBytes(map.tile_bytes, {id = map.id, width = map.W, height = map.H, k_lin = map.k_lin}, map.W, map.H)
local rawClient = Auto.rawState(Protocol.decode_snapshot(Protocol.encode_snapshot(live:snapshot())), rawMap, selfId)
local decisions, iterations, mem, lastScan, frames = 0, 0, {}, -1000, nil
local options = Auto.settings({AutoBoats = false})
for _ = 1, 1000 do
    if live.phase == Defs.PHASE_OVER then break end
    iterations += 1
    if iterations - lastScan >= 50 or not frames then frames = Auto.scan(rawClient); lastScan = iterations end
    local command, _, key = Auto.decide(rawClient, frames, options, mem, iterations / 10)
    if command then
        local cleanCommand = Protocol.decode_intent(Protocol.encode_intent(command))
        assert(cleanCommand)
        live:submit(selfId, cleanCommand)
        mem[key] = iterations / 10
        decisions += 1
    end
    local message = Protocol.encode_delta(live:step())
    client:apply_delta(Protocol.decode_delta(message))
    rawClient:apply_delta(Protocol.decode_delta(message))
    assert(rawClient.tick == client.tick and rawClient.phase == client.phase)
    for id, info in pairs(client.owners) do
        local r = rawClient.owners[id]
        assert(r and r.troops == info.troops and r.gold == info.gold and r.max_troops == info.max_troops
            and r.tiles == info.tiles and r.alive == info.alive, "independent owner mismatch at tick " .. client.tick)
    end
    for sid, info in pairs(client.structures) do
        local r = rawClient.structures[sid]
        assert(r and r.kind == info.kind and r.owner == info.owner and r.level == info.level and r.active_tick == info.active_tick)
    end
end
check(decisions > 0 and iterations > 100 and live.o_troops[selfId] >= 0,
    "ordinary bot flow runs through real simulator and protocol without throwing")
print("Offline bot flow:", iterations, "ticks,", decisions, "commands")
check(buffer.tostring(rawClient.owner) == buffer.tostring(client.owner), "independent reader matches original after complete bot flow")
print("TOTAL CHECKS", cases)
