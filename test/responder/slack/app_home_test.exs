defmodule Responder.Slack.AppHomeTest do
  use ExUnit.Case, async: true

  alias Responder.Slack.{AppHome, HomeEvent}

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
        published_work: 5
      },
      behaviors: [
        %{kind: :guidance, ref: "behavior:one", status: :active, subject: "Release checks"}
      ],
      incidents: [
        %{
          channel_ref: "CINCIDENT",
          ref: "incident-room:one",
          status: :ready,
          title: "Checkout API latency"
        }
      ],
      memories: [
        %{kind: :repository_binding, ref: "memory:one", subject: "checkout-api"}
      ],
      memory_review_count: 3,
      memory_reviews: [
        %{
          "entries" => [
            %{
              "scope" => "workspace",
              "scope_ref" => "slack:T123",
              "subject" => "checkout-api",
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
        }
      ],
      needs_attention: [
        %{
          kind: :operator_input,
          ref: "episode:one",
          title: "Choose the sampling strategy"
        }
      ],
      schedules: [
        %{next_occurrence_at: ~U[2026-08-29 12:00:00Z], ref: "schedule:one", title: "Daily audit"}
      ],
      work: [
        %{
          next_action: "continue_work",
          ref: "task-card:one",
          state: :working,
          title: "Repair checkout deploy"
        }
      ]
    }

    options = options(calls, fn "T123", "U123" -> snapshot end)

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
    assert text =~ "Forget all (2)"
    assert text =~ "Merge 2 entries?"
    assert text =~ "checkout-api-2"
    assert text =~ "scope: workspace (slack:T123)"
    assert text =~ "visibility: workspace"
    assert text =~ "2 more memory reviews are available"
    assert text =~ "responder_home_disable_behavior"
    assert text =~ "responder_home_pause_schedule"
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
      %{kind: :guidance, next_action: :continue_work, ref: "row:#{index}", status: :active}
    end

    snapshot = %{
      behaviors: Enum.map(1..5, row),
      counts: %{},
      incidents: Enum.map(1..5, row),
      memories: Enum.map(1..5, row),
      memory_review_count: 5,
      memory_reviews: reviews,
      needs_attention: Enum.map(1..8, row),
      schedules: Enum.map(1..5, row),
      work: Enum.map(1..8, row)
    }

    assert {:ok, %{access: :operator, outcome: :published}} =
             AppHome.handle(event("U123"), options(calls, fn _, _ -> snapshot end))

    assert [{"U123", %{"blocks" => blocks}}] = Agent.get(calls, & &1)
    assert length(blocks) < 100
    rendered = Jason.encode!(blocks)
    assert rendered =~ "3 more memory reviews are available"
    assert rendered =~ "visibility: workspace; value: VALUE-"
    assert rendered =~ "Durable state remains authoritative"
  end

  test "full nonoperators receive no operational details" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    options =
      options(calls, fn _workspace_ref, _actor_ref ->
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
        options(calls, fn _, _ -> flunk("must not query") end),
        [:client, :allowed],
        MapSet.new()
      )

    assert AppHome.handle(event("U123"), options) ==
             {:ok, %{access: :denied, outcome: :ignored}}

    assert Agent.get(calls, & &1) == []
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
      projection: projection
    }
  end
end
