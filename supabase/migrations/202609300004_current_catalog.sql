begin;
-- Copy the current 31-product demo catalogue exactly; keep legacy rows unpublished.
update public.mk_catalog_items set published=false;
insert into public.mk_catalog_items(product_id,variant_key,name,variant,photo,warranty,price,stock,is_demo,published) values
('case-magsafe','iphone15pro-black','MagSafe чохол','iPhone 15 Pro · Чорний','','Не вказано',499,5,true,true),
('case-magsafe','iphone15pro-clear','MagSafe чохол','iPhone 15 Pro · Прозорий','','Не вказано',499,3,true,true),
('case-magsafe','iphone14-black','MagSafe чохол','iPhone 14 · Чорний','','Не вказано',499,2,true,true),
('case-gleam-magnetic','iphone15-black','GLEAM Case with Magnetic Ring','iPhone 15 · Чорний','https://content1.rozetka.com.ua/goods/images/big/578240497.jpg','Не вказано',549,4,true,true),
('case-gleam-magnetic','iphone15-clear','GLEAM Case with Magnetic Ring','iPhone 15 · Прозорий','https://content1.rozetka.com.ua/goods/images/big/578240497.jpg','Не вказано',549,2,true,true),
('hoco-h86-dragon','','Hoco H86 Dragon','','','Не вказано',699,3,true,true),
('baseus-gravity-car-mount','','Baseus Car Mount Tank Gravity','','https://static.insales-cdn.com/files/1/3483/22252955/original/c2d87deaad0f27a11a17ae020c8e5acf.png','Не вказано',699,4,true,true),
('camera-a26','','Фотокамера A26','','https://www.7md.ae/web/image/product.image/60081/image_1024/Lily%20Toy%20Kids%20Instant%20Print%20Camera%2048MP%201080P%20800mAh?unique=ed54571','Не вказано',1599,2,true,true),
('camera-q5','','Дитяча фотокамера Q5','','https://a.allegroimg.com/original/1127fe/81ff89394df1b66b67e28b9d6e56/Aparat-dla-dzieci-z-drukarka-termiczna-natychmiastowa-dla-dziecka-Q5-uszy','Не вказано',1699,4,true,true),
('printer-d7-rabbit','','Портативний термопринтер Mini D7 Rabbit','','https://i.ebayimg.com/images/g/CoIAAOSwOx9mBqXd/s-l1600.jpg','Не вказано',1099,3,true,true),
('walker-wts67','','Walker WTS-67 ANC+ENC','','https://stylecom.ua/image/cache/catalog/photos/29020/2-jpg-17-1000x1000.jpg','Не вказано',1399,5,true,true),
('proove-dreamer','black','Proove Dreamer','Чорний','https://prooveglobal.com/image/cache/products/84/61/846128f2-c9e4-11f0-810d-a8a1593ebe6e-600x600.webp','Не вказано',1399,4,true,true),
('proove-dreamer','white','Proove Dreamer','Білий','https://prooveglobal.com/image/cache/products/84/61/846128f2-c9e4-11f0-810d-a8a1593ebe6e-600x600.webp','Не вказано',1399,2,true,true),
('proove-mello','','Proove Mello','','https://prooveglobal.com/image/cache/products/fe/cb/fecb947d-ed4a-11f0-8111-a8a1593ebe6e-600x600.webp','Не вказано',1299,3,true,true),
('remax-ap10','','Remax AP10','','https://mouse.ge/files/resized/products/remax-ap103.600x800.jpg','Не вказано',849,2,true,true),
('borofone-bg100','','Borofone BG100','','https://cs.vchehle.ua/uploads/CGm34mHevILt7Qha47qNiAI7wppf5ai4.jpg','Не вказано',899,4,true,true),
('xo-m8-pro','','XO M8 Pro','','https://external.webstorage.gr/mmimages/image/29/22/79/88/MRK3060312-XO-6920680837991-01-560x560.jpg','Не вказано',1499,5,true,true),
('xo-watch4','','XO Watch 4','','','Не вказано',1699,3,true,true),
('hy300','','HY300 Projector','','https://omegisza.pl/43765-large_default/przenosny-rzutnik-projektor-android-110-tv-wifi-bluetooth-hdmi-glosnik.jpg','Не вказано',2999,2,true,true),
('hoco-dt1','','HOCO DT1','','https://i00.eu/img/716/1600x1600/525ss9tg/102492.jpg','Не вказано',2799,4,true,true),
('aimb-g1','','Smart AI Glasses AIMB-G1','','https://s.alicdn.com/%40sc04/kf/Hc3c9c696022245e491d44191ad4f4bf2q.jpg','Не вказано',2499,2,true,true),
('hoco-k24-gimbal','','HOCO K24 3-Axis Smart Gimbal','','https://phukiengiaxuong.com.vn/cdn/images/202509/source_img/hoco-k24-5.jpg','Не вказано',1999,3,true,true),
('mj261','','MJ-261 RGB Fill Light','','','Не вказано',1499,4,true,true),
('rechargeable-light-35','','Акумуляторна лампа 35 см','','','Не вказано',699,5,true,true),
('baseus-fm11','10000-black','Baseus EnerFill FM11 10000mAh','10000 mAh · Чорний','https://eu.baseus.com/cdn/shop/files/Baseus_EnerFill_FM11_Magnetic_Power_Bank_10000mAh_22.5W_4_1200x.jpg?v=1759227033','Не вказано',1799,5,true,true),
('baseus-fm11','10000-white','Baseus EnerFill FM11 10000mAh','10000 mAh · Білий','https://eu.baseus.com/cdn/shop/files/Baseus_EnerFill_FM11_Magnetic_Power_Bank_10000mAh_22.5W_4_1200x.jpg?v=1759227033','Не вказано',1799,3,true,true),
('proove-hoodman','','Proove Hoodman Magnetic 10000mAh','','https://ncase.ua/images/cHJvZHVjdHMvYmIvNzkvYmI3OTcxOTMtMDU1MC00M2RhLWI4MjAtMmZjNmI3NWU3MWJmLmpwZzoxMDAwOjEwMDA%3D.jpg','Не вказано',1599,3,true,true),
('remax-rpp565','','Remax RPP-565 60000mAh','','https://rokbucket.rokomari.io/ProductNew20190903/260X372/Remax_RPP_565_60000mAh_225W_Fast_Chargin-Remax-d50e9-457509.png','Не вказано',2799,2,true,true),
('walker-wh43-33w','','Walker WH-43 GaN 33W','','https://content1.rozetka.com.ua/goods/images/big/541751425.jpg','Не вказано',699,5,true,true),
('proove-rapid-20w','','Proove RAPID 20W Charging Set','','https://aks.md/files/products/szu_proove_rapid_20w_type-c_cab_belyj_1.800x600w.png','Не вказано',699,4,true,true),
('proove-nova-10w','','Proove NOVA Bluetooth Speaker 10W','','https://prooveglobal.com/image/cache/products/ed/62/ed627375-948d-11f0-8109-a8a1593ebe6e-600x600.webp','Не вказано',1299,3,true,true),
('speaker-walker-wsp750','','Walker WSP-750 60W','','','Не вказано',2499,2,true,true),
('fan-hoco-hx60','','HOCO HX60 Nimble','','https://phukienhoco.vn/data/Product/quat-cam-tay-di-dong-hx60-nimble-QxMmQadS4NYbd6ZyjuGe.jpg','Не вказано',699,4,true,true),
('fan-baseus-gotrip-dt1','','Baseus GoTrip DT1','','https://down-my.img.susercontent.com/file/cn-11134207-7ras8-m7w2n0iw3nqq97','Не вказано',899,3,true,true),
('cable-walker-power-silicone-100w','1m-black','Walker Power Silicone Type-C ↔ Type-C 100W','1 м · Чорний','https://content1.rozetka.com.ua/goods/images/original/575555553.jpg','Не вказано',399,5,true,true),
('cable-walker-power-silicone-100w','2m-black','Walker Power Silicone Type-C ↔ Type-C 100W','2 м · Чорний','https://content1.rozetka.com.ua/goods/images/original/575555553.jpg','Не вказано',399,2,true,true),
('cable-walker-power-silicone-100w','2m-white','Walker Power Silicone Type-C ↔ Type-C 100W','2 м · Білий','https://content1.rozetka.com.ua/goods/images/original/575555553.jpg','Не вказано',399,0,true,true),
('cable-baseus-rapid-charge','1m-black','Baseus Rapid Charge Cable','1 м · Чорний','https://www.buyon.pk/image/cache/data/members/mjitraders/baseushalodatacableusbformicro2a2c3meterblackcamgh-e01-1620571441-386x386.jpg','Не вказано',399,4,true,true),
('cable-baseus-rapid-charge','2m-black','Baseus Rapid Charge Cable','2 м · Чорний','https://www.buyon.pk/image/cache/data/members/mjitraders/baseushalodatacableusbformicro2a2c3meterblackcamgh-e01-1620571441-386x386.jpg','Не вказано',399,1,true,true)
on conflict(product_id,variant_key) do update set name=excluded.name,variant=excluded.variant,photo=excluded.photo,warranty=excluded.warranty,price=excluded.price,stock=excluded.stock,is_demo=true,published=true;
commit;


