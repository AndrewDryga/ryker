defmodule Responder.Evals.Runtime do
  @moduledoc """
  The isolated transports a model-world evaluation needs.

  Built from the evaluation environment and code defaults alone: an eval never
  reads the installation's product settings, so it cannot acquire a production
  repository, destination or grant by running beside one. The state-tool
  capability set is the shipped default, which is what the recorded scenario
  catalogs were generated against; a mismatch is reported rather than papered
  over.
  """

  alias Responder.{Bootstrap, Defaults}

  @capabilities [:event_waits, :publication, :schedules]

  @type world :: %{
          gateway: map(),
          state_tools: map(),
          state_tools_endpoint: String.t(),
          state_tools_secret: String.t()
        }

  @doc "The worker gateway and state tools an isolated world evaluation serves."
  @spec world() :: {:ok, world()} | {:error, atom()}
  def world do
    bootstrap = Bootstrap.load!()

    case bootstrap.worker_gateway do
      nil ->
        {:error, :model_world_gateway_not_configured}

      gateway ->
        token = Bootstrap.secret!(:state_tools)

        state_tools = %{
          capabilities: @capabilities,
          ip: bootstrap.state_tools.ip,
          port: bootstrap.state_tools.port,
          token: token
        }

        {:ok,
         %{
           gateway:
             gateway
             |> Map.merge(Defaults.fetch!(:coop_worker_gateway))
             |> Map.put(:checkpoint_key, Bootstrap.checkpoint_key!())
             |> Map.put(:checkpoint_secrets, []),
           state_tools: state_tools,
           state_tools_endpoint: gateway.public_url <> "/v1/state-tools/mcp",
           state_tools_secret: token
         }}
    end
  rescue
    error in ArgumentError -> {:error, {:model_eval_environment_invalid, error.message}}
  end

  @doc "The receive timeout an eval Coop client uses."
  @spec receive_timeout_ms() :: pos_integer()
  def receive_timeout_ms, do: Defaults.fetch!(:coop).receive_timeout_ms
end
