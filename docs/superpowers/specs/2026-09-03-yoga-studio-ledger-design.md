# Ganesha — Solo Yoga Studio Ledger

**Date:** 2026-09-03
**Status:** design, pending review
**Diagrams:** [`2026-09-03-yoga-studio-diagrams.html`](./2026-09-03-yoga-studio-diagrams.html)

## 1. Context

A solo yoga teacher in Taiwan runs four recurring weekly classes and tracks everything
by hand in a LINE-pasted document (`8月上課、調課、補課名單`). That document does five
jobs at once: it publishes the month's schedule, collects signups, records who attended
each date, records who paid how much by which method, and tracks makeup entitlements
carried over from cancelled classes.

The system replaces the document. Phase 1 is a teacher-only web app. Phase 2 adds a LINE
bot that passively reads her existing student group and drafts records for her to confirm.

### 1.1 Source material

Facts drawn from the August document, each of which shapes the model:

| Observation | Example |
|---|---|
| Four weekly slots, 3–4 dates per month | 週一 早晨基礎 9:30–10:45 |
| A session's style can differ from its slot's default | `*基礎8/26` on the Wednesday 流動 slot |
| Package price is per-class × dates | 1600/4堂, 1200/3堂 (NT$400/class) |
| Drop-in and trial are the same price | 單堂 450, 體驗 450 |
| The same 2-class total appears at two prices | 900 (=450×2, drop-in) vs 800 (=400×2, package) |
| Prices get adjusted ad hoc | 靖心 400 for one class; 按摩器代購 in lieu of cash |
| A student is a regular in one slot, a drop-in in another | 彩華, 靖心, Jennifer, Kelly |
| Makeups come from two sources with different lifespans | package makeup vs `補7/10颱風假` |
| Makeup credits are portable across weekdays | 蘭子's Friday credit spendable Mon 8/17 or 8/31 |
| Unresolved credits are tracked by memory | `備註：蘭子補課8/17or 8/31` |
| Payment methods vary | Line Pay, LINE Bank, 現金, 按摩器代購 |
| Reconciliation is by reported last-5 digits | `並告知帳後五碼` |

### 1.2 Requirements from the user

1. Teacher-only for now; may open to other studios later, but not designed for it yet.
2. LINE stays the student-facing channel. Students change nothing.
3. A LINE bot monitors the group chat and creates **draft** records she confirms.
4. The bot is **not customer-facing** in phase 1, but will be later.
5. Interest in receiving payment through the LINE ecosystem (LINE Pay or wire).
6. She does this admin work **on her phone**. Mobile-first is a hard constraint.
7. Attendance recorded as expected-roster plus a one-tap "didn't come" mark.
8. A monthly package grants exactly one makeup, usable in another weekday's class.

### 1.3 Non-goals

- Student self-service booking, cancellation, or login.
- Multi-tenant / multi-teacher support.
- Automated bank reconciliation (see §7 — not available to this user).
- Payroll, invoicing, 發票, or accounting export.
- Capacity limits and waitlists. Classes run 4–6 people in a private studio; she can see the room.

## 2. Repository starting point

`ganesha` is a bare Phoenix 1.8.13 scaffold, single commit, no schemas or migrations.

- Elixir `~> 1.17`, Phoenix 1.8.13, LiveView 1.2, Bandit, `ecto_sqlite3`, `:req`, Tailwind v4.
- `mix.exs` vendors daisyUI, which `AGENTS.md` explicitly forbids.
  **Decision: remove the daisyUI dependency** and hand-write Tailwind components. Keeping
  both would establish exactly the second convention the project rules prohibit.

## 3. Domain model

Nine tables. The diagrams file graphs the eight core entities; `student_aliases` is a
lookup table hanging off `Student` and is omitted there for clarity.

### 3.1 Entities

**Package** — the price list. `name`, `kind :monthly | :drop_in | :trial`,
`price_per_class`, `included_makeups`, `active`.
Seeded as 月課程 (400/class, 1 makeup), 單堂 (450, 0), 體驗 (450, 0).

**Slot** — a recurring weekly class. `weekday`, `start_time`, `end_time`,
`default_style`, `label`, `active`. Four rows today.

**Session** — one real date. `slot_id`, `date`, `style`, `state :scheduled | :cancelled`,
`cancel_reason`. `style` overrides the slot default, which is what makes `*流動8/28`
representable.

**Student** — `line_user_id` (unique, nullable), `display_name`, `active`.
Keyed on `line_user_id` because it is stable for the lifetime of the LINE account;
display names change freely and are never the key. Nullable because a cash-only student
may never appear in LINE.

