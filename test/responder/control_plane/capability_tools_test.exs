defmodule Responder.ControlPlane.CapabilityToolsTest do
  use Responder.DataCase, async: true

  alias Responder.Artifacts
  alias Responder.ControlPlane.CapabilityTools
  alias Responder.Delivery.{PlatformAction, PlatformActionCustody}
  alias Responder.Episodes
  alias Responder.Episodes.Command
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo
  alias Responder.State.{Record, Records}
  alias Responder.Work.Custody

  @conversation_id "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"
  @conversation_ref "control-plane:lab:#{@conversation_id}"
  @now ~U[2026-09-02 20:00:00.000000Z]
  @policy_digest String.duplicate("a", 64)

  test "the Lab implements the exact Slack chat capability catalog without external Slack effects" do
    {binding, input_ref, source_item_ref} = lab_binding!("chat-parity")

    assert CapabilityTools.list() == Responder.Slack.CapabilityTools.definitions()

    assert Enum.map(CapabilityTools.list(), & &1["name"]) == [
             "list_slack_channels",
             "search_slack",
             "read_slack_source",
             "set_slack_reaction",
             "post_slack_message"
           ]

    assert {:ok, listed} =
             CapabilityTools.call(
               "list_slack_channels",
               %{
                 "configured_only" => false,
                 "cursor" => nil,
                 "include_archived" => false,
                 "include_resources" => true,
                 "kinds" => ["public_channel"],
                 "limit" => 50,
                 "query" => nil
               },
               binding
             )

    assert [channel] = listed["conversations"]
    assert channel["conversation_ref"] == @conversation_ref
    assert channel["source_ref"] == @conversation_ref
    assert listed["emulated"] == true
    assert listed["external_effects"] == false

    assert {:ok, searched} =
             CapabilityTools.call(
               "search_slack",
               %{
                 "after" => nil,
                 "author_ref" => nil,
                 "before" => nil,
                 "content_types" => ["messages"],
                 "conversation_refs" => [@conversation_ref],
                 "cursor" => nil,
                 "include_context" => true,
                 "limit" => 20,
                 "query" => "parity"
               },
               binding
             )

    assert [%{"content" => content, "source_ref" => ^input_ref}] =
             get_in(searched, ["results", "messages"])

    assert content =~ "Slack parity"

    assert {:ok, read} =
             CapabilityTools.call(
               "read_slack_source",
               %{
                 "after" => nil,
                 "before" => nil,
                 "cursor" => nil,
                 "limit" => 100,
                 "source_ref" => input_ref,
                 "view" => "surrounding"
               },
               binding
             )

    assert [%{"content" => ^content, "source_ref" => ^input_ref}] = read["messages"]
    assert read["emulated"] == true

    assert {:ok, %{"action_ref" => reaction_ref, "status" => "pending"}} =
             CapabilityTools.call(
               "set_slack_reaction",
               %{"action" => "add", "emoji" => "eyes", "message_ref" => input_ref},
               binding
             )

    assert %PlatformAction{
             action_ref: ^reaction_ref,
             conversation_ref: @conversation_ref,
             document: %{"action" => "add", "emoji_name" => "eyes"},
             source_item_ref: ^source_item_ref,
             status: :pending,
             tool: :set_slack_reaction,
             transport: "control_plane"
           } = Repo.get_by!(PlatformAction, action_ref: reaction_ref)

    assert {:ok,
            %{
              "kind" => "slack_post_offer",
              "record_ref" => post_ref,
              "status" => "open"
            }} =
             CapabilityTools.call(
               "post_slack_message",
               %{
                 "destination_ref" => @conversation_ref,
                 "instruction_ref" => input_ref,
                 "message" => "This additional Lab message stays local until confirmed."
               },
               binding
             )

    assert %Record{
             kind: "slack_post_offer",
             payload: %{
               "conversation_ref" => @conversation_ref,
               "destination_ref" => @conversation_ref,
               "instruction_ref" => ^input_ref,
               "message" => "This additional Lab message stays local until confirmed.",
               "requested_by_actor_ref" => "control-plane:local",
               "thread_ref" => @conversation_ref,
               "transport" => "control_plane"
             },
             status: :open
           } = Repo.get_by!(Record, ref: post_ref)
  end

  test "Lab Slack-compatible capabilities cannot escape the exact local conversation" do
    {binding, input_ref, _source_item_ref} = lab_binding!("authority")
    other = "control-plane:lab:#{Ecto.UUID.generate()}"

    assert CapabilityTools.call(
             "search_slack",
             %{"conversation_refs" => [other], "query" => "authority"},
             binding
           ) == {:error, "unauthorized"}

    assert CapabilityTools.call(
             "read_slack_source",
             %{"source_ref" => other, "view" => "channel"},
             binding
           ) == {:error, "unauthorized"}

    assert CapabilityTools.call(
             "set_slack_reaction",
             %{"action" => "add", "emoji" => "eyes", "message_ref" => other},
             binding
           ) == {:error, "unauthorized"}

    assert CapabilityTools.call(
             "post_slack_message",
             %{
               "destination_ref" => other,
               "instruction_ref" => input_ref,
               "message" => "Do not route this elsewhere."
             },
             binding
           ) == {:error, "unauthorized"}

    assert Repo.aggregate(PlatformAction, :count) == 0
    assert Repo.aggregate(Record, :count) == 0
  end

  test "Lab Slack-compatible reads preserve source-view and search-filter semantics" do
    {binding, input_ref, _source_item_ref} = lab_binding!("source-views")

    assert {:ok, %{"conversations" => []}} =
             CapabilityTools.call(
               "list_slack_channels",
               %{"kinds" => ["private_channel"], "query" => "does-not-match"},
               binding
             )

    assert {:ok, %{"messages" => messages}} =
             CapabilityTools.call(
               "read_slack_source",
               %{"limit" => 10, "source_ref" => @conversation_ref, "view" => "channel"},
               binding
             )

    assert [%{"source_ref" => ^input_ref}] = messages

    assert {:ok, %{"messages" => []}} =
             CapabilityTools.call(
               "read_slack_source",
               %{
                 "after" => "2026-09-02T20:00:01Z",
                 "source_ref" => @conversation_ref,
                 "view" => "channel"
               },
               binding
             )

    assert {:ok, %{"messages" => []}} =
             CapabilityTools.call(
               "read_slack_source",
               %{
                 "before" => "2026-09-02T19:59:59Z",
                 "source_ref" => input_ref,
                 "view" => "surrounding"
               },
               binding
             )

    assert {:ok, %{"messages" => []}} =
             CapabilityTools.call(
               "read_slack_source",
               %{"source_ref" => @conversation_ref, "view" => "metadata"},
               binding
             )

    assert {:ok, %{"messages" => []}} =
             CapabilityTools.call(
               "read_slack_source",
               %{"source_ref" => input_ref, "view" => "metadata"},
               binding
             )

    assert CapabilityTools.call(
             "read_slack_source",
             %{"source_ref" => input_ref, "view" => "thread"},
             binding
           ) == {:error, "invalid_arguments"}

    assert CapabilityTools.call(
             "read_slack_source",
             %{"source_ref" => "admit_input:missing", "view" => "surrounding"},
             binding
           ) == {:error, "unauthorized"}

    assert {:ok, searched} =
             CapabilityTools.call(
               "search_slack",
               %{
                 "after" => "2026-09-02T19:59:59Z",
                 "author_ref" => "local-operator",
                 "before" => "2026-09-02T20:00:01Z",
                 "content_types" => ["messages", "files", "channels", "users"],
                 "query" => "exact slack parity"
               },
               binding
             )

    assert [%{"source_ref" => ^input_ref}] = searched["results"]["messages"]
    assert searched["results"]["files"] == []
    assert searched["results"]["channels"] == []
    assert searched["results"]["users"] == []

    assert {:ok, %{"results" => %{"messages" => []}}} =
             CapabilityTools.call(
               "search_slack",
               %{"author_ref" => "somebody-else", "query" => "exact slack parity"},
               binding
             )
  end

  test "Lab Slack-compatible reads span every episode in the exact virtual conversation" do
    {historical_ref, _historical_episode, _historical_item_ref} =
      admit_lab_input!(
        "historical-source",
        @conversation_ref,
        "A durable message from an earlier Lab episode."
      )

    other_conversation_ref = "control-plane:lab:#{Ecto.UUID.generate()}"

    {other_ref, _other_episode, _other_item_ref} =
      admit_lab_input!(
        "other-conversation",
        other_conversation_ref,
        "A private marker from a different Lab conversation."
      )

    {binding, current_ref, _source_item_ref} = lab_binding!("cross-episode-history")

    assert {:ok, searched} =
             CapabilityTools.call(
               "search_slack",
               %{"query" => "earlier Lab episode"},
               binding
             )

    assert [%{"source_ref" => ^historical_ref}] = searched["results"]["messages"]

    assert {:ok, %{"messages" => [%{"content" => historical}]}} =
             CapabilityTools.call(
               "read_slack_source",
               %{"source_ref" => historical_ref, "view" => "surrounding"},
               binding
             )

    assert historical == "A durable message from an earlier Lab episode."

    assert {:ok, %{"messages" => channel_messages}} =
             CapabilityTools.call(
               "read_slack_source",
               %{"limit" => 100, "source_ref" => @conversation_ref, "view" => "channel"},
               binding
             )

    assert channel_messages |> Enum.map(& &1["source_ref"]) |> Enum.sort() ==
             Enum.sort([historical_ref, current_ref])

    assert CapabilityTools.call(
             "read_slack_source",
             %{"source_ref" => other_ref, "view" => "surrounding"},
             binding
           ) == {:error, "unauthorized"}

    assert {:ok, %{"results" => %{"messages" => []}}} =
             CapabilityTools.call(
               "search_slack",
               %{"query" => "private marker"},
               binding
             )
  end

  test "Lab Slack-compatible file search and document reads expose only local durable artifacts" do
    {:ok, artifact} =
      Artifacts.put(%{
        data: "# Local runbook\nThe Lab file body is readable.",
        media_type: "text/markdown",
        name: "local-runbook.md",
        source_kind: "control_plane",
        source_ref: "#{@conversation_id}:#{Ecto.UUID.generate()}:0"
      })

    descriptor = %{
      "artifact_ref" => artifact.ref,
      "bytes" => artifact.byte_size,
      "media_type" => artifact.media_type,
      "name" => artifact.name,
      "sha256" => artifact.sha256,
      "status" => "available"
    }

    {_file_input_ref, _file_episode, _source_item_ref} =
      admit_lab_content!(
        "file-source",
        @conversation_ref,
        %{"files" => [descriptor], "text" => "Use the attached local runbook."}
      )

    {binding, _current_ref, _current_item_ref} = lab_binding!("file-reader")

    assert {:ok, %{"conversations" => [listed]}} =
             CapabilityTools.call(
               "list_slack_channels",
               %{"include_resources" => true},
               binding
             )

    assert listed["resources"] == [%{"kind" => "file", "source_ref" => artifact.ref}]

    assert {:ok, %{"conversations" => [without_resources]}} =
             CapabilityTools.call(
               "list_slack_channels",
               %{"include_resources" => false},
               binding
             )

    refute Map.has_key?(without_resources, "resources")

    assert {:ok, searched} =
             CapabilityTools.call(
               "search_slack",
               %{"content_types" => ["files"], "query" => "local-runbook"},
               binding
             )

    assert [file] = searched["results"]["files"]
    assert file["file_id"] == artifact.ref
    assert file["source_ref"] == artifact.ref
    assert file["title"] == "local-runbook.md"
    assert file["media_type"] == "text/markdown"

    assert {:ok, read} =
             CapabilityTools.call(
               "read_slack_source",
               %{"source_ref" => artifact.ref, "view" => "document"},
               binding
             )

    assert read["complete"] == true

    assert read["document"] == %{
             "content" => "# Local runbook\nThe Lab file body is readable.",
             "content_complete" => true,
             "kind" => "file",
             "media_type" => "text/markdown",
             "size" => artifact.byte_size,
             "title" => "local-runbook.md"
           }

    assert read["emulated"] == true
    assert read["external_effects"] == false

    assert CapabilityTools.call(
             "read_slack_source",
             %{
               "source_ref" => "artifact:input:outside:#{String.duplicate("a", 64)}",
               "view" => "document"
             },
             binding
           ) == {:error, "unauthorized"}
  end

  test "bounded Lab source reads retain the newest conversation messages" do
    latest_ref =
      Enum.reduce(0..200, nil, fn index, _previous ->
        marker = if index == 200, do: " newest bounded marker", else: ""

        {ref, _episode, _source_item_ref} =
          admit_lab_input!(
            "bounded-history-#{index}",
            @conversation_ref,
            "Historical Lab message #{index}.#{marker}",
            DateTime.add(@now, index + 1, :microsecond)
          )

        ref
      end)

    {binding, _current_ref, _current_item_ref} = lab_binding!("bounded-current")

    assert {:ok, searched} =
             CapabilityTools.call(
               "search_slack",
               %{"query" => "newest bounded marker"},
               binding
             )

    assert [%{"source_ref" => ^latest_ref}] = searched["results"]["messages"]
  end

  test "Lab Slack-compatible reads expose only the current message revision" do
    {binding, original_ref, source_item_ref} = lab_binding!("message-lifecycle")
    episode = binding.episode
    item_id = String.replace_prefix(source_item_ref, "control-plane-item:", "")
    native_input_id = "control-plane-message:#{item_id}"

    edited_ref =
      admit_lab_revision!(
        episode,
        native_input_id,
        source_item_ref,
        :edit,
        2,
        "Corrected exact Slack parity wording.",
        DateTime.add(@now, 1, :second)
      )

    assert {:ok, searched} =
             CapabilityTools.call(
               "search_slack",
               %{"query" => "corrected exact"},
               binding
             )

    assert [%{"source_ref" => ^edited_ref}] = searched["results"]["messages"]

    assert {:ok, %{"results" => %{"messages" => []}}} =
             CapabilityTools.call(
               "search_slack",
               %{"query" => "Exercise exact Slack parity"},
               binding
             )

    _deleted_ref =
      admit_lab_revision!(
        episode,
        native_input_id,
        source_item_ref,
        :delete,
        3,
        "Corrected exact Slack parity wording.",
        DateTime.add(@now, 2, :second)
      )

    assert {:ok, %{"results" => %{"messages" => []}}} =
             CapabilityTools.call(
               "search_slack",
               %{"query" => "corrected exact"},
               binding
             )

    assert CapabilityTools.call(
             "read_slack_source",
             %{"source_ref" => original_ref, "view" => "surrounding"},
             binding
           ) == {:error, "unauthorized"}
  end

  test "Lab Slack-compatible tools reject malformed or stale calls without side effects" do
    {binding, input_ref, source_item_ref} = lab_binding!("invalid-calls")

    invalid_calls = [
      {"list_slack_channels", %{"unexpected" => true}},
      {"list_slack_channels", %{"kinds" => []}},
      {"list_slack_channels", %{"configured_only" => "yes"}},
      {"list_slack_channels", %{"limit" => 0}},
      {"search_slack", %{}},
      {"search_slack", %{"query" => nil}},
      {"search_slack", %{"content_types" => ["messages", "messages"], "query" => "x"}},
      {"search_slack", %{"after" => "not-a-time", "query" => "x"}},
      {"search_slack", %{"after" => 123, "query" => "x"}},
      {"read_slack_source", %{"source_ref" => input_ref, "view" => 123}},
      {"set_slack_reaction",
       %{"action" => "add", "emoji" => "EYES!", "message_ref" => input_ref}},
      {"set_slack_reaction", %{"action" => "add", "emoji" => "eyes", "message_ref" => 123}},
      {"post_slack_message",
       %{
         "destination_ref" => @conversation_ref,
         "instruction_ref" => input_ref,
         "message" => nil
       }}
    ]

    for {tool, arguments} <- invalid_calls do
      assert CapabilityTools.call(tool, arguments, binding) == {:error, "invalid_arguments"}
    end

    refute PlatformActionCustody.delivered_reaction_added?(
             binding.episode.id,
             @conversation_ref,
             source_item_ref,
             "eyes"
           )

    assert CapabilityTools.call(
             "set_slack_reaction",
             %{"action" => "remove", "emoji" => "eyes", "message_ref" => input_ref},
             binding
           ) == {:error, "unauthorized"}

    assert CapabilityTools.call("not_a_tool", %{}, binding) == {:error, "unknown_tool"}
    assert CapabilityTools.call(:not_a_tool, %{}, binding) == {:error, "invalid_arguments"}
    assert CapabilityTools.call("list_slack_channels", %{}, %{}) == {:error, "unauthorized"}

    invalid_ref = "control-plane:lab:not-a-uuid"

    invalid_uuid_binding =
      Map.put(
        binding,
        :episode,
        %{
          binding.episode
          | destination_conversation_ref: invalid_ref,
            destination_thread_ref: invalid_ref
        }
      )

    assert CapabilityTools.call("list_slack_channels", %{}, invalid_uuid_binding) ==
             {:error, "unauthorized"}

    assert CapabilityTools.call("list_slack_channels", %{}, %{binding | session: nil}) ==
             {:error, "temporarily_unavailable"}

    assert Repo.aggregate(PlatformAction, :count) == 0
    assert Repo.aggregate(Record, :count) == 0
  end

  defp lab_binding!(suffix) do
    {input_ref, episode, source_item_ref} =
      admit_lab_input!(
        suffix,
        @conversation_ref,
        "Exercise exact Slack parity in the local Lab."
      )

    assert {:ok, _session} =
             Custody.pin_episode(
               episode.id,
               "conversation-read",
               @policy_digest,
               "emisar"
             )

    assert {:ok, claim} = Custody.claim_next("lab-capabilities:#{suffix}", 60, :work)

    binding = %{
      episode: claim.episode,
      session: claim.session,
      state_token: Records.token(claim.turn),
      turn: claim.turn
    }

    {binding, input_ref, source_item_ref}
  end

  defp admit_lab_input!(suffix, conversation_ref, text, occurred_at \\ @now) do
    admit_lab_content!(suffix, conversation_ref, %{"text" => text}, occurred_at)
  end

  defp admit_lab_content!(suffix, conversation_ref, content, occurred_at \\ @now) do
    event_id = Ecto.UUID.generate()
    source_item_ref = "control-plane-item:#{event_id}"

    payload = %{
      "actor" => %{"kind" => "user", "ref" => "local-operator"},
      "content" => content,
      "destination" => %{
        "conversation_ref" => conversation_ref,
        "thread_ref" => conversation_ref,
        "transport" => "control_plane"
      },
      "event_kind" => "message",
      "event_ref" => "control-plane-event:#{event_id}",
      "native_input_id" => "control-plane-message:#{event_id}",
      "occurred_at" => DateTime.to_iso8601(occurred_at),
      "occurred_at_source" => "ingress",
      "revision" => 1,
      "source" => %{"kind" => "control_plane", "ref" => "local"},
      "source_capabilities" => %{
        "post_slack_message" => %{"destination_refs" => [conversation_ref]},
        "react" => %{"emoji_names" => nil}
      },
      "source_item_ref" => source_item_ref
    }

    command =
      EpisodeFixtures.admit_input(%{
        actor_ref: "local-operator",
        destination: %{
          conversation_ref: conversation_ref,
          thread_ref: conversation_ref,
          transport: "control_plane"
        },
        episode_id: Ecto.UUID.generate(),
        episode_key: "conversation-lab:#{suffix}:#{event_id}",
        native_input_id: "control-plane-message:#{event_id}",
        occurred_at: occurred_at,
        payload: payload,
        turn_ref: "turn:conversation-lab:#{suffix}:#{event_id}"
      })

    input_ref = Command.dedupe_key(command)
    assert {:ok, transition} = Episodes.apply(command)
    {input_ref, transition.episode, source_item_ref}
  end

  defp admit_lab_revision!(
         episode,
         native_input_id,
         source_item_ref,
         event_kind,
         revision,
         text,
         occurred_at
       ) do
    event_id = Ecto.UUID.generate()

    payload = %{
      "actor" => %{"kind" => "user", "ref" => "local-operator"},
      "content" => %{"text" => text},
      "destination" => %{
        "conversation_ref" => @conversation_ref,
        "thread_ref" => @conversation_ref,
        "transport" => "control_plane"
      },
      "event_kind" => Atom.to_string(event_kind),
      "event_ref" => "control-plane-event:#{event_id}",
      "native_input_id" => native_input_id,
      "occurred_at" => DateTime.to_iso8601(occurred_at),
      "occurred_at_source" => "ingress",
      "revision" => revision,
      "source" => %{"kind" => "control_plane", "ref" => "local"},
      "source_capabilities" =>
        if(event_kind == :delete,
          do: %{},
          else: %{
            "post_slack_message" => %{"destination_refs" => [@conversation_ref]},
            "react" => %{"emoji_names" => nil}
          }
        ),
      "source_item_ref" => source_item_ref
    }

    command =
      EpisodeFixtures.admit_input(%{
        actor_ref: "local-operator",
        destination: %{
          conversation_ref: @conversation_ref,
          thread_ref: @conversation_ref,
          transport: "control_plane"
        },
        episode_id: episode.id,
        episode_key: episode.key,
        native_input_id: native_input_id,
        occurred_at: occurred_at,
        payload: payload,
        revision: revision,
        turn_ref: episode.owner_ref
      })

    input_ref = Command.dedupe_key(command)
    assert {:ok, _transition} = Episodes.apply(command)
    input_ref
  end
end
