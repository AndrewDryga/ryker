defmodule Ryker.Slack.PublisherTest do
  use ExUnit.Case, async: true
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ryker.Delivery.Request
  alias Ryker.Slack.Publisher
  alias Ryker.TestSupport.FakeSlackAPI

  test "a lost Slack post response reconciles the metadata marker exactly once" do
    {:ok, api} =
      FakeSlackAPI.start_link(
        lose: [:post_message],
        message_ref: fn _n -> "1787832001.000200" end
      )

    request = message_request()
    binding = publisher_binding(api)

    assert Publisher.publish_message(request, binding) ==
             {:error, {:delivery_uncertain, :socket_closed}}

    assert {:ok, receipt} = Publisher.publish_message(request, binding)
    assert receipt["message_ref"] == "1787832001.000200"
    assert receipt["delivery_ref"] == request.ref

    state = FakeSlackAPI.state(api)
    assert length(state.posts) == 1
    assert state.finds == 2
  end

  test "a Slack refusal of the post is a definite failure, not an uncertain delivery" do
    # Slack answering ok:false means nothing was posted, yet the publisher
    # wrapped every non-rate-limit error as delivery_uncertain, which the
    # dispatcher always retries: an invalid_blocks or missing_scope reply
    # spent all eight attempts, each walking up to a hundred history pages
    # for a message that was never there, before the delivery blocked.
    {:ok, api} =
      FakeSlackAPI.start_link(
        refuse: %{"delivery:slack:1" => {:slack_api_error, "invalid_blocks"}}
      )

    request = message_request()

    assert Publisher.publish_message(request, publisher_binding(api)) ==
             {:error, {:slack_api_error, "invalid_blocks"}}
  end

  test "passes only the host-materialized document to Slack rendering" do
    {:ok, api} = FakeSlackAPI.start_link()

    assert {:ok, request} =
             Request.new(%{
               message_attributes()
               | document: %{
                   "message" => "I can prepare that.",
                   "records" => [
                     %{
                       "kind" => "task_offer",
                       "payload" => %{
                         "kind" => "engineering",
                         "prompt" => "Make the change.",
                         "repository" => "ryker",
                         "title" => "Make the change"
                       },
                       "ref" => "record:task_offer:abc",
                       "status" => "open"
                     }
                   ]
                 }
             })

    assert {:ok, _receipt} = Publisher.publish_message(request, publisher_binding(api))

    assert [%{document: document}] = FakeSlackAPI.state(api).posts
    assert document == request.document
  end

  test "typed Slack entities receive only the delivery-bound host authority" do
    {:ok, api} = FakeSlackAPI.start_link()

    assert {:ok, request} =
             Request.new(%{
               message_attributes()
               | document: %{
                   "message" => "Could [@Bruno](slack-user:U123) check this?"
                 }
             })

    authority = %{
      "broadcasts" => [],
      "channels" => ["slack:T123:C456"],
      "user_groups" => [],
      "users" => ["slack-user:U123"],
      "workspace_ref" => "T123"
    }

    binding =
      api
      |> publisher_binding()
      |> Map.put(:mention_authority, fn "delivery:slack:1" -> {:ok, authority} end)

    assert {:ok, _receipt} = Publisher.publish_message(request, binding)

    assert [%{document: document}] = FakeSlackAPI.state(api).posts
    assert document["message"] == request.document["message"]
    assert document["slack_mentions"] == authority
  end

  test "typed Slack entities cannot be delivered without host authority" do
    {:ok, api} = FakeSlackAPI.start_link()

    assert {:ok, request} =
             Request.new(%{
               message_attributes()
               | document: %{
                   "message" => "Could [@Mallory](slack-user:U999) check this?"
                 }
             })

    assert Publisher.publish_message(request, publisher_binding(api)) ==
             {:error, {:slack_mention_authority_not_configured, :delivery}}

    assert FakeSlackAPI.state(api).posts == []
  end

  test "a lost Slack file completion response reconciles every artifact exactly once" do
    {:ok, api} =
      FakeSlackAPI.start_link(
        lose: [:upload_files],
        message_ref: fn _n -> "1787832001.000300" end
      )

    request = artifact_message_request()
    binding = publisher_binding(api)

    assert Publisher.publish_message(request, binding) ==
             {:error, {:delivery_uncertain, :socket_closed}}

    assert {:ok, receipt} = Publisher.publish_message(request, binding)
    assert receipt["message_ref"] == "1787832001.000300"
    assert receipt["delivery_ref"] == request.ref

    state = FakeSlackAPI.state(api)
    assert state.file_finds == 2
    assert length(state.uploads) == 1
    assert state.posts == []

    # The share cannot be older than the request it delivers: the search starts there, not at
    # the channel's first message, which Slack walked 100 pages at a time (2026-10-04 review).
    frozen = request.frozen_at |> DateTime.add(-3_600) |> DateTime.to_unix()
    assert state.searched_since == ["#{frozen}.000000", "#{frozen}.000000"]

    [
      %{
        channel: "C456",
        delivery_ref: delivery_ref,
        document: document,
        files: files,
        thread: "1787832000.000100"
      }
    ] = state.uploads

    assert document == request.document
    assert delivery_ref == request.ref

    assert Enum.map(files, &Map.take(&1, [:alt_text, :filename, :media_type, :title])) == [
             %{
               alt_text: "Rendered output for: Done with charts.",
               filename: "latency-chart--b898afaa7e79-01.png",
               media_type: "image/png",
               title: "latency chart.png"
             },
             %{
               alt_text: "Rendered output for: Done with charts.",
               filename: "error-rate--b898afaa7e79-02.gif",
               media_type: "image/gif",
               title: "error rate.gif"
             }
           ]

    assert Enum.map(files, & &1.data) == [png(), gif()]
  end

  # Slack takes an image's description up to 1,000 bytes and its title up to 200. They were cut
  # to 960 and 200 characters, so a long reply with em dashes, curly quotes or Cyrillic made the
  # upload invalid, and the image never reached Slack (2026-10-04 review).
  test "an image's description and title fit Slack's byte limits in any language" do
    {:ok, api} = FakeSlackAPI.start_link(message_ref: fn _n -> "1787832001.000400" end)
    message = String.duplicate("Готово — графики ниже. ", 80)

    assert {:ok, request} =
             message_attributes()
             |> Map.merge(%{
               artifacts: [
                 artifact(
                   "output:chart",
                   String.duplicate("график", 20) <> ".png",
                   "image/png",
                   png()
                 )
               ],
               document: %{"message" => message},
               ref: "delivery:slack:long-visuals"
             })
             |> Request.new()

    assert {:ok, _receipt} = Publisher.publish_message(request, publisher_binding(api))
    [%{files: [file]}] = FakeSlackAPI.state(api).uploads
    assert byte_size(file.alt_text) <= 1_000
    assert byte_size(file.title) <= 200
    assert String.valid?(file.alt_text) and String.valid?(file.title)
  end

  test "Slack emoji reactions use the exact source message and are safe to replay" do
    {:ok, api} = FakeSlackAPI.start_link()
    request = reaction_request()
    binding = publisher_binding(api)

    assert {:ok, first} = Publisher.publish_reaction(request, binding)
    assert {:ok, retry} = Publisher.publish_reaction(request, binding)
    assert retry == first

    assert FakeSlackAPI.state(api).reactions ==
             MapSet.new([{"C456", "1787832001.000200", "white_check_mark"}])
  end

  test "a Slack workspace cannot be selected by request content" do
    {:ok, api} = FakeSlackAPI.start_link()

    assert Publisher.publish_message(message_request(), %{workspaces: %{}}) ==
             {:error, {:slack_workspace_not_configured, "T123"}}

    assert {:ok, malformed} =
             Request.new(%{
               message_attributes()
               | conversation_ref: "slack:T123:C456",
                 thread_ref: "not-a-thread"
             })

    assert Publisher.publish_message(malformed, publisher_binding(api)) ==
             {:error, {:invalid_slack_delivery_target, :thread_ref}}
  end

  test "a host-owned inactive incident destination is checked before any Slack write" do
    {:ok, api} = FakeSlackAPI.start_link()

    binding =
      api
      |> publisher_binding()
      |> Map.put(:destination_allowed, fn "T123", "C456" ->
        {:error, {:slack_incident_room_inactive, :archived}}
      end)

    assert Publisher.publish_message(message_request(), binding) ==
             {:error, {:slack_incident_room_inactive, :archived}}

    assert Publisher.publish_reaction(reaction_request(), binding) ==
             {:error, {:slack_incident_room_inactive, :archived}}

    assert FakeSlackAPI.state(api).posts == []
    assert FakeSlackAPI.state(api).reactions == MapSet.new()
  end

  test "a governed status refresh updates only the exact delivered Slack message" do
    {:ok, api} = FakeSlackAPI.start_link()
    request = message_request()

    status = %{
      "emisar_approval_statuses" => [approval_status("success")]
    }

    assert Publisher.update_message(
             request,
             "1787832001.000200",
             status,
             publisher_binding(api)
           ) == :ok

    assert [
             %{
               channel: "C456",
               delivery_ref: "delivery:slack:1",
               document: ^status,
               message_ref: "1787832001.000200"
             }
           ] = FakeSlackAPI.state(api).updates
  end

  defp publisher_binding(api) do
    %{workspaces: %{"T123" => %{api: FakeSlackAPI, client: api}}}
  end

  defp message_request do
    assert {:ok, request} = Request.new(message_attributes())
    request
  end

  defp message_attributes do
    %{
      conversation_ref: "slack:T123:C456",
      document: %{"message" => "Done."},
      kind: :message,
      ref: "delivery:slack:1",
      source_item_ref: nil,
      thread_ref: "1787832000.000100",
      transport: "slack"
    }
  end

  defp reaction_request do
    assert {:ok, request} =
             Request.new(%{
               conversation_ref: "slack:T123:C456",
               document: %{"emoji_name" => "white_check_mark"},
               kind: :reaction,
               ref: "reaction:slack:1",
               source_item_ref: "1787832001.000200",
               thread_ref: "1787832000.000100",
               transport: "slack"
             })

    request
  end

  defp artifact_message_request do
    assert {:ok, request} =
             message_attributes()
             |> Map.merge(%{
               artifacts: [
                 artifact("output:chart", "latency chart.png", "image/png", png()),
                 artifact("output:errors", "error rate.gif", "image/gif", gif())
               ],
               document: %{"message" => "Done with charts."},
               frozen_at: ~U[2026-10-04 12:00:00.000000Z],
               ref: "delivery:slack:visuals"
             })
             |> Request.new()

    request
  end

  defp artifact(ref, name, media_type, data) do
    %{
      "bytes" => byte_size(data),
      "data" => data,
      "media_type" => media_type,
      "name" => name,
      "ref" => ref,
      "sha256" => digest(data)
    }
  end

  defp approval_status(status) do
    %{
      "action_id" => "nomad.alloc_restart",
      "approval_url" => "https://emisar.example/app/acme/approvals/apr-1",
      "expires_at" => "2099-08-29T12:00:00.000000Z",
      "operation_id" => "op-1",
      "pack_ref" => "nomad@1#sha256:abc",
      "remote_error" => nil,
      "request_id" => "apr-1",
      "review" => nil,
      "run_id" => "run-1",
      "run_url" => "https://emisar.example/app/acme/runs/run-1",
      "runner_ref" => "production-runner",
      "status" => status
    }
  end

  defp png, do: <<137, 80, 78, 71, 13, 10, 26, 10, "png-body">>
  defp gif, do: <<"GIF89a", "gif-body">>
end