**StudentAlias** — `student_id`, `alias`, unique on `alias`. A separate table rather than
an `{:array, :string}` column: it does not depend on how `ecto_sqlite3` encodes array
types, and it gives the parser an indexed lookup instead of a scan. Her students appear
under mixed names (Lulu, Kelly, 莉芸, 素容), so alias matching is the parser's main
identity path before a `line_user_id` is ever linked.

**Purchase** — the money side of a sale. `student_id`, `package_id`, `slot_id` (nullable,
monthly only), `list_price`, `custom_amount` (nullable), `note`.
`payable = custom_amount ?? list_price`.

**Attendance** — the roster row, and the only thing that puts a name on a date.
`session_id`, `student_id`, `kind :enrolled | :makeup | :drop_in | :trial`,
`purchase_id` (nullable), `credit_id` (nullable), `state :expected | :no_show`, `note`.
Unique on `(session_id, student_id)`.

**Credit** — one makeup entitlement. `student_id`, `source :package | :cancellation`,
`origin_purchase_id`, `origin_session_id`, `expires_on` (nullable),
`consumed_by_attendance_id` (nullable).

**Payment** — `purchase_id`, `amount`, `method :line_pay | :line_bank | :cash | :other`,
`state :claimed | :confirmed | :disputed`, `paid_on`, `reported_last5`,
`source :manual | :line_draft`, `note`, `confirmed_at`, `confirmed_by`.

### 3.2 Design decisions and their rationale

**`custom_amount` rather than a discount field.** Her document records final agreed
numbers — 400, 800, 900, 1200 — never deltas. A discount field would force her to compute
a difference she never thinks in. The override is freeform: any integer, above or below
list, zero included. "How much did I comp this month" remains derivable as
`list_price − payable`, so nothing is lost.

**`list_price` is a snapshot.** The package price list will change. History must not mutate
when it does, and storing both values is what makes an override visible rather than silent.

**No `month` column anywhere.** A purchase's period is derived from the dates of its
attendance rows. Cost: monthly reporting joins `purchase → attendance → session`, and a
purchase with zero attendance rows has no period and falls out of monthly reports. Benefit:
a purchase spanning a month boundary needs no special case, and there is no denormalised
field to drift.

**`purchase_id` is Payment's only foreign key.** Because a drop-in is also a purchase,
payment needs neither a nullable FK pair nor a polymorphic association. Student is reached
through the purchase.

**One payment settles one purchase.** If she ever sends one transfer covering two slots,
a `payment_allocations` join table can be added additively. Her August document lists
1200 (Wed) and 800 (Mon) as separate amounts, which is evidence she already settles
per-slot. Revisit if the combined case appears in practice.

**`attendance.purchase_id` is nullable, deliberately.** A makeup has no sale behind it —
it is paid for by a credit. 允一's `無費用，補颱風假` row is exactly this shape.

**調課 and 補課 share one mechanism.** Both are `kind: :makeup` consuming a credit.
宜群's `調8/21` and 蘭子's `補7/10颱風假` differ only in `credit.source` and the note.
One code path, two labels.

**Money is integer TWD throughout.** No floats, no `Decimal`. `payment.amount` is
`NOT NULL`; there is no nullable money in the schema.

**The two 2-class prices become legible.** 素容's 900 is two drop-in purchases at 450;
彩華's 800 is one monthly purchase of two sessions at 400. Under a flat `price` integer
both were arbitrary numbers.

### 3.3 Invariants — enforced in code, not by convention

1. `kind: :makeup` requires a `credit_id` for the **same student**, with
   `consumed_by IS NULL` and (`expires_on IS NULL OR expires_on >= session.date`).
2. Assigning a monthly purchase's sessions mints `package.included_makeups` credits with
   `source: :package`, expiring on the last day of the calendar month of the purchase's
   **earliest session**, evaluated in `Asia/Taipei`. Minting is deferred to session
   assignment rather than purchase creation because a purchase has no month of its own
   (§3.2) — its period exists only once it has attendance rows. Minting is idempotent per
   purchase.
3. Cancelling a session mints one `source: :cancellation` credit per `:enrolled`
   attendance, with `expires_on = NULL`. **Idempotent** — re-running must not duplicate.
4. `state: :confirmed` requires `confirmed_at` and `confirmed_by`. **No code path may
   write `:confirmed`.** Only a human action sets it.
5. Unique `(session_id, student_id)` on attendance.
6. Month boundaries — including credit expiry — are computed in `Asia/Taipei`. Storing
   UTC and expiring on a UTC month boundary would kill a credit eight hours early.

### 3.4 Derived values

