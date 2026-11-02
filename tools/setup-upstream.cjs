const fs=require('node:fs'),path=require('node:path'),{execFileSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),dest=path.join(root,'vendor/roworld');
const commit='7919eeba500e473b842e2e11e3c62dee585b39c2',url='https://github.com/lukechatton/roworld.git';
const git=(args,cwd=root)=>execFileSync('git',args,{cwd,stdio:'inherit'});
if(fs.existsSync(dest)){
 const head=execFileSync('git',['rev-parse','HEAD'],{cwd:dest,encoding:'utf8'}).trim();
 if(head!==commit)throw Error('Istniejący vendor/roworld wskazuje inny commit; pozostawiono go bez zmian.');
 console.log('Upstream already pinned at '+commit);process.exit(0);
}
fs.mkdirSync(path.dirname(dest),{recursive:true});
git(['clone','--filter=blob:none','--no-checkout','--depth','1',url,dest]);
git(['sparse-checkout','init','--cone'],dest);git(['sparse-checkout','set','src'],dest);
git(['fetch','--depth','1','origin',commit],dest);git(['checkout','--detach',commit],dest);
console.log('Prepared pinned upstream at '+commit);
