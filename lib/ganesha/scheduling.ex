defmodule Ganesha.Scheduling do
  @moduledoc """
  Multi-step schedule changes shared by the web UI and the LINE assistant
  (spec §4.1). Each function runs its steps in one transaction, so a change
  is never left half done.
  """

  alias Ganesha.{Repo, Roster, Studio}
  alias Ganesha.Roster.Credit
  alias Ganesha.Studio.{Session, Slot}

  @doc """
  Cancels a Session and issues one never-expiring Credit to every student
  seated in it. A Session is never left cancelled without its Credits, or
  the reverse. A blank reason returns the cancellation changeset; a database
  failure while issuing Credits raises after rolling the cancellation back.
  """
  @spec cancel_session(%Session{}, String.t() | nil) ::
          {:ok, %{session: %Session{}, credits: [%Credit{}]}} | {:error, Ecto.Changeset.t()}
  def cancel_session(%Session{} = session, reason) do
    Repo.transaction(fn ->
      case Studio.cancel_session(session, reason) do
        {:ok, cancelled} ->
          {:ok, credits} = Roster.issue_cancellation_credits(cancelled)
          %{session: cancelled, credits: credits}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Creates a weekly Slot and its Sessions for `month`. A Slot is never left
  without the month's Sessions it was created for: an invalid or clashing
  Slot returns its changeset, and a database failure while generating the
  Sessions raises after rolling the Slot back.
  """
  @spec add_weekly_class(map(), Date.t()) ::
          {:ok, %{slot: %Slot{}, sessions: [%Session{}]}} | {:error, Ecto.Changeset.t()}
  def add_weekly_class(slot_attrs, %Date{} = month) do
    Repo.transaction(fn ->
      with {:ok, slot} <- Studio.create_slot(slot_attrs),
           {:ok, sessions} <- Studio.generate_month(slot, month) do
        %{slot: slot, sessions: sessions}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end
end
