(function(root){
'use strict';
const LIMIT=8000000;
function rle(runs,n,Type=Uint16Array){
 if(!Array.isArray(runs)||runs.length%2)throw Error('Nieprawidłowe RLE mapy');
 const out=new Type(n);let p=0;
 for(let i=0;i<runs.length;i+=2){const v=runs[i],c=runs[i+1];if(!Number.isInteger(v)||v<0||v>65535||!Number.isInteger(c)||c<1||p+c>n)throw Error('Nieprawidłowy rozmiar mapy');out.fill(v,p,p+c);p+=c;}
 if(p!==n)throw Error('Niepełna migawka mapy');return out;
}
function list(x){return Array.isArray(x)?x:[];}
function dictionary(rows,key){return new Map(list(rows).filter(r=>r&&Number.isInteger(r[key])).map(r=>[r[key],{...r}]));}
class Replay{
 constructor(texts){
  const all=[],ids=new Set();this.warnings=[];
  for(const text of texts){if(text.length>160000000)throw Error('Plik przekracza 160 MB. Wczytaj mniejsze części nagrania.');const lines=text.replace(/^\uFEFF/,'').split(/\r?\n/);
   for(let i=0;i<lines.length;i++){if(!lines[i].trim())continue;let p;try{p=JSON.parse(lines[i]);}catch(e){if(lines.slice(i+1).every(l=>!l.trim())){this.warnings.push('Pominięto niedokończony ostatni rekord.');continue;}throw Error('Uszkodzony rekord '+(i+1));}
    if(p.type==='segment'){if(p.id)ids.add(p.id);continue;}if(p.type==='header'&&p.id)ids.add(p.id);all.push(p);if(all.length>300000)throw Error('Za dużo rekordów w nagraniu.');
   }
  }
  if(ids.size>1)throw Error('Wybrano kilka różnych rund. Wczytaj części tylko jednego nagrania.');
  this.header=all.find(p=>p.type==='header');const h=this.header;
  if(!h)throw Error('Brak początku nagrania mapy. Zwykły log bota nie zawiera pełnej siatki; wczytaj .rwr.jsonl od v9.2, razem z pierwszą częścią.');
  if(h.schema!==1||!Number.isInteger(h.width)||!Number.isInteger(h.height)||h.width<1||h.height<1||h.width*h.height>LIMIT)throw Error('Nieobsługiwany format lub rozmiar mapy.');
  this.n=h.width*h.height;this.terrain=rle(h.terrainRLE,this.n,Uint8Array);
  const unique=new Map();for(const p of all){if(!p||!Number.isInteger(p.seq)||!Number.isFinite(p.tick))continue;if(!unique.has(p.seq))unique.set(p.seq,p);}
  this.packets=[...unique.values()].sort((a,b)=>a.seq-b.seq);this.keyframes=[];this.actions=[];this.plans=[];this.gaps=[];
  let last=-Infinity;
  for(let i=0;i<this.packets.length;i++){let p=this.packets[i];if(p.tick<last)throw Error('Niespójna kolejność czasu w nagraniu.');last=p.tick;if(p.type==='keyframe')this.keyframes.push({tick:p.tick,index:i});if(p.type==='action')this.actions.push(p);if(p.type==='plan')this.plans.push(p);if(p.type==='gap')this.gaps.push(p);}
  if(!this.keyframes.length)throw Error('Brak migawki stanu świata.');
  this.firstTick=this.keyframes[0].tick;this.lastTick=this.packets.reduce((v,p)=>Math.max(v,p.tick),this.firstTick);
  for(let i=1;i<this.packets.length;i++)if(this.packets[i].seq>this.packets[i-1].seq+1){this.warnings.push('Brak części rekordów; odtwarzacz użyje dostępnych migawek.');break;}
  this.version=0;this.seek(this.firstTick);
 }
 reset(p){this.owner=rle(p.ownerRLE,this.n);this.flags=rle(p.flagsRLE,this.n,Uint8Array);this.owners=dictionary(p.owners,'id');this.structures=dictionary(p.structures,'sid');this.units=dictionary(p.units,'uid');this.attacks=dictionary(p.attacks,'aid');this.nukes=dictionary(p.nukes,'uid');this.phase=p.phase;this.plan=p.plan||null;this.action=null;this.messages=list(p.messages);this.booms=list(p.booms);this.version++;}
 apply(p){
  if(p.type==='keyframe'){this.reset(p);return;}
  if(p.type==='plan'){this.plan=p;return;}if(p.type==='action'){this.action=p;return;}
  if(p.type==='gap'){this.messages.push({tick:p.tick,text:'PRZERWA W NAGRANIU: '+p.reason});return;}
  if(p.type!=='delta')return;
  for(const packed of list(p.tiles)){const t=Math.floor(packed/1024),id=packed%1024;if(!Number.isSafeInteger(packed)||t<0||t>=this.n||id<0)continue;const old=this.owner[t];if(old!==id){const a=this.owners.get(old),b=this.owners.get(id);if(a)a.tiles=Math.max(0,(a.tiles||0)-1);if(b)b.tiles=(b.tiles||0)+1;this.owner[t]=id;}}
  for(const packed of list(p.flags)){const t=Math.floor(packed/256);if(Number.isSafeInteger(packed)&&t>=0&&t<this.n)this.flags[t]=packed%256;}
  const stats=list(p.stats);for(let i=0;i+5<stats.length;i+=6){const o=this.owners.get(stats[i]);if(o){o.troops=stats[i+2];o.gold=stats[i+3];o.max_troops=stats[i+4];}}
  for(const e of list(p.ev)){if(!Array.isArray(e))continue;const k=e[0],id=e[1],b=this.structures.get(id),u=this.units.get(id),o=this.owners.get(id);
   if(k===0)this.owners.set(id,{...(o||{}),id,name:e[2],rgba:e[3],kind:e[4],team:e[5],alive:true});
   else if(k===1&&o)o.alive=false;else if(k===2)this.phase=id;else if(k===3&&o){o.spawned=true;o.spawn_tile=e[2];}
   else if(k===4)this.structures.set(id,{sid:id,kind:e[2],owner:e[3],tile:e[4],level:1,active_tick:p.tick});
   else if(k===5&&b)b.owner=e[2];else if(k===6)this.structures.delete(id);
   else if(k===9)this.units.set(id,{uid:id,kind:e[2],owner:e[3],path:list(e[4]),start_tick:e[5]??p.tick,ticks_per_tile_x100:e[6]||100,troops:e[7]||0,hp:e[8]||0,max_hp:e[9]||0,state:e[11]||0,prev_tile:-1,move_tick:p.tick});
   else if(k===10&&u){u.prev_tile=u.path[0]??-1;u.path=[e[2]];u.move_tick=p.tick;}
   else if(k===11)this.units.delete(id);
   else if(k===12)this.nukes.set(id,{uid:id,kind:e[2],owner:e[3],from_tile:e[4],to_tile:e[5],launch_tick:e[6],flight_ticks:e[7]});
   else if(k===13){this.nukes.delete(id);this.booms.push({tick:p.tick,tile:e[3],radius:Math.max(0,e[4]),owner:e[5],kind:e[2]});}
   else if(k===14)this.attacks.set(id,{aid:id,attacker:e[2],target:e[3],troops:e[4],anchor_tile:e[5],retreating:e[6]===true});
   else if(k===15)this.attacks.delete(id);
   else if(k===19&&(id===-1||id===this.header.localOwner))this.messages.push({tick:p.tick,text:String(e[3]??'')});
   else if(k===20)this.phase=2;else if(k===23&&b){b.level=e[2];b.active_tick=e[3];}
   else if(k===25&&u){u.hp=e[2];u.max_hp=e[3];}else if(k===27&&u)u.state=e[2];
   else if(k===28&&u){u.path=list(e[2]);u.start_tick=e[3];u.ticks_per_tile_x100=e[4];u.prev_tile=-1;}
   else if(k===32&&b)b.shots=list(e[2]);
  }
  this.messages=this.messages.slice(-30);this.booms=this.booms.filter(b=>p.tick-b.tick<100).slice(-30);this.version++;
 }
 seek(tick){tick=Math.max(this.firstTick,Math.min(this.lastTick,Math.floor(tick)));let k=this.keyframes[0];for(const row of this.keyframes){if(row.tick>tick)break;k=row;}
  if(this.index==null||tick<this.tick||k.index>this.index){this.reset(this.packets[k.index]);this.index=k.index+1;}
  while(this.index<this.packets.length&&this.packets[this.index].tick<=tick)this.apply(this.packets[this.index++]);
  this.tick=tick;
  // A keyframe may replace a plan; choose the latest explicit record at this tick.
  let p=null;for(const row of this.plans){if(row.tick>tick)break;p=row;}this.plan=p||this.plan;
  let a=null;for(const row of this.actions){if(row.tick>tick)break;a=row;}this.action=a;
  return this;
 }
 position(u,tick=this.tick){const path=list(u.path);if(!path.length)return null;const w=this.header.width;
  if(u.kind===2&&u.prev_tile>=0){const f=Math.max(0,Math.min(1,(tick-(u.move_tick||tick))/10));return[(u.prev_tile%w+(path[0]%w-u.prev_tile%w)*f+.5),(Math.floor(u.prev_tile/w)+(Math.floor(path[0]/w)-Math.floor(u.prev_tile/w))*f+.5)];}
  const done=Math.max(0,(tick-(u.start_tick??tick))*100/Math.max(1,u.ticks_per_tile_x100||100)),i=Math.min(Math.floor(done),path.length-1),a=path[i],b=path[Math.min(i+1,path.length-1)],f=i===path.length-1?0:done%1;
  return[a%w+(b%w-a%w)*f+.5,Math.floor(a/w)+(Math.floor(b/w)-Math.floor(a/w))*f+.5];
 }
}
root.RoWorldReplay={Replay,rle};if(typeof module!=='undefined')module.exports=root.RoWorldReplay;
})(globalThis);
