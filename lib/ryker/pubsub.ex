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

  def subscribe(topic) when is_binary(topic), do: Phoenix.PubSub.subscribe(@pubsub, topic)

  def unsubscribe(topic) when is_binary(topic), do: Phoenix.PubSub.unsubscribe(@pubsub, topic)

  # Normalized to :ok so the per-event broadcast_* functions can be handed to
  # `Repo.after_commit/1` without each appending a bare :ok. Broadcasts are
  # fire-and-forget; no caller branches on delivery.
  def broadcast(topic, payload) when is_binary(topic) do
    _ = Phoenix.PubSub.broadcast(@pubsub, topic, payload)
    :ok
  end
end
