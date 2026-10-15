const {chromium}=require('playwright');const fs=require('node:fs');const assert=require('node:assert/strict');
const html=fs.readFileSync('index.html','utf8');
const mock=`export function createClient(){return {auth:{getSession:async()=>({data:{session:{}}}),getUser:async()=>({data:{user:{id:'qa-user',email:'qa@example.invalid'}}}),onAuthStateChange(){},signOut:async()=>({})},from(){return {select(){return this},eq(){return this},maybeSingle:async()=>({data:{name:'QA Owner'}})}},storage:{from:()=>({upload:async()=>({}),getPublicUrl:()=>({data:{publicUrl:'https://example.invalid/photo.png'}})})},rpc:async(name,args)=>await(await fetch('/rpc',{method:'POST',body:JSON.stringify({name,args})})).json()}}`;
(async()=>{const browser=await chromium.launch({headless:true,executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe'});try{
 for(const width of [390,1440]){
 let role='owner',rows=[],offers=[],forceConflict=false,saves=0,categories=[];const page=await browser.newPage({viewport:{width,height:900}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/*',async route=>{const url=route.request().url();
 if(url==='https://mobikit.test/rpc'){const {name,args}=JSON.parse(route.request().postData());let data=[];
 if(name==='mk_admin_role')data=role;
 if(name==='mk_admin_banner_get')data=[{revision:0,title:'Banner',subtitle:'',image_url:'',published:false}];
 if(['mk_admin_catalog_list','mk_admin_promotions','mk_admin_product_save','mk_admin_promotion_save','mk_admin_category_create'].includes(name)&&!['owner','administrator'].includes(role))return route.fulfill({json:{error:{code:'42501'}}});
 if(name==='mk_admin_catalog_list')data=rows.map(r=>({...r,reserved:0,available:r.stock,orderable:Math.max(0,r.stock-1)}));
 if(name==='mk_admin_promotions')data=offers;
 if(name==='mk_admin_category_create'){if(categories.some(c=>c.name===args.p_name))return route.fulfill({json:{error:{code:'23505'}}});data={id:'cat-qa',name:args.p_name};categories.push(data)}
 if(name==='mk_storefront')data={categories,items:rows.filter(r=>r.published).map(r=>({...r,available:r.stock})),promotions:offers.filter(o=>o.published).map(o=>({id:o.product_id,salePrice:o.sale_price,published:true,startAt:o.start_at,endAt:o.end_at}))};
 if(name==='mk_admin_product_save'){
 const old=rows.find(r=>r.product_id===args.p_item.product_id&&r.variant_key===args.p_item.variant_key);
 if(forceConflict||old&&old.revision!==args.p_revision)return route.fulfill({json:{error:{code:'40001'}}});
 data={...args.p_item,is_demo:true,revision:old?old.revision+1:0};rows=rows.filter(r=>r!==old).concat(data);saves++;
 }
 if(name==='mk_admin_promotion_save'){data={...args.p_item,revision:0};offers=[data]}
 return route.fulfill({json:{data}});
 }
 
 if(url.startsWith('https://mobikit.test/'))return route.fulfill({contentType:'text/html',body:html});
 if(url.startsWith('https://esm.sh/'))return route.fulfill({contentType:'application/javascript',body:mock,headers:{'access-control-allow-origin':'*'}});
 return route.abort();});
 await page.goto('https://mobikit.test/?cloud=1#account');await page.locator('#catalogAdmin').waitFor({state:'attached'});await page.getByRole('button',{name:'Товари',exact:true}).click();await page.locator('#catalogAdmin').waitFor({state:'visible'});assert.equal(await page.locator('#account #catalogAdmin').count(),0);await page.locator('#categoryCreateName').fill('Ігрові аксесуари');await page.getByRole('button',{name:'Додати категорію',exact:true}).click();await page.getByText('Категорію «Ігрові аксесуари» додано.',{exact:false}).waitFor();assert.equal(await page.locator('[data-category=cat-qa]').innerText().then(x=>x.includes('Ігрові аксесуари')),true);await page.locator('[data-category=cat-qa]').click();await page.locator('#categoryAddProduct').click();assert.equal(await page.locator('#catalogCategory').inputValue(),'cat-qa');await page.locator('#catalogNew').click();
 await page.locator('#catalogName').fill('<b>QA Cable</b>');await page.locator('#catalogCategory').selectOption('cables');await page.locator('#catalogDescription').fill('New description');await page.locator('#catalogPrice').fill('245.50');await page.locator('#catalogStock').fill('5');
 assert.equal(await page.locator('#catalogPublished').isDisabled(),true);await page.locator('#catalogForm button[type=submit]').click();await page.getByText('Чернетку збережено.',{exact:false}).waitFor();assert.equal(rows.length,1);assert.equal(rows[0].published,false);
 await page.locator('#catalogPublished').check();await page.locator('#catalogForm button[type=submit]').click();await page.getByText('Товар збережено й опубліковано.',{exact:true}).waitFor();
 await page.locator('#catalogPhoto').fill('https://example.invalid/photo.png');await page.locator('#catalogForm button[type=submit]').click();await page.waitForFunction(()=>document.getElementById('catalogStatus').textContent.includes('опубліковано'));assert.equal(rows[0].photo,'https://example.invalid/photo.png');
 await page.locator('#promotionPrice').fill('199.99');await page.locator('#promotionPublished').check();await page.locator('#promotionForm button[type=submit]').click();await page.getByText('Акцію збережено.',{exact:true}).waitFor();assert.equal(offers[0].sale_price,199.99);
 await page.getByRole('button',{name:'Товари',exact:true}).click();await page.locator('[data-category=cables]').click();await page.locator('#categoryProducts h3').waitFor();assert.equal(await page.locator('#categoryProducts h3').innerText(),'<b>QA Cable</b>');assert.equal(await page.locator('#categoryProducts b').count(),0);assert.match(await page.locator('#categoryProducts').innerText(),/199/);await page.getByRole('button',{name:'Редагувати товар',exact:true}).click();assert.equal(await page.locator('#products').evaluate(e=>e.classList.contains('active')),true);
 await page.locator('#catalogAddVariant').click();await page.locator('#catalogVariant').fill('Red');await page.locator('#catalogPrice').fill('300');await page.locator('#catalogStock').fill('3');await page.locator('#catalogForm button[type=submit]').click();await page.getByText('Чернетку збережено.',{exact:false}).waitFor();assert.equal(rows.length,2);
 forceConflict=true;await page.locator('#catalogDescription').fill('Keep me');await page.locator('#catalogForm button[type=submit]').click();await page.getByText('Дані вже змінилися.',{exact:false}).waitFor();assert.equal(await page.locator('#catalogDescription').inputValue(),'Keep me');forceConflict=false;
 role='seller';const before=saves;await page.locator('#catalogForm button[type=submit]').click();await page.locator('#catalogAdmin').waitFor({state:'hidden'});assert.equal(saves,before);assert.equal(await page.locator('[data-edit-product]').count(),0);assert.equal(await page.locator('#categoryAdminTools').isHidden(),true);
 assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);assert.deepEqual(errors,[]);await page.close();console.log('PASS catalog UI draft/publish/photo/promotion/variant/conflict/revocation at '+width);
 }
 }finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1});
