defmodule Ryker.Episodes.CorrectionsTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.Episodes

  alias Ryker.Episodes.{
    AssociationCorrection,
    Command,
    Corrections,
    CorrelationClaims,
    Origins
  }

  alias Ryker.Ingress.Input
  alias Ryker.Repo
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Work.{Session, Turn}

  @now ~U[2026-09-11 12:00:00.000000Z]

  test "a confirmed merge retires the mistaken owner without rewriting its history" do
    # Two channels reported one outage before either knew about the other, so
    # two owners investigated it alone. The correction has to move effective
    # membership without replaying the work each episode already did.
    devops = admit!("merge:devops", channel_ref: "CDEVOPS")
    alerts = admit!("merge:alerts", channel_ref: "CALERTS")
    quiesce!(devops)
    quiesce!(alerts)

    assert {:ok, receipt} =
             Corrections.merge(%{
               action_ref: "operator-action:merge:1",
               actor_ref: "slack:user:UOPERATOR",
               confirmation_ref: "operator-confirmation:merge:1",
               reason: "Both alerts report the same database outage.",
               source_episode_id: alerts.id,
               target_episode_id: devops.id
             })

    assert receipt.status == :recorded
    assert receipt.outcome["moved_input_count"] == 1

    # The moved message is now the target's evidence and answers there.
    assert [moved] = Origins.for_episode(devops.id) |> Enum.filter(& &1.correction_ref)
    assert moved.conversation_ref == "slack:TROUTE:CALERTS"
    assert Origins.for_episode(alerts.id) == []

    {:ok, source} = Episodes.fetch_by_key(alerts.key)
    assert source.state == :cancelled

    # The retired owner keeps every event it recorded; nothing is rewritten.
    assert Enum.map(Episodes.list_events(alerts.key), & &1.kind) == [
             :input_admitted,
             :result_accepted,
             :episode_cancelled
           ]

    assert [%AssociationCorrection{kind: :merge} = correction] = Repo.all(AssociationCorrection)
    assert correction.source_episode_id == alerts.id
    assert correction.target_episode_id == devops.id
    assert moved.correction_ref == correction.id
  end

  test "a merge is denied by name while an answer is still undelivered" do
    # An accepted answer has an immutable destination and idempotency key. A
    # correction that quietly moved its episode would either lose it or send
    # it twice, so custody that cannot be proven safe blocks the correction.
    devops = admit!("denied:devops", channel_ref: "CDEVOPS")
    alerts = admit!("denied:alerts", channel_ref: "CALERTS")
    quiesce!(devops)
    reply_pending!(alerts)

    assert {:error, {:episode_correction_denied, :pending_delivery, details}} =
             Corrections.merge(%{
               action_ref: "operator-action:merge:2",
               actor_ref: "slack:user:UOPERATOR",
               confirmation_ref: "operator-confirmation:merge:2",
               reason: "Both alerts report the same database outage.",
               source_episode_id: alerts.id,
               target_episode_id: devops.id
             })

    assert details[:episode_id] == alerts.id
    assert Repo.all(AssociationCorrection) == []
    assert [%{effective: true}] = Origins.for_episode(alerts.id)
    assert {:ok, %{state: state}} = Episodes.fetch_by_key(alerts.key)
    refute state == :cancelled
  end

  test "a split removes the evidence and the session that saw it" do
    # A message that was never this work joined it anyway. Removing it from the
    # projection is not enough: the warm Coop session still holds the text, so
    # the next turn has to start from a session that never saw it.
    episode = admit!("split:devops", channel_ref: "CDEVOPS")
    quiesce!(episode)
    unrelated = join!(episode, channel_ref: "CDEVOPS", text: "Please review my PR instead")
    bound = bind_session!(episode)

    assert {:ok, receipt} =
             Corrections.split(%{
               action_ref: "operator-action:split:1",
               actor_ref: "slack:user:UOPERATOR",
               confirmation_ref: "operator-confirmation:split:1",
               input_refs: [unrelated],
               reason: "The pull request review is separate work.",
               source_episode_id: episode.id
             })

    assert receipt.outcome["moved_input_count"] == 1
    assert Enum.map(Origins.for_episode(episode.id), & &1.input_ref) != [unrelated]
    refute Origins.current_owner(native_input_id(unrelated), "slack", :live)

    # The contaminated session is replaced rather than reused, and the session
    # that held the removed text keeps its own history.
    sessions = Repo.all(from(session in Session, where: session.episode_id == ^episode.id))
    assert length(sessions) == 2
    replacement = Enum.max_by(sessions, & &1.generation)
    assert replacement.generation == bound.generation + 1
    assert is_nil(replacement.coop_session_id)
    assert Repo.get!(Session, bound.id).coop_session_id == bound.coop_session_id
  end

  test "a repeated confirmation applies the correction exactly once" do
    # A lost response after the correction committed must not move the same
    # inputs twice or record a second membership change.
    devops = admit!("repeat:devops", channel_ref: "CDEVOPS")
    alerts = admit!("repeat:alerts", channel_ref: "CALERTS")
    quiesce!(devops)
    quiesce!(alerts)

    request = %{
      action_ref: "operator-action:merge:3",
      actor_ref: "slack:user:UOPERATOR",
      confirmation_ref: "operator-confirmation:merge:3",
      reason: "Both alerts report the same database outage.",
      source_episode_id: alerts.id,
      target_episode_id: devops.id
    }

    assert {:ok, %{status: :recorded}} = Corrections.merge(request)
    assert {:ok, %{status: :duplicate}} = Corrections.merge(request)

    assert [_one] = Repo.all(AssociationCorrection)
    assert length(Origins.for_episode(devops.id)) == 2
  end

  test "a merge moves the retired owner's occurrence claims to the surviving work" do
    # Otherwise the occurrence would be unclaimed the moment its episode was
    # cancelled, and the next report of it would create a third episode.
    devops = admit!("claims:devops", channel_ref: "CDEVOPS")
    alerts = admit!("claims:alerts", channel_ref: "CALERTS")

    {:ok, _claim} =
      Repo.transaction(fn ->
        CorrelationClaims.claim_in_transaction(%{
          episode_id: alerts.id,
          input_ref: "admit:#{alerts.key}",
          scope_ref: "webhook:deployments",
          namespace: "publication:deployment:ryker",
          occurrence_ref: "deployment-run:1",
          lifecycle_state: :active,
          established_at: @now
        })
      end)

    quiesce!(devops)
    quiesce!(alerts)

    assert {:ok, _receipt} =
             Corrections.merge(%{
               action_ref: "operator-action:merge:4",
               actor_ref: "slack:user:UOPERATOR",
               confirmation_ref: "operator-confirmation:merge:4",
               reason: "Both reports describe the same rollout.",
               source_episode_id: alerts.id,
               target_episode_id: devops.id
             })

    owner =
      CorrelationClaims.owner(
        "webhook:deployments",
        "publication:deployment:ryker",
        "deployment-run:1"
      )

    assert owner.episode_id == devops.id
  end

  defp admit!(key, options) do
    input = slack_input!(options)
    id = Ecto.UUID.generate()

    {:ok, transition} =
      Episodes.apply(%Command.AdmitInput{
        actor_ref: Input.actor_ref(input),
        destination: input.destination,
        episode_id: id,
        episode_key: "#{key}:#{id}",
        linked_episode_id: nil,
        native_input_id: input.native_input_id,
        occurred_at: input.occurred_at,
        payload: Input.document(input),
        revision: 1,
        turn_ref: "turn:#{id}"
      })

    transition.episode
  end

  defp join!(episode, options) do
    input = slack_input!(options)
    occurred_at = DateTime.add(@now, System.unique_integer([:positive, :monotonic]), :second)

    command = %Command.AdmitInput{
      actor_ref: Input.actor_ref(input),
      destination: %{
        conversation_ref: episode.destination_conversation_ref,
        thread_ref: episode.destination_thread_ref,
        transport: episode.destination_transport
      },
      episode_id: episode.id,
      episode_key: episode.key,
      linked_episode_id: nil,
      native_input_id: input.native_input_id,
      occurred_at: occurred_at,
      payload: Input.document(input),
      revision: 1,
      turn_ref: "turn:#{episode.id}"
    }

    {:ok, _transition} = Episodes.apply(command)
    Command.dedupe_key(command)
  end

  # Quiescent work: the turn finished and the episode is waiting for whatever
  # someone says next, which is the ordinary state an operator corrects from.
  defp quiesce!(episode) do
    {:ok, current} = Episodes.fetch_by_key(episode.key)
    unique = System.unique_integer([:positive])

    {:ok, transition} =
      Episodes.apply(%Command.AcceptResult{
        decision_reason: "Nothing needed an answer here.",
        delivery: :none,
        delivery_ref: nil,
        episode_key: current.key,
        expected_turn_ref: current.owner_ref,
        next_turn_ref: nil,
        next_wait: %{kind: :input, ref: "question:#{unique}", deadline_at: nil},
        occurred_at: DateTime.add(@now, unique, :second),
        result_ref: "result:#{unique}"
      })

    transition.episode
  end

  defp reply_pending!(episode) do
    {:ok, transition} =
      Episodes.apply(%Command.AcceptResult{
        decision_reason: nil,
        delivery: :reply,
        delivery_ref: "delivery:#{episode.id}",
        episode_key: episode.key,
        expected_turn_ref: episode.owner_ref,
        next_turn_ref: nil,
        occurred_at: DateTime.add(@now, 30, :second),
        result_ref: "result:#{episode.id}"
      })

    transition.episode
  end

  defp bind_session!(episode) do
    Repo.insert!(%Session{
      id: Ecto.UUID.generate(),
      episode_id: episode.id,
      execution_kind: :work,
      policy: "engineering",
      policy_digest: String.duplicate("a", 64),
      external_ref: "episode:#{episode.id}:session:1",
      coop_session_id: "coop-session:#{episode.id}",
      generation: 1,
      create_generation: 1
    })
  end

  defp native_input_id(input_ref) do
    Repo.one!(
      from(origin in Ryker.Episodes.Origin,
        where: origin.input_ref == ^input_ref,
        select: origin.native_input_id,
        limit: 1
      )
    )
  end

  defp slack_input!(options) do
    unique = System.unique_integer([:positive])

    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "UALICE"},
        channel_ref: Keyword.fetch!(options, :channel_ref),
        content: %{"text" => Keyword.get(options, :text, "Database is unavailable")},
        event_kind: :message,
        event_ref: "Ev-#{unique}",
        message_ref: "#{1_789_000_000 + unique}.000200",
        occurred_at: @now,
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TROUTE"
      })

    input
  end
end
