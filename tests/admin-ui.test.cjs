const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const html=fs.readFileSync('index.html','utf8');
const script=html.match(/<script>([\s\S]*?)<\/script>/)[1];
new vm.Script(script); // Check the entire store, not only the extracted editor.
const source=script.slice(script.indexOf('let adminEpoch='),script.indexOf('if(CLOUD_MODE){',script.indexOf('let adminEpoch=')));
function harness(rpc,storage){
 const elements=new Map();const el=id=>{if(!elements.has(id))elements.set(id,{value:'',hidden:false,textContent:'',files:[],elements:[],reset(){},append(){},removeAttribute(){}});return elements.get(id)};
 const ctx=vm.createContext({document:{createElement:()=>({}),getElementById:el},URL,crypto:require('node:crypto').webcrypto,CLOUD_MODE:true,cloudClient:{storage,rpc:async name=>({data:await rpc(name)})},cloudAccount:{profileId:'verified-user'},cloudRpc:rpc,PROMO_CONFIG:{},renderPromos(){}});
 vm.runInContext(source,ctx);return {ctx,el,run:code=>vm.runInContext(code,ctx)};
}
const row={revision:3,title:'Banner',subtitle:'Text',image_url:'https://example.com/image.jpg',published:true};
test('ordinary users and sellers cannot open editor',async()=>{
 for(const role of [null,'seller']){let calls=[];const h=harness(async name=>{calls.push(name);return role});await h.run('adminLoad()');assert.equal(h.el('adminBannerForm').hidden,true);assert.deepEqual(calls,['mk_admin_role'])}
});
test('owner and administrator load draft with revision',async()=>{
 for(const role of ['owner','administrator']){const h=harness(async name=>name==='mk_admin_role'?role:[row]);await h.run('adminLoad()');assert.equal(h.el('adminTitle').value,'Banner');assert.equal(h.el('adminBannerForm').hidden,false);assert.equal(h.run('adminRevision'),3)}
});
test('reset invalidates in-flight role response',async()=>{
 let resolve;const h=harness(()=>new Promise(r=>resolve=r));const pending=h.run('adminLoad()');h.run('adminReset()');resolve('owner');await pending;assert.equal(h.el('adminBannerForm').hidden,true);assert.equal(h.run('adminRole'),null);
});
test('missing migration fails closed',async()=>{
 const h=harness(async()=>{throw {code:'PGRST202'}});await h.run('adminLoad()');assert.equal(h.el('adminBannerForm').hidden,true);
});
test('draft access failure clears previously loaded role and revision',async()=>{
 const h=harness(async name=>{if(name==='mk_admin_role')return 'owner';throw {code:'42501'}});
 await h.run('adminLoad()');assert.equal(h.run('adminRole'),null);assert.equal(h.run('adminRevision'),null);assert.equal(h.el('adminBannerForm').hidden,true);
});
test('invalid uploads fail before contacting Storage or saving',async()=>{
 for(const file of [{type:'image/svg+xml',size:10},{type:'image/png',size:0},{type:'image/jpeg',size:5242881}]){
  let saves=0;const h=harness(async name=>{if(name==='mk_admin_role')return 'owner';if(name==='mk_admin_banner_get')return [row];saves++});
  await h.run('adminLoad()');h.el('adminFile').files=[file];await h.el('adminBannerForm').onsubmit({preventDefault(){}});
  assert.equal(saves,0);assert.equal(h.run('adminBusy'),false);
 }
});
test('unpublished banner is hidden and unsafe URLs are rejected',async()=>{
 const h=harness(async()=>[]);await h.run('cloudLoadBanner()');assert.equal(h.el('promoBanner').hidden,true);
 for(const value of ['javascript:alert(1)','http://example.com','https://user:password@example.com','https://example.com/a b','https://example.com/a\\b','https://example.com/"x'])assert.equal(h.run(`adminImageUrl(${JSON.stringify(value)})`),'');
});
test('save supplies loaded revision; conflicts retain draft',async()=>{
 let payload;const h=harness(async(name,args)=>{if(name==='mk_admin_role')return 'owner';if(name==='mk_admin_banner_get')return [row];payload=args;throw {code:'40001'}});
 await h.run('adminLoad()');h.el('adminSubtitle').value='Edited';await h.el('adminBannerForm').onsubmit({preventDefault(){}});
 assert.equal(payload.p_revision,3);assert.equal(payload.p_subtitle,'Edited');assert.match(h.el('adminStatus').textContent,/Онови/);assert.equal(h.run('adminBusy'),false);
});
test('access revoked during save closes editor',async()=>{
 const h=harness(async name=>{if(name==='mk_admin_role')return 'administrator';if(name==='mk_admin_banner_get')return [row];throw {code:'42501'}});
 await h.run('adminLoad()');await h.el('adminBannerForm').onsubmit({preventDefault(){}});assert.equal(h.el('adminBannerForm').hidden,true);assert.equal(h.run('adminRole'),null);
});
test('older published response cannot undo a newer hidden banner',async()=>{
 let resolve;let calls=0;const h=harness(()=>++calls===1?new Promise(r=>resolve=r):[]);
 const older=h.run('cloudLoadBanner()');await h.run('cloudLoadBanner()');resolve([row]);await older;
 assert.equal(h.el('promoBanner').hidden,true);
});
test('older request failure cannot hide a newer published banner',async()=>{
 let reject;let calls=0;const h=harness(()=>++calls===1?new Promise((r,j)=>reject=j):[row]);
 const older=h.run('cloudLoadBanner()');await h.run('cloudLoadBanner()');reject(new Error('network'));await older;
 assert.equal(h.el('promoBanner').hidden,false);
});
test('failed save retains uploaded URL and retry does not upload again',async()=>{
 let uploads=0,saves=0;const url='https://example.com/new.webp';
 const storage={from:()=>({upload:async()=>{uploads++;return {}},getPublicUrl:()=>({data:{publicUrl:url}})})};
 const h=harness(async name=>{if(name==='mk_admin_role')return 'owner';if(name==='mk_admin_banner_get')return [row];if(name==='mk_admin_banner_save'){if(++saves===1)throw new Error('network');return 4}return [row]},storage);
 await h.run('adminLoad()');h.el('adminFile').files=[{type:'image/webp',size:10}];
 await h.el('adminBannerForm').onsubmit({preventDefault(){}});
 assert.equal(h.el('adminImage').value,url);assert.equal(h.el('adminFile').value,'');
 h.el('adminFile').files=[];await h.el('adminBannerForm').onsubmit({preventDefault(){}});assert.equal(uploads,1);assert.equal(saves,2);
});
test('Storage authorization failures close editor before banner save',async()=>{
 for(const error of [{statusCode:'403'},{status:401}]){
  let saves=0;const storage={from:()=>({upload:async()=>({error})})};
  const h=harness(async name=>{if(name==='mk_admin_role')return 'owner';if(name==='mk_admin_banner_get')return [row];saves++},storage);
  await h.run('adminLoad()');h.el('adminFile').files=[{type:'image/png',size:10}];await h.el('adminBannerForm').onsubmit({preventDefault(){}});
  assert.equal(saves,0);assert.equal(h.el('adminBannerForm').hidden,true);assert.equal(h.run('adminRevision'),null);assert.match(h.el('adminStatus').textContent,/відкликаний/);
 }
});
test('old upload cannot save or unlock a new session operation',async()=>{
 let finishUpload,finishSave,saves=0;
 const storage={from:()=>({upload:()=>new Promise(r=>finishUpload=r),getPublicUrl:()=>({data:{publicUrl:'https://example.com/old.png'}})})};
 const h=harness(async name=>{if(name==='mk_admin_role')return 'owner';if(name==='mk_admin_banner_get')return [row];if(name==='mk_admin_banner_save'){saves++;return new Promise(r=>finishSave=r)}return []},storage);
 const control={disabled:false};h.el('adminBannerForm').elements=[control];
 await h.run('adminLoad()');h.el('adminFile').files=[{type:'image/png',size:10}];const old=h.el('adminBannerForm').onsubmit({preventDefault(){}});
 h.run("adminReset();cloudAccount={profileId:'new-user'}");assert.equal(control.disabled,false);assert.equal(h.run('adminBusy'),false);
 h.el('adminFile').files=[];await h.run('adminLoad()');const current=h.el('adminBannerForm').onsubmit({preventDefault(){}});
 finishUpload({});await old;assert.equal(saves,1);assert.equal(h.run('adminBusy'),true);assert.equal(control.disabled,true);assert.equal(h.el('adminImage').value,row.image_url);
 finishSave(4);await current;assert.equal(h.run('adminBusy'),false);assert.equal(control.disabled,false);
});
test('closing and reopening editor retains unsaved text',async()=>{
 let calls=0;const h=harness(async name=>{calls++;return name==='mk_admin_role'?'owner':[row]});
 await h.run('adminLoad()');h.el('adminTitle').value='Unsaved title';h.el('adminDetails').open=true;h.el('adminDetails').ontoggle();
 assert.equal(calls,2);assert.equal(h.el('adminTitle').value,'Unsaved title');
});
