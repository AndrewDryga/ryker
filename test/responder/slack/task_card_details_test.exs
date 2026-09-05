defmodule Responder.Slack.TaskCardDetailsTest do
  use ExUnit.Case, async: true

  alias Responder.Slack.Renderer

  @records Jason.decode!(File.read!("priv/card_lab/legacy_task_records.json"))

  test "task cards show retained progress and goal states instead of only a summary" do
    # The production card discarded these dimensions entirely, leaving the
    # operator unable to distinguish active work from a motionless summary.
    task = task()

    progress =
      @records["runner_task"]["progress"]
      |> Enum.take(4)
      |> Enum.map(&Map.take(&1, ~w(phase summary at)))

    goals =
      @records["portal_goals"]["goals"]
      |> Enum.map(&Map.take(&1, ~w(id requested_outcome state parent_goal_id)))

    # Exercise each harvested episode separately; these are not one invented run.
    assert {:ok, running} = Renderer.render(%{"task_card" => Map.put(task, "progress", progress)})
    assert Jason.encode!(running) =~ "Still working; implementing and validating"
    assert Jason.encode!(running) =~ "Progress"

    assert {:ok, completed} = Renderer.render(%{"task_card" => Map.put(task, "goals", goals)})
    assert Jason.encode!(completed) =~ "Confirm the portal backend actually recovered"
    assert Jason.encode!(completed) =~ "3 of 3 completed"
  end

  test "extra card details cannot inject controls or exceed Slack bounds" do
    task = task()

    goal = %{
      "id" => "goal",
      "requested_outcome" => "Untrusted <@U123> <!channel> <script>",
      "state" => "working",
      "parent_goal_id" => nil
    }

    assert {:ok, rendered} = Renderer.render(%{"task_card" => Map.put(task, "goals", [goal])})
    json = Jason.encode!(rendered)
    refute json =~ "<@U123>"
    refute json =~ "<!channel>"
    assert length(rendered["blocks"]) <= 50

    for extra <- [
          %{"goals" => List.duplicate(goal, 9)},
          %{"goals" => [%{goal | "state" => "arbitrary"}]},
          %{"goals" => [Map.put(goal, "action_id", "responder_close_work")]},
          %{
            "progress" => [
              %{
                "phase" => "working",
                "summary" => String.duplicate("x", 601),
                "at" => "2026-09-05T00:00:00Z"
              }
            ]
          },
          %{"progress" => [%{"phase" => "working", "summary" => "Update", "at" => "not a date"}]},
          %{"model_thought" => "Private reasoning must never become card content"},
          %{"goals" => nil},
          %{"goals_total" => -1},
          %{"goals_total" => "1"},
          %{"goals_completed" => -1},
          %{"goals_completed" => 1},
          %{"goals" => [goal], "goals_completed" => 1},
          %{"request" => <<0>>},
          %{"goals" => [%{goal | "requested_outcome" => "   "}]},
          %{"progress" => [%{"phase" => "working", "summary" => "Update", "at" => 123}]}
        ] do
      assert Renderer.render(%{"task_card" => Map.merge(task, extra)}) ==
               {:error, {:invalid_slack_render, :task_card}}
    end
  end

  test "escaping expanded text still fits every Slack section" do
    task = Map.put(task(), "request", String.duplicate("<", 1_000))

    progress = %{
      "phase" => String.duplicate("<", 60),
      "summary" => String.duplicate("<", 600),
      "at" => "2026-09-05T00:00:00Z"
    }

    goals =
      for index <- 1..8 do
        %{
          "id" => "goal-#{index}",
          "requested_outcome" => String.duplicate("<", 250),
          "state" => "working",
          "parent_goal_id" => nil
        }
      end

    task =
      Map.merge(task, %{
        "progress" => List.duplicate(progress, 4),
        "goals" => goals,
        "goals_total" => 9
      })

    assert {:ok, rendered} = Renderer.render(%{"task_card" => task})

    for %{"type" => "section", "text" => %{"text" => text}} <- rendered["blocks"] do
      assert String.length(text) <= 3_000
    end

    assert Jason.encode!(rendered) =~ "Showing 8 of 9 subtasks"
  end

  test "the request precedes progress and the latest retained update is not duplicated" do
    progress =
      @records["runner_task"]["progress"]
      |> Enum.take(4)
      |> Enum.map(&Map.take(&1, ~w(phase summary at)))

    summary = List.last(progress)["summary"]

    task =
      Map.merge(task(), %{
        "title" => String.slice(@records["runner_task"]["title"], 0, 20),
        "request" => @records["runner_task"]["title"],
        "summary" => summary,
        "progress" => progress
      })

    assert {:ok, rendered} = Renderer.render(%{"task_card" => task})

    sections =
      for %{"type" => "section", "text" => %{"text" => text}} <- rendered["blocks"], do: text

    assert Enum.at(sections, 1) =~ "*The request*"

    assert length(Regex.scan(~r/Still working; implementing and validating/, Enum.join(sections))) ==
             1
  end

  test "an initial request is not repeated as a shorter latest update" do
    request = @records["runner_task"]["title"]

    task =
      Map.merge(task(), %{"request" => request, "summary" => String.slice(request, 0, 25) <> "…"})

    assert {:ok, rendered} = Renderer.render(%{"task_card" => task})

    sections =
      for %{"type" => "section", "text" => %{"text" => text}} <- rendered["blocks"], do: text

    refute Enum.join(sections) =~ "*Latest update*"
    refute Enum.join(sections) =~ "*The request*"
    assert hd(sections) =~ request
  end

  defp task do
    # Keep the established host-owned identity/control fixture; the added prose
    # above is harvested and carries its source episode in the checked-in file.
    %{
      "action_needed" => nil,
      "confirmed_at" => "2026-09-04T12:00:00Z",
      "confirmed_by" => "slack:user:U123",
      "controls" => [],
      "episode_state" => "working",
      "publication" => nil,
      "repository" => "emisar",
      "session_generation" => 1,
      "status" => "working",
      "summary" => "Retained task",
      "task_ref" => "task-card:test",
      "title" => @records["runner_task"]["title"],
      "ui_revision" => 4,
      "updated_at" => "2026-09-04T12:04:00Z",
      "work_state" => "pending"
    }
  end
end
