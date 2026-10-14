# mobikit-plt
MOBIKIT PLT demo website

## Admin and weekly banner

Open `https://y28phtcr4g-glitch.github.io/mobikit-plt/?cloud=1#account`, sign in with the email link, then open **Керування магазином** below the account. Owner and administrator can edit; seller and customers cannot. Roles come only from the database, never email, profile metadata, or browser storage. Membership management is deliberately SQL-only.

The editor supports HTTPS image URLs or JPEG/PNG/WebP uploads (5 MiB maximum), a title and subtitle, draft/hidden state, and publication. A revision check rejects concurrent edits; click **Перевірити доступ / оновити** to reload after a conflict (this discards local edits). Each upload uses a new path; old images are not overwritten or automatically deleted. A failed save after upload may leave an unused image: the editor retains its URL and clears the file input so retry does not upload it again. After a revision conflict, copy this URL before reloading (reload discards local edits), then paste it back, or remove unused objects manually through Storage after checking references. Banner images are public marketing assets, including draft uploads; do not upload private material.

The public storefront reads only published banners via `mk_weekly_banner`, including outside cloud account mode. The banner starts hidden. Only the latest refresh may change its display, so a stale response cannot restore a hidden banner. If no banner is published or the request fails, the banner is hidden; products remain available. Images use contain sizing to avoid cropping. Title/subtitle are rendered as text.

## Manual Supabase setup (required)

1. In the correct Supabase project, review and apply all migrations in filename order. If earlier migrations are already applied, apply only missing ones. In particular apply `202610100001_admin_banner_foundation.sql` followed by `202610140001_admin_banner_security.sql`. The second migration removes the old four-argument save RPC, adds roles/draft RPCs, revision checks, the `mk-banners` bucket and its insert policy. Apply it once through migration tracking; do not rerun it blindly.
2. Register/sign in with the intended owner's separate email. In **Authentication → Users**, personally verify the account identity, confirmed email and exact user UUID. Email alone is not authorization. No Owner has been assigned by this code or by development.
3. Only in the trusted SQL editor, replace BOTH placeholders below using that verified record, review the result, then execute. It refuses an unconfirmed/mismatched user or an existing owner. Never paste service-role keys into the site, repository, or chat.

```sql
do $$
declare
  verified_id uuid := 'REPLACE_WITH_VERIFIED_AUTH_USER_UUID';
  verified_email text := 'REPLACE_WITH_VERIFIED_EMAIL';
begin
  lock table public.mk_admin_members in exclusive mode;
  if exists(select 1 from public.mk_admin_members where role='owner') then
    raise exception 'Owner already exists; review membership manually';
  end if;
  if not exists(select 1 from auth.users where id=verified_id
    and email=verified_email and email_confirmed_at is not null) then
    raise exception 'Verified confirmed account does not match';
  end if;
  insert into public.mk_admin_members(user_id,role) values(verified_id,'owner');
end $$;
```

4. Configure Supabase Auth **Site URL** and allowed redirect URL to `https://y28phtcr4g-glitch.github.io/mobikit-plt/` and the exact email redirect used by the client: `https://y28phtcr4g-glitch.github.io/mobikit-plt/?cloud=1&qa=cloud`. Configure email delivery/SMTP and verify a real sign-in link. The browser uses only a publishable key.
5. Inspect existing Storage policies: broad permissive policies from earlier manual setup can also grant access. For `mk-banners`, allow only the new role-checked insert rule; no browser update/delete/list policy is required. Public image URLs remain readable by design. Verify the bucket size/MIME restrictions.
6. In a disposable Supabase test project, run `supabase/tests/admin_banners.sql` after all migrations (transaction rolls back). Then verify real uploads with Owner/administrator and rejection for customer/seller, logout, role revocation, concurrent edits, and anonymous published/hidden rendering. Remove production Owner membership only deliberately through trusted SQL; never trust a hidden UI as access enforcement.

## Local checks

Run `node --test tests/admin-ui.test.cjs`. This checks store JavaScript syntax and editor behavior with mocked DOM/RPC: denied roles, role loading, stale auth responses, missing migration, unsafe URLs, conflict handling, and revoked access. These tests do not substitute for database RLS tests or real browser/Storage verification. No live database credentials are required or stored.

Optional browser smoke check: `node tests/admin-browser.cjs` with Playwright available. Set `MOBIKIT_BROWSER_PATH` to an installed Chromium/Edge executable if Playwright's browser is unavailable. It mocks Supabase, exercises all four access roles, saves using the loaded revision, checks page errors and mobile horizontal overflow. The review passed 10 logic tests (including out-of-order banner responses and retry after upload) and all 4 browser role scenarios in headless Edge. The SQL suite also checks direct table privileges, Storage object insert paths/roles and denied update/delete; metadata inserts do not validate Storage API MIME/size enforcement. The SQL suite and live Supabase/Storage flows remain unverified until manual setup.
