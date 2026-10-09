defmodule Ryker.Work.OperationKeys do
  @moduledoc """
  The idempotency key of each remote operation a Work turn sends to Coop.

  Coop keeps an operation under its key, and a cancellation proves what it
  stopped by comparing keys exactly, so the executor and custody have to build
  each key alike. The formats were copied across five modules, and a drift in
  any copy would have made every stop impossible to settle (2026-10-04
  review). A format is part of what Coop already holds: changing one strands
  the operations sent under the old.
  """

  @spec create(%{id: Ecto.UUID.t(), create_generation: pos_integer()}) :: String.t()
  def create(session), do: "ryker:work:create:#{session.id}:g#{session.create_generation}"

  @spec turn(map()) :: String.t()
  def turn(turn),
    do: "ryker:work:turn:#{turn.id}:g#{turn.submit_generation}:#{turn.submission_fingerprint}"

  @spec checkpoint(map()) :: String.t()
  def checkpoint(turn),
    do: "ryker:work:checkpoint:#{turn.id}:a#{turn.candidate_attempt}:#{turn.candidate_sha256}"

  @doc "The validation verdict's key: `:accept`, or `{:reject, violations}`."
  @spec validate(map(), :accept | {:reject, list()}) :: String.t()
  def validate(turn, verdict) do
    name =
      case verdict do
        :accept -> "accept"
        {:reject, _violations} -> "reject"
      end

    "ryker:work:validate:#{turn.id}:a#{turn.candidate_attempt}:g#{turn.validation_generation}:" <>
      "#{turn.candidate_sha256}:#{name}"
  end

  @spec cancel(Ecto.UUID.t(), pos_integer()) :: String.t()
  def cancel(turn_id, generation), do: "ryker:work:cancel:#{turn_id}:g#{generation}"

  @spec cancel_close(map()) :: String.t()
  def cancel_close(turn), do: cancel_close_prefix() <> "#{turn.id}:g#{turn.cancel_generation}"

  @doc "What every stop's session close key starts with: a session a stop closed on purpose."
  @spec cancel_close_prefix() :: String.t()
  def cancel_close_prefix, do: "ryker:work:cancel-close:"
end
