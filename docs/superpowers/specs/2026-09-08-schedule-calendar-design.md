# 課表 (schedule) — calendar redesign

**Date:** 2026-09-08
**Status:** proposed

## 1. Problem

`/month` (bottom-nav label "月課表") is a list-only view: for each active
recurring `Slot`, a card lists that slot's `Session` dates in the selected
month. Generating a month's sessions is manual and per-slot (a "建立本月課程"
button per card, calling `Studio.generate_month/2`). There is no calendar
grid anywhere in the app, no way to schedule a one-off (non-recurring) class,
and no UI at all to create a recurring `Slot` — that currently has to happen
outside the web app.

This redesign turns `/month` into 課表: a calendar-first view of the month's
classes, with a way to schedule new classes (single or recurring) and to
bulk-copy a month's recurring classes forward instead of generating them one
slot at a time.

## 2. Data model

### One-off sessions

`Ganesha.Studio.Session` gains a genuinely new case: a session that has no
recurring `Slot` behind it.

- `slot_id` becomes nullable.
- Three new nullable fields: `label` (string), `start_time` (time), `end_time`
  (time). These are populated **only** when `slot_id` is `nil`; a recurring
  session continues to derive its label and time range from its slot.
- `style` stays required on every session regardless of origin — recurring
  sessions already carry it as a per-date override of the slot's default
  style.
- Changeset validation: exactly one of `slot_id` present, or
  `(label, start_time, end_time)` all present. Never both, never neither.
- Every place that currently assumes `session.slot` exists (enroll flow,
  session detail, cancellation) is updated to read label/time from the slot
  when present and from the session's own fields otherwise. The enroll flow
  (`EnrollLive`, slot+month scoped) is unaffected — one-off sessions are never
  reachable through it, since they don't belong to a slot.

### Attendee counts

New `Ganesha.Roster.count_by_session(session_ids)` — one grouped query
(`group_by: session_id, select: count(*)`) returning a
`%{session_id => count}` map. Counts every attendance row regardless of
`state` (a no-show still held a seat). Backs the calendar's per-class
attendee mark without an N+1 query per session across a month.

### Copy-month

New `Ganesha.Studio.copy_month(month)` — inside one transaction, runs
`generate_month/2` for every currently-active `Slot`. Idempotent, same as
today's per-slot generate: dates that already have a session are skipped, so
it never duplicates or overwrites a cancellation or style override. Returns
the total count of sessions created. One-off classes are never copied — they
are inherently non-repeating.

## 3. Page structure

Route stays `/month` and `/month/:year/:month`. Bottom-nav label changes from
"月課表" to "課表" (icon unchanged, `hero-calendar-days`).

Top to bottom:

1. `page_header` — title is the month (e.g. "2026年9月"), actions are the
   existing prev/next chevrons plus the existing quiet "發布課表" button.
   Unchanged from today.
2. A new full-width primary button, "排課", directly below the header and
   above the calendar. Kept out of the header's action row so a fourth
   control doesn't crowd the existing three on a phone width.
3. **Calendar** — a month grid. Each date cell shows the date number and, for
   each session that date, one small turmeric square holding that session's
   attendee count (from `count_by_session/1`); the square is sindoor instead
   of turmeric when the session is cancelled. No weekday glyph on the mark —
   the weekday is already the cell's column. Tapping a date scrolls the
   agenda list below to that date's entry; the calendar itself has no other
   interactive behavior.
4. **Copy-previous-month prompt** — shown when the viewed month has zero
   generated sessions across all active slots while the previous calendar
   month has at least one. A banner: "要複製 <上月> 的課表嗎？" with a
   "複製" button that calls `copy_month/1` for the viewed month and a
   dismiss control. This check is direction-agnostic (it doesn't matter
   whether the user arrived via next/prev/direct link) — tracking navigation
   direction across a full LiveView remount isn't worth the complexity, and
   in practice a studio only ever moves forward into an unpopulated month.
