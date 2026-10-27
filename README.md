# Decant

A native iOS app for discovering, scanning, rating, collecting and sharing wine. Think Vivino + Letterboxd, plus an interactive 3D cellar.

**Critical journey (working end to end):** open app → scan a label → identify the wine and vintage → view details → rate → add to cellar → open the 3D cellar → tap the bottle → rotate and inspect it → see your rating → share a story card.

- Swift 6, SwiftUI, iOS 17+ (built with Xcode 26)
- VisionKit live text scanning, Vision OCR, rectangle detection and Core Image perspective correction
- SceneKit 3D cellar with lathe-turned bottles, scanned-label textures, PBR materials, soft shadows
- Supabase for auth (Sign in with Apple and email), Postgres with RLS, Storage and Edge Functions
- OpenAI vision (or any compatible model) called **only** from an Edge Function

---

## Quick start (no credentials needed)

```bash
brew install xcodegen          # once
xcodegen generate
open Decant.xcodeproj          # run the "Decant" scheme on an iPhone simulator or device
```

If no Supabase keys are configured, the app runs in **Local Mode**:

- Everything is stored on the device (`Application Support/Decant/local-store.json`).
- Label identification runs on-device: OCR, a deterministic parser, then catalog matching.
- A small **simulated sample community** (5 fictional people) is added so you can exercise the feed, likes, comments and friends' ratings. The app labels this clearly in onboarding, on the profile and in Settings. None of it is ever sent to a server.
- The Simulator has no camera. Use **Photos** in the scanner to choose a label photo (`xcrun simctl addmedia booted label.jpg`), or **Manual** entry.

Run the tests:

```bash
xcodebuild test -project Decant.xcodeproj -scheme Decant \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

> If the project is inside an iCloud-synced folder (for example `~/Documents`), keep DerivedData outside it, which is Xcode's default. Codesign rejects the extended attributes that iCloud adds.

---

## Backend setup (Supabase)

1. **Create a project** at supabase.com (or run `supabase start` locally with Docker).
2. **Apply the schema and seed:**
   ```bash
   supabase link --project-ref <ref>
   supabase db push                      # supabase/migrations/*
   psql "$DATABASE_URL" -f supabase/seed.sql
   ```
3. **Check the RLS policies** (optional, but recommended after any policy change):
   ```bash
   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls_test.sql   # runs in a transaction, rolls back
   ```
4. **Deploy the Edge Functions and set their secrets:**
   ```bash
   supabase secrets set OPENAI_API_KEY=sk-... OPENAI_MODEL=gpt-4.1-mini
   supabase functions deploy identify-wine
   supabase functions deploy delete-account
   ```
5. **Configure auth:**
   - Apple: enable the Apple provider and add your bundle ID (`com.decant.app`, or your own) as a Client ID. Native sign-in needs no secret.
   - In Xcode, set your Team and enable the *Sign in with Apple* capability. The entitlement is already in `Decant/Resources/Decant.entitlements`.
   - Email: enabled by default. Turn confirmations on or off as you like; the app handles both.
6. **Point the app at the project:**
   ```bash
   cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # git-ignored
   # set SUPABASE_URL and SUPABASE_ANON_KEY (the public anon key, never the service key)
   xcodegen generate
   ```
   On the next launch the app switches to the Supabase backend automatically.

### Environment configuration

| Where | Key | Purpose |
|---|---|---|
| `Config/Secrets.xcconfig` (app) | `SUPABASE_URL`, `SUPABASE_ANON_KEY` | Public client config. Leave empty for Local Mode. |
| Supabase function secrets | `OPENAI_API_KEY` | Vision model for label reading. Lives only on the server. |
| Supabase function secrets | `OPENAI_MODEL` | Optional. Any vision-capable chat-completions model. |
| Supabase (automatic) | `SUPABASE_SERVICE_ROLE_KEY` | Used by Edge Functions for the label cache and account deletion. |

No provider key ever ships in the app binary.

---

## Architecture

```
Decant/
  App/               Entry point, AppEnvironment (DI container + session), tab shell
  DesignSystem/      Palette (light/dark), typography, buttons, cards, rating, bottle art, skeletons
  Core/
    Models/          Typed domain: Wine (a vintage), Winery, Characteristics, TastingEntry, CellarBottle…
    Services/        Protocols: Auth, WineCatalog, Tasting, Social, Cellar, ScanHistory, Media, RemoteLabelReader
    Backend/Local/   On-device implementation of every protocol (+ isolated sample community)
    Backend/Supabase/ Supabase implementation of every protocol (+ row DTOs)
    Identification/  OCR and perspective crop, label parser, wine lexicon, matcher, identification pipeline
    Logic/           Pure, unit-tested logic: recommendations, statistics, cellar layout and filters
    Caching/         Memory and disk image cache with request coalescing; procedural label art
  Features/          Onboarding, Discover, Search, Scan, WineDetail, Rating, Cellar (+ Scene), Profile, Share
