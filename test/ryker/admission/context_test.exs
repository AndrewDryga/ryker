defmodule Ryker.Admission.ContextTest do
  use Ryker.DataCase, async: true

  @moduletag isolation: "REPEATABLE READ"

  import Ecto.Query

  alias Ryker.Admission
  alias Ryker.Admission.{Context, Decision}
  alias Ryker.Episodes
  alias Ryker.Episodes.Command
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.People
  alias Ryker.Repo
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Work.Session

  @now ~U[2026-08-27 12:00:00.000000Z]
  @current_thread "1787832000.000100"

  test "new admission snapshots replace instructions while restored requests keep their saved layers" do
    alias Ryker.Instructions

    scope = {:channel, "TA6E21ABA08AF", "C456"}
    assert {:ok, _} = Instructions.save(:global, "Use plain language.", 0, "operator:test")
    assert {:ok, _} = Instructions.save(scope, "Keep this channel concise.", 0, "operator:test")
    entry = record_input!()
    assert {:ok, context} = build_context(entry)
    expected = Instructions.snapshot(context.input.destination)
    assert Context.for_model(context)["custom_instructions"] == expected
    saved = Context.snapshot(context)
    assert saved["custom_instructions"] == expected

    assert {:ok, _} = Instructions.save(scope, "", 1, "operator:test")
    assert {:ok, _} = Instructions.save(:global, "Explain assumptions.", 1, "operator:test")
    assert {:ok, restored} = Context.restore(saved, context.input, entry, %{})
    assert Context.for_model(restored)["custom_instructions"] == expected
    assert {:ok, fresh} = build_context(entry)
    assert fresh.custom_instructions["channel"]["text"] == ""
    assert fresh.custom_instructions["channel"]["revision"] == 2
    assert fresh.custom_instructions["global"]["text"] == "Explain assumptions."

    other = %{
      context.input
      | destination: %{context.input.destination | conversation_ref: "slack:TA6E21ABA08AF:COTHER"}
    }

    assert {:error, {:invalid_admission_context_snapshot, :custom_instructions}} =
             Context.restore(saved, other, entry, %{})

    historical = Map.delete(saved, "custom_instructions")
    assert {:ok, old} = Context.restore(historical, context.input, entry, %{})
    refute Map.has_key?(Context.for_model(old), "custom_instructions")
  end

  # Andrew, 2026-09-30: Ryker learns what people say about themselves
  # (`Ryker.People`) so it can be considerate to them. Routing writes the
  # quick replies, so it reads what the sender said, frozen with the rest of
  # its context, and nothing about anyone else.
  test "routing reads what the sender said about themselves, and nothing about anyone else" do
    alice = %{kind: :user, ref: "UALICE"}

    told =
      record_input!(
        actor: alice,
        content: %{"text" => "My birthday is 12 March"},
        message_ref: "1787831000.000100"
      )

    birthday = %{
      "source_input_id" => told.id,
      "key" => "birthday",
      "fact" => "Birthday is 12 March."
    }

    assert {:ok, :ok} =
             Repo.transaction(fn -> People.learn_in_transaction([birthday], [told]) end)

    asking = record_input!(actor: alice, content: %{"text" => "hi!"})
    assert {:ok, context} = build_context(asking)

    assert %{"said_about_themselves" => ["Birthday is 12 March."], "use" => use} =
             Context.for_model(context)["person_asking"]

    assert use =~ "never repeat it to anyone else"

    saved = Context.snapshot(context)
    assert {:ok, 1} = People.forget_person("slack:user:UALICE")
    assert {:ok, restored} = Context.restore(saved, context.input, asking, %{})

    assert Context.for_model(restored)["person_asking"] ==
             Context.for_model(context)["person_asking"]

    bob = record_input!(actor: %{kind: :user, ref: "UBOB"}, message_ref: "1787833000.000100")
    assert {:ok, bob_context} = build_context(bob)
    refute Map.has_key?(Context.for_model(bob_context), "person_asking")
    refute Map.has_key?(Context.snapshot(bob_context), "person_asking")
  end

  # Andrew, 2026-09-30: routing's search "won't actually work in real
  # life". It now also searches by meaning: the message's vector is asked for
  # before the snapshot opens, and a server that fails costs the search only
  # that lane, which the receipt says.
  test "routing searches by the message's meaning, and says why when it could not" do
    entry =
      record_input!(
        actor: %{kind: :user, ref: "UALICE"},
        content: %{"text" => "is the database back?"}
      )

    test = self()

    embedder = fn [text], options ->
      send(test, {:asked, text, options[:timeout_ms]})
      {:ok, [[1.0, 0.0]]}
    end

    assert {:ok, context} = build_context(entry, embedder: embedder)
    assert_received {:asked, "is the database back?", 3_000}
    assert context.routing_receipt["meaning"] == %{"model" => Ryker.Embeddings.model()}

    stopped = fn _texts, _options -> {:error, :unreachable} end
    assert {:ok, context} = build_context(entry, embedder: stopped)

    assert context.routing_receipt["meaning"] == %{
             "unavailable" => "the embedding server could not be reached"
           }

    assert {:ok, context} = build_context(entry, embedder: nil)
    assert context.routing_receipt["meaning"] == nil
  end

  test "addressing is frozen from the receipt and restored independently of current entry metadata" do
    assert {:ok, %{entry: entry}} =
             Inbox.record(input!([]), slack_audience: :ambient, slack_bot_user_ref: "UBOT")

    assert {:ok, context} = build_context(entry)
    expected = %{"audience" => "ambient", "ryker_user_ref" => "UBOT"}
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
          %{"audience" => "mention", "ryker_user_ref" => nil},
          %{"audience" => "unknown", "ryker_user_ref" => "UBOT"},
          %{"audience" => "direct", "ryker_user_ref" => "U-bot"},
          %{"audience" => "direct", "ryker_user_ref" => String.duplicate("U", 257)},
          %{"audience" => "mention", "ryker_user_ref" => "UBOT", "authority" => "write"}
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
                 "ryker_user_ref" => "UBOT"
               }),
               other_input,
               context.input_entry,
               %{}
             )
  end

  test "offers same-work and history candidates without inspecting provider text" do
    current = record_input!(content: %{"text" => "A custom app changed state"})

    same_thread =
      create_episode!(
        key: "same-thread",
        thread_ref: @current_thread,
        content: %{"text" => "This could be any earlier human or app message"},
        complete: true,
        updated_at: DateTime.add(@now, -40 * 24 * 60 * 60)
      )

    matching_other_thread =
      create_episode!(
        key: "matching-other-thread",
        thread_ref: "1787831000.000001",
        content: %{"text" => "A custom app changed state earlier today"},
        complete: true,
        updated_at: DateTime.add(@now, -5 * 60)
      )

    expired_other_thread =
      create_episode!(
        key: "expired-other-thread",
        thread_ref: "1787830000.000001",
        content: %{"text" => "A custom app changed state last month"},
        complete: true,
        updated_at: DateTime.add(@now, -2 * 60 * 60)
      )

    other_channel =
      create_episode!(
        key: "other-channel",
        channel_ref: "C999",
        thread_ref: "1787833000.000001",
        content: %{"text" => "A custom app changed state somewhere Ryker has not joined"}
      )

    assert {:ok, context} = build_context(current)
    candidates = Map.new(context.candidates, &{&1.episode.id, &1})

    assert candidates[same_thread.id].allowed_relations == [:same_work, :history_only]
    assert candidates[same_thread.id].same_thread

    assert candidates[matching_other_thread.id].allowed_relations == [
             :same_work,
             :history_only
           ]

    assert candidates[expired_other_thread.id].allowed_relations == [:history_only]

    # Ryker has no recorded membership of C999, so that conversation is not
    # in this input's correlation scope at all.
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
    refute encoded =~ matching_other_thread.destination_thread_ref
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

  test "a Slack channel default does not hide active work in another selected repository" do
    episode =
      create_episode!(
        key: "selected-repository",
        thread_ref: @current_thread,
        content: %{"text" => "Update the test repository"}
      )

    Repo.insert!(%Session{
      id: Ecto.UUID.generate(),
      episode_id: episode.id,
      external_ref: "selected-repository",
      policy: "test-policy",
      policy_digest: String.duplicate("a", 64),
      repository_ref: "test"
    })

    input =
      input!(
        content: %{"text" => "Continue the README change in test"},
        event_ref: "Ev-selected-repository-followup",
        message_ref: "1787832001.000100",
        thread_ref: @current_thread
      )

    assert {:ok, %{entry: entry}} =
             Inbox.record(input,
               work_profile: %{
                 policy: "default-policy",
                 policy_digest: String.duplicate("b", 64),
                 repository_ref: "default"
               }
             )

    assert entry.repository_ref == "default"
    assert {:ok, context} = build_context(entry)
    candidate = Enum.find(context.candidates, &(&1.episode.id == episode.id))
    assert candidate.allowed_relations == [:same_work, :history_only]
  end

  test "a human message can join eligible work outside its own thread" do
    # The old contract forbade a human actor from continuing any thread but
    # their own, which is exactly what split one incident into two episodes
    # when people discussed it beside the alert that reported it.
    current =
      record_input!(
        actor: %{kind: :user, ref: "U123"},
        content: %{"text" => "The replica is still lagging badly"}
      )

    other_thread =
      create_episode!(
        key: "human-root-other-thread",
        thread_ref: "1787820000.000002",
        content: %{"text" => "The replica is lagging and reads are slow"}
      )

    assert {:ok, context} = build_context(current)
    candidate = Enum.find(context.candidates, &(&1.episode.id == other_thread.id))

    assert candidate.allowed_relations == [:same_work, :history_only]
    refute candidate.same_thread
    assert candidate.match["topic_fit"] > 0.0
  end

  test "a direct message correlates only inside its own conversation" do
    current =
      record_input!(
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "D456",
        content: %{"text" => "Rotate the staging credentials"},
        message_ref: "1787832002.000300"
      )

    inside =
      create_episode!(
        key: "active-direct-message",
        channel_ref: "D456",
        thread_ref: "1787820000.000001",
        content: %{"text" => "Rotate the staging credentials for the sandbox"}
      )

    outside =
      create_episode!(
        key: "channel-work",
        thread_ref: "1787810000.000001",
        content: %{"text" => "Rotate the staging credentials for the sandbox"}
      )

    assert {:ok, context} = build_context(current)
    candidates = Map.new(context.candidates, &{&1.episode.id, &1})

    assert candidates[inside.id].allowed_relations == [:same_work, :history_only]
    refute Map.has_key?(candidates, outside.id)
  end

  test "the exact source item's owner is offered first however busy the conversation is" do
    current = record_input!(revision: 2)

    owner =
      create_episode!(
        key: "app-source-owner",
        thread_ref: "1787820000.000011",
        content: %{"text" => "Earlier revision of this exact source lifecycle"},
        native_input_id: current.native_input_id
      )

    for index <- 1..12 do
      create_episode!(
        key: "unrelated-active-#{index}",
        thread_ref: "1787832001.#{String.pad_leading(Integer.to_string(index), 6, "0")}",
        content: %{"text" => "Unrelated active work #{index}"}
      )
    end

    assert {:ok, context} = build_context(current)
    assert length(context.candidates) <= 8
    assert hd(context.candidates).episode.id == owner.id
    assert hd(context.candidates).source_owner
    assert hd(context.candidates).allowed_relations == [:same_work, :history_only]
  end

  test "unrelated completed history is no longer offered just for being recent" do
    # Recency is a tie-breaker, never the selector. Twenty unrelated completed
    # episodes used to fill the shortlist purely because they were newest.
    current = record_input!(content: %{"text" => "The reporting database is unavailable"})

    active =
      create_episode!(
        key: "old-active",
        thread_ref: "1787820000.000099",
        content: %{"text" => "The reporting database keeps timing out"},
        updated_at: DateTime.add(@now, -20 * 24 * 60 * 60)
      )

    for index <- 1..8 do
      create_episode!(
        key: "newer-complete-#{index}",
        thread_ref: "1787831000.#{String.pad_leading(Integer.to_string(index), 6, "0")}",
        content: %{"text" => "Marketing site deploy #{index} finished"},
        complete: true,
        updated_at: DateTime.add(@now, -index, :second)
      )
    end

    assert {:ok, context} = build_context(current)
    offered = Enum.map(context.candidates, & &1.episode.id)

    assert active.id in offered
    assert length(offered) < 9
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
        content: %{"text" => "Current Slack input, from an older completed episode"},
        complete: true,
        updated_at: DateTime.add(@now, -2 * 60 * 60)
      )

    assert {:ok, context} = build_context(current)
    candidate = Enum.find(context.candidates, &(&1.episode.id == expired.id))

    assert {:ok, history_decision} =
             Decision.parse(%{
               "action" => "start_episode",
               "episode_ref" => candidate.ref,
               "messages" => nil,
               "reactions" => nil,
               "relation" => "history_only",
               "repository" => nil,
               "repository_source" => nil,
               "reason" => "The older work is useful history, but this is a new episode.",
               "work_class" => "standard"
             })

    assert {:ok, %{candidate: ^candidate}} = Admission.validate(context, history_decision)

    assert {:ok, continuation} =
             Decision.parse(%{
               "action" => "continue_episode",
               "episode_ref" => candidate.ref,
               "messages" => nil,
               "reactions" => nil,
               "relation" => "same_work",
               "repository" => nil,
               "repository_source" => nil,
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
               "messages" => nil,
               "reactions" => nil,
               "relation" => "same_work",
               "repository" => nil,
               "repository_source" => nil,
               "reason" => "Try an arbitrary reference.",
               "work_class" => "standard"
             })

    assert {:error, {:admission_rejected, :unknown_candidate}} =
             Admission.validate(context, unknown)
  end

  test "refuses to build a second model context after an input is decided" do
    entry = record_input!()

    Repo.update_all(
      from(stored in Ryker.Ingress.Inbox.Entry, where: stored.id == ^entry.id),
      set: [
        decision_action: :ignore,
        decision_document: %{
          "action" => "ignore",
          "episode_ref" => nil,
          "messages" => nil,
          "reactions" => nil,
          "relation" => "unrelated",
          "repository" => nil,
          "repository_source" => nil,
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

    # The message the candidate's preview quotes is frozen beside it, for
    # forgetting to reach a copy of the prompt by (`Ryker.RoutingExamples`).
    assert snapshot["candidate_messages"] == [
             %{
               "conversation_ref" => episode.destination_conversation_ref,
               "message_ref" => "1787830000.000777"
             }
           ]

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

    assert {:error, {:invalid_admission_context_snapshot, :candidate_messages}} =
             Context.restore(
               Map.put(snapshot, "candidate_messages", [%{"message_ref" => 1}]),
               context.input,
               context.input_entry,
               %{episode.id => episode}
             )
  end

  # A route in an environment with several repositories lists them for the
  # router, each with what the operator wrote about it, so the model can name
  # the one the event concerns; the list is frozen with the context, so the
  # receipt shows exactly the choices the model had even after the environment
  # changes. Before, the router never saw the repositories at all, and every
  # episode in the environment changed its first one.
  test "the router sees each repository of a shared environment with its description, frozen with the context" do
    alias Ryker.Admission.Prompt
    alias Ryker.Settings

    {:ok, initialized} = Settings.initialize("control-plane:local")

    {:ok, with_billing} =
      Settings.put_repository(
        %{ref: "billing", description: "Invoices and payment runs"},
        initialized.installation.revision,
        "control-plane:local"
      )

    {:ok, _with_ledger} =
      Settings.put_repository(
        %{ref: "ledger", display_name: "General ledger"},
        with_billing.installation.revision,
        "control-plane:local"
      )

    assert {:ok, %{entry: entry}} =
             Inbox.record(input!([]),
               work_profile: shared_environment_profile(["billing", "ledger", "runbooks"])
             )

    assert {:ok, context} = build_context(entry)

    choices = [
      %{"ref" => "billing", "description" => "Invoices and payment runs"},
      %{"ref" => "ledger", "description" => "General ledger"},
      %{"ref" => "runbooks"}
    ]

    assert context.repository_choices == choices
    document = Context.for_model(context)
    assert document["repository_choices"] == choices
    assert Prompt.build(context)["instructions"] =~ "repository_choices"

    snapshot = Context.snapshot(context)
    assert snapshot["repository_choices"] == choices
    assert {:ok, restored} = Context.restore(snapshot, context.input, entry, %{})
    assert restored.repository_choices == choices
    assert Context.for_model(restored) == document

    # A snapshot frozen before the choice existed offered none.
    assert {:ok, older} =
             Context.restore(
               Map.delete(snapshot, "repository_choices"),
               context.input,
               entry,
               %{}
             )

    assert older.repository_choices == []
    refute Map.has_key?(Context.for_model(older), "repository_choices")

    for malformed <- [
          %{},
          ["billing"],
          [%{"ref" => ""}, %{"ref" => "ledger"}],
          [%{"ref" => "billing", "extra" => 1}, %{"ref" => "ledger"}],
          [%{"ref" => "billing"}, %{"ref" => "billing"}],
          [%{"ref" => "billing"}]
        ] do
      assert {:error, {:invalid_admission_context_snapshot, :repository_choices}} =
               Context.restore(
                 Map.put(snapshot, "repository_choices", malformed),
                 context.input,
                 entry,
                 %{}
               )
    end

    # One repository, or none, leaves nothing to choose.
    assert {:ok, %{entry: single}} =
             Inbox.record(input!(event_ref: "Ev-single", message_ref: "1787832000.000200"),
               work_profile: shared_environment_profile(["billing"])
             )

    assert {:ok, context} = build_context(single)
    assert context.repository_choices == []
    refute Map.has_key?(Context.for_model(context), "repository_choices")
    refute Prompt.build(context)["instructions"] =~ "repository_choices"
  end

  # Each repository's three class policies share one execution authority, as
  # the Coop worker advertises them.
  defp shared_environment_profile(repositories) do
    %{
      environment_ref: "platform",
      parallel_goal_limit: 2,
      policies:
        Map.new(repositories, fn repository ->
          {repository,
           Map.new([:conversational, :standard, :deep], fn work_class ->
             {work_class,
              %{
                authority_digest: String.duplicate("e", 64),
                policy: "#{repository}-#{work_class}",
                policy_digest: String.duplicate("b", 64)
              }}
           end)}
        end),
      repositories: repositories
    }
  end

  defp build_context(entry, options \\ []) do
    Admission.context(
      Inbox.ref(entry),
      [
        now: @now,
        continuation_window: 30 * 60,
        history_window: 30 * 24 * 60 * 60,
        candidate_limit: 8
      ] ++ options
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
          from(episode in Ryker.Episodes.Episode, where: episode.id == ^episode_id),
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
