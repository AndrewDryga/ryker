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
end
