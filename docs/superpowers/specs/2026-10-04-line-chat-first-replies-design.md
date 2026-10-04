# LINE assistant: chat-first replies

Supersedes §6.2 (cards) and the lookup-card parts of §3.1 in
`2026-10-02-line-teacher-assistant-design.md`. Everything else in that spec stands.

## Problem

Chat replies copy the web app: lookup answers arrive as Flex cards with the
same rows, totals and labels as the matching page, Draft cards are compact web
forms (title, detail lines, before→after table, "Open on web"), and the model's
text above them repeats what the cards show. A LINE reply should read like the
studio assistant talking, with the full detail left to the web.

## Decisions

1. **Who writes the words.** Fixed code-written text for anything that changes
   data (Draft confirmations, where amounts must be exact). Model-written text
   for answers to questions.
2. **Confirmations** are a minimal Flex card per Draft: one sentence plus
   確認 / 捨棄. Several Drafts sit in one carousel. Buttons stay in the chat
   history.
3. **No "Open on web"** anywhere in the chat.
4. **Before→after** appears only when it says something useful, usually money
   owed, written into the sentence.
5. **Answers to questions are text only.** No lookup cards, no `show_card`.

## 1. Task contract

Every `:change` task replaces `describe/2` with:

```elixir
@callback summary(parsed :: map(), locale :: String.t()) :: String.t()
```

- The sentence is the request in chat voice, with every fact needed to
  confirm: who, what, when, how much, and the money effect when there is one.
- Built from `parsed` only; never queries current data (same rule as
  `describe/2`).
- No `%{` placeholders and no markdown.

`Assistant.draft_summary(draft, locale) :: String.t()` replaces
`Assistant.describe_draft/2`. A Draft of a retired kind falls back to its kind
name.

### Sentences per task (zh-TW; illustrative, not pinned)

| Task | Sentence |
|---|---|
| `record_payment` | 記錄 Amy 付款 NT$3,200（LINE Pay，10/3）— 欠款 NT$3,200 → 0 |
| `confirm_payment` | 確認收到 Amy 的 NT$800（LINE Pay，10/2） |
| `override_price` | Amy 的月課程改收 NT$1,500（原價 NT$1,600） |
| `enroll` | 幫 阿花 報名十月 週三 19:00 基礎，4 堂 NT$1,600 |
| `book_one_off` | 幫 Lulu 排 10/8 週四 19:00 基礎 單堂 NT$400 |
| `book_makeup` | 用 Lulu 的補課券排 10/8 週四 19:00 基礎補課 |
| `set_no_show` | 把 阿花 10/2 晚課記為缺席；取消時：阿花 10/2 晚課改回會來 |
| `cancel_session` | 停課 10/8 週四 19:00 基礎（颱風假），3 人各得一張補課券 |
| `set_session_style` | 10/8 週四 19:00 改上 陰瑜伽（原本 哈達） |
| `add_session` | 加開 10/10 週六 10:00–11:15 流動 |
| `add_slot` | 新增每週一 09:30 基礎，十月 4 堂 |
| `copy_month` | 照十月排十一月課表，共 16 堂 |
| `add_student` | 新增學生 Amy（別名 小艾） |
| `save_package` | 新增方案 晚間單堂 NT$450／堂；或 月課程 每堂 NT$400 → NT$420 |

## 2. Draft card, outcomes, reply packing

**Draft card** (`Line.Cards.draft_bubble/2`): Flex bubble.
- Body: the summary sentence, wrapped, normal size. No header, rows, table or
  link.
- Footer: 確認 (primary) and 捨棄; postbacks unchanged
  (`action=confirm&draft_id=N`, `action=discard&draft_id=N`).
- Alt text: the summary sentence.

**Carousel**: ≤ 12 bubbles; the rest counted in the text (`more_drafts`).

**Turn reply order** (`Line.Reply.build/3`): model text → Draft carousel →
`ask_teacher` quick-reply chips. At most 3 messages.

**Postback outcome**: one text message.
- Applied: 好，已記錄：<summary>
- Discarded: 已捨棄：<summary>
- Failed: 沒辦法套用：<summary>（<readable reason>）
- `already_handled` / `replaced` / `not_found`: unchanged.

**Readable failure reasons** (`Line.Labels`, both locales):

| Reason | zh-TW |
|---|---|
| `:purchase_changed`, `:attendance_changed`, `:package_changed`, `:payment_not_claimed`, `:credit_already_consumed`, `:session_cancelled`, any other `*_changed` | 資料已經變了，請再跟我說一次 |
| `:not_found` | 找不到相關資料了 |
| `%Ecto.Changeset{}` | the changeset's errors via `format_changeset_errors/1` |
| anything else | 系統沒辦法完成這筆 |

The raw reason stays in `draft.failure_reason` and in the model's history line.

**History line** the model reads: `[草稿 #41 待確認] <summary>`; outcomes:
`[已確認] 草稿 #41 <summary>`. No lookup card lines.

**Group push** (`GroupDraftNotifier`): intro text + the same carousel.

**Dashboard**: pending row shows the summary sentence.

## 3. Lookups and prompts

`answer/2` returns `%{data: String.t()}`, plus `choices` / `draft_ids` where
used today. Removed: the `card` key, the `show_card` tool field,
`Turn.cards`.

- `data` is model-facing: compact facts plus the ids later tool calls need
  (session ids, attendance ids, credit ids, purchase ids).
- `pending_drafts` keeps returning `draft_ids` (they become the carousel); its
  `data` becomes a count plus one summary per Draft.

**Teacher prompt** reply rules replace the show_card rule:
- A few short lines of plain chat in her language; lead with the answer.
- Long lists: top ~5, then how many more, and offer the rest.
- Copy numbers, names and dates exactly as tools returned them; never compute
  totals a tool didn't give.
- After proposing a change, one line saying there is something to confirm;
  never repeat the card's details.
- No markdown (`**`, `#`, tables).

Student and group prompts unchanged.

## 4. Removal

- `Line.Cards`: session/month/money/student/credits renderers and their
  history lines. Keeps `draft_bubble/2`, `draft_carousel/2`,
  `history_line({:draft, _}, _)`.
- `Line.Labels`: labels used only by removed cards (`card_*`, `open_web`,
  `roster_count`, `schedule_title`, `revenue`, `owes`, …). Keep labels used by
  outcomes, chips, push intro and dashboard.
- Lookup payload builders (`Lookup.session_payload/3`, money/student/credits
  payloads).
- `Turn.cards`, `show_card` in `Agent` and `Tasks.add_shared_fields/2`, the
  card half of `Reply`.
- `describe/2` on every task and `Assistant.describe_draft/2`, plus helpers
  that only fed them.
- `mix line.validate_cards`: draft bubble + choices only.

## 5. Testing

- Each change task: `summary/2` in `zh-TW` and `en` contains the key facts
  (name, amount, date, money before→after where relevant) and no `%{`.
  Wording is not pinned.
- `Cards`: bubble body is the summary; footer postbacks are exactly confirm
  and discard for that Draft id.
- `Reply`: text → carousel → chips; 12-bubble cap and `more_drafts` count.
- Outcomes: `*_changed` failures render the readable reason, never the atom.
- Lookups: no `card` key; tool schemas have no `show_card`.
- `line_smoke.exs`: Draft card checked by postbacks; next-session answer is
  text with no Flex message.
- Real model: one run each of `line_real_turn.exs` (payment, enroll, no_show)
  and `line_real_questions.exs`; answers are short, accurate, markdown-free.
