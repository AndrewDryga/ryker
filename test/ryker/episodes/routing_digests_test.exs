defmodule Ryker.Episodes.RoutingDigestsTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, RoutingDigests}
  alias Ryker.Ingress.Input
  alias Ryker.Slack.Input, as: SlackInput

  @now ~U[2026-09-11 08:00:00.000000Z]

  test "a link is searched as a link, never cut into words" do
    # 2026-09-24: the first search card to show its words listed a Kubernetes
    # docs link cut at 80 characters, plus its tail "bes/" as a word of its own.
    text =
      "Why would a Kubernetes readiness probe keep failing after a deploy? See " <>
        "https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/"

    words = RoutingDigests.search_words(text)
    assert words == ~w(kubernetes readiness probe failing deploy)
    refute Enum.any?(words, &String.contains?(&1, "/"))
    assert RoutingDigests.search_terms(text) == Enum.map_join(words, " | ", &"'#{&1}'")
  end

  test "words that say nothing about the subject are not searched" do
    # Andrew, 2026-09-25, reading that card: "why do we search by 'see'?"
    # Every "see", "please" or "keep" matched unrelated past work as strongly
    # as the words that named the problem, and crowded it out of the list.
    assert RoutingDigests.search_words(
             "Hey, can you please check why checkout keeps timing out since the deploy? Thanks!"
           ) == ~w(checkout timing deploy)

    assert RoutingDigests.search_words("hello there, thanks!") == []
  end

  test "the digest keeps the material middle input that misleading endpoints would hide" do
    # Candidate previews only ever showed the first and latest inputs, so the
    # one message that named the failing resource was invisible to routing
    # whenever an episode had a generic opening and a generic latest update.
    episode = admit!("digest:middle", "Investigating something in production")

    admit_more!(episode, "The failing host is nomad-hst05 and the job is tolgee-postgres-metrics")
    admit_more!(episode, "Still looking into it")

    digest = RoutingDigests.fetch(episode.id)

    assert digest.objective =~ "Investigating something in production"
    assert digest.latest_development =~ "Still looking into it"
    assert digest.search_text =~ "nomad-hst05"
    assert digest.search_text =~ "tolgee-postgres-metrics"
    assert digest.input_count == 3
  end

  test "identifiers become indexed anchors only when a retained input actually named them" do
    episode =
      admit!(
        "digest:anchors",
        "Run https://app.terraform.io/app/SME-Tenant/tenant-infra/runs/run-TobiKjYqqj17v2YB failed"
      )

    digest = RoutingDigests.fetch(episode.id)
    assert digest.anchor_keys != []

    assert RoutingDigests.anchor_keys([
             "https://app.terraform.io/app/SME-Tenant/tenant-infra/runs/run-TobiKjYqqj17v2YB"
           ]) -- digest.anchor_keys == []

    assert RoutingDigests.anchor_keys(["https://app.terraform.io/app/Other/other/runs/run-ZZZ"]) --
             digest.anchor_keys ==
             RoutingDigests.anchor_keys(["https://app.terraform.io/app/Other/other/runs/run-ZZZ"])
  end

  test "coverage advances with each admitted input and records every contributing conversation" do
    episode = admit!("digest:coverage", "Database is unavailable", channel_ref: "CDEVOPS")
    first = RoutingDigests.fetch(episode.id)
    assert first.conversation_refs == ["slack:TDIGESTS:CDEVOPS"]
    assert first.covered_through_sequence == 1

    admit_more!(episode, "Replica recovered", channel_ref: "CALERTS")
    second = RoutingDigests.fetch(episode.id)

    assert second.conversation_refs == ["slack:TDIGESTS:CALERTS", "slack:TDIGESTS:CDEVOPS"]
    assert second.covered_through_sequence > first.covered_through_sequence
    assert DateTime.compare(second.covered_through_at, first.covered_through_at) == :gt
  end

  test "routing reads the work's own name and size from its digest, not its messages again" do
    # The digest's objective was the first message verbatim in 48 of 49 routed
    # candidates, beside a first-message preview that said the same thing.
    episode = admit!("digest:facts", "Database is unavailable")
    admit_more!(episode, "Replica recovered", channel_ref: "CALERTS")

    assert RoutingDigests.document(RoutingDigests.fetch(episode.id)) == %{
             "conversations" => 2,
             "message_count" => 2,
             "title" => nil
           }
  end

  # Candidates were known to routing only by their first and latest messages.
  # The name Work gave the episode travels with its digest, and a new message
  # never erases it.
  test "routing reads the episode's own title beside its source text, and new input keeps it" do
    episode = admit!("digest:title", "Something is off with checkout")
    assert RoutingDigests.document(RoutingDigests.fetch(episode.id))["title"] == nil

    turn_id = Ecto.UUID.generate()

    Repo.update_all(
      from(digest in Ryker.Episodes.RoutingDigest, where: digest.episode_id == ^episode.id),
      set: [title: "Investigate checkout 502s", title_turn_id: turn_id, title_updated_at: @now]
    )

    admit_more!(episode, "It is back to normal now")
    digest = RoutingDigests.fetch(episode.id)

    assert RoutingDigests.document(digest)["title"] == "Investigate checkout 502s"
    assert digest.objective =~ "Something is off with checkout"
    assert digest.title_turn_id == turn_id
  end

  # Andrew, 2026-09-30: routing's search is "rudimentary and won't actually
  # work in real life". Only URLs and UUIDs counted as identifiers, so a
  # message naming the failing host or run found its work by wording alone,
  # behind unrelated running work (the routing search benchmark ranked a
  # shared run ID fifth).
  test "the names operations gives things are identifiers, ordinary words and generic names are not" do
    text =
      "[FIRING:1] CheckoutLatencyHigh on pgsql-prod-01 (run-7f2a1c, v2.14.0) after PR #482, " <>
        "commit 3f9a2b1c, api.example.com at 10:00 with p99 over 2s; utf-8 logs on github.com."

    identifiers = RoutingDigests.identifiers([text])

    for name <-
          ~w(checkoutlatencyhigh pgsql-prod-01 run-7f2a1c v2.14.0 #482 3f9a2b1c api.example.com),
        do: assert(name in identifiers, name)

    for word <- ~w(p99 utf-8 github.com 10:00 firing checkout),
        do: refute(word in identifiers, word)
  end

  test "rebuilding every digest gives existing work the identifiers its messages named" do
    episode = admit!("digest:rebuild", "pgsql-prod-01 is unreachable after run-7f2a1c")

    Repo.update_all(
      from(digest in Ryker.Episodes.RoutingDigest, where: digest.episode_id == ^episode.id),
      set: [
        anchor_keys: [],
        title: "Postgres primary unreachable",
        title_turn_id: Ecto.UUID.generate(),
        title_updated_at: @now
      ]
    )

    assert RoutingDigests.refresh_all() >= 1
    digest = RoutingDigests.fetch(episode.id)

    assert RoutingDigests.anchor_keys(["pgsql-prod-01"]) -- digest.anchor_keys == []
    assert RoutingDigests.anchor_keys(["run-7f2a1c"]) -- digest.anchor_keys == []
    assert digest.title == "Postgres primary unreachable"
  end

  # A request's vector says what its text said (`Ryker.Embeddings`): new text
  # clears it, and the embeddings worker computes it again.
  test "a request's vector is cleared when its text changes" do
    episode = admit!("digest:embedding", "Checkout returns 502 on the cart page")

    Repo.update_all(
      from(digest in Ryker.Episodes.RoutingDigest, where: digest.episode_id == ^episode.id),
      set: [embedding: [0.6, 0.8], embedding_model: "bge-m3", embedded_at: @now]
    )

    admit_more!(episode, "Now it returns 504 instead")

    assert %{embedding_model: nil, embedded_at: nil} = RoutingDigests.fetch(episode.id)

    assert RoutingDigests.embedding_text(RoutingDigests.fetch(episode.id)) =~
             "Checkout returns 502 on the cart page"
  end

  defp admit!(key, text, options \\ []) do
    input = slack_input!(text, options)

    {:ok, transition} =
      Episodes.apply(%Command.AdmitInput{
        actor_ref: Input.actor_ref(input),
        destination: input.destination,
        episode_id: Ecto.UUID.generate(),
        episode_key: key,
        linked_episode_id: nil,
        native_input_id: input.native_input_id,
        occurred_at: input.occurred_at,
        payload: Input.document(input),
        revision: input.revision,
        turn_ref: "turn:#{key}"
      })

    transition.episode
  end

  defp admit_more!(episode, text, options \\ []) do
    occurred_at = DateTime.add(@now, System.unique_integer([:positive, :monotonic]), :second)
    input = slack_input!(text, Keyword.put(options, :occurred_at, occurred_at))

    {:ok, transition} =
      Episodes.apply(%Command.AdmitInput{
        actor_ref: Input.actor_ref(input),
        destination: %{
          conversation_ref: episode.destination_conversation_ref,
          thread_ref: episode.destination_thread_ref,
          transport: episode.destination_transport
        },
        episode_id: episode.id,
        episode_key: episode.key,
        linked_episode_id: episode.linked_episode_id,
        native_input_id: input.native_input_id,
        occurred_at: occurred_at,
        payload: Input.document(input),
        revision: input.revision,
        turn_ref: "turn:#{episode.key}"
      })

    transition.episode
  end

  defp slack_input!(text, options) do
    occurred_at = Keyword.get(options, :occurred_at, @now)
    message_ref = "#{DateTime.to_unix(occurred_at)}.#{System.unique_integer([:positive])}"

    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :app, ref: "A123"},
        channel_ref: Keyword.get(options, :channel_ref, "CDEVOPS"),
        content: %{"text" => text},
        event_kind: :message,
        event_ref: "Ev-#{message_ref}",
        message_ref: message_ref,
        occurred_at: occurred_at,
        revision: 1,
        thread_ref: Keyword.get(options, :thread_ref),
        workspace_ref: "TDIGESTS"
      })

    input
  end
end