5. **本月名單 shortcut strip** — one compact row per active slot that has
   sessions in the viewed month, e.g. "{印章} {label} · 本月名單 →",
   linking to the existing `EnrollLive` route (`/enroll/:slot_id/:year/:month`,
   unchanged). Kept separate from the agenda list below because enrollment is
   a slot+month-scoped flow (pick from several dates at once), not a
   per-date one.
6. **Agenda list** — one entry per date that has at least one session that
   month, in chronological order. A date with more than one session (e.g. two
   slots overlapping that day) renders one row per session under that date.
   Each session row keeps today's exact interaction, just regrouped from
   per-slot to per-date:
   - The date/time/pills wrapped in `<.link navigate={~p"/sessions/#{id}"}>`
     (unchanged destination and content: style-override pill, cancelled
     pill).
   - The existing `<details>`"調整" disclosure below it, with the same
     style-change and cancel forms as today, unchanged.
   - One-off sessions render with the same row shape; there is no
     "overridden style" pill (there's no slot default to compare against),
     and no slot-seal glyph in place of the (already-scoped) calendar mark.

## 4. Schedule creation flow

New route, e.g. `/month/new`, navigated to by "排課". One LiveView, one page,
a two-way segmented toggle at the top ("單堂" / "固定班次") in the same visual
style as the existing dashboard variant-picker (`a`/`b`/`c` toggle on
`/dashboard`).

- **單堂** (single): date picker, start/end time, label, style. Submits by
  creating a slot-less `Session` directly (the new one-off case above).
- **固定班次** (recurring): the existing weekday, start/end time, style,
  label fields — creates a `Slot`. On success, immediately calls
  `generate_month/2` for the month currently being viewed on `/month`, so the
  new recurring class shows up right away instead of needing an explicit
  first "generate" step.

Either submission returns to `/month/:year/:month` for the month the class
was scheduled into (or the currently-viewed month, for a recurring class).

## 5. Motion

Scoped to the agenda list only, consistent with the app's one-animation-per-
moment stated philosophy (`docs/superpowers/specs/2026-09-06-ui-design-system.md`
§4 "Motion"). Prev/next navigation uses `navigate` (a full LiveView remount,
not `patch`), so there's no live diff to transition between — the same
constraint the existing `.fills-across`/`.fills-up` one-shot mount animations
already work under. A new `.slides-in` CSS class (short fade + small
translateX keyframe) is applied to the agenda list container, added to the
existing `@media (prefers-reduced-motion: reduce)` disable block alongside
`.fills-across`/`.fills-up`/`.struck::after`. No directionality (left vs.
right based on prev/next) — not supportable cleanly across a full remount,
and not asked for beyond "sliding animation."

## 6. Testing

Context-level (`Ganesha.StudioTest`, `Ganesha.RosterTest`):
- `copy_month/1` creates sessions for every active slot, skips a slot that
  already has sessions that month (idempotency), ignores inactive slots.
- One-off `Session.changeset/2` rejects both `slot_id` and
  `label`/`start_time`/`end_time` present together, and rejects neither
  present.
- `count_by_session/1` returns correct per-session counts including no-shows,
  and `0`/absent for a session with no attendance rows.

LiveView-level (`MonthLiveTest`, new schedule LiveView test):
- Calendar renders one mark per session on its date, with the right
  attendee count, sindoor when cancelled.
- Copy-prompt appears only when the viewed month has zero sessions and the
  previous month has some; disappears after copying.
- The new schedule page creates a one-off session via `render_submit` in
  single mode, and a slot (with sessions generated for the current month) in
  recurring mode.
- Agenda list groups by date after navigating between months, including a
  date with two overlapping sessions.

## 7. Out of scope

- Editing a one-off session's own label/time/date after creation (style
  change and cancellation are already covered by the existing forms; renaming
  or rescheduling is unrequested new surface).
- Copying one-off classes forward when copying a month.
- Directional (left/right) slide animation tied to prev vs. next.
