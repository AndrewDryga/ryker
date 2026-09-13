defmodule Ryker.Ingress.Projections do
  @moduledoc false

  alias Ryker.Ingress.Input
  alias Ryker.Publication.Followups
  alias Ryker.State.Behaviors

  @spec observe(Input.t(), String.t()) :: :ok | {:error, term()}
  def observe(%Input{} = input, input_ref) when is_binary(input_ref) do
    with {:ok, _assignment_count} <- Behaviors.observe_input(input, input_ref),
         {:ok, _followup_count} <- Followups.observe_input(input) do
      :ok
    end
  end

  def observe(_input, _input_ref), do: {:error, {:invalid_ingress_projection, :input}}

  @doc """
  Records the inspection-only standing-rule inventory for one accepted input.

  Called after input custody has committed. The result is deliberately
  discarded: losing this evidence costs a diagnosis, and failing the input
  would cost the answer the operator asked for.
  """
  @spec observe_rules(Input.t(), String.t()) :: :ok
  def observe_rules(%Input{} = input, input_ref) when is_binary(input_ref) do
    _evidence = Behaviors.record_rule_inventory(input, input_ref)
    :ok
  end

  def observe_rules(_input, _input_ref), do: :ok
end
