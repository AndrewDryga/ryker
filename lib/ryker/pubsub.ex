defmodule Ryker.PubSub do
  @moduledoc """
  Shared Phoenix.PubSub plumbing. Topic *names*, subscriptions and broadcasts
  are owned by the domain contexts (`Ryker.Episodes.subscribe_episode/1`,
  `Ryker.Ingress.Inbox.subscribe_inputs/0`, …); this module only knows the
  server and the raw operations they compose.

  A context announces a change after it commits, never inside the transaction
  that makes it (`Ryker.Repo.after_commit/1`), so a subscriber that reads what
  it heard about finds it. Payloads carry identities, not rows: a subscriber
  reads the current state through the owning context, which keeps message
  bodies, prompts and credentials off the bus.

  Ryker serves one installation, so topics are not partitioned by account; a
  topic name is an address, never an authorization.
  """
  @pubsub Ryker.PubSub.Server

  @doc "Starts the server, `Ryker.PubSub.Server`, under a supervisor."
  def child_spec(_options), do: Phoenix.PubSub.child_spec(name: @pubsub)

  @doc "Subscribes the calling process to `topic`: `:ok`, or `{:error, reason}`."
  def subscribe(topic) when is_binary(topic), do: Phoenix.PubSub.subscribe(@pubsub, topic)

  @doc "Unsubscribes the calling process from `topic`."
  def unsubscribe(topic) when is_binary(topic), do: Phoenix.PubSub.unsubscribe(@pubsub, topic)

  @doc """
  Sends `payload` to every subscriber of `topic` and answers `:ok`, so a
  context's `broadcast_*` function can be handed to `Repo.after_commit/1`
  as it is. Delivery is fire-and-forget: no caller branches on it.
  """
  def broadcast(topic, payload) when is_binary(topic) do
    _ = Phoenix.PubSub.broadcast(@pubsub, topic, payload)
    :ok
  end

  @doc """
  Subscribes the calling process to `topic` through a process alias, for a
  process that waits on one thing and goes on to other work. What
  `broadcast_to_aliases/2` sends reaches the alias, and once
  `unsubscribe_alias/2` drops it, a message still on its way is discarded by
  the runtime instead of reaching a process that stopped waiting.
  """
  @spec subscribe_alias(String.t()) :: reference()
  def subscribe_alias(topic) when is_binary(topic) do
    alias = :erlang.alias()
    :ok = Phoenix.PubSub.subscribe(@pubsub, topic, metadata: alias)
    alias
  end

  @doc """
  Unsubscribes `alias` from `topic` and drops the alias, so a message still
  on its way is discarded (`subscribe_alias/1`).
  """
  @spec unsubscribe_alias(String.t(), reference()) :: :ok
  def unsubscribe_alias(topic, alias) when is_binary(topic) and is_reference(alias) do
    :ok = Phoenix.PubSub.unsubscribe(@pubsub, topic)
    _active? = :erlang.unalias(alias)
    :ok
  end

  @doc "Sends `payload` to every alias subscribed to `topic` (`subscribe_alias/1`)."
  def broadcast_to_aliases(topic, payload) when is_binary(topic) do
    _ = Phoenix.PubSub.broadcast(@pubsub, topic, payload, __MODULE__.AliasDispatcher)
    :ok
  end

  defmodule AliasDispatcher do
    @moduledoc false
    def dispatch(entries, _from, message),
      do: Enum.each(entries, fn {_pid, alias} -> send(alias, message) end)
  end
end
