defmodule Responder.Ingress.Projections do
  @moduledoc false

  alias Responder.Ingress.Input
  alias Responder.Publication.Followups
  alias Responder.State.Behaviors

  @spec observe(Input.t(), String.t()) :: :ok | {:error, term()}
  def observe(%Input{} = input, input_ref) when is_binary(input_ref) do
    with {:ok, _assignment_count} <- Behaviors.observe_input(input, input_ref),
         {:ok, _followup_count} <- Followups.observe_input(input) do
      :ok
    end
  end

  def observe(_input, _input_ref), do: {:error, {:invalid_ingress_projection, :input}}
end
