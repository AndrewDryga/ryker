defmodule Ryker.Episodes.RoutingDigestsTest do
  use Ryker.DataCase, async: true

  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, RoutingDigests}
  alias Ryker.Ingress.Input
  alias Ryker.Slack.Input, as: SlackInput

  @now ~U[2026-09-11 08:00:00.000000Z]

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

  test "a digest reports coverage rather than pretending to be current" do
    episode = admit!("digest:stale", "Database is unavailable")
    digest = RoutingDigests.fetch(episode.id)
    document = RoutingDigests.document(digest, DateTime.add(@now, 3 * 24 * 60 * 60, :second))

    assert document["covered_through"] == DateTime.to_iso8601(digest.covered_through_at)
    assert document["freshness"] == "stale"
    assert document["input_count"] == 1

    fresh = RoutingDigests.document(digest, DateTime.add(@now, 60, :second))
    assert fresh["freshness"] == "current"
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
