local Auto = require("./_generated/bot_module/RoWorldAuto")
local checks = 0
local function check(ok, text) assert(ok, text); checks += 1; print("PASS", text) end
local log = Auto.newLog(Auto.Defaults.LogCapacity)
for i = 1, 1667 do log:add(if i == 2 then "spawn_selected" else "event", {}, i) end
local rows = {}
log:export(function(row) table.insert(rows, row); return "{}" end, {}, Auto.Defaults.LogExportEntries)
check(#rows == 1668 and rows[3].kind == "spawn_selected", "default export retains the spawn evidence in a 1667-event round")
check(rows[1].firstExportedSeq == 1 and rows[1].lastExportedSeq == 1667 and rows[1].exportedEvents == 1667,
    "metadata explicitly identifies the complete exported range")
rows = {}
log:export(function(row) table.insert(rows, row); return "{}" end, {}, 1500)
check(#rows == 1501 and rows[1].firstExportedSeq == 168 and rows[1].exportedEvents == 1500,
    "an explicitly shortened export reports the missing prefix accurately")
local bounded = Auto.newLog(50)
for i = 1, 60 do bounded:add("event", {}, i) end
rows = {}; bounded:export(function(row) table.insert(rows, row); return "{}" end, {}, 6000)
check(#rows == 51 and rows[1].firstExportedSeq == 11 and rows[1].dropped == 10,
    "full export preserves capacity limits and discloses discarded events")
rows = {}; Auto.newLog(50):export(function(row) table.insert(rows, row); return "{}" end, {}, 6000)
check(rows[1].exportedEvents == 0 and rows[1].firstExportedSeq == nil, "empty log has an honest empty exported range")
print("TOTAL EXPORT V8.8.1 CHECKS", checks)
