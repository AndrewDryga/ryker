defmodule Ryker.Embeddings.WorkerTest do
  # The embeddings worker keeps a vector beside each request's digest so
  # routing can search by meaning (`Ryker.Embeddings.Worker`). It writes a
  # vector only for the text it read, and leaves the rest waiting when the
  # server fails.
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.Embeddings.Worker
  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, RoutingDigest, RoutingDigests}
  alias Ryker.Ingress.Input
  alias Ryker.Slack.Input, as: SlackInput

  @now ~U[2026-09-30 08:00:00.000000Z]

  setup do
    Repo.delete_all(RoutingDigest)
    :ok
  end

  test "every request without a vector gets one, then the worker has nothing to do" do
    checkout = admit!("Checkout returns 502 on the cart page")
    database = admit!("pgsql-prod-01 is unreachable")
    test = self()

    embed = fn texts, options ->
      send(test, {:asked, texts, options[:model]})

      {:ok,
       Enum.map(texts, fn text -> if text =~ "Checkout", do: [1.0, 0.0], else: [0.0, 1.0] end)}
    end

    assert Worker.embed_next(options(embed)) == {:ok, 2}
    assert_received {:asked, texts, "bge-m3"}

    assert Enum.sort(texts) == [
             "Checkout returns 502 on the cart page",
             "pgsql-prod-01 is unreachable"
           ]

    assert vector(checkout) == {[1.0, 0.0], "bge-m3"}
    assert vector(database) == {[0.0, 1.0], "bge-m3"}
    assert Worker.embed_next(options(embed)) == :idle
  end

  test "a request whose text changed while its vector was computed keeps waiting for the new one" do
    episode = admit!("Checkout returns 502 on the cart page")

    embed = fn texts, _options ->
      Repo.update_all(from(digest in RoutingDigest, where: digest.episode_id == ^episode.id),
        set: [updated_at: DateTime.add(@now, 60, :second)]
      )

      {:ok, Enum.map(texts, fn _text -> [1.0, 0.0] end)}
    end

    assert Worker.embed_next(options(embed)) == {:ok, 0}
    assert vector(episode) == {nil, nil}
  end

  test "a server that fails leaves every request waiting" do
    episode = admit!("Checkout returns 502 on the cart page")
    embed = fn _texts, _options -> {:error, :unreachable} end

    assert Worker.embed_next(options(embed)) == {:error, :unreachable}
    assert vector(episode) == {nil, nil}
  end

  defp options(embed), do: %{url: "http://embed.test", model: "bge-m3", embed: embed}

  defp vector(episode) do
    Repo.one!(
      from(digest in RoutingDigest,
        where: digest.episode_id == ^episode.id,
        select: {digest.embedding, digest.embedding_model}
      )
    )
  end

  defp admit!(text) do
    unique = System.unique_integer([:positive])

    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "UALICE"},
        channel_ref: "CDEVOPS",
        content: %{"text" => text},
        event_kind: :message,
        event_ref: "Ev-embed-#{unique}",
        message_ref: "#{1_790_000_000 + unique}.000100",
        occurred_at: @now,
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TEMBED"
      })

    id = Ecto.UUID.generate()

    {:ok, transition} =
      Episodes.apply(%Command.AdmitInput{
        actor_ref: Input.actor_ref(input),
        destination: input.destination,
        episode_id: id,
        episode_key: "embed:#{id}",
        linked_episode_id: nil,
        native_input_id: input.native_input_id,
        occurred_at: @now,
        payload: Input.document(input),
        revision: 1,
        turn_ref: "turn:#{id}"
      })

    _digest = RoutingDigests.fetch(id)
    transition.episode
  end
end
