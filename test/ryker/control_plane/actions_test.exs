defmodule Ryker.ControlPlane.ActionsTest do
  use Ryker.DataCase, async: false
  alias Ryker.ControlPlane.{Actions, EpisodeProjection}
  alias Ryker.Episodes
  alias Ryker.Episodes.Command
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures

  test "local retention callbacks fail closed while preserving audited action identity" do
    callbacks = Actions.callbacks()

    assert callbacks.send_lab_message.(Ecto.UUID.generate(), "hello", [], nil) ==
             {:error, :conversation_lab_not_configured}

    assert callbacks.rearm_retention.("missing-session", nil) ==
             {:error, :operator_failure_not_found}

    assert callbacks.discard_retention.("missing-session", nil) ==
             {:error, :retention_session_not_found}

    assert callbacks.run_schedule.("missing-schedule", nil) ==
             {:error, :schedule_policy_unavailable}

    configured = Actions.callbacks(nil, %{}, %{}, fn _schedule -> {:ok, %{name: "policy"}} end)
    assert configured.run_schedule.("missing-schedule", nil) == {:error, :schedule_not_found}
  end

  test "no retired Card Lab action can queue a Slack specimen or record catalog feedback" do
    # Retired 2026-09-13. The confirmed HTTP router used to reach these five
    # callbacks; a surviving callback would be a send path with no page, no
    # confirmation step and no worker draining what it queued.
    callbacks = Actions.callbacks()

    for retired <- [
          :record_card_feedback,
          :describe_card_slack_target,
          :post_card_to_slack,
          :transition_card_slack_post,
          :retry_card_slack_post
        ] do
      refute Map.has_key?(callbacks, retired), "#{retired} must not survive the Card Lab"
    end
  end

  test "episode controls resolve waits and review the exact terminal semantic version" do
    callbacks = Actions.callbacks()
    waiting = start_episode!("resolve")
    wait_ref = "wait:resolve:#{waiting.episode.id}"

    assert {:ok, _waiting} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 episode_key: waiting.episode.key,
                 expected_turn_ref: waiting.episode.owner_ref,
                 kind: :input,
                 wait_ref: wait_ref
               })
             )

    assert {:ok, %{state: :cancelled}} = callbacks.resolve_episode.(waiting.episode.key)

    assert callbacks.resolve_episode.(waiting.episode.key) ==
             {:error, :episode_not_resolvable}

    complete = start_episode!("review")

    assert {:ok, completed} =
             Episodes.apply(
               EpisodeFixtures.accept_result(%{
                 decision_reason: "No visible reply is required.",
                 delivery: :none,
                 delivery_ref: nil,
                 episode_key: complete.episode.key,
                 expected_turn_ref: complete.episode.owner_ref,
                 result_ref: "result:review:#{complete.episode.id}"
               })
             )

    assert {:ok, %{review: review, status: :recorded}} =
             callbacks.rate_episode.(complete.episode.key, :needs_work, nil)

    assert review.semantic_version == completed.episode.semantic_version
    assert review.actor_ref == "control-plane:local"
    assert review.rating == :needs_work

    assert {:ok, %{review: replayed, status: :duplicate}} =
             callbacks.rate_episode.(complete.episode.key, :needs_work, nil)

    assert replayed.id == review.id

    # One rating per ending: a different one is refused, not rewritten.
    assert callbacks.rate_episode.(complete.episode.key, :good, nil) ==
             {:error, :episode_review_conflict}
  end

  # Every console action was recorded as control-plane:local, so on a console
  # several people reach through Tailscale nobody could tell who did what.
  test "an action taken by a tailnet user is recorded as theirs" do
    viewer = %{login: "andrew@example.com", name: "Andrew Example", via: :tailscale}
    complete = start_episode!("tailnet-review")

    assert {:ok, _completed} =
             Episodes.apply(
               EpisodeFixtures.accept_result(%{
                 decision_reason: "No visible reply is required.",
                 delivery: :none,
                 delivery_ref: nil,
                 episode_key: complete.episode.key,
                 expected_turn_ref: complete.episode.owner_ref,
                 result_ref: "result:tailnet-review:#{complete.episode.id}"
               })
             )

    assert {:ok, %{review: review}} =
             Actions.callbacks().rate_episode.(complete.episode.key, :good, viewer)

    assert review.actor_ref == "control-plane:tailscale:andrew@example.com"
  end

  test "closing a request does not ask its closer to rate the ending they chose" do
    # QA re-test, 2026-09-26: right after "Close as no longer needed" the
    # timeline asked about the ending the person had just chosen.
    callbacks = Actions.callbacks()
    waiting = start_episode!("close-review")

    assert {:ok, _waiting} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 episode_key: waiting.episode.key,
                 expected_turn_ref: waiting.episode.owner_ref,
                 kind: :input,
                 wait_ref: "wait:close-review:#{waiting.episode.id}"
               })
             )

    assert {:ok, %{state: :cancelled}} = callbacks.resolve_episode.(waiting.episode.key)
    refute awaiting_review?(waiting.episode.key)

    # A stopped task's close settles later, as this cancel with the close's
    # own reference.
    stopped = start_episode!("close-stopped")

    assert {:ok, _cancelled} =
             cancel(stopped.episode, "control-plane:resolve:#{Ecto.UUID.generate()}")

    refute awaiting_review?(stopped.episode.key)

    # So does closing a task from its chat card.
    card = start_episode!("close-card")

    assert {:ok, _cancelled} =
             cancel(card.episode, "control-plane-action:#{String.duplicate("c", 64)}")

    refute awaiting_review?(card.episode.key)

    # An ending nobody chose here still asks how it went.
    ended = start_episode!("stalled")
    assert {:ok, _cancelled} = cancel(ended.episode, "work:stalled:#{Ecto.UUID.generate()}")
    assert awaiting_review?(ended.episode.key)
  end

  defp cancel(episode, cancel_ref) do
    Episodes.apply(%Command.CancelEpisode{
      cancel_ref: cancel_ref,
      episode_key: episode.key,
      expected_owner: %{kind: :turn, ref: episode.owner_ref},
      occurred_at: DateTime.utc_now(),
      reason: "Stopped."
    })
  end

  defp awaiting_review?(episode_key) do
    {:ok, %{trace: trace}} = EpisodeProjection.fetch(episode_key)
    trace.rating.awaiting
  end

  defp start_episode!(suffix) do
    id = Ecto.UUID.generate()

    {:ok, transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: id,
          episode_key: "control-plane-action:#{suffix}:#{id}",
          native_input_id: "control-plane-action-input:#{suffix}:#{id}",
          turn_ref: "control-plane-action-turn:#{suffix}:#{id}"
        })
      )

    transition
  end
end
