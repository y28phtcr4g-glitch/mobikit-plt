// Optional: requires Playwright and its Chromium browser in the local environment.
const {chromium}=require('playwright');
const fs=require('node:fs');
const assert=require('node:assert/strict');
const html=fs.readFileSync('index.html','utf8');
const mock=`export function createClient(){return {
 auth:{getSession:async()=>({data:{session:{}}}),getUser:async()=>({data:{user:{id:'qa-user',email:'qa@example.invalid'}}}),onAuthStateChange(){window.qaReady=true},signOut:async()=>({})},
 from(){return {select(){return this},eq(){return this},maybeSingle:async()=>({data:{name:'QA User'}})}},
 storage:{from:()=>({upload:async(path,file,options)=>{const result=await(await fetch('/qa-storage',{method:'POST',body:JSON.stringify({path,type:file.type,size:file.size,options})})).json();window.qaUploadFinished=true;return result},getPublicUrl:path=>({data:{publicUrl:'https://example.invalid/'+path}})})},
 rpc:async(name,args)=>{const result=await(await fetch('/qa-rpc',{method:'POST',body:JSON.stringify({name,args})})).json();if(name==='mk_admin_banner_save')window.qaSave=args;return result}
}}`;
function backend(role='owner'){
 return {role,banner:{title:'QA Banner',subtitle:'Draft',image_url:'https://example.invalid/banner.jpg',published:false,revision:4},saves:0,uploads:[]};
}
async function openEditor(browser,state,width=390){
 const page=await browser.newPage({viewport:{width,height:844}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/*',async route=>{
  const url=route.request().url();
  if(url==='https://mobikit.test/qa-storage'){
   state.uploads.push(JSON.parse(route.request().postData()));if(state.uploadGate)await state.uploadGate;
   return route.fulfill({contentType:'application/json',body:JSON.stringify(['owner','administrator'].includes(state.role)?{}:{error:{statusCode:'403'}})});
  }
  if(url==='https://mobikit.test/qa-rpc'){
   const {name,args}=JSON.parse(route.request().postData());let result={data:[]};if(name==='mk_storefront')result={data:{items:[],promotions:[]}};
   if(name==='mk_admin_role')result={data:state.role};
   if(name==='mk_weekly_banner')result={data:state.banner.published?[state.banner]:[]};
   if(name==='mk_admin_banner_get'||name==='mk_admin_banner_save'){
    if(!['owner','administrator'].includes(state.role))result={error:{code:'42501',message:'Not authorized'}};
    else if(name==='mk_admin_banner_get')result={data:[state.banner]};
    else if(state.failNextSave){state.failNextSave=false;result={error:{code:'500',message:'Temporary failure'}}}
    else if(args.p_revision!==state.banner.revision)result={error:{code:'40001',message:'Conflict'}};
    else{state.banner={title:args.p_title,subtitle:args.p_subtitle,image_url:args.p_image_url,published:args.p_published,revision:state.banner.revision+1};state.saves++;result={data:state.banner.revision}}
   }
   return route.fulfill({contentType:'application/json',body:JSON.stringify(result)});
  }
  if(url.startsWith('https://mobikit.test/'))return route.fulfill({contentType:'text/html',body:html});
  if(url.startsWith('https://esm.sh/'))return route.fulfill({contentType:'application/javascript',body:mock,headers:{'access-control-allow-origin':'*'}});
  return route.abort();
 });
 await page.goto('https://mobikit.test/?cloud=1#account');
 await page.waitForFunction(()=>window.qaReady);
 await page.locator('#adminDetails summary').click();
 await page.waitForFunction(()=>!document.getElementById('adminStatus').textContent.includes('Перевіряємо'));
 return {page,errors};
}
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.MOBIKIT_BROWSER_PATH?{executablePath:process.env.MOBIKIT_BROWSER_PATH}:{})});
 try{
  for(const width of [320,390,768,1440])for(const role of ['owner','administrator','seller',null]){
   const state=backend(role);const {page,errors}=await openEditor(browser,state,width);
   if(['owner','administrator'].includes(role)){
    await page.locator('#adminBannerForm').waitFor({state:'visible'});
    await page.locator('#adminTitle').fill('Updated');await page.locator('#adminBannerForm button[type=submit]').click();
    await page.waitForFunction(()=>window.qaSave);
    assert.equal(await page.evaluate(()=>window.qaSave.p_revision),4);
    assert.equal(await page.evaluate(()=>window.qaSave.p_title),'Updated');
   }else assert.equal(await page.locator('#adminBannerForm').isVisible(),false);
   if(['owner','administrator'].includes(role)){
    const form=page.locator('#adminBannerForm');
    const bounds=await form.boundingBox();assert.ok(bounds.x>=0&&bounds.x+bounds.width<=width);
    for(const id of ['adminTitle','adminSubtitle','adminImage','adminFile']){
     const box=await page.locator('#'+id).boundingBox();assert.ok(box.x>=bounds.x&&box.x+box.width<=bounds.x+bounds.width+1,id+' overflows editor');
    }
   }
   assert.deepEqual(errors,[]);
   assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
   await page.close();console.log('PASS browser:',width,role);
  }
  // Two independent tabs share a backend revision; stale writes must retain edits.
  {
   const state=backend();const first=await openEditor(browser,state),second=await openEditor(browser,state);
   await first.page.locator('#adminTitle').fill('First editor');
   await first.page.locator('#adminBannerForm button[type=submit]').click();
   await first.page.waitForFunction(()=>document.getElementById('adminStatus').textContent.includes('Збережено'));
   await second.page.locator('#adminTitle').fill('Second editor');
   await second.page.locator('#adminBannerForm button[type=submit]').click();
   await second.page.waitForFunction(()=>document.getElementById('adminStatus').textContent.includes('Онови'));
   assert.equal(await second.page.locator('#adminTitle').inputValue(),'Second editor');assert.equal(state.saves,1);
   await second.page.locator('#adminReload').click();
   await second.page.waitForFunction(()=>document.getElementById('adminTitle').value==='First editor');
   await second.page.locator('#adminTitle').fill('After reload');
   await second.page.locator('#adminPublished').check();
   await second.page.locator('#adminBannerForm button[type=submit]').click();
   await second.page.waitForFunction(()=>document.getElementById('adminStatus').textContent.includes('опубліковано'));
   assert.equal(state.saves,2);assert.equal(state.banner.revision,6);
   assert.deepEqual([...first.errors,...second.errors],[]);
   await first.page.close();await second.page.close();console.log('PASS browser: two-editor conflict, reload and publish');
  }
  {
   const state=backend('administrator');const {page,errors}=await openEditor(browser,state);
   await page.locator('#adminBannerForm').waitFor({state:'visible'});state.role=null;
   await page.locator('#adminBannerForm button[type=submit]').click();
   await page.locator('#adminBannerForm').waitFor({state:'hidden'});
   assert.equal(state.saves,0);assert.match(await page.locator('#adminStatus').textContent(),/відкликаний/);
   assert.deepEqual(errors,[]);await page.close();console.log('PASS browser: revoked administrator cannot save');
  }
  {
   const state=backend();const {page,errors}=await openEditor(browser,state);
   await page.locator('#adminBannerForm').waitFor({state:'visible'});
   await page.locator('[data-account-view=security]').click();await page.locator('#demoLogout').click();
   await page.locator('#adminBannerForm').waitFor({state:'hidden'});
   assert.equal(await page.locator('#adminTitle').inputValue(),'');assert.equal(state.saves,0);
   assert.deepEqual(errors,[]);await page.close();console.log('PASS browser: logout clears editor');
  }
  {
   const state=backend();const {page,errors}=await openEditor(browser,state);
   await page.locator('#adminTitle').fill('Keep this draft');
   await page.locator('#adminDetails summary').click();await page.locator('#adminDetails summary').click();
   assert.equal(await page.locator('#adminTitle').inputValue(),'Keep this draft');
   assert.deepEqual(errors,[]);await page.close();console.log('PASS browser: collapse retains draft');
  }
  {
   const state=backend();state.failNextSave=true;const {page,errors}=await openEditor(browser,state);
   await page.locator('#adminFile').setInputFiles({name:'banner.png',mimeType:'image/png',buffer:Buffer.from('mock image')});
   await page.locator('#adminBannerForm button[type=submit]').click();
   await page.waitForFunction(()=>document.getElementById('adminStatus').textContent.includes('Не вдалося'));
   const image=await page.locator('#adminImage').inputValue();assert.match(image,/^https:\/\/example.invalid\/weekly\/qa-user\//);
   assert.equal(await page.locator('#adminFile').inputValue(),'');
   await page.locator('#adminBannerForm button[type=submit]').click();
   await page.waitForFunction(()=>document.getElementById('adminStatus').textContent.includes('Збережено'));
   assert.equal(state.uploads.length,1);assert.equal(state.saves,1);assert.equal(state.uploads[0].options.upsert,false);assert.equal(state.banner.image_url,image);
   assert.deepEqual(errors,[]);await page.close();console.log('PASS browser: uploaded URL survives save failure and retry');
  }
  {
   const state=backend();const {page,errors}=await openEditor(browser,state);state.role=null;
   await page.locator('#adminFile').setInputFiles({name:'banner.webp',mimeType:'image/webp',buffer:Buffer.from('mock image')});
   await page.locator('#adminBannerForm button[type=submit]').click();await page.locator('#adminBannerForm').waitFor({state:'hidden'});
   assert.equal(state.saves,0);assert.match(await page.locator('#adminStatus').textContent(),/відкликаний/);
   assert.deepEqual(errors,[]);await page.close();console.log('PASS browser: Storage 403 closes editor');
  }
  {
   const state=backend();let release;state.uploadGate=new Promise(r=>release=r);const {page,errors}=await openEditor(browser,state);
   await page.locator('#adminFile').setInputFiles({name:'banner.jpg',mimeType:'image/jpeg',buffer:Buffer.from('mock image')});
   await page.locator('#adminBannerForm button[type=submit]').click();
   assert.equal(await page.locator('#adminTitle').isDisabled(),true);
   await page.locator('[data-account-view=security]').click();await page.locator('#demoLogout').click();
   await page.locator('#adminBannerForm').waitFor({state:'hidden'});release();await page.waitForFunction(()=>window.qaUploadFinished);
   assert.equal(state.saves,0);assert.equal(await page.locator('#adminTitle').isDisabled(),false);assert.equal(await page.locator('#adminImage').inputValue(),'');
   assert.deepEqual(errors,[]);await page.close();console.log('PASS browser: logout during upload prevents stale save');
  }
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
