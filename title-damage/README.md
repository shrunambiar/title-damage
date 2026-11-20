# TITLE DAMAGE 🍿
**One word. One movie. Infinite ways to ruin it.**

An original TV-and-phones multiplayer party game for **3–10 players**. The TV host opens `/`, creates a room, and puts `/room/CODE` on a television. Friends scan the QR code, type a nickname, and play on their phone without accounts or apps. Built with Next.js 15, React 19, Tailwind, Supabase Postgres, Realtime Broadcast, and Vercel serverless endpoints.

## Included

- Host/TV lobby, overscan-safe display, scannable generated QR, 4-character code, full-screen mode, 10-player cap and editable game settings.
- Phone controller with controlled one-word insertion, server-side title construction, countdown, anonymous voting, results, leaderboard, finale, results card (local SVG), rematches, host and player session cookies.
- Transactional room state machine in PostgreSQL. Lazy idempotent server-driven deadline progression: no dedicated always-on server needed. Reload/reconnect via HttpOnly browser cookie. Realtime change hints plus periodic recovery refresh.
- **2,198 locally curated movie records** in `data/movies.json` across Hollywood, Indian-language cinemas, and international films. The validator checks record count, required fields and duplicate identities, **not** external truth or licensing. These titles have *not* undergone an externally verified metadata audit; years, exact official display titles, genre flags and family suitability still need quality control before production.
- Persistent per-browser-host unseen-movie history, stateful rematches and oldest-first reuse after filter exhaustion.
- Rate limits backed by PostgreSQL, row locks for membership/actions, session-token hashes, row-level security, and private vote storage.

## Requirements

- Node.js 20.9+ or 22 (recommended)
- A free Supabase project (Postgres + public Realtime Broadcast enabled)
- Optional: free Vercel personal Hobby deployment and GitHub repository

## 1. Local setup

```bash
npm install
cp .env.example .env.local
```

Create a new Supabase project. Under **Project Settings → API** (labels may vary), copy the project URL, the public/anon key, and **service role secret** into `.env.local`. **Never prefix the service role variable with `NEXT_PUBLIC_` or commit it.**

In Supabase SQL Editor, run these files **in order**:

1. `db/001_init.sql`
2. `db/002_rate_limit.sql`

Seed the movie library:

```bash
npm run movies:validate
npm run movies:seed
npm run dev
```

Open `http://localhost:3000` in your laptop browser and create a room. **Phones cannot access `localhost` on your laptop**: for local multiplayer use a local LAN address with accessible Next.js dev server or deploy to Vercel, which is simpler. Set `NEXT_PUBLIC_SITE_URL` to the reachable external origin when needed; otherwise the QR link uses the current browser origin. Test the QR using an actual phone on a different network after deployment.

## 2. Vercel deployment (not performed here)

1. Create a private GitHub repo and commit this project (excluding `.env.local`).
2. Import the repository into Vercel and select Next.js.
3. Add `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` as environment variables on Vercel. Leave `NEXT_PUBLIC_SITE_URL` unset to use the real deployed page origin (or explicitly set to your production domain).
4. Deploy. Open the deployed homepage and create a room; use a second device **on cellular** to scan the TV QR and join. Verify 3+ phones before relying on the party setup.
5. Use your generated `https://<project>.vercel.app` URL for free; optionally assign a purchased domain in Vercel Domains and update `NEXT_PUBLIC_SITE_URL` if you previously set it.