- `payable(purchase) = custom_amount ?? list_price`
- `outstanding(student) = Σ payable − Σ amount where state = :confirmed`
  Unconfirmed claims are excluded so "who owes me" never counts money she has not seen.
- `revenue(range) = Σ confirmed payments` joined through attendance dates.
- 起徵點 warning when rolling monthly revenue approaches NT$50,000 (§7.4).

## 4. Phase 1 — the ledger (no LINE integration)

Fully usable standalone. Contexts:

- `Ganesha.Studio` — slots, sessions, session generation for a month, cancellation.
- `Ganesha.People` — students, aliases.
- `Ganesha.Catalog` — packages.
- `Ganesha.Sales` — purchases, payments, balances.
- `Ganesha.Roster` — attendance, credits, makeup consumption.
- `Ganesha.Publishing` — monthly announcement text.

### 4.1 Screens (mobile-first)

1. **Today** — the next/current session's roster; tap to mark no-show; add a drop-in or a makeup.
2. **Month by slot** — sessions for the month, enrolled list, style override, cancel session.
3. **Drafts inbox** — phase 2.
4. **Student** — timeline of purchases, payments, credits, attendance.
5. **Money** — outstanding by student, month revenue, 起徵點 gauge.
6. **Publish** — generated announcement with one-tap copy.
7. **Packages & settings** — price list, bank details, transfer deadline.

Phone-first specifics: bottom navigation; tap targets ≥44px; cards rather than tables;
preset amount chips (400/450/800/900/1200/1600) so she rarely types digits; `push_patch`
routes instead of modals so Back behaves; LiveView streams for rosters and drafts;
Traditional Chinese UI copy.

### 4.2 Publishing

Generates both blocks of her current document: the ✨開課時間表 (per-slot label, 時間,
日期 with `*` style overrides, price line) and the numbered signup list with its 其他
section, followed by the bank footer. Plain text, copied with one tap via a
`Phoenix.LiveView.ColocatedHook` calling `navigator.clipboard` — `AGENTS.md` forbids
inline `<script>`. The template lives in code; bank account, transfer deadline and closing
note live in a `studio_settings` singleton.

The bot never posts this. A group push costs 25 of the 200 free monthly messages (§7.1),
and the bot is not customer-facing.

## 5. Phase 2 — LINE ingestion

The ledger knows LINE exists only through `student.line_user_id`. Deleting the bot would
remove an input pipe and nothing else.

### 5.1 Webhook path

Scoped to `/line/webhook` only, never application-wide:

```
RawBodyPlug          cache untouched bytes into conn.assigns
VerifySignaturePlug  Base64(HMAC-SHA256(channel_secret, raw)) vs x-line-signature,
                     compared with Plug.Crypto.secure_compare/2
Plug.Parsers         body_reader: {RawBodyPlug, :read_cached_body, []}
Controller           insert line_events (unique webhook_event_id) → 200
```

Order is load-bearing: the signature must be computed over raw bytes before `Plug.Parsers`
consumes the body, which is why `body_reader` re-serves the cached copy. Return 200 for the
empty `{"events":[]}` connectivity probe. Guard `event.mode == "active"` before any reply.

**Budget: 200 within 2 seconds.** Nothing but verify-persist-respond happens inline.

### 5.2 Async processing

`line_events.processed_at` plus a `Task.Supervisor` child fired by the controller and a
periodic sweeper that re-picks `processed_at IS NULL`. At-least-once, restart-safe, zero
new dependencies. Oban ships a SQLite engine, but taking that dependency for roughly 30
events per month is not justified, and its SQLite support would need verification first.

### 5.3 Sender resolution

`GET /v2/bot/group/{groupId}/member/{userId}` returns the display name — and works for
members who never friended the Official Account, on an unverified account. Match order:
`line_user_id` → `aliases` → unattributed draft she assigns by hand.

`source.userId` is absent for LINE-for-PC senders, so `sender_user_id` is nullable and an
unattributed draft is a valid state, not an error.

### 5.4 Parser

`Ganesha.Line.Parser`, a pure function `String.t() → [suggestion]`. It **never rejects**:
unrecognised text yields `kind: :unknown` and is discarded; low-confidence text yields a
draft she edits. Real inputs it must survive, from her document:

```
2.Lulu （Line pay 1200元）
（2堂課，Line pay 900元）
Line pay已付 按摩器代購
蘭子補課8/17or 8/31
宜群（調8/21)
現金400元
```

**Draft** — `line_event_id`, `kind :payment | :signup | :makeup_request | :unknown`,
`student_id`, `parsed` map, `confidence`, `state :pending | :applied | :discarded`, and
the ledger row produced on apply.

