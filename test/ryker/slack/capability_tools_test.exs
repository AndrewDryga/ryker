defmodule Ryker.Slack.CapabilityToolsTest do
  use ExUnit.Case, async: true

  alias Ryker.Delivery.PlatformAction
  alias Ryker.Episodes.Episode
  alias Ryker.Slack.{CapabilityTools, ChannelConfiguration, SourceRef}
  alias Ryker.Work.Turn

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

  defmodule ContextSearchAPI do
    defdelegate list_conversations(observer, document), to: FakeAPI
    defdelegate conversation_info(observer, channel_ref), to: FakeAPI
    defdelegate list_bookmarks(observer, channel_ref), to: FakeAPI
    defdelegate file_info(observer, file_ref), to: FakeAPI
    defdelegate read_messages(observer, channel_ref, thread_ref, document), to: FakeAPI

    def search_context(observer, token, document) do
      send(observer, {:search_context, token, document})

      [root, hit, later] =
        Path.join(__DIR__, "fixtures/readiness_thread.json") |> File.read!() |> Jason.decode!()

      root = Map.merge(root, Process.get(:nested_context_override, %{}))

      {:ok,
       %{
         "next_cursor" => "",
         "results" => %{
           "messages" => [
             %{
               "channel_id" => "C456",
               "content" => hit["text"],
               "context_messages" => %{"before" => [root, root, hit], "after" => [later]},
               "message_ts" => hit["ts"],
               "thread_ts" => hit["thread_ts"]
             }
           ]
         }
       }}
    end
  end

  defmodule PagedSourceAPI do
    defdelegate list_conversations(observer, document), to: FakeAPI
    defdelegate conversation_info(observer, channel_ref), to: FakeAPI
    defdelegate list_bookmarks(observer, channel_ref), to: FakeAPI
    defdelegate file_info(observer, file_ref), to: FakeAPI
    defdelegate search_context(observer, token, document), to: FakeAPI

    def read_messages(observer, channel_ref, thread_ref, document) do
      send(observer, {:read_messages, channel_ref, thread_ref, document})

      [root, _hit, later] =
        Path.join(__DIR__, "fixtures/readiness_thread.json") |> File.read!() |> Jason.decode!()

      if document["oldest"] == root["ts"] and document["latest"] == root["ts"] do
        {:ok,
         %{"messages" => if(Process.get(:anchor_deleted), do: [], else: [root]), "cursor" => ""}}
      else
        # A dense history page, or a later thread page, need not repeat the anchor.
        {:ok, %{"messages" => [later], "cursor" => "next-page"}}
      end
    end
  end

  defmodule DenseSourceAPI do
    defdelegate list_conversations(observer, document), to: FakeAPI
    defdelegate conversation_info(observer, channel_ref), to: FakeAPI
    defdelegate list_bookmarks(observer, channel_ref), to: FakeAPI
    defdelegate file_info(observer, file_ref), to: FakeAPI
    defdelegate search_context(observer, token, document), to: FakeAPI

    def read_messages(_observer, _channel, _thread, document) do
      originals =
        for n <- 1..250, do: %{"ts" => "#{1_789_000_000 + n}.000001", "text" => "row #{n}"}

      rows =
        Enum.filter(originals, fn row ->
          above?(row["ts"], document["oldest"], document["inclusive"]) and
            below?(row["ts"], document["latest"], document["inclusive"])
        end)
        |> Enum.reverse()

      offset = if document["cursor"], do: String.to_integer(document["cursor"]), else: 0
      page = Enum.slice(rows, offset, document["limit"])

      cursor =
        if offset + length(page) < length(rows), do: to_string(offset + length(page)), else: ""

      {:ok, %{"messages" => page, "cursor" => cursor}}
    end

    defp above?(_value, nil, _inclusive), do: true
    defp above?(value, bound, true), do: value >= bound
    defp above?(value, bound, _), do: value > bound
    defp below?(_value, nil, _inclusive), do: true
    defp below?(value, bound, true), do: value <= bound
    defp below?(value, bound, _), do: value < bound
  end

  defmodule ThreadSourceAPI do
    defdelegate list_conversations(observer, document), to: FakeAPI
    defdelegate conversation_info(observer, channel_ref), to: FakeAPI
    defdelegate list_bookmarks(observer, channel_ref), to: FakeAPI
    defdelegate file_info(observer, file_ref), to: FakeAPI
    defdelegate search_context(observer, token, document), to: FakeAPI

    def read_messages(observer, channel, thread, document) do
      send(observer, {:read_messages, channel, thread, document})

      [root | _] =
        originals =
        Path.join(__DIR__, "fixtures/readiness_thread.json") |> File.read!() |> Jason.decode!()

      selected =
        Enum.filter(originals, fn message ->
          (is_nil(document["oldest"]) or message["ts"] >= document["oldest"]) and
            (is_nil(document["latest"]) or message["ts"] <= document["latest"])
        end)

      # Harvested replies behavior: the real root is also returned for an exact reply.
      {:ok, %{"messages" => Enum.uniq_by([root | selected], & &1["ts"]), "cursor" => ""}}
    end
  end

  defmodule ContextualThreadAPI do
    defdelegate conversation_info(observer, channel_ref), to: FakeAPI
    defdelegate list_conversations(observer, document), to: FakeAPI
    defdelegate list_bookmarks(observer, channel_ref), to: FakeAPI
    defdelegate file_info(observer, file_ref), to: FakeAPI
    defdelegate search_context(observer, token, document), to: FakeAPI

    def read_messages(observer, channel, thread, document) do
      send(observer, {:read_messages, channel, thread, document})

      originals =
        Path.join(__DIR__, "fixtures/readiness_thread.json") |> File.read!() |> Jason.decode!()

      [root | _] = originals
      # These additional rows describe only channel/thread structure. The
      # conversational originals above retain the captured production wording.
      rows =
        if thread,
          do: originals,
          else: [
            %{"ts" => "1789058306.000001", "text" => "preceding channel original"},
            root,
            %{
              "ts" => "1789058308.000001",
              "text" => "another thread reply",
              "thread_ts" => "1789000000.000001"
            },
            %{"ts" => "1789058309.000001", "text" => "following channel original"}
          ]

      inclusive = document["inclusive"] == true

      selected =
        Enum.filter(rows, fn row ->
          (is_nil(document["oldest"]) or row["ts"] > document["oldest"] or
             (inclusive and row["ts"] == document["oldest"])) and
            (is_nil(document["latest"]) or row["ts"] < document["latest"] or
               (inclusive and row["ts"] == document["latest"]))
        end)

      # This valid exact-reply response omits the root. The reader must obtain
      # it explicitly, not assume every provider response repeats the parent.
      {:ok, %{"messages" => selected, "cursor" => ""}}
    end
  end

  defmodule DenseChannelThreadAPI do
    defdelegate conversation_info(observer, channel_ref), to: FakeAPI
    defdelegate list_conversations(observer, document), to: FakeAPI
    defdelegate list_bookmarks(observer, channel_ref), to: FakeAPI
    defdelegate file_info(observer, file_ref), to: FakeAPI
    defdelegate search_context(observer, token, document), to: FakeAPI

    @root_ts "1789058307.523479"

    def read_messages(observer, _channel, thread, document) when is_binary(thread) do
      send(observer, {:read_thread, document})
      [root, reply | _] = originals()
      {:ok, %{"messages" => [root, reply], "cursor" => ""}}
    end

    def read_messages(observer, _channel, nil, document) do
      send(observer, {:read_channel, document})
      rows = channel_rows() |> Enum.filter(&selected?(&1, document)) |> Enum.reverse()
      offset = if document["cursor"], do: String.to_integer(document["cursor"]), else: 0
      page = Enum.slice(rows, offset, document["limit"])

      cursor =
        if offset + length(page) < length(rows), do: to_string(offset + length(page)), else: ""

      {:ok, %{"messages" => page, "cursor" => cursor}}
    end

    defp selected?(row, document) do
      inclusive = document["inclusive"] == true

      above?(row["ts"], document["oldest"], inclusive) and
        below?(row["ts"], document["latest"], inclusive)
    end

    defp above?(_value, nil, _inclusive), do: true
    defp above?(value, bound, true), do: value >= bound
    defp above?(value, bound, _inclusive), do: value > bound
    defp below?(_value, nil, _inclusive), do: true
    defp below?(value, bound, true), do: value <= bound
    defp below?(value, bound, _inclusive), do: value < bound

    # A dense channel whose newest page is nowhere near the thread root.
    def channel_rows do
      [root | _] = originals()

      generated =
        for n <- 1..250,
            do: %{"ts" => "#{1_789_058_200 + n}.000001", "text" => "channel row #{n}"}

      Enum.sort_by([root | generated], & &1["ts"])
    end

    def root_ts, do: @root_ts

    defp originals,
      do: Path.join(__DIR__, "fixtures/readiness_thread.json") |> File.read!() |> Jason.decode!()
  end

  test "a dense channel still returns the originals around a thread root, not its newest page" do
    # The thread reader asks for a small window around the root. In a busy
    # channel that window is hundreds of messages behind the newest page, and a
    # reader that answers with the newest page describes a different
    # conversation while looking complete.
    source = SourceRef.thread("T123", "C456", DenseChannelThreadAPI.root_ts())
    anchor = SourceRef.message("T123", "C456", "1789058455.189229")
    arguments = %{"source_ref" => source, "anchor_ref" => anchor, "view" => "thread"}

    assert {:ok, result} =
             CapabilityTools.call("read_slack_source", arguments, work_binding(), %{
               options()
               | api: DenseChannelThreadAPI
             })

    assert result["thread_root"]["ts"] == DenseChannelThreadAPI.root_ts()
    context = result["channel_context"]
    stamps = Enum.map(context["messages"], & &1["ts"])

    assert stamps != [], "a dense channel must still yield the root's neighbours"
    refute DenseChannelThreadAPI.root_ts() in stamps

    newest = DenseChannelThreadAPI.channel_rows() |> List.last() |> Map.fetch!("ts")
    refute newest in stamps

    assert Enum.all?(stamps, fn stamp ->
             abs(String.to_integer(hd(String.split(stamp, "."))) - 1_789_058_307) <= 4
           end),
           "channel context must centre on the root: #{inspect(stamps)}"

    assert context["coverage"]["before"]["status"] in ~w(complete partial previous_page)
    assert context["coverage"]["after"]["status"] in ~w(complete partial previous_page)
    assert context["coverage"]["provider_pages"] <= context["coverage"]["page_limit"]
  end

  test "thread expansion fetches a missing root and separates surrounding channel originals" do
    source = SourceRef.thread("T123", "C456", "1789058307.523479")
    anchor = SourceRef.message("T123", "C456", "1789058455.189229")
    arguments = %{"source_ref" => source, "anchor_ref" => anchor, "view" => "thread"}

    assert {:ok, result} =
             CapabilityTools.call("read_slack_source", arguments, work_binding(), %{
               options()
               | api: ContextualThreadAPI
             })

    assert result["thread_root"]["ts"] == "1789058307.523479"
    assert result["anchor"]["source_ref"] == anchor

    assert Enum.map(result["channel_context"]["messages"], & &1["ts"]) == [
             "1789058306.000001",
             "1789058309.000001"
           ]

    refute Jason.encode!(result["channel_context"]) =~ "another thread reply"

    assert result["channel_context"]["source_read"]["arguments"]["source_ref"] ==
             SourceRef.message("T123", "C456", "1789058307.523479")

    assert {:ok, expanded} =
             CapabilityTools.call(
               "read_slack_source",
               result["channel_context"]["source_read"]["arguments"],
               work_binding(),
               %{options() | api: ContextualThreadAPI}
             )

    refute Jason.encode!(expanded) =~ "another thread reply"
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

  test "file context retains known shares without inventing a unique originating thread" do
    {:ok, file} = FakeAPI.file_info(self(), "F123")

    file =
      Map.merge(file, %{
        "created" => 1_787_832_000,
        "updated" => 1_787_833_000,
        "shares" => %{
          "public" => %{
            "C456" => [
              %{
                "ts" => "1787832001.000200",
                "thread_ts" => "1787832000.000100",
                "team_id" => "T123"
              },
              %{
                "ts" => "1787833001.000200",
                "thread_ts" => "1787833000.000100",
                "team_id" => "T123"
              }
            ]
          },
          "private" => %{
            "G999" => [%{"ts" => "1787834001.000200", "thread_ts" => "1787834000.000100"}]
          }
        }
      })

    Process.put(:adversarial_file_response, {:ok, file})

    assert {:ok, result} =
             CapabilityTools.call(
               "read_slack_source",
               %{"source_ref" => SourceRef.file("T123", "C456", "F123"), "view" => "document"},
               work_binding(),
               %{options() | api: AdversarialSearchAPI}
             )

    assert result["document"]["created"] == 1_787_832_000
    assert result["document"]["updated"] == 1_787_833_000
    context = result["document"]["source_context"]
    assert context["origin"] == "not_established"
    assert [first, second] = context["shares"]
    assert first["source_ref"] == SourceRef.message("T123", "C456", "1787832001.000200")
    assert first["thread_source_ref"] == SourceRef.thread("T123", "C456", "1787832000.000100")
    assert second["source_ref"] == SourceRef.message("T123", "C456", "1787833001.000200")
    refute Ryker.CanonicalJSON.encode!(context) =~ "G999"
    refute Map.has_key?(context, "thread_source_ref")

    Process.put(:adversarial_search_response, %{
      "results" => %{"files" => [%{"file_id" => "F123"}]}
    })

    assert {:ok, searched} =
             CapabilityTools.call("search_slack", valid_arguments(), public_work_binding(), %{
               options()
               | api: AdversarialSearchAPI
             })

    assert [hit] = searched["results"]["files"]
    assert hit["source_context"] == context
    assert hit["created"] == file["created"]
    assert hit["source_read"]["arguments"]["view"] == "document"
  end

  test "a provider preview is not reported as the complete file content" do
    {:ok, file} = FakeAPI.file_info(self(), "F123")
    preview = file |> Map.delete("plain_text") |> Map.put("preview", "# Checkout")
    Process.put(:adversarial_file_response, {:ok, preview})

    assert {:ok, result} =
             CapabilityTools.call(
               "read_slack_source",
               %{"source_ref" => SourceRef.file("T123", "C456", "F123"), "view" => "document"},
               work_binding(),
               %{options() | api: AdversarialSearchAPI}
             )

    assert result["document"]["content"] == "# Checkout"
    refute result["document"]["content_complete"]
    refute result["complete"]
  end

  test "an exact file read cannot substitute another file shared in the same channel" do
    {:ok, file} = FakeAPI.file_info(self(), "FOTHER")
    Process.put(:adversarial_file_response, {:ok, file})

    assert CapabilityTools.call(
             "read_slack_source",
             %{"source_ref" => SourceRef.file("T123", "C456", "F123"), "view" => "document"},
             work_binding(),
             %{options() | api: AdversarialSearchAPI}
           ) == {:error, "unauthorized"}
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
                       "latest" => "1787832001.000200",
                       "oldest" => "1787745601.000000"
                     }}

    assert_received {:read_messages, "C456", nil,
                     %{"oldest" => "1787832001.000200", "latest" => "1787918401.999999"}}

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
      # The original-read expansion now checks the requested range, so this
      # query must include the fixture's 27 Aug source rather than start a day later.
      "after" => "2026-08-27T11:00:00Z",
      "author_ref" => "slack-user:U123",
      "before" => nil,
      "content_types" => ["messages"],
      "conversation_refs" => ["slack:T123:C456"],
      "cursor" => nil,
      "limit" => 20,
      "query" => "What happened to the deploy?"
    }

    assert {:ok, result} =
             CapabilityTools.call("search_slack", arguments, work_binding(), options)

    assert_received {:token_checkout, "Ev-current", "turn-row-id"}

    assert_received {:search_context, "xact-user-turn-secret", document}
    assert document["action_token"] == nil
    assert document["after"] == 1_787_828_400
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

  test "surrounding context cannot be disabled or supplied as a retired search option" do
    search = Enum.find(CapabilityTools.definitions(), &(&1["name"] == "search_slack"))
    refute Map.has_key?(search["inputSchema"]["properties"], "include_context")

    for value <- [true, false] do
      assert CapabilityTools.call(
               "search_slack",
               %{"query" => "deployment", "include_context" => value},
               work_binding(),
               options()
             ) == {:error, "invalid_arguments"}
    end

    refute_received {:search_context, _, _}
  end

  test "search neighbors have exact source identities and exclude the duplicated anchor" do
    # A real QA thread has an older task card and a later completion message.
    # Returning either without the other hid the difference between task and review state.
    assert {:ok, result} =
             CapabilityTools.call("search_slack", %{"query" => "task"}, work_binding(), %{
               options()
               | api: ContextSearchAPI
             })

    [hit] = result["results"]["messages"]

    assert [%{"ts" => "1789058307.523479", "source_ref" => root_ref}] =
             hit["context_messages"]["before"]

    assert [%{"ts" => "1789058572.713319", "source_ref" => later_ref}] =
             hit["context_messages"]["after"]

    assert root_ref == SourceRef.message("T123", "C456", "1789058307.523479")
    assert later_ref == SourceRef.message("T123", "C456", "1789058572.713319")
    assert hit["thread_source_ref"] == SourceRef.thread("T123", "C456", "1789058307.523479")
    assert hit["context_coverage"]["status"] == "partial"
    assert hit["context_coverage"]["basis"] == "provider_selected"
  end

  test "a visible search hit cannot smuggle neighbors from another audience or thread" do
    for identity <- [
          %{"channel_id" => "G999"},
          %{"team_id" => "TOTHER"},
          %{"thread_ts" => "1789000000.000001"}
        ] do
      Process.put(:nested_context_override, identity)

      assert CapabilityTools.call("search_slack", %{"query" => "task"}, work_binding(), %{
               options()
               | api: ContextSearchAPI
             }) == {:error, "temporarily_unavailable"}
    end
  end

  defmodule MissingContextSearchAPI do
    defdelegate conversation_info(observer, channel), to: FakeAPI
    defdelegate list_conversations(observer, document), to: FakeAPI
    defdelegate list_bookmarks(observer, channel), to: FakeAPI
    defdelegate file_info(observer, file), to: FakeAPI
    defdelegate read_messages(observer, channel, thread, document), to: ThreadSourceAPI

    def search_context(_observer, _token, _document) do
      originals =
        Path.join(__DIR__, "fixtures/readiness_thread.json") |> File.read!() |> Jason.decode!()

      selected = if Process.get(:all_missing_hits), do: originals, else: [Enum.at(originals, 1)]

      messages =
        Enum.map(
          selected,
          &%{
            "channel_id" => "C456",
            "content" => &1["text"],
            "message_ts" => &1["ts"],
            "thread_ts" => &1["thread_ts"]
          }
        )

      {:ok, %{"next_cursor" => "", "results" => %{"messages" => messages}}}
    end
  end

  defmodule ThrottledExpansionAPI do
    defdelegate conversation_info(observer, channel), to: FakeAPI
    defdelegate list_conversations(observer, document), to: FakeAPI
    defdelegate list_bookmarks(observer, channel), to: FakeAPI
    defdelegate file_info(observer, file), to: FakeAPI
    defdelegate search_context(observer, token, document), to: MissingContextSearchAPI

    def read_messages(observer, _channel, _thread, _document) do
      send(observer, {:throttled_read, :conversations_history})
      {:error, {:delivery_rate_limited, 30, {:slack_http_error, 429, "upstream rate limit"}}}
    end
  end

  test "a throttled neighbour read fails the lookup instead of inventing the context" do
    # Slack rate limits the neighbour read a hit needs to be interpreted.
    # Returning the hit anyway with empty neighbours would describe a
    # conversation the reader never saw, and the emptiness would look verified.
    assert CapabilityTools.call(
             "search_slack",
             %{"query" => "Engineering task"},
             work_binding(),
             %{options() | api: ThrottledExpansionAPI}
           ) == {:error, "temporarily_unavailable"}

    assert_received {:throttled_read, :conversations_history}

    assert CapabilityTools.call(
             "read_slack_source",
             %{
               "source_ref" => SourceRef.message("T123", "C456", "1789058455.189229"),
               "view" => "surrounding"
             },
             work_binding(),
             %{options() | api: ThrottledExpansionAPI}
           ) == {:error, "temporarily_unavailable"}
  end

  test "missing provider context triggers a bounded original read with nonmatching neighbors" do
    assert {:ok, result} =
             CapabilityTools.call(
               "search_slack",
               %{"query" => "Engineering task"},
               work_binding(),
               %{options() | api: MissingContextSearchAPI}
             )

    [hit] = result["results"]["messages"]
    assert hit["thread_root"]["ts"] == "1789058307.523479"
    assert [%{"ts" => "1789058572.713319"}] = hit["context_messages"]["after"]
    assert hit["context_coverage"]["basis"] == "original_reader"
    assert hit["source_read"]["tool"] == "read_slack_source"
  end

  test "automatic search expansion preserves all hits without exceeding its fallback allowance" do
    Process.put(:all_missing_hits, true)

    assert {:ok, result} =
             CapabilityTools.call("search_slack", %{"query" => "QA"}, work_binding(), %{
               options()
               | api: MissingContextSearchAPI
             })

    hits = result["results"]["messages"]
    assert length(hits) == 3
    assert Enum.count(hits, &(&1["context_coverage"]["basis"] == "original_reader")) == 2
    assert result["context_limits"]["fallback_reads"] == 2
    assert result["context_limits"]["message_page_limit"] == 12
    assert List.last(hits)["context_coverage"]["reason"] == "expansion_budget"
    assert List.last(hits)["source_read"]["tool"] == "read_slack_source"
  end

  test "provider context absence is only complete after an original read verifies the empty neighborhood" do
    assert {:ok, result} =
             CapabilityTools.call(
               "search_slack",
               %{"query" => "deploy"},
               work_binding(),
               options()
             )

    [hit] = result["results"]["messages"]
    assert hit["context_messages"] == %{"before" => [], "after" => []}
    assert hit["context_coverage"]["status"] == "complete"
    assert hit["context_coverage"]["basis"] == "original_reader"
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
                       "inclusive" => false,
                       "latest" => nil,
                       "limit" => 50,
                       "oldest" => "1787832000.000100"
                     }}

    assert result["complete"] == true
    assert result["source_ref"] == source_ref
    assert result["messages"] == []
    assert [%{"ts" => "1787832001.000200"}] = result["channel_context"]["messages"]
    assert %{"source_ref" => hydrated_ref} = result["anchor"]

    assert {:ok, %{kind: :message, channel_ref: "G123"}} =
             SourceRef.parse(hydrated_ref, "T123")

    assert_received {:source_audit,
                     %{
                       capability: "conversations.replies",
                       channel_ref: "G123",
                       result_count: 2,
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

  test "dense surrounding reads return neighbors instead of the newest distant page" do
    source = SourceRef.message("T123", "C456", "1789000101.000001")
    arguments = %{"source_ref" => source, "view" => "surrounding", "limit" => 10}

    assert {:ok, result} =
             CapabilityTools.call("read_slack_source", arguments, work_binding(), %{
               options()
               | api: DenseSourceAPI
             })

    assert Enum.map(result["messages"], & &1["ts"]) ==
             Enum.map(
               Enum.to_list(96..100) ++ Enum.to_list(102..106),
               &"#{1_789_000_000 + &1}.000001"
             )
  end

  test "a paginated source keeps its independently verified anchor even when the page omits it" do
    source = SourceRef.message("T123", "C456", "1789058307.523479")
    options = %{options() | api: PagedSourceAPI}
    arguments = %{"source_ref" => source, "view" => "surrounding", "limit" => 20}

    assert {:ok, first} =
             CapabilityTools.call("read_slack_source", arguments, work_binding(), options)

    assert first["anchor"]["source_ref"] == source
    # This provider page does not finish the scan toward the anchor. Its
    # distant originals must not be emitted again as later windows expand.
    assert first["messages"] == []
    refute first["complete"]

    assert {:ok, next} =
             CapabilityTools.call(
               "read_slack_source",
               Map.put(arguments, "cursor", first["cursor"]),
               work_binding(),
               options
             )

    assert next["anchor"]["source_ref"] == source
    Process.put(:anchor_deleted, true)

    assert CapabilityTools.call(
             "read_slack_source",
             Map.put(arguments, "cursor", next["cursor"]),
             work_binding(),
             options
           ) == {:error, "not_found"}
  end

  test "source continuation cannot change the original source range or caller" do
    source = SourceRef.message("T123", "C456", "1789058307.523479")
    options = %{options() | api: PagedSourceAPI}
    arguments = %{"source_ref" => source, "view" => "surrounding", "limit" => 20}
    binding = work_binding()
    assert {:ok, first} = CapabilityTools.call("read_slack_source", arguments, binding, options)
    refute first["cursor"] == "next-page"

    for {changed, caller} <- [
          {Map.put(arguments, "limit", 21), binding},
          {arguments, %{binding | turn: %{binding.turn | id: "other-turn"}}},
          {arguments, binding}
        ] do
      cursor =
        if changed == arguments and caller == binding,
          do: first["cursor"] <> "altered",
          else: first["cursor"]

      assert CapabilityTools.call(
               "read_slack_source",
               Map.put(changed, "cursor", cursor),
               caller,
               options
             ) == {:error, "invalid_source_cursor"}
    end
  end

  test "a source continuation expires with its own signature rather than living forever" do
    # Cursors are signed with a one-hour maximum age, and only tampering and
    # scope changes were ever tested. An age check that stopped working would
    # let a cursor minted in one turn keep reading a conversation indefinitely,
    # and nothing would have noticed.
    source = SourceRef.message("T123", "C456", "1789058307.523479")
    options = %{options() | api: PagedSourceAPI}
    arguments = %{"source_ref" => source, "view" => "surrounding", "limit" => 20}
    binding = work_binding()

    assert {:ok, first} = CapabilityTools.call("read_slack_source", arguments, binding, options)
    assert is_binary(first["cursor"]) and first["cursor"] != ""

    assert {:ok, sealed} =
             Plug.Crypto.verify(
               binding.cursor_secret,
               "slack-source-read",
               first["cursor"],
               max_age: :infinity
             )

    fresh =
      Plug.Crypto.sign(binding.cursor_secret, "slack-source-read", sealed,
        signed_at: System.system_time(:second) - 60
      )

    assert {:ok, _} =
             CapabilityTools.call(
               "read_slack_source",
               Map.put(arguments, "cursor", fresh),
               binding,
               options
             )

    stale =
      Plug.Crypto.sign(binding.cursor_secret, "slack-source-read", sealed,
        signed_at: System.system_time(:second) - 3_601
      )

    assert CapabilityTools.call(
             "read_slack_source",
             Map.put(arguments, "cursor", stale),
             binding,
             options
           ) == {:error, "invalid_source_cursor"}
  end

  test "a thread source can preserve an exact reply anchor without confusing it with the root" do
    source = SourceRef.thread("T123", "C456", "1789058307.523479")
    anchor = SourceRef.message("T123", "C456", "1789058455.189229")
    arguments = %{"source_ref" => source, "anchor_ref" => anchor, "view" => "thread"}
    options = %{options() | api: ThreadSourceAPI}

    assert {:ok, result} =
             CapabilityTools.call("read_slack_source", arguments, work_binding(), options)

    assert result["anchor"]["source_ref"] == anchor
    assert result["thread_root"]["ts"] == "1789058307.523479"

    for crossed <- [
          SourceRef.message("T123", "G999", "1789058455.189229"),
          SourceRef.message("TOTHER", "C456", "1789058455.189229")
        ] do
      assert CapabilityTools.call(
               "read_slack_source",
               %{arguments | "anchor_ref" => crossed},
               work_binding(),
               options
             ) == {:error, "unauthorized"}
    end
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

  # A configured channel selects an environment. The listing read the
  # channel's repository after that field became the environment, so every
  # channel listed with no configured value and a filter by it matched none.
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
                 "query" => "checkout-production"
               },
               work_binding(),
               options
             )

    assert [%{"name" => "backend-ops"} = channel] = result["conversations"]
    assert channel["configured_environment_ref"] == "checkout-production"
    refute Map.has_key?(channel, "configured_repository_ref")
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
        "T123", "C456" -> %ChannelConfiguration{environment_ref: "checkout-production"}
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
      cursor_secret: String.duplicate("a", 64),
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
      "limit" => 20,
      "query" => "deployment"
    }
  end
end
