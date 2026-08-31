defmodule Responder.Ingress.AdaptersTest do
  use ExUnit.Case, async: true

  alias Responder.Ingress.Adapters
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.Webhooks.{Input, Route}

  @occurred_at ~U[2026-08-27 12:00:00Z]

  defmodule WrongSourceAdapter do
    @behaviour Responder.Ingress.Adapter

    alias Responder.Ingress.AdaptersTest
    alias Responder.Slack.Input

    @impl true
    def source_kind, do: "wrong_source"

    @impl true
    def normalize(_event, _binding) do
      Input.new(AdaptersTest.slack_event())
    end
  end

  defmodule InvalidResultAdapter do
    @behaviour Responder.Ingress.Adapter

    @impl true
    def source_kind, do: "invalid_result"

    @impl true
    def normalize(_event, _binding), do: :not_an_adapter_result
  end

  test "registered Slack and universal webhook adapters produce the existing canonical inputs" do
    slack_event = slack_event()

    assert {:ok, expected_slack} = SlackInput.new(slack_event)
    assert Adapters.normalize("slack", slack_event, nil) == {:ok, expected_slack}

    route = route!()

    webhook_event = %{
      metadata: [
        event_id: "evt-123",
        event_type: "unknown.changed",
        occurred_at: @occurred_at,
        occurred_at_source: :source,
        revision: 1
      ],
      payload: %{"anything" => [1, true, nil]}
    }

    assert {:ok, expected_webhook} =
             Input.new(route, webhook_event.payload, webhook_event.metadata)

    assert Adapters.normalize("webhook", webhook_event, route) == {:ok, expected_webhook}
  end

  test "unknown and malformed adapter registrations fail without creating atoms" do
    untrusted = "future-#{System.unique_integer([:positive])}"

    assert Adapters.normalize(untrusted, %{}, nil) ==
             {:error, {:unknown_ingress_adapter, untrusted}}

    assert Adapters.prepare(%{"slack" => String}) ==
             {:error, {:invalid_ingress_adapter, "slack"}}

    assert Adapters.prepare(:not_a_registry) ==
             {:error, {:invalid_ingress_adapters, :registry}}

    assert {:ok, registry} = Adapters.prepare(%{"slack" => SlackInput})
    assert Map.keys(registry) == ["slack"]

    assert Adapters.normalize(:slack, %{}, nil) ==
             {:error, {:unknown_ingress_adapter, :slack}}
  end

  test "the registry refuses output that crosses its registered source boundary" do
    assert {:ok, wrong_source} = Adapters.prepare(%{"wrong_source" => WrongSourceAdapter})

    assert Adapters.normalize("wrong_source", %{}, nil, wrong_source) ==
             {:error, {:invalid_ingress_adapter_output, "wrong_source", :source_kind}}

    assert {:ok, invalid_result} =
             Adapters.prepare(%{"invalid_result" => InvalidResultAdapter})

    assert Adapters.normalize("invalid_result", %{}, nil, invalid_result) ==
             {:error, {:invalid_ingress_adapter_output, "invalid_result", :result}}

    assert SlackInput.normalize(%{}, :unexpected_binding) ==
             {:error, {:invalid_slack_input, :binding}}

    assert Input.normalize(%{}, route!()) ==
             {:error, {:invalid_webhook_input, :adapter_event}}
  end

  @doc false
  def slack_event do
    %{
      actor: %{kind: :app, ref: "A123"},
      channel_ref: "C456",
      content: %{"text" => "A generic Slack message"},
      event_kind: :message,
      event_ref: "Ev123",
      message_ref: "1787832000.000100",
      occurred_at: @occurred_at,
      revision: 1,
      thread_ref: nil,
      workspace_ref: "T123"
    }
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
