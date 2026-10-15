// Real PostgreSQL execution with a minimal Supabase schema fixture.
// Does not test GoTrue, PostgREST, Storage HTTP or production grants.
const fs=require('node:fs');
const path=require('node:path');
const {PGlite}=require(process.env.MOBIKIT_PGLITE_MODULE||'@electric-sql/pglite');
const root=path.resolve(__dirname,'..');
const fixture=`
 create role anon nologin;
 create role authenticated nologin;
 create schema auth;
 create schema storage;
 grant usage on schema public, auth, storage to anon, authenticated;
 create table auth.users (
  id uuid primary key, aud text, role text, email text,
  email_confirmed_at timestamptz, raw_user_meta_data jsonb default '{}'
 );
 create function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),
   nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid
 $$;
 create table storage.buckets (
  id text primary key, name text, public boolean default false,
  file_size_limit bigint, allowed_mime_types text[]
 );
 create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id), name text not null,
  unique(bucket_id,name)
 );
 alter table storage.objects enable row level security;
 grant select, insert, update, delete on storage.objects to anon, authenticated;
`;
(async()=>{
 const db=new PGlite();
 try{
  await db.exec(fixture);
  for(const file of fs.readdirSync(path.join(root,'supabase/migrations')).filter(x=>x.endsWith('.sql')).sort()){
   await db.exec(fs.readFileSync(path.join(root,'supabase/migrations',file),'utf8'));
   console.log('PASS migration:',file);
  }
  for(const file of fs.readdirSync(path.join(root,'supabase/tests')).filter(x=>x.endsWith('.sql')).sort()){
   try{await db.exec(fs.readFileSync(path.join(root,'supabase/tests',file),'utf8'))}
   catch(e){console.error('FAIL SQL suite:',file);throw e}
   console.log('PASS SQL suite:',file);
  }
 }finally{await db.close()}
})().catch(e=>{console.error(e.message,e.code||'',e.where||'');process.exitCode=1});
