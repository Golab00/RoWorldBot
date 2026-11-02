local Auto = require("./_generated/bot_module/RoWorldAuto")
local checks = 0
local function check(ok, text) assert(ok, text); checks += 1; print("PASS", text) end
local function fixture(ocean)
    local w,h=300,240
    local bytes=buffer.create(w*h); buffer.fill(bytes,0,if ocean then 32 else 128)
    if ocean then
        for y=80,159 do for x=20,99 do buffer.writeu8(bytes,y*w+x,128) end end
        for y=90,139 do for x=180,229 do buffer.writeu8(bytes,y*w+x,128) end end
    end
    local map=Auto.mapFromBytes(bytes,{id="strategy9",width=w,height=h,k_lin=1},w,h)
    local grid=buffer.create(w*h*4)
    for y=100,139 do for x=30,79 do buffer.writei32(grid,(y*w+x)*4,1) end end
    if ocean then for y=80,159 do for x=20,99 do buffer.writei32(grid,(y*w+x)*4,1) end end end
    if not ocean then for y=100,139 do for x=80,139 do buffer.writei32(grid,(y*w+x)*4,2) end end end
    local s=Auto.rawState({map_id="strategy9",t=1200,phase=1,playing_since=0,owner=grid,flags=buffer.create(w*h),
        owners={{1,"Tester",0,2,0,true,2000,800000,5000000,1000000,0,0,120*w+50},
            {2,"Enemy",0,2,0,true,2400,300000,0,800000,0,0,120*w+100}}},map,1)
    s.learningProfile=Auto.newLearning()
    return s
end
local cfg=Auto.settings({AutoBuild=false,AutoNukes=false,AutoWarships=false,AutoDiplomacy=false,AutoArsenal=false})
local s=fixture(); local scan=Auto.scan(s)
local ctx=Auto.strategicContext(s,scan,cfg,Auto.context(s,scan,cfg))
check(ctx.strategy.landBudget+ctx.strategy.seaBudget<=ctx.available and ctx.strategy.homeReserve==ctx.reserve,
    "land and sea budgets share available troops without spending the home reserve twice")
s.owners[2].troops,s.owners[2].max_troops=2100000,2500000
ctx=Auto.strategicContext(s,scan,cfg,Auto.context(s,scan,cfg))
check(#ctx.strategy.alerts==1 and ctx.strategy.alerts[1].horizonTicks==200 and ctx.reserve>=550000,
    "strong neighboring recovery creates a warning and reserve before an incoming attack exists")
local score,why=Auto.allianceScore(s,scan,2,cfg,ctx)
check(score<0 and why:find("ryzyko zdrady"),"an overwhelming neighbor is not automatically treated as a safe alliance")
s.alliances[1*1024+2]=true
ctx=Auto.strategicContext(s,scan,cfg,Auto.context(s,scan,cfg))
check(ctx.strategy.allyReserve>0 and ctx.strategy.alerts[1].allied,"a powerful ally still contributes a betrayal contingency reserve")
s.alliances={}; s.owners[2].troops,s.owners[2].max_troops=300000,800000
local ledger=Auto.strategyLedger(s)
Auto.commitStrategy(s,{type="attack",tile=120*s.W+80,ratio=0.2},"attack",cfg)
local war=ledger.wars[2]
check(war.sent==160000,"only committed ordinary attacks enter the war spending ledger")
Auto.commitStrategy(s,{type="attack",tile=120*s.W+80,ratio=0.2},"counter",cfg)
check(war.sent==160000,"defensive cancellations are not mislabeled as offensive war spending")
s.attacks[7]={aid=7,attacker=1,target=2,troops=20000,anchor_tile=120*s.W+80}
s.tick+=300; Auto.reviewStrategy(s,cfg)
Auto.commitStrategy(s,{type="attack",tile=120*s.W+80,ratio=0.2},"attack",cfg)
s.tick+=300; Auto.reviewStrategy(s,cfg)
check(not Auto.strategyAllowsWar(s,2) and war.costPerTile>1000,"two costly windows without progress pause a war")
local intent,reason=Auto.decide(s,scan,cfg,{},100)
check(intent and intent.type=="retreat" and reason:find("kosztowna"),"the actual decision loop withdraws a failed expedition")
s.tick=war.pauseUntil; Auto.reviewStrategy(s,cfg)
check(Auto.strategyAllowsWar(s,2),"a paused war can be reconsidered after the bounded cooldown")
Auto.recordMapChange(s,120*s.W+80,2,1)
check(war.gained==1 and war.confirmed,"territory credit requires an observed enemy-to-us ownership change")
local learned=Auto.newLearning(s.learningProfile)
check(learned.strategies.land.samples>=2 and learned.strategies.land.utility>=0.7,"strategic calibration survives profile serialization validation")
Auto.strategyOutcome(s,"sea",999,{})
check(s.learningProfile.strategies.sea.utility<=1.3,"outcome calibration remains bounded")
local n=fixture(); n.learningProfile=nil
Auto.strategyOutcome(n,"land",0.7,{})
check(Auto.strategyLedger(n).outcomes[1].learned==false,"learning OFF still records evidence without changing a profile")

