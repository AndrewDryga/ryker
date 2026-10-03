defmodule Ryker.Operator.FailureDismissals do
  @moduledoc """
  Failures a person left as they are (Andrew, 2026-10-03: "how do I hide the alert if I want to
  leave it and not be annoyed by having a failure pending forever?").

  Leaving one records its kind and reference and when it last changed. Failures stops listing it
  until it changes again: a later change is a new failure worth seeing. Nothing about the failure
  itself changes. A failure that ends where it lives is left by ending it there instead (a
  learning batch dropped, an incident room or a request closed), and needs no row here.
  """

  import Ecto.Query

  alias Ryker.Operator.FailureDismissal
  alias Ryker.Repo

  @doc "Leaves one failure, as it was when it last changed, on `actor_ref`'s behalf."
  @spec leave(String.t(), String.t(), DateTime.t(), String.t()) ::
          {:ok, FailureDismissal.t()} | {:error, term()}
  def leave(kind, ref, %DateTime{} = failure_updated_at, actor_ref)
      when is_binary(kind) and is_binary(ref) and is_binary(actor_ref) do
    %FailureDismissal{
      failure_updated_at: failure_updated_at,
      kind: kind,
      left_at: Repo.now!(),
      left_by: actor_ref,
      ref: ref
    }
    |> Repo.insert(
      on_conflict: {:replace, [:failure_updated_at, :left_at, :left_by]},
      conflict_target: [:kind, :ref]
    )
  end

  def leave(_kind, _ref, _failure_updated_at, _actor_ref), do: {:error, :invalid_failure}

  @doc """
  The rows not left, of `rows` (each with `kind`, `ref` and `updated_at`): a row a person left
  shows again once it has changed since.
  """
  @spec reject_left([map()]) :: [map()]
  def reject_left([]), do: []

  def reject_left(rows) do
    left = left(rows)
    Enum.reject(rows, &left?(&1, left))
  end

  @doc "When a person left this failure as it is now, or nil."
  @spec left_at(map()) :: DateTime.t() | nil
  def left_at(row) do
    left = left([row])

    if left?(row, left), do: Map.fetch!(left, {row.kind, row.ref}).left_at
  end

  defp left(rows) do
    keys = rows |> Enum.map(&{&1.kind, &1.ref}) |> Enum.uniq()
    kinds = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    refs = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    from(dismissal in FailureDismissal,
      where: dismissal.kind in ^kinds and dismissal.ref in ^refs
    )
    |> Repo.all()
    |> Map.new(&{{&1.kind, &1.ref}, &1})
  end

  defp left?(row, left) do
    case Map.get(left, {row.kind, row.ref}) do
      %FailureDismissal{failure_updated_at: at} ->
        is_nil(row[:updated_at]) or DateTime.compare(row.updated_at, at) != :gt

      nil ->
        false
    end
  end
end
