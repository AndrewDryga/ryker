defmodule Ryker.GitHub.ProcessingReactionWorker do
  @moduledoc "Reconciles temporary GitHub eyes from durable ingress and Work ownership."
  use Ryker.PollingWorker, lane: :github_processing, interval: :interval_ms
  alias Ryker.Adapter
  alias Ryker.Episodes
  alias Ryker.ErrorDetail
  alias Ryker.GitHub
  alias Ryker.GitHub.{Client, ProcessingReaction, ProcessingReactions}
  alias Ryker.Ingress
  alias Ryker.Options
  alias Ryker.Settings
  require Logger

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl Ryker.PollingWorker
  def setup(options), do: {:ok, options!(options)}

  def options!(options) do
    options =
      Options.normalize!(
        options,
        [:api, :bindings, :interval_ms],
        [],
        "invalid GitHub processing reaction worker configuration"
      )
      |> Map.put_new(:api, Client)
      |> Map.put_new(:bindings, %{})
      |> Map.put_new(:interval_ms, 1_000)

    unless options.interval_ms in 100..60_000 and is_map(options.bindings) and
             Adapter.implements?(options.api,
               ensure_processing_reaction: 5,
               remove_processing_reaction: 5
             ) and
             Enum.all?(options.bindings, &valid_binding?/1),
           do: raise(ArgumentError, "invalid GitHub processing reaction worker configuration")

    options
  end

  defp valid_binding?(
         {name,
          %{
            client: _client,
            repository_full_name: repository,
            repository_id: id,
            ryker_actor_id: actor_id
          }}
       ) do
    Settings.adapter_name?(name) and GitHub.repository_name?(repository) and
      GitHub.id?(id) and GitHub.id?(actor_id)
  end

  defp valid_binding?(_binding), do: false

  @impl Ryker.PollingWorker
  def wake_on(_options), do: [&Ingress.Inbox.subscribe_inputs/0, &Episodes.subscribe_episodes/0]

  @impl Ryker.PollingWorker
  def poll(options) do
    Enum.each(options.bindings, fn {name, binding} ->
      case run_once(name, binding, options.api) do
        {:ok, _written} ->
          :ok

        {:error, reason} ->
          Logger.warning("GitHub processing reaction failed: #{ErrorDetail.detail(reason)}")
      end
    end)

    options.interval_ms
  end

  def run_once(name, binding, api \\ Client) do
    targets = ProcessingReactions.active_targets(name, binding.repository_id)

    with {:ok, _} <- ProcessingReactions.reconcile(name, binding, targets),
         do: deliver_due(name, binding, api, 10, 0)
  end

  defp deliver_due(_name, _binding, _api, 0, written), do: {:ok, written}

  defp deliver_due(name, binding, api, remaining, written) do
    case ProcessingReactions.claim_next(name, binding) do
      {:ok, nil} ->
        {:ok, written}

      {:ok, reaction} ->
        result = deliver(reaction, binding, api)

        with {:ok, _} <- ProcessingReactions.settle(reaction, result),
             {:ok, _} <- result do
          deliver_due(name, binding, api, remaining - 1, written + 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver(%ProcessingReaction{desired: true} = reaction, binding, api),
    do: ensure_reaction(reaction, binding, api)

  defp deliver(%ProcessingReaction{} = reaction, binding, api) do
    receipt =
      if reaction.reaction_id,
        do: {:ok, reaction.reaction_id},
        else: ensure_reaction(reaction, binding, api)

    case receipt do
      {:ok, id} ->
        with :ok <-
               api.remove_processing_reaction(
                 binding.client,
                 binding.repository_full_name,
                 reaction.comment_kind,
                 reaction.comment_id,
                 id
               ),
             do: {:ok, nil}

      # A deleted comment cannot keep displaying its processing indicator.
      {:error, {:github_api_error, status, _body}} when status in [404, 410] ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_reaction(reaction, binding, api) do
    api.ensure_processing_reaction(
      binding.client,
      binding.repository_full_name,
      reaction.comment_kind,
      reaction.comment_id,
      binding.ryker_actor_id
    )
  end
end
