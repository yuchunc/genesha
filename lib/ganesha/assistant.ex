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
  alias Ganesha.{Roster, Sales}

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
        %Thread{} |> Thread.changeset(%{source_type: source_type, source_id: source_id}) |> Repo.insert()
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
    with {:ok, purchase_id} <- fetch_purchase_id(draft),
         payment_attrs = Map.put(draft.parsed, "purchase_id", purchase_id),
         {:ok, payment} <- Sales.record_payment(payment_attrs),
         {:ok, payment} <- Sales.confirm_payment(payment, confirmed_by) do
      mark_applied(draft, "Ganesha.Sales.Payment", payment.id)
    end
  end

  def apply_draft(%Draft{state: "pending", kind: "attendance"} = draft, _confirmed_by) do
    case Roster.create_attendance(draft.parsed) do
      {:ok, attendance} -> mark_applied(draft, "Ganesha.Roster.Attendance", attendance.id)
      {:error, _} = error -> error
    end
  end

  def apply_draft(%Draft{state: "pending", kind: kind} = draft, _confirmed_by)
      when kind in ["makeup_request", "unknown"] do
    mark_applied(draft, nil, nil)
  end

  def apply_draft(%Draft{state: state}, _confirmed_by) when state != "pending", do: {:error, :not_pending}

  def discard_draft(%Draft{state: "pending"} = draft), do: draft |> Draft.state_changeset("discarded") |> Repo.update()
  def discard_draft(%Draft{}), do: {:error, :not_pending}

  defp fetch_purchase_id(%Draft{parsed: %{"purchase_id" => id}}) when not is_nil(id), do: {:ok, id}
  defp fetch_purchase_id(%Draft{}), do: {:error, :missing_purchase_id}

  defp mark_applied(draft, record_type, record_id) do
    draft |> Draft.apply_changeset(record_type, record_id) |> Repo.update()
  end
end
