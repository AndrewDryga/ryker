defmodule Ryker.Evals.Runtime do
  @moduledoc """
  The isolated transports a model-world evaluation needs.

  Built from the evaluation environment and code defaults alone: an eval never
  reads the installation's product settings, so it cannot acquire a production
  repository, destination or grant by running beside one. The state-tool
  capability set is the shipped default, which is what the recorded scenario
  catalogs were generated against; a mismatch is reported rather than papered
  over.
  """

  alias Ryker.{Bootstrap, Defaults}
  alias Ryker.StateTools.Capabilities

  @type world :: %{
          gateway: map(),
          state_tools: map(),
          state_tools_endpoint: String.t(),
          state_tools_secret: Ryker.Secret.t()
        }

  @doc "The worker gateway and state tools an isolated world evaluation serves."
  @spec world() :: {:ok, world()} | {:error, atom()}
  def world do
    # Only what the world uses: the whole bootstrap demanded a database URL, a
    # credential key and a console listener an eval never touches (2026-10-04
    # review).
    case Bootstrap.worker_gateway!() do
      nil ->
        {:error, :model_world_gateway_not_configured}

      gateway ->
        token = Ryker.Secret.new(Bootstrap.secret!(:state_tools))

        state_tools = %{capabilities: Capabilities.default(), token: token}

        {:ok,
         %{
           gateway:
             gateway
             |> Map.merge(Defaults.fetch!(:coop_worker_gateway))
             # Bodies the worker transfers, as the installation keeps them; one
             # store per shard, which is one gateway port.
             |> Map.put(
               :body_root,
               Path.join([
                 Bootstrap.storage_root!(),
                 "worker-bodies",
                 Integer.to_string(gateway.port)
               ])
             )
             |> Map.put(:checkpoint_key, Ryker.Secret.new(Bootstrap.checkpoint_key!())),
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