Vercel serverless functions and Supabase each have changing limits. Check [Vercel pricing](https://vercel.com/pricing) and [Supabase pricing](https://supabase.com/pricing) before inviting large groups. This personal/noncommercial project is designed for Hobby tier, not guaranteed to remain at $0 at any traffic level.

## Architecture

| Concern | Design |
|---|---|
| Primary authority | SQL functions on Supabase Postgres behind server-only Next.js API routes |
| Auth | HttpOnly `SameSite=Lax` host/player cookies holding 256-bit random tokens; only SHA-256 hashes persisted in DB |
| Max 10 | `td_join` locks room row (`FOR UPDATE`), counts players, inserts while locked |
| Game transitions | `td_progress` locks room row; timestamp-based transitions; called by state fetch and mutations; force advance reserved for host |
| Deadline enforcement | `td_action` checks `now()` inside locked transaction; browser countdown display is cosmetic |
| Realtime | Supabase public Broadcast channel `td:CODE` emits *only* “changed”; clients fetch authorized view. Fallback 9-second refresh and deadline-triggered fetch |
| SQL RLS | All tables deny anon/authenticated direct access; server accesses via service role; security-definer functions execute revoked from public roles |
| Votes | Indexed unique voter-per-round tables, no self-votes, no pre-result voter identities sent to clients |
| Scoring | Once per round with `scored` flag, fractional tie bonuses stored as numeric |
| Host history | Reusable anonymous host cookie maps to host history in DB; browser cleared = history lost |
| QR | `qrcode.react` SVG created client-side from exact deployed origin plus room code |

**Security caveats:** rate limiting here uses hashed forwarded IP for creation/joining (and hashed session credential for actions), suitable for modest personal games, not hardened anti-abuse for internet-scale access. Public Realtime channels carry only an update signal. CSRF defense relies on SameSite cookies plus JSON request body; for a publicly popular commercial application add explicit Origin/CSRF checks, anti-automation challenge and a managed edge-rate-limit layer. Nicknames and words are plain text rendered as text by React, never unsanitized HTML. Basic family-mode word filtering is an incomplete heuristic, not comprehensive moderation.

## Lifecycle and cleanup

Rooms expire eight hours after creation. A periodic cleanup is **not** automatically scheduled on free tiers. In Supabase SQL Editor, run this occasionally (e.g. monthly):

```sql
delete from public.rooms where expires_at < now();
delete from public.anonymous_hosts h
where not exists(select 1 from public.rooms r where r.host_id=h.id)
and h.created_at < now()-interval '180 days';
delete from public.td_rate_limits where window_start < now()-interval '1 day';
```

You can schedule this with Supabase Cron if available and within your project's allowance. Do not assume cron is enabled for free projects. `movie_history` is deliberately retained along with host identity. Room expiration blocks actions even before cleanup.

## Movie library quality and expansion

`npm run movies:validate` reports total structural-valid records, including whether the count meets 2,000. It does **not** prove every record is a real film or metadata is accurate; this manual starter file needs a human verification pass. A streaming optional external metadata pipeline is available:

```bash
npx tsx scripts/import-imdb.ts /path/to/title.basics.tsv.gz /path/to/title.ratings.tsv.gz
```

This creates `data/movies.imdb.json` **for review**, not automatic ingestion, since IMDb basics/rating TSV lacks dependable country/language/age rating fields and treating all films as Hollywood or family-friendly would be misleading. The importer uses popular vote counts to prioritize recognizable real titles. Review and deduplicate before merging into the hand curated JSON; IMDb dataset usage is governed by [IMDb non-commercial dataset conditions](https://developer.imdb.com/non-commercial-datasets/). No external movie API is used *during gameplay*. The local title collection is presented as factual metadata, not as licensed artwork or posters. Popularity tiers and humor scores are subjective heuristics, not independently verified ratings.

`Custom Genre Mix` currently falls back to the global pool; custom weighted-genre controls aren't implemented. The built-in `Comedy`/`Horror` filters rely on the limited local genre labels, which require enrichment before they should be described as comprehensively curated. Movie filters cannot return unavailable genres. `Family Friendly` is a heuristic selection and basic word blocklist, not a formal ratings/age safeguard. Use appropriate judgment with children.

## Tests

```bash
npm run lint
npm test
npx playwright install chromium
npm run test:e2e
```

`tests/game.test.ts` checks word insertion and scoring math, including Unicode and ties. `tests/e2e/room.spec.ts` covers basic page rendering. SQL integration / concurrent 10-phone race and full game-flow tests are **not included**; perform the manual acceptance checklist below before public use. Twelve direct compiled-game-helper assertions and Python movie structural validation were run successfully. The Vitest, Playwright and live SQL integration suites have **not** run because npm package installation and Supabase credentials were unavailable. Do not interpret the included tests as passing until you run them.

### Manual multiplayer acceptance checklist

- [ ] Host creates room; QR works from an iPhone and Android on cellular.
- [ ] 10 devices join with unique names; 11th device is rejected; attempts racing for last slot never create 11th.
- [ ] Three players join; host starts; same title appears on TV and phones.
- [ ] Word insertion at start, middle, end; invalid whitespace/markup blocked, refreshed player retains submission state.
- [ ] TV shows anonymous titles first, no names until results; own submission not available as vote target.
- [ ] Two votes for one title, tie votes, zero votes, expired votes, repeated vote attempts all resolve correctly.
- [ ] All 3/5/10 rounds complete without repeated movie IDs. Scores persist under reconnect.
- [ ] Finale finalist IDs, vote eligibility, tied winners, no-vote showcase and overall champions.
- [ ] End game/rematch, old host history retained, browser refresh restores host controls.
- [ ] With host/phone on different networks, state updates and deadline recovery operate.

## Rough hosting considerations (not usage quotes)

Five rounds + finale with ten players will cause scores of small SQL reads and writes. With a nine-second fallback refresh, an eight-minute game at 11 clients generates roughly **600 fallback status reads**, plus event-driven reads. Approximate monthly scenarios, assuming 10 players, 5 regular rounds, one finale, and ~8 minutes per game:

| Games/month | Players/game | Fallback status requests | Estimated hosting fee |
|---:|---:|---:|---|
| 10 | 10 | 6,000 | $0 if within both current free quotas |
| 100 | 10 | 60,000 | $0 if within both current free quotas |
| 1,000 | 10 | 600,000 | Unknown: monitor usage; free tier is **not** guaranteed |

Totals omit event-driven reads and database mutations, which can materially increase real usage. Actual duration, database load, network transfer and concurrent peaks matter more than total games. Estimated cost is **$0 if both providers' current free quotas, project policies and fair-use rules cover that use**, otherwise upgrade or throttle. 1,000 games per month should be regarded as capacity testing territory, not guaranteed free.

Supabase Free projects may pause due to inactivity; free realtime/database size, egress, connection, and message quotas change. Vercel Hobby has restrictions including commercial-use policy and function/bandwidth/CPU limits. For frequent events, review quotas in both dashboards and migrate to paid plans if needed.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `Supabase environment variables are not set` | Copy `.env.example` to `.env.local` and supply both server variables, restart dev server |
| `Could not find function td_limit` | Run `db/002_rate_limit.sql` after 001 |
| Room created but starting has no movie | Run movie seeder and validate `movies` table in Supabase |
| QR opens wrong domain | Check `NEXT_PUBLIC_SITE_URL` is unset or uses your actual HTTPS production domain; redeploy after changing public env variables |
| TV updates slowly | Verify Supabase public Broadcast permitted, Realtime not blocked by network, fallback refresh every 9s |
| Session lost | Browser disabled/cleared cookies or switched browser/device; this has no account-based cross-device recovery |
| Room expired | Rooms are intentionally 8-hour sessions; create another |
| Can’t use full screen | Tap the full-screen control; some browser/embedded mirror setups require user gesture |

## Current limitations

This is a substantial source implementation, **not a verified production-ready launch**. SQL migrations have not been executed against a live Supabase instance here. Ten-way concurrency, complete mobile gameplay, correct host/proxy setup, realtime live delivery, migration syntax, deployment and broad mobile-browser usability require validation. Movie data has not been externally audited. There is no automatic browser-image screenshot, rich sound library, comprehensive content moderation, weighted custom genre builder, or formal accessibility audit. Please test before inviting friends.
