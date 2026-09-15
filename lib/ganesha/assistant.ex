defmodule Ganesha.Assistant do
  @moduledoc """
  Threads, messages, and drafts for the LINE AI chat (group listening and
  the teacher's 1:1 assistant). See
  docs/superpowers/specs/2026-09-11-line-ai-chat-design.md.
  """

  import Ecto.Query, warn: false
  alias Ganesha.Assistant.Draft
  alias Ganesha.Assistant.Message
  alias Ganesha.Assistant.Thread
  alias Ganesha.Repo
  alias Ganesha.{Clock, Roster, Sales}

  alias Ganesha.Assistant.Tools.{
    FindStudent,
    ProposeAttendanceDraft,
    ProposeMakeupDraft,
    ProposePaymentDraft,
    StudentBalance,
    StudentHistory,
    TodayRoster,
    UpcomingSessions
  }

  def get_or_create_thread(source_type, source_id) do
    case Repo.get_by(Thread, source_type: source_type, source_id: source_id) do
      %Thread{} = thread ->
        {:ok, thread}

      nil ->
        %Thread{}
        |> Thread.changeset(%{source_type: source_type, source_id: source_id})
        |> Repo.insert()
    end
  end

  def list_messages(%Thread{} = thread) do
    Repo.all(from m in Message, where: m.thread_id == ^thread.id, order_by: m.id)
  end

  def append_message(%Thread{} = thread, role, content, tool_calls, opts \\ []) do
    %Message{}
    |> Message.changeset(%{
      thread_id: thread.id,
      role: role,
      content: content,
      tool_calls: tool_calls,
      line_message_id: opts[:line_message_id]
    })
    |> Repo.insert()
  end

  def create_draft(%Thread{} = thread, attrs) do
    origin = latest_user_message(thread)

    attrs
    |> Map.put(:thread_id, thread.id)
    |> Map.put(:origin_message_id, origin && origin.id)
    |> then(&(%Draft{} |> Draft.changeset(&1) |> Repo.insert()))
  end

  defp latest_user_message(%Thread{} = thread) do
    Repo.one(
      from m in Message,
        where: m.thread_id == ^thread.id and m.role == "user",
        order_by: [desc: m.id],
        limit: 1
    )
  end

  def get_draft!(id), do: Repo.get!(Draft, id)

  @doc "The full tool roster — identical for the group and teacher threads (spec §2, §4, §5, §8)."
  def tools do
    [
      FindStudent,
      StudentBalance,
      TodayRoster,
      UpcomingSessions,
      StudentHistory,
      ProposePaymentDraft,
      ProposeAttendanceDraft,
      ProposeMakeupDraft
    ]
  end

  @studio_vocabulary """
  只用繁體中文回覆，語氣專業、簡潔，使用瑜珈教室慣用詞彙（堂數、補課、單堂、體驗、
  月課程）。你可以查詢學生、堂數與帳務資料，也可以建立「草稿」（付款、出席、補課
  需求）供她確認 — 你永遠不能把草稿直接變成正式紀錄，只有她本人確認後才算數。
  """

  def teacher_system_prompt do
    "你是師父的課程記帳助理，正在跟她本人對話。" <> @studio_vocabulary
  end

  def group_system_prompt do
    "你正在被動觀察師父的學生群組對話，任何人都看不到你的回覆 — 你唯一能做的事是視
    情況建立草稿供師父之後確認，絕不能、也沒有管道對群組發送任何訊息。" <> @studio_vocabulary
  end

  def apply_draft(%Draft{state: "pending", kind: "payment"} = draft, confirmed_by) do
    with {:ok, purchase_id} <- fetch_purchase_id(draft) do
      Repo.transaction(fn ->
        payment_attrs =
          draft.parsed
          |> Map.put("purchase_id", purchase_id)
          |> Map.put("source", "line_draft")
          |> Map.put_new("paid_on", Date.to_iso8601(Clock.today()))

        with {1, _} <- claim_pending(draft.id),
             {:ok, payment} <- Sales.record_payment(payment_attrs),
             {:ok, payment} <- Sales.confirm_payment(payment, confirmed_by),
             {:ok, updated} <-
               draft
               |> Draft.apply_changeset("Ganesha.Sales.Payment", payment.id)
               |> Repo.update() do
          updated
        else
          {0, _} -> Repo.rollback(:not_pending)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  # A "makeup" attendance draft only ever books through
  # `Roster.book_makeup/3`'s credit-consuming transaction, called from a
  # human action in the app — never through here. Without this guard,
  # confirming such a draft would insert a `kind: "makeup"` attendance row
  # with no credit ever spent, silently granting a free class the student
  # could then also redeem again through the normal in-app flow.
  def apply_draft(
        %Draft{state: "pending", kind: "attendance", parsed: %{"kind" => "makeup"}},
        _confirmed_by
      ) do
    {:error, :makeup_requires_credit}
  end

  def apply_draft(%Draft{state: "pending", kind: "attendance"} = draft, _confirmed_by) do
    # Narrowed to exactly what the tool's schema declares — `parsed` is
    # LLM-authored JSON, and `Attendance.changeset/2` would otherwise cast
    # `state`, `purchase_id`, and `credit_id` straight out of it.
    attendance_attrs = Map.take(draft.parsed, ["session_id", "student_id", "kind", "note"])

    Repo.transaction(fn ->
      with {1, _} <- claim_pending(draft.id),
           {:ok, attendance} <- Roster.create_attendance(attendance_attrs),
           {:ok, updated} <-
             draft
             |> Draft.apply_changeset("Ganesha.Roster.Attendance", attendance.id)
             |> Repo.update() do
        updated
      else
        {0, _} -> Repo.rollback(:not_pending)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def apply_draft(%Draft{state: "pending", kind: kind} = draft, _confirmed_by)
      when kind in ["makeup_request", "unknown"] do
    mark_applied(draft, nil, nil)
  end

  def apply_draft(%Draft{state: state}, _confirmed_by) when state != "pending",
    do: {:error, :not_pending}

  def discard_draft(%Draft{state: "pending"} = draft),
    do: draft |> Draft.state_changeset("discarded") |> Repo.update()

  def discard_draft(%Draft{}), do: {:error, :not_pending}

  defp fetch_purchase_id(%Draft{parsed: %{"purchase_id" => id}}) when not is_nil(id),
    do: {:ok, id}

  defp fetch_purchase_id(%Draft{}), do: {:error, :missing_purchase_id}

  # Atomically claims exclusive rights to apply this draft: a compare-and-set
  # on `state == "pending"` so two concurrent confirms (or a retried Oban job
  # racing a postback tap) can never both proceed past this point. Runs
  # inside the caller's `Repo.transaction/1`, so a later step failing rolls
  # this flip back too — the draft genuinely stays "pending" unless the
  # ledger write it guards actually lands.
  defp claim_pending(id) do
    Repo.update_all(from(d in Draft, where: d.id == ^id and d.state == "pending"),
      set: [state: "applied"]
    )
  end

  defp mark_applied(draft, record_type, record_id) do
    draft |> Draft.apply_changeset(record_type, record_id) |> Repo.update()
  end
end
