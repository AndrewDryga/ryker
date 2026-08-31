defmodule Responder.Slack.CapabilityToolsTest do
  use ExUnit.Case, async: true

  alias Responder.Delivery.PlatformAction
  alias Responder.Episodes.Episode
  alias Responder.Slack.{CapabilityTools, SourceRef}
  alias Responder.Work.Turn

  defmodule FakeActionTokens do
    def checkout(observer, event_ref, turn_id) do
      send(observer, {:token_checkout, event_ref, turn_id})
      {:ok, "xact-user-turn-secret"}
    end
  end

  defmodule BudgetExhaustedActionTokens do
    def checkout(_observer, _event_ref, _turn_id),
      do: {:error, :slack_search_budget_exhausted}
  end

  defmodule UnauthorizedActionTokens do
    def checkout(_observer, _event_ref, _turn_id),
      do: {:error, :slack_action_token_not_authorized}
  end

  defmodule FakeAPI do
    def list_conversations(observer, document) do
      send(observer, {:list_conversations, document})

      {:ok,
       %{
         "conversations" => [
           conversation("C456", false, "backend-ops"),
           conversation("G123", true, "current-private"),
           conversation("G999", true, "secret-private"),
           conversation("CEXT", false, "shared-external", true)
         ],
         "cursor" => "next-page"
       }}
    end

    def search_context(observer, token, document) do
      send(observer, {:search_context, token, document})

      {:ok,
       %{
         "next_cursor" => "next-page",
         "results" => %{
           "messages" => [
             %{
               "channel_id" => "C456",
               "content" => "The deploy completed.",
               "message_ts" => "1787832001.000200"
             }
           ]
         }
       }}
    end

    def conversation_info(observer, channel_ref) do
      send(observer, {:conversation_info, channel_ref})

      {:ok,
       %{
         "id" => channel_ref,
         "is_archived" => false,
         "is_ext_shared" => false,
         "is_private" => String.starts_with?(channel_ref, "G"),
         "name" => "incident-room"
       }}
    end

    def list_bookmarks(observer, channel_ref) do
      send(observer, {:list_bookmarks, channel_ref})

      {:ok,
       [
         %{
           "channel_id" => channel_ref,
           "entity_id" => nil,
           "id" => "BkRUNBOOK",
           "link" => "https://runbooks.example.test/checkout",
           "title" => "Checkout runbook",
           "type" => "link"
         },
         %{
           "channel_id" => channel_ref,
           "entity_id" => "F123",
           "id" => "BkFILE",
           "link" => "https://example.slack.com/files/F123",
           "title" => "Current architecture",
           "type" => "file"
         }
       ]}
    end

    def file_info(observer, file_ref) do
      send(observer, {:file_info, file_ref})

      {:ok,
       %{
         "channels" => ["C456"],
         "filetype" => "markdown",
         "id" => file_ref,
         "mimetype" => "text/markdown",
         "permalink" => "https://example.slack.com/files/#{file_ref}",
         "plain_text" => "# Checkout\nThe canonical deployment runbook.",
         "size" => 47,
         "title" => "Checkout runbook"
       }}
    end

    def read_messages(observer, channel_ref, thread_ref, document) do
      send(observer, {:read_messages, channel_ref, thread_ref, document})

      {:ok,
       %{
         "cursor" => "",
         "messages" => [
           %{
             "text" => "The deploy completed.",
             "ts" => thread_ref || "1787832001.000200",
             "user" => "U456"
           }
         ]
       }}
    end

    defp conversation(channel_ref, private, name, external \\ false) do
      %{
        "canvas_ref" => if(channel_ref == "C456", do: "FCHANNEL", else: nil),
        "channel_ref" => channel_ref,
        "is_archived" => false,
        "is_external_shared" => external,
        "is_private" => private,
        "name" => name,
        "purpose" => "Operations",
        "topic" => "Checkout service"
      }
    end
  end

  defmodule CrossAudienceSearchAPI do
    defdelegate list_conversations(observer, document), to: FakeAPI
    defdelegate list_bookmarks(observer, channel_ref), to: FakeAPI
    defdelegate read_messages(observer, channel_ref, thread_ref, document), to: FakeAPI

    def search_context(observer, token, document) do
      send(observer, {:search_context, token, document})

      {:ok,
       %{
         "next_cursor" => "",
         "results" => %{
           "channels" => [
             %{"channel_id" => "C456", "name" => "backend-ops"},
             %{"channel_id" => "G999", "name" => "secret-private"},
             %{"channel_id" => "CEXT", "name" => "shared-external"}
           ],
           "files" => [
             %{"file_id" => "FSAFE", "title" => "Public runbook"},
             %{"file_id" => "FPRIVATE", "title" => "Private plan"}
           ],
           "messages" => [
             message("C456", "Public deployment note", "1787832001.000200"),
             message("G999", "Private incident detail", "1787832002.000200"),
             message("CEXT", "Slack Connect customer detail", "1787832003.000200")
           ],
           "users" => [%{"name" => "Ada", "user_id" => "U123"}]
         }
       }}
    end

    def conversation_info(observer, channel_ref) do
      send(observer, {:conversation_info, channel_ref})

      {:ok,
       %{
         "id" => channel_ref,
         "is_archived" => false,
         "is_ext_shared" => channel_ref == "CEXT",
         "is_private" => channel_ref == "G999",
         "name" => "channel-#{channel_ref}"
       }}
    end

    def file_info(observer, file_ref) do
      send(observer, {:file_info, file_ref})

      {:ok,
       %{
         "channels" => if(file_ref == "FSAFE", do: ["C456"], else: ["G999"]),
         "filetype" => "markdown",
         "id" => file_ref,
         "mimetype" => "text/markdown",
         "permalink" => "https://example.slack.com/files/#{file_ref}",
         "size" => 20,
         "title" => file_ref
       }}
    end

    defp message(channel_ref, content, message_ref) do
      %{"channel_id" => channel_ref, "content" => content, "message_ts" => message_ref}
    end
  end

  test "list_slack_channels exposes public joined channels and only the current private channel" do
    options = options()

    assert Enum.map(CapabilityTools.list(options), & &1["name"]) == [
             "list_slack_channels",
             "search_slack",
             "read_slack_source",
             "set_slack_reaction",
             "post_slack_message"
           ]

    assert {:ok, result} =
             CapabilityTools.call(
               "list_slack_channels",
               %{
                 "configured_only" => false,
                 "cursor" => nil,
                 "include_archived" => false,
                 "include_resources" => true,
                 "kinds" => ["public_channel", "private_channel"],
                 "limit" => 50,
                 "query" => "operations"
               },
               work_binding(),
               options
             )

    assert_received {:list_conversations,
                     %{
                       "exclude_archived" => true,
                       "limit" => 50,
                       "types" => ["public_channel", "private_channel"]
                     }}

    assert Enum.map(result["conversations"], & &1["name"]) == [
             "backend-ops",
             "current-private"
           ]

    assert Enum.all?(result["conversations"], &(&1["resources_complete"] == false))

    [backend, current_private] = result["conversations"]

    assert backend["resources_unavailable"] == ["pins"]
    assert current_private["resources_unavailable"] == ["pins"]

    assert Enum.map(backend["resources"], & &1["kind"]) == [
             "bookmark",
             "bookmark",
             "canvas"
           ]

    assert_received {:list_bookmarks, "C456"}
    assert_received {:list_bookmarks, "G123"}

    assert {:ok, %{kind: :bookmark, resource_ref: "BkRUNBOOK"}} =
             backend["resources"]
             |> hd()
             |> Map.fetch!("source_ref")
             |> SourceRef.parse("T123")

    assert {:ok, %{kind: :canvas, resource_ref: "FCHANNEL"}} =
             backend["resources"]
             |> List.last()
             |> Map.fetch!("source_ref")
             |> SourceRef.parse("T123")

    assert result["visibility"] == "public_and_current_private"

    assert_received {:source_audit,
                     %{
                       authorized: true,
                       capability: "users.conversations",
                       requester_ref: "slack:user:U123",
                       result_count: 2,
                       tool: :list_slack_channels
                     }}
  end

  test "read_slack_source resolves an exact channel-bound file without widening visibility" do
    options = options()
    source_ref = SourceRef.file("T123", "C456", "F123")

    assert {:ok, result} =
             CapabilityTools.call(
               "read_slack_source",
               %{"source_ref" => source_ref, "view" => "document"},
               work_binding(),
               options
             )

    assert_received {:conversation_info, "C456"}
    assert_received {:file_info, "F123"}
    assert result["complete"] == true
    assert result["document"]["content"] == "# Checkout\nThe canonical deployment runbook."
    assert result["document"]["kind"] == "file"
    assert result["source_ref"] == source_ref

    assert_received {:source_audit,
                     %{
                       capability: "files.info",
                       channel_ref: "C456",
                       complete: true,
                       result_count: 1,
                       source_ref: ^source_ref,
                       tool: :read_slack_source
                     }}

    denied_options =
      put_in(options, [:api], __MODULE__.WrongChannelFileAPI)

    assert CapabilityTools.call(
             "read_slack_source",
             %{"source_ref" => source_ref, "view" => "document"},
             work_binding(),
             denied_options
           ) == {:error, "unauthorized"}
  end

  defmodule WrongChannelFileAPI do
    defdelegate list_conversations(observer, document), to: FakeAPI
    defdelegate search_context(observer, token, document), to: FakeAPI
    defdelegate conversation_info(observer, channel_ref), to: FakeAPI
    defdelegate read_messages(observer, channel_ref, thread_ref, document), to: FakeAPI
    defdelegate list_bookmarks(observer, channel_ref), to: FakeAPI

    def file_info(observer, file_ref) do
      send(observer, {:file_info, file_ref})

      {:ok,
       %{
         "channels" => ["C999"],
         "filetype" => "markdown",
         "id" => file_ref,
         "mimetype" => "text/markdown",
         "plain_text" => "secret",
         "size" => 6,
         "title" => "Other channel"
       }}
    end
  end

  defmodule InvalidSearchAPI do
    defdelegate list_conversations(observer, document), to: FakeAPI
    defdelegate conversation_info(observer, channel_ref), to: FakeAPI
    defdelegate read_messages(observer, channel_ref, thread_ref, document), to: FakeAPI
    defdelegate list_bookmarks(observer, channel_ref), to: FakeAPI
    defdelegate file_info(observer, file_ref), to: FakeAPI

    def search_context(_observer, _token, _document), do: {:ok, %{}}
  end

  defmodule AdversarialSearchAPI do
    defdelegate list_conversations(observer, document), to: FakeAPI
    defdelegate list_bookmarks(observer, channel_ref), to: FakeAPI
    defdelegate read_messages(observer, channel_ref, thread_ref, document), to: FakeAPI

    def search_context(observer, token, document) do
      send(observer, {:search_context, token, document})
      {:ok, Process.get(:adversarial_search_response)}
    end

    def conversation_info(observer, channel_ref) do
      send(observer, {:conversation_info, channel_ref})

      {:ok,
       %{
         "id" => channel_ref,
         "is_archived" => false,
         "is_ext_shared" => false,
         "is_private" => false,
         "name" => "channel-#{channel_ref}"
       }}
    end

    def file_info(observer, file_ref) do
      send(observer, {:file_info, file_ref})
      Process.get(:adversarial_file_response)
    end
  end

  test "read_slack_source resolves a bookmark as metadata without fetching its external link" do
    options = options()
    source_ref = SourceRef.bookmark("T123", "C456", "BkRUNBOOK")

    assert {:ok, result} =
             CapabilityTools.call(
               "read_slack_source",
               %{"source_ref" => source_ref, "view" => "metadata"},
               work_binding(),
               options
             )

    assert_received {:conversation_info, "C456"}
    assert_received {:list_bookmarks, "C456"}
    assert result["bookmark"]["link"] == "https://runbooks.example.test/checkout"
    assert result["bookmark"]["title"] == "Checkout runbook"
    assert result["complete"] == true
    refute_received {:file_info, _file_ref}

    assert_received {:source_audit,
                     %{
                       capability: "bookmarks.list",
                       result_count: 1,
                       source_ref: ^source_ref,
                       tool: :read_slack_source
                     }}
  end

  test "read_slack_source keeps channel, surrounding-message, canvas, and bookmark-file views typed" do
    options = options()

    channel_ref = SourceRef.channel("T123", "C456")

    assert {:ok, channel} =
             CapabilityTools.call(
               "read_slack_source",
               %{
                 "after" => nil,
                 "before" => nil,
                 "cursor" => nil,
                 "limit" => 25,
                 "source_ref" => channel_ref,
                 "view" => "channel"
               },
               work_binding(),
               options
             )

    assert channel["view"] == "channel"
    assert [%{"source_ref" => message_ref}] = channel["messages"]
    assert {:ok, %{kind: :message, channel_ref: "C456"}} = SourceRef.parse(message_ref, "T123")
    assert_received {:read_messages, "C456", nil, %{"limit" => 25}}

    surrounding_ref = SourceRef.message("T123", "C456", "1787832001.000200")

    assert {:ok, surrounding} =
             CapabilityTools.call(
               "read_slack_source",
               %{
                 "after" => nil,
                 "before" => nil,
                 "cursor" => nil,
                 "limit" => 10,
                 "source_ref" => surrounding_ref,
                 "view" => "surrounding"
               },
               work_binding(),
               options
             )

    assert surrounding["view"] == "surrounding"

    assert_received {:read_messages, "C456", nil,
                     %{
                       "latest" => "1787918401.999999",
                       "oldest" => "1787745601.000000"
                     }}

    canvas_ref = SourceRef.canvas("T123", "C456", "FCHANNEL")

    assert {:ok, canvas} =
             CapabilityTools.call(
               "read_slack_source",
               %{"source_ref" => canvas_ref, "view" => "document"},
               work_binding(),
               options
             )

    assert canvas["document"]["kind"] == "canvas"
    assert canvas["document"]["content_complete"] == true

    bookmark_ref = SourceRef.bookmark("T123", "C456", "BkFILE")

    assert {:ok, bookmark} =
             CapabilityTools.call(
               "read_slack_source",
               %{"source_ref" => bookmark_ref, "view" => "document"},
               work_binding(),
               options
             )

    assert bookmark["bookmark"]["target_source_ref"] ==
             SourceRef.file("T123", "C456", "F123")

    assert bookmark["document"]["kind"] == "file"
  end

  test "a channel bookmark cannot expose a file that is no longer shared in that channel" do
    source_ref = SourceRef.bookmark("T123", "C456", "BkFILE")
    options = put_in(options(), [:api], __MODULE__.WrongChannelFileAPI)

    assert CapabilityTools.call(
             "read_slack_source",
             %{"source_ref" => source_ref, "view" => "document"},
             work_binding(),
             options
           ) == {:error, "unauthorized"}

    assert_received {:conversation_info, "C456"}
    assert_received {:list_bookmarks, "C456"}
    assert_received {:file_info, "F123"}
  end

  test "metadata and link bookmarks never widen into message or external-URL reads" do
    options = options()
    message_ref = SourceRef.message("T123", "C456", "1787832001.000200")

    assert {:ok, metadata} =
             CapabilityTools.call(
               "read_slack_source",
               %{"source_ref" => message_ref, "view" => "metadata"},
               work_binding(),
               options
             )

    assert metadata["messages"] == []
    assert metadata["view"] == "metadata"
    refute_received {:read_messages, _, _, _}

    link_ref = SourceRef.bookmark("T123", "C456", "BkRUNBOOK")

    assert {:ok, link} =
             CapabilityTools.call(
               "read_slack_source",
               %{"source_ref" => link_ref, "view" => "document"},
               work_binding(),
               options
             )

    assert link["complete"] == true
    assert link["bookmark"]["link"] == "https://runbooks.example.test/checkout"
    refute Map.has_key?(link, "document")
    refute_received {:file_info, _}

    assert CapabilityTools.call(
             "read_slack_source",
             %{
               "source_ref" => SourceRef.bookmark("T123", "C456", "BkMISSING"),
               "view" => "metadata"
             },
             work_binding(),
             options
           ) == {:error, "not_found"}

    assert CapabilityTools.call(
             "read_slack_source",
             %{"source_ref" => message_ref, "view" => "document"},
             work_binding(),
             options
           ) == {:error, "invalid_arguments"}
  end

  test "search_slack uses one ephemeral user action token and returns host source refs" do
    options = options()

    assert Enum.map(CapabilityTools.list(options), & &1["name"]) == [
             "list_slack_channels",
             "search_slack",
             "read_slack_source",
             "set_slack_reaction",
             "post_slack_message"
           ]

    arguments = %{
      "after" => "2026-08-28T11:00:00Z",
      "author_ref" => "slack-user:U123",
      "before" => nil,
      "content_types" => ["messages"],
      "conversation_refs" => ["slack:T123:C456"],
      "cursor" => nil,
      "include_context" => true,
      "limit" => 20,
      "query" => "What happened to the deploy?"
    }

    assert {:ok, result} =
             CapabilityTools.call("search_slack", arguments, work_binding(), options)

    assert_received {:token_checkout, "Ev-current", "turn-row-id"}

    assert_received {:search_context, "xact-user-turn-secret", document}
    assert document["action_token"] == nil
    assert document["after"] == 1_787_914_800
    assert document["include_context_messages"] == true
    assert document["limit"] == 20
    assert document["query"] =~ "in:<#C456>"
    assert document["query"] =~ "from:<@U123>"

    assert_received {:source_audit,
                     %{
                       capability: "assistant.search.context",
                       result_count: 1,
                       source_ref: nil,
                       tool: :search_slack
                     }}

    [message] = get_in(result, ["results", "messages"])

    assert {:ok, %{channel_ref: "C456", kind: :message, message_ref: "1787832001.000200"}} =
             SourceRef.parse(message["source_ref"], "T123")
  end

  test "workspace search exposes only host-verified public results to an internal destination" do
    binding = public_work_binding()
    options = %{options() | api: CrossAudienceSearchAPI}

    assert {:ok, result} =
             CapabilityTools.call(
               "search_slack",
               %{valid_arguments() | "content_types" => ~w(messages files channels users)},
               binding,
               options
             )

    assert_received {:search_context, "xact-user-turn-secret", document}
    assert document["channel_types"] == ["public_channel"]

    assert [%{"channel_id" => "C456", "source_ref" => message_ref}] =
             result["results"]["messages"]

    assert {:ok, %{channel_ref: "C456"}} = SourceRef.parse(message_ref, "T123")

    assert [%{"file_id" => "FSAFE", "source_ref" => file_ref}] =
             result["results"]["files"]

    assert {:ok, %{channel_ref: "C456"}} = SourceRef.parse(file_ref, "T123")

    assert [%{"channel_id" => "C456", "source_ref" => channel_ref}] =
             result["results"]["channels"]

    assert {:ok, %{channel_ref: "C456"}} = SourceRef.parse(channel_ref, "T123")
    assert [%{"entity_ref" => "slack-user:U123"}] = result["results"]["users"]
  end

  test "an external destination cannot widen into the internal Slack workspace" do
    binding = public_work_binding("CEXT")
    options = %{options() | api: CrossAudienceSearchAPI}

    assert CapabilityTools.call("search_slack", valid_arguments(), binding, options) ==
             {:error, "unauthorized"}

    refute_received {:token_checkout, _, _}
    refute_received {:search_context, _, _}
  end

  test "malformed or crossed workspace search results fail closed" do
    options = %{options() | api: AdversarialSearchAPI}
    binding = public_work_binding()

    on_exit(fn ->
      Process.delete(:adversarial_search_response)
      Process.delete(:adversarial_file_response)
    end)

    cases = [
      {%{"results" => %{"unknown" => []}}, nil},
      {%{"results" => %{"messages" => %{}}}, nil},
      {%{"results" => %{"users" => [42]}}, nil},
      {%{"results" => %{"files" => [42]}}, nil},
      {%{"results" => %{"files" => [%{"file_id" => "FCROSSED"}]}},
       {:ok, %{"channels" => ["C456"], "id" => "FOTHER"}}},
      {%{"results" => %{"files" => [%{"file_id" => "FERROR"}]}},
       {:error, :slack_transport_error}},
      {%{
         "results" => %{
           "messages" => [%{"channel_id" => "bad id", "message_ts" => "1.000001"}]
         }
       }, nil},
      {%{"results" => %{"files" => [%{"file_id" => "bad id"}]}},
       {:ok, %{"channels" => ["C456"], "id" => "bad id"}}}
    ]

    for {response, file_response} <- cases do
      Process.put(:adversarial_search_response, response)
      Process.put(:adversarial_file_response, file_response)

      assert CapabilityTools.call("search_slack", valid_arguments(), binding, options) ==
               {:error, "temporarily_unavailable"}
    end
  end

  test "read_slack_source rechecks channel visibility and hydrates an exact thread" do
    options = options()
    source_ref = SourceRef.thread("T123", "G123", "1787832000.000100")

    assert {:ok, result} =
             CapabilityTools.call(
               "read_slack_source",
               %{
                 "after" => nil,
                 "before" => nil,
                 "cursor" => nil,
                 "limit" => 100,
                 "source_ref" => source_ref,
                 "view" => "thread"
               },
               work_binding(),
               options
             )

    assert_received {:conversation_info, "G123"}

    assert_received {:read_messages, "G123", "1787832000.000100",
                     %{
                       "cursor" => nil,
                       "inclusive" => true,
                       "latest" => nil,
                       "limit" => 100,
                       "oldest" => nil
                     }}

    assert result["complete"] == true
    assert result["source_ref"] == source_ref
    assert [%{"source_ref" => hydrated_ref}] = result["messages"]

    assert {:ok, %{kind: :message, channel_ref: "G123"}} =
             SourceRef.parse(hydrated_ref, "T123")

    assert_received {:source_audit,
                     %{
                       capability: "conversations.replies",
                       channel_ref: "G123",
                       result_count: 1,
                       source_ref: ^source_ref,
                       tool: :read_slack_source
                     }}

    assert CapabilityTools.call(
             "read_slack_source",
             %{
               "source_ref" => SourceRef.thread("T123", "G999", "1787832000.000100"),
               "view" => "thread"
             },
             work_binding(),
             options
           ) == {:error, "unauthorized"}
  end

  test "search_slack rejects destination widening and invalid arguments before token checkout" do
    options = options()
    arguments = valid_arguments()

    assert CapabilityTools.call(
             "search_slack",
             %{arguments | "conversation_refs" => ["slack:T999:C456"]},
             work_binding(),
             options
           ) == {:error, "unauthorized"}

    assert CapabilityTools.call(
             "search_slack",
             %{arguments | "limit" => 21},
             work_binding(),
             options
           ) == {:error, "invalid_arguments"}

    refute_received {:token_checkout, _, _}
    refute_received {:search_context, _, _}
  end

  test "search_slack distinguishes revoked action authority from budget exhaustion" do
    arguments = valid_arguments()

    assert CapabilityTools.call(
             "search_slack",
             arguments,
             work_binding(),
             %{options() | action_tokens: {UnauthorizedActionTokens, self()}}
           ) == {:error, "unauthorized"}

    assert CapabilityTools.call(
             "search_slack",
             arguments,
             work_binding(),
             %{options() | action_tokens: {BudgetExhaustedActionTokens, self()}}
           ) == {:error, "search_budget_exhausted"}

    assert CapabilityTools.call(
             "search_slack",
             arguments,
             work_binding(),
             %{options() | api: InvalidSearchAPI}
           ) == {:error, "temporarily_unavailable"}
  end

  test "set_slack_reaction freezes one exact current-message action and cannot remove others" do
    options = options()
    message_ref = SourceRef.message("T123", "G123", "1787832001.000200")

    assert {:ok, %{"action_ref" => "platform-action:reaction", "status" => "pending"}} =
             CapabilityTools.call(
               "set_slack_reaction",
               %{"action" => "add", "emoji" => "eyes", "message_ref" => message_ref},
               work_binding(),
               options
             )

    assert_received {:enqueue_action, attributes}
    assert attributes.host_slot == "reaction"
    assert attributes.document == %{"action" => "add", "emoji_name" => "eyes"}
    assert attributes.source_item_ref == "1787832001.000200"
    assert attributes.conversation_ref == "slack:T123:G123"

    assert CapabilityTools.call(
             "set_slack_reaction",
             %{"action" => "remove", "emoji" => "heart", "message_ref" => message_ref},
             work_binding(),
             options
           ) == {:error, "unauthorized"}

    refute_received {:enqueue_action, %{document: %{"action" => "remove"}}}

    assert {:ok, %{"status" => "pending"}} =
             CapabilityTools.call(
               "set_slack_reaction",
               %{"action" => "remove", "emoji" => "eyes", "message_ref" => message_ref},
               work_binding(),
               options
             )

    assert_received {:enqueue_action,
                     %{document: %{"action" => "remove", "emoji_name" => "eyes"}}}
  end

  test "post_slack_message creates an inert exact offer without treating prose as authority" do
    destination_ref = SourceRef.thread("T123", "G123", "1787832000.000100")
    instruction_ref = SourceRef.message("T123", "G123", "1787832001.000200")

    options =
      options()
      |> Map.put(:current_instruction, fn _binding, source, granted_destination_ref ->
        send(self(), {:instruction_checked, source.message_ref, granted_destination_ref})
        {:ok, %{actor_ref: "slack:user:U123"}}
      end)
      |> Map.put(:propose_post, fn _binding, payload ->
        send(self(), {:post_proposed, payload})

        {:ok,
         %{
           ref: "record:slack_post_offer:exact",
           status: :open
         }}
      end)

    assert {:ok,
            %{
              "kind" => "slack_post_offer",
              "record_ref" => "record:slack_post_offer:exact",
              "status" => "open"
            }} =
             CapabilityTools.call(
               "post_slack_message",
               %{
                 "destination_ref" => destination_ref,
                 "instruction_ref" => instruction_ref,
                 "message" => "The deployment is healthy."
               },
               work_binding(),
               options
             )

    assert_received {:conversation_info, "G123"}
    assert_received {:instruction_checked, "1787832001.000200", ^destination_ref}
    assert_received {:post_proposed, payload}
    assert payload["conversation_ref"] == "slack:T123:G123"
    assert payload["destination_ref"] == destination_ref
    assert payload["instruction_ref"] == instruction_ref
    assert payload["message"] == "The deployment is healthy."
    assert payload["requested_by_actor_ref"] == "slack:user:U123"
    assert payload["thread_ref"] == "1787832000.000100"
    assert payload["transport"] == "slack"
    refute_received {:enqueue_action, _attributes}

    denied_ref = SourceRef.channel("T123", "G999")

    assert CapabilityTools.call(
             "post_slack_message",
             %{
               "destination_ref" => denied_ref,
               "instruction_ref" => instruction_ref,
               "message" => "This must remain private."
             },
             work_binding(),
             options
           ) == {:error, "unauthorized"}

    refute_received {:post_proposed, _payload}
  end

  test "post authority is an exact ingress grant rather than instruction prose" do
    destination_ref = SourceRef.channel("T123", "C456")

    granted = %{
      "content" => %{"text" => "do not post this anywhere"},
      "source_capabilities" => %{
        "post_slack_message" => %{"destination_refs" => [destination_ref]}
      }
    }

    assert CapabilityTools.authorized_post_instruction?(granted, destination_ref)

    refute CapabilityTools.authorized_post_instruction?(
             granted,
             SourceRef.channel("T123", "C789")
           )

    refute CapabilityTools.authorized_post_instruction?(
             %{
               "content" => %{
                 "text" => "post to <#C456>: this arbitrary prose is not authority"
               },
               "source_capabilities" => %{"react" => %{"emoji_names" => nil}}
             },
             destination_ref
           )

    instruction_ref = SourceRef.message("T123", "G123", "1787832001.000200")

    options =
      options()
      |> Map.put(:current_instruction, fn _binding, _source, _destination_ref ->
        {:error, :unauthorized}
      end)

    assert CapabilityTools.call(
             "post_slack_message",
             %{
               "destination_ref" => destination_ref,
               "instruction_ref" => instruction_ref,
               "message" => "This remains inert."
             },
             work_binding(),
             options
           ) == {:error, "unauthorized"}

    refute_received {:conversation_info, "C456"}
    refute_received {:post_proposed, _payload}
  end

  test "malformed capability calls and authority configuration fail closed" do
    options = options()

    assert CapabilityTools.call("unknown", %{}, work_binding(), options) ==
             {:error, "unknown_tool"}

    for {tool, arguments} <- [
          {"search_slack", :invalid},
          {"list_slack_channels", :invalid},
          {"read_slack_source", :invalid},
          {"set_slack_reaction", :invalid},
          {"post_slack_message", :invalid}
        ] do
      assert CapabilityTools.call(tool, arguments, work_binding(), options) ==
               {:error, "invalid_arguments"}
    end

    assert_raise ArgumentError, ~r/options are invalid/, fn ->
      CapabilityTools.options!(:invalid)
    end

    assert_raise ArgumentError, ~r/options are invalid/, fn ->
      CapabilityTools.options!(workspace_ref: "T123", workspace_ref: "T456")
    end

    assert_raise ArgumentError, ~r/authority is invalid/, fn ->
      CapabilityTools.options!(%{options | action_tokens: :invalid})
    end

    assert CapabilityTools.options!(Map.to_list(options)).workspace_ref == "T123"
  end

  test "every source capability rejects malformed bounds before using Slack authority" do
    options = options()
    binding = work_binding()

    for arguments <- [
          %{:query => "deploy"},
          %{"unknown" => true},
          %{"query" => ""},
          %{"query" => "deploy", "content_types" => ["messages", "messages"]},
          %{"query" => "deploy", "content_types" => []},
          %{"query" => "deploy", "conversation_refs" => :invalid},
          %{"query" => "deploy", "conversation_refs" => ["slack:T123:not valid"]},
          %{"query" => "deploy", "author_ref" => "slack-user:not valid"},
          %{"query" => "deploy", "after" => "yesterday"},
          %{"query" => "deploy", "before" => 42},
          %{"query" => "deploy", "cursor" => 42},
          %{"query" => "deploy", "include_context" => "yes"},
          %{"query" => "deploy", "limit" => 0}
        ] do
      assert CapabilityTools.call("search_slack", arguments, binding, options) ==
               {:error, "invalid_arguments"}
    end

    for arguments <- [
          %{configured_only: true},
          %{"unknown" => true},
          %{"query" => ""},
          %{"kinds" => []},
          %{"kinds" => ["public_channel", "public_channel"]},
          %{"configured_only" => "yes"},
          %{"include_archived" => "yes"},
          %{"include_resources" => "yes"},
          %{"cursor" => 42},
          %{"limit" => 0}
        ] do
      assert CapabilityTools.call("list_slack_channels", arguments, binding, options) ==
               {:error, "invalid_arguments"}
    end

    channel_ref = SourceRef.channel("T123", "C456")
    message_ref = SourceRef.message("T123", "C456", "1787832001.000200")

    for arguments <- [
          %{:source_ref => channel_ref, "view" => "channel"},
          %{"unknown" => true},
          %{"source_ref" => "", "view" => "channel"},
          %{"source_ref" => channel_ref, "view" => "thread"},
          %{"source_ref" => channel_ref, "view" => "channel", "after" => "yesterday"},
          %{"source_ref" => channel_ref, "view" => "channel", "before" => 42},
          %{"source_ref" => channel_ref, "view" => "channel", "cursor" => 42},
          %{"source_ref" => channel_ref, "view" => "channel", "limit" => 0}
        ] do
      assert CapabilityTools.call("read_slack_source", arguments, binding, options) ==
               {:error, "invalid_arguments"}
    end

    assert CapabilityTools.call(
             "read_slack_source",
             %{"source_ref" => SourceRef.channel("T999", "C456"), "view" => "channel"},
             binding,
             options
           ) == {:error, "unauthorized"}

    for arguments <- [
          %{"action" => "add", "emoji" => "eyes"},
          %{"action" => "add", "emoji" => "eyes", "message_ref" => channel_ref},
          %{"action" => "replace", "emoji" => "eyes", "message_ref" => message_ref},
          %{"action" => "add", "emoji" => 42, "message_ref" => message_ref},
          %{"action" => "add", "emoji" => "not valid", "message_ref" => message_ref}
        ] do
      assert CapabilityTools.call("set_slack_reaction", arguments, binding, options) ==
               {:error, "invalid_arguments"}
    end

    for arguments <- [
          %{"destination_ref" => channel_ref, "message" => "Done"},
          %{
            "destination_ref" => message_ref,
            "instruction_ref" => message_ref,
            "message" => "Done"
          },
          %{
            "destination_ref" => channel_ref,
            "instruction_ref" => channel_ref,
            "message" => "Done"
          },
          %{
            "destination_ref" => channel_ref,
            "instruction_ref" => message_ref,
            "message" => ""
          }
        ] do
      assert CapabilityTools.call("post_slack_message", arguments, binding, options) ==
               {:error, "invalid_arguments"}
    end

    refute_received {:token_checkout, _, _}
    refute_received {:list_conversations, _}
    refute_received {:conversation_info, _}
    refute_received {:enqueue_action, _}
  end

  test "capability bindings and callback crashes fail closed without widening the turn" do
    options = options()

    for binding <- [
          %{},
          %{episode: %Episode{}, turn: %Turn{id: "turn-row-id"}},
          %{
            episode: %Episode{
              destination_conversation_ref: "github:binding:repository:1",
              destination_transport: "github",
              id: "episode-row-id"
            },
            turn: %Turn{id: "turn-row-id"}
          },
          %{
            episode: %Episode{
              destination_conversation_ref: "slack:T999:G123",
              destination_transport: "slack",
              id: "episode-row-id"
            },
            turn: %Turn{id: "turn-row-id"}
          }
        ] do
      assert CapabilityTools.call("list_slack_channels", %{}, binding, options) ==
               {:error, "unauthorized"}
    end

    for tool <-
          ~w(list_slack_channels search_slack read_slack_source set_slack_reaction post_slack_message) do
      crashing =
        options
        |> Map.put(:api, __MODULE__.CrashingAPI)
        |> then(fn configured ->
          case tool do
            "set_slack_reaction" ->
              Map.put(configured, :current_input, fn _binding, _source -> raise "input failed" end)

            "post_slack_message" ->
              Map.put(configured, :current_input, fn _binding, _source ->
                {:ok, %{"content" => %{"text" => "Post to <#G123>."}}}
              end)

            _other ->
              configured
          end
        end)

      arguments =
        case tool do
          "list_slack_channels" ->
            %{}

          "search_slack" ->
            %{"query" => "deploy"}

          "read_slack_source" ->
            %{"source_ref" => SourceRef.channel("T123", "C456"), "view" => "channel"}

          "set_slack_reaction" ->
            %{
              "action" => "add",
              "emoji" => "eyes",
              "message_ref" => SourceRef.message("T123", "G123", "1787832001.000200")
            }

          "post_slack_message" ->
            %{
              "destination_ref" => SourceRef.channel("T123", "G123"),
              "instruction_ref" => SourceRef.message("T123", "G123", "1787832001.000200"),
              "message" => "Done"
            }
        end

      assert CapabilityTools.call(tool, arguments, work_binding(), crashing) ==
               {:error, "temporarily_unavailable"}
    end
  end

  defmodule CrashingAPI do
    def list_conversations(_observer, _document), do: raise("list failed")
    def search_context(_observer, _token, _document), do: raise("search failed")
    def conversation_info(_observer, _channel_ref), do: raise("read failed")
    def list_bookmarks(_observer, _channel_ref), do: raise("bookmarks failed")
    def file_info(_observer, _file_ref), do: raise("file failed")
    def read_messages(_observer, _channel_ref, _thread_ref, _document), do: raise("read failed")
  end

  defmodule MalformedResourceAPI do
    def list_conversations(_observer, _document),
      do: {:ok, %{"conversations" => [%{}], "cursor" => ""}}

    def search_context(_observer, _token, _document),
      do: {:ok, %{"results" => %{"messages" => [%{"channel_id" => "C456"}]}}}

    def conversation_info(_observer, channel_ref) do
      {:ok,
       %{
         "id" => channel_ref,
         "is_archived" => false,
         "is_ext_shared" => false,
         "is_private" => false,
         "name" => "operations"
       }}
    end

    def list_bookmarks(_observer, _channel_ref), do: {:ok, :invalid}
    def file_info(_observer, _file_ref), do: {:ok, :invalid}

    def read_messages(_observer, _channel_ref, _thread_ref, _document),
      do: {:ok, %{"cursor" => "", "messages" => :invalid}}
  end

  test "malformed Slack resource envelopes cannot become model-visible source evidence" do
    options = %{options() | api: MalformedResourceAPI}
    binding = work_binding()

    assert CapabilityTools.call("list_slack_channels", %{}, binding, options) ==
             {:error, "temporarily_unavailable"}

    assert CapabilityTools.call(
             "search_slack",
             %{"query" => "deploy"},
             binding,
             options
           ) == {:error, "temporarily_unavailable"}

    assert CapabilityTools.call(
             "read_slack_source",
             %{
               "source_ref" => SourceRef.bookmark("T123", "C456", "BkRUNBOOK"),
               "view" => "metadata"
             },
             binding,
             options
           ) == {:error, "temporarily_unavailable"}

    assert CapabilityTools.call(
             "read_slack_source",
             %{
               "source_ref" => SourceRef.file("T123", "C456", "F123"),
               "view" => "document"
             },
             binding,
             options
           ) == {:error, "temporarily_unavailable"}

    assert CapabilityTools.call(
             "read_slack_source",
             %{
               "source_ref" => SourceRef.channel("T123", "C456"),
               "view" => "channel"
             },
             binding,
             options
           ) == {:error, "temporarily_unavailable"}
  end

  test "channel listing can omit resource hydration and require trusted configuration" do
    options = options()

    assert {:ok, result} =
             CapabilityTools.call(
               "list_slack_channels",
               %{
                 "configured_only" => true,
                 "cursor" => "page-one",
                 "include_archived" => true,
                 "include_resources" => false,
                 "kinds" => ["public_channel", "private_channel"],
                 "limit" => 25,
                 "query" => "repo:checkout"
               },
               work_binding(),
               options
             )

    assert [%{"name" => "backend-ops"} = channel] = result["conversations"]
    refute Map.has_key?(channel, "resources")
    refute_received {:list_bookmarks, _}

    assert_received {:list_conversations,
                     %{
                       "cursor" => "page-one",
                       "exclude_archived" => false,
                       "limit" => 25
                     }}
  end

  defp options do
    %{
      action_tokens: {FakeActionTokens, self()},
      api: FakeAPI,
      audit: fn attributes ->
        send(self(), {:source_audit, attributes})
        :ok
      end,
      client: self(),
      configuration: fn
        "T123", "C456" -> %{repository_ref: "repo:checkout"}
        _workspace_ref, _channel_ref -> nil
      end,
      current_input: fn _binding, source ->
        {:ok,
         %{
           "destination" => %{
             "conversation_ref" => "slack:#{source.workspace_ref}:#{source.channel_ref}",
             "thread_ref" => source.message_ref,
             "transport" => "slack"
           }
         }}
      end,
      current_instruction: fn _binding, _source, _destination_ref ->
        {:ok, %{actor_ref: "slack:user:U123"}}
      end,
      propose_post: fn _binding, payload ->
        send(self(), {:post_proposed, payload})
        {:ok, %{ref: "record:slack_post_offer:default", status: :open}}
      end,
      enqueue_action: fn _binding, attributes ->
        send(self(), {:enqueue_action, attributes})

        {:ok,
         %{
           action: %PlatformAction{action_ref: "platform-action:reaction", status: :pending},
           status: :created
         }}
      end,
      event_ref: fn _binding -> {:ok, "Ev-current"} end,
      reaction_added: fn _episode_id, _conversation_ref, _message_ref, emoji_name ->
        emoji_name == "eyes"
      end,
      requester_ref: fn _binding -> {:ok, "slack:user:U123"} end,
      workspace_ref: "T123"
    }
  end

  defp work_binding do
    %{
      episode: %Episode{
        active_input_refs: ["input-current"],
        destination_conversation_ref: "slack:T123:G123",
        destination_transport: "slack",
        id: "episode-row-id"
      },
      turn: %Turn{id: "turn-row-id"}
    }
  end

  defp public_work_binding(channel_ref \\ "C456") do
    binding = work_binding()

    %{
      binding
      | episode: %{
          binding.episode
          | destination_conversation_ref: "slack:T123:#{channel_ref}"
        }
    }
  end

  defp valid_arguments do
    %{
      "after" => nil,
      "author_ref" => nil,
      "before" => nil,
      "content_types" => ["messages"],
      "conversation_refs" => [],
      "cursor" => nil,
      "include_context" => true,
      "limit" => 20,
      "query" => "deployment"
    }
  end
end
