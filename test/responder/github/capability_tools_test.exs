defmodule Responder.GitHub.CapabilityToolsTest do
  use ExUnit.Case, async: true

  alias Responder.Delivery.PlatformAction
  alias Responder.Episodes.Episode
  alias Responder.GitHub.{CapabilityTools, SourceRef}
  alias Responder.Work.Turn

  test "exposes GitHub's exact emoji set and freezes a current comment reaction" do
    options = options()
    assert [%{"name" => "set_github_reaction"} = tool] = CapabilityTools.list(options)

    assert get_in(tool, ["inputSchema", "properties", "emoji", "enum"]) ==
             ~w(+1 -1 confused eyes heart hooray laugh rocket)

    item_ref = SourceRef.item("github-main", "issue_comment", 9_001)

    assert {:ok, %{"action_ref" => "platform-action:github", "status" => "pending"}} =
             CapabilityTools.call(
               "set_github_reaction",
               %{"emoji" => "+1", "item_ref" => item_ref},
               work_binding(),
               options
             )

    assert_received {:enqueue_action, attributes}
    assert attributes.host_slot == "reaction"
    assert attributes.tool == :set_github_reaction
    assert attributes.transport == "github"
    assert attributes.source_item_ref == "github:issue_comment:9001"
    assert attributes.document == %{"action" => "add", "emoji_name" => "+1"}
  end

  test "rejects another repository binding and unsupported Slack emoji names" do
    options = options()

    assert CapabilityTools.call(
             "set_github_reaction",
             %{
               "emoji" => "thumbsup",
               "item_ref" => SourceRef.item("github-main", "issue_comment", 9_001)
             },
             work_binding(),
             options
           ) == {:error, "invalid_arguments"}

    assert CapabilityTools.call(
             "set_github_reaction",
             %{
               "emoji" => "eyes",
               "item_ref" => SourceRef.item("another-app", "issue_comment", 9_001)
             },
             work_binding(),
             options
           ) == {:error, "unauthorized"}

    refute_received {:enqueue_action, _attributes}
  end

  test "malformed reactions and capability authority fail closed" do
    options = options()

    assert CapabilityTools.call("unknown", %{}, work_binding(), options) ==
             {:error, "unknown_tool"}

    assert CapabilityTools.call(
             "set_github_reaction",
             :invalid,
             work_binding(),
             options
           ) == {:error, "invalid_arguments"}

    assert CapabilityTools.call(
             "set_github_reaction",
             %{
               "emoji" => "eyes",
               "extra" => true,
               "item_ref" => SourceRef.item("github-main", "issue_comment", 9_001)
             },
             work_binding(),
             options
           ) == {:error, "invalid_arguments"}

    assert_raise ArgumentError, ~r/options are invalid/, fn ->
      CapabilityTools.options!(:invalid)
    end

    assert_raise ArgumentError, ~r/options are invalid/, fn ->
      CapabilityTools.options!(bindings: %{}, bindings: %{})
    end

    assert_raise ArgumentError, ~r/bindings are invalid/, fn ->
      CapabilityTools.options!(bindings: ["github-main"])
    end

    assert_raise ArgumentError, ~r/authority is invalid/, fn ->
      CapabilityTools.options!(bindings: %{"github-main" => :trusted}, current_input: :invalid)
    end

    assert CapabilityTools.options!(bindings: MapSet.new(["github-main"])).bindings ==
             MapSet.new(["github-main"])

    assert_raise ArgumentError, ~r/bindings are invalid/, fn ->
      CapabilityTools.options!(bindings: %{"Not Valid" => :trusted})
    end

    assert CapabilityTools.call(
             "set_github_reaction",
             %{"emoji" => "eyes", "item_ref" => "not-a-source-ref"},
             work_binding(),
             options
           ) == {:error, "unauthorized"}

    unavailable = %{options | current_input: fn _binding, _source -> {:error, :offline} end}

    assert CapabilityTools.call(
             "set_github_reaction",
             %{
               "emoji" => "eyes",
               "item_ref" => SourceRef.item("github-main", "issue_comment", 9_001)
             },
             work_binding(),
             unavailable
           ) == {:error, "temporarily_unavailable"}

    crashing = %{options | enqueue_action: fn _binding, _attributes -> raise "offline" end}

    assert CapabilityTools.call(
             "set_github_reaction",
             %{
               "emoji" => "eyes",
               "item_ref" => SourceRef.item("github-main", "issue_comment", 9_001)
             },
             work_binding(),
             crashing
           ) == {:error, "temporarily_unavailable"}
  end

  defp options do
    %{
      bindings: %{"github-main" => :trusted},
      current_input: fn _binding, source ->
        {:ok,
         %{
           "destination" => %{
             "conversation_ref" => "github:#{source.binding}:repository:2001",
             "thread_ref" => "github:#{source.binding}:issue:42",
             "transport" => "github"
           }
         }}
      end,
      enqueue_action: fn _binding, attributes ->
        send(self(), {:enqueue_action, attributes})

        {:ok,
         %{
           action: %PlatformAction{action_ref: "platform-action:github", status: :pending},
           status: :created
         }}
      end
    }
  end

  defp work_binding do
    %{
      episode: %Episode{id: "episode-id"},
      turn: %Turn{id: "turn-id", lease_ref: Ecto.UUID.generate()}
    }
  end
end