supabase/
  migrations/        Schema, RLS, RPCs, triggers, storage policies
  functions/         identify-wine (AI label reading), delete-account
  seed/              catalog.source.json → build-seed.mjs → seed.sql and the app's SeedCatalog.json
  tests/rls_test.sql RLS regression checks
DecantTests/         Swift Testing suites (parser, matcher, privacy rules, journey, layout, stats, recs)
```

- **MVVM with `@Observable`.** View models live in feature folders. Views never perform network I/O; everything goes through the service protocols on `AppEnvironment`.
- **Swappable backends.** `AppEnvironment.live()` picks Supabase when it's configured and Local Mode otherwise. Previews and tests use `AppEnvironment.preview()` or an isolated `LocalStore`.
- **Separate wine identities.** `wineries` → `wine_products` (a wine, any vintage) → `wine_vintages` (one year and bottle size). Tastings, cellar bottles, wishlists and scans always reference a vintage, so different vintages of the same wine stay distinct.

### Label identification pipeline

```
Camera / photo → Vision rectangle detection → perspective correction (or crop to text region)
  → Vision OCR (multilingual, language correction off for proper nouns)
  → 1. Local cache: same label text seen before → instant, free
  → 2. identify-wine Edge Function (if configured): server-side cache by text hash → vision model with a strict JSON schema
       → pg_trgm catalog matching (match_wines) → candidates and confidence
  → 3. On-device fallback: LabelTextParser + WineMatcher against the catalog
  → Result screen: confidence badge, what was read from the label, alternatives, vintage-mismatch handling,
    manual correction (pre-filled), "enter details" when nothing matches
