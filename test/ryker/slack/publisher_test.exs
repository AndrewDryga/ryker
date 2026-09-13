defmodule Ryker.Slack.PublisherTest do
  use ExUnit.Case, async: true

  alias Ryker.Delivery.Request
  alias Ryker.Slack.Publisher

  defmodule FakeAPI do
    @behaviour Ryker.Slack.API

    def start(options \\ %{}), do: Agent.start_link(fn -> Map.merge(initial(), options) end)

    @impl true
    def find_message(agent, channel, thread, delivery_ref) do
      Agent.get_and_update(agent, fn state ->
        key = {channel, thread, delivery_ref}

        result =
          state.messages
          |> Map.fetch(key)
          |> case do
            {:ok, message_ref} -> {:ok, message_ref}
            :error -> :not_found
          end

        {result, %{state | finds: state.finds + 1}}
      end)
    end

    @impl true
    def post_message(agent, channel, thread, body, delivery_ref) do
      Agent.get_and_update(agent, fn state ->
        key = {channel, thread, delivery_ref}
        message_ref = "1787832001.000200"
        messages = Map.put(state.messages, key, message_ref)
        state = %{state | messages: messages, posts: [{channel, thread, body, delivery_ref}]}

        if state.lose_post_response,
          do: {{:error, :socket_closed}, %{state | lose_post_response: false}},
          else: {{:ok, message_ref}, state}
      end)
    end

    @impl true
    def update_message(agent, channel, message_ref, body, delivery_ref) do
      Agent.update(agent, fn state ->
        %{state | updates: [{channel, message_ref, body, delivery_ref} | state.updates]}
      end)
    end

    @impl true
    def add_reaction(agent, channel, message_ref, emoji_name) do
      Agent.update(agent, fn state ->
        %{state | reactions: MapSet.put(state.reactions, {channel, message_ref, emoji_name})}
      end)
    end

    @impl true
    def find_files(agent, channel, thread, filenames) do
      Agent.get_and_update(agent, fn state ->
        key = {channel, thread, filenames}

        result =
          case Map.fetch(state.files, key) do
            {:ok, message_ref} -> {:ok, message_ref}
            :error -> :not_found
          end

        {result, %{state | file_finds: state.file_finds + 1}}
      end)
    end

    @impl true
    def upload_files(agent, channel, thread, body, delivery_ref, files) do
      Agent.get_and_update(agent, fn state ->
        filenames = Enum.map(files, & &1.filename)
        key = {channel, thread, filenames}
        message_ref = "1787832001.000300"

        next = %{
          state
          | files: Map.put(state.files, key, message_ref),
            uploads: [{channel, thread, body, delivery_ref, files} | state.uploads]
        }

        if state.lose_upload_response,
          do: {{:error, :socket_closed}, %{next | lose_upload_response: false}},
          else: {{:ok, message_ref}, next}
      end)
    end

    def state(agent), do: Agent.get(agent, & &1)

    defp initial do
      %{
        file_finds: 0,
        files: %{},
        finds: 0,
        lose_post_response: false,
        lose_upload_response: false,
        messages: %{},
        posts: [],
        reactions: MapSet.new(),
        updates: [],
        uploads: []
      }
    end
  end

  test "a lost Slack post response reconciles the metadata marker exactly once" do
    {:ok, api} = FakeAPI.start(%{lose_post_response: true})
    request = message_request()
    binding = publisher_binding(api)

    assert Publisher.publish_message(request, binding) ==
             {:error, {:delivery_uncertain, :socket_closed}}

    assert {:ok, receipt} = Publisher.publish_message(request, binding)
    assert receipt["message_ref"] == "1787832001.000200"
    assert receipt["delivery_ref"] == request.ref

    state = FakeAPI.state(api)
    assert length(state.posts) == 1
    assert state.finds == 2
  end

  test "passes only the host-materialized document to Slack rendering" do
    {:ok, api} = FakeAPI.start()

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

    assert [{_channel, _thread, document, _ref}] = FakeAPI.state(api).posts
    assert document == request.document
  end

  test "typed Slack entities receive only the delivery-bound host authority" do
    {:ok, api} = FakeAPI.start()

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

    assert [{_channel, _thread, document, _ref}] = FakeAPI.state(api).posts
    assert document["message"] == request.document["message"]
    assert document["slack_mentions"] == authority
  end

  test "typed Slack entities cannot be delivered without host authority" do
    {:ok, api} = FakeAPI.start()

    assert {:ok, request} =
             Request.new(%{
               message_attributes()
               | document: %{
                   "message" => "Could [@Mallory](slack-user:U999) check this?"
                 }
             })

    assert Publisher.publish_message(request, publisher_binding(api)) ==
             {:error, {:slack_mention_authority_not_configured, :delivery}}

    assert FakeAPI.state(api).posts == []
  end

  test "a lost Slack file completion response reconciles every artifact exactly once" do
    {:ok, api} = FakeAPI.start(%{lose_upload_response: true})
    request = artifact_message_request()
    binding = publisher_binding(api)

    assert Publisher.publish_message(request, binding) ==
             {:error, {:delivery_uncertain, :socket_closed}}

    assert {:ok, receipt} = Publisher.publish_message(request, binding)
    assert receipt["message_ref"] == "1787832001.000300"
    assert receipt["delivery_ref"] == request.ref

    state = FakeAPI.state(api)
    assert state.file_finds == 2
    assert length(state.uploads) == 1
    assert state.posts == []

    [{"C456", "1787832000.000100", document, delivery_ref, files}] = state.uploads
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

  test "Slack emoji reactions use the exact source message and are safe to replay" do
    {:ok, api} = FakeAPI.start()
    request = reaction_request()
    binding = publisher_binding(api)

    assert {:ok, first} = Publisher.publish_reaction(request, binding)
    assert {:ok, retry} = Publisher.publish_reaction(request, binding)
    assert retry == first

    assert FakeAPI.state(api).reactions ==
             MapSet.new([{"C456", "1787832001.000200", "white_check_mark"}])
  end

  test "a Slack workspace cannot be selected by request content" do
    {:ok, api} = FakeAPI.start()

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
    {:ok, api} = FakeAPI.start()

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

    assert FakeAPI.state(api).posts == []
    assert FakeAPI.state(api).reactions == MapSet.new()
  end

  test "a governed status refresh updates only the exact delivered Slack message" do
    {:ok, api} = FakeAPI.start()
    request = message_request()

    status = %{
      "emisar_approval_status" => approval_status("success")
    }

    assert :ok =
             Publisher.update_message(
               request,
               "1787832001.000200",
               status,
               publisher_binding(api)
             )

    assert [
             {"C456", "1787832001.000200", ^status, "delivery:slack:1"}
           ] = FakeAPI.state(api).updates
  end

  defp publisher_binding(api) do
    %{workspaces: %{"T123" => %{api: FakeAPI, client: api}}}
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
      "sha256" => :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
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
