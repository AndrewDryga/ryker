defmodule Responder.Slack.InputTest do
  use ExUnit.Case, async: true

  alias Responder.Slack.Input

  @occurred_at ~U[2026-08-27 12:00:00Z]

  test "keeps arbitrary Slack content as data while routing from trusted fields" do
    content = %{
      "blocks" => [%{"type" => "section", "text" => %{"text" => "STATE CHANGED"}}],
      "metadata" => %{"vendor" => "an-app-responder-has-never-seen"},
      "text" => "Whatever this app chooses to say",
      "thread_ref" => "malicious-content-cannot-route"
    }

    assert {:ok, input} = Input.new(valid_attributes(content: content))

    assert input.content == content
    assert input.occurred_at == ~U[2026-08-27 12:00:00.000000Z]

    assert Input.destination(input) == %{
             conversation_ref: "slack:T123:C456",
             thread_ref: "1787832000.000100",
             transport: "slack"
           }
  end

  test "a reply remains bound to its existing thread" do
    assert {:ok, input} =
             Input.new(valid_attributes(thread_ref: "1787831000.000001"))

    assert Input.destination(input).thread_ref == "1787831000.000001"
  end

  test "the Slack event identity is stable but changed content has a different fingerprint" do
    assert {:ok, first} = Input.new(valid_attributes())
    assert {:ok, retried} = Input.new(valid_attributes())

    assert Input.dedupe_key(first) == Input.dedupe_key(retried)
    assert Input.fingerprint(first) == Input.fingerprint(retried)

    assert {:ok, changed} =
             Input.new(valid_attributes(content: %{"text" => "changed after retry"}))

    assert Input.dedupe_key(first) == Input.dedupe_key(changed)
    refute Input.fingerprint(first) == Input.fingerprint(changed)
  end

  test "rejects malformed trusted fields and unbounded content without raising" do
    assert {:error, {:invalid_input, :revision}} = Input.new(valid_attributes(revision: 0))

    assert {:error, {:invalid_input, :actor}} =
             Input.new(valid_attributes(actor: %{kind: :unknown, ref: "X1"}))

    assert {:error, {:invalid_input, :content, {:too_large, _, _}}} =
             Input.new(valid_attributes(content: %{"text" => String.duplicate("x", 300_000)}))

    assert {:error, {:invalid_input, :content, {:invalid_json_value, _, _}}} =
             Input.new(valid_attributes(content: %{"text" => <<255>>}))
  end

  test "rejects Slack fields whose derived episode command would be invalid" do
    assert {:error, {:invalid_input, :episode_envelope, :destination}} =
             Input.new(
               valid_attributes(
                 channel_ref: String.duplicate("c", 1_024),
                 workspace_ref: String.duplicate("w", 1_024)
               )
             )

    assert {:error, {:invalid_input, :episode_envelope, :actor_ref}} =
             Input.new(valid_attributes(actor: %{kind: :user, ref: String.duplicate("u", 1_024)}))
  end

  test "accepts a large durable payload when the complete derived command stays bounded" do
    assert {:ok, input} =
             Input.new(valid_attributes(content: %{"text" => String.duplicate("x", 45_000)}))

    assert input.content["text"] |> byte_size() == 45_000
  end

  defp valid_attributes(overrides \\ []) do
    defaults = [
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
    ]

    Keyword.merge(defaults, overrides)
  end
end
