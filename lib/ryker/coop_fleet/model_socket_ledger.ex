defmodule Ryker.CoopFleet.ModelSocketLedger do
  @moduledoc false
  defstruct pending: %{}, active: %{}

  def enqueue(ledger, lane, lease) do
    %{ledger | pending: Map.update(ledger.pending, lane, [lease], &(&1 ++ [lease]))}
  end

  def receive_event(ledger, data) do
    case Jason.decode(data) do
      {:ok, %{"type" => "response.created", "response" => %{"id" => id}} = event}
      when is_binary(id) and byte_size(id) in 1..512 ->
        created(ledger, Map.get(event, "stream_id"), id)

      {:ok, %{"type" => type, "response" => %{"id" => id}}}
      when type in ["response.completed", "response.failed", "response.incomplete"] ->
        completed(ledger, id)

      {:ok, %{"type" => "error"} = event} ->
        # Generic errors have no documented response identity. Closing upstream
        # is the only safe way to retire unresolved creates without guessing.
        {:error, event}

      {:ok, %{"type" => "response.created"}} ->
        :invalid

      {:ok, %{} = _event} ->
        {:ok, ledger, nil}

      _invalid ->
        :invalid
    end
  end

  defp completed(ledger, id) do
    case Map.pop(ledger.active, id) do
      {nil, _active} -> {:ok, ledger, nil}
      {lease, active} -> {:complete, %{ledger | active: active}, {lease, id}}
    end
  end

  defp created(ledger, lane, id) do
    case {Map.has_key?(ledger.active, id), Map.get(ledger.pending, lane, [])} do
      {false, [lease | rest]} ->
        pending =
          if rest == [],
            do: Map.delete(ledger.pending, lane),
            else: Map.put(ledger.pending, lane, rest)

        {:bind, %{ledger | pending: pending, active: Map.put(ledger.active, id, lease)},
         {lease, id}}

      _unmatched ->
        :invalid
    end
  end
end
