# Ganesha — LINE chat interface with AI integration

**Date:** 2026-09-11
**Status:** design
**Relation to prior work:** replaces the "Phase 2 — LINE ingestion" plan in
`docs/superpowers/specs/2026-09-03-yoga-studio-ledger-design.md` §5. That plan's
webhook plumbing, sender-resolution, retention, and correctness-event decisions
(§5.1, §5.3, §5.5, §5.6, §5.7) are reused unchanged here; only the extraction
mechanism (regex parser → AI agent) and the addition of a teacher-facing chat
surface are new. Phase 1 (the ledger app: Catalog/People/Studio/Sales/Roster/
Reporting/Publishing) is unaffected — this is a new subsystem consuming it, not
a replacement for it.

## 1. Scope

**In scope:**
- A LINE Official Account that sits in the teacher's existing student group,
  listening only — it never sends a message into the group.
- The same Official Account, reachable by the teacher 1:1, as a conversational
  AI assistant that can answer questions from ledger data and propose draft
  records for her to confirm.
- One unified AI agent (tool-calling loop) powering both surfaces — no separate
  regex parser and no separate "extraction-only" code path.
- Drafts (payment, attendance, makeup) proposed by the agent from either
  surface, confirmed or discarded inline in the LINE 1:1 chat via quick-reply/
  postback. Nothing the agent produces becomes a real ledger fact without that
  explicit human tap.

**Explicitly out of scope (deferred):**
- A student-facing chat experience. Noted for a later phase via LINE Business
  chat; this design does not build it, and the group thread never sends
  outbound messages to students under this design.
- LIFF, ID-token login, or any new end-user (student) authentication surface.
- Automated payment reconciliation (ECPay or otherwise) — unaffected finding
  from the original spec's §7.3/§7.5, unchanged here.
- Multi-tenant support.

## 2. Architecture overview

```
LINE Platform
   │ webhook POST (signed)
   ▼
POST /line/webhook  (public route, dedicated pipeline — not :browser or :api)
   RawBodyPlug            caches untouched bytes into conn.assigns
   VerifySignaturePlug    Base64(HMAC-SHA256(channel_secret, raw)) vs
                          x-line-signature, Plug.Crypto.secure_compare/2
   Plug.Parsers           body_reader: {RawBodyPlug, :read_cached_body, []}
   Controller             dedupe by webhook_event_id → insert LineEvent → 200
   │
   ▼ (Oban job per event — decouples the 2s webhook ack from LLM latency)
Ganesha.Assistant.ProcessEventWorker
   routes by event.source.type and sender:
     source.type == "group"                      → group thread
     source.type == "user" AND
       source.userId == configured teacher id     → teacher thread
     anything else (unknown 1:1 sender, room, …)  → ignored, event marked processed
   │
   ▼
Ganesha.Assistant.Agent  — one engine, reused for both threads
   loads thread history + system prompt
   → tool-calling loop (capped iterations)
       → Ganesha.Assistant.Provider (behaviour) → configured adapter
       → tool_calls dispatched to Ganesha.Assistant.Tools.{Read, Draft, Reply}
   │
   ├─ group thread:   Reply tool not registered. Output = any drafts created
   │                  + updated thread memory. Bot never posts into the group.
   └─ teacher thread:  Reply tool registered. Text reply sent via LINE Reply
                       API (falls back to Push if the reply token expired).
                       A created draft is sent as a quick-reply template with
                       確認 / 修改 / 捨棄 actions.
   │
   ▼ (postback tap)
POST /line/webhook  (postback event, same pipeline)
   → apply or discard the draft by calling the same context functions a human
     action in the app already calls:
       Sales.record_payment/1 + Sales.confirm_payment/2
       Roster.create_attendance/1
       Roster.book_makeup/3
```

**Async via Oban, not a hand-rolled supervisor.** The original Phase 2 plan
avoided Oban because its SQLite engine was unverified at the time. It is no
longer unverified: `Oban.Engines.Lite` is already configured
(`config/config.exs`) and running `Ganesha.Reporting.CloseMonthWorker` in
production. Reusing it here removes an entire hand-rolled supervisor+sweeper
component and gets retry/backoff for free — which matters now that
"processing an event" means an LLM call that can fail or time out, not a pure
function.

**Webhook budget unchanged.** Still verify → persist → `200` inline, nothing
else; §5.1 and §5.7's failure-mode table (signature mismatch → 403, duplicate
`webhook_event_id` → 200 no-op, unknown event type → persisted and ignored)
apply unchanged.

## 3. Data model

Four new tables. None of `line_events`, threads, messages, or drafts exist
yet (verified against `priv/repo/migrations/`).

**`line_events`**
| Column | Type | Notes |
|---|---|---|
| `webhook_event_id` | `:string`, unique | dedupe key |
| `source_type` | `:string` | `"group" \| "user" \| "room"` |
| `source_id` | `:string` | group id or LINE user id |
| `raw_type` | `:string` | `"message" \| "postback" \| "unsend" \| "messageEdited" \| ...` |
| `payload` | `:map` (JSON) | raw event; purged per §6 |
| `processed_at` | `:utc_datetime`, nullable | set by the Oban worker |

