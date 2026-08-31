defmodule Responder.Slack.ClientTest do
  use ExUnit.Case, async: true

  alias Responder.Slack.Client

  defmodule FakeRequester do
    def start(responses), do: Agent.start_link(fn -> %{requests: [], responses: responses} end)

    def request(agent, method, path, document, headers) do
      Agent.get_and_update(agent, fn state ->
        [response | remaining] = state.responses
        request = {method, path, document, headers}
        {response, %{state | requests: state.requests ++ [request], responses: remaining}}
      end)
    end

    def requests(agent), do: Agent.get(agent, & &1.requests)
  end

  defmodule FakeUploader do
    def start, do: Agent.start_link(fn -> [] end)

    def upload(agent, url, data, media_type) do
      Agent.update(agent, &[{url, data, media_type} | &1])
      :ok
    end

    def uploads(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()
  end

  defmodule FailingUploader do
    def upload(_agent, _url, _data, _media_type), do: {:error, :upload_failed}
  end

  test "finds a delivery marker through exact Slack thread pagination" do
    {:ok, requester} =
      FakeRequester.start([
        slack(%{
          "messages" => [%{"ts" => "1.000001"}],
          "response_metadata" => %{"next_cursor" => "next page"}
        }),
        slack(%{
          "messages" => [
            %{
              "metadata" => %{
                "event_payload" => %{"id" => "delivery:slack:1"},
                "event_type" => "responder_delivery"
              },
              "ts" => "1.000002"
            }
          ],
          "response_metadata" => %{"next_cursor" => ""}
        })
      ])

    client = client(requester)

    assert Client.find_message(client, "C123", "1787832000.000100", "delivery:slack:1") ==
             {:ok, "1.000002"}

    assert [
             {:get,
              "/conversations.replies?channel=C123&ts=1787832000.000100&limit=100&include_all_metadata=true",
              nil, []},
             {:get,
              "/conversations.replies?channel=C123&ts=1787832000.000100&limit=100&include_all_metadata=true&cursor=next+page",
              nil, []}
           ] = FakeRequester.requests(requester)
  end

  test "posts Slack messages with opaque metadata and the exact optional thread" do
    {:ok, requester} = FakeRequester.start([slack(%{"ts" => "1787832001.000200"})])
    client = client(requester)

    assert Client.post_message(
             client,
             "C123",
             "1787832000.000100",
             "Done. <!channel> <@U123> https://example.test",
             "delivery:slack:1"
           ) == {:ok, "1787832001.000200"}

    assert [
             {:post, "/chat.postMessage",
              %{
                "channel" => "C123",
                "metadata" => %{
                  "event_payload" => %{"id" => "delivery:slack:1"},
                  "event_type" => "responder_delivery"
                },
                "mrkdwn" => false,
                "text" => "Done. &lt;!channel&gt; &lt;@U123&gt; https://example.test",
                "thread_ts" => "1787832000.000100",
                "unfurl_links" => false,
                "unfurl_media" => false
              }, []}
           ] = FakeRequester.requests(requester)
  end

  test "updates one exact Slack card while preserving its durable delivery marker" do
    {:ok, requester} =
      FakeRequester.start([slack(%{"channel" => "C123", "ts" => "1787832001.000200"})])

    client = client(requester)

    assert Client.update_message(
             client,
             "C123",
             "1787832001.000200",
             %{"message" => "Investigation is waiting for an operator."},
             "incident-room:room-1:root"
           ) == :ok

    assert [
             {:post, "/chat.update",
              %{
                "blocks" => [
                  %{
                    "text" => "Investigation is waiting for an operator.",
                    "type" => "markdown"
                  }
                ],
                "channel" => "C123",
                "metadata" => %{
                  "event_payload" => %{"id" => "incident-room:room-1:root"},
                  "event_type" => "responder_delivery"
                },
                "mrkdwn" => false,
                "text" => "Investigation is waiting for an operator.",
                "ts" => "1787832001.000200",
                "unfurl_links" => false,
                "unfurl_media" => false
              }, []}
           ] = FakeRequester.requests(requester)
  end

  test "publishes one exact bounded App Home view" do
    {:ok, requester} =
      FakeRequester.start([
        slack(%{"user_id" => "U123", "view" => %{"type" => "home"}})
      ])

    client = client(requester)

    view = %{
      "blocks" => [
        %{
          "text" => %{"text" => "Responder", "type" => "plain_text"},
          "type" => "header"
        }
      ],
      "type" => "home"
    }

    assert Client.publish_home(client, "U123", view) == :ok

    assert FakeRequester.requests(requester) == [
             {:post, "/views.publish", %{"user_id" => "U123", "view" => view}, []}
           ]
  end

  test "rejects malformed or oversized App Home views before transport" do
    {:ok, requester} = FakeRequester.start([])
    client = client(requester)

    assert Client.publish_home(client, "U123", %{"type" => "modal", "blocks" => []}) ==
             {:error, {:invalid_slack_api_request, :home_view}}

    assert Client.publish_home(client, "U123", %{
             "type" => "home",
             "blocks" => List.duplicate(%{"type" => "divider"}, 101)
           }) == {:error, {:invalid_slack_api_request, :home_view}}

    assert FakeRequester.requests(requester) == []
  end

  test "Slack reactions are idempotent when the actor already reacted" do
    {:ok, requester} =
      FakeRequester.start([
        slack(%{}),
        {:ok, %{body: %{"error" => "already_reacted", "ok" => false}, headers: [], status: 200}},
        {:ok, %{body: %{"error" => "invalid_name", "ok" => false}, headers: [], status: 200}}
      ])

    client = client(requester)

    assert :ok = Client.add_reaction(client, "C123", "1787832001.000200", "rocket")
    assert :ok = Client.add_reaction(client, "C123", "1787832001.000200", "rocket")

    assert Client.add_reaction(client, "C123", "1787832001.000200", "not-real") ==
             {:error, {:slack_api_error, "invalid_name"}}
  end

  test "Slack reaction removal is idempotent only when the reaction is already absent" do
    {:ok, requester} =
      FakeRequester.start([
        slack(%{}),
        {:ok, %{body: %{"error" => "no_reaction", "ok" => false}, headers: [], status: 200}},
        {:ok, %{body: %{"error" => "channel_not_found", "ok" => false}, headers: [], status: 200}}
      ])

    client = client(requester)

    assert :ok = Client.remove_reaction(client, "C123", "1787832001.000200", "rocket")
    assert :ok = Client.remove_reaction(client, "C123", "1787832001.000200", "rocket")

    assert Client.remove_reaction(client, "C123", "1787832001.000200", "rocket") ==
             {:error, {:slack_api_error, "channel_not_found"}}

    assert Enum.map(FakeRequester.requests(requester), fn request -> elem(request, 1) end) ==
             List.duplicate("/reactions.remove", 3)
  end

  test "real-time search sends the user event action token without retaining it" do
    response = %{
      "next_cursor" => "next-search-page",
      "results" => %{
        "messages" => [
          %{
            "channel_id" => "C123",
            "content" => "The deployment completed.",
            "message_ts" => "1787832001.000200",
            "permalink" => "https://example.slack.com/archives/C123/p1787832001000200"
          }
        ]
      }
    }

    {:ok, requester} = FakeRequester.start([slack(response)])
    client = client(requester)

    document = %{
      "content_types" => ["messages"],
      "include_context_messages" => true,
      "limit" => 20,
      "query" => "What happened to the deployment?"
    }

    assert Client.search_context(client, "xact-user-turn-secret", document) ==
             {:ok, response}

    assert FakeRequester.requests(requester) == [
             {:post, "/assistant.search.context",
              Map.put(document, "action_token", "xact-user-turn-secret"), []}
           ]
  end

  test "real-time search rejects malformed credentials and request fields before transport" do
    {:ok, requester} = FakeRequester.start([])
    client = client(requester)

    assert Client.search_context(client, "", %{"query" => "deployment"}) ==
             {:error, {:invalid_slack_api_request, :action_token}}

    assert Client.search_context(client, "xact-secret", %{"unknown" => true}) ==
             {:error, {:invalid_slack_api_request, :search}}

    assert FakeRequester.requests(requester) == []
  end

  test "a lost conversation-create response reconciles only the exact recent bot-created room" do
    requested_at = ~U[2026-08-28 12:00:00.000000Z]

    {:ok, requester} =
      FakeRequester.start([
        slack(%{"channels" => [], "response_metadata" => %{"next_cursor" => ""}}),
        {:error, :timeout},
        slack(%{
          "channels" => [
            %{
              "created" => DateTime.to_unix(requested_at),
              "creator" => "U999BOT",
              "id" => "CINCIDENT",
              "is_private" => true,
              "name" => "ems-0828-checkout-1234abcd"
            }
          ],
          "response_metadata" => %{"next_cursor" => ""}
        })
      ])

    client = client(requester)

    assert Client.ensure_conversation(
             client,
             "T123",
             "ems-0828-checkout-1234abcd",
             true,
             "U999BOT",
             requested_at
           ) == {:ok, "CINCIDENT"}

    assert [first_list, create, second_list] = FakeRequester.requests(requester)
    assert {:get, "/conversations.list?" <> _, nil, []} = first_list

    assert create ==
             {:post, "/conversations.create",
              %{
                "is_private" => true,
                "name" => "ems-0828-checkout-1234abcd",
                "team_id" => "T123"
              }, []}

    assert {:get, "/conversations.list?" <> _, nil, []} = second_list
  end

  test "incident-room audience, topic, and pin preparation are exact and idempotent" do
    {:ok, requester} =
      FakeRequester.start([
        slack(%{}),
        {:ok,
         %{body: %{"error" => "already_in_channel", "ok" => false}, headers: [], status: 200}},
        slack(%{}),
        {:ok, %{body: %{"error" => "already_pinned", "ok" => false}, headers: [], status: 200}}
      ])

    client = client(requester)

    assert :ok = Client.invite_users(client, "CINCIDENT", ["U123", "U456"])
    assert :ok = Client.set_topic(client, "CINCIDENT", "Incident 1234 | checkout | managed")
    assert :ok = Client.pin_message(client, "CINCIDENT", "1787832001.000200")

    assert FakeRequester.requests(requester) == [
             {:post, "/conversations.invite", %{"channel" => "CINCIDENT", "users" => "U123"}, []},
             {:post, "/conversations.invite", %{"channel" => "CINCIDENT", "users" => "U456"}, []},
             {:post, "/conversations.setTopic",
              %{"channel" => "CINCIDENT", "topic" => "Incident 1234 | checkout | managed"}, []},
             {:post, "/pins.add", %{"channel" => "CINCIDENT", "timestamp" => "1787832001.000200"},
              []}
           ]
  end

  test "incident-room health distinguishes active archived and unavailable channels" do
    {:ok, requester} =
      FakeRequester.start([
        slack(%{"channel" => %{"id" => "CINCIDENT", "is_archived" => false}}),
        slack(%{"channel" => %{"id" => "CINCIDENT", "is_archived" => true}}),
        {:ok, %{body: %{"error" => "channel_not_found", "ok" => false}, headers: [], status: 200}}
      ])

    client = client(requester)

    assert Client.conversation_state(client, "CINCIDENT") == {:ok, :active}
    assert Client.conversation_state(client, "CINCIDENT") == {:ok, :archived}
    assert Client.conversation_state(client, "CINCIDENT") == :not_found

    assert Enum.map(FakeRequester.requests(requester), &elem(&1, 1)) == [
             "/conversations.info?channel=CINCIDENT&include_num_members=false",
             "/conversations.info?channel=CINCIDENT&include_num_members=false",
             "/conversations.info?channel=CINCIDENT&include_num_members=false"
           ]
  end

  test "lists joined channels when users.conversations omits the redundant membership flag" do
    page =
      slack(%{
        "channels" => [
          %{
            "id" => "C123",
            "is_archived" => false,
            "is_private" => false,
            "name" => "backend-ops",
            "properties" => %{"canvas" => %{"file_id" => "FCHANNEL"}},
            "purpose" => %{"value" => "Service operations"},
            "topic" => %{"value" => "Checkout and API health"}
          },
          %{
            "id" => "G456",
            "is_archived" => false,
            "is_private" => true,
            "name" => "private-incident",
            "purpose" => %{"value" => ""},
            "topic" => %{"value" => "Incident coordination"}
          }
        ],
        "response_metadata" => %{"next_cursor" => "next-page"}
      })

    {:ok, requester} = FakeRequester.start([page])
    client = client(requester)

    assert Client.list_conversations(client, %{
             "exclude_archived" => true,
             "limit" => 50,
             "types" => ["public_channel", "private_channel"]
           }) ==
             {:ok,
              %{
                "conversations" => [
                  %{
                    "canvas_ref" => "FCHANNEL",
                    "channel_ref" => "C123",
                    "is_archived" => false,
                    "is_external_shared" => false,
                    "is_private" => false,
                    "name" => "backend-ops",
                    "purpose" => "Service operations",
                    "topic" => "Checkout and API health"
                  },
                  %{
                    "channel_ref" => "G456",
                    "is_archived" => false,
                    "is_external_shared" => false,
                    "is_private" => true,
                    "name" => "private-incident",
                    "purpose" => "",
                    "topic" => "Incident coordination"
                  }
                ],
                "cursor" => "next-page"
              }}

    assert [{:get, first_path, nil, []}] = FakeRequester.requests(requester)

    assert first_path =~ "/users.conversations?"
    assert first_path =~ "limit=50"

    {:ok, terminal_response} = page

    terminal_page =
      {:ok, put_in(terminal_response, [:body, "response_metadata", "next_cursor"], "")}

    {:ok, joined_requester} = FakeRequester.start([terminal_page])

    assert joined_requester |> client() |> Client.joined_conversations() ==
             {:ok, ["C123", "G456"]}
  end

  test "reads one bounded Slack conversation and thread without exposing a credential" do
    {:ok, requester} =
      FakeRequester.start([
        slack(%{
          "channel" => %{
            "id" => "C123",
            "is_archived" => false,
            "is_ext_shared" => false,
            "is_private" => false,
            "name" => "backend-ops"
          }
        }),
        slack(%{
          "messages" => [
            %{"text" => "Root", "ts" => "1787832000.000100", "user" => "U123"},
            %{"text" => "Applied", "ts" => "1787832001.000200", "user" => "U456"}
          ],
          "response_metadata" => %{"next_cursor" => "next-page"}
        })
      ])

    client = client(requester)

    assert {:ok, %{"id" => "C123", "name" => "backend-ops"}} =
             Client.conversation_info(client, "C123")

    assert Client.read_messages(client, "C123", "1787832000.000100", %{
             "cursor" => nil,
             "inclusive" => true,
             "latest" => "1787832999.999999",
             "limit" => 100,
             "oldest" => "1787832000.000100"
           }) ==
             {:ok,
              %{
                "cursor" => "next-page",
                "messages" => [
                  %{"text" => "Root", "ts" => "1787832000.000100", "user" => "U123"},
                  %{"text" => "Applied", "ts" => "1787832001.000200", "user" => "U456"}
                ]
              }}

    assert [
             {:get, "/conversations.info?channel=C123&include_num_members=false", nil, []},
             {:get, history_path, nil, []}
           ] = FakeRequester.requests(requester)

    assert history_path =~ "/conversations.replies?"
    assert history_path =~ "channel=C123"
    assert history_path =~ "ts=1787832000.000100"
    refute history_path =~ "cursor="
  end

  test "lists bounded channel bookmarks and reads one exact file or canvas object" do
    {:ok, requester} =
      FakeRequester.start([
        slack(%{
          "bookmarks" => [
            %{
              "channel_id" => "C123",
              "entity_id" => nil,
              "id" => "BkRUNBOOK",
              "link" => "https://runbooks.example.test/checkout",
              "title" => "Checkout runbook",
              "type" => "link"
            }
          ]
        }),
        slack(%{
          "file" => %{
            "channels" => ["C123"],
            "id" => "F123",
            "mimetype" => "text/markdown",
            "plain_text" => "# Runbook",
            "size" => 9,
            "title" => "Runbook"
          }
        })
      ])

    client = client(requester)

    assert {:ok, [%{"id" => "BkRUNBOOK"}]} = Client.list_bookmarks(client, "C123")

    assert {:ok, %{"id" => "F123", "plain_text" => "# Runbook"}} =
             Client.file_info(client, "F123")

    assert [
             {:post, "/bookmarks.list", %{"channel_id" => "C123"}, []},
             {:get, "/files.info?file=F123", nil, []}
           ] = FakeRequester.requests(requester)
  end

  test "rejects malformed or over-bound Slack resource responses" do
    bookmarks =
      Enum.map(1..101, fn index ->
        %{
          "channel_id" => "C123",
          "entity_id" => nil,
          "id" => "Bk#{index}",
          "link" => "https://example.test/#{index}",
          "title" => "Resource #{index}",
          "type" => "link"
        }
      end)

    {:ok, requester} =
      FakeRequester.start([
        slack(%{"bookmarks" => bookmarks}),
        slack(%{"file" => %{"id" => "F999"}})
      ])

    client = client(requester)

    assert Client.list_bookmarks(client, "C123") ==
             {:error, {:slack_protocol_error, :bookmarks}}

    assert Client.file_info(client, "F123") ==
             {:error, {:slack_protocol_error, :file}}
  end

  test "uploads multiple files through Slack's external flow and returns the bound share" do
    {:ok, requester} =
      FakeRequester.start([
        slack(%{
          "file_id" => "F123",
          "upload_url" => "https://files.slack.com/upload/v1/one"
        }),
        slack(%{
          "file_id" => "F456",
          "upload_url" => "https://files.slack.com/upload/v1/two"
        }),
        slack(%{"files" => [%{"id" => "F123"}, %{"id" => "F456"}]}),
        slack(%{
          "messages" => [
            %{
              "files" => [
                %{"id" => "F123", "name" => "chart--delivery-01.png"},
                %{"id" => "F456", "name" => "errors--delivery-02.gif"}
              ],
              "ts" => "1787832001.000300"
            }
          ],
          "response_metadata" => %{"next_cursor" => ""}
        })
      ])

    {:ok, uploader} = FakeUploader.start()

    assert {:ok, client} =
             Client.new(
               http: requester,
               requester: FakeRequester,
               upload_http: uploader,
               uploader: FakeUploader
             )

    files = [
      %{
        alt_text: "Rendered output for: Done.",
        data: "png bytes",
        filename: "chart--delivery-01.png",
        media_type: "image/png",
        title: "chart.png"
      },
      %{
        alt_text: "Rendered output for: Done.",
        data: "gif bytes",
        filename: "errors--delivery-02.gif",
        media_type: "image/gif",
        title: "errors.gif"
      }
    ]

    assert Client.upload_files(
             client,
             "C123",
             "1787832000.000100",
             %{"message" => "Done.", "records" => []},
             "delivery:slack:visuals",
             files
           ) == {:ok, "1787832001.000300"}

    assert FakeUploader.uploads(uploader) == [
             {"https://files.slack.com/upload/v1/one", "png bytes", "image/png"},
             {"https://files.slack.com/upload/v1/two", "gif bytes", "image/gif"}
           ]

    [first_url, second_url, complete, history] = FakeRequester.requests(requester)

    assert first_url ==
             {:post, "/files.getUploadURLExternal",
              %{
                "alt_txt" => "Rendered output for: Done.",
                "filename" => "chart--delivery-01.png",
                "length" => 9
              }, []}

    assert second_url ==
             {:post, "/files.getUploadURLExternal",
              %{
                "alt_txt" => "Rendered output for: Done.",
                "filename" => "errors--delivery-02.gif",
                "length" => 9
              }, []}

    assert {:post, "/files.completeUploadExternal", completion, []} = complete
    assert completion["channel_id"] == "C123"
    assert completion["thread_ts"] == "1787832000.000100"
    assert completion["initial_comment"] == "Done."
    assert Jason.decode!(completion["blocks"]) |> length() == 1

    assert completion["files"] == [
             %{"id" => "F123", "title" => "chart.png"},
             %{"id" => "F456", "title" => "errors.gif"}
           ]

    assert {:get, path, nil, []} = history
    assert path =~ "/conversations.replies?"
  end

  test "finds one file-share message only when it contains every deterministic filename" do
    {:ok, requester} =
      FakeRequester.start([
        slack(%{
          "messages" => [
            %{"files" => [%{"name" => "one.png"}], "ts" => "1.1"},
            %{
              "files" => [%{"name" => "one.png"}, %{"name" => "two.gif"}],
              "ts" => "1.2"
            }
          ],
          "response_metadata" => %{"next_cursor" => ""}
        })
      ])

    assert Client.find_files(client(requester), "C123", nil, ["one.png", "two.gif"]) ==
             {:ok, "1.2"}
  end

  test "only an active full human in the bound workspace may confirm a control" do
    {:ok, requester} =
      FakeRequester.start([
        slack(%{
          "user" => %{
            "deleted" => false,
            "id" => "U123",
            "is_bot" => false,
            "is_restricted" => false,
            "is_ultra_restricted" => false,
            "team_id" => "T123"
          }
        }),
        slack(%{
          "user" => %{
            "deleted" => false,
            "id" => "U456",
            "is_bot" => false,
            "is_restricted" => true,
            "is_ultra_restricted" => false,
            "team_id" => "T123"
          }
        }),
        slack(%{"user" => %{"id" => "U789", "team_id" => "T999"}}),
        slack(%{"user" => "not-an-object"})
      ])

    client = client(requester)

    assert Client.user_allowed(client, "U123", "T123") == {:ok, true}
    assert Client.user_allowed(client, "U456", "T123") == {:ok, false}
    assert Client.user_allowed(client, "U789", "T123") == {:ok, false}

    assert Client.user_allowed(client, "U000", "T123") ==
             {:error, {:slack_protocol_error, :user}}

    assert Enum.map(FakeRequester.requests(requester), &elem(&1, 1)) == [
             "/users.info?user=U123",
             "/users.info?user=U456",
             "/users.info?user=U789",
             "/users.info?user=U000"
           ]
  end

  test "resolves a configured Slack user group to bounded current member ids" do
    {:ok, requester} = FakeRequester.start([slack(%{"users" => ["U456", "U123"]})])
    client = client(requester)

    assert Client.user_group_members(client, "S123", "T123") == {:ok, ["U123", "U456"]}

    assert [{:get, "/usergroups.users.list?usergroup=S123", nil, []}] =
             FakeRequester.requests(requester)
  end

  test "lists only current joined conversations through bounded pagination" do
    {:ok, requester} =
      FakeRequester.start([
        slack(%{
          "channels" => [
            %{"id" => "C456", "is_archived" => false, "is_member" => true},
            %{"id" => "C999", "is_archived" => true, "is_member" => true}
          ],
          "response_metadata" => %{"next_cursor" => "next"}
        }),
        slack(%{
          "channels" => [
            %{"id" => "G123", "is_archived" => false, "is_member" => true},
            %{"id" => "C777", "is_archived" => false, "is_member" => false}
          ],
          "response_metadata" => %{"next_cursor" => ""}
        })
      ])

    client = client(requester)
    assert Client.joined_conversations(client) == {:ok, ["C456", "G123"]}

    assert Enum.map(FakeRequester.requests(requester), &elem(&1, 1)) == [
             "/users.conversations?exclude_archived=true&limit=200&types=public_channel%2Cprivate_channel",
             "/users.conversations?exclude_archived=true&limit=200&types=public_channel%2Cprivate_channel&cursor=next"
           ]
  end

  test "uses channel history for a top-level message and rejects malformed Slack payloads" do
    {:ok, requester} =
      FakeRequester.start([
        slack(%{"messages" => [], "response_metadata" => %{"next_cursor" => ""}}),
        {:ok, %{body: %{"ok" => true, "ts" => 42}, headers: [], status: 200}},
        {:ok,
         %{
           body: "upstream rate limit",
           headers: [{"retry-after", "23"}],
           status: 429
         }}
      ])

    client = client(requester)
    assert Client.find_message(client, "C123", nil, "delivery:slack:2") == :not_found

    assert Client.post_message(client, "C123", nil, "Done.", "delivery:slack:2") ==
             {:error, {:slack_protocol_error, :message}}

    assert Client.add_reaction(client, "C123", "1787832001.000200", "rocket") ==
             {:error,
              {:delivery_rate_limited, 23, {:slack_http_error, 429, "upstream rate limit"}}}

    assert [
             {:get, "/conversations.history?channel=C123&limit=100&include_all_metadata=true",
              nil, []}
             | _
           ] =
             FakeRequester.requests(requester)
  end

  test "requires an exact requester callback and bounded trusted configuration" do
    assert Client.new(http: self(), requester: String) ==
             {:error, {:invalid_slack_client, :requester}}

    assert Client.new(http: self(), requester: :not_a_module) ==
             {:error, {:invalid_slack_client, :requester}}

    assert Client.new(:invalid) == {:error, {:invalid_slack_client, :fields}}
  end

  test "Slack protocol failures remain typed across every administrative adapter call" do
    {:ok, requester} =
      FakeRequester.start([
        slack(%{"view" => %{"type" => "modal"}}),
        {:error, :invite_offline},
        {:error, :topic_offline},
        {:error, :pin_offline},
        {:error, :conversation_offline},
        slack(%{"users" => "not-a-list"}),
        slack(%{"channels" => "not-a-list"}),
        {:ok, %{body: %{"error" => "ratelimited", "ok" => false}, headers: [], status: 200}},
        {:ok, %{body: %{"error" => "server_error"}, headers: [], status: 500}},
        {:ok, %{body: %{}, headers: [], status: 500}},
        {:ok, :"not-an-http-response"}
      ])

    client = client(requester)

    assert Client.publish_home(client, "U123", %{"blocks" => [], "type" => "home"}) ==
             {:error, {:slack_protocol_error, :home_view}}

    assert Client.invite_users(client, "C123", ["U123"]) == {:error, :invite_offline}
    assert Client.set_topic(client, "C123", "Incident topic") == {:error, :topic_offline}
    assert Client.pin_message(client, "C123", "1.000001") == {:error, :pin_offline}
    assert Client.conversation_state(client, "C123") == {:error, :conversation_offline}

    assert Client.user_group_members(client, "S123", "T123") ==
             {:error, {:slack_protocol_error, :user_group}}

    assert Client.joined_conversations(client) ==
             {:error, {:slack_protocol_error, :conversations}}

    assert Client.add_reaction(client, "C123", "1.000001", "rocket") ==
             {:error, {:delivery_rate_limited, nil, {:slack_api_error, "ratelimited"}}}

    assert Client.add_reaction(client, "C123", "1.000001", "rocket") ==
             {:error, {:slack_http_error, 500, "server_error"}}

    assert Client.add_reaction(client, "C123", "1.000001", "rocket") ==
             {:error, {:slack_http_error, 500, :invalid_response}}

    assert Client.add_reaction(client, "C123", "1.000001", "rocket") ==
             {:error, {:slack_protocol_error, :response}}
  end

  test "conversation creation reconciles exact resources and never guesses from malformed search" do
    requested_at = ~U[2026-08-28 12:00:00.000000Z]
    name = "ems-0828-checkout-1234abcd"

    existing = %{
      "created" => DateTime.to_unix(requested_at),
      "creator" => "U999BOT",
      "id" => "CEXISTING",
      "is_private" => true,
      "name" => name
    }

    created = put_in(existing, ["id"], "CCREATED")

    {:ok, requester} =
      FakeRequester.start([
        slack(%{"channels" => [existing], "response_metadata" => %{"next_cursor" => ""}}),
        slack(%{"channels" => [], "response_metadata" => %{"next_cursor" => ""}}),
        slack(%{"channel" => created}),
        slack(%{"channels" => [], "response_metadata" => %{"next_cursor" => ""}}),
        {:ok, %{body: %{"error" => "name_taken", "ok" => false}, headers: [], status: 200}},
        slack(%{"channels" => [], "response_metadata" => %{"next_cursor" => ""}}),
        slack(%{"channels" => [42], "response_metadata" => %{"next_cursor" => ""}})
      ])

    client = client(requester)

    assert Client.ensure_conversation(client, "T123", name, true, "U999BOT", requested_at) ==
             {:ok, "CEXISTING"}

    assert Client.ensure_conversation(client, "T123", name, true, "U999BOT", requested_at) ==
             {:ok, "CCREATED"}

    assert Client.ensure_conversation(client, "T123", name, true, "U999BOT", requested_at) ==
             {:error, {:slack_reconciliation_pending, :conversation}}

    assert Client.ensure_conversation(client, "T123", name, true, "U999BOT", requested_at) ==
             {:error, {:slack_protocol_error, :conversation}}

    assert Client.ensure_conversation(client, "T123", name, :private, "U999BOT", requested_at) ==
             {:error, {:invalid_slack_api_request, :private}}

    assert Client.ensure_conversation(client, "T123", name, true, "U999BOT", "yesterday") ==
             {:error, {:invalid_slack_api_request, :requested_at}}
  end

  test "message and file reconciliation reject malformed history and preserve retry custody" do
    {:ok, requester} =
      FakeRequester.start([
        slack(%{"messages" => [42], "response_metadata" => %{"next_cursor" => ""}}),
        slack(%{
          "messages" => [%{"files" => [42], "ts" => "1.000001"}],
          "response_metadata" => %{"next_cursor" => ""}
        }),
        slack(%{"file_id" => "F123", "upload_url" => "https://files.slack.com/upload/one"}),
        slack(%{"files" => [%{"id" => "F123"}]}),
        slack(%{"messages" => [], "response_metadata" => %{"next_cursor" => ""}}),
        slack(%{"upload_url" => "https://files.slack.com/upload/missing-id"})
      ])

    {:ok, uploader} = FakeUploader.start()

    assert {:ok, client} =
             Client.new(
               http: requester,
               requester: FakeRequester,
               upload_http: uploader,
               uploader: FakeUploader
             )

    assert Client.find_message(client, "C123", nil, "delivery:1") ==
             {:error, {:slack_protocol_error, :message}}

    assert Client.find_files(client, "C123", nil, ["one.png"]) ==
             {:error, {:slack_protocol_error, :file}}

    file = %{
      alt_text: "Rendered output",
      data: "png",
      filename: "one.png",
      media_type: "image/png",
      title: "one.png"
    }

    assert Client.upload_files(client, "C123", nil, "Done.", "delivery:files", [file]) ==
             {:error, {:slack_reconciliation_pending, :file_share}}

    assert Client.upload_files(client, "C123", nil, "Done.", "delivery:files:2", [file]) ==
             {:error, {:slack_protocol_error, :upload_target}}
  end

  test "invalid message, audience, and upload values fail before external side effects" do
    {:ok, requester} = FakeRequester.start([])
    client = client(requester)

    assert Client.find_message(client, "", nil, "delivery") ==
             {:error, {:invalid_slack_api_request, :text}}

    assert Client.find_files(client, "C123", nil, []) ==
             {:error, {:invalid_slack_api_request, :files}}

    assert Client.post_message(client, "C123", nil, %{}, "delivery") ==
             {:error, {:invalid_slack_render, :document}}

    assert Client.update_message(client, "C123", "", "Done.", "delivery") ==
             {:error, {:invalid_slack_api_request, :text}}

    assert Client.invite_users(client, "C123", ["U123", "U123"]) ==
             {:error, {:invalid_slack_api_request, :users}}

    assert Client.invite_users(client, "C123", :users) ==
             {:error, {:invalid_slack_api_request, :users}}

    assert Client.set_topic(client, "C123", String.duplicate("x", 251)) ==
             {:error, {:invalid_slack_api_request, :text}}

    assert Client.upload_files(client, "C123", nil, "Done.", "delivery", []) ==
             {:error, {:invalid_slack_api_request, :files}}

    assert Client.upload_files(client, "C123", nil, "Done.", "delivery", :files) ==
             {:error, {:invalid_slack_api_request, :files}}

    assert Client.upload_files(client, "C123", nil, "Done.", "delivery", [
             %{data: "png"}
           ]) == {:error, {:invalid_slack_api_request, :files}}

    assert FakeRequester.requests(requester) == []

    {:ok, upload_requester} =
      FakeRequester.start([
        slack(%{"file_id" => "F123", "upload_url" => "https://files.slack.com/upload/one"})
      ])

    assert {:ok, failing_client} =
             Client.new(
               http: upload_requester,
               requester: FakeRequester,
               upload_http: self(),
               uploader: FailingUploader
             )

    valid_file = %{
      alt_text: "Rendered output",
      data: "png",
      filename: "one.png",
      media_type: "image/png",
      title: "one.png"
    }

    assert Client.upload_files(
             failing_client,
             "C123",
             nil,
             "Done.",
             "delivery:failed",
             [valid_file]
           ) == {:error, :upload_failed}
  end

  test "structured Slack reads reject malformed cursors, filters, and identities before transport" do
    {:ok, requester} = FakeRequester.start([])
    client = client(requester)

    assert Client.search_context(client, "token", :invalid) ==
             {:error, {:invalid_slack_api_request, :search}}

    for document <- [
          %{
            "cursor" => 42,
            "exclude_archived" => true,
            "limit" => 50,
            "types" => ["public_channel"]
          },
          %{
            "cursor" => nil,
            "exclude_archived" => "yes",
            "limit" => 50,
            "types" => ["public_channel"]
          },
          %{
            "cursor" => nil,
            "exclude_archived" => true,
            "limit" => 0,
            "types" => ["public_channel"]
          },
          %{"cursor" => nil, "exclude_archived" => true, "limit" => 50, "types" => :invalid},
          %{"cursor" => nil, "exclude_archived" => true, "limit" => 50, "types" => ["im"]},
          :invalid
        ] do
      assert Client.list_conversations(client, document) ==
               {:error, {:invalid_slack_api_request, :conversations}}
    end

    base_history = %{
      "cursor" => nil,
      "inclusive" => false,
      "latest" => nil,
      "limit" => 50,
      "oldest" => nil
    }

    for document <- [
          %{base_history | "cursor" => 42},
          %{base_history | "inclusive" => "yes"},
          %{base_history | "limit" => 0},
          %{base_history | "oldest" => "yesterday"},
          %{base_history | "latest" => "tomorrow"},
          :invalid
        ] do
      assert Client.read_messages(client, "C123", nil, document) ==
               {:error, {:invalid_slack_api_request, :history}}
    end

    assert Client.read_messages(client, "C123", "not-a-timestamp", base_history) ==
             {:error, {:invalid_slack_api_request, :timestamp}}

    assert Client.conversation_info(client, "not valid") ==
             {:error, {:invalid_slack_api_request, :id}}

    assert Client.list_bookmarks(client, "not valid") ==
             {:error, {:invalid_slack_api_request, :id}}

    assert Client.file_info(client, "not valid") ==
             {:error, {:invalid_slack_api_request, :id}}

    assert FakeRequester.requests(requester) == []
  end

  test "every public Slack operation rejects invalid host identity before transport" do
    {:ok, requester} = FakeRequester.start([])
    client = client(requester)
    timestamp = ~U[2026-08-28 12:00:00Z]

    invalid_text = {:error, {:invalid_slack_api_request, :text}}
    invalid_id = {:error, {:invalid_slack_api_request, :id}}

    assert Client.find_message(client, "C123", 42, "delivery") == invalid_text
    assert Client.find_message(client, "C123", nil, "") == invalid_text
    assert Client.find_files(client, "C123", 42, ["one.png"]) == invalid_text

    assert Client.find_files(client, "C123", nil, ["one.png", "one.png"]) ==
             {:error, {:invalid_slack_api_request, :files}}

    assert Client.post_message(client, "", nil, "Done", "delivery") == invalid_text
    assert Client.post_message(client, "C123", 42, "Done", "delivery") == invalid_text
    assert Client.post_message(client, "C123", nil, "Done", "") == invalid_text
    assert Client.update_message(client, "", "1.1", "Done", "delivery") == invalid_text
    assert Client.update_message(client, "C123", "1.1", "Done", "") == invalid_text

    assert Client.publish_home(client, "not valid", %{"blocks" => [], "type" => "home"}) ==
             invalid_id

    assert Client.add_reaction(client, "", "1.1", "eyes") == invalid_text
    assert Client.add_reaction(client, "C123", "", "eyes") == invalid_text
    assert Client.add_reaction(client, "C123", "1.1", "") == invalid_text
    assert Client.remove_reaction(client, "", "1.1", "eyes") == invalid_text
    assert Client.remove_reaction(client, "C123", "", "eyes") == invalid_text
    assert Client.remove_reaction(client, "C123", "1.1", "") == invalid_text

    assert Client.ensure_conversation(client, "not valid", "incident", true, "U123", timestamp) ==
             invalid_id

    assert Client.ensure_conversation(client, "T123", "Not Valid", true, "U123", timestamp) ==
             {:error, {:invalid_slack_api_request, :conversation_name}}

    assert Client.ensure_conversation(client, "T123", "incident", true, "not valid", timestamp) ==
             invalid_id

    assert Client.invite_users(client, "not valid", ["U123"]) == invalid_id

    assert Client.invite_users(client, "C123", ["not valid"]) ==
             {:error, {:invalid_slack_api_request, :users}}

    assert Client.set_topic(client, "not valid", "Incident") == invalid_id
    assert Client.set_topic(client, "C123", "") == invalid_text
    assert Client.pin_message(client, "not valid", "1.1") == invalid_id
    assert Client.pin_message(client, "C123", "") == invalid_text
    assert Client.conversation_state(client, "not valid") == invalid_id
    assert Client.user_allowed(client, "not valid", "T123") == invalid_id
    assert Client.user_allowed(client, "U123", "not valid") == invalid_id
    assert Client.user_group_members(client, "not valid", "T123") == invalid_id
    assert Client.user_group_members(client, "S123", "not valid") == invalid_id

    assert FakeRequester.requests(requester) == []
  end

  test "Slack object reads never accept a crossed or structurally invalid resource" do
    {:ok, requester} =
      FakeRequester.start([
        slack(%{"channel" => %{"id" => "C999"}}),
        slack(%{"channel" => "not-an-object"}),
        slack(%{"file" => %{"id" => "F999"}}),
        slack(%{"bookmarks" => [%{"channel_id" => "C123", "id" => 42}]}),
        slack(%{"messages" => "not-a-list"}),
        slack(%{"results" => "not-an-object"}),
        slack(%{"results" => %{}, "next_cursor" => 42}),
        slack(%{"channel" => %{"id" => "C999", "is_archived" => false}}),
        slack(%{"channel" => "not-an-object"}),
        slack(%{
          "channels" => [
            %{
              "id" => "C123",
              "is_archived" => false,
              "is_private" => false,
              "name" => "backend",
              "purpose" => "not-an-object",
              "topic" => nil
            }
          ],
          "response_metadata" => %{"next_cursor" => ""}
        }),
        slack(%{
          "channels" => [%{"id" => "not valid", "is_archived" => false, "is_member" => true}],
          "response_metadata" => %{"next_cursor" => ""}
        })
      ])

    client = client(requester)

    assert Client.conversation_info(client, "C123") ==
             {:error, {:slack_protocol_error, :conversation}}

    assert Client.conversation_info(client, "C123") ==
             {:error, {:slack_protocol_error, :conversation}}

    assert Client.file_info(client, "F123") == {:error, {:slack_protocol_error, :file}}

    assert Client.list_bookmarks(client, "C123") ==
             {:error, {:slack_protocol_error, :bookmarks}}

    assert Client.read_messages(client, "C123", nil, %{}) ==
             {:error, {:slack_protocol_error, :history}}

    assert Client.search_context(client, "token", %{"query" => "deploy"}) ==
             {:error, {:slack_protocol_error, :search}}

    assert Client.search_context(client, "token", %{"query" => "deploy"}) ==
             {:error, {:slack_protocol_error, :search}}

    assert Client.conversation_state(client, "C123") ==
             {:error, {:slack_protocol_error, :conversation}}

    assert Client.conversation_state(client, "C123") ==
             {:error, {:slack_protocol_error, :conversation}}

    assert Client.list_conversations(client, %{}) ==
             {:error, {:slack_protocol_error, :conversations}}

    assert Client.joined_conversations(client) ==
             {:error, {:slack_protocol_error, :conversations}}
  end

  defp client(requester) do
    assert {:ok, client} = Client.new(http: requester, requester: FakeRequester)
    client
  end

  defp slack(body), do: {:ok, %{body: Map.put(body, "ok", true), headers: [], status: 200}}
end
