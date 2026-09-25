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

    admit_more!(episode, "The failing host is nomad-hvn05 and the job is tolgee-postgres-metrics")
    admit_more!(episode, "Still looking into it")

    digest = RoutingDigests.fetch(episode.id)

    assert digest.objective =~ "Investigating something in production"
    assert digest.latest_development =~ "Still looking into it"
    assert digest.search_text =~ "nomad-hvn05"
    assert digest.search_text =~ "tolgee-postgres-metrics"
    assert digest.input_count == 3
  end

  test "identifiers become indexed anchors only when a retained input actually named them" do
    episode =
      admit!(
        "digest:anchors",
        "Run https://app.terraform.io/app/SME-Blitz/blitz-infra/runs/run-TT4LiosRo6Eh8Rnq failed"
      )

    digest = RoutingDigests.fetch(episode.id)
    assert digest.anchor_keys != []

    assert RoutingDigests.anchor_keys([
             "https://app.terraform.io/app/SME-Blitz/blitz-infra/runs/run-TT4LiosRo6Eh8Rnq"
           ]) -- digest.anchor_keys == []

    assert RoutingDigests.anchor_keys(["https://app.terraform.io/app/Other/other/runs/run-ZZZ"]) --
             digest.anchor_keys ==
             RoutingDigests.anchor_keys(["https://app.terraform.io/app/Other/other/runs/run-ZZZ"])
  end

  test "coverage advances with each admitted input and records every contributing conversation" do
    episode = admit!("digest:coverage", "Database is unavailable", channel_ref: "CDEVOPS")
    first = RoutingDigests.fetch(episode.id)
    assert first.conversation_refs == ["slack:TROUTE:CDEVOPS"]
    assert first.covered_through_sequence == 1

    admit_more!(episode, "Replica recovered", channel_ref: "CALERTS")
    second = RoutingDigests.fetch(episode.id)

    assert second.conversation_refs == ["slack:TROUTE:CALERTS", "slack:TROUTE:CDEVOPS"]
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
        workspace_ref: "TROUTE"
      })

    input
  end
end
