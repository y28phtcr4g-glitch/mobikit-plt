# mobikit-plt
MOBIKIT PLT demo website

## Admin and weekly banner

Open `https://y28phtcr4g-glitch.github.io/mobikit-plt/?cloud=1#account`, sign in with the email link, then open **Керування магазином** below the account. Owner and administrator can edit; seller and customers cannot. Roles come only from the database, never email, profile metadata, or browser storage. Membership management is deliberately SQL-only.

The editor supports HTTPS image URLs or JPEG/PNG/WebP uploads (5 MiB maximum), a title and subtitle, draft/hidden state, and publication. A revision check rejects concurrent edits; click **Перевірити доступ / оновити** to reload after a conflict (this discards local edits). Each upload uses a new path; old images are not overwritten or automatically deleted. A failed save after upload may leave an unused image: the editor retains its URL and clears the file input so retry does not upload it again. After a revision conflict, copy this URL before reloading (reload discards local edits), then paste it back, or remove unused objects manually through Storage after checking references. Banner images are public marketing assets, including draft uploads; do not upload private material.

The public storefront reads only published banners via `mk_weekly_banner`, including outside cloud account mode. The banner starts hidden. Only the latest refresh may change its display, so a stale response cannot restore a hidden banner. If no banner is published or the request fails, the banner is hidden; products remain available. Images use contain sizing to avoid cropping. Title/subtitle are rendered as text.

## Manual Supabase setup (required)

1. In the correct Supabase project, review and apply all migrations in filename order. If earlier migrations are already applied, apply only missing ones. In particular apply `202610100001_admin_banner_foundation.sql` followed by `202610140001_admin_banner_security.sql` and `202610140002_banner_storage_guards.sql`. The second migration removes the old four-argument save RPC, adds roles/draft RPCs, revision checks, the `mk-banners` bucket and its insert policy. Apply it once through migration tracking; do not rerun it blindly.
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
5. Inspect existing Storage policies: broad permissive policies from earlier manual setup can also grant access. The new restrictive guards constrain even broad legacy permissive policies for `mk-banners`: only role-checked inserts into the current user’s path are allowed; browser update/delete/list are blocked. Other buckets keep their existing rules. Public image URLs remain readable by design. Verify the bucket size/MIME restrictions.
6. In a disposable Supabase test project, run `supabase/tests/admin_banners.sql` after all migrations (transaction rolls back). Then verify real uploads with Owner/administrator and rejection for customer/seller, logout, role revocation, concurrent edits, and anonymous published/hidden rendering. Remove production Owner membership only deliberately through trusted SQL; never trust a hidden UI as access enforcement.

## Local checks

Run `node --test tests/admin-ui.test.cjs`. This checks store JavaScript syntax and editor behavior with mocked DOM/RPC: denied roles, role loading, stale auth responses, missing migration, unsafe URLs, conflict handling, and revoked access. These tests do not substitute for database RLS tests or real browser/Storage verification. No live database credentials are required or stored.

Optional browser smoke check: `node tests/admin-browser.cjs` with Playwright available. Set `MOBIKIT_BROWSER_PATH` to an installed Chromium/Edge executable if Playwright's browser is unavailable. It mocks Supabase, exercises all four access roles, saves using the loaded revision, checks page errors and mobile horizontal overflow. The browser suite covers four roles at 320, 390, 768 and 1440 px, including editor field bounds. The SQL suite also checks direct table privileges, Storage object insert paths/roles and denied update/delete; metadata inserts do not validate Storage API MIME/size enforcement. The embedded PostgreSQL runner passes all migration and SQL suites against minimal Supabase schema fixtures. Live Supabase/Storage flows remain unverified until manual setup.

## Відтворення перевірок і ручне приймання

- `node --test tests/admin-ui.test.cjs` — логіка редактора, відкликання доступу, конфлікти, завантаження та безпечні URL.
- `node tests/admin-browser.cjs` — потрібен Playwright (`npm install --no-save playwright@1.62.1`), Chromium (`npx playwright install chromium`) або `MOBIKIT_BROWSER_PATH` до Edge/Chromium. Запускати з кореня репозиторію. Браузерні тести використовують mock Supabase, не реальні облікові записи. Крім 16 перевірок ролей/ширин є сценарії двох вкладок зі спільною ревізією, конфлікту й повторної публікації, відкликання доступу та виходу з очищенням форми. Додатково перевіряються збереження тексту після згортання, повторна спроба без дублювання фото, відмова Storage 403 та вихід під час затриманого завантаження.
- `npm install --no-save @electric-sql/pglite@0.5.9 playwright@1.62.1`, потім `node tests/sql-embedded.cjs` — локальний PostgreSQL у пам’яті, без Docker і без доступу до Supabase. Виконує всі 8 міграцій за порядком та 4 SQL-набори перевірок. `MOBIKIT_PGLITE_MODULE` дозволяє вказати шлях до вже встановленого модуля. Runner створює мінімальні `auth`/`storage` fixtures і ролі з RLS; не відтворює повний Supabase, HTTP API, JWT-перевірку, MIME/size enforcement або production grants. Жодних даних чи ролей зовнішньої бази не змінює.
- SQL: лише в одноразовому тестовому Supabase застосувати всі міграції за порядком і виконати кожен `supabase/tests/*.sql` через `psql "$TEST_DATABASE_URL" --set=ON_ERROR_STOP=1 --file=...`. Не підставляти production URL. Тести завершуються rollback; після помилки зупинити запуск і закрити з’єднання. Це звичайні SQL assertions, не pgTAP.
- `admin_banners.sql` навмисно створює широку permissive Storage policy всередині транзакції: перевіряє, що restrictive guards блокують обхід, сторонні шляхи, seller/customer/anon, відкликану роль та самопідвищення через metadata. Перевірки metadata не замінюють реальний Storage API.
- У тестовому проєкті: Owner/administrator зберігають чернетку та публікують; seller/customer отримують відмову. Перевірити вихід, відкликання ролі у відкритій сесії, конфлікт двох вкладок, приховування банера для гостя, MIME/ліміт 5 MiB через Storage API, читання публічного фото та заборону overwrite/delete/list.
- Призначення Owner — лише після особистої перевірки UUID, підтвердженої пошти й дозволу власника за процедурою вище. Ці зміни не призначають ролі і не застосовують production міграції.

Редактор зберігає незбережений текст при згортанні й повторному відкритті. Кнопка «Перевірити доступ / оновити» навмисно перечитує дані й відкидає місцеві зміни. Вихід або зміна сесії очищає форму та блокування; відповідь старого завантаження не зберігає банер і не розблоковує нове збереження. Storage 401/403 закриває редактор до повторної перевірки доступу. Успішне завантаження, завершене після виходу, може залишити невикористаний публічний файл: перевірити посилання перед ручним видаленням у Storage.
