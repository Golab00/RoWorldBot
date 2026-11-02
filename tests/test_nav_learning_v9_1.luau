local Auto=require("./_generated/bot_module/RoWorldAuto")
local checks=0
local function check(ok,text) assert(ok,text); checks+=1; print("PASS",text) end
local w,h=300,200
local bytes=buffer.create(w*h); buffer.fill(bytes,0,32)
for y=40,139 do for x=20,99 do buffer.writeu8(bytes,y*w+x,128) end end
for y=70,119 do for x=180,229 do buffer.writeu8(bytes,y*w+x,128) end end
local map=Auto.mapFromBytes(bytes,{id="nav91",width=w,height=h,k_lin=1.25},w,h)
local grid=buffer.create(w*h*4)
for y=40,139 do for x=20,99 do buffer.writei32(grid,(y*w+x)*4,1) end end
local s=Auto.rawState({map_id="nav91",t=2919,phase=1,playing_since=0,owner=grid,flags=buffer.create(w*h),
    owners={{1,"Tester",0,2,0,true,8000,3000000,0,4000000,0,0,90*w+50}}},map,1)
s.learningProfile=Auto.newLearning()
local cfg=Auto.settings(); local scan=Auto.scan(s); local tiles=Auto.islandCandidateTiles(s,scan)
local tile=tiles[1]; assert(tile)
Auto.commitStrategy(s,{type="attack",tile=tile,ratio=0.01},"attack",cfg)
Auto.commitStrategy(s,{type="boat",tile=tile,ratio=0.15},"boat",cfg,{}, {pathLength=195})
local ledger=Auto.strategyLedger(s); local op=ledger.seaOps[1]
check(ledger.wars[0].mode=="land" and ledger.wars[0].sent==30000,"boat spending no longer contaminates the neutral-land war ledger")
check(op.amount==450000 and op.evaluateAfter==3463,"sea review starts after route ETA plus a separate 300-tick result window")
s.tick=3036; Auto.reviewStrategy(s,cfg)
check(not s.learningProfile.strategies.sea and #ledger.seaOps==1,"logged premature review tick does not penalize a transport still traveling")
check(#Auto.islandCandidateTiles(s,scan)==0,"pending landing reserves its island against duplicate transport orders")
s.tick=3089; Auto.recordMapChange(s,tile,0,1)
check(op.gained==1 and op.confirmed and ledger.wars[0].gained==0,"island gains are credited to the landing rather than the neutral land campaign")
Auto.recordMapChange(s,41*w+21,0,1)
check(ledger.wars[0].gained==1 and op.gained==1,"mainland gains do not improve the landing score")
s.tick=op.evaluateAfter; s.units[1]={uid=1,kind=0,owner=1,path={tile}}
Auto.reviewStrategy(s,cfg)
check(#ledger.seaOps==1 and not s.learningProfile.strategies.sea,"a still-observed transport postpones evaluation beyond the estimate")
s.units={}; s.tick+=1; Auto.reviewStrategy(s,cfg)
check(#ledger.seaOps==0 and s.learningProfile.strategies.sea.samples==1,"a confirmed completed expedition is evaluated exactly once")
local samples=s.learningProfile.strategies.sea.samples
Auto.commitStrategy(s,{type="boat",tile=tile+1,ratio=0.01},"boat",cfg,{}, {pathLength=1})
s.tick+=1000; Auto.reviewStrategy(s,cfg)
check(s.learningProfile.strategies.sea.samples==samples,"an unconfirmed transport does not fabricate another learning failure")
local old=Auto.newLearning({schema=1,frontMultiplier=2.5,strategies={sea={utility=.75,samples=24},land={utility=.8,samples=10},sam={utility=1.1,samples=8}}})
check(old.strategySchema==2 and not old.strategies.sea and not old.strategies.land and old.strategies.sam.samples==8 and old.frontMultiplier==2.5,
    "migration clears only tainted campaign scores and preserves construction and purchase experience")
check(Auto.newLearning(s.learningProfile).strategies.sea.samples==samples,"new-format campaign learning survives validated reload")
check(Auto.neutralLandingArea(s,tile+1,3000)==2500,"landing area counts connected free island cells instead of the entire continent")
print("TOTAL NAV LEARNING V9.1 CHECKS",checks)
