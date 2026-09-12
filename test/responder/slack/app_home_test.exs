defmodule Responder.Slack.AppHomeTest do
  use ExUnit.Case, async: true

  alias Responder.Slack.{AppHome, HomeEvent}

  @plan_fingerprint String.duplicate("a", 64)

  defmodule Directory do
    def user_allowed(%{allowed: allowed}, user_ref, _workspace_ref),
      do: {:ok, MapSet.member?(allowed, user_ref)}
  end

  defmodule API do
    def publish_home(%{calls: agent}, user_ref, view) do
      Agent.update(agent, &[{user_ref, view} | &1])
      :ok
    end
  end

  defmodule InvalidDirectory do
    def user_allowed(_client, _user_ref, _workspace_ref), do: :invalid
  end

  defmodule FailingAPI do
    def publish_home(_client, _user_ref, _view), do: {:error, :slack_unavailable}
  end

  test "publishes a bounded what-needs-me view for an operator" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    snapshot = %{
      counts: %{
        active_behaviors: 3,
        active_commitments: 4,
        active_memory: 2,
        active_schedules: 1,
        blocked_work: 1,
        incident_history: 7,
        open_incidents: 1,
        published_work: 5,
        retained_workspaces: 1
      },
      behaviors: [
        %{
          kind: :guidance,
          ref: "behavior:one",
          revision: 3,
          status: :active,
          subject: "Release checks",
          url: "https://slack.com/app_redirect?team=T123&channel=COPS"
        }
      ],
      incidents: [
        %{
          channel_ref: "CINCIDENT",
          ref: "incident-room:one",
          status: :ready,
          title: "Checkout API latency",
          url: "https://slack.com/app_redirect?team=T123&channel=CINCIDENT"
        }
      ],
      memories: [
        %{
          kind: :repository_binding,
          ref: "memory:one",
          subject: "checkout-api",
          url: "https://slack.com/app_redirect?team=T123&channel=COPS"
        }
      ],
      memory_review_count: 3,
      memory_reviews: [
        %{
          "entries" => [
            %{
              "scope" => "workspace",
              "scope_ref" => "slack:T123",
              "subject" => "checkout-api",
              "url" => "https://slack.com/app_redirect?team=T123&channel=COPS",
              "value" => "payments",
              "visibility" => "workspace"
            },
            %{
              "scope" => "workspace",
              "scope_ref" => "slack:T123",
              "subject" => "checkout-api-2",
              "value" => "payments",
              "visibility" => "workspace"
            }
          ],
          "kind" => "duplicate",
          "reason" => "Same value",
          "review_ref" => "memory-review:one",
          "status" => "pending"
        },
        %{
          "entries" => [
            %{
              "scope" => "workspace",
              "scope_ref" => "slack:T123",
              "subject" => "deploy-style",
              "value" => "show the proof first",
              "visibility" => "workspace"
            }
          ],
          "kind" => "stale",
          "reason" => "Review this value",
          "review_ref" => "memory-review:two",
          "status" => "pending"
        }
      ],
      needs_attention: [
        %{
          controls: [],
          kind: :operator_input,
          ref: "episode:one",
          title: "Choose the sampling strategy",
          url:
            "https://slack.com/app_redirect?team=T123&channel=COPS&message_ts=1787832000.000100"
        },
        %{
          controls: ["retry"],
          kind: :publish_pending,
          recovery_generation: 3,
          ref: "publication:one",
          title: "Repair checkout deploy",
          url:
            "https://slack.com/app_redirect?team=T123&channel=COPS&message_ts=1787832000.000100"
        },
        %{
          controls: ["discard_workspace"],
          discard_plan_fingerprint: @plan_fingerprint,
          kind: :retained_workspace,
          ref: "responder-work:episode-one:session:1",
          title: "Preserved checkout patch",
          url:
            "https://slack.com/app_redirect?team=T123&channel=COPS&message_ts=1787832000.000100"
        }
      ],
      schedules: [
        %{
          next_occurrence_at: ~U[2026-08-29 12:00:00Z],
          ref: "schedule:one",
          revision: 4,
          status: :active,
          title: "Daily audit",
          url:
            "https://slack.com/app_redirect?team=T123&channel=COPS&message_ts=1787832000.000100"
        }
      ],
      work: [
        %{
          next_action: "continue_work",
          ref: "task-card:one",
          state: :working,
          title: "Repair checkout deploy",
          url:
            "https://slack.com/app_redirect?team=T123&channel=COPS&message_ts=1787832000.000100"
        }
      ]
    }

    options =
      options(calls, fn "T123", "U123", %MapSet{} = shared_conversations ->
        assert shared_conversations == MapSet.new(["COPS"])
        snapshot
      end)

    assert {:ok, %{access: :operator, outcome: :published}} =
             AppHome.handle(event("U123"), options)

    assert [{"U123", %{"blocks" => blocks, "type" => "home"}}] = Agent.get(calls, & &1)
    assert length(blocks) < 100

    text = Jason.encode!(blocks)
    assert text =~ "What needs you"
    assert text =~ "Choose the sampling strategy"
    assert text =~ "Checkout API latency"
    assert text =~ "Repair checkout deploy"
    assert text =~ "Daily audit"
    assert text =~ "checkout-api"
    assert text =~ "responder_home_forget_memory"
    assert text =~ "responder_home_keep_memory_review"
    assert text =~ "responder_home_merge_memory_review"
    assert text =~ "responder_home_forget_memory_review"
    assert text =~ "responder_home_edit_memory_review"
    assert text =~ "Forget all (2)"
    assert text =~ "Merge 2 entries?"
    assert text =~ "checkout-api-2"
    assert text =~ "scope: workspace (slack:T123)"
    assert text =~ "visibility: workspace"
    assert text =~ "1 more memory review is available"
    assert text =~ "responder_home_disable_behavior"
    assert text =~ "responder_home_pause_schedule"
    assert text =~ "responder_home_run_schedule"
    assert text =~ "Replace in chat"
    assert text =~ "responder_home_retry_publication"
    assert text =~ "publication-recovery:one:3"
    assert text =~ "responder_home_discard_workspace"

    assert text =~
             "responder-work-control:responder-work:episode-one:session:1:#{@plan_fingerprint}"

    assert text =~ "responder_home_open"
    assert text =~ "https://slack.com/app_redirect?team=T123&channel=COPS"

    assert text =~ "responder_home_show_collection"
    assert text =~ "home-collection:schedules:0"
    assert text =~ "home-collection:standing_rules:0"
    assert text =~ "home-collection:knowledge:0"
  end

  # The channel card said "operators can open my App Home for the complete
  # list" while Home showed five rows of each kind and stopped. Opening a
  # collection from Home shows the whole authorized list, one page at a time.
  test "a complete list shows the items the capped sections leave out" do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    parent = self()

    options =
      options(calls, fn _, _, _ -> flunk("the dashboard projection must not be queried") end)
      |> Map.put(:collection, fn kind, workspace_ref, shared_conversations, offset ->
        send(parent, {:collection, kind, workspace_ref, shared_conversations, offset})

        %{
          kind: :schedules,
          offset: offset,
          outcome: :listed,
          page_size: 10,
          rows:
            Enum.map((offset + 1)..(offset + 10), fn index ->
              %{
                detail: "Schedule active",
                ref: "schedule:#{index}",
                title: "Check #{index}",
                url: "https://slack.com/app_redirect?team=T123&channel=COPS"
              }
            end),
          total: 27
        }
      end)

    assert {:ok, %{access: :operator, outcome: :published}} =
             AppHome.publish_collection(event("U123"), :schedules, 10, options)

    assert_received {:collection, :schedules, "T123", shared_conversations, 10}
    assert shared_conversations == MapSet.new(["COPS"])

    assert [{"U123", %{"blocks" => blocks, "type" => "home"}}] = Agent.get(calls, & &1)
    assert length(blocks) < 100
    text = Jason.encode!(blocks)

    assert text =~ "All active schedules"
    assert text =~ "27 schedules in the channels we share"
    assert text =~ "page 2 of 3"
    assert text =~ "Check 11 — Schedule active"
    assert text =~ "Check 20 — Schedule active"
    assert text =~ "home-collection:schedules:0"
    assert text =~ "home-collection:schedules:20"
    assert text =~ "responder_home_show_dashboard"
    assert text =~ "home-collection:dashboard"
    assert text =~ "https://slack.com/app_redirect?team=T123&channel=COPS"
  end

  test "paging stops at the ends of the complete list" do
    first =
      AppHome.render(:collection, %{
        kind: :knowledge,
        offset: 0,
        outcome: :listed,
        page_size: 10,
        rows: [
          %{detail: "Guidance active", ref: "behavior:one", title: "Deploy reviews", url: nil}
        ],
        total: 4
      })

    values = control_values(first["blocks"])
    assert "home-collection:dashboard" in values
    refute Enum.any?(values, &String.starts_with?(&1, "home-collection:knowledge:"))
    assert Jason.encode!(first) =~ "4 saved knowledge items in the channels we share"
    refute Jason.encode!(first) =~ "page 1 of 1"

    last =
      AppHome.render(:collection, %{
        kind: :schedules,
        offset: 20,
        outcome: :listed,
        page_size: 10,
        rows: [%{detail: "Schedule paused", ref: "schedule:21", title: "Check 21", url: nil}],
        total: 21
      })

    values = control_values(last["blocks"])
    assert "home-collection:schedules:10" in values
    refute "home-collection:schedules:30" in values
    assert Jason.encode!(last) =~ "page 3 of 3"
  end

  # A complete list that could not be read must not read as "you have none":
  # the operator would stop looking for the schedule they still have.
  test "an empty complete list and one that could not be read are different pages" do
    empty =
      AppHome.render(:collection, %{
        kind: :standing_rules,
        offset: 0,
        outcome: :empty,
        page_size: 10,
        rows: [],
        total: 0
      })

    unavailable =
      AppHome.render(:collection, %{
        kind: :standing_rules,
        offset: 0,
        outcome: :unavailable,
        page_size: 10,
        rows: [],
        total: 0
      })

    assert Jason.encode!(empty) =~ "No standing rules are set up in the channels we share."
    assert Jason.encode!(unavailable) =~ "I couldn't load your standing rules right now."
    refute Jason.encode!(unavailable) =~ "No standing rules"
    assert "home-collection:dashboard" in control_values(empty["blocks"])
    assert "home-collection:dashboard" in control_values(unavailable["blocks"])
  end

  test "a full nonoperator cannot open a complete list" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    options =
      options(calls, fn _, _, _ -> flunk("must not query") end)
      |> Map.put(:collection, fn _kind, _workspace, _conversations, _offset ->
        flunk("the collection must not be read for a nonoperator")
      end)

    assert {:ok, %{access: :restricted, outcome: :published}} =
             AppHome.publish_collection(event("U456"), :schedules, 0, options)

    assert [{"U456", %{"blocks" => blocks}}] = Agent.get(calls, & &1)
    assert Jason.encode!(blocks) =~ "operational details are limited"

    denied = put_in(options, [:client, :allowed], MapSet.new())

    assert AppHome.publish_collection(event("U123"), :schedules, 0, denied) ==
             {:ok, %{access: :denied, outcome: :ignored}}
  end

  test "a maximal operator view remains complete and below Slack's block limit" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    reviews =
      Enum.map(1..5, fn review_index ->
        %{
          "entries" =>
            Enum.map(1..8, fn entry_index ->
              %{
                "memory_ref" => "memory:#{review_index}:#{entry_index}",
                "scope" => "workspace",
                "scope_ref" => "slack:T123:" <> String.duplicate("channel", 150),
                "subject" => String.duplicate("subject", 20),
                "value" => "VALUE-" <> String.duplicate("detail", 700),
                "visibility" => "workspace"
              }
            end),
          "kind" => "duplicate",
          "reason" => "Same value",
          "review_ref" => "memory-review:#{review_index}"
        }
      end)

    row = fn index ->
      %{
        kind: :guidance,
        next_action: :continue_work,
        ref: "row:#{index}",
        revision: index,
        status: :active
      }
    end

    attention_row = fn index ->
      %{
        controls: ["update", "discard"],
        kind: :publish_pending,
        recovery_generation: 1,
        ref: "publication:#{index}",
        title: "Publication #{index}",
        url: "https://slack.com/app_redirect?team=T123&channel=COPS"
      }
    end

    snapshot = %{
      behaviors: Enum.map(1..5, row),
      counts: %{},
      incidents: Enum.map(1..5, row),
      memories: Enum.map(1..5, row),
      memory_review_count: 5,
      memory_reviews: reviews,
      needs_attention: Enum.map(1..8, attention_row),
      schedules: Enum.map(1..5, row),
      work: Enum.map(1..8, row)
    }

    assert {:ok, %{access: :operator, outcome: :published}} =
             AppHome.handle(event("U123"), options(calls, fn _, _, _ -> snapshot end))

    assert [{"U123", %{"blocks" => blocks}}] = Agent.get(calls, & &1)
    # Slack rejects a view over 100 blocks, so the complete-list controls cost
    # exactly one actions block for all three collections.
    assert length(blocks) < 100
    assert length(blocks) == 99
    action_ids = action_ids(blocks)
    assert length(action_ids) == length(Enum.uniq(action_ids))
    rendered = Jason.encode!(blocks)
    assert rendered =~ "3 more memory reviews are available"
    assert rendered =~ "visibility: workspace; value: VALUE-"
    assert rendered =~ "Durable state remains authoritative"
  end

  test "a dashboard the host could not read says so instead of showing nothing" do
    # The 2026-09-12 coverage measurement: an unreadable dashboard rendered
    # exactly like a person with no schedules, no rules and no work. A quiet
    # zero is the most convincing wrong answer a surface can give.
    view = AppHome.render(:operator, Responder.Slack.AppHomeProjection.unreadable())
    encoded = Jason.encode!(view)

    assert encoded =~ "couldn't read"
    refute encoded =~ "Nothing needs you right now"

    empty = Jason.encode!(AppHome.render(:operator, Responder.Slack.AppHomeProjection.empty()))
    refute empty =~ "couldn't read"
  end

  test "a sparse operator view stays useful and renders terminal lifecycle choices safely" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    snapshot = %{
      behaviors: [
        %{
          kind: :guidance,
          ref: "behavior:disabled",
          revision: 2,
          status: :disabled,
          subject: "Quiet hours"
        }
      ],
      counts: :unavailable,
      incidents: [],
      memories: [],
      memory_review_count: :unavailable,
      memory_reviews: [],
      needs_attention: [],
      schedules: [
        %{ref: "schedule:paused", revision: 5, status: :paused, title: "Paused audit"},
        %{ref: "schedule:completed", revision: 2, status: :completed, title: "One-time audit"}
      ],
      work: []
    }

    assert {:ok, %{access: :operator, outcome: :published}} =
             AppHome.handle(event("U123"), options(calls, fn _, _, _ -> snapshot end))

    assert [{"U123", %{"blocks" => blocks}}] = Agent.get(calls, & &1)
    rendered = Jason.encode!(blocks)
    assert rendered =~ "Nothing needs your attention right now."
    assert rendered =~ "responder_home_enable_behavior"
    assert rendered =~ "responder_home_resume_schedule"
    assert rendered =~ "One-time audit"
  end

  test "full nonoperators receive no operational details" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    options =
      options(calls, fn _workspace_ref, _actor_ref, _shared_conversations ->
        flunk("the operational projection must not be queried for a nonoperator")
      end)

    assert {:ok, %{access: :restricted, outcome: :published}} =
             AppHome.handle(event("U456"), options)

    assert [{"U456", %{"blocks" => blocks, "type" => "home"}}] = Agent.get(calls, & &1)
    text = Jason.encode!(blocks)
    assert text =~ "Responder is available"
    assert text =~ "operational details are limited"
    refute text =~ "incident-room"
  end

  test "inactive or guest users cannot cause a Home publication" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    options =
      put_in(
        options(calls, fn _, _, _ -> flunk("must not query") end),
        [:client, :allowed],
        MapSet.new()
      )

    assert AppHome.handle(event("U123"), options) ==
             {:ok, %{access: :denied, outcome: :ignored}}

    assert Agent.get(calls, & &1) == []
  end

  test "malformed dependencies fail closed and publisher errors remain retryable" do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    valid = options(calls, fn _, _, _ -> %{counts: %{}} end)

    assert AppHome.handle(:invalid, %{}) == {:error, {:invalid_app_home, :request}}

    assert AppHome.handle(event("U123"), Map.delete(valid, :directory)) ==
             {:error, {:invalid_app_home, :directory}}

    assert AppHome.handle(event("U123"), %{valid | directory: InvalidDirectory}) ==
             {:error, {:invalid_app_home, :directory}}

    assert AppHome.handle(event("U123"), %{valid | projection: fn _, _, _ -> :invalid end}) ==
             {:error, {:invalid_app_home, :projection}}

    assert AppHome.handle(
             event("U123"),
             %{valid | shared_conversations: fn _client, _actor, _workspace -> :invalid end}
           ) == {:error, {:invalid_app_home, :shared_conversations}}

    assert AppHome.handle(event("U123"), %{valid | operators: :invalid}) ==
             {:error, {:invalid_app_home, :operators}}

    assert AppHome.handle(event("U123"), %{valid | api: FailingAPI}) ==
             {:error, :slack_unavailable}
  end

  defp event(actor_ref) do
    %HomeEvent{actor_ref: actor_ref, event_ref: "Ev-home-1", workspace_ref: "T123"}
  end

  defp options(calls, projection) do
    %{
      api: API,
      client: %{allowed: MapSet.new(["U123", "U456"]), calls: calls},
      directory: Directory,
      operators: MapSet.new(["U123"]),
      projection: projection,
      shared_conversations: fn _client, _actor_ref, _workspace_ref ->
        {:ok, MapSet.new(["COPS"])}
      end
    }
  end

  defp control_values(blocks) do
    Enum.flat_map(blocks, fn block ->
      block
      |> Map.get("elements", [])
      |> Enum.flat_map(fn
        %{"value" => value} -> [value]
        _not_a_control -> []
      end)
    end)
  end

  defp action_ids(blocks) do
    Enum.flat_map(blocks, fn block ->
      [Map.get(block, "accessory") | List.wrap(Map.get(block, "elements"))]
      |> Enum.flat_map(fn
        %{"action_id" => action_id} -> [action_id]
        _not_an_action -> []
      end)
    end)
  end
end
