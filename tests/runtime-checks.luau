-- Appended to the complete mocked client flow, before Stop.
local recorder = controller.Replay
check(recorder and recorder.recording and state.replayWrapped and #recorder.pending > 0,
    "map recorder binds automatically and retains unsaved packets without file access")
check(recorder.error and recorder.error:find("Brak writefile",1,true) and controller.Alive,
    "missing file writer is visible without stopping the bot")
local seenTypes = {}
for _, packet in ipairs(recorder.pending) do seenTypes[packet.type] = true end
check(seenTypes.header and seenTypes.keyframe and seenTypes.delta and seenTypes.plan and seenTypes.action,
    "real decision loop records map snapshots, deltas, plans and sent actions")
controller.SetReplay(false)
local pausedCount = #recorder.pending
state:apply_delta({t=1203})
check(not recorder.recording and #recorder.pending == pausedCount and recorder.pending[pausedCount].type=="gap",
    "recording OFF captures an explicit gap and suspends map capture")
controller.SetReplay(true)
check(recorder.recording and recorder.pending[#recorder.pending].reason=="resume",
    "resume inserts a full current map checkpoint")
local files, encoded = {}, {}
local originalEncode = services.HttpService.JSONEncode
services.HttpService.JSONEncode=function(_,packet) table.insert(encoded,packet); return "{\"type\":\""..tostring(packet.type).."\"}" end
mocks.writefile=function(path,data) files[path]=data end
mocks.isfolder=function() return false end
mocks.makefolder=function(path) assert(path=="RoWorldRecordings") end
recorder.folder=nil
local saved,path=controller.SaveReplay()
check(saved and path:find("RoWorldRecordings/",1,true)==1 and path:find("_0001.rwr.jsonl",1,true)
    and #recorder.pending==0 and encoded[1].type=="segment" and encoded[2].type=="header",
    "first disk part includes manifest, header and pending records and clears only after success")
state:apply_delta({t=1204})
mocks.appendfile=function() error("must preserve original parts mode") end
local savedNext,nextPath=controller.SaveReplay()
check(savedNext and nextPath~=path and nextPath:find("_0002.rwr.jsonl",1,true) and files[path]~=nil,
    "numbered disk parts preserve earlier data and their selected storage format")
state:apply_delta({t=1205})
local retained=#recorder.pending
mocks.writefile=function() error("controlled disk failure") end
check(not controller.SaveReplay() and #recorder.pending==retained and controller.Alive,
    "failed disk write keeps unsaved data and gameplay alive")
mocks.writefile=function(path,data) files[path]=data end
check(controller.SaveReplay() and #recorder.pending==0,"failed save can be retried without losing packets")
controller.CopyReplay()
local previous = recorder
controller.BindReplay(state,{})
recorder=controller.Replay
check(previous.closed and recorder~=previous and recorder.fileMode=="append" and recorder.part==1,
    "new recording closes the previous stream and starts a complete append-format file")
local appendPath=recorder.path
local beforeAppend=files[appendPath]
mocks.appendfile=function(path,data) files[path]=(files[path] or "")..data end
state:apply_delta({t=1206})
check(controller.SaveReplay() and recorder.path==appendPath and #files[appendPath]>#beforeAppend,
    "append-capable writer extends the same replay file")
state:apply_delta({t=1207})
check(controller.SaveReplay(nil,true) and recorder.closed and not recorder.recording,
    "closing flushes the final packets and ends capture")
local closedCount=#recorder.pending
state:apply_delta({t=1208})
check(#recorder.pending==closedCount,"closed recording ignores subsequent live deltas")
mocks.writefile,mocks.appendfile,mocks.isfolder,mocks.makefolder=nil,nil,nil,nil
services.HttpService.JSONEncode=originalEncode
