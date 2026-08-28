defmodule Responder.Webhooks.InputTest do
  use ExUnit.Case, async: true

  alias Responder.Ingress.Input, as: IngressInput
  alias Responder.Webhooks.{Input, Route}

  @occurred_at ~U[2026-08-27 12:00:00Z]

  test "wraps any JSON value without letting payload fields control routing" do
    route = route!()

    payload = %{
      "destination" => %{"conversation_ref" => "attacker-selected"},
      "nested" => [1, true, nil],
      "text" => "An integration Responder has never seen"
    }

    assert {:ok, input} =
             Input.new(route, payload,
               event_id: "evt-123",
               event_type: "vendor.changed",
               occurred_at: @occurred_at,
               occurred_at_source: :source,
               revision: 2
             )

    assert input.destination == route.destination
    assert input.can_react == false
    assert input.source == %{kind: :webhook, ref: "universal"}
    assert input.actor == %{kind: :system, ref: "universal"}
    assert input.content == %{"event_type" => "vendor.changed", "payload" => payload}
    assert input.event_kind == :event
    assert input.revision == 2

    assert IngressInput.allowed_actions(input) == [
             :start_episode,
             :continue_episode,
             :reply,
             :ignore
           ]
  end

  test "accepts scalar and null payloads" do
    for payload <- [nil, true, 42, "hello", [1, 2, 3]] do
      assert {:ok, input} =
               Input.new(route!(), payload,
                 event_id: "evt-#{inspect(payload)}",
                 event_type: nil,
                 occurred_at: @occurred_at,
                 occurred_at_source: :source,
                 revision: 1
               )

      assert input.content["payload"] == payload
    end
  end

  test "rejects malformed metadata without raising" do
    assert {:error, {:invalid_webhook_input, :event_id}} =
             Input.new(route!(), %{},
               event_id: " ",
               event_type: nil,
               occurred_at: @occurred_at,
               occurred_at_source: :source,
               revision: 1
             )

    assert {:error, {:invalid_webhook_input, :revision}} =
             Input.new(route!(), %{},
               event_id: "evt-1",
               event_type: nil,
               occurred_at: @occurred_at,
               occurred_at_source: :source,
               revision: 0
             )

    assert {:error, {:invalid_webhook_input, :revision}} =
             Input.new(route!(), %{},
               event_id: "evt-1",
               event_type: nil,
               occurred_at: @occurred_at,
               occurred_at_source: :source,
               revision: 9_223_372_036_854_775_808
             )
  end

  defp route! do
    assert {:ok, route} =
             Route.new(%{
               auth: {:bearer, "a-secret-token-long-enough"},
               destination: %{
                 conversation_ref: "slack:T123:C456",
                 thread_ref: nil,
                 transport: "slack"
               },
               name: "universal"
             })

    route
  end
end
