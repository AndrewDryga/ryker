defmodule Ryker.Records.Findings do
  @moduledoc """
  What a person can do with a finding Ryker recorded in an investigation.

  Forget: the finding is wrong or no longer matters. Mark explained: a
  finding Ryker could not explain has been explained since. Either way Ryker
  stops using it: a later request no longer reads it among related outcomes
  (`Ryker.Records.Outcomes`), the investigation's own next turns no longer
  see it, and a case remembered from the investigation leaves it out
  (`Ryker.Memories.Cases`). The finding itself stays in the investigation's
  history and on Findings, as forgotten or marked explained; nothing is
  erased and neither can be undone.

  Andrew, 2026-09-27, of the Findings page: "any actions I should be able to
  do on those?" A finding could only be opened.

  The record's own lifecycle carries it: a forgotten finding is dismissed,
  and one marked explained is answered, as a question a person answered is.
  """

  import Ecto.Query

  alias Ryker.Records
  alias Ryker.Records.Record
  alias Ryker.Repo

  @doc "Forgets a finding Ryker still uses."
  @spec forget(String.t()) :: {:ok, Record.t()} | {:error, term()}
  def forget(id), do: settle(id, :dismissed, fn _payload -> :ok end)

  @doc "Marks a finding Ryker could not explain as explained."
  @spec mark_explained(String.t()) :: {:ok, Record.t()} | {:error, term()}
  def mark_explained(id) do
    settle(id, :answered, fn
      %{"status" => "unexplained"} -> :ok
      _payload -> {:error, :finding_not_unexplained}
    end)
  end

  defp settle(id, status, allowed?) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.transaction(fn -> settle_locked(id, status, allowed?) end)
      :error -> {:error, :finding_not_found}
    end
  end

  defp settle_locked(id, status, allowed?) do
    record =
      Repo.one(
        from(record in Record,
          where: record.id == ^id and record.kind == "finding",
          lock: "FOR UPDATE"
        )
      )

    with {:ok, payload} <- open_payload(record),
         :ok <- allowed?.(payload) do
      set_status!(id, status)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Only a finding Ryker still uses can be settled, and only once.
  defp open_payload(%Record{status: :open, payload: payload}), do: {:ok, payload}
  defp open_payload(%Record{}), do: {:error, :finding_settled}
  defp open_payload(nil), do: {:error, :finding_not_found}

  defp set_status!(id, status) do
    {1, [record]} =
      Repo.update_all(
        from(record in Record,
          where: record.id == ^id,
          update: [set: [status: ^status, updated_at: fragment("clock_timestamp()")]],
          select: record
        ),
        []
      )

    Records.broadcast_record_updated(record)
    record
  end
end