**`assistant_threads`**
| Column | Type | Notes |
|---|---|---|
| `source_type` | `:string` | `"group" \| "teacher"` |
| `source_id` | `:string` | LINE group id, or the constant teacher user id |

One row per thread; `unique_index([:source_type, :source_id])`.

**`assistant_messages`**
| Column | Type | Notes |
|---|---|---|
| `thread_id` | references `assistant_threads` | |
| `role` | `:string` | `"user" \| "assistant" \| "tool"` |
| `content` | `:string` | purged per §6 for group-thread rows |
| `tool_calls` | `:map` (JSON), nullable | structured tool-call record |

This is the conversation history replayed to the LLM provider each turn.

**`drafts`** — same shape as the original spec's Draft entity (§5.4);
producer changes, schema does not.
| Column | Type | Notes |
|---|---|---|
| `thread_id` | references `assistant_threads` | which conversation produced it |
| `kind` | `:string` | `"payment" \| "attendance" \| "makeup_request" \| "unknown"` |
| `student_id` | references `students`, nullable | unattributed is a valid state |
| `parsed` | `:map` (JSON) | structured proposal, e.g. `%{amount: 1200, method: "line_pay", purchase_id: 42}` |
| `confidence` | `:float` | surfaced to the teacher |
| `state` | `:string` | `"pending" \| "applied" \| "discarded"` |
| `applied_record_type` / `applied_record_id` | nullable | polymorphic ref to the ledger row created on apply |

## 4. Group thread — unified agent, bounded blast radius

Every group message (excluding the teacher's own posts, and excluding
anything predating the bot joining, per the original onboarding runbook §5.8)
triggers one `Ganesha.Assistant.Agent` run against the group thread. The
agent has the full tool set:

- **Read tools** — `find_student`, `student_balance`, `today_roster`,
  `upcoming_sessions`, `student_history`, thin wrappers around existing
  `Ganesha.People` / `Ganesha.Sales` / `Ganesha.Roster` / `Ganesha.Studio`
  query functions.
- **Draft tools** — `propose_payment_draft`, `propose_attendance_draft`,
  `propose_makeup_draft`, each inserting a `drafts` row in `state: "pending"`.
  These never call `Sales.confirm_payment/2` or any state-mutating context
  function directly — only draft-table inserts.

Guardrails specific to this thread:

1. **No reply/send tool is registered when `thread.source_type == "group"`.**
   This is enforced by the tool dispatcher never including it in the
   provider's tool list for this thread — a code-level constraint, not a
   prompt instruction. It reproduces the original design's "reply-only,
   never push to the group" economics (§7.1) as a hard invariant: the bot
   has no code path to send group messages at all, so it cannot even
   accidentally spend the 200-message/month budget on the group.
2. **Iteration cap** (6 tool calls) per message, bounding cost and latency
   against adversarial or rambling input.
3. **The only externally observable effect of processing a group message is
   a `pending` draft.** No code path from a draft to a real ledger fact
   exists outside the teacher's explicit postback confirm (§5). This is the
   same trust boundary the original design already enforced for payments
   (`payment.state = "confirmed"` never written by code) — a successful
   prompt-injection attempt via a student's message is therefore bounded to
   "creates a spurious draft she rejects," never a real ledger or messaging
   side effect.

## 5. Teacher's 1:1 thread

Same agent engine, same tool set, plus a `Reply` tool available only on this
thread. The teacher's messages to the Official Account (source.type ==
`"user"`, sender matching the configured teacher LINE user id) run through
the identical agent loop as the group thread; the difference is purely which
tools are registered.

- The assistant's natural-language answer is sent via LINE's Reply API
  (free, using the incoming webhook's reply token), falling back to Push if
  the reply token has expired by the time the LLM call completes. Push cost
  is a single recipient per message — negligible against the 200/month free
  tier at this volume (one user, occasional conversations).
- When the agent creates a draft, the reply includes a LINE quick-reply/
  template message with 確認 / 修改 / 捨棄 actions. Tapping posts back
  through the same `/line/webhook` route; the controller applies (state →
  `"applied"`, dispatch to the matching `Sales`/`Roster` function) or
  discards (state → `"discarded"`) the draft. This postback tap **is** the
  human confirmation action already required by the ledger's payment-trust
  invariant — architecturally identical to tapping confirm in the app UI,
  just over a different transport.
- 修改 (edit) opens the existing app's draft/edit surface (not a new LINE-side
  editing flow) — she edits the same way she would edit any ledger record
  today, then confirms there.

## 6. AI provider abstraction

```elixir
defmodule Ganesha.Assistant.Provider do
  @callback complete(messages :: [map()], tools :: [map()], opts :: keyword()) ::
              {:ok, %{text: String.t() | nil, tool_calls: [map()]}} | {:error, term()}
end
```

