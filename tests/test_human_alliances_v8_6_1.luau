local Auto = require("./_generated/bot_module/RoWorldAuto")
local checks = 0
local function check(ok, message) assert(ok, message); checks += 1; print("PASS", message) end
local function fixture()
    local s = {local_owner = 1, tick = 1200, owners = {}, attacks = {}, requests = {}, alliances = {}, alliance_expires = {}, alliance_ext = {},
        map = {contestable_count = 100000}, betrayers = {}, aggressors = {}}
    for id, kind in pairs({[1] = 2, [2] = 2, [3] = 0, [4] = 1}) do
        s.owners[id] = {id = id, name = "Country" .. id, kind = kind, spawned = true, alive = true, troops = 700000, tiles = 3600}
    end
    return s, {borders = {[2] = {}, [3] = {}, [4] = {}}}, {wars = {}, outgoing = {}, totalIncoming = 0}
end
local cfg = Auto.settings()
for _, bot in ipairs({3, 4}) do
    local s, scan, ctx = fixture()
    local score, reason = Auto.allianceScore(s, scan, bot, cfg, ctx)
    check(score < 0 and reason:find("bot"), "reject nonhuman country kind " .. s.owners[bot].kind)
    s.requests[bot * 1024 + 1] = s.tick
    local command = Auto.diplomacy(s, scan, cfg, {}, ctx, 100)
    check(command and command.type == "ally_reply" and command.target == bot and not command.accept,
        "decline incoming offer from nonhuman country " .. bot)
    s.requests = {}; s.alliances[1024 + bot], s.alliance_expires[1024 + bot] = true, s.tick + 100
    scan.borders = {[bot] = {}}
    command = Auto.diplomacy(s, scan, cfg, {}, ctx, 100)
    check(command == nil, "do not renew an existing nonhuman alliance " .. bot)
    s.alliances, s.alliance_expires = {}, {}
    command = Auto.diplomacy(s, scan, cfg, {}, ctx, 100)
    check(command == nil, "never propose a nonhuman alliance " .. bot)
end
local s, scan, ctx = fixture()
s.requests[2 * 1024 + 1] = s.tick
local command = Auto.diplomacy(s, scan, cfg, {}, ctx, 100)
check(command and command.accept and command.target == 2, "useful human offers remain eligible")
s.requests = {}; scan.borders = {[2] = {}}
command = Auto.diplomacy(s, scan, cfg, {}, ctx, 100)
check(command and command.type == "ally_request" and command.target == 2, "useful human proposals remain eligible")
s.alliances[1026], s.alliance_expires[1026] = true, s.tick + 100
command = Auto.diplomacy(s, scan, cfg, {}, ctx, 100)
check(command and command.type == "ally_extend" and command.target == 2, "useful human renewals remain eligible")
s.betrayers[2] = s.tick
check(Auto.allianceScore(s, scan, 2, cfg, ctx) < 0, "human betrayal exclusion remains active")
s.betrayers = {}; s.aggressors[2] = s.tick
check(Auto.allianceScore(s, scan, 2, cfg, ctx) < 0, "human prior-aggression exclusion remains active")
print("TOTAL HUMAN ALLIANCES V8.6.1 CHECKS", checks)
