local Protocol = require("../vendor/roworld/src/shared/Net/Protocol")
local Auto = require("./_generated/bot_module/RoWorldAuto")
local checks, instances, sent, scheduled = 0, {}, {}, {}
local function check(ok, msg) assert(ok, msg); checks += 1; print("PASS", msg) end
local function signal()
    local s = {listeners = {}}
    function s:Connect(fn)
        local c = {fn = fn, connected = true}
        function c:Disconnect() self.connected = false end
        table.insert(self.listeners, c); return c
    end
    function s:Fire(...)
        for _, c in ipairs(self.listeners) do if c.connected then c.fn(...) end end
    end
    return s
end
local function node(name)
    local n = {Name = name, children = {}, Activated = signal(), InputBegan = signal()}
    function n:FindFirstChild(key) return self.children[key] end
    function n:WaitForChild(key) return self.children[key] end
    function n:Destroy() self.destroyed = true end
    function n:CaptureFocus() end
    return n
end
local replies = {OnClientEvent = signal()}
local remote = {FireServer = function(_, ...) table.insert(sent, table.pack(...)) end}
local protocolNode = {}
local shared = node("Airfront"); shared.children.Net = node("Net"); shared.Net = shared.children.Net
shared.Net.children.Protocol = protocolNode; shared.Net.Protocol = protocolNode
local net = node("AirfrontNet"); net.children.ToServer = remote; net.children.ToClient = replies
local rs = node("ReplicatedStorage"); rs.children.AirfrontNet = net; rs.children.Airfront = shared
local player = node("Player"); player.children.PlayerGui = node("PlayerGui")
local inputs = node("UserInputService"); function inputs:GetFocusedTextBox() return nil end
local services = {ReplicatedStorage = rs, Players = {LocalPlayer = player}, UserInputService = inputs,
    HttpService = {JSONEncode = function() return "{}" end}}
local mocks = setmetatable({}, {__index = getfenv(0)})
mocks.game = {GetService = function(_, name) assert(services[name], name); return services[name] end}
mocks.workspace = {CurrentCamera = {ViewportSize = {Y = 900}}}
mocks.Instance = {new = function(kind) local n = node(kind); n.ClassName = kind; table.insert(instances, n); return n end}
mocks.Color3 = {fromRGB = function(...) return {...} end, new = function(...) return {...} end}
mocks.UDim2 = {new = function(...) return {...} end, fromOffset = function(x, y) return {x = x, y = y} end,
    fromScale = function(x, y) return {x = x, y = y} end}
mocks.UDim = {new = function(...) return {...} end}; mocks.Vector2 = {new = function(...) return {...} end}
mocks.Enum = {ScrollingDirection = {Y = 1}, Font = {Gotham = 1, Code = 2}, TextXAlignment = {Left = 1},
    TextYAlignment = {Top = 1}, KeyCode = {F8 = 8, F9 = 9}}
mocks.task = {spawn = function(fn) table.insert(scheduled, coroutine.create(fn)) end,
    wait = function(seconds) mocks.lastWait = seconds; coroutine.yield() end, delay = function(_, fn) table.insert(scheduled, coroutine.create(fn)) end}