One concrete adapter to start, chosen at build time and swappable via config
— a thin `:req`-based HTTP client either way, per `AGENTS.md`'s HTTP client
guidance. The agent loop, tool dispatch, both threads, and the test suite
(mocked provider) are all provider-agnostic; picking or changing the vendor
is a config change, never a rewrite.

## 7. Retention & privacy

- **Group thread** — unchanged from the original spec's §5.5/§7.2: raw
  message text (`line_events.payload` and `assistant_messages.content`
  sourced from group input) purged at 24h. `drafts.parsed` (structured, not
  raw text) survives past purge — same accepted cost as before: a pending
  draft older than 24h keeps its parsed fields but loses the sentence that
  produced it. No group member roster is ever stored, matching the original
  §5.8 disclosure-notice requirement (LINE User Data Policy §3.2.3).
- **Teacher's own thread** — retained without the 24h purge. This is a
  deliberate design decision, not an oversight: her own conversation with
  the assistant is her operating the product — functionally equivalent to
  typing a note into the app's UI, not "Friend/Group information" of a third
  party under LINE's User Data Policy. It sits in the same category as her
  existing typed `Payment.note` field, which the app already retains
  indefinitely. If this reading proves wrong on further legal review, adding
  a purge job for the teacher thread is a one-line change — flagged here in
  the same spirit as the original spec's own §8 UNVERIFIED items, not
  presented as settled law.

## 8. Safety guardrails (recap)

1. No code path may set `payment.state = "confirmed"` — existing invariant,
   unchanged; applies equally to agent-produced drafts.
2. The group thread has no send/reply tool, enforced in the tool dispatcher.
3. Tool-call iteration cap per agent run (both threads).
4. A postback confirm/discard is the only path from `draft` to a real ledger
   row; 修改 routes to the existing in-app edit flow, never a LINE-side write.
5. Only the configured teacher LINE user id gets the teacher thread's
   privileged tool set (Reply tool, and treated as a trusted principal); any
   other 1:1 sender is ignored, not silently given assistant access.

## 9. Testing strategy

- **Agent loop and tool dispatch** — tested against a mocked
  `Ganesha.Assistant.Provider` (fixed tool-call sequences in, assert on
  which tools were dispatched and the resulting `drafts`/`assistant_messages`
  rows). No live LLM calls in the suite.
- **Group-thread safety** — a test asserting the group thread's tool
  registry contains no send/reply tool, and that a mocked provider
  attempting to call one is rejected rather than silently ignored.
- **Signature verification, idempotent `webhook_event_id`** — same as the
  original spec's §9 (known-good HMAC vector plus rejection on a mutated
  body; the same event id processed twice yields one `line_events` row).
- **Postback applies/discards a draft correctly** — including the
  payment-trust-boundary assertion (no code path produces `:confirmed`
  outside `Sales.confirm_payment/2` called from a human action).
- **Unsend/edit correctness events** (§5.6, reused) — `unsend` deletes the
  raw text and any *pending* draft derived from it, never an applied one;
  `messageEdited` re-runs the agent and replaces the pending draft.

## 10. Build order

1. `line_events`, `assistant_threads`, `assistant_messages`, `drafts`
   migrations; webhook route + RawBodyPlug/VerifySignaturePlug/controller
   (direct build of the original §5.1 design, source-type routing added).
2. `Ganesha.Assistant.Provider` behaviour + a mock adapter; `Agent` tool-
   calling loop tested end-to-end against the mock, no real LINE or LLM
   calls yet.
3. Read tools, then draft tools, wrapping existing `People`/`Sales`/
   `Roster`/`Studio` context functions.
4. Teacher 1:1 thread wired to a real LINE Reply/Push send + real provider
   adapter — lowest risk, single trusted user, easiest to validate manually.
5. Group thread wired in last, behind the safety guardrails in §8, tested
   against the original spec's real message corpus (§5.4) plus adversarial
   inputs for the prompt-injection bound in §4.3.
6. Onboarding runbook — reuse the original spec's §5.8 checklist unchanged
   (single Official Account in the group, webhook on, auto-reply/greeting
   off, disclosure notice on `join`).

## 11. Risks and unverified items

| Item | Status | Mitigation |
|---|---|---|
| Teacher-thread retention not being "Friend/Group information" under LINE's policy | UNVERIFIED — LINE does not define this boundary | Documented in §7 as a considered call; one-line purge job available if wrong |
| LLM latency exceeding the LINE reply-token window on the teacher thread | Expected occasionally | Push fallback; negligible quota cost at this volume |
| Prompt injection via group messages reaching draft tools | Accepted, bounded | No send tool in group context; draft-only, human-confirmed apply path (§4.3, §8) |
| Parser accuracy moving from deterministic regex to LLM extraction | Behavior change, not a regression risk per se | Same "never rejects, confidence surfaced" contract as the original parser; tested against the same real-string corpus (§9) |
| Another Official Account already in her group | Blocks this design entirely, same as original Phase 2 | Verify before building (carried over from original §8) |
