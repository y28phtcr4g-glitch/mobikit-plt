// Optional: requires Playwright and its Chromium browser in the local environment.
const {chromium}=require('playwright');
const fs=require('node:fs');
const assert=require('node:assert/strict');
const html=fs.readFileSync('index.html','utf8');
const mock=`export function createClient(){return {
 auth:{getSession:async()=>({data:{session:{}}}),getUser:async()=>({data:{user:{id:'qa-user',email:'qa@example.invalid'}}}),onAuthStateChange(){},signOut:async()=>({})},
 from(){return {select(){return this},eq(){return this},maybeSingle:async()=>({data:{name:'QA User'}})}},
 rpc:async(name,args)=>{if(name==='mk_admin_role')return {data:window.qaRole};
 if(name==='mk_admin_banner_get')return {data:[{title:'QA Banner',subtitle:'Draft',image_url:'https://example.invalid/banner.jpg',published:false,revision:4}]};
 if(name==='mk_admin_banner_save'){window.qaSave=args;return {data:5}};
 return {data:[]}}
}}`;
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.MOBIKIT_BROWSER_PATH?{executablePath:process.env.MOBIKIT_BROWSER_PATH}:{})});
 try{
  for(const width of [320,390,768,1440])for(const role of ['owner','administrator','seller',null]){
   const page=await browser.newPage({viewport:{width,height:844}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
   await page.addInitScript(role=>{window.qaRole=role},role);
   await page.route('**/*',route=>{const url=route.request().url();if(url.startsWith('https://mobikit.test/'))return route.fulfill({contentType:'text/html',body:html});if(url.startsWith('https://esm.sh/'))return route.fulfill({contentType:'application/javascript',body:mock,headers:{'access-control-allow-origin':'*'}});return route.abort()});
   await page.goto('https://mobikit.test/?cloud=1#account');
   await page.locator('#adminDetails summary').click();
   await page.waitForFunction(()=>!document.getElementById('adminStatus').textContent.includes('Перевіряємо'));
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
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
