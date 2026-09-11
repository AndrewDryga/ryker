defmodule Responder.Admission.CandidateSearchTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Admission.{CandidateSearch, CorrelationScope, Ranking}
  alias Responder.Episodes
  alias Responder.Episodes.{Command, CorrelationClaims, Episode}
  alias Responder.Ingress.Input
  alias Responder.Repo
  alias Responder.Slack.ChannelMembership
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.Work.Session

  @workspace "TROUTE"
  @now ~U[2026-09-11 12:00:00.000000Z]

  setup do
    Enum.each(~w(CDEVOPS CALERTS CENGINEERING), &joined!/1)
    :ok
  end

  test "a matching incident in another channel survives more than a hundred nearer distractors" do
    # Admission only ever searched the destination conversation, so the #devops
    # alert and the #alerts alert for one outage became two episodes with two
    # owners. Ranking by location and time alone reproduces that: the match has
    # to survive noise that is newer, nearer and more numerous.
    match =
      episode!("routing:cross-channel",
        channel_ref: "CDEVOPS",
        text: "Postgres primary pgsql-prod-01 is unreachable and replication is stalled"
      )

    for index <- 1..120 do
      channel = if rem(index, 2) == 0, do: "CALERTS", else: "CENGINEERING"

      episode!("routing:distractor-#{index}",
        channel_ref: channel,
        text: "Routine deploy #{index} finished for the marketing website",
        updated_at: DateTime.add(@now, -index, :second),
        thread_ref: if(channel == "CALERTS" and index <= 44, do: "1789000000.000100")
      )
    end

    result =
      search!(
        channel_ref: "CALERTS",
        thread_ref: "1789000000.000100",
        text: "Is pgsql-prod-01 still unreachable? Replication is stalled on the primary."
      )

    offered = Enum.map(result.selected, & &1.episode.id)
    assert match.id in offered
    assert length(offered) <= 20

    assert result.receipt["lanes"]["thread"]["returned"] >= 20
    assert result.receipt["examined"] > 20
    assert result.receipt["omitted"] > 0
    assert result.receipt["cutoff_reason"] =~ "non-local"
  end

  test "one saturated lane does not hide the best evidence another lane found" do
    match =
      episode!("routing:lane-evidence",
        channel_ref: "CDEVOPS",
        text: "Terraform run run-TT4LiosRo6Eh8Rnq needs confirmation for blitz-infra"
      )

    for index <- 1..60 do
      episode!("routing:lane-filler-#{index}",
        channel_ref: "CDEVOPS",
        text: "Terraform plan summary #{index}",
        updated_at: DateTime.add(@now, -index, :second)
      )
    end

    result =
      search!(
        channel_ref: "CDEVOPS",
        text: "The Terraform run run-TT4LiosRo6Eh8Rnq applied successfully for blitz-infra"
      )

    assert match.id in Enum.map(result.selected, & &1.episode.id)
    assert result.receipt["lanes"]["text"]["saturated"]
    assert result.receipt["pool_saturated"] or result.receipt["examined"] <= 200
  end

  test "the exact source item's owner is offered even when every rank feature favours others" do
    owner =
      episode!("routing:owner",
        channel_ref: "CENGINEERING",
        text: "Older revision of this exact card"
      )

    native_input_id = owner_native_input_id(owner)

    for index <- 1..40 do
      episode!("routing:owner-noise-#{index}",
        channel_ref: "CDEVOPS",
        text: "Unrelated active work #{index}",
        updated_at: DateTime.add(@now, -index, :second)
      )
    end

    result =
      search!(
        channel_ref: "CDEVOPS",
        text: "Unrelated active work text",
        native_input_id: native_input_id
      )

    assert [first | _rest] = result.selected
    assert first.episode.id == owner.id
    assert first.source_owner
  end

  test "a proven occurrence identity outranks thread gravity and recency" do
    incident =
      episode!("routing:occurrence",
        channel_ref: "CDEVOPS",
        text: "Checkout latency alert started"
      )

    {:ok, _claim} =
      Repo.transaction(fn ->
        {:ok, claim} =
          CorrelationClaims.claim_in_transaction(%{
            episode_id: incident.id,
            input_ref: "admit:routing:occurrence",
            scope_ref: "slack:#{@workspace}",
            namespace: "slack:app:A123",
            occurrence_ref: "alert:checkout:started:1",
            established_at: @now
          })

        claim
      end)

    nearest =
      episode!("routing:same-thread",
        channel_ref: "CALERTS",
        text: "Checkout latency alert started",
        thread_ref: "1789000500.000100",
        updated_at: @now
      )

    result =
      search!(
        channel_ref: "CALERTS",
        thread_ref: "1789000500.000100",
        text: "Checkout latency alert recovered",
        occurrences: [%{namespace: "slack:app:A123", occurrence_ref: "alert:checkout:started:1"}]
      )

    assert [first, second | _rest] = result.selected
    assert first.episode.id == incident.id
    assert second.episode.id == nearest.id
    assert Ranking.document(first)["occurrence_identity"]
    refute Ranking.document(second)["occurrence_identity"]
  end

  test "private, direct and other-workspace work never appears, not even as a count" do
    Repo.insert!(%ChannelMembership{
      id: Ecto.UUID.generate(),
      workspace_ref: @workspace,
      channel_ref: "CPRIVATE",
      private: true,
      external_shared: false,
      generation: 1,
      status: :joined,
      joined_at: @now
    })

    private =
      episode!("routing:private",
        channel_ref: "CPRIVATE",
        text: "Payroll database credentials rotation"
      )

    direct =
      episode!("routing:direct",
        channel_ref: "D999",
        text: "Payroll database credentials rotation"
      )

    other =
      episode!("routing:other-workspace",
        channel_ref: "CDEVOPS",
        workspace_ref: "TOTHER",
        text: "Payroll database credentials rotation"
      )

    result = search!(channel_ref: "CDEVOPS", text: "Payroll database credentials rotation")
    offered = Enum.map(result.selected, & &1.episode.id)

    refute private.id in offered
    refute direct.id in offered
    refute other.id in offered
    assert result.receipt["examined"] == length(result.selected)
  end

  test "a direct message correlates only inside its own conversation" do
    channel =
      episode!("routing:dm-channel",
        channel_ref: "CDEVOPS",
        text: "Rotate the staging credentials"
      )

    inside =
      episode!("routing:dm-inside", channel_ref: "D777", text: "Rotate the staging credentials")

    result = search!(channel_ref: "D777", text: "Rotate the staging credentials")
    offered = Enum.map(result.selected, & &1.episode.id)

    assert inside.id in offered
    refute channel.id in offered
    assert result.receipt["scope"] == "conversation"
  end

  test "work pinned to another repository is offered as history, never as the same work" do
    pinned =
      episode!("routing:pinned",
        channel_ref: "CDEVOPS",
        text: "Upgrade the API gateway dependency"
      )

    pin!(pinned, "acme/other-service")

    result =
      search!(
        channel_ref: "CDEVOPS",
        text: "Upgrade the API gateway dependency",
        repository_ref: "acme/api-gateway"
      )

    entry = Enum.find(result.selected, &(&1.episode.id == pinned.id))
    assert entry.repository_ref == "acme/other-service"
  end

  test "an episode that also gathered evidence outside this scope is not offered at all" do
    contaminated =
      episode!("routing:contaminated", channel_ref: "CDEVOPS", text: "Shared outage evidence")

    # An origin that a correction placed in a private channel makes the whole
    # episode ineligible; its digest already mixes both audiences.
    Repo.update_all(
      from(digest in Responder.Episodes.RoutingDigest,
        where: digest.episode_id == ^contaminated.id
      ),
      set: [conversation_refs: ["slack:#{@workspace}:CDEVOPS", "slack:#{@workspace}:CPRIVATE"]]
    )

    result = search!(channel_ref: "CDEVOPS", text: "Shared outage evidence")
    refute contaminated.id in Enum.map(result.selected, & &1.episode.id)
  end

  defp search!(options) do
    channel_ref = Keyword.fetch!(options, :channel_ref)
    workspace_ref = Keyword.get(options, :workspace_ref, @workspace)
    thread_ref = Keyword.get(options, :thread_ref)

    destination = %{
      conversation_ref: "slack:#{workspace_ref}:#{channel_ref}",
      thread_ref: thread_ref || "1789009999.000100",
      transport: "slack"
    }

    scope = CorrelationScope.for_destination(destination)

    CandidateSearch.search(%{
      scope: scope,
      transport: "slack",
      thread_ref: destination.thread_ref,
      text: Keyword.fetch!(options, :text),
      native_input_id: Keyword.get(options, :native_input_id, "slack-message:absent"),
      execution_mode: :live,
      repository_ref: Keyword.get(options, :repository_ref),
      occurrences: Keyword.get(options, :occurrences, []),
      candidate_limit: 20,
      history_cutoff: DateTime.add(@now, -30 * 24 * 60 * 60, :second),
      now: @now
    })
  end

  defp episode!(key, options) do
    channel_ref = Keyword.fetch!(options, :channel_ref)
    workspace_ref = Keyword.get(options, :workspace_ref, @workspace)
    thread_ref = Keyword.get(options, :thread_ref)
    occurred_at = Keyword.get(options, :updated_at, DateTime.add(@now, -3600, :second))

    message_ref =
      thread_ref || "#{DateTime.to_unix(occurred_at)}.#{System.unique_integer([:positive])}"

    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :app, ref: "A123"},
        channel_ref: channel_ref,
        content: %{"text" => Keyword.fetch!(options, :text)},
        event_kind: :message,
        event_ref: "Ev-#{key}-#{System.unique_integer([:positive])}",
        message_ref: message_ref,
        occurred_at: occurred_at,
        revision: 1,
        thread_ref: thread_ref,
        workspace_ref: workspace_ref
      })

    id = Ecto.UUID.generate()

    {:ok, transition} =
      Episodes.apply(%Command.AdmitInput{
        actor_ref: Input.actor_ref(input),
        destination: input.destination,
        episode_id: id,
        episode_key: "#{key}:#{id}",
        linked_episode_id: nil,
        native_input_id: input.native_input_id,
        occurred_at: occurred_at,
        payload: Input.document(input),
        revision: 1,
        turn_ref: "turn:#{id}"
      })

    if updated_at = Keyword.get(options, :updated_at) do
      Repo.update_all(from(episode in Episode, where: episode.id == ^id),
        set: [updated_at: updated_at]
      )
    end

    Repo.get!(Episode, id)
  end

  defp owner_native_input_id(episode) do
    Repo.one!(
      from(origin in Responder.Episodes.Origin,
        where: origin.episode_id == ^episode.id,
        select: origin.native_input_id
      )
    )
  end

  defp pin!(episode, repository_ref) do
    Repo.insert!(%Session{
      id: Ecto.UUID.generate(),
      episode_id: episode.id,
      execution_kind: :work,
      policy: "engineering",
      policy_digest: String.duplicate("a", 64),
      repository_ref: repository_ref,
      external_ref: "episode:#{episode.id}:session:1",
      generation: 1,
      create_generation: 1
    })
  end

  defp joined!(channel_ref) do
    Repo.insert!(%ChannelMembership{
      id: Ecto.UUID.generate(),
      workspace_ref: @workspace,
      channel_ref: channel_ref,
      private: false,
      external_shared: false,
      generation: 1,
      status: :joined,
      joined_at: @now
    })
  end
end