```

How the app stays honest about what it knows:

- `LabelExtraction` holds only text that is printed on the label. The AI prompt and the parser both return `null` instead of guessing.
- Every fact carries an `InfoSource` (`verified`, `label`, `editorial`, `ai_suggested`, `user`), and the UI shows it as a badge. AI tasting guidance appears in its own dashed card marked "AI suggestion".
- Clients never write AI suggestions. `create_wine_from_scan` and `attach_cached_suggestion` copy them from the server-side `label_cache`, and only onto wines that have no profile yet.
- When the confidence is low, the app shows no match. It offers a pre-filled manual entry instead.
- If the label's vintage differs from the catalog, the app offers "Use the 2016 vintage", which creates a new vintage row of the same product.

### 3D cellar

- One lathe mesh per bottle style (Bordeaux, Burgundy, Champagne) and one label-patch mesh. Each bottle uses a shallow `geometry.copy()`, which shares vertex buffers, so only the label material is unique.
- Labels load asynchronously: the scanned photo through `ImageLoader`, or generated typographic art made off the main thread.
- Rack bays are built once and `flattenedClone()`d, so all the wood shares a single material. LED strips are emissive geometry, not real lights. There's one shadowed spot light plus image-based lighting.
- The camera rig smooths on a `CADisplayLink` and pauses rendering once the scene settles. A gentle idle drift is skipped when Reduce Motion is on.
- Gestures:
  - Drag to orbit, two-finger drag to pan, pinch to zoom, double-tap to reset.
  - Tap a bottle and it slides off the shelf and flies to the camera. Drag rotates it, pinch zooms it.
  - Long-press a bottle to move it: glowing slot markers appear. Tap a slot, or another bottle to swap. The new layout persists through `save_cellar_placements`.
- Filters (type, vintage, grape, region, rating, collection) dim non-matching bottles. Sort modes re-flow the racks. There are four shelf finishes and custom collections, and you can share a snapshot of the cellar.
- The rest of the app never depends on the 3D scene:
  - A 2D shelf view is available as a toggle, and Low Power Mode switches to it automatically.
  - VoiceOver gets a plain bottle list.
  - Empty cellars show a "Scan your first bottle" state with an optional, clearly labelled sample preview.

### Security (RLS)

- **Every table has RLS enabled.** `anon` has no table access.
- **Catalog:** readable by signed-in users. Writes go only through `SECURITY DEFINER` RPCs that validate input.
- **Tastings and reviews:** visibility is `public`, `friends` (mutual follows) or `private`. A private profile hides all content from anyone who isn't an approved follower, and follows to a private profile start as requests.
- **Private notes:** stored in a separate table that only the owner can read.
- **Cellar, wishlist, scan history and notifications:** visible to the owner only.
- **Label cache:** service role only.
- **Storage:** objects are namespaced by `<uid>/`. Tasting photos follow the visibility of their entry and are served through signed URLs.
- **Account deletion:** an Edge Function deletes the auth user, and ON DELETE CASCADE removes every row the user owns plus their storage objects.

`supabase/tests/rls_test.sql` has 17 checks covering these rules. They pass against Postgres 17.

---

## External dependencies and data licensing

| Dependency | Status | Notes |
|---|---|---|
| Supabase | Integrated | `supabase-swift` 2.x via SPM. |
| OpenAI (vision) | Integrated server-side | Swap models with `OPENAI_MODEL`. Any provider can sit behind the same Edge Function contract. |
| **Wine data provider** | **Not included** | See below. |
| Push notifications (APNs) | Architecture only | `device_tokens` table, `notifications` rows written by triggers, permission prompt in Settings. Delivery needs an APNs key and a sender (an Edge Function or webhook). |

**Wine data licensing.** There's no free, licensed and comprehensive wine database. The bundled catalog (`supabase/seed/catalog.source.json`, 25 producers and 27 vintages) is **development seed data**:

- Producer facts are well-established public facts, marked `editorial` ("Curated").
- Tasting profiles, drinking windows and prices are editorial estimates, labelled as typical style. ABV is left empty because it varies by vintage.

For production, license a provider (for example Wine-Searcher, Global Wine Database or a distributor feed) and load it into `wineries`, `wine_products` and `wine_vintages` with `source = 'verified'`. Scraping Vivino or similar sites violates their terms. Don't.

`WineIdentificationService` uses the `RemoteLabelReader` protocol, so a dedicated label-recognition provider can be added alongside the LLM reader without UI changes.

### Credentials you need to supply

1. Supabase project URL and anon key, for the app.
2. `OPENAI_API_KEY`, as a Supabase secret.
3. An Apple Developer Team, for Sign in with Apple and running on a device. Set it in Xcode or as `DEVELOPMENT_TEAM` in `project.yml`.
4. Later: an APNs auth key and a wine data provider license.

---

## Roadmap

**Done:**

- Onboarding, including a live 3D preview.
- Auth: Apple and email, plus Local Mode.
- Live scanner: VisionKit, perspective correction, OCR, AI and on-device identification, confidence, correction, manual entry, scan history, caching.
- Wine details with progressive disclosure, vintages, taste profile, pairings, winery story, friends' ratings, reviews and similar wines.
- Tastings: half-star ratings, reviews, private notes, photos, date, location, occasion, tagging friends, drink-again, favourites, visibility.
- Social: follows and follow requests, feed with pagination, likes, comments, notifications.
- Cellar: inventory, consumption that keeps tasting history, collections, milestones, filters, sorting, finishes, 3D and 2D views, sharing.
- Personalised Discover sections and Search with filters and people search.
- Stats with Swift Charts.
- Wishlist, recently viewed, share cards sized for Instagram Stories.
- Privacy settings, account deletion, dark mode, Dynamic Type, VoiceOver labels, skeletons, empty and error states.

**Next:**

- APNs delivery.
- Approving follow requests from the inbox (the RPC `respond_follow_request` exists; the app has no UI for it yet).
- A licensed wine data import.
- Embedding-based recommendations behind `RecommendationEngine`.
- UI tests and snapshot tests.
- App Store assets.

**Later:** restaurant wine-list scanning, an AI sommelier, winery visit logs, location-based discovery, blind tasting mode, a yearly recap, friend tasting sessions, public cellar tours, cellar rooms and lighting themes.

### Release
- Store listing, privacy answers, review notes and a moderation runbook are in **`AppStore.md`**. The six 6.9" screenshots are in `screenshots/`.
- Legal pages (privacy, terms with community guidelines, support) are in `legal/`, ready for GitHub Pages.
- Safety: age gate and Terms acceptance, Report and Block on every review, comment and profile, and server-side hiding of reported or blocked content (`supabase/migrations/20261028000000_moderation.sql`).
- Archive: `xcodebuild archive -scheme Decant -configuration Release -destination 'generic/platform=iOS' -allowProvisioningUpdates`, or **Product → Archive** in Xcode.
- Screenshots: Debug builds accept `-screenshotSeed [-tab cellar|search|profile] [-inspectFirst]` to launch into a populated local store. This code is not compiled into Release builds.
