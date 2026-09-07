defmodule Ganesha.Reporting.CloseMonthWorker do
  @moduledoc """
  Closes the most recently elapsed month, if it isn't closed yet.

  Runs daily rather than exactly at the month boundary. Idempotent by
  construction: running it twice in a day, or missing a day, is harmless
  — any successful run during month M closes M-1. The recovery window is
  one calendar month: if no run succeeds for a whole month, that month's
  predecessor is never closed and there is no backfill path to recover it.
  """
  use Oban.Worker, queue: :default

  alias Ganesha.Clock
  alias Ganesha.Reporting

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    last_month = Date.shift(Date.beginning_of_month(Clock.today()), month: -1)

    if is_nil(Reporting.get_closed_month(last_month)) do
      {:ok, _} = Reporting.close_month(last_month)
    end

    :ok
  end
end