### 5.5 Retention

Raw message text and cached display names purge at 24 hours (§7.2). **Consequence to
accept: a pending draft older than 24 hours keeps its parsed fields but loses the original
sentence**, so the parser's work can no longer be checked against what the student wrote.
This is a policy cost, not a design preference.

The conservative line: purge raw text at 24h, never store a group member roster at all,
retain only `line_user_id` plus teacher-confirmed ledger facts. The exact scope of "Group
information" in the LINE User Data Policy is undefined by LINE and is recorded as
UNVERIFIED in §8.

### 5.6 Correctness events

- `unsend` → delete the raw text and any **pending** draft derived from it. Never an
  applied one; that is a ledger fact she confirmed.
- `messageEdited` → re-parse and replace the pending draft.

Both are required for ledger correctness, not optional polish.

### 5.7 Failure modes

| Condition | Behaviour |
|---|---|
| Signature mismatch | 403, empty body |
| Duplicate `webhook_event_id` | 200, no-op |
| Member profile fetch fails | Draft stays unattributed; sweeper retries |
| Unknown event type | Persisted, ignored |
| Parser finds nothing | `kind: :unknown`, discarded |

### 5.8 Onboarding runbook

Non-code, and the design fails without it:

1. Both channels under **one** provider — user IDs are provider-scoped and cross-provider
   IDs silently no-op.
2. Confirm **no other Official Account** is in her group. Only one is permitted.
3. Allow bot to join group chats **ON** (disabled by default).
4. Use webhook **ON**; webhook URL verified over HTTPS with a CA certificate.
5. Auto-reply **OFF**, Greeting **OFF**, so students never receive robotic replies.
6. Webhook redelivery **ON**.
7. She adds the Official Account as a friend.
8. Disclosure notice posted in Traditional Chinese as a reply to the `join` event.

The disclosure is the one message students will ever see from the bot. It is required by
the LINE User Data Policy and, being a reply, costs nothing.

## 6. Auth, hosting, operations

**Auth** — `mix phx.gen.auth`, registration disabled, her account seeded. Heavy for one
user, but hand-rolled session auth is a known footgun and this guards money records. It
also provides the `current_scope` plumbing Phoenix 1.8 expects. A LIFF entry point can
later verify a LINE ID token at one route and mint a normal session.

**Hosting** — Fly.io, single machine in `nrt` (Tokyo, closest to Taiwan), volume-backed
SQLite. Single machine avoids SQLite replication entirely.

**Backup** — Litestream continuous replication to S3-compatible storage. A nightly dump's
24-hour RPO is unacceptable for payment records when the alternative is one sidecar.

**Time** — store UTC, render `Asia/Taipei`. See invariant 6.

## 7. Payments: what is and is not possible

Researched against primary sources. The blockers are **documented absences**, not gaps in
research.

### 7.1 LINE messaging economics

