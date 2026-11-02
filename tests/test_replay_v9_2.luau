local Auto=require("./_generated/bot_module/RoWorldAuto")
local checks=0
local function check(ok,text)assert(ok,text);checks+=1;print("PASS",text)end
local w,h=120,80;local bytes=buffer.create(w*h);buffer.fill(bytes,0,32)
for y=15,64 do for x=8,44 do buffer.writeu8(bytes,y*w+x,128)end end
for y=15,64 do for x=70,110 do buffer.writeu8(bytes,y*w+x,128)end end
local map=Auto.mapFromBytes(bytes,{id="Wyspy testowe",width=w,height=h,k_lin=1},w,h)
local owner=buffer.create(w*h*4)
for y=15,64 do for x=8,44 do buffer.writei32(owner,(y*w+x)*4,1)end end
for y=15,64 do for x=70,110 do buffer.writei32(owner,(y*w+x)*4,2)end end
local s=Auto.rawState({map_id=map.id,t=0,phase=1,playing_since=-500,owner=owner,flags=buffer.create(w*h),owners={
 {1,"Nasza flota",0xf7b661ff,2,0,true,1850,80000,1500000,120000,0,0,40*w+24},
 {2,"Sasiad",0x6db8deff,2,0,true,2050,45000,700000,110000,0,0,40*w+88}}},map,1)
