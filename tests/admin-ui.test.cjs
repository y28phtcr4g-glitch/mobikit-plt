const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const html=fs.readFileSync('index.html','utf8');
const script=html.match(/<script>([\s\S]*?)<\/script>/)[1];
new vm.Script(script); // Check the entire store, not only the extracted editor.
const source=script.slice(script.indexOf('let adminEpoch='),script.indexOf('if(CLOUD_MODE){',script.indexOf('let adminEpoch=')));
function harness(rpc){
 const elements=new Map();const el=id=>{if(!elements.has(id))elements.set(id,{value:'',hidden:false,textContent:'',files:[],elements:[],reset(){},append(){},removeAttribute(){}});return elements.get(id)};
 const ctx=vm.createContext({document:{createElement:()=>({}),getElementById:el},URL,crypto:require('node:crypto').webcrypto,CLOUD_MODE:true,cloudClient:{rpc:async name=>({data:await rpc(name)})},cloudAccount:{profileId:'verified-user'},cloudRpc:rpc,PROMO_CONFIG:{},renderPromos(){}});
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
test('unpublished banner is hidden and unsafe URLs are rejected',async()=>{
 const h=harness(async()=>[]);await h.run('cloudLoadBanner()');assert.equal(h.el('promoBanner').hidden,true);
 for(const value of ['javascript:alert(1)','http://example.com','https://user:password@example.com'])assert.equal(h.run(`adminImageUrl(${JSON.stringify(value)})`),'');
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
