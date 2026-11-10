# App Store submission kit — Decant 1.0

## App Store Connect: New App

| Field | Value |
|---|---|
| Platform | iOS |
| Name | **Decant** (fallback if taken: `Decant: Wine Scanner & Cellar`) |
| Primary language | English (U.S.) |
| Bundle ID | `com.drewmanley.decant` |
| SKU | `decant-ios-001` |
| User access | Full access |

## App Information

- **Subtitle** (30 chars max): `Scan, rate & cellar your wine`
- **Category:** Food & Drink. **Secondary:** Lifestyle.
- **Content rights:** the app doesn't contain, show or access third-party content it lacks rights to. User content is moderated.
- **Age rating questionnaire:**
  - Alcohol, Tobacco, or Drug Use or References: **Frequent**
  - User-Generated Content: **Yes**
  - Messaging and Chat: **No** (public comments only)
  - Everything else: **None**
  - Expected result: **18+**
- **Privacy Policy URL:** `https://drewmanley16.github.io/decant-legal/privacy.html`

## Pricing and Availability
- Price: Free
- Availability: all countries where selling alcohol-related apps is allowed. Consider excluding countries where alcohol is prohibited.

## Version 1.0 page

**Promotional text** (170 chars max):
> Point your camera at any wine label. Decant identifies the exact wine and vintage, remembers how you rated it, and stands the bottle on your own cellar shelves in 3D.

**Description:**
```
Every great bottle, remembered.

Decant is the wine app for people who love what's in their glass — at a restaurant, at a winery, or at home with friends.

SCAN ANY LABEL
Point your camera at a bottle. Decant reads the label and identifies the wine and vintage from a catalog of over 185,000 wines, showing you the producer, region and appellation, plus what your friends and the community thought of it. If it's not sure, it tells you — and you can correct it in a tap.

A DIARY FOR EVERY GLASS
Rate wines in half stars, write reviews, keep private tasting notes, add photos, and log where and when you drank them. Taste the same wine again next year? Log it again.

SEE WHAT FRIENDS ARE POURING
Follow friends, like and comment on their reviews, and see their ratings right on each wine's page. Share beautiful wine cards to Instagram Stories or iMessage.

YOUR CELLAR, IN 3D
Every bottle you own stands on lit shelves, grouped by style and wearing its own label. Tap one to lift it off the shelf in 3D, turn it in your hand to read the label, and swipe through the rest of your collection. Track how many bottles you have and what you paid. When you open one, it moves to your Wine History.

DISCOVER WHAT'S NEXT
Personal recommendations based on wines you loved, regions you haven't explored, and what's popular with your friends.

YOUR STATS
Wines tasted, countries explored, favorite grapes and regions, monthly activity, and your top-rated bottles.

PRIVATE BY DESIGN
Choose who sees each review: everyone, friends, or only you. Make your profile private. Your cellar and notes are always yours alone.

Decant is for adults of legal drinking age. Please drink responsibly.
```

**Keywords** (100 chars max, 98 used):
```
wine,scanner,label,cellar,bottle,sommelier,tasting,notes,rating,vintage,red,white,collection,diary
```
> `vivino` was swapped for `bottle`: competitor names in keywords can get a first submission rejected under guideline 2.3.7.

**Support URL:** `https://drewmanley16.github.io/decant-legal/support.html`
**Marketing URL:** `https://drewmanley16.github.io/decant-legal/`
**Copyright:** `2026 Drew Manley`

**Screenshots** are in `screenshots/`, captured from the live app on the demo account. Upload in filename order:
- `iphone-6.9/` (1320×2868): the required set. Apple scales it down for smaller iPhones.
- `iphone-6.3/` (1206×2622): the "iPhone with Dynamic Island (medium display)" slot. The 6.9" set is rejected there for its size.
- `iphone-6.1/` (1179×2556): fallback for the medium slot if it asks for the 6.1" size.

All screenshots are flattened RGB with no alpha channel, which App Store Connect requires.

1. `1-cellar.png`: cellar shelves grouped by style
2. `2-inspect.png`: a bottle lifted off the shelf in 3D
3. `3-discover.png`: personal recommendations
4. `4-wine-detail.png`: the wine page with community rating
5. `5-history.png`: Wine History, every wine you've tasted
6. `6-stats.png`: your tasting statistics

**Product page header** (Header and Search Results → Header): `screenshots/header/decant-header-3840x1646.png`.

## App Privacy (the "nutrition label")
Data used to track you: **No.**

Data linked to you, all for **App Functionality** only:

| Category | Data type |
|---|---|
| Contact Info | Email Address, Name |
| User Content | Photos or Videos, Other User Content (reviews, notes, comments) |
| Identifiers | User ID |

Not collected: location, contacts, health, financial info, browsing history, diagnostics, usage data, purchases.

This matches `Decant/Resources/PrivacyInfo.xcprivacy`.

## App Review Information
- **Sign-in required:** yes. Provide a demo account (see the `README` checklist), already filled with tastings and cellar bottles.
- **Contact:** your name, phone and email.
- **Notes for the reviewer:**
```
Decant identifies wine from a photo of the bottle label.

To test scanning: tap the round Scan button, then point the camera at any wine label (or tap "Photos" to choose a label photo). If you don't have a bottle handy, search "Margaux" in the Search tab to open a wine directly.

The cellar is in the Cellar tab. Shelves scroll sideways. Tap a bottle to open it in 3D, swipe left and right to move between bottles, and tap "Turn bottle" to rotate it and pinch to zoom.

Decant is invite-only. The demo account below is already a member. To test creating a new account, use invite code <DEMO_INVITE_CODE>.

User-generated content safeguards (Guideline 1.2):
• Users must accept the Terms of Use / Community Guidelines (zero tolerance for objectionable content) and confirm legal drinking age before using the app.
• Every review, comment and profile has a "…" menu to Report or Block.
• Reported content is hidden from the reporter immediately; blocking hides content in both directions and removes follows.
• Reports are reviewed within 24 hours; violating content is removed and accounts are banned.

Account deletion: Profile → Settings → Delete account.

The demo account below already has tastings and cellar bottles.
```

**Demo account** (Sign-In Information):
- Username: `drewmanley16+appreview@gmail.com`
- Password: kept out of this public repo. It was given to Drew directly; store it in a password manager.
- Invite code for the reviewer notes: the demo account's code from Profile → Invite friends. Kept out of this public repo for the same reason: anyone could use it to join.

## Moderation runbook (needed to keep the 24-hour promise)
Supabase dashboard → SQL Editor:
```sql
-- Open reports, newest first
select r.created_at, r.reason, r.details, r.entry_id, r.comment_id, p.username as reported_user
from content_reports r left join profiles p on p.id = r.reported_user_id
where r.status = 'open' order by r.created_at desc;

-- Hide a review or comment, and close the report
update tasting_entries set hidden_by_moderation = true where id = '<entry_id>';
update review_comments set hidden_by_moderation = true where id = '<comment_id>';
update content_reports set status = 'actioned' where entry_id = '<entry_id>' or comment_id = '<comment_id>';

-- Ban an account: Authentication → Users → … → Ban user (or delete)
```
To get an email whenever a report comes in, add a Database Webhook on `content_reports` insert in Supabase.