s.equipment=Auto.newEquipment();Auto.applyInventory(s.equipment,{unlocks={"railgun","reinforce"}})
s.structures[10]={sid=10,kind=0,owner=1,tile=35*w+25,level=2,active_tick=0,shots={}}
s.structures[20]={sid=20,kind=4,owner=2,tile=35*w+83,level=1,active_tick=0,shots={}}
local cfg=Auto.settings();local rec=Auto.newReplay(s,cfg,"Demo_wyspy")
check(#rec.pending==2 and rec.pending[1].type=="header" and rec.pending[2].type=="keyframe","recording begins with geography and a complete world keyframe")
check(#rec.pending[1].terrainRLE<map.N,"geography uses lossless runs rather than one JSON value per map cell")
local rle=Auto.replayRLE(s.owner,4);local total=0;for i=2,#rle,2 do total+=rle[i]end
check(total==s.N,"ownership RLE covers the complete map")
local memory={armyText="Oszczedzam rezerwe; planuje desant",navalText="Transport omija zasieg wrogiego SAM",considered={},
 analysis={reserve=42000,totalIncoming=0,strategy={landBudget=16000,seaBudget=12000,alerts={{enemy=2,ratio=1.6,forecast=128000,horizonTicks=200}},assets={}}}}
Auto.consider(memory,"land_target",{target=2,allowed=false,reason="brak granicy ladowej"})
Auto.consider(memory,"purchase",{kind="railgun",cost=2500000,gold=1500000,utility=2.4})
local intent={type="boat",tile=40*w+70,ratio=.15}
check(Auto.replayPlan(rec,s,cfg,memory,intent,"Desant na wschodnia wyspe","boat",true),"recording stores actual model budgets, considered options and the proposed action")
Auto.replayPush(rec,{type="action",tick=0,intent=intent,reason="Wyslano transport z 12000 wojska"})
local function delta(d)Auto.replayDelta(rec,d);s:apply_delta(d)end
delta({t=20,ev={{9,1,0,1,{40*w+45,40*w+50,40*w+60,40*w+69},20,100,12000,0,0,0,0}}})
check(rec.pending[#rec.pending].type=="delta" and rec.pending[#rec.pending].ev[1][1]==9,"raw game events are retained for ship playback")
delta({t=40,tiles={(40*w+70)*1024+1,(40*w+71)*1024+1},ev={{11,1,0},{14,7,1,2,11000,40*w+70,false},{4,30,3,2,40*w+76},{23,30,1,60}}})
s.tick=40;memory.armyText="Fort blokuje dojscie do miasta";memory.analysis.strategy.assets={[2]={target=2,kind=0,tile=35*w+83,entry=40*w+71,distance=15,value=6,contested=true}}
memory.weaponText="Railgun celuje w fort przy natarciu";memory.considered={}
Auto.consider(memory,"attack_cost",{target=2,amount=14000,goal=80,expectedSeconds=8,modeledLosses=4500,protected=true})
Auto.replayPlan(rec,s,cfg,memory,{type="nuke",kind="slug",tile=40*w+76},"Usuwam fort z drogi natarcia","strike",true)
Auto.replayPush(rec,{type="action",tick=40,intent={type="nuke",kind="slug",tile=40*w+76},reason="Railgun: fort na froncie"})
delta({t=60,ev={{12,11,7,1,35*w+25,40*w+76,60,20},{9,2,2,2,{20*w+68,20*w+60},60,100,0,1000,1000,0,0}}})
delta({t=80,flags={(40*w+76)*256+1},ev={{13,11,7,40*w+76,5,1},{6,30},{19,-1,0,"Fort zniszczony. <img src=x onerror=alert(1)>"}}})
Auto.replayKeyframe(rec,s,"periodic")
check(rec.pending[#rec.pending].structures[1] and rec.pending[#rec.pending].tick==80,"later keyframes preserve the current structures for backward seeking")
Auto.replayPlan(rec,s,cfg,memory,nil,nil,nil,true)
check(not Auto.replayPlan(rec,s,cfg,memory,nil,nil,nil,true),"idle plan snapshots are throttled rather than recorded every frame")
delta({t=120,stats={1,0,70000,1250000,120000,0},ev={{5,20,1},{15,7},{25,2,650,1000}}})
memory.armyText="Przyczolek zabezpieczony; odbudowuje armie";memory.weaponText="Railgun przeladowuje";memory.analysis.strategy.alerts={}
Auto.replayPlan(rec,s,cfg,memory,nil,"Odbudowa po desancie",nil,true)
Auto.replayKeyframe(rec,s,"periodic")
delta({t=200,ev={{2,2,0}}})
Auto.replayPush(rec,{type="end",tick=200,reason="demo_complete"})
local clean=Auto.replayValue({bad=0/0,huge=math.huge,nested={a=1}})
check(clean.bad=="non-finite" and clean.huge=="non-finite" and clean.nested.a==1,"non-finite model values cannot create invalid JSON")
local before=#rec.pending;rec.closed=true
check(not Auto.replayPush(rec,{type="plan",tick=201}) and #rec.pending==before,"closed recordings cannot silently collect further state")
rec.closed=false
local limited=Auto.newReplay(s,Auto.settings({ReplayMaxPending=2}),"limited")
check(not Auto.replayPush(limited,{type="delta",tick=201}) and limited.truncated and limited.pending[#limited.pending].type=="gap",
 "memory ceiling stops recording explicitly without discarding the beginning")
for i=1,100 do Auto.consider(memory,"many",{index=i})end
check(#memory.considered==80,"recorded candidate details are bounded")
local function encode(v)
 local kind=type(v)
 if kind=="nil" then return "null" elseif kind=="boolean" then return tostring(v) elseif kind=="number" then return tostring(v)
 elseif kind=="string" then return '"'..v:gsub('[%z\1-\31\\"]',function(c)
  if c=='"' then return '\\"' elseif c=='\\' then return '\\\\' elseif c=='\n' then return '\\n' elseif c=='\r' then return '\\r' elseif c=='\t' then return '\\t' end
  return string.format('\\u%04x',string.byte(c))end)..'"'
 elseif kind=="table" then
  local n,count,array=#v,0,true
  for k in pairs(v)do count+=1;if type(k)~="number" or k<1 or k>n or k%1~=0 then array=false end end
  array=array and count==n
  local rows={};if array then for i=1,n do table.insert(rows,encode(v[i]))end
  else for k,child in pairs(v)do table.insert(rows,encode(tostring(k))..":"..encode(child))end end
  return (if array then "[" else "{")..table.concat(rows,",")..(if array then "]" else "}")
 end
 error("unexpected value")
end
local data=Auto.replayLines(rec,encode)
check(data:sub(-1)=="\n" and data:find('"type":"segment"',1,true),"disk segments have explicit identity and complete JSON Lines boundaries")
print("TOTAL REPLAY V9.2 CHECKS",checks)
print("DEMO_JSON_BEGIN")
print(data)
print("DEMO_JSON_END")
