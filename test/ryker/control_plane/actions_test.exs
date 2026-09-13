defmodule Ryker.ControlPlane.ActionsTest do
  use Ryker.DataCase, async: false

  alias Ryker.ControlPlane.Actions
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures

  test "local retention callbacks fail closed while preserving audited action identity" do
    callbacks = Actions.callbacks()

    assert callbacks.send_lab_message.(Ecto.UUID.generate(), "hello", []) ==
             {:error, :conversation_lab_not_configured}

    assert callbacks.rearm_retention.("missing-session") ==
             {:error, :operator_failure_not_found}

    assert callbacks.discard_retention.("missing-session") ==
             {:error, :retention_session_not_found}

    assert callbacks.run_schedule.("missing-schedule") ==
             {:error, :schedule_policy_unavailable}

    configured = Actions.callbacks(nil, %{}, %{}, fn _schedule -> {:ok, %{name: "policy"}} end)
    assert configured.run_schedule.("missing-schedule") == {:error, :schedule_not_found}
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
             callbacks.review_episode.(complete.episode.key)

    assert review.semantic_version == completed.episode.semantic_version
    assert review.actor_ref == "control-plane:local"

    assert {:ok, %{review: replayed, status: :duplicate}} =
             callbacks.review_episode.(complete.episode.key)

    assert replayed.id == review.id
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
