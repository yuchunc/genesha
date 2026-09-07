# Ganesha — UI design system

**Date:** 2026-09-06
**Status:** built
**Supersedes:** the Phoenix scaffold styling (zinc + emerald + orange + sky + amber + purple + stone — seven palettes, no system)

## 1. Subject, audience, job

**Audience: Taiwan local yoga studios, and their students.**

The operator is a studio owner-teacher in Taipei running a handful of recurring
weekly classes for 4–6 people each, doing the admin on her phone between LINE
messages. The first studio is a solo teacher; the design is not built for
multi-tenant use (the domain spec rules that out) but it must not read as one
person's private notebook either, because the next studio to use it is a
different studio.

Students are the second half of the audience, and they never log in. Per the
domain spec, LINE stays the student-facing channel — so the students' entire
experience of this product is **one block of text pasted into a LINE group**.
That makes the Publish screen a real design surface rather than a debug view,
and it is treated as one: the announcement is previewed the way a student will
receive it, and the studio's private roster block is styled so it can never be
mistaken for the message students see.

The operator's job is not analytics. It is three questions, in this order:

1. Who is coming to the next class, and did anyone not show?
2. Who owes the studio money?
3. Whose makeup credit is about to expire?

The app replaces a hand-kept document. So it has to read as **at least as
trustworthy and legible as that document**, and be faster to use.

Consequences for tone: studio-professional Traditional Chinese using the
vocabulary local studios actually use — 堂數, 補課, 單堂, 體驗, 月課程 — never
personal shorthand, and never translated Western SaaS ("Dashboard", "Submit").
A control says what happens: 「確認收到」, not 「儲存」.

## 2. Where the visual language comes from

Two grounded sources, not mood.

**Ganesha the scribe.** The app's namesake broke off his own tusk to use as a pen
and transcribed the Mahabharata without stopping. He is the patron of writing and
the remover of obstacles. A ledger named Ganesha is a scribe's book. This gives the
palette its saffron and its sense of one continuous, unbroken record.

**The 課表 as a physical timetable.** Her whole business is four weekly slots with
3–4 dates each. That is not a feed and not a set of cards — it is a **timetable with
four lanes**. And a roster of 4–6 people is never a scrolling list; it is a small set
of named places.

## 3. Tokens

### Color — 藍染 indigo ink on 青瓷 celadon paper, turmeric accent

| Token | Light | Dark | Role |
|---|---|---|---|
| `paper` | `#EDF0EA` | `#131B2C` | ground — pale celadon, a Taiwanese ceramic glaze |
| `paper-raised` | `#F7F9F4` | `#1B2438` | raised surface |
| `paper-sunk` | `#E2E7DE` | `#0D1420` | inset surface, inputs |
| `rule` | `#C5CFC2` | `#2E3A52` | hairline |
| `rule-strong` | `#A3B0A0` | `#43516E` | emphatic rule |
| `ink` | `#16233F` | `#E4E8EF` | primary text — 藍染 indigo, genuinely blue, not tinted black |
| `ink-soft` | `#4F5F7C` | `#A6B1C4` | secondary text |
| `ink-faint` | `#67748A` | `#7C8899` | tertiary text (4.7:1 on paper) |
| `turmeric` | `#B87513` | `#E0A64A` | the single accent: money, active state |
| `turmeric-ink` | `#8F5A0D` | `#E9B968` | accent as small text (5.9:1) |
| `sindoor` | `#A02A26` | `#E2726A` | correction: cancelled, no-show, overdue — the 朱印 red of a mark made in a book |
| `celadon` | `#416B4F` | `#7FB08D` | settled: confirmed payment, done |

Explicitly rejected: `#F4F1EA` cream with `#D97757` terracotta; near-black with one
acid accent. Turmeric `#B87513` is yellow-orange and dark; it is not terracotta.

### Type

- `--font-display`: `Literata, "Songti TC", "Noto Serif TC", "Source Han Serif TC", serif`
- `--font-ui`: `-apple-system, "PingFang TC", "Noto Sans TC", "Microsoft JhengHei", sans-serif`

Latin first in the display stack, so **numerals get Literata** and **Chinese falls to
Songti TC** — a 宋體, the typeface of printed Chinese books, already on every iOS and
macOS device. Both are high-contrast bookish serifs, so they harmonize. Literata is
self-hosted (`priv/static/fonts/literata-latin.woff2`, 110 KB Latin subset) — no
render-blocking third-party request, and no `<link href>` in the layout, which
`AGENTS.md` forbids.