local globals = {}
mocks.getgenv = function() return globals end
mocks.require = function(arg) assert(arg == protocolNode, "unexpected game module require"); return Protocol end
local boot = function()
-- BOT_SOURCE_HERE
end
setfenv(boot, mocks)
local ok, controller = pcall(boot)
check(ok and type(controller) == "table" and controller.Alive, "full client script boots with the documented game services")
check(sent[1][1] == Protocol.OP.HELLO, "request inventory only after the client listener is installed")
check(#scheduled == 3, "mirror, optional test and main decision loops are scheduled without blocking panel creation")
local function findButton(prefix)
    for i = #instances, 1, -1 do
        local n = instances[i]
        if not n.destroyed and n.ClassName == "TextButton" and type(n.Text) == "string" and n.Text:find(prefix, 1, true) == 1 then return n end
    end
end
local b = findButton("WYPOSAZENIE / USTAWIENIA")
check(b and b.Position.y == 275, "equipment settings button is accessible above the map summary")
b.Activated:Fire()
check(findButton("Railgun | AUTO | czekam") ~= nil, "settings show unknown inventory honestly")
replies.OnClientEvent:Fire(Protocol.OP.INVENTORY, {unlocks = {"railgun"}, stars = 1000})
check(controller.Equipment.owned.railgun and findButton("Railgun | AUTO | posiadane"), "inventory event refreshes ownership and the open settings UI")
local row = findButton("Railgun |")
row.Activated:Fire()
check(controller.Config.EquipmentModes.railgun == "owned" and globals.RoWorldEquipmentModes.railgun == "owned", "manual MAM mode is saved for reinjection")
row.Activated:Fire()
check(controller.Config.EquipmentModes.railgun == "off", "manual OFF disables a detected unlock")
row.Activated:Fire()
check(controller.Config.EquipmentModes.railgun == "auto", "manual control cycles back to AUTO")
findButton("ANALIZA:").Activated:Fire()
check(controller.Config.DeepAnalysis and controller.Config.ScanGap == 1 and controller.Config.BorderSamples == 256, "more detailed mode adjusts CPU analysis without changing network message rate limits")
findButton("OKRETY WOJENNE:").Activated:Fire()
check(not controller.Config.AutoWarships, "settings can disable warship decisions")
findButton("ZAMKNIJ USTAWIENIA").Activated:Fire()
replies.OnClientEvent:Fire(Protocol.OP.INVENTORY, {unlocks = {"railgun", "mega"}})
check(controller.Equipment.owned.mega, "later inventory updates work after the popup is closed")
-- Start each long-running task once; execution yields instead of performing an endless wait.
for i = 1, 3 do local success, err = coroutine.resume(scheduled[i]); assert(success, tostring(err)) end
check(controller.Session and controller.Session.Detached, "main loop selects the independent reader without requiring GameState")
findButton("BOT:").Activated:Fire()
check(controller.Enabled, "F8-equivalent panel toggle enables the bot")
inputs.InputBegan:Fire({KeyCode = 8}, false)
check(not controller.Enabled, "keyboard F8 uses the same toggle")
local spawnW, spawnH, beforeSpawn = 180, 120, #sent
local spawnBytes = buffer.create(spawnW * spawnH); buffer.fill(spawnBytes, 0, 128)
local spawnMap = Auto.mapFromBytes(spawnBytes, {id = "runtime-spawn", width = spawnW, height = spawnH, k_lin = 1}, spawnW, spawnH)
local spawnState = Auto.rawState({map_id = "runtime-spawn", t = 100, phase = 0, phase_left = 30,
    owner = buffer.create(spawnW * spawnH * 4), flags = buffer.create(spawnW * spawnH),
    owners = {{1, "Tester", 0, 2, 0, true, 0, 25000, 0, 0, 0, 0, -1}}}, spawnMap, 1)
controller.Session.state = spawnState
inputs.InputBegan:Fire({KeyCode = 8}, false)
local function pollStart(times)
    for _ = 1, times do local success, err = coroutine.resume(scheduled[3]); assert(success, tostring(err)) end
end
local function startsSent()
    local found = {}
    for i = beforeSpawn + 1, #sent do
        if sent[i][1] == Protocol.OP.INTENT then
            local it = Protocol.decode_intent(sent[i][2]); if it and it.type == "spawn" then table.insert(found, it) end
        end
    end
    return found
end
pollStart(20)
check(#startsSent() == 0, "runtime analyzes but sends no start three seconds before the deadline")
check(mocks.lastWait == 0.05, "countdown polls frequently enough to act within its final second")
spawnState:apply_delta({t = 119}); pollStart(4)
check(#startsSent() == 0 and Auto.spawnTicksLeft(spawnState) == 11, "runtime keeps waiting with eleven server ticks left")
spawnState:apply_delta({t = 120, ev = {{2, 0, 10}}}); pollStart(4)
local chosenStarts = startsSent()
check(#chosenStarts == 1, "runtime sends exactly one initial start using the real codec in the final second")
check(buffer.readi32(spawnState.owner, chosenStarts[1].tile * 4) == 0, "runtime start targets actual unoccupied land")
local analysisLog, selectionLog
for _, event in ipairs(controller.Log.entries) do
    if event.kind == "spawn_analysis" then analysisLog = event end
    if event.kind == "spawn_selected" then selectionLog = event end
end
check(analysisLog and analysisLog.data.evaluated == spawnW * spawnH, "runtime log verifies coverage of every free land tile")
check(selectionLog and selectionLog.data.ticksLeft == 10 and selectionLog.data.tile == chosenStarts[1].tile,
    "runtime log records the actual selected location and remaining server time")
spawnState:apply_delta({t = 121, ev = {{3, 1, chosenStarts[1].tile}}}); pollStart(4)
check(#startsSent() == 1 and controller.LastError == nil, "server confirmation prevents repeated selection without stopping the bot")
inputs.InputBegan:Fire({KeyCode = 8}, false)
local w, h = 120, 100
local bytes = buffer.create(w * h); buffer.fill(bytes, 0, 128)
local map = Auto.mapFromBytes(bytes, {id = "runtime", width = w, height = h, k_lin = 1}, w, h)
local owned = buffer.create(w * h * 4)
for y = 30, 49 do for x = 30, 49 do buffer.writei32(owned, (y * w + x) * 4, 1) end end
local state = Auto.rawState({map_id = "runtime", t = 1200, phase = 1, playing_since = 0, owner = owned, flags = buffer.create(w * h),
    owners = {{1, "Tester", 0, 2, 0, true, 400, 700000, 2000000, 1000000, 0, 0, 40 * w + 40}}}, map, 1)
controller.Session.state = state
inputs.InputBegan:Fire({KeyCode = 8}, false)
for _ = 1, 4 do local success, err = coroutine.resume(scheduled[3]); assert(success, tostring(err)) end
check(controller.Alive and controller.Enabled and controller.LastError == nil, "full decision loop binds the independent state and equipment without a runtime error")
local decoded
for _, packet in ipairs(sent) do
    if packet[1] == Protocol.OP.INTENT then local it = Protocol.decode_intent(packet[2]); if it and it.type == "attack" then decoded = it end end
end
check(decoded and decoded.type == "attack" and decoded.ratio > 0 and decoded.ratio < 0.7,
    "runtime actually sends its planned action through the real intent codec")
check(controller.MatchHistory and controller.MatchHistory.owner == 1 and state.equipment == controller.Equipment,
    "runtime shares the per-match history and current inventory with the decision state")
state:apply_delta({t = 1201, tiles = {(30 * w + 30) * 1024}, ev = {{14, 7, 2, 1, 100000, 30 * w + 30, false}}})
check(Auto.mapTrend(state, 50).lost == 1 and state.aggressors[2], "live delta processing still records loss and aggression after the runtime observer is installed")
local inspected = controller.InspectTile(40, 40)
check(inspected and inspected.owner == 1 and inspected.controlledBy == "player", "runtime exposes exact tile ownership through the map inspector")
check(controller.InspectTile(-1, 40) == nil and controller.InspectTile("invalid", 40) == nil, "map inspector rejects invalid coordinates")
controller.OpenMap()
check(findButton("SPRAWDZ POLE") and findButton("POKAZ OSTATNI WYBUCH"), "map inspector opens with tile and blast controls")
findButton("POKAZ OSTATNI WYBUCH").Activated:Fire()
findButton("ZAMKNIJ MAPE").Activated:Fire()
check(controller.Alive, "map popup can be queried and closed while the bot is running")
local beforeCounter = #sent
local remoteTile = 70 * w + 80
state:apply_delta({t = 1202, tiles = {remoteTile * 1024 + 2}, ev = {{0, 2, "Attacker", 0, 2, 0}}})
for _ = 1, 4 do local success, err = coroutine.resume(scheduled[3]); assert(success, tostring(err)) end
local counterSent = false
for i = beforeCounter + 1, #sent do
    if sent[i][1] == Protocol.OP.INTENT then
        local it = Protocol.decode_intent(sent[i][2]); if it and it.type == "attack" and it.tile == remoteTile then counterSent = true end
    end
end
check(counterSent and controller.LastError == nil, "runtime validation permits the legitimate counter cancellation without a shared frontier")
controller.OpenMap(); findButton("ZAMKNIJ MAPE").Activated:Fire()
check(controller.Enabled, "counter handling keeps the bot running and the map usable")
local recovery = controller.Session.state.combatMemory.offensiveRecovery
check(recovery and recovery.untilTick > controller.Session.state.tick, "runtime commits offensive recovery after sending an expensive counter")
local hasRecoveryEvent = false
for _, row in ipairs(controller.Log.entries) do if row.kind == "offense_recovery" then hasRecoveryEvent = true end end
check(hasRecoveryEvent, "runtime records the recovery decision in the diagnostic log")
check(controller.Session.state.combatMemory.strategy and controller.Session.state.combatMemory.strategy.wars[0],
    "runtime commits ordinary expansion to its strategy ledger")
Auto.strategyOutcome(controller.Session.state,"land",0.75,{test="controlled outcome"})
for _=1,2 do local success,err=coroutine.resume(scheduled[3]); assert(success,tostring(err)) end
local strategyLogged=false
for _,event in ipairs(controller.Log.entries) do if event.kind=="strategy_outcome" then strategyLogged=true end end
check(strategyLogged and controller.LearningProfile.strategies.land.samples>=1,"runtime logs and retains strategic calibration outcomes")
local report = controller.ExportLog()
check(report:find("RoWorldBot v", 1, true), "runtime exports logs with the correct version")
check(controller.Log.entries[#controller.Log.entries].data.offensiveRecovery ~= nil, "export retains the current offensive recovery deadline")
controller.Config.LogExportEntries = 2
local shortReport, fullReport = controller.ExportLog(), controller.ExportLog(true)
local function lineCount(text) local n = 1; for _ in text:gmatch("\n") do n += 1 end; return n end
check(lineCount(fullReport) > lineCount(shortReport), "full retained export includes history beyond the usual latest-entry limit")
check(controller.Log.entries[#controller.Log.entries].data.scope == "retained_history", "full export identifies its retained-history scope")
findButton("WYPOSAZENIE / USTAWIENIA").Activated:Fire()
check(findButton("UCZENIE: ON") and findButton("RESET PAMIECI UCZENIA"), "learning controls are accessible in the equipment settings")
check(controller.Session.state.learningProfile == controller.LearningProfile, "runtime binds the shared learning profile to the current map state")
findButton("ODBUDOWA PO KONTRACH:").Activated:Fire()
check(not controller.Config.AutoCounterRecovery and controller.Config.AutoCounter and not controller.Session.state.combatMemory.offensiveRecovery,
    "settings can disable and clear recovery without disabling defensive counters")
findButton("ODBUDOWA PO KONTRACH:").Activated:Fire()
check(controller.Config.AutoCounterRecovery, "settings can restore automatic recovery")
findButton("STRATEGIA:").Activated:Fire()
check(not controller.Config.StrategicPlanning and controller.Config.AutoCounter,"strategy can be disabled without removing defensive counters")
findButton("STRATEGIA:").Activated:Fire()
check(controller.Config.StrategicPlanning,"strategy can be restored during the same session")
findButton("UCZENIE:").Activated:Fire()
check(not controller.Config.AdaptiveLearning and controller.Session.state.learningProfile == nil, "learning OFF removes adaptive influence from the active state")
findButton("UCZENIE:").Activated:Fire()
check(controller.Config.AdaptiveLearning and controller.Session.state.learningProfile == controller.LearningProfile, "learning ON restores the profile without restarting the bot")
controller.LearningProfile.frontMultiplier = 3
findButton("RESET PAMIECI UCZENIA").Activated:Fire()
check(controller.LearningProfile.frontMultiplier == 1 and globals.RoWorldLearningProfile.frontMultiplier == 1, "reset clears both the current calibration and the reinjection profile")
local persisted, scope = controller.SaveLearning(true)
check(not persisted and scope == "session_only", "missing executor file access has an explicit session-only fallback")
local writtenPath, writtenData
mocks.writefile = function(path, data) writtenPath, writtenData = path, data end
check(controller.SaveLearning(true) and writtenPath == "RoWorldLearning_v1.json" and writtenData == "{}", "available file writer receives only the bounded JSON learning profile")
mocks.writefile = function() error("test disk failure") end
check(not controller.SaveLearning(true) and controller.Alive and controller.Log.entries[#controller.Log.entries].kind == "learning_save_error", "profile write failure is logged without stopping gameplay")
mocks.writefile = nil
controller.ExportLog(true)
check(controller.Log.entries[#controller.Log.entries].data.learning.frontMultiplier == 1, "export contains the learning profile for later diagnosis")
controller.Stop()
check(not controller.Alive and not controller.Enabled, "Stop shuts down the complete runtime and its listeners")
globals.RoWorldAuto, globals.RoWorldLearningProfile = nil, nil
mocks.readfile = function(path) assert(path == "RoWorldLearning_v1.json"); return "saved-profile" end
services.HttpService.JSONDecode = function(_, data) assert(data == "saved-profile"); return {schema = 1, frontMultiplier = 2.5, commandLagTicks = 24} end
local loadedOK, loadedController = pcall(boot)
check(loadedOK and loadedController.LearningProfile.frontMultiplier == 2.5 and loadedController.LearningProfile.commandLagTicks == 24, "fresh runtime can load a validated profile through optional file access")
loadedController.Stop()
globals.RoWorldAuto, globals.RoWorldLearningProfile = nil, nil
mocks.readfile = function() error("test missing or corrupt file") end
local fallbackOK, fallbackController = pcall(boot)
check(fallbackOK and fallbackController.LearningProfile.frontMultiplier == 1, "unreadable profile file falls back to default calibration without blocking startup")
fallbackController.Stop()
print("TOTAL CLIENT RUNTIME CHECKS", checks)



