defmodule Ryker.Operator.FailureDismissals do
  @moduledoc """
  Failures a person left as they are (Andrew, 2026-10-03: "how do I hide the alert if I want to
  leave it and not be annoyed by having a failure pending forever?").

  Leaving one records its kind and reference and how it failed (its summary). Failures stops
  listing it while it fails that way: a retry that fails the same way is not news, and Ryker
  retries some kinds every minute. Failing some other way is a new failure worth seeing. Nothing
  about the failure itself changes. A failure that ends where it lives is left by ending it there
  instead (a learning batch dropped, an incident room or a request closed), and needs no row here.
  The choice is audit history, so it is kept to the audit horizon; a failure still failing the
  same way then shows once more.
  """

  alias Ryker.Operator.{FailureDismissal, FailureDismissalQuery}
  alias Ryker.Repo

  @doc "Leaves one failure, failing as `summary` says, on `actor_ref`'s behalf."
  @spec leave(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, FailureDismissal.t()} | {:error, term()}
  def leave(kind, ref, summary, actor_ref)
      when is_binary(kind) and is_binary(ref) and is_binary(summary) and is_binary(actor_ref) do
    %FailureDismissal{
      failure_summary: summary,
      kind: kind,
      left_at: Repo.now!(),
      left_by: actor_ref,
      ref: ref
    }
    |> Repo.insert(
      on_conflict: {:replace, [:failure_summary, :left_at, :left_by]},
      conflict_target: [:kind, :ref]
    )
  end

  def leave(_kind, _ref, _summary, _actor_ref), do: {:error, :invalid_failure}

  @doc """
  How many failures people left, by kind. Each kind's list reads that many more rows, so the ones
  left never crowd an open one off it.
  """
  @spec counts() :: %{String.t() => non_neg_integer()}
  def counts do
    FailureDismissalQuery.count_by_kind()
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The rows not left, of `rows` (each with `kind`, `ref` and `summary`): a row a person left
  shows again once it fails some other way.
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

    kinds
    |> FailureDismissalQuery.of_kinds_and_refs(refs)
    |> Repo.all()
    |> Map.new(&{{&1.kind, &1.ref}, &1})
  end

  defp left?(row, left) do
    case Map.get(left, {row.kind, row.ref}) do
      %FailureDismissal{failure_summary: summary} ->
        row.summary == summary

      nil ->
        false
    end
  end
end
