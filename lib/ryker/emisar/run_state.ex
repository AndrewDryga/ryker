defmodule Ryker.Emisar.RunState do
  @moduledoc """
  Bounded public projection of an Emisar run supervised by Ryker.

  `review` is the receipt Emisar publishes for a run a human reviewed: the
  rationale its approvers were shown, the trusted command, the recorded votes
  and any explicit override. It is absent for a run policy never gated, and its
  absence is never read as a decision.
  """

  @enforce_keys [
    :action_id,
    :operation_id,
    :pack_ref,
    :run_id,
    :runner_ref,
    :status
  ]
  defstruct @enforce_keys ++ [error_message: nil, review: nil, run_url: nil]

  @nonterminal ~w(pending pending_approval sent running cancelling)
  @terminal ~w(success failed error validation_failed unknown_action cancelled timed_out refused denied)

  @type t :: %__MODULE__{
          action_id: String.t(),
          error_message: String.t() | nil,
          operation_id: String.t(),
          pack_ref: String.t(),
          review: map() | nil,
          run_id: String.t(),
          run_url: String.t() | nil,
          runner_ref: String.t(),
          status: String.t()
        }

  @spec statuses() :: [String.t()]
  def statuses, do: @nonterminal ++ @terminal

  @spec terminal?(t() | String.t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: terminal?(status)
  def terminal?(status) when is_binary(status), do: status in @terminal
  def terminal?(_status), do: false

  @spec valid_status?(term()) :: boolean()
  def valid_status?(status), do: status in @nonterminal or status in @terminal
end
