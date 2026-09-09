defmodule Responder.Admission.ContextTest do
  use Responder.DataCase, async: true

  @moduletag isolation: "REPEATABLE READ"

  import Ecto.Query

  alias Responder.Admission
  alias Responder.Admission.{Context, Decision}
  alias Responder.Episodes
  alias Responder.Episodes.Command
  alias Responder.Ingress.{Inbox, Input}
  alias Responder.Repo
  alias Responder.Slack.Input, as: SlackInput

  @now ~U[2026-08-27 12:00:00.000000Z]
  @current_thread "1787832000.000100"

  test "addressing is frozen from the receipt and restored independently of current entry metadata" do
    assert {:ok, %{entry: entry}} =
             Inbox.record(input!([]), slack_audience: :ambient, slack_bot_user_ref: "UBOT")

    assert {:ok, context} = build_context(entry)
    expected = %{"audience" => "ambient", "responder_user_ref" => "UBOT"}
    assert Context.for_model(context)["slack_addressing"] == expected
    snapshot = Context.snapshot(context)
    assert snapshot["slack_addressing"] == expected

    changed_entry =
      entry |> Map.put(:slack_audience, :mention) |> Map.put(:slack_bot_user_ref, "UNEWBOT")

    assert {:ok, restored} = Context.restore(snapshot, context.input, changed_entry, %{})
    assert Context.for_model(restored) == Context.for_model(context)
    assert Context.snapshot(restored) == snapshot

    absent = Map.delete(snapshot, "slack_addressing")
    assert {:ok, old} = Context.restore(absent, context.input, changed_entry, %{})
    refute Map.has_key?(Context.for_model(old), "slack_addressing")
    assert Context.snapshot(old) == absent
  end

  test "malformed present addressing snapshots cannot be silently treated as absent" do
    assert {:ok, context} = build_context(record_input!())
    snapshot = Context.snapshot(context)

    for invalid <- [
          nil,
          %{},
          %{"audience" => "mention"},
          %{"audience" => "mention", "responder_user_ref" => nil},
          %{"audience" => "unknown", "responder_user_ref" => "UBOT"},
          %{"audience" => "direct", "responder_user_ref" => "U-bot"},
          %{"audience" => "direct", "responder_user_ref" => String.duplicate("U", 257)},
          %{"audience" => "mention", "responder_user_ref" => "UBOT", "authority" => "write"}
        ] do
      assert {:error, {:invalid_admission_context_snapshot, :slack_addressing}} =
               Context.restore(
                 Map.put(snapshot, "slack_addressing", invalid),
                 context.input,
                 context.input_entry,
                 %{}
               )
    end

    other_input = %{context.input | source: %{kind: "webhook", ref: "other"}}

    assert {:error, {:invalid_admission_context_snapshot, :slack_addressing}} =
             Context.restore(
               Map.put(snapshot, "slack_addressing", %{
                 "audience" => "ambient",
                 "responder_user_ref" => "UBOT"
               }),
               other_input,
               context.input_entry,
               %{}
             )
  end

  test "offers generic same-work and history candidates without inspecting provider text" do
    current = record_input!(content: %{"text" => "A custom app changed state"})

    same_thread =
      create_episode!(
        key: "same-thread",
        thread_ref: @current_thread,
        content: %{"text" => "This could be any earlier human or app message"},
        complete: true,
        updated_at: DateTime.add(@now, -40 * 24 * 60 * 60)
      )

    recent_other_thread =
      create_episode!(
        key: "recent-other-thread",
        thread_ref: "1787831000.000001",
        content: %{"text" => "No provider-specific status words here"},
        complete: true,
        updated_at: DateTime.add(@now, -5 * 60)
      )

    expired_other_thread =
      create_episode!(
        key: "expired-other-thread",
        thread_ref: "1787830000.000001",
        content: %{"text" => "Related historical work"},
        complete: true,
        updated_at: DateTime.add(@now, -2 * 60 * 60)
      )

    other_channel =
      create_episode!(
        key: "other-channel",
        channel_ref: "C999",
        thread_ref: "1787833000.000001",
        content: %{"text" => "Must remain invisible to this admission decision"}
      )

    assert {:ok, context} = build_context(current)
    candidates = Map.new(context.candidates, &{&1.episode.id, &1})

    assert candidates[same_thread.id].allowed_relations == [:same_work, :history_only]
    assert candidates[same_thread.id].same_thread

    assert candidates[recent_other_thread.id].allowed_relations == [
             :same_work,
             :history_only
           ]

    assert candidates[expired_other_thread.id].allowed_relations == [:history_only]
    refute Map.has_key?(candidates, other_channel.id)

    model_context = Context.for_model(context)

    model_same_thread =
      Enum.find(
        model_context["candidates"],
        &(&1["episode_ref"] == candidates[same_thread.id].ref)
      )

    assert model_same_thread["state"] == "complete"
    encoded = Jason.encode!(model_context)

    refute encoded =~ same_thread.id
    refute encoded =~ same_thread.key
    refute encoded =~ recent_other_thread.destination_thread_ref
    assert encoded =~ "This could be any earlier human or app message"
  end

  test "active work from the same Slack app remains a continuation candidate" do
    current = record_input!()

    active =
      create_episode!(
        key: "still-active",
        thread_ref: "1787820000.000001",
        content: %{"text" => "Long-running work"},
        updated_at: DateTime.add(@now, -10 * 24 * 60 * 60)
      )

    assert {:ok, context} = build_context(current)
    candidate = Enum.find(context.candidates, &(&1.episode.id == active.id))

    assert candidate.allowed_relations == [:same_work, :history_only]
  end

  test "a human Slack root cannot silently continue work in another thread" do
    current = record_input!(actor: %{kind: :user, ref: "U123"})

    other_thread =
      create_episode!(
        key: "human-root-other-thread",
        thread_ref: "1787820000.000002",
        content: %{"text" => "Existing work in another visible Slack thread"}
      )

    assert {:ok, context} = build_context(current)
    candidate = Enum.find(context.candidates, &(&1.episode.id == other_thread.id))

    assert candidate.allowed_relations == [:history_only]
    refute candidate.same_thread
  end

  test "a Slack app can cross threads only through its exact source lifecycle" do
    current = record_input!(revision: 2)

    unrelated =
      create_episode!(
        key: "app-root-other-thread",
        thread_ref: "1787820000.000010",
        content: %{"text" => "Unrelated writable work in another Slack thread"},
        actor: %{kind: :app, ref: "B999"}
      )

    owner =
      create_episode!(
        key: "app-source-owner",
        thread_ref: "1787820000.000011",
        content: %{"text" => "Earlier revision of this exact source lifecycle"},
        native_input_id: current.native_input_id
      )

    assert {:ok, context} = build_context(current)
    candidates = Map.new(context.candidates, &{&1.episode.id, &1})

    assert candidates[unrelated.id].allowed_relations == [:history_only]
    assert candidates[owner.id].allowed_relations == [:same_work, :history_only]
  end

  test "a human shared-channel thread reply can continue only its exact thread" do
    current =
      record_input!(
        actor: %{kind: :user, ref: "U123"},
        message_ref: "1787832001.000200",
        thread_ref: @current_thread
      )

    exact =
      create_episode!(
        key: "human-exact-thread",
        thread_ref: @current_thread,
        content: %{"text" => "Work in the exact visible Slack thread"}
      )

    other =
      create_episode!(
        key: "human-different-thread",
        thread_ref: "1787820000.000002",
        content: %{"text" => "Unrelated active work in another Slack thread"}
      )

    assert {:ok, context} = build_context(current)
    candidates = Map.new(context.candidates, &{&1.episode.id, &1})

    assert candidates[exact.id].allowed_relations == [:same_work, :history_only]
    assert candidates[exact.id].same_thread
    assert candidates[other.id].allowed_relations == [:history_only]
    refute candidates[other.id].same_thread
  end

  test "a direct-message root can continue only current active DM work" do
    current =
      record_input!(
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "D456",
        message_ref: "1787832002.000300"
      )

    active =
      create_episode!(
        key: "active-direct-message",
        channel_ref: "D456",
        thread_ref: "1787820000.000001",
        content: %{"text" => "The current DM task"}
      )

    completed =
      create_episode!(
        key: "completed-direct-message",
        channel_ref: "D456",
        thread_ref: "1787810000.000001",
        content: %{"text" => "An earlier completed DM task"},
        complete: true
      )

    assert {:ok, context} = build_context(current)
    candidates = Map.new(context.candidates, &{&1.episode.id, &1})

    assert candidates[active.id].allowed_relations == [:same_work, :history_only]
    assert candidates[completed.id].allowed_relations == [:history_only]
    refute candidates[active.id].same_thread
  end

  test "active work is never displaced by newer completed history" do
    current = record_input!()

    active =
      create_episode!(
        key: "old-active",
        thread_ref: "1787820000.000099",
        content: %{"text" => "Still-running work"},
        updated_at: DateTime.add(@now, -20 * 24 * 60 * 60)
      )

    for index <- 1..8 do
      create_episode!(
        key: "newer-complete-#{index}",
        thread_ref: "1787831000.#{String.pad_leading(Integer.to_string(index), 6, "0")}",
        content: %{"text" => "Completed history #{index}"},
        complete: true,
        updated_at: DateTime.add(@now, -index, :second)
      )
    end

    assert {:ok, context} = build_context(current)
    assert length(context.candidates) == 8
    assert Enum.any?(context.candidates, &(&1.episode.id == active.id))
  end

  test "top-level admission reports active candidate overflow instead of hiding work" do
    current = record_input!()

    for index <- 1..9 do
      create_episode!(
        key: "active-overflow-#{index}",
        thread_ref: "1787832001.#{String.pad_leading(Integer.to_string(index), 6, "0")}",
        content: %{"text" => "Active work #{index}"},
        updated_at: DateTime.add(@now, -index, :second)
      )
    end

    assert {:error, {:admission_context_overflow, required: 9, limit: 8}} =
             build_context(current)
  end

  test "unrelated active threads cannot block an input that cannot continue them" do
    # The Blitz replay retried this 386 times and held 255 later messages: every
    # mandatory candidate was actually history-only under the Slack thread fence.
    for index <- 1..21 do
      create_episode!(
        key: "history-only-active-#{index}",
        thread_ref: "1787831000.#{String.pad_leading(Integer.to_string(index), 6, "0")}",
        content: %{"text" => "Earlier work in another thread"}
      )
    end

    for actor <- [%{kind: :bot, ref: "B08N64XSHNU"}, %{kind: :user, ref: "U123"}] do
      current =
        record_input!(
          actor: actor,
          message_ref: "1787832000.#{if actor.kind == :bot, do: "000100", else: "000200"}"
        )

      assert {:ok, context} = build_context(current)
      assert length(context.candidates) == 8
      assert Enum.all?(context.candidates, &(&1.allowed_relations == [:history_only]))

      owner =
        create_episode!(
          key: "old-owner-#{actor.ref}",
          thread_ref: "1787830000.#{if actor.kind == :bot, do: "000100", else: "000200"}",
          native_input_id: current.native_input_id,
          content: %{"text" => "The original input's owner"},
          updated_at: DateTime.add(@now, -60 * 24 * 60 * 60, :second)
        )

      assert {:ok, with_owner} = build_context(current)
      assert hd(with_owner.candidates).episode.id == owner.id
      assert :same_work in hd(with_owner.candidates).allowed_relations

      if actor.kind == :bot do
        lifecycle =
          create_episode!(
            key: "older-bot-lifecycle",
            actor: actor,
            thread_ref: "1787820000.000001",
            content: %{"text" => "Earlier run from this exact source"},
            updated_at: DateTime.add(@now, -3600)
          )

        assert {:ok, with_lifecycle} = build_context(current)

        assert Enum.any?(
                 with_lifecycle.candidates,
                 &(&1.episode.id == lifecycle.id and :same_work in &1.allowed_relations)
               )
      end
    end
  end

  test "shadow episodes cannot consume live admission capacity" do
    current = record_input!()

    live =
      create_episode!(
        key: "live-capacity-owner",
        thread_ref: "1787832001.000001",
        content: %{"text" => "Live work that must remain selectable"}
      )

    for index <- 1..8 do
      create_episode!(
        key: "shadow-capacity-#{index}",
        thread_ref: "1787833000.#{String.pad_leading(Integer.to_string(index), 6, "0")}",
        content: %{"text" => "Observe-only work #{index}"},
        execution_mode: :shadow
      )
    end

    assert {:ok, context} = build_context(current)
    assert Enum.map(context.candidates, & &1.episode.id) == [live.id]
    assert Enum.all?(context.candidates, &(&1.episode.execution_mode == :live))
  end

  test "an exact thread remains admissible when unrelated active work fills the bound" do
    current = record_input!(thread_ref: @current_thread)

    create_episode!(
      key: "completed-exact-thread",
      thread_ref: @current_thread,
      content: %{"text" => "The current thread's completed work"},
      complete: true,
      updated_at: DateTime.add(@now, -60, :second)
    )

    for index <- 1..8 do
      create_episode!(
        key: "active-other-thread-#{index}",
        thread_ref: "1787833000.#{String.pad_leading(Integer.to_string(index), 6, "0")}",
        content: %{"text" => "Other active work #{index}"}
      )
    end

    assert {:ok, context} = build_context(current)
    assert length(context.candidates) == 8

    assert hd(context.candidates).episode.destination_thread_ref == @current_thread
    assert hd(context.candidates).same_thread
  end

  test "old completed cycles cannot permanently overflow an exact thread" do
    thread_ref = "1787830000.009999"

    for index <- 1..21 do
      create_episode!(
        key: "old-thread-cycle-#{index}",
        thread_ref: thread_ref,
        content: %{"text" => "Old completed cycle #{index}"},
        complete: true,
        updated_at: DateTime.add(@now, -index, :minute)
      )
    end

    current = record_input!(thread_ref: thread_ref)

    assert {:ok, context} = build_context(current)
    assert length(context.candidates) == 8
    assert Enum.all?(context.candidates, & &1.same_thread)
  end

  test "validates model choices only against the supplied opaque candidates" do
    current = record_input!()

    expired =
      create_episode!(
        key: "expired",
        thread_ref: "1787830000.000001",
        content: %{"text" => "Old completed work"},
        complete: true,
        updated_at: DateTime.add(@now, -2 * 60 * 60)
      )

    assert {:ok, context} = build_context(current)
    candidate = Enum.find(context.candidates, &(&1.episode.id == expired.id))

    assert {:ok, history_decision} =
             Decision.parse(%{
               "action" => "start_episode",
               "episode_ref" => candidate.ref,
               "reaction" => nil,
               "relation" => "history_only",
               "reason" => "The older work is useful history, but this is a new episode.",
               "work_class" => "standard"
             })

    assert {:ok, %{candidate: ^candidate}} = Admission.validate(context, history_decision)

    assert {:ok, continuation} =
             Decision.parse(%{
               "action" => "continue_episode",
               "episode_ref" => candidate.ref,
               "reaction" => nil,
               "relation" => "same_work",
               "reason" => "Continue the old work.",
               "work_class" => "standard"
             })

    assert {:error,
            {:admission_rejected, :relation_not_allowed,
             allowed: [:history_only], submitted: :same_work}} =
             Admission.validate(context, continuation)

    assert {:ok, unknown} =
             Decision.parse(%{
               "action" => "continue_episode",
               "episode_ref" => "candidate-not-offered",
               "reaction" => nil,
               "relation" => "same_work",
               "reason" => "Try an arbitrary reference.",
               "work_class" => "standard"
             })

    assert {:error, {:admission_rejected, :unknown_candidate}} =
             Admission.validate(context, unknown)
  end

  test "refuses to build a second model context after an input is decided" do
    entry = record_input!()

    Repo.update_all(
      from(stored in Responder.Ingress.Inbox.Entry, where: stored.id == ^entry.id),
      set: [
        decision_action: :ignore,
        decision_document: %{
          "action" => "ignore",
          "episode_ref" => nil,
          "reaction" => nil,
          "relation" => "unrelated",
          "reason" => "Exact duplicate.",
          "work_class" => nil
        },
        decision_fingerprint: String.duplicate("a", 64),
        decision_ref: "decision-1",
        status: :decided
      ]
    )

    assert {:error, {:input_already_decided, "decision-1"}} = build_context(entry)
  end

  test "returns the durable reason when an input is already blocked" do
    entry = record_input!()
    assert {:ok, %{lease_ref: lease_ref}} = Inbox.claim_next("executor:blocked", @now, 60)

    assert {:ok, blocked} =
             Inbox.block(
               Inbox.ref(entry),
               lease_ref,
               "operation_uncertain",
               "Coop cannot prove whether the mutation was accepted"
             )

    assert {:error,
            {:input_blocked, "operation_uncertain",
             "Coop cannot prove whether the mutation was accepted"}} = build_context(blocked)
  end

  test "candidate history fetches only chronological first and latest inputs" do
    episode =
      create_episode!(
        key: "bounded-endpoints",
        thread_ref: "1787830000.000001",
        content: %{"text" => "chronological first"}
      )

    for index <- 1..25 do
      admit_followup!(episode, "middle #{index}", DateTime.add(@now, -1_000 + index, :second))
    end

    admit_followup!(episode, "chronological latest", DateTime.add(@now, 120, :second))
    admit_followup!(episode, "delayed but committed last", DateTime.add(@now, 60, :second))

    assert %{first: first, latest: latest} =
             Admission.input_event_endpoints([episode.id])[episode.id]

    assert first.payload["payload"]["content"]["text"] == "chronological first"
    assert latest.payload["payload"]["content"]["text"] == "chronological latest"
    assert map_size(Admission.input_event_endpoints([episode.id])[episode.id]) == 2
  end

  test "equal occurrence timestamps retain durable event sequence" do
    episode =
      create_episode!(
        key: "equal-timestamp-order",
        thread_ref: "1787830000.000002",
        content: %{"text" => "chronological first"}
      )

    occurred_at = DateTime.add(@now, 120, :second)

    commands =
      for index <- 1..4 do
        input =
          input!(
            content: %{"text" => "same-time #{index}"},
            event_ref: "Ev-same-time-#{index}",
            message_ref: "1787832120.00000#{index}",
            occurred_at: occurred_at,
            thread_ref: episode.destination_thread_ref
          )

        %Command.AdmitInput{
          actor_ref: Input.actor_ref(input),
          destination: %{
            conversation_ref: episode.destination_conversation_ref,
            thread_ref: episode.destination_thread_ref,
            transport: episode.destination_transport
          },
          episode_id: episode.id,
          episode_key: episode.key,
          linked_episode_id: episode.linked_episode_id,
          native_input_id: input.native_input_id,
          occurred_at: occurred_at,
          payload: Input.document(input),
          revision: input.revision,
          turn_ref: "turn-same-time-#{index}"
        }
      end
      |> Enum.sort_by(&Command.dedupe_key/1, :desc)

    for command <- commands do
      assert {:ok, _transition} = Episodes.apply(command)
    end

    expected_latest = commands |> List.last() |> Command.document()

    assert %{latest: latest} = Admission.input_event_endpoints([episode.id])[episode.id]
    assert latest.payload == expected_latest
  end

  test "the frozen model context round-trips exactly and rejects corrupted snapshots" do
    episode =
      create_episode!(
        key: "frozen-context-round-trip",
        thread_ref: "1787830000.000777",
        content: %{"text" => "Earlier work visible to the admission turn"}
      )

    entry = record_input!()
    assert {:ok, context} = build_context(entry)
    snapshot = Context.snapshot(context)

    assert {:ok, [episode_id]} = Context.episode_ids(snapshot)
    assert episode_id == episode.id

    assert {:ok, restored} =
             Context.restore(snapshot, context.input, context.input_entry, %{
               episode.id => episode
             })

    assert Context.for_model(restored) == Context.for_model(context)
    assert Context.snapshot(restored) == snapshot

    assert {:error, {:invalid_admission_context_snapshot, :episode_ids}} =
             Context.episode_ids(%{"candidates" => [%{"episode_id" => "not-a-uuid"}]})

    assert {:error, {:invalid_admission_context_snapshot, :episode_ids}} =
             Context.episode_ids(:not_a_snapshot)

    assert {:error, {:invalid_admission_context_snapshot, :episode_ids}} =
             Context.episode_ids(%{"candidates" => [:not_a_candidate]})

    assert {:error, {:invalid_admission_context_snapshot, :document}} =
             Context.restore(
               Map.put(snapshot, "unexpected", true),
               context.input,
               context.input_entry,
               %{episode.id => episode}
             )

    assert {:error, {:invalid_admission_context_snapshot, :built_at}} =
             Context.restore(
               Map.put(snapshot, "built_at", "not-a-date"),
               context.input,
               context.input_entry,
               %{episode.id => episode}
             )

    assert {:error, {:invalid_admission_context_snapshot, :built_at}} =
             Context.restore(
               Map.put(snapshot, "built_at", 1),
               context.input,
               context.input_entry,
               %{episode.id => episode}
             )

    assert {:error, {:invalid_admission_context_snapshot, :candidates}} =
             Context.restore(
               snapshot,
               context.input,
               context.input_entry,
               %{}
             )

    assert {:error, {:invalid_admission_context_snapshot, :candidates}} =
             Context.restore(
               Map.put(snapshot, "candidates", :not_a_candidate_list),
               context.input,
               context.input_entry,
               %{}
             )

    assert {:error, {:invalid_admission_context_snapshot, :document}} =
             Context.restore(snapshot, context.input, context.input_entry, :not_an_episode_map)
  end

  defp build_context(entry) do
    Admission.context(Inbox.ref(entry),
      now: @now,
      continuation_window: 30 * 60,
      history_window: 30 * 24 * 60 * 60,
      candidate_limit: 8
    )
  end

  defp record_input!(overrides \\ []) do
    input = input!(overrides)
    assert {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp create_episode!(options) do
    channel_ref = Keyword.get(options, :channel_ref, "C456")
    thread_ref = Keyword.fetch!(options, :thread_ref)
    episode_id = Ecto.UUID.generate()
    episode_key = "admission-test:#{Keyword.fetch!(options, :key)}:#{episode_id}"

    source_input =
      input!(
        actor: Keyword.get(options, :actor, %{kind: :app, ref: "A123"}),
        channel_ref: channel_ref,
        content: Keyword.fetch!(options, :content),
        event_ref: "Ev-#{episode_id}",
        message_ref: thread_ref,
        thread_ref: nil
      )

    command = %Command.AdmitInput{
      actor_ref: Input.actor_ref(source_input),
      destination: source_input.destination,
      episode_id: episode_id,
      episode_key: episode_key,
      execution_mode: Keyword.get(options, :execution_mode, :live),
      linked_episode_id: nil,
      native_input_id: Keyword.get(options, :native_input_id, source_input.native_input_id),
      occurred_at: DateTime.add(@now, -3 * 60 * 60),
      payload: Input.document(source_input),
      revision: 1,
      turn_ref: "turn-#{episode_id}"
    }

    assert {:ok, _transition} = Episodes.apply(command)

    if Keyword.get(options, :complete, false) do
      assert {:ok, _transition} =
               Episodes.apply(%Command.AcceptResult{
                 decision_reason: "No reply was useful for this fixture.",
                 delivery: :none,
                 delivery_ref: nil,
                 episode_key: episode_key,
                 expected_turn_ref: command.turn_ref,
                 next_turn_ref: nil,
                 occurred_at: DateTime.add(command.occurred_at, 1, :second),
                 result_ref: "result-#{episode_id}"
               })
    end

    case Keyword.fetch(options, :updated_at) do
      {:ok, updated_at} ->
        Repo.update_all(
          from(episode in Responder.Episodes.Episode, where: episode.id == ^episode_id),
          set: [updated_at: updated_at]
        )

      :error ->
        :ok
    end

    {:ok, episode} = Episodes.fetch_by_key(episode_key)
    episode
  end

  defp admit_followup!(episode, text, occurred_at) do
    input =
      input!(
        content: %{"text" => text},
        event_ref: "Ev-#{Ecto.UUID.generate()}",
        message_ref: "#{DateTime.to_unix(occurred_at, :microsecond) / 1_000_000}",
        occurred_at: occurred_at,
        thread_ref: episode.destination_thread_ref
      )

    assert {:ok, _transition} =
             Episodes.apply(%Command.AdmitInput{
               actor_ref: Input.actor_ref(input),
               destination: %{
                 conversation_ref: episode.destination_conversation_ref,
                 thread_ref: episode.destination_thread_ref,
                 transport: episode.destination_transport
               },
               episode_id: episode.id,
               episode_key: episode.key,
               linked_episode_id: episode.linked_episode_id,
               native_input_id: input.native_input_id,
               occurred_at: occurred_at,
               payload: Input.document(input),
               revision: input.revision,
               turn_ref: "turn-#{Ecto.UUID.generate()}"
             })
  end

  defp input!(overrides) do
    attributes =
      Keyword.merge(
        [
          actor: %{kind: :app, ref: "A123"},
          channel_ref: "C456",
          content: %{"text" => "Current Slack input"},
          event_kind: :message,
          event_ref: "Ev-current-#{Ecto.UUID.generate()}",
          message_ref: @current_thread,
          occurred_at: @now,
          revision: 1,
          thread_ref: nil,
          workspace_ref: "TA6E21ABA08AF"
        ],
        overrides
      )

    assert {:ok, input} = SlackInput.new(attributes)
    input
  end
end