- 輕用量 plan is NT$0/month with 200 free messages.
  [TW pricing](https://tw.linebiz.com/faq/oa-price/message-price-list/)
- **Reply** messages consume no quota; push/multicast/broadcast/narrowcast do.
  [pricing](https://developers.line.biz/en/docs/messaging-api/pricing/)
- Push counts **per recipient**: one push into a 25-person group costs 25 messages, so
  8 per month on the free tier, with no overage available on 輕用量.
- Inbound webhooks have no documented cap.

A reply-only bot watching one group costs NT$0/month indefinitely. **This is the cost
model, not an optimisation:** never push to the group.

### 7.2 Data policy

Storing LINE User Information other than internal identifiers beyond 24 hours requires
notifying users, and the policy separately states Friend and Group information must not be
stored beyond 24 hours regardless of notification.
[User Data Policy §3.2.3](https://terms2.line.me/LINE_Developers_user_data_policy?lang=en)

Drives §5.5 and the disclosure notice in §5.8.

### 7.3 Automated reconciliation is unavailable

| Finding | Source |
|---|---|
| LINE Bank (824) publishes no API and is absent from all three Taiwan open-banking phases | [FISC](https://www.fisc.com.tw/tc/business/detail.aspx?caid=219ca7b9-2ae0-4fee-aedb-510430c01771) |
| Only Phase 2 exposes 帳戶餘額/交易明細, and LINE Bank does not participate | FISC (as above) |
| TSP status requires a registered legal entity, per-bank bilateral contracts, ISO 27001, and a TAF-accredited security assessment — impossible for an individual | [FISC TSP](https://www.fisc.com.tw/TSP/) |
| No LINE Pay API reads P2P transfers; the surface is 10 merchant payment-lifecycle endpoints | [LINE Pay](https://developers-pay.line.me/online-api-v3) |
| LINE Bank's transaction alerts are sent by LINE Bank's **own** Official Account into her private chat; one OA's bot can never read another OA's messages | [receiving messages](https://developers.line.biz/en/docs/messaging-api/receiving-messages/) |
| LINE Pay merchant: the no-統編 個人商店 tier is closed to online business except 餐飲 with a storefront; class packages are 遞延性商品 requiring consent plus 履約保證; the free QR tier receives no API credentials at all | [LINE Pay FAQ](https://pay.line.me/portal/tw/customer/faq?categoryId=regacct) |

**Therefore payment is a claim until a human confirms it.** The bot removes transcription,
identity lookup, and arithmetic — but not the verification glance at her bank app. The
honest product description is "draft capture plus fast confirmation", never "automatic
reconciliation". Invariant 4 encodes this in the schema.

`帳後五碼` is a lookup hint for a human, not a receipt: five digits prove nothing about
amount, date, or sender. No unique constraint on `reported_last5`; instead flag repeats as
a likely double-post or copy-paste error.

### 7.4 Tax threshold

The 營業稅 起徵點 for 勞務 is NT$50,000/month from 114年 onward. At NT$20–30k she is below
it with roughly 40% headroom; crossing it obliges 稅籍登記, and registering late means
back-assessment from day 1 of that month.
[財政部](https://www.mof.gov.tw/singlehtml/384fb3077bb349ea973e7fc6f13b6974?cntId=3b62d010b3ce4e3997ad920bbb27220d)

A rolling-revenue warning is cheap and genuinely protective. Included in phase 1.

### 7.5 The one real automation path — deferred

ECPay 個人賣家 with ATM 虛擬帳號: verified on 身分證 only, **no 統一編號 required**,
documented server-to-server callback, full sandbox before applying, ~NT$15.75 per payment
(1%, NT$15 floor, +5% tax). [ECPay](https://developers.ecpay.com.tw/?p=2878)

Buys genuine machine-verified confirmation, at the cost of moving collection off the P2P
rail, ~NT$390/month at her volume, 10-day settlement, and a public sales page (ECPay
rejects LINE-group URLs). Deferred until the manual glance proves painful. The ledger is
built so an `:ecpay` payment source could self-confirm while LINE claims stay
human-confirmed — one ledger, two source types, two trust levels.

## 8. Risks and unverified items

| Item | Status | Mitigation |
|---|---|---|
| Another Official Account already in her group | **Blocks phase 2 entirely** | Verify before building phase 2 |
| Exact scope of "Group information" in the data policy | UNVERIFIED — LINE never defines it | Store no group roster; keep only `line_user_id` |
| LiveView WebSockets inside a LIFF WebView | UNVERIFIED by LINE docs | LIFF is deferred; phase 1 is a normal browser app |
| Parser accuracy on unseen phrasing | Expected to be imperfect | Never rejects; she edits. Confidence surfaced in the UI |
| 24h purge removes evidence behind stale drafts | Accepted cost | Surface draft age prominently; triage promptly |
| Oban's SQLite engine | Not verified | Avoided; sweeper instead |
| Revenue crossing NT$50,000/month | Real business risk | 起徵點 warning in phase 1 |

## 9. Testing strategy

Narrow and load-bearing. Not a coverage exercise.

1. **Parser** — table-driven against the real strings in §5.4. Adversarial human input, and
   a wrong parse writes to a ledger.
2. **Credit invariants** — the three-part consumption guard; idempotent cancellation;
   expiry computed on a Taipei month boundary.
3. **Payment trust boundary** — assert no code path produces `:confirmed`.
4. **Signature verification** — known-good HMAC vector, plus rejection on a mutated body.
5. **Idempotency** — the same `webhook_event_id` twice yields one event and one draft.
6. **Smoke** — one LiveView test per screen, asserting on element IDs per `AGENTS.md`.

## 10. Build order

1. Remove daisyUI; establish layout and Tailwind component conventions.
2. `phx.gen.auth`, registration disabled, seeded account.
3. Catalog, People, Studio (slots, sessions, month generation).
4. Sales (purchases, payments) and the Money screen.
5. Roster (attendance, credits) — invariants 1–3, 6.
6. Publishing.
7. Fly deploy, Litestream, then use it for one real month with manual entry.
8. Phase 2: webhook, parser, drafts inbox, retention sweep, onboarding runbook.

Phase 1 must survive a real month before phase 2 begins. The parser's value depends on the
ledger being correct first.
