defmodule Ryker.Coop.CreateOutcome do
  @moduledoc """
  What a Coop session create, or the fence of one, says became of it. Both
  pools that start sessions ahead of time read it the same way
  (`Ryker.Admission.ReadyPool`, `Ryker.Work.ReadyPool`).
  """

  @doc """
  `{:created, coop_session_id}` for a create that made a session, `:absent`
  for one that failed and never will, `:unknown` while it still may.
  """
  @spec of(term()) :: {:created, String.t()} | :absent | :unknown
  def of({:ok, operation}), do: of(operation)

  def of(%{"state" => "succeeded", "resource_type" => "session", "resource_id" => id})
      when is_binary(id),
      do: {:created, id}

  def of(%{"state" => "failed"}), do: :absent
  def of(_operation), do: :unknown
end
