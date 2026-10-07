defmodule Ryker.PubSubTest do
  @moduledoc """
  Topic names belong to the context that owns the change, and every broadcast
  waits for its commit (`Ryker.Repo.after_commit/1`). A module that reached
  for Phoenix.PubSub itself chose its own topic and its own moment: Settings,
  Credentials, the Slack names cache and the bundled worker's problem watcher
  each did until 2026-09-26, and two of them broadcast on a global topic every
  open page redrew for.
  """
  use ExUnit.Case, async: true
  alias Ryker.PubSub.AliasDispatcher

  @root Path.expand("../..", __DIR__)

  test "only Ryker.PubSub talks to Phoenix.PubSub" do
    offenders =
      Path.wildcard(Path.join(@root, "lib/**/*.ex"))
      |> Enum.reject(&(&1 == Path.join(@root, "lib/ryker/pubsub.ex")))
      |> Enum.filter(&(File.read!(&1) =~ "Phoenix.PubSub"))
      |> Enum.map(&Path.relative_to(&1, @root))

    assert offenders == []
  end

  test "a broadcast reaches the subscribers of its topic and no other" do
    :ok = Ryker.PubSub.subscribe("pubsub-test:one")
    assert :ok = Ryker.PubSub.broadcast("pubsub-test:one", {:changed, 1})
    assert :ok = Ryker.PubSub.broadcast("pubsub-test:two", {:changed, 2})
    assert_received {:changed, 1}
    refute_received {:changed, 2}

    :ok = Ryker.PubSub.unsubscribe("pubsub-test:one")
    :ok = Ryker.PubSub.broadcast("pubsub-test:one", {:changed, 3})
    refute_received {:changed, 3}
  end

  # A worker command's caller waits on it, then goes on to other work in the
  # same process, often a polling worker that logs a message it did not expect.
  # A result announced while it was unsubscribing must not follow it there.
  test "a message on its way to a subscription that ended is dropped, not delivered late" do
    topic = "pubsub-test:alias"
    alias = Ryker.PubSub.subscribe_alias(topic)
    assert :ok = Ryker.PubSub.broadcast_to_aliases(topic, {:settled, 1})
    assert_received {:settled, 1}

    # A broadcast that had already found the subscription, delivered after it ended.
    :ok = Ryker.PubSub.unsubscribe_alias(topic, alias)
    AliasDispatcher.dispatch([{self(), alias}], self(), {:settled, 2})
    assert :ok = Ryker.PubSub.broadcast_to_aliases(topic, {:settled, 3})
    refute_receive {:settled, _late}, 50
  end
end
