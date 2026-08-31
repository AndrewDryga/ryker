defmodule Responder.Slack.InputTest do
  use ExUnit.Case, async: true

  alias Responder.Ingress.Input
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.Slack.SourceRef

  @occurred_at ~U[2026-08-27 12:00:00Z]

  test "keeps arbitrary Slack content as data while routing from trusted fields" do
    content = %{
      "blocks" => [%{"type" => "section", "text" => %{"text" => "STATE CHANGED"}}],
      "metadata" => %{"vendor" => "an-app-responder-has-never-seen"},
      "text" => "Whatever this app chooses to say",
      "thread_ref" => "malicious-content-cannot-route"
    }

    assert {:ok, input} = SlackInput.new(valid_attributes(content: content))

    assert input.content == content
    assert input.occurred_at == ~U[2026-08-27 12:00:00.000000Z]

    assert input.destination == %{
             conversation_ref: "slack:T123:C456",
             thread_ref: "1787832000.000100",
             transport: "slack"
           }
  end

  test "a reply remains bound to its existing thread" do
    assert {:ok, input} =
             SlackInput.new(valid_attributes(thread_ref: "1787831000.000001"))

    assert input.destination.thread_ref == "1787831000.000001"
    assert input.source_item_ref == "1787832000.000100"
    refute input.source_item_ref == input.destination.thread_ref
  end

  test "a deleted Slack message cannot be offered a reaction" do
    assert {:ok, input} = SlackInput.new(valid_attributes(event_kind: :delete))

    assert input.source_capabilities == %{}
    refute :react in Input.allowed_actions(input)
  end

  test "source adapters use bounded string identities and typed reaction capabilities" do
    assert {:ok, slack} = SlackInput.new(valid_attributes())

    assert slack.source == %{kind: "slack", ref: "T123"}

    assert slack.source_capabilities == %{
             "react" => %{"emoji_names" => nil}
           }

    assert Input.reaction_names(slack) == :any

    attributes =
      slack
      |> Map.from_struct()
      |> Map.merge(%{
        source: %{kind: "github", ref: "installation:42"},
        source_capabilities: %{
          "react" => %{
            "emoji_names" => ~w(+1 -1 confused eyes heart hooray laugh rocket)
          }
        }
      })

    assert {:ok, github} = Input.new(attributes)
    assert github.source.kind == "github"
    assert Input.reaction_names(github) == ~w(+1 -1 confused eyes heart hooray laugh rocket)
    assert :react in Input.allowed_actions(github)

    assert Input.new(%{attributes | source: %{kind: :github, ref: "installation:42"}}) ==
             {:error, {:invalid_input, :source}}

    assert Input.new(%{
             attributes
             | source_capabilities: %{
                 "react" => %{"emoji_names" => ["eyes", "not a github reaction"]}
               }
           }) == {:error, {:invalid_input, :source_capabilities}}
  end

  test "Slack post grants are canonical, source-bound, and user-only" do
    destination_ref = SourceRef.channel("T123", "C789")

    assert {:ok, granted} =
             SlackInput.new(
               valid_attributes(
                 actor: %{kind: :user, ref: "U123"},
                 post_destination_refs: [destination_ref]
               )
             )

    assert granted.source_capabilities["post_slack_message"] == %{
             "destination_refs" => [destination_ref]
           }

    for invalid_ref <- [
          "post to C789",
          SourceRef.channel("T999", "C789"),
          SourceRef.message("T123", "C789", "1787832000.000100")
        ] do
      assert SlackInput.new(
               valid_attributes(
                 actor: %{kind: :user, ref: "U123"},
                 post_destination_refs: [invalid_ref]
               )
             ) ==
               {:error, {:invalid_input, :source_capabilities}}
    end

    assert {:ok, app_input} =
             SlackInput.new(
               valid_attributes(
                 actor: %{kind: :app, ref: "A123"},
                 post_destination_refs: [destination_ref]
               )
             )

    refute Map.has_key?(app_input.source_capabilities, "post_slack_message")
  end

  test "the Slack event identity is stable but changed content has a different fingerprint" do
    assert {:ok, first} = SlackInput.new(valid_attributes())
    assert {:ok, retried} = SlackInput.new(valid_attributes())

    assert Input.dedupe_key(first) == Input.dedupe_key(retried)
    assert Input.fingerprint(first) == Input.fingerprint(retried)

    assert {:ok, changed} =
             SlackInput.new(valid_attributes(content: %{"text" => "changed after retry"}))

    assert Input.dedupe_key(first) == Input.dedupe_key(changed)
    refute Input.fingerprint(first) == Input.fingerprint(changed)
  end

  test "rejects malformed trusted fields and unbounded content without raising" do
    assert {:error, {:invalid_input, :revision}} = SlackInput.new(valid_attributes(revision: 0))

    assert {:error, {:invalid_input, :actor}} =
             SlackInput.new(valid_attributes(actor: %{kind: :unknown, ref: "X1"}))

    assert {:error, {:invalid_input, :content, {:too_large, _, _}}} =
             SlackInput.new(
               valid_attributes(content: %{"text" => String.duplicate("x", 300_000)})
             )

    assert {:error, {:invalid_input, :content, {:invalid_json_value, _, _}}} =
             SlackInput.new(valid_attributes(content: %{"text" => <<255>>}))
  end

  test "rejects Slack fields whose derived episode command would be invalid" do
    assert {:error, {:invalid_input, :destination}} =
             SlackInput.new(
               valid_attributes(
                 channel_ref: String.duplicate("c", 1_024),
                 workspace_ref: String.duplicate("w", 1_024)
               )
             )

    assert {:error, {:invalid_input, :episode_envelope, :actor_ref}} =
             SlackInput.new(
               valid_attributes(actor: %{kind: :user, ref: String.duplicate("u", 1_024)})
             )
  end

  test "accepts a large durable payload when the complete derived command stays bounded" do
    assert {:ok, input} =
             SlackInput.new(valid_attributes(content: %{"text" => String.duplicate("x", 45_000)}))

    assert input.content["text"] |> byte_size() == 45_000
  end

  test "the generic ingress boundary rejects malformed adapter output without raising" do
    assert {:ok, valid} = SlackInput.new(valid_attributes())
    attributes = Map.from_struct(valid)

    assert {:ok, from_keyword} = Input.new(Map.to_list(attributes))
    assert from_keyword == valid

    assert Input.prepare(:not_an_input) == {:error, {:invalid_input, :type}}
    assert Input.new(:not_attributes) == {:error, {:invalid_input, :fields}}

    assert Input.new(actor: valid.actor, actor: valid.actor) ==
             {:error, {:invalid_input, :fields}}

    assert Input.new(%{attributes | content: "not a JSON object"}) ==
             {:error, {:invalid_input, :content}}

    assert Input.new(%{attributes | source: %{kind: "slack"}}) ==
             {:error, {:invalid_input, :source}}

    assert Input.new(%{attributes | destination: %{transport: "slack"}}) ==
             {:error, {:invalid_input, :destination}}

    assert Input.new(%{attributes | occurred_at: ~D[2026-08-27]}) ==
             {:error, {:invalid_input, :occurred_at}}
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
