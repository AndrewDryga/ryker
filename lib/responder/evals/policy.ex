defmodule Responder.Evals.Policy do
  @moduledoc false

  @type authority :: %{name: String.t(), digest: String.t()}
  @type selection :: %{
          required(:subject) => authority(),
          required(:judge) => authority() | nil,
          optional(:baseline) => authority() | nil
        }

  @spec for_kind(map(), :admission | :work | :world) ::
          {:ok, selection()} | {:error, atom()}
  def for_kind(%{model_evals: configuration}, kind)
      when kind in [:admission, :work, :world] do
    no_tools = %{
      name: configuration.no_tools_policy,
      digest: configuration.no_tools_policy_digest
    }

    case kind do
      :world ->
        {:ok,
         %{
           baseline: baseline(configuration),
           subject: %{
             name: configuration.world_policy,
             digest: configuration.world_policy_digest
           },
           judge: no_tools
         }}

      _no_tools_lane ->
        {:ok, %{subject: no_tools, judge: nil}}
    end
  end

  def for_kind(%{model_evals: _configuration}, _kind),
    do: {:error, :invalid_model_eval_kind}

  def for_kind(_configuration, _kind),
    do: {:error, :model_eval_policies_not_configured}

  defp baseline(%{
         world_baseline_policy: name,
         world_baseline_policy_digest: digest
       }),
       do: %{name: name, digest: digest}

  defp baseline(_configuration), do: nil
end