No CJK webfont: the good ones are 20 MB+ and cannot be subset because student names
are runtime data. The system CJK faces on her phone are excellent and instant.

No monospace anywhere. Tabular alignment comes from `font-variant-numeric: tabular-nums`
on Literata.

Scale — 1.25 major third off 16px, per Bringhurst's default guidance:
13 / 14 / 16 / 20 / 25 / 31 / 39 / 48.

Chinese body text gets `line-height: 1.75` and `letter-spacing: 0.02em`; CJK benefits
from slight tracking where Latin does not. Line length capped at 34rem.

### Layout

Radius has exactly two values and they carry meaning: `2px` for rules, inputs and
chrome (near-square, ledger-like) and `9999px` for kind pills. There is no 16px
"card" radius. There is exactly one shadow in the app, lifting the fixed bottom nav.

## 4. Structural devices — each one encodes information

**The weekday seal (印章).** Every session belongs to one of four weekly slots. Each
slot carries a persistent square seal bearing its weekday glyph — 一 三 四 五 — set
in the display serif. 印章 is the mark of authority in a hand-kept Chinese ledger; here
it means "which class", and it lets her identify a class without reading a word. Four
slots, four seals, the same everywhere.

**The left rule as state.** Not a four-sided border on identical cards: a single 3px
rule down the left edge whose color is the state. `ink` normal, `turmeric` money due,
`sindoor` cancelled or absent, `celadon` settled. Vertical rules also echo the ruling
of a 帳簿.

**Struck-through names.** A no-show in her document would be crossed out, so marking
one strikes the name in sindoor. Ledger vernacular, instantly legible, and the strike
draws across the name in 160ms so the change is visible.

**Money right-aligned in a shared tabular column.** Real ledger behavior. The label
sits after the figure on the same baseline, not above it — a ledger line, not a stat card.

**No numbered markers** except the 報名 signup list on the Publish screen, where her own
document is literally numbered 1..N. Sequence markers appear only where content is a
sequence.

**No icons in content.** Icons appear only in the bottom nav, where they aid
recognition. Chinese labels are already self-describing; heroicons throughout would be
Western SaaS chrome bolted onto a Chinese ledger. This is the accessory removed.

**Motion.** One orchestrated moment: on the dashboard, the revenue figure and the
起徵點 measure fill once on load. Everything else answers an action — the no-show
strike, a form reveal. `prefers-reduced-motion` disables all of it.

## 5. Three dashboard variants

Not three color schemes. Three information architectures answering three different
questions. Routes: `/dashboard` (= `a`), `/dashboard/b`, `/dashboard/c`.

### A — 今日 The Day
*What do I need to do in the next hour?* Single focus. The next session fills the
screen: seal, slot label, time, style, and the roster as named places with state rules.
Money is one quiet line at the bottom.

### B — 四軌 Four Lanes
*How is the month shaped?* The hero is the four-lane timetable — the most
characteristic object in her world. Dates are stations along each lane; the station
mark carries headcount, cancellation and style override. Below it, only the live
obligations: unplaced makeups and empty rosters.

### C — 帳 The Ledger
*Who owes me, and am I near the tax line?* The 起徵點 gauge is a real vertical measure
against a NT$50,000 tick, not a thin progress bar. Then outstanding by student, ranked,
in a tabular column; then confirmed receipts; then expiring credits.

## 6. Plan review — where the first draft was generic

Checked each axis against what a generated page would default to.

- **Palette.** First instinct was warm paper with a clay accent. That is the single
  most recognisable generated-design tell. Moved the ground cooler and greener to
  celadon, and the accent from red-orange to turmeric. Both now trace to the subject:
  ceramic glaze, temple saffron, indigo dye.
- **Type.** First instinct was a Latin display serif with the Chinese left to fall back
  to whatever sans the device has — which throws away the personality of the language
  the entire UI is written in. Named a CJK serif in the display stack so Chinese
  headlines render as 宋體.
- **Cards.** First draft chopped every screen into identical rounded cards with the
  same soft grey shadow. Replaced with the left state rule, which carries information
  the border did not.
- **Money line.** First draft had the default treatment — big number, small label
  above, gradient accent. Removed the gradient, moved the label onto the figure's
  baseline, and let the tabular column do the work.
- **Sequence markers.** Removed everywhere except the one list that is genuinely
  numbered.
