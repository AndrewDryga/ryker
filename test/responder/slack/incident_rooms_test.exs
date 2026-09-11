defmodule Responder.Slack.IncidentRoomsTest do
  use Responder.DataCase, async: false

  import Ecto.Query

  alias Responder.ControlPlane.InstructionSettings
  alias Responder.Delivery.JSONClient
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.{Inbox, Input}
  alias Responder.Repo

  alias Responder.Slack.{
    ChannelConfigurationChangeset,
    Client,
    IncidentRoom,
    IncidentRoomCard,
    IncidentRoomLifecycleEvent,
    IncidentRooms,
    IncidentRoomWorker,
    MembershipTransition,
    Runtime,
    WorkRecord,
    WorkTarget
  }

  alias Responder.State.{KnowledgeSnapshot, Record, Records}
  alias Responder.Work.{Custody, DeliveryReceipt, Result, Session, SubmissionBuilder, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]
  @policy_digest String.duplicate("b", 64)

  defmodule API do
    def ensure_conversation(agent, "T123", name, private, creator_ref, requested_at) do
      Agent.get_and_update(agent, fn state ->
        case Map.get(state, :ensure_error) do
          nil ->
            channel_ref = state.channel_ref || "CINCIDENT"

            {{:ok, channel_ref},
             %{
               state
               | channel_ref: channel_ref,
                 conversations:
                   state.conversations ++ [{name, private, creator_ref, requested_at}]
             }}

          reason ->
            {{:error, reason}, state}
        end
      end)
    end

    def find_message(agent, channel_ref, thread_ref, delivery_ref) do
      Agent.get(agent, &message_result(&1, channel_ref, thread_ref, delivery_ref))
    end

    defp message_result(state, channel_ref, thread_ref, delivery_ref) do
      error = get_in(state, [:find_errors, delivery_ref])
      message_ref = Map.get(state.messages, {channel_ref, thread_ref, delivery_ref})
      message_result(error, message_ref)
    end

    defp message_result(reason, _message_ref) when not is_nil(reason), do: {:error, reason}
    defp message_result(nil, nil), do: :not_found
    defp message_result(nil, message_ref), do: {:ok, message_ref}

    def post_message(agent, channel_ref, thread_ref, document, delivery_ref) do
      Agent.get_and_update(agent, fn state ->
        case get_in(state, [:post_errors, delivery_ref]) do
          nil ->
            key = {channel_ref, thread_ref, delivery_ref}
            message_ref = Map.get(state.messages, key, "1787832001.000200")

            {{:ok, message_ref},
             %{
               state
               | messages: Map.put(state.messages, key, message_ref),
                 posts: state.posts ++ [{channel_ref, thread_ref, document, delivery_ref}]
             }}

          reason ->
            {{:error, reason}, state}
        end
      end)
    end

    def update_message(agent, channel_ref, message_ref, document, delivery_ref) do
      Agent.get_and_update(agent, fn state ->
        case Map.get(state, :update_error) do
          nil ->
            update = {channel_ref, message_ref, document, delivery_ref}
            {:ok, Map.update(state, :updates, [update], &(&1 ++ [update]))}

          reason ->
            {{:error, reason}, state}
        end
      end)
    end

    def invite_users(agent, channel_ref, users) do
      Agent.get_and_update(agent, fn state ->
        case Map.get(state, :invite_error) do
          nil -> {:ok, %{state | invites: state.invites ++ [{channel_ref, users}]}}
          reason -> {{:error, reason}, state}
        end
      end)
    end

    def set_topic(agent, channel_ref, topic) do
      Agent.get_and_update(agent, fn state ->
        case Map.get(state, :topic_error) do
          nil -> {:ok, %{state | topics: state.topics ++ [{channel_ref, topic}]}}
          reason -> {{:error, reason}, state}
        end
      end)
    end

    def pin_message(agent, channel_ref, message_ref) do
      Agent.get_and_update(agent, fn state ->
        case Map.get(state, :pin_error) do
          nil -> {:ok, %{state | pins: state.pins ++ [{channel_ref, message_ref}]}}
          reason -> {{:error, reason}, state}
        end
      end)
    end

    def conversation_state(agent, _channel_ref) do
      Agent.get(agent, fn state ->
        case Map.get(state, :conversation_state, :active) do
          :not_found -> :not_found
          {:error, reason} -> {:error, reason}
          value when value in [:active, :archived] -> {:ok, value}
        end
      end)
    end
  end

  defmodule Directory do
    def user_allowed(agent, user_ref, "T123") do
      Agent.get(agent, &{:ok, MapSet.member?(&1.allowed_users, user_ref)})
    end

    def user_group_members(agent, group_ref, "T123") do
      Agent.get(agent, &{:ok, Map.fetch!(&1.groups, group_ref)})
    end
  end

  test "incident offer Work carries source receipts that a source deletion revokes" do
    # Incident behavior tests must pass through the same raw-input custody as
    # production; a handcrafted source-looking prompt bypasses that boundary.
    fixture = delivered_offer!()
    assert [receipt] = KnowledgeSnapshot.session_sources(fixture.session.id)
    assert receipt["source_input_id"] == fixture.input_entry.id
    assert :ok = KnowledgeSnapshot.authorize_session(fixture.episode, fixture.session)

    deleted = %{
      fixture.input
      | event_ref: fixture.input.event_ref <> ":deleted",
        event_kind: :delete,
        revision: fixture.input.revision + 1
    }

    assert {:ok, _} = Inbox.record(deleted)

    assert {:error, :work_knowledge_context_stale} =
             KnowledgeSnapshot.authorize_session(fixture.episode, fixture.session)
  end

  # One offer owns both paths. Before 2026-09-11 an incident offer had only
  # "Open incident room"; the in-place path did not exist, and nothing stopped a
  # room request and a thread investigation from both starting on one offer.
  test "one incident offer starts exactly one path: investigate in the thread or create a room" do
    fixture = delivered_offer!()
    other = delivered_offer!()
    save_channel_configuration!()

    assert {:ok, investigation} = IncidentRooms.investigate(investigate(fixture))
    assert investigation.status == :confirmed
    assert investigation.episode.destination_conversation_ref == "slack:T123:C456"
    assert investigation.episode.destination_thread_ref == "1787832000.000100"
    assert investigation.session.policy == "incident-investigate"
    assert investigation.session.repository_ref == nil

    record = Repo.get!(Record, fixture.record.id)
    assert record.status == :confirmed
    assert record.confirmed_episode_id == investigation.episode.id
    refute Repo.get_by(IncidentRoom, record_id: record.id)

    assert IncidentRooms.request(request(fixture)) == {:error, :incident_offer_stale}
    refute Repo.get_by(IncidentRoom, record_id: record.id)

    assert {:ok, duplicate} = IncidentRooms.investigate(investigate(fixture))
    assert duplicate.status == :duplicate
    assert duplicate.episode.id == investigation.episode.id

    assert {:ok, requested} = IncidentRooms.request(request(other))
    assert requested.status == :requested

    assert IncidentRooms.investigate(investigate(other)) == {:error, :incident_offer_stale}
    assert Repo.get!(Record, other.record.id).confirmed_episode_id == nil

    assert IncidentRooms.investigate(%{
             investigate(fixture)
             | record_ref: "record:task_offer:missing"
           }) ==
             {:error, :incident_offer_not_found}

    assert IncidentRooms.investigate(%{investigate(fixture) | workspace_ref: "T999"}) ==
             {:error, :incident_offer_workspace_mismatch}

    assert IncidentRooms.investigate(Map.delete(investigate(fixture), :policy)) ==
             {:error, {:invalid_incident_investigation, :fields}}
  end

  test "a delivered incident offer provisions one usable room before starting linked work" do
    fixture = delivered_offer!()
    save_channel_configuration!()

    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             allowed_users: MapSet.new(["U123", "U200", "U201", "U300"]),
             channel_ref: nil,
             conversations: [],
             groups: %{"SRE" => ["U201", "U200"]},
             invites: [],
             messages: %{},
             pins: [],
             posts: [],
             topics: []
           }
         end}
      )

    assert {:ok, requested} = IncidentRooms.request(request(fixture))
    assert requested.status == :requested
    assert requested.room.channel_ref == nil
    assert requested.room.channel_name =~ ~r/^ems-0828-checkout-errors-/

    observer = self()

    options =
      worker_options(agent)
      |> Map.put(:reserve_channel, fn workspace_ref, channel_ref ->
        send(observer, {:reserved_managed_channel, workspace_ref, channel_ref})
        :ok
      end)

    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(options)
    assert_received {:reserved_managed_channel, "T123", "CINCIDENT"}
    assert room_ref == requested.room.ref

    room = Repo.get_by!(IncidentRoom, ref: room_ref)
    assert room.status == :ready
    assert room.channel_ref == "CINCIDENT"
    assert room.root_message_ref == "1787832001.000200"
    assert room.root_card_fingerprint =~ ~r/\A[0-9a-f]{64}\z/
    assert room.root_card_ui_revision == 2
    assert room.episode_id
    assert room.audience_prepared_at
    assert room.topic_prepared_at
    assert room.root_pinned_at
    assert room.handoff_message_ref == "1787832001.000200"

    episode = Repo.get!(Responder.Episodes.Episode, room.episode_id)
    assert episode.linked_episode_id == fixture.episode.id
    assert episode.destination_transport == "slack"
    assert episode.destination_conversation_ref == "slack:T123:CINCIDENT"
    assert episode.destination_thread_ref == room.root_message_ref

    assert %Session{
             policy: "incident-investigate",
             policy_digest: @policy_digest,
             repository_ref: "responder"
           } = Repo.get_by!(Session, episode_id: episode.id)

    room_target = %{
      conversation_ref: "slack:T123:CINCIDENT",
      message_ref: room.root_message_ref,
      thread_ref: room.root_message_ref,
      transport: "slack"
    }

    assert {:ok, %{kind: :incident, work_ref: ^room_ref}} =
             WorkTarget.resolve(room_ref, room_target)

    assert {:ok, %{kind: :incident, work_ref: ^room_ref}} =
             WorkTarget.resolve_thread(
               room_ref,
               %{room_target | message_ref: "1787832001.000201"}
             )

    assert %Record{
             status: :confirmed,
             confirmed_episode_id: confirmed_episode_id,
             confirmation_ref: "interaction:incident"
           } = Repo.get!(Record, fixture.record.id)

    assert confirmed_episode_id == episode.id

    state = Agent.get(agent, & &1)

    assert [{name, true, "U-BOT", requested_at}] = state.conversations
    assert name == room.channel_name
    assert requested_at == DateTime.add(@now, 2, :second)
    assert state.invites == [{"CINCIDENT", ["U123", "U200", "U201", "U300"]}]
    assert [{"CINCIDENT", topic}] = state.topics

    assert topic =~
             "Incident #{room.ref |> String.replace_prefix("incident-room:", "") |> String.slice(0, 8)}"

    assert state.pins == [{"CINCIDENT", room.root_message_ref}]

    assert [
             {"CINCIDENT", nil, %{"incident_room" => root}, root_delivery_ref},
             {"C456", "1787832000.000100", %{"message" => handoff}, handoff_delivery_ref}
           ] = state.posts

    assert root["room_ref"] == room.ref
    assert root["status"] == "provisioning"
    assert root["repository"] == "responder"
    assert root_delivery_ref == "#{room.ref}:root"
    assert handoff =~ "<#CINCIDENT>"
    assert handoff_delivery_ref == "incident-room:#{room.ref}:handoff"

    assert {:ok, duplicate} =
             fixture
             |> request()
             |> Map.put(:confirmation_ref, "interaction:incident:retry")
             |> IncidentRooms.request()

    assert duplicate.status == :duplicate
    assert duplicate.room.id == room.id
    assert {:ok, {:ready, ^room_ref}} = IncidentRoomWorker.run_once(options)
    assert Agent.get(agent, &length(&1.posts)) == 2

    assert [
             {"CINCIDENT", "1787832001.000200", %{"incident_room" => updated_root},
              ^root_delivery_ref}
           ] = Agent.get(agent, &Map.get(&1, :updates, []))

    assert updated_root["status"] == "investigating"
    assert updated_root["episode_state"] == "working"
    assert updated_root["session_generation"] == 1

    assert updated_root["controls"] == [
             "close",
             "timeline",
             "evidence",
             "handoff",
             "postmortem"
           ]

    assert {:ok, claim} = Custody.claim_next("incident-card-work", 60, :work)
    assert claim.episode.id == room.episode_id

    # An incident moves work from its source channel into the bound incident room.
    assert {:ok, _} =
             Responder.Instructions.save(:global, "Global incident default", 0, "operator:test")

    assert {:ok, _} =
             Responder.Instructions.save(
               {:channel, "T123", "C456"},
               "Source channel only",
               0,
               "operator:test"
             )

    assert {:ok, _} =
             Responder.Instructions.save(
               {:channel, "T123", "CINCIDENT"},
               "Incident room default",
               0,
               "operator:test"
             )

    assert {:ok, submission} = SubmissionBuilder.build(claim)
    instructions = submission["context"]["custom_instructions"]
    assert instructions["global"]["text"] == "Global incident default"
    assert instructions["channel"]["text"] == "Incident room default"
    refute inspect(instructions) =~ "Source channel only"

    assert {:ok, %{setting: %{text: "Incident room default"}}} =
             InstructionSettings.fetch({:channel, "T123", "CINCIDENT"})

    assert {:ok, _progress} =
             Records.create(Records.token(claim.turn), "incident-progress", "progress", %{
               "next_due_at" => nil,
               "phase" => "verifying",
               "summary" => "Checkout traffic recovered; worker queues are still being verified."
             })

    refreshed = Repo.get!(IncidentRoom, room.id)

    Repo.update_all(
      from(candidate in IncidentRoom, where: candidate.id == ^room.id),
      set: [root_card_checked_at: DateTime.add(refreshed.root_card_checked_at, -10, :second)]
    )

    Agent.update(agent, &Map.put(&1, :updates, []))
    options = Map.put(options, :root_card_check_seconds, 1)
    assert {:ok, {:ready, ^room_ref}} = IncidentRoomWorker.run_once(options)

    assert [
             {"CINCIDENT", "1787832001.000200", %{"incident_room" => progress_root},
              ^root_delivery_ref}
           ] = Agent.get(agent, & &1.updates)

    assert progress_root["summary"] ==
             "Checkout traffic recovered; worker queues are still being verified."

    record_target = %{
      conversation_ref: "slack:T123:CINCIDENT",
      message_ref: room.root_message_ref,
      thread_ref: room.root_message_ref,
      transport: "slack"
    }

    assert {:ok, handoff} = WorkRecord.build(room.ref, record_target, :handoff)
    assert handoff["message"] =~ "Latest progress: verifying"
    assert handoff["message"] =~ "Publication: none recorded"

    assert {:ok, postmortem} = WorkRecord.build(room.ref, record_target, :postmortem)
    assert postmortem["message"] =~ "human review is required"
    assert postmortem["message"] =~ "Unknown — no alert impact assessment"
    assert postmortem["message"] =~ "Unknown — no evidence-backed root cause"
  end

  test "an invalid configured audience blocks before creating a Slack room" do
    fixture = delivered_offer!()
    save_channel_configuration!()

    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             allowed_users: MapSet.new(["U123", "U300"]),
             channel_ref: nil,
             conversations: [],
             groups: %{"SRE" => ["U201", "U200"]},
             invites: [],
             messages: %{},
             pins: [],
             posts: [],
             topics: []
           }
         end}
      )

    assert {:ok, requested} = IncidentRooms.request(request(fixture))

    assert {:ok, {:blocked, room_ref, :incident_audience_member_invalid}} =
             IncidentRoomWorker.run_once(worker_options(agent))

    assert room_ref == requested.room.ref
    assert Repo.get!(IncidentRoom, requested.room.id).status == :blocked
    assert Agent.get(agent, & &1.conversations) == []
    assert Repo.get!(Record, fixture.record.id).status == :open

    assert {:ok, rearmed} = IncidentRooms.rearm(room_ref)
    assert rearmed.status == :requested
    assert rearmed.attempt_count == 0
    assert rearmed.last_error_code == nil
    assert rearmed.lease_ref == nil
    assert {:error, :incident_room_not_blocked} = IncidentRooms.rearm(room_ref)
  end

  test "archive and unarchive events durably pause and resume only the managed incident" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()

    assert {:ok, requested} = IncidentRooms.request(request(fixture))
    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    room = Repo.get_by!(IncidentRoom, ref: room_ref)
    archived_at = DateTime.add(room.channel_state_changed_at, 1, :second)
    archived = lifecycle(room, :archived, "Ev-incident-archived", archived_at)

    assert {:ok, archived_result} = IncidentRooms.observe_lifecycle(archived)
    assert archived_result.status == :applied
    assert archived_result.room.channel_state == :archived
    assert archived_result.room.reconciled_channel_state == :active

    assert {:ok, duplicate} = IncidentRooms.observe_lifecycle(archived)
    assert duplicate.status == :duplicate
    assert Repo.aggregate(IncidentRoomLifecycleEvent, :count) == 1

    assert {:ok, {:ready, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    paused_room = Repo.get!(IncidentRoom, requested.room.id)
    assert paused_room.channel_state == :archived
    assert paused_room.reconciled_channel_state == :archived

    episode = Repo.get!(Responder.Episodes.Episode, room.episode_id)
    paused_turn = Repo.get_by!(Turn, episode_id: episode.id, turn_ref: episode.owner_ref)
    assert paused_turn.status == :blocked
    assert paused_turn.cancellation_intent["reason"] == "destination_paused:#{room.ref}:channel"
    assert Custody.claim_next("work:archived-room", 60, :work) == {:ok, nil}

    stale = lifecycle(room, :joined, "Ev-incident-stale", room.channel_state_changed_at)
    assert {:ok, %{status: :stale}} = IncidentRooms.observe_lifecycle(stale)
    assert Repo.get!(IncidentRoom, room.id).channel_state == :archived

    unarchived =
      lifecycle(
        room,
        :unarchived,
        "Ev-incident-unarchived",
        DateTime.add(archived_at, 1, :second)
      )

    assert {:ok, %{status: :applied, room: active}} =
             IncidentRooms.observe_lifecycle(unarchived)

    assert active.channel_state == :active
    assert {:ok, {:ready, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    resumed_room = Repo.get!(IncidentRoom, room.id)
    assert resumed_room.reconciled_channel_state == :active

    resumed_episode = Repo.get!(Responder.Episodes.Episode, room.episode_id)
    assert resumed_episode.owner_ref != episode.owner_ref

    assert {:ok, claim} = Custody.claim_next("work:unarchived-room", 60, :work)
    assert claim.episode.id == room.episode_id
    assert claim.turn.turn_ref == resumed_episode.owner_ref
  end

  test "a periodic channel check repairs a missed archive and treats not-found as unavailable" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()

    assert {:ok, _requested} = IncidentRooms.request(request(fixture))
    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get_by!(IncidentRoom, ref: room_ref)

    Repo.update_all(
      from(candidate in IncidentRoom, where: candidate.id == ^room.id),
      set: [channel_checked_at: DateTime.add(room.channel_checked_at, -10, :second)]
    )

    Agent.update(agent, &Map.put(&1, :conversation_state, :archived))
    options = Map.put(worker_options(agent), :health_check_seconds, 1)

    assert {:ok, {:ready, ^room_ref}} = IncidentRoomWorker.run_once(options)
    archived = Repo.get!(IncidentRoom, room.id)
    assert archived.channel_state == :archived
    assert archived.reconciled_channel_state == :archived

    assert %IncidentRoomLifecycleEvent{kind: :observed_archived} =
             Repo.one!(
               from(event in IncidentRoomLifecycleEvent,
                 where: event.room_id == ^room.id and event.kind == :observed_archived
               )
             )

    Repo.update_all(
      from(candidate in IncidentRoom, where: candidate.id == ^room.id),
      set: [channel_checked_at: DateTime.add(archived.channel_checked_at, -10, :second)]
    )

    Agent.update(agent, &Map.put(&1, :conversation_state, :not_found))
    assert {:ok, {:ready, ^room_ref}} = IncidentRoomWorker.run_once(options)

    unavailable = Repo.get!(IncidentRoom, room.id)
    assert unavailable.channel_state == :unavailable
    assert unavailable.reconciled_channel_state == :unavailable
    refute unavailable.channel_state == :deleted
  end

  test "the trusted Slack runtime makes an active room conversational and keeps its frozen authority" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()

    assert {:ok, _requested} = IncidentRooms.request(request(fixture))
    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get_by!(IncidentRoom, ref: room_ref)

    configuration = runtime_configuration!()
    settings = Runtime.options!(configuration).handler_settings
    conversation_ref = "slack:T123:#{room.channel_ref}"

    assert settings.effective_settings.("T123", conversation_ref) == %{
             proactive: %{source: :incident_room, value: true},
             shadow: %{source: :incident_room, value: false}
           }

    assert settings.work_profile.("T123", conversation_ref) ==
             {:ok,
              %{
                policy: "incident-investigate",
                policy_digest: @policy_digest,
                repository_ref: "responder"
              }}

    operator_input = %{
      actor: %{kind: :user, ref: "U123"},
      destination: %{conversation_ref: conversation_ref},
      source: %{ref: "T123"}
    }

    assert settings.conversation_actor_allowed.(operator_input) == {:ok, true}
    assert settings.setup_allowed.("T123", conversation_ref) == {:ok, false}

    teammate_input = put_in(operator_input, [:actor, :ref], "U200")
    app_input = %{operator_input | actor: %{kind: :app, ref: "A123"}}
    assert settings.conversation_actor_allowed.(teammate_input) == {:ok, false}
    assert settings.conversation_actor_allowed.(app_input) == {:ok, false}

    adapter = Runtime.delivery_adapter!(configuration)
    assert adapter.binding.destination_allowed.("T123", room.channel_ref) == :ok

    assert {:ok, %{status: :applied}} =
             IncidentRooms.observe_lifecycle(
               lifecycle(
                 room,
                 :archived,
                 "Ev-runtime-archived",
                 DateTime.add(room.channel_state_changed_at, 1, :second)
               )
             )

    assert settings.effective_settings.("T123", conversation_ref).proactive.value == false
    assert settings.conversation_actor_allowed.(operator_input) == {:ok, false}

    assert adapter.binding.destination_allowed.("T123", room.channel_ref) ==
             {:error, {:slack_incident_room_inactive, :archived}}
  end

  test "automatic alert policy opens only a delivered external-app incident offer" do
    _human_offer = delivered_offer!(:user)
    save_channel_configuration!(:automatic)
    agent = incident_agent!()

    automatic_request = fn ->
      case IncidentRooms.automatic_candidate("T123") do
        {:ok, nil} -> {:ok, nil}
        {:ok, candidate} -> IncidentRooms.request(automatic_request(candidate))
        {:error, _reason} = error -> error
      end
    end

    options = Map.put(worker_options(agent), :automatic_request, automatic_request)
    assert {:ok, :idle} = IncidentRoomWorker.run_once(options)
    assert Repo.aggregate(IncidentRoom, :count) == 0

    app_offer = delivered_offer!(:app)

    assert {:ok, {:requested, room_ref}} = IncidentRoomWorker.run_once(options)
    requested = Repo.get_by!(IncidentRoom, ref: room_ref)
    assert requested.record_id == app_offer.record.id
    assert requested.requested_by_actor_ref == "slack:app:A123"
    assert requested.confirmation_ref == "automatic-alert:#{app_offer.record.ref}"

    assert {:ok, {:ready, ^room_ref}} = IncidentRoomWorker.run_once(options)
    assert Repo.get_by!(IncidentRoom, ref: room_ref).status == :ready
  end

  test "transient Slack failures resume each exact provisioning phase without duplicating the room" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()
    assert {:ok, requested} = IncidentRooms.request(request(fixture))

    options = %{worker_options(agent) | max_attempts: 20}
    root_ref = "#{requested.room.ref}:root"
    handoff_ref = "incident-room:#{requested.room.ref}:handoff"

    Agent.update(agent, &Map.put(&1, :ensure_error, :conversation_offline))
    assert {:ok, {:deferred, room_ref}} = IncidentRoomWorker.run_once(options)
    assert room_ref == requested.room.ref

    make_room_retryable!(requested.room.id)

    Agent.update(agent, fn state ->
      state |> Map.delete(:ensure_error) |> Map.put(:find_errors, %{root_ref => :history_offline})
    end)

    assert {:ok, {:deferred, ^room_ref}} = IncidentRoomWorker.run_once(options)
    assert Repo.get!(IncidentRoom, requested.room.id).channel_ref == "CINCIDENT"

    make_room_retryable!(requested.room.id)

    Agent.update(agent, fn state ->
      state
      |> Map.put(:find_errors, %{})
      |> Map.put(:post_errors, %{root_ref => :post_offline})
    end)

    assert {:ok, {:deferred, ^room_ref}} = IncidentRoomWorker.run_once(options)

    make_room_retryable!(requested.room.id)

    Agent.update(agent, fn state ->
      state |> Map.put(:post_errors, %{}) |> Map.put(:invite_error, :invite_offline)
    end)

    assert {:ok, {:deferred, ^room_ref}} = IncidentRoomWorker.run_once(options)
    assert Repo.get!(IncidentRoom, requested.room.id).root_message_ref

    make_room_retryable!(requested.room.id)

    Agent.update(agent, fn state ->
      state |> Map.delete(:invite_error) |> Map.put(:topic_error, :topic_offline)
    end)

    assert {:ok, {:deferred, ^room_ref}} = IncidentRoomWorker.run_once(options)

    make_room_retryable!(requested.room.id)

    Agent.update(agent, fn state ->
      state |> Map.delete(:topic_error) |> Map.put(:pin_error, :pin_offline)
    end)

    assert {:ok, {:deferred, ^room_ref}} = IncidentRoomWorker.run_once(options)

    make_room_retryable!(requested.room.id)

    Agent.update(agent, fn state ->
      state
      |> Map.delete(:pin_error)
      |> Map.put(:find_errors, %{handoff_ref => :handoff_history_offline})
    end)

    assert {:ok, {:deferred, ^room_ref}} = IncidentRoomWorker.run_once(options)

    make_room_retryable!(requested.room.id)

    Agent.update(agent, fn state ->
      state
      |> Map.put(:find_errors, %{})
      |> Map.put(:post_errors, %{handoff_ref => :handoff_post_offline})
    end)

    assert {:ok, {:deferred, ^room_ref}} = IncidentRoomWorker.run_once(options)

    make_room_retryable!(requested.room.id)
    Agent.update(agent, &Map.put(&1, :post_errors, %{}))
    assert {:ok, {:ready, ^room_ref}} = IncidentRoomWorker.run_once(options)

    room = Repo.get!(IncidentRoom, requested.room.id)
    assert room.status == :ready
    assert length(Agent.get(agent, & &1.conversations)) == 1
    assert length(Agent.get(agent, & &1.posts)) == 2
  end

  test "incident-room public boundaries reject malformed authority and unknown custody" do
    assert {:error, _reason} = IncidentRooms.request(%{})

    invalid_private = %{
      actor_ref: "slack:user:U123",
      bot_user_ref: "U-BOT",
      channel_prefix: "ems",
      confirmation_ref: "interaction:invalid",
      invite_user_refs: [],
      maximum_open_rooms: 25,
      occurred_at: @now,
      policy: %{digest: @policy_digest, name: "incident-investigate"},
      private: :yes,
      record_ref: "record:missing",
      target: %{
        conversation_ref: "slack:T123:C456",
        message_ref: "1.000001",
        thread_ref: nil,
        transport: "slack"
      },
      workspace_ref: "T123"
    }

    assert IncidentRooms.request(invalid_private) ==
             {:error, {:invalid_incident_room_request, :private}}

    assert IncidentRooms.observe_lifecycle(%{}) ==
             {:error, {:invalid_incident_room_lifecycle, :transition}}

    refute IncidentRooms.managed_channel?("T123", "CUNKNOWN")
    assert IncidentRooms.channel_profile("T123", "CUNKNOWN") == :not_found
    assert IncidentRooms.delivery_allowed("T123", "CUNKNOWN") == :ok
    assert {:error, _reason} = IncidentRooms.automatic_candidate("")
    assert {:error, _reason} = IncidentRooms.claim_next("", 0)
    assert {:error, _reason} = IncidentRooms.claim_health_check("", 0, 0)
    assert {:error, _reason} = IncidentRooms.claim_root_card("", 0, 0)
    assert {:error, _reason} = IncidentRooms.bind_root("room", "lease", "", "digest", 0)
    assert {:error, _reason} = IncidentRooms.mark_root_card("room", "lease", "digest", 0)
    assert {:error, _reason} = IncidentRooms.renew("room", "lease", 0)

    assert IncidentRooms.finalize(Ecto.UUID.generate(), Ecto.UUID.generate()) ==
             {:error, :incident_room_not_found}
  end

  test "provisioning identifiers are idempotent and conflicting Slack resources never rebind a room" do
    fixture = delivered_offer!()
    save_channel_configuration!()

    assert {:ok, %{room: requested}} = IncidentRooms.request(request(fixture))
    assert {:ok, claimed} = IncidentRooms.claim_next("incident-contract-worker", 60)
    assert claimed.id == requested.id

    assert {:ok, channel} =
             IncidentRooms.bind_channel(claimed.id, claimed.lease_ref, "CINCIDENT")

    assert {:ok, exact_channel_retry} =
             IncidentRooms.bind_channel(claimed.id, claimed.lease_ref, "CINCIDENT")

    assert exact_channel_retry.channel_ref == channel.channel_ref

    assert IncidentRooms.bind_channel(claimed.id, claimed.lease_ref, "COTHER") ==
             {:error, :incident_room_channel_conflict}

    fingerprint = String.duplicate("a", 64)

    assert {:ok, root} =
             IncidentRooms.bind_root(claimed.id, claimed.lease_ref, "1.000001", fingerprint, 1)

    assert {:ok, exact_root_retry} =
             IncidentRooms.bind_root(claimed.id, claimed.lease_ref, "1.000001", fingerprint, 1)

    assert exact_root_retry.root_message_ref == root.root_message_ref

    assert IncidentRooms.bind_root(
             claimed.id,
             claimed.lease_ref,
             "1.000002",
             fingerprint,
             1
           ) == {:error, :incident_room_root_conflict}

    assert {:ok, handoff} =
             IncidentRooms.bind_handoff(claimed.id, claimed.lease_ref, "1.000003")

    assert {:ok, exact_handoff_retry} =
             IncidentRooms.bind_handoff(claimed.id, claimed.lease_ref, "1.000003")

    assert exact_handoff_retry.handoff_message_ref == handoff.handoff_message_ref

    assert IncidentRooms.bind_handoff(claimed.id, claimed.lease_ref, "1.000004") ==
             {:error, :incident_room_handoff_conflict}

    for kind <- [:audience, :topic, :root_pin] do
      assert {:ok, prepared} = IncidentRooms.mark_prepared(claimed.id, claimed.lease_ref, kind)
      assert {:ok, ^prepared} = IncidentRooms.mark_prepared(claimed.id, claimed.lease_ref, kind)
    end

    assert {:ok, renewed} = IncidentRooms.renew(claimed.id, claimed.lease_ref, 120)
    assert DateTime.compare(renewed.lease_expires_at, claimed.lease_expires_at) == :gt
  end

  test "incident-room requests reject every malformed authority field before touching an offer" do
    base = %{
      actor_ref: "slack:user:U123",
      bot_user_ref: "U-BOT",
      channel_prefix: "ems",
      confirmation_ref: "interaction:boundary",
      invite_user_refs: ["U123"],
      maximum_open_rooms: 25,
      occurred_at: @now,
      policy: %{digest: @policy_digest, name: "incident-investigate"},
      private: true,
      record_ref: "record:missing",
      target: %{
        conversation_ref: "slack:T123:C456",
        message_ref: "1.000001",
        thread_ref: nil,
        transport: "slack"
      },
      workspace_ref: "T123"
    }

    assert IncidentRooms.request(base) == {:error, :incident_offer_not_found}

    invalid = [
      {:fields, Map.put(base, :unexpected, true)},
      {:policy, %{base | policy: :invalid}},
      {:policy_digest, put_in(base, [:policy, :digest], "bad")},
      {:policy, put_in(base, [:policy, :name], "")},
      {:transport, put_in(base, [:target, :transport], "github")},
      {:target, %{base | target: :invalid}},
      {:conversation_ref, put_in(base, [:target, :conversation_ref], "slack:T999:C456")},
      {:invite_user_refs, %{base | invite_user_refs: :invalid}},
      {:invite_user_refs, %{base | invite_user_refs: ["U1", "U1"]}},
      {:maximum_open_rooms, %{base | maximum_open_rooms: 0}},
      {:occurred_at, %{base | occurred_at: "now"}},
      {:workspace_ref,
       base |> Map.put(:workspace_ref, "") |> put_in([:target, :conversation_ref], "slack::C456")},
      {:channel_prefix, %{base | channel_prefix: String.duplicate("x", 65)}}
    ]

    for {field, attributes} <- invalid do
      assert {:error, reason} = IncidentRooms.request(attributes)
      assert inspect(reason) =~ Atom.to_string(field)
    end

    duplicate_keyword = Map.to_list(base) ++ [actor_ref: "slack:user:other"]
    assert {:error, _reason} = IncidentRooms.request(duplicate_keyword)
    assert {:error, _reason} = IncidentRooms.request(actor_ref: "only-one-field")
  end

  test "all Slack membership lifecycle variants update only a managed room" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()

    assert {:ok, _requested} = IncidentRooms.request(request(fixture))
    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get_by!(IncidentRoom, ref: room_ref)
    timestamp = DateTime.add(room.channel_state_changed_at, 1, :second)

    assert {:ok, %{status: :applied, room: left}} =
             IncidentRooms.observe_lifecycle(lifecycle(room, :left, "event:left", timestamp))

    assert left.channel_state == :unavailable

    assert {:ok, %{status: :applied, room: joined}} =
             IncidentRooms.observe_lifecycle(
               lifecycle(room, :joined, "event:joined", DateTime.add(timestamp, 1, :second))
             )

    assert joined.channel_state == :active

    same_time = DateTime.add(timestamp, 2, :second)

    assert {:ok, %{status: :applied, room: archived}} =
             IncidentRooms.observe_lifecycle(lifecycle(room, :archived, "event:a", same_time))

    assert {:ok, %{status: :applied, room: unarchived}} =
             IncidentRooms.observe_lifecycle(
               lifecycle(archived, :unarchived, "event:z", same_time)
             )

    assert unarchived.channel_state == :active

    assert {:ok, %{status: :applied, room: deleted}} =
             IncidentRooms.observe_lifecycle(
               lifecycle(room, :deleted, "event:deleted", DateTime.add(same_time, 1, :second))
             )

    assert deleted.channel_state == :deleted

    unknown = %MembershipTransition{
      actor_ref: "U123",
      channel_ref: "CUNKNOWN",
      event_ref: "event:unknown-room",
      kind: :joined,
      occurred_at: @now,
      workspace_ref: "T123"
    }

    assert {:ok, %{room: nil, status: :not_incident_room}} =
             IncidentRooms.observe_lifecycle(unknown)
  end

  test "incident cards expose alert evidence, operator questions, event waits, and terminal state" do
    save_channel_configuration!()
    input_wait = ready_room!("card-input-wait")
    assert {:ok, claim} = Custody.claim_next("incident-card:input", 60, :work)

    assert {:ok, alert} =
             Records.create(Records.token(claim.turn), "alert", "alert_assessment", %{
               "immediate_action" => "Inspect checkout and payment telemetry.",
               "impact" => "Checkout failures affect every production payment.",
               "verdict" => "unverified"
             })

    assert {:ok, question} =
             Records.create(Records.token(claim.turn), "question", "input_request", %{
               "choices" => ["rollback", "continue"],
               "question" => "Should we roll back the checkout deployment?"
             })

    assert {:ok, _waiting} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 episode_key: input_wait.episode.key,
                 expected_turn_ref: input_wait.episode.owner_ref,
                 occurred_at: DateTime.add(@now, 5, :second),
                 wait_ref: question.ref
               })
             )

    assert {:ok, projection} = IncidentRoomCard.build(input_wait.room)
    card = projection.document["incident_room"]
    assert card["status"] == "waiting_for_input"
    assert card["action_needed"] =~ "roll back"

    assert card["alert"] == %{
             "impact" => alert.payload["impact"],
             "verdict" => "unverified"
           }

    assert card["summary"] == alert.payload["impact"]

    event_wait = ready_room!("card-event-wait")
    assert {:ok, event_claim} = Custody.claim_next("incident-card:event", 60, :work)
    deadline = ~U[2099-08-28 13:00:00.000000Z]

    assert {:ok, wait_record} =
             Records.create(Records.token(event_claim.turn), "event-wait", "event_wait", %{
               "deadline_at" => DateTime.to_iso8601(deadline),
               "event_matcher" => %{"deployment" => "responder"},
               "kind" => "deployment_health",
               "verification" => "Wait for the production deployment health check."
             })

    assert {:ok, _waiting} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 deadline_at: deadline,
                 episode_key: event_wait.episode.key,
                 expected_turn_ref: event_wait.episode.owner_ref,
                 kind: :event,
                 occurred_at: DateTime.add(@now, 5, :second),
                 wait_ref: wait_record.ref
               })
             )

    assert {:ok, projection} = IncidentRoomCard.build(event_wait.room)
    assert projection.document["incident_room"]["status"] == "waiting_for_event"
    assert projection.document["incident_room"]["action_needed"] =~ "production deployment"

    assert IncidentRoomCard.build(:invalid) == {:error, :invalid_incident_room_card}

    missing = %{event_wait.room | episode_id: Ecto.UUID.generate()}
    assert IncidentRoomCard.build(missing) == {:error, :incident_room_episode_not_found}

    assert {:ok, provisioning} = IncidentRoomCard.build(%{event_wait.room | episode_id: nil})
    assert provisioning.document["incident_room"]["status"] == "provisioning"
    assert provisioning.document["incident_room"]["episode_state"] == "provisioning"

    for {state, expected} <- [
          {:archived, "Unarchive it"},
          {:unavailable, "Restore access"},
          {:deleted, "deleted"}
        ] do
      assert {:ok, inactive} = IncidentRoomCard.build(%{event_wait.room | channel_state: state})
      assert inactive.document["incident_room"]["status"] == "paused"
      assert inactive.document["incident_room"]["action_needed"] =~ expected
    end
  end

  test "incident worker options are strict and a named worker remains alive while idle" do
    agent = incident_agent!()
    options = worker_options(agent)

    assert IncidentRoomWorker.options!(Map.to_list(options)).interval_ms == 1_000

    assert_raise ArgumentError, ~r/unique options/, fn ->
      IncidentRoomWorker.options!(api: API, api: API)
    end

    assert_raise ArgumentError, ~r/invalid incident-room worker options/, fn ->
      IncidentRoomWorker.options!(%{options | lease_seconds: 1})
    end

    assert_raise ArgumentError, ~r/invalid incident-room worker options/, fn ->
      IncidentRoomWorker.options!(:invalid)
    end

    name = Module.concat(__MODULE__, "Idle#{System.unique_integer([:positive])}")

    pid =
      start_supervised!({IncidentRoomWorker, Map.merge(options, %{interval_ms: 50, name: name})})

    assert Process.alive?(pid)
  end

  defp save_channel_configuration!(alert_policy \\ :offer) do
    attributes = %{
      actor_ref: "U123",
      alert_policy: alert_policy,
      channel_ref: "C456",
      id: Ecto.UUID.generate(),
      invite_user_group_refs: ["SRE"],
      invite_user_refs: ["U200"],
      participation: :proactive,
      repository_ref: "responder",
      revision: 1,
      saved_at: @now,
      workspace_ref: "T123"
    }

    attributes
    |> ChannelConfigurationChangeset.configuration()
    |> Repo.insert!()
  end

  defp worker_options(agent) do
    %{
      api: API,
      bot_user_ref: "U-BOT",
      client: agent,
      directory: Directory,
      lease_seconds: 60,
      max_attempts: 3,
      retry_base_seconds: 1,
      worker_ref: "incident-room-worker"
    }
  end

  defp ready_room!(suffix) do
    fixture = delivered_offer!()
    agent = incident_agent!()
    channel_ref = "C#{System.unique_integer([:positive])}"
    Agent.update(agent, &Map.put(&1, :channel_ref, channel_ref))

    request =
      fixture
      |> request()
      |> Map.put(:confirmation_ref, "interaction:#{suffix}")

    assert {:ok, _requested} = IncidentRooms.request(request)
    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get_by!(IncidentRoom, ref: room_ref)
    episode = Repo.get!(Responder.Episodes.Episode, room.episode_id)
    %{agent: agent, episode: episode, room: room}
  end

  defp incident_agent! do
    start_supervised!(
      {Agent,
       fn ->
         %{
           allowed_users: MapSet.new(["U123", "U200", "U201", "U300"]),
           channel_ref: nil,
           conversations: [],
           groups: %{"SRE" => ["U201", "U200"]},
           invites: [],
           messages: %{},
           pins: [],
           posts: [],
           topics: []
         }
       end},
      id: {:incident_room_agent, System.unique_integer([:positive])}
    )
  end

  defp runtime_configuration! do
    {:ok, http} =
      JSONClient.new(%{
        base_url: "https://slack.com/api",
        finch: Responder.CoopFinch,
        receive_timeout: 1_000,
        token_provider: fn -> {:ok, "xoxb-test"} end
      })

    {:ok, client} = Client.new(http: http, requester: JSONClient)

    %{
      app_http: http,
      bot_client: client,
      default_repository: "responder",
      identity: %{bot_ref: "B123", bot_user_ref: "U999", workspace_ref: "T123"},
      incident_policy: %{digest: @policy_digest, name: "incident-investigate"},
      operators: ["U123"],
      repositories: %{
        "responder" => %{
          contributor_policy: %{
            digest: String.duplicate("c", 64),
            name: "responder-contributor"
          }
        }
      },
      default_participation: :mentions
    }
  end

  defp make_room_retryable!(room_id) do
    Repo.update_all(
      from(room in IncidentRoom, where: room.id == ^room_id),
      set: [lease_expires_at: nil, lease_owner: nil, lease_ref: nil, next_attempt_at: @now]
    )
  end

  defp lifecycle(room, kind, event_ref, occurred_at) do
    %MembershipTransition{
      actor_ref: "U123",
      channel_ref: room.channel_ref,
      event_ref: event_ref,
      kind: kind,
      occurred_at: occurred_at,
      workspace_ref: room.workspace_ref
    }
  end

  defp request(fixture) do
    %{
      actor_ref: "slack:user:U123",
      bot_user_ref: "U-BOT",
      channel_prefix: "ems",
      confirmation_ref: "interaction:incident",
      invite_user_refs: ["U300", "U123"],
      maximum_open_rooms: 25,
      occurred_at: DateTime.add(@now, 2, :second),
      policy: %{digest: @policy_digest, name: "incident-investigate"},
      private: true,
      record_ref: fixture.record.ref,
      target: %{
        conversation_ref: "slack:T123:C456",
        message_ref: fixture.receipt["message_ref"],
        thread_ref: "1787832000.000100",
        transport: "slack"
      },
      workspace_ref: "T123"
    }
  end

  defp investigate(fixture) do
    %{
      actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:investigate",
      occurred_at: DateTime.add(@now, 2, :second),
      policy: %{digest: @policy_digest, name: "incident-investigate"},
      record_ref: fixture.record.ref,
      target: %{
        conversation_ref: "slack:T123:C456",
        message_ref: fixture.receipt["message_ref"],
        thread_ref: "1787832000.000100",
        transport: "slack"
      },
      workspace_ref: "T123"
    }
  end

  defp automatic_request(candidate) do
    Map.merge(candidate, %{
      bot_user_ref: "U-BOT",
      channel_prefix: "ems",
      invite_user_refs: ["U123", "U300"],
      maximum_open_rooms: 25,
      policy: %{digest: @policy_digest, name: "incident-investigate"},
      private: true
    })
  end

  defp delivered_offer!(actor_kind \\ :user) do
    episode_id = Ecto.UUID.generate()
    actor_ref = if actor_kind == :app, do: "slack:app:A123", else: "slack:user:U123"

    command =
      EpisodeFixtures.admit_input(%{
        actor_ref: actor_ref,
        destination: %{
          conversation_ref: "slack:T123:C456",
          thread_ref: "1787832000.000100",
          transport: "slack"
        },
        episode_id: episode_id,
        episode_key: "incident-offer-source:#{episode_id}",
        native_input_id: "slack-message:incident-offer:#{episode_id}",
        occurred_at: @now,
        turn_ref: "turn:incident-offer:#{episode_id}"
      })

    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: actor_kind, ref: if(actor_kind == :app, do: "A123", else: "U123")},
               content: command.payload,
               destination: command.destination,
               event_kind: :message,
               event_ref: "incident-offer-source:#{episode_id}",
               native_input_id: command.native_input_id,
               occurred_at: command.occurred_at,
               occurred_at_source: :source,
               revision: command.revision,
               source: %{kind: "slack", ref: "T123"},
               source_capabilities: %{},
               source_item_ref: "1787832000.000100"
             })

    assert {:ok, source} = Inbox.record(input)
    command = %{command | payload: Input.document(input)}
    assert {:ok, transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "responder-read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:incident-offer", 60, :work)

    payload = %{
      "kind" => "incident",
      "prompt" => "Investigate checkout errors and coordinate responders.",
      "repository" => nil,
      "title" => "Checkout errors"
    }

    assert {:ok, record} =
             Records.create(Records.token(claim.turn), "incident-offer", "task_offer", payload)

    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert {:ok, frozen_turn} =
             Custody.freeze_submission(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert :ok = KnowledgeSnapshot.expose_submission(%{claim | turn: frozen_turn})

    assert {:ok, session} =
             Custody.bind_session(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:incident-offer:#{episode_id}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:incident-offer:#{episode_id}"
             )

    candidate = ~s({"delivery":"reply","message":"I can open an incident room."})
    sha256 = :crypto.hash(:sha256, candidate) |> Base.encode16(case: :lower)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               episode_id,
               turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               1
             )

    assert {:ok, result} =
             Result.new(:reply, %{
               "decision_reason" => nil,
               "delivery" => "reply",
               "message" => "I can open an incident room.",
               "outcome" => %{
                 "artifact_refs" => [],
                 "record_refs" => [record.ref],
                 "state" => "complete"
               }
             })

    assert {:ok, _turn} =
             Custody.prepare_validation(
               episode_id,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               episode_id,
               transition.episode.key,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               "validation-receipt:incident-offer"
             )

    assert {:ok, delivery_claim} = Custody.claim_next("delivery:incident-offer", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "slack",
               "slack:T123:C456",
               "1787832000.000100",
               "1787832001.000100"
             )

    assert {:ok, settled} =
             Custody.confirm_delivery(
               episode_id,
               transition.episode.key,
               turn.turn_ref,
               delivery_claim.lease_ref,
               receipt
             )

    %{
      episode: settled.episode,
      input: input,
      input_entry: source.entry,
      receipt: receipt,
      record: record,
      session: session
    }
  end
end
