local Auto=require("./_generated/bot_module/RoWorldAuto")
local WorldMap=require("../vendor/roworld/src/shared/Core/WorldMap")
local Sim=require("../vendor/roworld/src/shared/Core/Sim")
local map=WorldMap.new(220,160); map.id="strategy-comparison"
buffer.fill(map.tile_bytes,0,128); map:_derive()
print("Porownanie ustawien na oryginalnym symulatorze; 100 tickow, przeciwnik bez nowych rozkazow.")
print("To scenariusz kontrolowany, nie prognoza publicznego meczu ani automatyczny wybor ustawien.")
print("land_share | sea_share | sent_commands | troops_committed | gained_tiles | home_troops | enemy_city_captured")
local checks=0
for _,land in ipairs({0.35,0.55,0.70}) do
 for _,sea in ipairs({0.10,0.18,0.30}) do
    local sim=Sim.new(map,{nations=false,tribes=0,max_humans=2,spawn_ticks=10,seed=90})
    local a,b=sim:add_human("test","Tester"),sim:add_human("enemy","Opponent")
    sim.o_ai[a],sim.o_ai[b],sim.o_spawned[a],sim.o_spawned[b]=0,0,1,1
    sim.phase,sim.tick,sim.playing_since=1,1200,0
    for y=0,map.H-1 do
        for x=0,89 do sim:set_owner(y*map.W+x,a) end
        for x=90,map.W-1 do sim:set_owner(y*map.W+x,b) end
    end
    sim.o_troops[a],sim.o_troops[b],sim.o_gold[a]=850000,170000,500000
    sim.o_spawn_tile[a],sim.o_spawn_tile[b]=90*map.W+50,90*map.W+120
    local city=sim:add_struct(0,a,90*map.W+40); city.level,city.active,city.active_tick=2,true,0
    local factory=sim:add_struct(2,a,70*map.W+60); factory.active,factory.active_tick=true,0
    local target=sim:add_struct(0,b,90*map.W+105); target.active,target.active_tick=true,0
    local raw=Auto.mapFromBytes(map.tile_bytes,{id=map.id,width=map.W,height=map.H,k_lin=1},map.W,map.H)
    local state=Auto.rawState(sim:snapshot(),raw,a); local initial=state.owners[a].tiles
    state.learningProfile=Auto.newLearning()
    local cfg=Auto.settings({LandBudgetShare=land,SeaBudgetShare=sea,AutoBuild=false,AutoBoats=false,
        AutoArsenal=false,AutoNukes=false,AutoWarships=false,AutoDiplomacy=false})
    local memory,commands,spent={},0,0
    for tick=1,100 do
        if tick%10==1 then
            local intent,_,bucket=Auto.decide(state,Auto.scan(state),cfg,memory,tick/10)
            if intent then
                if intent.ratio then spent+=math.floor(state.owners[a].troops*math.clamp(intent.ratio,0.01,1)) end
                sim:submit(a,intent); Auto.commitStrategy(state,intent,bucket,cfg,memory.armyDetails)
                commands+=1; memory[bucket]=tick/10
            end
        end
        state:apply_delta(sim:step())
    end
    assert(commands>0 and state.owners[a].tiles>initial,"scenario failed to execute a real territorial attack")
    assert(state.owners[a].troops>=0,"negative army")
    checks+=2
    print(string.format("%.2f | %.2f | %d | %d | %d | %d | %s",land,sea,commands,spent,
        state.owners[a].tiles-initial,math.floor(state.owners[a].troops),tostring(target.owner==a)))
 end
end
print("TOTAL SIMULATION CHECKS",checks)
