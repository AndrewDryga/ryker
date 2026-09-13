defmodule Ryker.Slack.TaskCardDetailsTest do
  use ExUnit.Case, async: true

  alias Ryker.Slack.Renderer

  @records Jason.decode!(File.read!("testdata/slack/legacy_task_records.json"))
  @stages ~w(workspace_setup planning implementation self_review draft_pr ci review_and_merge)

  test "task cards keep all seven stages visible, bold the current work and mark the human handoff" do
    # The production card showed four recent progress notes and one flat goal
    # list, so a waiting subtask erased which stage the task was in.
    task =
      Map.put(task(), "stages", [
        stage("workspace_setup", "completed"),
        stage("planning", "completed"),
        stage("implementation", "waiting", %{
          "current" => true,
          "detail" => "2/4 subtasks",
          "your_turn" => true,
          "subtasks" => [
            subtask("export", "Export bounded per-worker memory metrics", "completed"),
            subtask("capture", "Add protected diagnostic capture", "completed"),
            subtask("drain", "Drain and recycle workers safely", "waiting", %{
              "current" => true,
              "detail" => "waiting for the storage-location answer"
            }),
            subtask("cooldown", "Cover cooldown and worker replacement", "ready")
          ]
        }),
        stage("self_review", "pending"),
        stage("draft_pr", "pending"),
        stage("ci", "pending"),
        stage("review_and_merge", "pending")
      ])

    assert {:ok, rendered} = Renderer.render(%{"task_card" => task})
    progress = section_text(rendered, "*Progress*")

    assert progress ==
             Enum.join(
               [
                 "*Progress*",
                 "✓ Workspace setup",
                 "✓ Planning",
                 "*◷ Implementation · 2/4 subtasks ← 🙋 your turn*",
                 "    ✓ Export bounded per-worker memory metrics",
                 "    ✓ Add protected diagnostic capture",
                 "    *◷ Drain and recycle workers safely · waiting for the storage-location answer*",
                 "    ○ Cover cooldown and worker replacement",
                 "○ Self-review and checks",
                 "○ Draft PR",
                 "○ CI",
                 "○ Review and merge"
               ],
               "\n"
             )

    refute Jason.encode!(rendered) =~ "Latest update"
    refute Jason.encode!(rendered) =~ "Reply in this thread"
    refute Jason.encode!(rendered) =~ "Waiting for input"
  end

  test "every stage disposition has one glyph and completed stages never repeat Passed" do
    stages = [
      stage("workspace_setup", "failed", %{"detail" => "No worker accepted the placement."}),
      stage("planning", "unknown", %{"detail" => "not recorded"}),
      stage("implementation", "stopped", %{"detail" => "2/4 subtasks · stopped"}),
      stage("self_review", "stale", %{"detail" => "previous version checked"}),
      stage("draft_pr", "completed", %{
        "detail" => "#617",
        "url" => "https://github.com/theblitzapp/blitz-app-svelte/pull/617"
      }),
      stage("ci", "skipped", %{"detail" => "no checks configured"}),
      stage("review_and_merge", "running", %{"current" => true})
    ]

    assert {:ok, rendered} = Renderer.render(%{"task_card" => Map.put(task(), "stages", stages)})
    progress = section_text(rendered, "*Progress*")

    assert progress =~ "! Workspace setup · No worker accepted the placement."
    assert progress =~ "? Planning · not recorded"
    assert progress =~ "■ Implementation · 2/4 subtasks · stopped"
    assert progress =~ "↻ Self-review and checks · previous version checked"

    assert progress =~
             "✓ <https://github.com/theblitzapp/blitz-app-svelte/pull/617|Draft PR #617>"

    assert progress =~ "− CI · no checks configured"
    assert progress =~ "*▸ Review and merge*"
    refute progress =~ "Passed"
  end

  test "the request precedes progress and the repository links only from a trusted destination" do
    request = @records["portal_goals"]["goals"] |> hd() |> Map.fetch!("completion_contract")

    task =
      Map.merge(task(), %{
        "request" => request,
        "stages" => Enum.map(@stages, &stage(&1, "pending"))
      })

    assert {:ok, rendered} = Renderer.render(%{"task_card" => task})
    sections = section_texts(rendered)
    assert Enum.at(sections, 0) =~ @records["runner_task"]["title"]
    assert Enum.at(sections, 1) == "*The request*\n" <> request
    assert Enum.at(sections, 2) =~ "*Progress*"

    assert [%{"fields" => [%{"text" => "*Repository*\n`emisar`"}]}] =
             Enum.filter(rendered["blocks"], &Map.has_key?(&1, "fields"))

    linked = Map.put(task, "repository_url", "https://github.com/theblitzapp/emisar")
    assert {:ok, rendered} = Renderer.render(%{"task_card" => linked})

    assert [
             %{
               "fields" => [
                 %{"text" => "*Repository*\n<https://github.com/theblitzapp/emisar|emisar>"}
               ]
             }
           ] =
             Enum.filter(rendered["blocks"], &Map.has_key?(&1, "fields"))

    assert Renderer.render(%{
             "task_card" => Map.put(task, "repository_url", "http://github.com/x/y")
           }) ==
             {:error, {:invalid_slack_render, :task_card}}
  end

  test "extra card details cannot inject controls or exceed Slack bounds" do
    task = task()

    hostile =
      stage("implementation", "running", %{
        "detail" => "<!channel> <script>",
        "subtasks" => [
          subtask("goal", "Untrusted <@U123> <!channel> <script>", "working", %{"current" => true})
        ]
      })

    stages = List.replace_at(Enum.map(@stages, &stage(&1, "pending")), 2, hostile)
    assert {:ok, rendered} = Renderer.render(%{"task_card" => Map.put(task, "stages", stages)})
    json = Jason.encode!(rendered)
    refute json =~ "<@U123>"
    refute json =~ "<!channel>"
    assert length(rendered["blocks"]) <= 50

    subtask = subtask("goal", "Goal", "working")

    for extra <- [
          %{
            "stages" =>
              Enum.map(@stages, &stage(&1, "pending")) ++
                [stage("unassigned", "unknown"), stage("ci", "pending")]
          },
          %{"stages" => [stage("ci", "pending")]},
          %{"stages" => Enum.map(@stages, &stage(&1, "arbitrary"))},
          %{
            "stages" =>
              List.replace_at(
                Enum.map(@stages, &stage(&1, "pending")),
                0,
                stage("deploy", "pending")
              )
          },
          %{
            "stages" =>
              List.replace_at(
                Enum.map(@stages, &stage(&1, "pending")),
                2,
                stage("implementation", "running", %{"subtasks" => List.duplicate(subtask, 7)})
              )
          },
          %{
            "stages" =>
              List.replace_at(
                Enum.map(@stages, &stage(&1, "pending")),
                2,
                stage("implementation", "running", %{
                  "subtasks" => [%{subtask | "state" => "arbitrary"}]
                })
              )
          },
          %{
            "stages" =>
              List.replace_at(
                Enum.map(@stages, &stage(&1, "pending")),
                2,
                stage("implementation", "running", %{
                  "subtasks" => [Map.put(subtask, "action_id", "ryker_close_work")]
                })
              )
          },
          %{
            "stages" =>
              List.replace_at(
                Enum.map(@stages, &stage(&1, "pending")),
                2,
                stage("implementation", "running", %{"detail" => String.duplicate("x", 201)})
              )
          },
          %{
            "stages" =>
              List.replace_at(
                Enum.map(@stages, &stage(&1, "pending")),
                4,
                stage("draft_pr", "completed", %{"url" => "javascript:alert(1)"})
              )
          },
          %{
            "stages" =>
              List.replace_at(
                Enum.map(@stages, &stage(&1, "pending")),
                2,
                stage("implementation", "running", %{
                  "subtasks_total" => 0,
                  "subtasks" => [subtask]
                })
              )
          },
          %{"stages" => nil},
          %{"model_thought" => "Private reasoning must never become card content"},
          %{"request" => <<0>>},
          %{"repository_url" => "github.com/x/y"}
        ] do
      assert Renderer.render(%{"task_card" => Map.merge(task, extra)}) ==
               {:error, {:invalid_slack_render, :task_card}}
    end
  end

  test "escaping expanded text still fits every Slack section" do
    task = Map.put(task(), "request", String.duplicate("<", 600))

    subtasks =
      for index <- 1..6 do
        subtask("goal-#{index}", String.duplicate("<", 250), "working", %{
          "detail" => String.duplicate("<", 200)
        })
      end

    stages =
      Enum.map(@stages, fn stage ->
        stage(stage, "running", %{
          "detail" => String.duplicate("<", 200),
          "subtasks" => subtasks,
          "subtasks_total" => 9
        })
      end)

    assert {:ok, rendered} = Renderer.render(%{"task_card" => Map.put(task, "stages", stages)})

    for %{"type" => "section", "text" => %{"text" => text}} <- rendered["blocks"] do
      assert String.length(text) <= 3_000
    end

    assert Jason.encode!(rendered) =~ "Showing 6 of 9 subtasks"
    assert length(section_texts(rendered)) > 3
  end

  defp section_texts(rendered) do
    for %{"type" => "section", "text" => %{"text" => text}} <- rendered["blocks"], do: text
  end

  defp section_text(rendered, prefix) do
    rendered |> section_texts() |> Enum.find(&String.starts_with?(&1, prefix))
  end

  defp stage(id, state, overrides \\ %{}) do
    Map.merge(
      %{
        "current" => false,
        "detail" => nil,
        "stage" => id,
        "state" => state,
        "subtasks" => [],
        "subtasks_total" => nil,
        "url" => nil,
        "your_turn" => false
      },
      overrides
    )
  end

  defp subtask(id, outcome, state, overrides \\ %{}) do
    Map.merge(
      %{"current" => false, "detail" => nil, "id" => id, "outcome" => outcome, "state" => state},
      overrides
    )
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
