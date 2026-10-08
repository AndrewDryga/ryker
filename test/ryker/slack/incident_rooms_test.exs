defmodule Ryker.Slack.IncidentRoomsTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  import Ryker.TestHelpers, only: [digest: 1, eventually: 2]
  import ExUnit.CaptureLog
  alias Ryker.Config
  alias Ryker.ControlPlane.{FailureExplanation, FailureProjection, InstructionSettings}
  alias Ryker.Delivery.{Adapters, Dispatcher, JSONClient}
  alias Ryker.Episodes
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.TaskOffer
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Ingress.{Inbox, Input, WorkProfile}
  alias Ryker.Inspectors
  alias Ryker.Knowledge.KnowledgeSnapshot
  alias Ryker.Operator.Delivery, as: DeliveryOperator
  alias Ryker.Records
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Slack.{ChannelConfiguration, Client, IncidentRoom}
  alias Ryker.Slack.{IncidentRoomCard, IncidentRoomLifecycleEvent, IncidentRooms}
  alias Ryker.Slack.{IncidentRoomWorker, MembershipTransition, Renderer, Runtime, WorkRecord}
  alias Ryker.Slack.WorkTarget
  alias Ryker.Work.{Cancellation, Custody, DeliveryReceipt, Result, Session, Submission}
  alias Ryker.Work.{SubmissionBuilder, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]
  @policy_digest String.duplicate("b", 64)
  # What the alert's own conversation mounted: its environment's writable
  # repository and the one it reads.
  @source_context %{
    "context_ref" => "production",
    "parallel_goal_limit" => 2,
    "primary_repository" => "ryker",
    "read_only_repositories" => ["docs"]
  }

  # A finished answer as a run's final result, harvested from
  # episode_work_turns.delivery_document (turn e35050df, 2026-09-23).
  @finished_answer %{
    "decision_reason" => nil,
    "delivery" => "reply",
    "message" =>
      "A liveness probe checks whether a container is still functioning; repeated failures cause Kubernetes to restart it. A readiness probe checks whether it can serve traffic; failures mark the Pod unready and remove it from matching Services’ ready endpoints without restarting the container. Use liveness for problems a restart can fix, such as a deadlock, and readiness for temporary inability to handle requests, such as warming up or waiting on a dependency.",
    "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
  }

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
            post(state, channel_ref, thread_ref, document, delivery_ref)

          # Slack posted it, but its answer never reached Ryker.
          {:answer_lost, reason} ->
            {_posted, state} = post(state, channel_ref, thread_ref, document, delivery_ref)
            {{:error, reason}, state}

          reason ->
            {{:error, reason}, state}
        end
      end)
    end

    defp post(state, channel_ref, thread_ref, document, delivery_ref) do
      key = {channel_ref, thread_ref, delivery_ref}
      message_ref = Map.get(state.messages, key, "1787832001.000200")

      {{:ok, message_ref},
       %{
         state
         | messages: Map.put(state.messages, key, message_ref),
           posts: state.posts ++ [{channel_ref, thread_ref, document, delivery_ref}]
       }}
    end

    # The rest of the surface Slack's publisher checks for; notes never use it.
    def find_files(_agent, _channel_ref, _thread_ref, _filenames, _oldest), do: :not_found

    def upload_files(_agent, _channel_ref, _thread_ref, _document, _delivery_ref, _files),
      do: {:error, :not_used}

    def add_reaction(_agent, _channel_ref, _message_ref, _emoji_name), do: {:error, :not_used}

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
    assert KnowledgeSnapshot.authorize_session(fixture.episode, fixture.session) == :ok

    deleted = %{
      fixture.input
      | event_ref: fixture.input.event_ref <> ":deleted",
        event_kind: :delete,
        revision: fixture.input.revision + 1
    }

    assert {:ok, _} = Inbox.record(deleted)

    assert KnowledgeSnapshot.authorize_session(fixture.episode, fixture.session) ==
             {:error, :work_knowledge_context_stale}
  end

  # One offer owns both paths. Before 2026-09-11 an incident offer had only
  # "Open incident room"; the in-place path did not exist, and nothing stopped a
  # room request and a thread investigation from both starting on one offer.
  # Incident rooms, a room's page and the request that offered the room all
  # show it. Until 2026-09-26 they heard of a requested room from a trigger's
  # NOTIFY and a five-second poll; the context now announces the room, and the
  # request it came from, once the request commits.
  test "a requested room reaches the room pages and the request that offered it" do
    fixture = delivered_offer!()
    source_id = fixture.episode.id
    :ok = IncidentRooms.subscribe_rooms()
    :ok = Episodes.subscribe_episode(source_id)

    assert {:ok, %{status: :requested, room: %{id: id, ref: ref}}} =
             IncidentRooms.request(request(fixture))

    assert_received {:incident_room_updated, ^id}
    assert_received {:episode_updated, ^source_id}

    :ok = IncidentRooms.subscribe_room(ref)
    assert {:ok, %{status: :duplicate}} = IncidentRooms.request(request(fixture))
    refute_received {:incident_room_updated, ^id}
  end

  test "one incident offer starts exactly one path: investigate in the thread or create a room" do
    fixture = delivered_offer!()
    other = delivered_offer!()
    save_channel_configuration!()

    assert {:ok, investigation} = IncidentRooms.investigate(investigate(fixture))
    assert investigation.status == :confirmed
    assert investigation.episode.destination_conversation_ref == "slack:T123:C456"
    assert investigation.episode.destination_thread_ref == "1787832000.000100"
    assert investigation.session.policy == "incident-investigate"
    # It works where the conversation works, like a room would: the same
    # environment (and Emisar account) and the same mounted repositories.
    assert investigation.session.environment_ref == "production"
    assert investigation.session.repository_ref == "ryker"
    assert investigation.session.repository_context == @source_context

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

  # The in-place path authorizes the press against the exact card this host
  # delivered, and nothing exercised that check: the room path's mismatch had a
  # test, the investigate path's did not. A card state nobody drives from its
  # producing condition is a claim, not a fact — the 2026-09-12 audit found one
  # such claim ("the parked state clears native activity") was simply false, and
  # a thread had been told "is working..." every 90 seconds ever since.
  test "investigating from a message this host never delivered starts no work" do
    fixture = delivered_offer!()

    crossed = put_in(investigate(fixture), [:target, :message_ref], "1787832999.999999")

    assert IncidentRooms.investigate(crossed) == {:error, :incident_offer_delivery_mismatch}

    record = Repo.get!(Record, fixture.record.id)
    assert record.status == :open
    assert is_nil(record.confirmed_episode_id)
    refute Repo.get_by(IncidentRoom, record_id: record.id)
    assert Repo.aggregate(Session, :count, :id) == 1

    # The offer itself is untouched: only the crossed message was refused.
    assert {:ok, investigation} = IncidentRooms.investigate(investigate(fixture))
    assert investigation.status == :confirmed
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
    assert room.root_card_ui_revision == 3
    assert room.episode_id
    assert room.audience_prepared_at
    assert room.topic_prepared_at
    assert room.root_pinned_at
    assert room.handoff_message_ref == "1787832001.000200"

    episode = Repo.get!(Ryker.Episodes.Episode, room.episode_id)
    assert episode.linked_episode_id == fixture.episode.id
    assert episode.destination_transport == "slack"
    assert episode.destination_conversation_ref == "slack:T123:CINCIDENT"
    assert episode.destination_thread_ref == room.root_message_ref

    assert %Session{
             policy: "incident-investigate",
             policy_digest: @policy_digest,
             repository_ref: "ryker"
           } = Repo.get_by!(Session, episode_id: episode.id)

    room_target = %{
      conversation_ref: "slack:T123:CINCIDENT",
      message_ref: room.root_message_ref,
      thread_ref: room.root_message_ref,
      transport: "slack"
    }

    assert {:ok, %{kind: :incident, work_ref: ^room_ref}} =
             WorkTarget.resolve(room_ref, room_target)

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
    # Topics said "Incident 1a2b3c4d | … | managed by Emisar": Ryker's own id,
    # and the wrong product (2026-10-04 review).
    assert state.topics == [{"CINCIDENT", "Checkout errors · incident room opened by Ryker"}]

    assert state.pins == [{"CINCIDENT", room.root_message_ref}]

    assert [
             {"CINCIDENT", nil, %{"incident_room" => root}, root_delivery_ref},
             {"C456", "1787832000.000100", handoff, handoff_delivery_ref}
           ] = state.posts

    assert root["room_ref"] == room.ref
    assert root["status"] == "provisioning"
    assert root["repository"] == "ryker"
    assert root_delivery_ref == "#{room.ref}:root"
    # What Slack is sent links the room's channel; the escaped text of a link showed as
    # "<#CINCIDENT>" in the thread (2026-10-04 review).
    assert {:ok, %{"text" => handoff_text}} = Client.Messages.render(handoff)
    assert handoff_text =~ "Incident room ready: <#CINCIDENT>."
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
    # What Slack is sent is what the renderer accepts.
    assert {:ok, _rendered} = Renderer.render(%{"incident_room" => updated_root})

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
             Ryker.Instructions.save(:global, "Global incident default", 0, "operator:test")

    assert {:ok, _} =
             Ryker.Instructions.save(
               {:channel, "T123", "C456"},
               "Source channel only",
               0,
               "operator:test"
             )

    assert {:ok, _} =
             Ryker.Instructions.save(
               {:channel, "T123", "CINCIDENT"},
               "Incident room default",
               0,
               "operator:test"
             )

    assert {:ok, submission} = SubmissionBuilder.build(claim)
    # As the room's live Work turn records, so its records may be shown there.
    assert KnowledgeSnapshot.expose(claim, []) == :ok
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
    assert handoff["message"] =~ "*Where this stands* · Checkout errors"
    assert handoff["message"] =~ "Latest update: Checkout traffic recovered"
    # An incident opens no pull request, and whether its cause is known matters to it.
    refute handoff["message"] =~ "draft PR"
    assert handoff["message"] =~ "Unknown: Root cause is not established"

    assert {:ok, postmortem} = WorkRecord.build(room.ref, record_target, :postmortem)
    assert postmortem["message"] =~ "human review is required"
    assert postmortem["message"] =~ "Unknown: no alert impact assessment"
    assert postmortem["message"] =~ "Unknown: no evidence-backed root cause"
  end

  # A room continues the work of the conversation it was opened from, so it
  # works in that conversation's environment: the same repositories mounted
  # and the same Emisar account, whatever the channel has chosen since. A room
  # took its repository from the channel's saved setting, which names an
  # environment now, and pinned no environment, so its investigation ran
  # outside every environment, without the Emisar account the alert had.
  test "an incident room inherits its conversation's environment" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()

    assert fixture.session.environment_ref == "production"
    assert Inspectors.channel_configuration("T123", "C456").environment_ref == nil

    assert {:ok, %{room: requested}} = IncidentRooms.request(request(fixture))
    assert requested.environment_ref == "production"
    assert requested.repository_ref == "ryker"
    assert requested.repository_context == @source_context

    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get_by!(IncidentRoom, ref: room_ref)

    assert %Session{
             environment_ref: "production",
             policy: "incident-investigate",
             repository_context: @source_context,
             repository_ref: "ryker"
           } = Repo.get_by!(Session, episode_id: room.episode_id)

    # A conversation started in the room works there too: in the same
    # environment, with the repositories the room froze, its own repository
    # the default working copy and the others mounted read-only.
    work_profile = Runtime.options!(runtime_configuration!()).handler_settings.work_profile

    assert {:ok, attributes} = work_profile.("T123", "slack:T123:#{room.channel_ref}")
    assert {:ok, profile} = WorkProfile.new(attributes)
    assert profile.environment_ref == "production"
    assert profile.repositories == ["ryker", "docs"]
    assert WorkProfile.repository_refs(profile) == ["ryker"]
    assert WorkProfile.read_only_refs(profile) == ["docs"]

    assert WorkProfile.policy_for(profile, :standard, "docs") ==
             {:error, {:invalid_work_profile, :repository_ref}}

    assert profile.parallel_goal_limit == 2

    assert {:ok, %{name: "incident-investigate", repository_context: @source_context}} =
             WorkProfile.policy_for(profile, :standard)
  end

  # A conversation in no environment works without a repository, and asking
  # for an incident room there failed: a room had to name a repository, so
  # the request rolled back (2026-10-04 review).
  test "a conversation with no repository can open an incident room" do
    fixture = delivered_offer!(:user, repository: nil, environment: nil)
    save_channel_configuration!()
    agent = incident_agent!()

    assert {:ok, %{room: requested}} = IncidentRooms.request(request(fixture))
    assert requested.repository_ref == nil

    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get_by!(IncidentRoom, ref: room_ref)
    assert %Session{repository_ref: nil} = Repo.get_by!(Session, episode_id: room.episode_id)

    # Its pinned card renders: the card required a repository and refused one
    # without (2026-10-06).
    assert {:ok, card} = IncidentRoomCard.build(room)
    assert {:ok, _rendered} = Renderer.render(card.document)
  end

  # A channel's room audience named one person who had since left the
  # workspace, and every room from that channel blocked before Slack made it,
  # during the incidents it was for (2026-10-04 review). People who cannot
  # join, and groups with nobody in them, are left out; the room is made.
  test "invitees who cannot join are left out, and the room is still made" do
    fixture = delivered_offer!()
    save_channel_configuration!()

    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             allowed_users: MapSet.new(["U123", "U201", "U300"]),
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

    log =
      capture_log(fn ->
        assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
        assert room_ref == requested.room.ref
      end)

    assert log =~ "left out U200"
    invited = agent |> Agent.get(& &1.invites) |> Enum.flat_map(&elem(&1, 1))
    assert "U201" in invited
    refute "U200" in invited
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

    episode = Repo.get!(Ryker.Episodes.Episode, room.episode_id)
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

    resumed_episode = Repo.get!(Ryker.Episodes.Episode, room.episode_id)
    assert resumed_episode.owner_ref != episode.owner_ref

    assert {:ok, claim} = Custody.claim_next("work:unarchived-room", 60, :work)
    assert claim.episode.id == room.episode_id
    assert claim.turn.turn_ref == resumed_episode.owner_ref
  end

  # On 2026-09-27 an idle install committed about 125 transactions a second;
  # the incident-room worker ran five queries every second with no room to
  # tend. It now sleeps until a room or its request is announced, so a room
  # someone asks for has to wake it.
  test "a room requested while the worker is idle is set up at once, not at the next timer" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()

    worker = start_supervised!({IncidentRoomWorker, sleeping_worker_options(agent)})
    # Its first poll found nothing, and its next timer is five minutes away.
    _state = :sys.get_state(worker)

    assert {:ok, %{status: :requested}} = IncidentRooms.request(request(fixture))
    assert eventually(fn -> Agent.get(agent, & &1.conversations) != [] end, 500)
  end

  # A room whose setup failed is retried after a backoff, and only the clock
  # says when: a worker sleeping its whole safety-net interval would leave the
  # incident without its room for ten seconds more.
  test "a room whose retry falls due is set up then, not at the safety-net interval" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()
    assert {:ok, %{status: :requested}} = IncidentRooms.request(request(fixture))

    Agent.update(agent, &Map.put(&1, :invite_error, :invite_offline))
    assert {:ok, {:deferred, _room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    Agent.update(agent, &Map.delete(&1, :invite_error))

    start_supervised!({IncidentRoomWorker, sleeping_worker_options(agent)})

    refute eventually(fn -> Agent.get(agent, & &1.invites) != [] end, 500)
    assert eventually(fn -> Agent.get(agent, & &1.invites) != [] end, 1_500)
  end

  # A ready room's pinned card is checked every few seconds for as long as
  # the room is open, and each check announced its claim and its result on
  # the incident's topics even when the card had not changed. Once a dozen
  # workers woke on those topics, every such check woke all of them.
  test "a check that finds a room's card unchanged is not announced" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()
    assert {:ok, %{room: requested}} = IncidentRooms.request(request(fixture))
    assert {:ok, {:ready, _room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    room = Repo.get!(IncidentRoom, requested.id)
    card_check_due!(room)
    assert {:ok, {:ready, _room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    card_check_due!(room)
    :ok = IncidentRooms.subscribe_rooms()
    :ok = Episodes.subscribe_episode(room.episode_id)
    assert {:ok, {:ready, _room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    refute_received {:incident_room_updated, _room_id}
    refute_received {:episode_updated, _episode_id}
  end

  # The pinned card printed a blocked turn's saved error as it was stored, a
  # code and whatever the worker had said, in the room everyone reads
  # (2026-10-04 review). It says what Ryker can tell in words, and where the
  # rest is written.
  test "a blocked investigation's card says what stopped it in words, never its saved code" do
    room = ready_room!("card-blocked")
    assert {:ok, claim} = Custody.claim_next("incident-card:blocked", 60, :work)

    Repo.update_all(from(turn in Turn, where: turn.id == ^claim.turn.id),
      set: [
        status: :blocked,
        last_error_code: "work_execution_failed",
        last_error_detail: "work_execution_failed: {:work_execution_failed, :unknown}",
        lease_ref: nil,
        lease_owner: nil,
        lease_expires_at: nil,
        next_attempt_at: nil
      ]
    )

    assert {:ok, projection} = IncidentRoomCard.build(Repo.get!(IncidentRoom, room.room.id))
    action = projection.document["incident_room"]["action_needed"]
    refute action =~ "work_execution"
    assert action =~ "needs a person"
  end

  # Every routine check of a ready room's card took an attempt and gave none
  # back, so a room open for an hour had spent thousands, and its first refused
  # card update waited the longest backoff, minutes, where a fresh room waits a
  # second (2026-10-04 review).
  test "routine card checks leave a ready room's attempts unspent" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()
    assert {:ok, %{room: requested}} = IncidentRooms.request(request(fixture))
    assert {:ok, {:ready, _room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get!(IncidentRoom, requested.id)

    for _check <- 1..3 do
      card_check_due!(room)
      assert {:ok, {:ready, _room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    end

    assert Repo.get!(IncidentRoom, room.id).attempt_count == 0
  end

  # Each ready room's card was checked every 2 seconds for as long as the room
  # was open, two writes and a full card build each time, whether or not its
  # investigation was doing anything (2026-10-04 review).
  test "a ready room's card is checked every few seconds only while its investigation works" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()
    assert {:ok, %{room: requested}} = IncidentRooms.request(request(fixture))
    assert {:ok, {:ready, _room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get!(IncidentRoom, requested.id)

    card_checked!(room, 10)
    assert {:ok, %IncidentRoom{id: claimed}} = IncidentRooms.claim_root_card("card-check", 60, 2)
    assert claimed == room.id

    finish!(room.episode_id)
    card_checked!(room, 10)
    assert IncidentRooms.claim_root_card("card-check", 60, 2) == {:ok, nil}

    # The worker sleeps until then, not until two seconds after the check: an
    # announced change makes it due before then.
    checked = Repo.get!(IncidentRoom, room.id).root_card_checked_at
    assert IncidentRooms.next_due_at(Repo.now!(), 3_600, 2) == DateTime.add(checked, 600, :second)

    # A finished investigation's card is still checked every ten minutes.
    card_checked!(room, 601)
    assert {:ok, %IncidentRoom{id: ^claimed}} = IncidentRooms.claim_root_card("card-check", 60, 2)
  end

  # A room's card was checked by the clock alone, so an investigation that
  # finished showed as working until the next check (2026-10-04 review). An
  # announced change to it is checked at the next poll.
  test "a ready room's card shows an announced change to its investigation at once" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()
    assert {:ok, %{room: requested}} = IncidentRooms.request(request(fixture))
    assert {:ok, {:ready, _room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get!(IncidentRoom, requested.id)

    finish!(room.episode_id)
    card_checked!(room, 0)
    Agent.update(agent, &Map.put(&1, :updates, []))

    worker = start_supervised!({IncidentRoomWorker, sleeping_worker_options(agent)})
    _state = :sys.get_state(worker)
    refute eventually(fn -> Agent.get(agent, & &1.updates) != [] end, 300)

    :ok = Episodes.broadcast_episode_updated(room.episode_id)
    assert eventually(fn -> Agent.get(agent, & &1.updates) != [] end, 1_000)
  end

  # Asking for a room locked the offer's episode, turn and session along with
  # the offer, so every write to that conversation's work waited for the
  # request (2026-10-04 review). The offer alone serializes its requests. A
  # sandboxed test is one transaction that holds those rows already, so the
  # locks the request asks for are read from the statements it sends.
  test "asking for a room locks the offer and no row of its conversation's work" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    parent = self()
    handler = "incident-room-locks-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:ryker, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata.query =~ "FOR UPDATE", do: send(parent, {:locks, metadata.query})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, %{status: :requested}} = IncidentRooms.request(request(fixture))
    :telemetry.detach(handler)

    assert_received {:locks, offer} when is_binary(offer)
    assert offer =~ ~s(FROM "episode_state_records")
    assert offer =~ ~r/FOR UPDATE OF e0\z/
  end

  defp card_checked!(room, seconds_ago) do
    Repo.update_all(from(stored in IncidentRoom, where: stored.id == ^room.id),
      set: [
        root_card_checked_at: DateTime.add(Repo.now!(), -seconds_ago, :second),
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil
      ]
    )
  end

  defp finish!(episode_id) do
    Repo.update_all(from(episode in Episode, where: episode.id == ^episode_id),
      set: [
        state: :complete,
        owner_kind: nil,
        owner_ref: nil,
        owner_deadline_at: nil,
        active_input_refs: [],
        queued_input_refs: [],
        queued_input_order_keys: []
      ]
    )
  end

  defp card_check_due!(room) do
    Repo.update_all(from(stored in IncidentRoom, where: stored.id == ^room.id),
      set: [
        channel_checked_at: Repo.now!(),
        root_card_checked_at: DateTime.add(Repo.now!(), -3_600, :second)
      ]
    )
  end

  # A room whose channel was deleted before setup finished was blocked for
  # good: the Failures page could only say its retry would be refused, and the
  # room counted against the open-room limit forever, one step closer to no
  # incident room opening at all.
  test "a room whose channel is deleted during setup closes itself and frees its place" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()

    assert {:ok, %{room: requested}} =
             IncidentRooms.request(%{request(fixture) | maximum_open_rooms: 1})

    Agent.update(agent, &Map.put(&1, :invite_error, :invite_offline))
    assert {:ok, {:deferred, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get!(IncidentRoom, requested.id)
    assert room.channel_ref == "CINCIDENT"

    deleted_at = DateTime.add(room.channel_state_changed_at, 1, :second)

    assert {:ok, %{status: :applied, room: closed}} =
             IncidentRooms.observe_lifecycle(
               lifecycle(room, :deleted, "Ev-incident-deleted-in-setup", deleted_at)
             )

    assert closed.status == :closed
    assert closed.channel_state == :deleted
    assert closed.last_error_code == "incident_room_deleted"
    assert closed.lease_ref == nil
    assert closed.next_attempt_at == nil
    assert FailureProjection.slack_incident(room_ref) == :not_found

    # History stays: the room, its channel and the deletion Slack reported.
    assert %IncidentRoomLifecycleEvent{kind: :deleted} =
             Repo.get_by!(IncidentRoomLifecycleEvent, room_id: room.id)

    # Nothing is left for the worker to do, and the limit has room again.
    assert IncidentRoomWorker.run_once(worker_options(agent)) == {:ok, :idle}
    assert Repo.get!(IncidentRoom, room.id).status == :closed

    assert {:ok, %{status: :requested}} =
             IncidentRooms.request(%{request(delivered_offer!()) | maximum_open_rooms: 1})
  end

  # A room whose channel was archived, or that Ryker was removed from, before
  # setup finished was never taken up again: it stayed requested and held a
  # place in the open-room limit for good (2026-10-04 review). Like a deleted
  # one, it closes itself.
  for {kind, code} <- [archived: "incident_room_archived", left: "incident_room_left"] do
    test "a room whose channel is #{kind} during setup closes itself and frees its place" do
      fixture = delivered_offer!()
      save_channel_configuration!()
      agent = incident_agent!()

      assert {:ok, %{room: requested}} =
               IncidentRooms.request(%{request(fixture) | maximum_open_rooms: 1})

      Agent.update(agent, &Map.put(&1, :invite_error, :invite_offline))
      assert {:ok, {:deferred, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
      room = Repo.get!(IncidentRoom, requested.id)
      changed_at = DateTime.add(room.channel_state_changed_at, 1, :second)
      event = lifecycle(room, unquote(kind), "Ev-incident-#{unquote(kind)}-in-setup", changed_at)

      assert {:ok, %{status: :applied, room: closed}} = IncidentRooms.observe_lifecycle(event)
      assert closed.status == :closed
      assert closed.last_error_code == unquote(code)
      assert FailureProjection.slack_incident(room_ref) == :not_found

      assert {:ok, %{status: :requested}} =
               IncidentRooms.request(%{request(delivered_offer!()) | maximum_open_rooms: 1})
    end
  end

  # A room whose channel was deleted paused its investigation for good: Slack
  # never brings a deleted channel back, so the request stayed open forever,
  # the Failures page promised it would resume "when the room is active
  # again", and nobody in the alert thread was told the room was gone. The
  # investigation now closes the way a person's Close request closes it, and
  # one fixed note says so in the thread the room was opened from.
  test "a deleted incident room closes its investigation and says so in the alert thread" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()
    publish_through_slack!(agent)

    assert {:ok, _requested} =
             IncidentRooms.request(%{request(fixture) | maximum_open_rooms: 1})

    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get_by!(IncidentRoom, ref: room_ref)
    posted_before = Agent.get(agent, & &1.posts)

    assert {:ok, %{status: :applied, room: %{status: :ready}}} =
             IncidentRooms.observe_lifecycle(
               lifecycle(room, :deleted, "Ev-incident-ready-deleted", deleted_at(room))
             )

    assert {:ok, {:closed, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    closed = Repo.get!(IncidentRoom, room.id)
    assert closed.status == :closed
    assert closed.channel_state == :deleted
    assert closed.reconciled_channel_state == :deleted
    assert closed.last_error_code == "incident_room_deleted"
    assert closed.episode_id == room.episode_id

    # Closed the way a person closes a request, saying why; nothing is deleted.
    assert %Episode{state: :cancelled} = episode = Repo.get!(Episode, room.episode_id)
    assert cancellation_reason(episode) =~ "##{room.channel_name} was deleted"

    # One note, in the host's own words, in the alert thread the room came from.
    note = "The incident room ##{room.channel_name} was deleted. Reply here to pick it up."

    assert Agent.get(agent, & &1.posts) -- posted_before == [
             {"C456", "1787832000.000100", %{"message" => note},
              "incident-room:#{room.ref}:deleted"}
           ]

    # Nothing is left to do, and a later pass never posts it again.
    assert IncidentRoomWorker.run_once(worker_options(agent)) == {:ok, :idle}
    assert length(Agent.get(agent, & &1.posts)) == length(posted_before) + 1

    # Neither the room nor its closed request waits on anyone.
    assert FailureProjection.slack_incident(room_ref) == :not_found
    assert FailureProjection.work(episode.key) == :not_found

    assert {:ok, %{status: :requested}} =
             IncidentRooms.request(%{request(delivered_offer!()) | maximum_open_rooms: 1})
  end

  # Andrew, 2026-10-03: "why I can't do shit to incident rooms, how about at least closing them?"
  # A room closed only when Slack deleted its channel, so a room whose incident was over stayed
  # open, counted against the open-room limit, and Ryker kept working in it.
  test "a room a person closes stops its investigation, says so in the room and the alert thread, and frees its place" do
    save_channel_configuration!()
    %{agent: agent, episode: episode, room: room} = ready_room!("closed-on-request")
    publish_through_slack!(agent)
    wait_for_an_answer!(episode)
    posted_before = Agent.get(agent, & &1.posts)

    assert {:ok, %IncidentRoom{status: :ready, close_requested_by: "control-plane:local"}} =
             IncidentRooms.request_close(room.ref, "control-plane:local")

    # Asking twice is one request.
    assert {:ok, %IncidentRoom{status: :ready}} =
             IncidentRooms.request_close(room.ref, "control-plane:local")

    room_ref = room.ref
    assert {:ok, {:closed, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    # Closed the way a person closes a request, saying why; nothing is deleted.
    assert %Episode{state: :cancelled} = closed_episode = Repo.get!(Episode, episode.id)

    assert cancellation_reason(closed_episode) ==
             "Closed with its incident room ##{room.channel_name}."

    # One note in the room, while people still read it, and one in the alert thread.
    assert Agent.get(agent, & &1.posts) -- posted_before == [
             {room.channel_ref, nil,
              %{
                "message" =>
                  "This incident room is closed. Ryker won't answer here anymore. Archive the channel in Slack when you no longer need it."
              }, "incident-room:#{room.ref}:closed-room"},
             {"C456", "1787832000.000100",
              %{"message" => "The incident room ##{room.channel_name} is closed."},
              "incident-room:#{room.ref}:closed"}
           ]

    closed = Repo.get!(IncidentRoom, room.id)
    assert closed.status == :closed
    assert closed.channel_state == :active
    assert closed.last_error_code == "incident_room_closed"

    assert closed.last_error_detail ==
             "Closed on request from Ryker's console. Ryker said so in the room and in the alert thread it was opened from."

    # Nothing is left to do, a closed room stays closed, and it no longer counts as open.
    assert IncidentRoomWorker.run_once(worker_options(agent)) == {:ok, :idle}
    assert length(Agent.get(agent, & &1.posts)) == length(posted_before) + 2

    assert IncidentRooms.request_close(room.ref, "control-plane:local") ==
             {:error, :incident_room_closed}

    assert {:ok, %{status: :requested}} =
             IncidentRooms.request(%{request(delivered_offer!()) | maximum_open_rooms: 1})
  end

  # The demo room on the Compose install, 2026-10-03, names a channel Slack does not know: Ryker
  # could not reach it, said its work there was paused, and offered nothing to do about it.
  test "a room whose channel Ryker cannot reach closes, saying so only in the alert thread" do
    save_channel_configuration!()
    %{agent: agent, episode: episode, room: room} = ready_room!("closed-unreachable")
    publish_through_slack!(agent)
    wait_for_an_answer!(episode)

    Repo.update_all(from(saved in IncidentRoom, where: saved.id == ^room.id),
      set: [channel_state: :unavailable, reconciled_channel_state: :unavailable]
    )

    posted_before = Agent.get(agent, & &1.posts)
    assert {:ok, _closing} = IncidentRooms.request_close(room.ref, "control-plane:local")

    room_ref = room.ref
    assert {:ok, {:closed, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    assert Repo.get!(Episode, episode.id).state == :cancelled

    assert [{"C456", "1787832000.000100", %{"message" => note}, _ref}] =
             Agent.get(agent, & &1.posts) -- posted_before

    assert note == "The incident room ##{room.channel_name} is closed."

    assert Repo.get!(IncidentRoom, room.id).last_error_detail ==
             "Closed on request from Ryker's console. Ryker said so in the alert thread it was opened from."
  end

  # A reply Ryker already finished for the room belongs in the room, where people are reading;
  # closing waits for it to be posted there, then closes what the request went on to do.
  test "a reply finished just as a room is closed is posted in the room before it closes" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()
    publish_through_slack!(agent)

    assert {:ok, _requested} = IncidentRooms.request(request(fixture))
    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get_by!(IncidentRoom, ref: room_ref)
    reply = accept_investigation_reply!(room, @finished_answer)
    posted_before = Agent.get(agent, & &1.posts)

    assert {:ok, _closing} = IncidentRooms.request_close(room_ref, "control-plane:local")
    assert {:ok, {:deferred, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    assert Agent.get(agent, & &1.posts) == posted_before

    assert {:ok, {:delivered, :message, delivery_ref}} =
             Dispatcher.run_once(delivery_options(agent))

    assert delivery_ref == reply.delivery_ref
    make_room_retryable!(room.id)
    assert {:ok, {:closed, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    # The reply in the room's thread under its card, then the note for everyone in the channel.
    answer = Map.take(@finished_answer, ["message"])

    assert [
             {channel, room_thread, ^answer, ^delivery_ref},
             {channel, nil, %{"message" => "This incident room is closed." <> _}, _room_note},
             {"C456", "1787832000.000100", %{"message" => _thread_note}, _ref}
           ] = Agent.get(agent, & &1.posts) -- posted_before

    assert channel == room.channel_ref
    assert room_thread == Repo.get!(IncidentRoom, room.id).root_message_ref
    assert Repo.get!(Episode, room.episode_id).state == :complete
  end

  test "a room whose setup stopped closes on request without waiting for a person to retry it" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()
    Agent.update(agent, &Map.put(&1, :ensure_error, :conversation_offline))
    publish_through_slack!(agent)

    assert {:ok, requested} = IncidentRooms.request(request(fixture))
    room_ref = requested.room.ref

    assert {:ok, {:blocked, ^room_ref, :conversation_offline}} =
             IncidentRoomWorker.run_once(%{worker_options(agent) | max_attempts: 1})

    assert {:ok, %IncidentRoom{status: :requested, close_requested_at: %DateTime{}}} =
             IncidentRooms.request_close(room_ref, "control-plane:local")

    posted_before = Agent.get(agent, & &1.posts)
    assert {:ok, {:closed, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    # No channel was ever made, so there is no room to post in and nothing to stop.
    assert [{"C456", "1787832000.000100", %{"message" => note}, _ref}] =
             Agent.get(agent, & &1.posts) -- posted_before

    assert note == "The incident room for this alert was closed before Ryker set it up."
    assert Agent.get(agent, & &1.conversations) == []
    assert Repo.get!(IncidentRoom, requested.room.id).status == :closed
  end

  test "closing a room asks for a known room and a named person" do
    assert IncidentRooms.request_close("incident-room:missing", "control-plane:local") ==
             {:error, :incident_room_not_found}

    assert IncidentRooms.request_close("incident-room:missing", "") ==
             {:error, {:invalid_incident_room_request, :actor_ref}}

    assert IncidentRooms.request_close(nil, "control-plane:local") ==
             {:error, {:invalid_incident_room_request, :room_ref}}
  end

  # A run still working when its room is deleted is stopped through the same
  # cancellation custody as a person's close: the request closes on the
  # worker's answer, never on Ryker's say-so, and the note waits for it.
  test "an investigation still running when its room is deleted closes only once its worker confirms the stop" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()
    publish_through_slack!(agent)

    assert {:ok, _requested} = IncidentRooms.request(request(fixture))
    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get_by!(IncidentRoom, ref: room_ref)
    running = start_investigation_run!(room)
    posted_before = Agent.get(agent, & &1.posts)

    assert {:ok, %{status: :applied}} =
             IncidentRooms.observe_lifecycle(
               lifecycle(room, :deleted, "Ev-incident-running-deleted", deleted_at(room))
             )

    assert {:ok, {:deferred, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    stopping = Repo.get!(Turn, running.turn.id)
    assert stopping.status == :cancel_pending
    assert stopping.cancellation_intent["action"] == "cancel"
    assert stopping.cancellation_intent["reason"] =~ "##{room.channel_name} was deleted"
    assert Repo.get!(Episode, room.episode_id).state == :working
    assert Repo.get!(IncidentRoom, room.id).status == :ready
    assert Agent.get(agent, & &1.posts) == posted_before

    # The worker answers that the run stopped.
    assert {:ok, claim} = Custody.claim_next("work:incident-room-stop", 60, :work)
    assert claim.turn.id == running.turn.id

    assert {:ok, receipt} =
             Cancellation.terminal_receipt(
               running.session.coop_session_id,
               running.turn.coop_turn_id,
               "cancelled",
               nil,
               "closed",
               nil
             )

    assert {:ok, _settled} =
             Custody.settle_cancellation(
               running.episode.id,
               running.episode.key,
               running.turn.turn_ref,
               claim.lease_ref,
               receipt
             )

    make_room_retryable!(room.id)
    assert {:ok, {:closed, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    assert Repo.get!(Episode, room.episode_id).state == :cancelled

    assert [{"C456", "1787832000.000100", %{"message" => note}, _ref}] =
             Agent.get(agent, & &1.posts) -- posted_before

    assert note ==
             "The incident room ##{room.channel_name} was deleted. Reply here to pick it up."
  end

  # An investigation waiting for someone's answer in its room waited for
  # good once the room was deleted: nobody can answer in a channel that is
  # gone. It closes at once, the way a person's close closes a waiting request.
  test "an investigation waiting for an answer closes at once when its room is deleted" do
    save_channel_configuration!()
    %{agent: agent, episode: episode, room: room} = ready_room!("deleted-while-waiting")
    publish_through_slack!(agent)
    assert {:ok, claim} = Custody.claim_next("incident-room:waiting", 60, :work)
    assert claim.episode.id == episode.id

    assert {:ok, question} =
             Records.create(Records.token(claim.turn), "question", "input_request", %{
               "choices" => ["rollback", "continue"],
               "question" => "Should we roll back the checkout deployment?"
             })

    assert {:ok, %{episode: %Episode{state: :waiting_for_input}}} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 episode_key: episode.key,
                 expected_turn_ref: episode.owner_ref,
                 occurred_at: DateTime.add(@now, 5, :second),
                 wait_ref: question.ref
               })
             )

    posted_before = Agent.get(agent, & &1.posts)

    assert {:ok, %{status: :applied}} =
             IncidentRooms.observe_lifecycle(
               lifecycle(room, :deleted, "Ev-incident-deleted-waiting", deleted_at(room))
             )

    room_ref = room.ref
    assert {:ok, {:closed, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    assert %Episode{state: :cancelled} = closed = Repo.get!(Episode, episode.id)
    assert cancellation_reason(closed) =~ "##{room.channel_name} was deleted"

    assert [{"C456", "1787832000.000100", %{"message" => note}, _ref}] =
             Agent.get(agent, & &1.posts) -- posted_before

    assert note ==
             "The incident room ##{room.channel_name} was deleted. Reply here to pick it up."
  end

  # Archiving a room before its investigation's first run parks that run
  # before any worker has it. Deleting the channel afterwards left the request
  # parked for good: closing it was refused as a conflicting stop, and the
  # Failures page kept saying it would resume when the room came back.
  test "an investigation parked before its first run closes when its archived room is deleted" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()
    publish_through_slack!(agent)

    assert {:ok, _requested} = IncidentRooms.request(request(fixture))
    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get_by!(IncidentRoom, ref: room_ref)
    archived_at = deleted_at(room)
    posted_before = Agent.get(agent, & &1.posts)

    assert {:ok, %{status: :applied}} =
             IncidentRooms.observe_lifecycle(
               lifecycle(room, :archived, "Ev-incident-archived-first", archived_at)
             )

    assert {:ok, {:ready, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    episode = Repo.get!(Episode, room.episode_id)

    assert %Turn{status: :blocked, coop_turn_id: nil} =
             Repo.get_by!(Turn, episode_id: episode.id, turn_ref: episode.owner_ref)

    # While the room is archived the task waits for it, and says so.
    assert {:ok, paused} = FailureProjection.fetch("work", episode.key)
    assert inspect(FailureExplanation.explain(paused)) =~ "active again"

    assert {:ok, %{status: :applied}} =
             IncidentRooms.observe_lifecycle(
               lifecycle(
                 room,
                 :deleted,
                 "Ev-incident-archived-deleted",
                 DateTime.add(archived_at, 1, :second)
               )
             )

    # Deleted, it never reads as waiting for a room that cannot come back.
    assert {:ok, closing} = FailureProjection.fetch("work", episode.key)
    refute inspect(FailureExplanation.explain(closing)) =~ "active again"

    assert {:ok, {:closed, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    assert Repo.get!(Episode, room.episode_id).state == :cancelled
    assert FailureProjection.fetch("work", episode.key) == :not_found

    assert [{"C456", "1787832000.000100", %{"message" => note}, _ref}] =
             Agent.get(agent, & &1.posts) -- posted_before

    assert note ==
             "The incident room ##{room.channel_name} was deleted. Reply here to pick it up."
  end

  # Without a publisher there is nobody to post through; the room and its
  # request still close rather than wait for one.
  test "a deleted room with no publisher configured closes without a note" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()

    assert {:ok, _requested} = IncidentRooms.request(request(fixture))
    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get_by!(IncidentRoom, ref: room_ref)
    posted_before = Agent.get(agent, & &1.posts)

    assert {:ok, %{status: :applied}} =
             IncidentRooms.observe_lifecycle(
               lifecycle(room, :deleted, "Ev-incident-deleted-unpublished", deleted_at(room))
             )

    assert {:ok, {:closed, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    assert Repo.get!(Episode, room.episode_id).state == :cancelled
    assert Agent.get(agent, & &1.posts) == posted_before
  end

  # Once the investigation is closed the note is all that is left. Slack
  # being unreachable for a moment must not lose it or post it twice.
  test "a deleted room's note waits out a Slack outage and is posted once" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()
    publish_through_slack!(agent)

    assert {:ok, _requested} = IncidentRooms.request(request(fixture))
    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get_by!(IncidentRoom, ref: room_ref)
    note_ref = "incident-room:#{room.ref}:deleted"
    posted_before = Agent.get(agent, & &1.posts)

    Agent.update(
      agent,
      &Map.put(&1, :post_errors, %{note_ref => {:slack_http_error, 503, "unavailable"}})
    )

    assert {:ok, %{status: :applied}} =
             IncidentRooms.observe_lifecycle(
               lifecycle(room, :deleted, "Ev-incident-deleted-outage", deleted_at(room))
             )

    assert {:ok, {:deferred, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    assert Repo.get!(IncidentRoom, room.id).status == :ready
    assert Repo.get!(Episode, room.episode_id).state == :cancelled
    assert Agent.get(agent, & &1.posts) == posted_before

    Agent.update(agent, &Map.put(&1, :post_errors, %{}))
    make_room_retryable!(room.id)
    assert {:ok, {:closed, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    assert [{"C456", "1787832000.000100", %{"message" => _note}, ^note_ref}] =
             Agent.get(agent, & &1.posts) -- posted_before
  end

  # A refusal no retry can change, here because Ryker is no longer in the
  # alert channel, must not hold the room, and its place in the open-room
  # limit, open for good. The room closes and records why nothing was said.
  test "a deleted room whose note Slack refuses for good still closes" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()
    publish_through_slack!(agent)

    assert {:ok, _requested} =
             IncidentRooms.request(%{request(fixture) | maximum_open_rooms: 1})

    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get_by!(IncidentRoom, ref: room_ref)
    note_ref = "incident-room:#{room.ref}:deleted"

    Agent.update(
      agent,
      &Map.put(&1, :post_errors, %{note_ref => {:slack_api_error, "not_in_channel"}})
    )

    assert {:ok, %{status: :applied}} =
             IncidentRooms.observe_lifecycle(
               lifecycle(room, :deleted, "Ev-incident-deleted-refused", deleted_at(room))
             )

    assert {:ok, {:closed, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    closed = Repo.get!(IncidentRoom, room.id)
    assert closed.status == :closed
    assert closed.last_error_code == "incident_room_deleted"
    assert closed.last_error_detail =~ "not_in_channel"
    assert Repo.get!(Episode, room.episode_id).state == :cancelled

    assert {:ok, %{status: :requested}} =
             IncidentRooms.request(%{request(delivered_offer!()) | maximum_open_rooms: 1})
  end

  # An answer accepted just as its room was deleted was owed to a channel Slack
  # never brings back. The kernel rightly closes no request under an accepted
  # reply, so the request stayed paused for good, the answer reached nobody,
  # and Failures listed a blocked reply with a generic cause. The answer now
  # goes, word for word, to the alert thread the room was opened from, and the
  # room's note follows it there, each exactly once.
  test "a reply finished for a deleted room reaches the alert thread instead of being lost" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()
    publish_through_slack!(agent)

    assert {:ok, _requested} =
             IncidentRooms.request(%{request(fixture) | maximum_open_rooms: 1})

    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get_by!(IncidentRoom, ref: room_ref)
    reply = accept_investigation_reply!(room, @finished_answer)
    assert reply.delivery_target["conversation_ref"] == "slack:T123:#{room.channel_ref}"
    posted_before = Agent.get(agent, & &1.posts)

    assert {:ok, %{status: :applied}} =
             IncidentRooms.observe_lifecycle(
               lifecycle(room, :deleted, "Ev-incident-deleted-with-reply", deleted_at(room))
             )

    # The room waits for its reply instead of closing over it.
    assert {:ok, {:deferred, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    assert Repo.get!(IncidentRoom, room.id).status == :ready
    assert Agent.get(agent, & &1.posts) == posted_before

    # The reply goes out through the ordinary delivery lane. Slack posts it but
    # its answer is lost, and the retry finds that post instead of posting again.
    Agent.update(
      agent,
      &Map.put(&1, :post_errors, %{reply.delivery_ref => {:answer_lost, :timeout}})
    )

    assert {:ok, {:deferred, :message, delivery_ref, _uncertain}} =
             Dispatcher.run_once(delivery_options(agent))

    assert delivery_ref == reply.delivery_ref

    # The note never goes ahead of the reply.
    make_room_retryable!(room.id)
    assert {:ok, {:deferred, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    make_reply_retryable!(reply.id)

    assert {:ok, {:delivered, :message, ^delivery_ref}} =
             Dispatcher.run_once(delivery_options(agent))

    make_room_retryable!(room.id)
    assert {:ok, {:closed, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    note = "The incident room ##{room.channel_name} was deleted. Reply here to pick it up."

    assert Agent.get(agent, & &1.posts) -- posted_before == [
             {"C456", "1787832000.000100", %{"message" => @finished_answer["message"]},
              delivery_ref},
             {"C456", "1787832000.000100", %{"message" => note},
              "incident-room:#{room.ref}:deleted"}
           ]

    assert %Turn{status: :settled, delivery_document: @finished_answer} =
             Repo.get!(Turn, reply.id)

    assert Repo.get!(Episode, room.episode_id).state == :complete
    assert Repo.get!(IncidentRoom, room.id).status == :closed

    # Nothing is left to do, and a later pass of either lane posts nothing.
    assert IncidentRoomWorker.run_once(worker_options(agent)) == {:ok, :idle}
    assert Dispatcher.run_once(delivery_options(agent)) == {:ok, :idle}
    assert length(Agent.get(agent, & &1.posts)) == length(posted_before) + 2
    assert FailureProjection.fetch("delivery", delivery_ref) == :not_found

    assert {:ok, %{status: :requested}} =
             IncidentRooms.request(%{request(delivered_offer!()) | maximum_open_rooms: 1})
  end

  # When the alert thread refuses the moved reply for good, here because Ryker
  # was removed from the alert channel, the room still closes and records why,
  # but the answer is never thrown away: it stays owed, Failures lists it as a
  # reply for the alert thread, and a retry posts it there.
  test "a moved reply the alert thread refuses stays owed and its room still closes" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()
    publish_through_slack!(agent)

    assert {:ok, _requested} =
             IncidentRooms.request(%{request(fixture) | maximum_open_rooms: 1})

    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get_by!(IncidentRoom, ref: room_ref)
    reply = accept_investigation_reply!(room, @finished_answer)
    note_ref = "incident-room:#{room.ref}:deleted"
    posted_before = Agent.get(agent, & &1.posts)

    assert {:ok, %{status: :applied}} =
             IncidentRooms.observe_lifecycle(
               lifecycle(room, :deleted, "Ev-incident-deleted-reply-refused", deleted_at(room))
             )

    assert {:ok, {:deferred, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    Agent.update(
      agent,
      &Map.put(&1, :post_errors, %{
        reply.delivery_ref => {:slack_api_error, "not_in_channel"},
        note_ref => {:slack_api_error, "not_in_channel"}
      })
    )

    assert {:ok, {:blocked, :message, delivery_ref, _refused}} =
             Dispatcher.run_once(delivery_options(agent))

    make_room_retryable!(room.id)
    assert {:ok, {:closed, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    closed = Repo.get!(IncidentRoom, room.id)
    assert closed.status == :closed
    assert closed.last_error_code == "incident_room_deleted"
    assert closed.last_error_detail =~ "reply could not be posted (not_in_channel)"
    assert Agent.get(agent, & &1.posts) == posted_before

    # The answer is kept, still owed, and now owed to the alert thread.
    owed = Repo.get!(Turn, reply.id)
    assert owed.status == :blocked
    assert owed.delivery_document == @finished_answer

    assert owed.delivery_target == %{
             "conversation_ref" => "slack:T123:C456",
             "thread_ref" => "1787832000.000100",
             "transport" => "slack"
           }

    assert %Episode{state: :working, owner_kind: :delivery} = Repo.get!(Episode, room.episode_id)

    # Failures names the alert thread, never the room that cannot come back.
    assert {:ok, row} = FailureProjection.fetch("delivery", delivery_ref)
    assert row.destination == "slack:T123:C456 / 1787832000.000100"
    explanation = FailureExplanation.explain(row)
    assert Enum.any?(explanation.happened, &(&1 =~ "##{room.channel_name}, which was deleted"))
    refute inspect(explanation) =~ "active again"
    refute inspect(explanation) =~ "room is active"
    refute inspect(explanation) =~ "Unarchive"

    # Once Ryker can post there again, a retry posts it there, word for word.
    Agent.update(agent, &Map.put(&1, :post_errors, %{}))
    assert {:ok, _rearmed} = DeliveryOperator.rearm(delivery_ref)

    assert {:ok, {:delivered, :message, ^delivery_ref}} =
             Dispatcher.run_once(delivery_options(agent))

    assert Agent.get(agent, & &1.posts) -- posted_before == [
             {"C456", "1787832000.000100", %{"message" => @finished_answer["message"]},
              delivery_ref}
           ]

    assert FailureProjection.fetch("delivery", delivery_ref) == :not_found

    # A finished answer ends the investigation once it is posted.
    assert Repo.get!(Episode, room.episode_id).state == :complete
    assert IncidentRoomWorker.run_once(worker_options(agent)) == {:ok, :idle}

    assert {:ok, %{status: :requested}} =
             IncidentRooms.request(%{request(delivered_offer!()) | maximum_open_rooms: 1})
  end

  # A reply that asks a question waits for the answer once it is posted. When
  # it was owed to a room Slack deleted, the alert thread refused it, and a
  # person later posted it from the Failures page, the investigation went on
  # waiting for an answer in a room that no longer exists: the room had closed
  # already, so nothing looked at it again, and it stayed open for good.
  test "a reply posted from Failures for a deleted room closes its investigation" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()
    publish_through_slack!(agent)

    assert {:ok, _requested} = IncidentRooms.request(request(fixture))
    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get_by!(IncidentRoom, ref: room_ref)
    reply = ask_investigation_question!(room)
    note_ref = "incident-room:#{room.ref}:deleted"

    assert {:ok, %{status: :applied}} =
             IncidentRooms.observe_lifecycle(
               lifecycle(room, :deleted, "Ev-incident-deleted-question", deleted_at(room))
             )

    assert {:ok, {:deferred, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    Agent.update(
      agent,
      &Map.put(&1, :post_errors, %{
        reply.delivery_ref => {:slack_api_error, "not_in_channel"},
        note_ref => {:slack_api_error, "not_in_channel"}
      })
    )

    assert {:ok, {:blocked, :message, delivery_ref, _refused}} =
             Dispatcher.run_once(delivery_options(agent))

    make_room_retryable!(room.id)
    assert {:ok, {:closed, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    assert Repo.get!(IncidentRoom, room.id).status == :closed

    # A person posts the reply from Failures once Ryker can post there again.
    Agent.update(agent, &Map.put(&1, :post_errors, %{}))
    assert {:ok, _rearmed} = DeliveryOperator.rearm(delivery_ref)

    assert {:ok, {:delivered, :message, ^delivery_ref}} =
             Dispatcher.run_once(delivery_options(agent))

    posted = Agent.get(agent, & &1.posts)

    # Nobody can answer in a room that is gone: the investigation closes the
    # way the room's deletion closes one, saying why.
    assert {:ok, {:closed, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    assert %Episode{state: :cancelled} = episode = Repo.get!(Episode, room.episode_id)
    assert cancellation_reason(episode) =~ "##{room.channel_name} was deleted"
    assert FailureProjection.fetch("work", episode.key) == :not_found

    # The room stays closed, nothing more is posted, and a later pass is idle.
    assert Repo.get!(IncidentRoom, room.id).status == :closed
    assert IncidentRoomWorker.run_once(worker_options(agent)) == {:ok, :idle}
    assert Agent.get(agent, & &1.posts) == posted
  end

  # Slack refuses a post in a room it deleted, and the reply's lane can reach
  # it before the room's lane does. Failures then said the reply "fails until
  # the room is active and Ryker is in it again", for a room that never comes
  # back. It says Ryker moves the reply on its own, and lists it no longer
  # once the reply is on its way to the alert thread.
  test "a reply refused in its deleted room reads as moving to the alert thread, never as waiting for the room" do
    fixture = delivered_offer!()
    save_channel_configuration!()
    agent = incident_agent!()
    publish_through_slack!(agent)

    assert {:ok, _requested} = IncidentRooms.request(request(fixture))
    assert {:ok, {:ready, room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    room = Repo.get_by!(IncidentRoom, ref: room_ref)
    reply = accept_investigation_reply!(room, @finished_answer)

    assert {:ok, %{status: :applied}} =
             IncidentRooms.observe_lifecycle(
               lifecycle(room, :deleted, "Ev-incident-deleted-reply-first", deleted_at(room))
             )

    assert {:ok, {:blocked, :message, delivery_ref, {:slack_incident_room_inactive, :deleted}}} =
             Dispatcher.run_once(delivery_options(agent))

    assert {:ok, row} = FailureProjection.fetch("delivery", delivery_ref)
    explanation = FailureExplanation.explain(row)
    assert explanation.outlook == :automatic
    assert inspect(explanation) =~ "alert thread"
    refute inspect(explanation) =~ "active again"
    refute inspect(explanation) =~ "room is active"
    refute inspect(explanation) =~ "Unarchive"

    assert {:ok, {:deferred, ^room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))
    assert FailureProjection.fetch("delivery", delivery_ref) == :not_found
    assert %Turn{status: :delivery_pending} = Repo.get!(Turn, reply.id)
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

    # Only the working repository runs under the incident policy; the frozen
    # companion stays readable without becoming a writable task target.
    incident = %{policy: "incident-investigate", policy_digest: @policy_digest}
    classes = %{conversational: incident, deep: incident, standard: incident}

    assert settings.work_profile.("T123", conversation_ref) ==
             {:ok,
              %{
                environment_ref: "production",
                parallel_goal_limit: 2,
                policies: %{"ryker" => classes},
                policy: "incident-investigate",
                policy_digest: @policy_digest,
                repositories: ["ryker", "docs"],
                repository_ref: "ryker"
              }}

    operator_input = %{
      actor: %{kind: :user, ref: "U123"},
      destination: %{conversation_ref: conversation_ref},
      source: %{ref: "T123"}
    }

    assert settings.conversation_actor_allowed.(operator_input) == {:ok, true}
    assert settings.setup_allowed.("T123", conversation_ref) == {:ok, false}

    # A room invited its responders, then heard only the operators among them,
    # though anyone may talk to Ryker (Andrew, 2026-09-26; 2026-10-04 review).
    # An app's posts there are not the investigation's.
    teammate_input = put_in(operator_input, [:actor, :ref], "U200")
    app_input = %{operator_input | actor: %{kind: :app, ref: "A123"}}
    assert settings.conversation_actor_allowed.(teammate_input) == {:ok, true}
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

  # An incident offer may carry a brief of 32,000 characters, but a room kept
  # at most 4,000, so an offer with a longer brief could never get its room:
  # pressed, it failed; offered automatically, it failed every second and hid
  # every newer offer (2026-10-05).
  test "an incident offer with a long brief gets its room" do
    brief = String.duplicate("Check the payment gateway's error rate by region. ", 120)
    fixture = delivered_offer!(:user, prompt: brief)
    save_channel_configuration!()

    assert {:ok, %{status: :requested, room: room}} = IncidentRooms.request(request(fixture))
    assert String.length(room.prompt) > 4_000
    assert room.prompt == fixture.record.payload["prompt"]
  end

  test "automatic alert policy opens only a delivered external-app incident offer" do
    _human_offer = delivered_offer!(:user)
    save_channel_configuration!(:automatic)
    agent = incident_agent!()

    options = automatic_options(agent)
    assert IncidentRoomWorker.run_once(options) == {:ok, :idle}
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

  # With the open-room limit full, an automatic offer's request failed every
  # second, and each failure was logged (2026-10-04 review). A full limit is
  # nothing to do until a room closes.
  test "a full room limit leaves an automatic offer waiting, not failing every second" do
    save_channel_configuration!(:automatic)
    agent = incident_agent!()
    _app_offer = delivered_offer!(:app)

    # One room is open and checked: the limit is full and the room needs nothing.
    assert {:ok, %{status: :requested}} = IncidentRooms.request(request(delivered_offer!()))
    assert {:ok, {:ready, _room_ref}} = IncidentRoomWorker.run_once(worker_options(agent))

    Repo.update_all(IncidentRoom,
      set: [channel_checked_at: Repo.now!(), root_card_checked_at: Repo.now!()]
    )

    options = automatic_options(agent, maximum_open_rooms: 1)

    log = capture_log(fn -> assert IncidentRoomWorker.run_once(options) == {:ok, :idle} end)
    refute log =~ "incident_room_capacity"
  end

  # An automatic offer whose room could not be made was asked for again every
  # second, logged each time, and, being the oldest, hid every newer offer from
  # the worker (2026-10-04 review).
  test "an automatic offer refused its room is logged once and stops hiding newer offers" do
    save_channel_configuration!(:automatic)
    agent = incident_agent!()
    refused = delivered_offer!(:app)
    newer = delivered_offer!(:app)

    # Its brief is gone, so no room can be made from it.
    Repo.update_all(from(record in Record, where: record.id == ^refused.record.id),
      set: [payload: Map.put(refused.record.payload, "prompt", "")]
    )

    options = automatic_options(agent)
    refused_ref = refused.record.ref

    log =
      capture_log(fn ->
        assert {:ok, {:refused, ^refused_ref}} = IncidentRoomWorker.run_once(options)
      end)

    assert log =~ "could not open an incident room for #{refused_ref} automatically"

    log =
      capture_log(fn ->
        assert {:ok, {:requested, room_ref}} = IncidentRoomWorker.run_once(options)
        assert Repo.get_by!(IncidentRoom, ref: room_ref).record_id == newer.record.id
      end)

    refute log =~ refused_ref
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

  # The card cut a goal's words to 200 characters and the renderer allows 200
  # bytes, so a goal written in Ukrainian, or with a few emoji, made Slack's
  # renderer refuse the whole card and the room's pinned status stopped
  # updating. The task card has cut in bytes since 2026-10-04; this card kept a
  # copy of the old cut (found 2026-10-08).
  test "an incident card's words fit the bounds its renderer checks, in any language" do
    save_channel_configuration!()
    room = ready_room!("card-bytes")
    assert {:ok, claim} = Custody.claim_next("incident-card:bytes", 60, :work)
    outcome = String.duplicate("Перевірити сервіс ", 9)

    assert {:ok, _goal} =
             Records.create(Records.token(claim.turn), "scope", "goal", %{
               "authority" => "read_only",
               "completion_contract" => "The affected service is named from a current signal.",
               "id" => "confirm-scope",
               "kind" => "check",
               "requested_outcome" => outcome,
               "required" => true,
               "stage" => "planning"
             })

    assert {:ok, projection} = IncidentRoomCard.build(Repo.get!(IncidentRoom, room.room.id))
    assert {:ok, _card} = Renderer.WorkCards.incident_room(projection.document["incident_room"])
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

    # The 2026-09-12 coverage measurement: an incident card carried a prose
    # summary and no ledger, on the one surface where "what have we actually
    # established" is the whole question. The task card has had this since
    # 405e9443.
    assert {:ok, _goal} =
             Records.create(Records.token(claim.turn), "scope", "goal", %{
               "authority" => "read_only",
               "completion_contract" => "The affected service is named from a current signal.",
               "id" => "confirm-scope",
               "kind" => "check",
               "requested_outcome" => "Confirm which service is affected",
               "required" => true,
               "stage" => "planning"
             })

    assert {:ok, _state} =
             Records.create(Records.token(claim.turn), "scope-done", "goal_state", %{
               "detail" => "Checkout is the affected service.",
               "goal_id" => "confirm-scope",
               "state" => "completed"
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

    assert card["goals"] == [
             %{
               "detail" => "Checkout is the affected service.",
               "id" => "confirm-scope",
               "outcome" => "Confirm which service is affected",
               "state" => "completed"
             }
           ]

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
               "event_matcher" => %{"deployment" => "ryker"},
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
    assert {:ok, _rendered} = Renderer.render(provisioning.document)

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

    pid = start_supervised!({IncidentRoomWorker, Map.merge(options, %{interval_ms: 50})})

    assert Process.alive?(pid)
  end

  # The alert channel's saved setting, with No environment chosen since the
  # alert's conversation ran: a room follows that conversation, not this.
  defp save_channel_configuration!(alert_policy \\ :offer) do
    attributes = %{
      actor_ref: "U123",
      alert_policy: alert_policy,
      channel_ref: "C456",
      environment_ref: nil,
      id: Ecto.UUID.generate(),
      invite_user_group_refs: ["SRE"],
      invite_user_refs: ["U200"],
      participation: :proactive,
      revision: 1,
      saved_at: @now,
      workspace_ref: "T123"
    }

    attributes
    |> ChannelConfiguration.Changeset.insert()
    |> Repo.insert!()
  end

  defp sleeping_worker_options(agent) do
    agent
    |> worker_options()
    |> Map.merge(%{idle_interval_ms: 300_000, interval_ms: 300_000, name: nil})
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

  # Host notes go through the delivery adapters every reply uses: here
  # Slack's own publisher, over this test's Slack.
  defp publish_through_slack!(agent) do
    Config.put_override(:delivery, %{adapters: slack_registrations(agent)})
  end

  defp slack_registrations(agent) do
    %{
      "slack" => %{
        binding: %{
          destination_allowed: &IncidentRooms.delivery_allowed/2,
          workspaces: %{"T123" => %{api: API, client: agent}}
        },
        message_publisher: Ryker.Slack.Publisher,
        reaction_publisher: Ryker.Slack.Publisher
      }
    }
  end

  # The lane that posts every accepted reply, over the same Slack.
  defp delivery_options(agent) do
    assert {:ok, adapters} = Adapters.new(slack_registrations(agent))

    [
      adapters: adapters,
      kind: :message,
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "incident-room-delivery"
    ]
  end

  defp make_reply_retryable!(turn_id) do
    Repo.update_all(from(turn in Turn, where: turn.id == ^turn_id), set: [next_attempt_at: @now])
  end

  defp deleted_at(room), do: DateTime.add(room.channel_state_changed_at, 1, :second)

  defp cancellation_reason(episode) do
    Repo.one!(
      from(event in Event,
        where: event.episode_id == ^episode.id and event.kind == :episode_cancelled,
        select: event.payload
      )
    )
    |> Map.fetch!("reason")
  end

  # The investigation's first run, on a worker: a bound session and turn.
  defp start_investigation_run!(room) do
    assert {:ok, claim} = Custody.claim_next("work:incident-room", 60, :work)
    assert claim.episode.id == room.episode_id

    assert {:ok, submission} =
             Submission.new(
               %{"request" => "Investigate checkout errors."},
               "Investigate the incident.",
               %{"type" => "object"},
               "work-final-live-v3"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:incident-room:#{room.id}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:incident-room:#{room.id}"
             )

    %{episode: claim.episode, lease_ref: claim.lease_ref, session: session, turn: turn}
  end

  # The investigation's run finishes: its answer is accepted for the room and
  # waits for the delivery lane, posted nowhere yet.
  defp accept_investigation_reply!(room, document) do
    room
    |> start_investigation_run!()
    |> accept_reply!(room, document, %{"kind" => "complete"})
  end

  defp accept_reply!(running, room, document, continuation) do
    candidate = Jason.encode!(document)
    sha256 = digest(candidate)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               running.episode.id,
               running.turn.turn_ref,
               running.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               1
             )

    assert {:ok, result} = Result.new(:reply, document, nil, continuation)

    assert {:ok, _turn} =
             Custody.prepare_validation(
               running.episode.id,
               running.turn.turn_ref,
               running.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    assert {:ok, %{episode: %Episode{owner_kind: :delivery}, turn: turn}} =
             Custody.accept_result(
               running.episode.id,
               running.episode.key,
               running.turn.turn_ref,
               running.lease_ref,
               sha256,
               1,
               "validation-receipt:#{room.ref}"
             )

    turn
  end

  # The investigation's run finishes by asking a question: its reply waits for
  # the answer once it is posted, and waits for the delivery lane first.
  defp ask_investigation_question!(room) do
    running = start_investigation_run!(room)

    assert {:ok, question} =
             Records.create(Records.token(running.turn), "question", "input_request", %{
               "choices" => ["rollback", "continue"],
               "question" => "Should we roll back the checkout deployment?"
             })

    document = %{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" =>
        "Checkout errors started with the last deployment. Should we roll back the checkout deployment?",
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [question.ref],
        "state" => "waiting_for_input"
      }
    }

    continuation = %{
      "deadline_at" => nil,
      "kind" => "wait",
      "wait_kind" => "input",
      "wait_ref" => question.ref
    }

    accept_reply!(running, room, document, continuation)
  end

  # The investigation asks the room a question and waits for the answer.
  defp wait_for_an_answer!(episode) do
    assert {:ok, claim} = Custody.claim_next("incident-room:waiting", 60, :work)
    assert claim.episode.id == episode.id

    assert {:ok, question} =
             Records.create(Records.token(claim.turn), "question", "input_request", %{
               "choices" => ["rollback", "continue"],
               "question" => "Should we roll back the checkout deployment?"
             })

    assert {:ok, %{episode: %Episode{state: :waiting_for_input}}} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 episode_key: episode.key,
                 expected_turn_ref: episode.owner_ref,
                 occurred_at: DateTime.add(@now, 5, :second),
                 wait_ref: question.ref
               })
             )
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
    episode = Repo.get!(Ryker.Episodes.Episode, room.episode_id)
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
        finch: Ryker.CoopFinch,
        receive_timeout: 1_000,
        token_provider: fn -> {:ok, "xoxb-test"} end
      })

    {:ok, client} = Client.new(http: http, requester: JSONClient)

    %{
      app_http: http,
      bot_client: client,
      default_environment: nil,
      environments: %{},
      identity: %{bot_ref: "B123", bot_user_ref: "U999", workspace_ref: "T123"},
      incident_policy: %{digest: @policy_digest, name: "incident-investigate"},
      operators: ["U123"],
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

  # The worker's automatic request as the runtime wires it.
  defp automatic_options(agent, settings \\ []) do
    settings =
      Map.merge(
        %{
          bot_user_ref: "U-BOT",
          channel_prefix: "ems",
          invite_user_refs: ["U123", "U300"],
          maximum_open_rooms: 25,
          policy: %{digest: @policy_digest, name: "incident-investigate"},
          private: true
        },
        Map.new(settings)
      )

    Map.put(
      worker_options(agent),
      :automatic_request,
      &IncidentRooms.request_automatic("T123", settings, &1)
    )
  end

  defp delivered_offer!(actor_kind \\ :user, options \\ []) do
    repository = Keyword.get(options, :repository, "ryker")
    environment = Keyword.get(options, :environment, "production")
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

    # The alert's conversation runs in the production environment.
    assert {:ok, _session} =
             WorkSessions.pin_episode(episode_id, "ryker-read", String.duplicate("a", 64),
               repository_ref: repository,
               repository_context: if(repository, do: @source_context),
               environment_ref: environment
             )

    assert {:ok, claim} = Custody.claim_next("worker:incident-offer", 60, :work)

    payload =
      TaskOffer.payload(%{
        "kind" => "incident",
        "prompt" =>
          Keyword.get(options, :prompt, "Investigate checkout errors and coordinate responders."),
        "repository" => nil,
        "title" => "Checkout errors"
      })

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

    assert KnowledgeSnapshot.expose_submission(%{claim | turn: frozen_turn}) == :ok

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
    sha256 = digest(candidate)

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
