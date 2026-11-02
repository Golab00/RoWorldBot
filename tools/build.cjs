const fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'..'),check=process.argv.includes('--check');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const source=read('src/RoWorldAuto.luau'),demo=read('examples/Przyklad_nagrania.rwr.jsonl').replace(/^\uFEFF/,'');
for(const line of demo.trim().split(/\r?\n/))JSON.parse(line);
const html=read('viewer/viewer.html').replace('/* ENGINE */',()=>read('viewer/engine.js'))
 .replace('/* UI */',()=> 'window.REPLAY_DEMO='+JSON.stringify(demo).replace(/</g,'\\u003c')+';\n'+read('viewer/ui.js'));
for(const [name,data] of [['releases/RoWorldAuto.lua',source],['releases/RoWorldAuto_v9_2.lua',source],['releases/Odtwarzacz_RoWorld.html',html]]){
 const file=path.join(root,name);if(check){if(!fs.existsSync(file)||fs.readFileSync(file,'utf8')!==data)throw Error('Wydanie wymaga przebudowania: '+name);}
 else{fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,data);}
}
console.log(check?'Build is up to date.':'Built bot releases and standalone replay viewer.');
