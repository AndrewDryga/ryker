defmodule Responder.Slack.TaskCardProjectionTest do
  use Responder.DataCase, async: true

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Slack.{Renderer, TaskCardProjection}
  alias Responder.State.{Record, Records}
  alias Responder.Work.Custody

  @records Jason.decode!(File.read!("priv/card_lab/legacy_task_records.json"))

  test "progress and goal transitions change the durable card fingerprint without a new reply" do
    # The old projection omitted all goal state and only retained the last
    # summary, so subtask transitions never refreshed the pinned Slack card.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    {:ok, _} = Custody.pin_episode(episode.id, "read-only", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("card-details", 60, :work)
    token = Records.token(claim.turn)

    source = %Record{
      kind: "task_offer",
      status: :confirmed,
      confirmed_episode_id: episode.id,
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "slack:user:U1",
      ref: "task-card:details",
      payload: %{
        "title" => "Retained portal investigation",
        "repository" => "emisar",
        "prompt" => @records["portal_goals"]["goals"] |> hd() |> Map.fetch!("requested_outcome")
      }
    }

    {:ok, before} = TaskCardProjection.build(source)

    for {progress, index} <- Enum.with_index(Enum.take(@records["runner_task"]["progress"], 5)) do
      assert {:ok, _} =
               Records.create(
                 token,
                 "progress-#{index}",
                 "progress",
                 Map.take(progress, ~w(phase summary))
               )
    end

    [retained | _] = @records["portal_goals"]["goals"]

    goal =
      retained
      |> Map.take(~w(id requested_outcome completion_contract))
      |> Map.merge(%{"kind" => "check", "authority" => "read_only", "required" => false})

    assert {:ok, _} = Records.create(token, "goal", "goal", goal)

    assert {:ok, _} =
             Records.create(token, "goal-working", "goal_state", %{
               "goal_id" => goal["id"],
               "state" => "working"
             })

    assert {:ok, active} = TaskCardProjection.build(source)
    assert is_list(active.document["task_card"]["progress"])
    assert length(active.document["task_card"]["progress"]) == 4

    assert [%{"state" => "working", "requested_outcome" => title}] =
             active.document["task_card"]["goals"]

    assert title == goal["requested_outcome"]
    assert active.fingerprint != before.fingerprint
    assert {:ok, ^active} = TaskCardProjection.build(source)

    assert {:ok, _} =
             Records.create(token, "goal-complete", "goal_state", %{
               "goal_id" => goal["id"],
               "state" => "completed"
             })

    assert {:ok, complete} = TaskCardProjection.build(source)
    assert [%{"state" => "completed"}] = complete.document["task_card"]["goals"]
    assert complete.fingerprint != active.fingerprint

    # Feedback shares the progress record kind but is not a public work update.
    # Publishing it here would replace the live card with internal product notes.
    assert {:ok, _} =
             Records.create(token, "feedback", "progress", %{
               "phase" => "feedback:ux:suggestion",
               "summary" => "Internal feedback must not replace task progress"
             })

    assert {:ok, after_feedback} = TaskCardProjection.build(source)
    refute Jason.encode!(after_feedback.document) =~ "Internal feedback"
    assert after_feedback.fingerprint == complete.fingerprint

    # Exercise the existing 500/600-character boundary with retained prose:
    # differing truncation made a long update appear twice on the same card.
    long_summary =
      @records["runner_task"]["progress"]
      |> List.last()
      |> Map.fetch!("summary")
      |> String.duplicate(100)

    assert {:ok, _} =
             Records.create(token, "long-progress", "progress", %{
               "phase" => "working",
               "summary" => long_summary
             })

    assert {:ok, long_card} = TaskCardProjection.build(source)
    task = long_card.document["task_card"]
    assert task["summary"] == List.last(task["progress"])["summary"]
    assert String.ends_with?(task["summary"], "…")

    long_request =
      put_in(source.payload["prompt"], String.duplicate(source.payload["prompt"], 25))

    assert {:ok, request_card} = TaskCardProjection.build(long_request)
    assert String.length(request_card.document["task_card"]["request"]) == 1_000
    assert String.ends_with?(request_card.document["task_card"]["request"], "…")

    # Completed history must not conceal the next active subtask on long tasks.
    for index <- 2..9 do
      next_goal = Map.put(goal, "id", "goal-#{index}")

      next_goal =
        if index == 9,
          do: Map.update!(next_goal, "requested_outcome", &String.duplicate(&1, 6)),
          else: next_goal

      assert {:ok, _} = Records.create(token, "goal-#{index}", "goal", next_goal)

      assert {:ok, _} =
               Records.create(token, "goal-state-#{index}", "goal_state", %{
                 "goal_id" => next_goal["id"],
                 "state" => if(index == 9, do: "working", else: "completed")
               })
    end

    assert {:ok, many_goals} = TaskCardProjection.build(source)
    assert many_goals.document["task_card"]["goals_total"] == 9
    assert many_goals.document["task_card"]["goals_completed"] == 8

    assert [%{"id" => "goal-9", "state" => "working"} | _] =
             many_goals.document["task_card"]["goals"]

    assert many_goals.document["task_card"]["goals"]
           |> hd()
           |> Map.fetch!("requested_outcome")
           |> String.ends_with?("…")

    assert {:ok, rendered} = Renderer.render(many_goals.document)
    assert Jason.encode!(rendered) =~ "8 of 9 completed"
  end
end
