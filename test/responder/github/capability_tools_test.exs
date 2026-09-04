defmodule Responder.GitHub.CapabilityToolsTest do
  use ExUnit.Case, async: true

  alias Responder.Delivery.PlatformAction
  alias Responder.Episodes.Episode
  alias Responder.GitHub.{CapabilityTools, SourceRef}
  alias Responder.Work.Turn

  defmodule ContextAPI do
    def read_context(client, request) do
      send(client, {:read_github_context, request})
      {:ok, %{"items" => [%{"title" => "Exact pull"}], "next_cursor" => nil}}
    end

    def search(client, request) do
      send(client, {:search_github, request})
      {:ok, %{"items" => [%{"title" => "Matching issue"}], "next_cursor" => "page:2"}}
    end
  end

  defmodule FailingContextAPI do
    def read_context(_client, _request), do: {:error, :offline}
    def search(_client, _request), do: raise("offline")
  end

  test "exposes GitHub's exact emoji set and freezes a current comment reaction" do
    options = options()

    assert [read, search, %{"name" => "set_github_reaction"} = tool] =
             CapabilityTools.list(options)

    assert read["name"] == "read_github_conversation"
    assert search["name"] == "search_github"

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

  test "reads the exact bound pull request and searches only its configured repository" do
    options = context_options()
    binding = work_binding()

    assert {:ok, %{"items" => [%{"title" => "Exact pull"}]}} =
             CapabilityTools.call(
               "read_github_conversation",
               %{"cursor" => nil, "limit" => 20, "section" => "subject"},
               binding,
               options
             )

    assert_received {:read_github_context,
                     %{
                       limit: 20,
                       number: 42,
                       page: 1,
                       repository: "octo/example",
                       review_root_id: 8_001,
                       section: "subject",
                       subject_kind: "pull"
                     }}

    assert {:ok, %{"next_cursor" => "page:2"}} =
             CapabilityTools.call(
               "search_github",
               %{
                 "cursor" => nil,
                 "kind" => "issues",
                 "limit" => 10,
                 "query" => "freshness receipt",
                 "state" => "open"
               },
               binding,
               options
             )

    assert_received {:search_github,
                     %{
                       kind: "issues",
                       limit: 10,
                       page: 1,
                       query: "freshness receipt",
                       repository: "octo/example",
                       state: "open"
                     }}
  end

  test "context tools reject crossed destinations cursors and unconfigured clients" do
    options = context_options()

    crossed =
      put_in(
        work_binding(),
        [:episode, Access.key!(:destination_conversation_ref)],
        "github:other:repository:99"
      )

    assert CapabilityTools.call(
             "read_github_conversation",
             %{"cursor" => nil, "limit" => 20, "section" => "subject"},
             crossed,
             options
           ) == {:error, "unauthorized"}

    assert CapabilityTools.call(
             "search_github",
             %{
               "cursor" => "page:11",
               "kind" => "all",
               "limit" => 20,
               "query" => "test",
               "state" => "all"
             },
             work_binding(),
             options
           ) == {:error, "invalid_arguments"}

    assert CapabilityTools.call(
             "read_github_conversation",
             %{"cursor" => nil, "limit" => 20, "section" => "subject"},
             work_binding(),
             options()
           ) == {:error, "temporarily_unavailable"}
  end

  test "context tools validate every bound subject and provider boundary" do
    options = context_options()
    binding = work_binding()

    assert {:ok, %{"items" => [%{"title" => "Exact pull"}]}} =
             CapabilityTools.call(
               "read_github_conversation",
               %{"cursor" => "page:2", "limit" => 1, "section" => "review_thread"},
               binding,
               options
             )

    assert_received {:read_github_context, %{page: 2, review_root_id: 8_001}}

    issue =
      put_in(
        binding,
        [:episode, Access.key!(:destination_thread_ref)],
        "github:github-main:issue:42"
      )

    assert {:ok, _result} =
             CapabilityTools.call(
               "read_github_conversation",
               %{"cursor" => nil, "limit" => 20, "section" => "issue_comments"},
               issue,
               options
             )

    for {name, arguments, rejected_binding, expected} <- [
          {"read_github_conversation", :invalid, binding, "invalid_arguments"},
          {"read_github_conversation",
           %{"cursor" => "next", "limit" => 20, "section" => "subject"}, binding,
           "invalid_arguments"},
          {"read_github_conversation", %{"cursor" => nil, "limit" => 20, "section" => "reviews"},
           issue, "invalid_arguments"},
          {"search_github", :invalid, binding, "invalid_arguments"},
          {"search_github",
           %{"cursor" => nil, "kind" => "all", "limit" => 20, "query" => "   ", "state" => "all"},
           binding, "invalid_arguments"},
          {"search_github",
           %{
             "cursor" => nil,
             "kind" => "all",
             "limit" => 20,
             "query" => "test",
             "state" => "all"
           }, %{}, "unauthorized"}
        ] do
      assert CapabilityTools.call(name, arguments, rejected_binding, options) ==
               {:error, expected}
    end

    wrong_repository =
      put_in(
        binding,
        [:episode, Access.key!(:destination_conversation_ref)],
        "github:github-main:repository:2002"
      )

    assert CapabilityTools.call(
             "search_github",
             %{
               "cursor" => nil,
               "kind" => "all",
               "limit" => 20,
               "query" => "test",
               "state" => "all"
             },
             wrong_repository,
             options
           ) == {:error, "unauthorized"}

    failing =
      CapabilityTools.options!(%{
        bindings: %{
          "github-main" => %{
            api: FailingContextAPI,
            client: self(),
            repository_full_name: "octo/example",
            repository_id: 2_001
          }
        }
      })

    assert CapabilityTools.call(
             "read_github_conversation",
             %{"cursor" => nil, "limit" => 20, "section" => "subject"},
             binding,
             failing
           ) == {:error, "temporarily_unavailable"}

    assert CapabilityTools.call(
             "search_github",
             %{
               "cursor" => nil,
               "kind" => "all",
               "limit" => 20,
               "query" => "test",
               "state" => "all"
             },
             binding,
             failing
           ) == {:error, "temporarily_unavailable"}
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

    assert_raise ArgumentError, ~r/authority is invalid/, fn ->
      CapabilityTools.options!(bindings: MapSet.new(["github-main"]), clients: [])
    end

    assert_raise ArgumentError, ~r/authority is invalid/, fn ->
      CapabilityTools.options!(
        bindings: %{
          "github-main" => %{
            api: ContextAPI,
            client: self(),
            repository_full_name: "not-a-repository",
            repository_id: 2_001
          }
        },
        clients: %{"github-main" => :invalid}
      )
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

  defp context_options do
    CapabilityTools.options!(%{
      bindings: %{
        "github-main" => %{
          api: ContextAPI,
          client: self(),
          repository_full_name: "octo/example",
          repository_id: 2_001
        }
      }
    })
  end

  defp work_binding do
    %{
      episode: %Episode{
        id: "episode-id",
        destination_conversation_ref: "github:github-main:repository:2001",
        destination_thread_ref: "github:github-main:pull:42:review-thread:8001",
        destination_transport: "github"
      },
      turn: %Turn{id: "turn-id", lease_ref: Ecto.UUID.generate()}
    }
  end
end