s=fixture(); scan=Auto.scan(s)
s.structures[10]={sid=10,owner=2,kind=0,level=3,tile=120*s.W+88,active_tick=0}
s.structures[11]={sid=11,owner=2,kind=3,level=1,tile=125*s.W+90,active_tick=0}
s.structures[12]={sid=12,owner=2,kind=4,level=1,tile=135*s.W+100,active_tick=0}
s.attacks[7]={aid=7,attacker=1,target=2,troops=1000,anchor_tile=120*s.W+80}
s.attacks[8]={aid=8,attacker=3,target=2,troops=40000,anchor_tile=120*s.W+100}
ctx=Auto.strategicContext(s,scan,cfg,Auto.context(s,scan,cfg))
local front=Auto.strategicFront(s,scan,ctx,2)
check(ctx.strategy.assets[2] and ctx.strategy.assets[2].contested and ctx.strategy.assets[2].distance<35 and ctx.strategy.raceUrgent,
    "nearby enemy infrastructure and a competing attacker create a capture opportunity")
check(front.tile==ctx.strategy.assets[2].entry and buffer.readi32(s.owner,front.tile*4)==2,
    "the planned entry actually lies on the enemy side of our border")
intent=Auto.decide(s,scan,cfg,{},100)
check(intent and intent.type=="attack" and intent.ratio*s.owners[1].troops<=ctx.strategy.landBudget+1,
    "contested infrastructure can receive a bounded reinforcement through the real decision loop")
s.equipment=Auto.newEquipment(); Auto.applyInventory(s.equipment,{unlocks={"railgun"}})
s.structures[20]={sid=20,owner=1,kind=8,level=1,tile=115*s.W+50,active_tick=0,shots={}}
s.structures[21]={sid=21,owner=2,kind=8,level=1,tile=190*s.W+240,active_tick=0,shots={}}
local memory={}; local weapons=Auto.settings()
intent=Auto.strikePlan(s,weapons,memory,ctx)
check(intent and intent.kind=="slug" and (intent.tile==s.structures[11].tile or intent.tile==s.structures[12].tile),
    "ready Railgun removes a fort or SAM supporting the front instead of an unrelated remote trophy")
check(memory.arsenalDetails.samInterceptable==false,"front support retains the actual non-interceptable Railgun rules")

local pctx=Auto.context(s,scan,cfg)
s.structures[25]={sid=25,owner=1,kind=0,level=2,tile=100*s.W+40,active_tick=0}
s.structures[26]={sid=26,owner=1,kind=2,level=1,tile=100*s.W+60,active_tick=0}
check(Auto.purchaseUtility(s,cfg,pctx,"city",1000000)>Auto.purchaseUtility(s,cfg,pctx,"sam",3000000,5),
    "an expensive extra SAM for little infrastructure loses to economic growth")
pctx.nuclearThreat=true
check(Auto.purchaseUtility(s,cfg,pctx,"sam",3000000,5)>Auto.purchaseUtility(s,cfg,pctx,"city",1000000),
    "an actual nuclear warning can reverse the purchase comparison")
Auto.commitStrategy(s,{type="build",kind="city",tile=110*s.W+45},"build",cfg,{cost=125000})
s.structures[30]={sid=30,owner=1,kind=0,level=1,tile=110*s.W+45,active_tick=s.tick+20}
Auto.reviewStrategy(s,cfg); s.tick+=621; Auto.reviewStrategy(s,cfg)
check(s.learningProfile.strategies.city and s.learningProfile.strategies.city.samples==1,
    "confirmed economic purchases update a separately labeled survival metric")

local sea=fixture(true); local seaScan=Auto.scan(sea)
sea.attacks[7]={aid=7,attacker=1,target=2,troops=20000,anchor_tile=100*sea.W+80}
local seaCtx=Auto.strategicContext(sea,seaScan,cfg,Auto.context(sea,seaScan,cfg))
local islands=Auto.islandCandidateTiles(sea,seaScan)
check(#islands>0,"connected land indexing discovers a separate neutral island")
intent,reason=Auto.decide(sea,seaScan,cfg,{},100)
check(intent and intent.type=="boat" and intent.ratio*sea.owners[1].troops<=seaCtx.strategy.seaBudget+1,
    "a safe island expedition can coexist with an ongoing land attack within its own budget")
Auto.commitStrategy(sea,intent,"boat",cfg)
check(Auto.strategyLedger(sea).seaSpent>0,"sent expeditions consume the rolling sea allowance")
local samState=fixture(); samState.structures[1]={sid=1,owner=1,kind=4,level=1,tile=120*samState.W+40,active_tick=0}
local samScan=Auto.scan(samState); local samCtx=Auto.context(samState,samScan,cfg)
samCtx.nuclearDefense={needed=true,reserve=3000000,cost=3000000,value=5}
Auto.strategicContext(samState,samScan,cfg,samCtx)
check(not samCtx.nuclearDefense.needed and samCtx.nuclearDefense.reserve==0,"low-value additional SAM releases its excessive savings reservation")
samCtx.nuclearDefense={needed=true,reserve=3000000,cost=3000000,value=5}; samCtx.nuclearThreat=true
Auto.strategicContext(samState,samScan,cfg,samCtx)
check(samCtx.nuclearDefense.needed,"actual incoming nuclear danger bypasses discretionary savings deferral")
local unconfirmed=fixture()
Auto.commitStrategy(unconfirmed,{type="build",kind="city",tile=110*unconfirmed.W+45},"build",cfg,{cost=125000})
unconfirmed.tick+=501; Auto.reviewStrategy(unconfirmed,cfg)
check(not unconfirmed.learningProfile.strategies.city,"unconfirmed purchases do not become fabricated learning failures")
print("TOTAL STRATEGY V9 CHECKS",checks)
