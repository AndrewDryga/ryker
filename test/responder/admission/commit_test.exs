defmodule Responder.Admission.CommitTest do
  use Responder.DataCase, async: true

  # A suite-owned workspace keeps conversation locks out of other async fixtures.

  @moduletag isolation: "REPEATABLE READ"

  import Ecto.Query

  alias Responder.Admission
  alias Responder.Admission.Decision
  alias Responder.Episodes
  alias Responder.Episodes.Command
  alias Responder.Ingress.{Inbox, Input}
  alias Responder.Repo
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.Work.{Cancellation, Custody, Session, Submission}

  @now ~U[2026-08-27 12:00:00.000000Z]

  test "ignoring a useful human message learns without creating work or delivery in either mode" do
    # Blitz's real keep-service decision must remain recallable even when the bot
    # has nothing useful to add. Previously ignore retained no conversation memory.
    for mode <- [:live, :shadow] do
      input =
        input!(
          event_ref: "observe-#{mode}",
          message_ref: "1787832000.000#{if mode == :live, do: "101", else: "102"}",
          actor: %{kind: :user, ref: "U03EPT4RP5M"},
          content: %{
            "text" =>
              "`draft-ai-suggestions`\nplanning to look into it at some point, let’s keep it"
          }
        )

      {:ok, %{entry: entry}} = Inbox.record(input, execution_mode: mode)
      document = decision!(:ignore, nil, :unrelated) |> Decision.document()

      note = %{
        "summary" =>
          "U03EPT4RP5M wants to keep `draft-ai-suggestions` and plans to look into it at an unspecified future time.",
        "topics" => ["draft-ai-suggestions"]
      }

      assert {:ok, decision} = Decision.parse(Map.put(document, "observation", note))

      assert {:ok, %{episode: nil, transitions: []}} =
               Admission.commit(context!(entry), decision, "observed:#{mode}")

      assert {:ok, %{rows: [[saved]]}} =
               Repo.query(
                 "SELECT note FROM conversation_observations WHERE source_input_id = $1::uuid",
                 [Ecto.UUID.dump!(entry.id)]
               )

      assert Jason.decode!(saved) == note
    end

    assert Repo.aggregate(Responder.Episodes.Episode, :count) == 0
    assert Repo.aggregate(Responder.Delivery.Reaction, :count) == 0
    assert Repo.aggregate(Responder.Work.Turn, :count) == 0
  end

  test "starts one episode under the current Slack message and reconciles a lost response" do
    entry = record_input!(content: %{"text" => "Please investigate this unfamiliar app card"})
    context = context!(entry)
    decision = decision!(:start_episode, nil, :unrelated)

    assert {:ok, first} = Admission.commit(context, decision, "decision-start-1")
    assert first.status == :applied
    assert first.entry.status == :decided
    assert first.entry.decision_action == :start_episode
    assert first.entry.episode_id == first.episode.id
    assert first.episode.destination_thread_ref == entry.destination_thread_ref
    assert first.episode.destination_conversation_ref == "slack:TADMISSIONCOMMIT:C456"
    assert length(first.transitions) == 1

    assert [event] = Episodes.list_events(first.episode.key)
    assert event.payload["payload"]["content"]["text"] =~ "unfamiliar app card"

    assert {:ok, duplicate} = Admission.commit(context, decision, "decision-start-1")
    assert duplicate.status == :duplicate
    assert duplicate.entry.id == first.entry.id
    assert duplicate.episode.id == first.episode.id
    assert Episodes.list_events(first.episode.key) == [event]

    paraphrased = %{decision | reason: "Same decision, explained differently after reconnecting."}
    assert {:ok, duplicate} = Admission.commit(context, paraphrased, "decision-start-1")
    assert duplicate.status == :duplicate
    assert duplicate.entry.decision_document["reason"] == decision.reason

    assert {:error, {:decision_conflict, details}} =
             Admission.commit(context, decision, "decision-from-another-turn")

    assert details[:stored_decision_ref] == "decision-start-1"
    assert details[:submitted_decision_ref] == "decision-from-another-turn"
  end

  test "shadow work is isolated from live episodes and remains observe-only" do
    live = create_episode!(thread_ref: "1787830000.000001")
    input = input!(event_ref: "Ev-shadow-admission", message_ref: "1787832000.000100")

    assert {:ok, %{entry: entry}} = Inbox.record(input, execution_mode: :shadow)

    context = context!(entry)
    assert context.candidates == []

    assert {:ok, result} =
             Admission.commit(
               context,
               decision!(:start_episode, nil, :unrelated),
               "decision-shadow-isolated"
             )

    assert result.episode.id != live.id
    assert result.episode.execution_mode == :shadow
    assert result.episode.linked_episode_id == nil
    assert result.episode.destination_conversation_ref == live.destination_conversation_ref

    assert {:ok, unchanged_live} = Episodes.fetch_by_key(live.key)
    assert unchanged_live.execution_mode == :live
    assert unchanged_live.queued_input_refs == []
  end

  test "a claimed input can only be decided by its current executor lease" do
    entry = record_input!(event_ref: "Ev-owned-admission")

    assert {:ok, %{lease_ref: lease_ref}} =
             Inbox.claim_next("executor:owner", @now, 300)

    assert {:error, {:admission_rejected, :lease_lost}} = context_result(entry)
    assert {:ok, context} = context_result(entry, lease_ref)
    decision = decision!(:reply, nil, :unrelated)

    assert {:error, {:admission_rejected, :lease_lost}} =
             Admission.commit(context, decision, "decision-wrong-lease",
               lease_ref: "ingress-lease:wrong"
             )

    assert {:ok, result} =
             Admission.commit(context, decision, "decision-right-lease", lease_ref: lease_ref)

    assert result.entry.status == :decided
    assert result.entry.lease_ref == nil
  end

  test "a frozen context returns the durable blocker when custody changes before commit" do
    entry = record_input!(event_ref: "Ev-blocked-before-commit")

    assert {:ok, %{lease_ref: lease_ref}} =
             Inbox.claim_next("executor:block-before-commit", @now, 300)

    assert {:ok, context} = context_result(entry, lease_ref)

    assert {:ok, blocked} =
             Inbox.block(
               Inbox.ref(entry),
               lease_ref,
               "operation_uncertain",
               "Coop could not prove whether the admission mutation was accepted."
             )

    assert blocked.status == :blocked
    decision = decision!(:reply, nil, :unrelated)

    assert {:error,
            {:input_blocked, "operation_uncertain",
             "Coop could not prove whether the admission mutation was accepted."}} =
             Admission.commit(context, decision, "decision-after-block", lease_ref: lease_ref)
  end

  test "starts a new episode with old work as history without borrowing its thread" do
    old = create_episode!(thread_ref: "1787830000.000001", complete: true)
    entry = record_input!(message_ref: "1787832000.000100")
    context = context!(entry)
    candidate = candidate!(context, old.id)
    decision = decision!(:start_episode, candidate.ref, :history_only)

    assert {:ok, result} = Admission.commit(context, decision, "decision-history-1")

    assert result.episode.id != old.id
    assert result.episode.linked_episode_id == old.id
    assert result.episode.destination_thread_ref == entry.destination_thread_ref

    assert {:ok, unchanged_old} = Episodes.fetch_by_key(old.key)
    assert unchanged_old.destination_thread_ref == "1787830000.000001"
  end

  test "a direct reply uses the current message thread and preserves its action" do
    entry = record_input!(event_ref: "Ev-direct-reply")
    context = context!(entry)
    decision = decision!(:reply, nil, :unrelated)

    assert {:ok, result} = Admission.commit(context, decision, "decision-reply-1")
    assert result.entry.decision_action == :reply
    assert result.episode.destination_thread_ref == entry.destination_thread_ref
  end

  test "an app event can continue active work in its bound thread and queue the input" do
    active =
      create_episode!(thread_ref: "1787830000.000001", actor: %{kind: :app, ref: "A123"})

    entry = record_input!(actor: %{kind: :app, ref: "A123"}, message_ref: "1787832000.000100")
    context = context!(entry)
    candidate = candidate!(context, active.id)
    decision = decision!(:continue_episode, candidate.ref, :same_work)

    assert {:ok, result} = Admission.commit(context, decision, "decision-continue-1")

    assert result.episode.id == active.id
    assert result.episode.destination_thread_ref == "1787830000.000001"
    assert result.episode.owner_ref == active.owner_ref
    assert length(result.episode.queued_input_refs) == 1

    assert Enum.map(Episodes.list_events(active.key), & &1.kind) == [
             :input_admitted,
             :input_admitted
           ]
  end

  test "an existing episode keeps its pinned policy when a later classification selects another class" do
    active = create_episode!(thread_ref: "1787830000.007001")
    original_digest = String.duplicate("a", 64)

    assert {:ok, original_session} =
             Custody.pin_episode(
               active.id,
               "conversation-terra-medium",
               original_digest,
               "service"
             )

    entry =
      record_input!(
        event_ref: "Ev-existing-work-class",
        message_ref: "1787830000.007002",
        thread_ref: active.destination_thread_ref
      )

    context = context!(entry)
    candidate = candidate!(context, active.id)
    decision = decision!(:continue_episode, candidate.ref, :same_work, "deep")

    assert {:ok, result} =
             Admission.commit(context, decision, "decision-existing-work-class",
               work_policy: %{
                 digest: String.duplicate("d", 64),
                 name: "deep-sol-xhigh",
                 repository_ref: "service"
               }
             )

    assert result.episode.id == active.id

    assert %Session{
             id: session_id,
             policy: "conversation-terra-medium",
             policy_digest: ^original_digest,
             repository_ref: "service"
           } = Repo.one!(from(session in Session, where: session.episode_id == ^active.id))

    assert session_id == original_session.id
  end

  test "a same-work correction rearms a remotely settled blocked turn" do
    active = create_episode!(thread_ref: "1787830000.006001")
    policy = %{digest: String.duplicate("a", 64), name: "work-read-only"}

    assert {:ok, _session} =
             Custody.pin_episode(active.id, policy.name, policy.digest)

    assert {:ok, claim} = Custody.claim_next("worker:block-before-correction", 60)

    assert {:ok, submission} =
             Submission.new(
               %{"request" => "The original request"},
               "Handle the original request.",
               %{"type" => "object"},
               "work-final-v1"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(
               active.id,
               active.owner_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               active.id,
               active.owner_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:blocked-correction"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               active.id,
               active.owner_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:blocked-correction"
             )

    assert {:ok, _requested} =
             Custody.request_block(
               active.id,
               active.key,
               active.owner_ref,
               claim.lease_ref,
               "The executor needs a human correction."
             )

    assert {:ok, stop_claim} = Custody.claim_next("worker:stop-before-correction", 60)

    assert {:ok, receipt} =
             Cancellation.terminal_receipt(
               session.coop_session_id,
               turn.coop_turn_id,
               "cancelled",
               Cancellation.operation_key(turn.id, 1),
               "closed",
               "responder:work:cancel-close:#{turn.id}:g1"
             )

    assert {:ok, blocked} =
             Custody.settle_cancellation(
               active.id,
               active.key,
               active.owner_ref,
               stop_claim.lease_ref,
               receipt
             )

    assert blocked.turn.status == :blocked

    entry =
      record_input!(
        event_ref: "Ev-correct-blocked-work",
        message_ref: "1787830000.006002",
        thread_ref: active.destination_thread_ref
      )

    context = context!(entry)
    candidate = candidate!(context, active.id)
    continue = decision!(:continue_episode, candidate.ref, :same_work)

    assert {:ok, result} =
             Admission.commit(context, continue, "decision-resume-blocked", work_policy: policy)

    assert result.episode.owner_ref =~ "turn:resume-blocked:#{turn.id}:v"
    assert result.episode.queued_input_refs == []
    assert length(result.episode.active_input_refs) == 2

    assert {:ok, replacement} = Custody.claim_next("worker:corrected-work", 60)
    assert replacement.turn.turn_ref == result.episode.owner_ref
    assert replacement.session.generation == session.generation + 1
  end

  test "an admitted trigger resumes a waiting episode in the same transaction" do
    waiting =
      create_episode!(
        thread_ref: "1787830000.000001",
        wait: :event,
        actor: %{kind: :app, ref: "A123"}
      )

    entry = record_input!(actor: %{kind: :app, ref: "A123"})
    context = context!(entry)
    candidate = candidate!(context, waiting.id)
    decision = decision!(:continue_episode, candidate.ref, :same_work)

    assert {:ok, result} = Admission.commit(context, decision, "decision-resume-1")

    assert result.episode.state == :working
    assert result.episode.owner_kind == :turn
    assert result.episode.owner_ref == "ingress-turn:#{entry.id}"
    assert length(result.episode.active_input_refs) == 1
    assert Enum.map(result.transitions, & &1.event.kind) == [:input_admitted, :wait_resumed]
  end

  test "an input that occurred before a wait cannot satisfy that later wait" do
    waiting =
      create_episode!(
        thread_ref: "1787830000.000001",
        wait: :event,
        actor: %{kind: :app, ref: "A123"}
      )

    entry =
      record_input!(
        actor: %{kind: :app, ref: "A123"},
        event_ref: "Ev-delayed-before-wait",
        occurred_at: DateTime.add(@now, -120, :second)
      )

    context = context!(entry)
    candidate = candidate!(context, waiting.id)
    decision = decision!(:continue_episode, candidate.ref, :same_work)

    assert {:ok, result} = Admission.commit(context, decision, "decision-delayed-input")

    assert result.episode.state == :waiting_for_event
    assert result.episode.owner_ref == waiting.owner_ref
    assert length(result.episode.queued_input_refs) == 1
    assert Enum.map(result.transitions, & &1.event.kind) == [:input_admitted]
  end

  test "a wait started after context construction is resumed from locked current state" do
    active =
      create_episode!(thread_ref: "1787830000.000001", actor: %{kind: :app, ref: "A123"})

    entry = record_input!(actor: %{kind: :app, ref: "A123"}, event_ref: "Ev-wait-race")
    context = context!(entry)
    candidate = candidate!(context, active.id)
    assert candidate.episode.state == :working

    assert {:ok, _waiting} =
             Episodes.apply(%Command.StartWait{
               deadline_at: DateTime.add(@now, 3_600, :second),
               episode_key: active.key,
               expected_turn_ref: active.owner_ref,
               kind: :event,
               occurred_at: DateTime.add(@now, -1, :second),
               wait_ref: "wait-after-context"
             })

    decision = decision!(:continue_episode, candidate.ref, :same_work)
    assert {:ok, result} = Admission.commit(context, decision, "decision-wait-race")

    assert result.episode.state == :working
    assert result.episode.owner_ref == "ingress-turn:#{entry.id}"
    assert Enum.map(result.transitions, & &1.event.kind) == [:input_admitted, :wait_resumed]
  end

  test "ignore and react decisions remain durable without inventing an episode" do
    for action <- [:ignore, :react] do
      entry = record_input!(event_ref: "Ev-#{action}")
      context = context!(entry)
      decision = decision!(action, nil, :unrelated)

      assert {:ok, result} = Admission.commit(context, decision, "decision-#{action}")
      assert result.status == :applied
      assert result.episode == nil
      assert result.transitions == []
      assert result.entry.decision_action == action
      assert result.entry.episode_id == nil

      if action == :react do
        assert result.entry.decision_document["reaction"] == %{"emoji_name" => "eyes"}
      else
        assert result.entry.decision_document["reaction"] == nil
      end
    end
  end

  test "a decision-store failure rolls back the episode transition" do
    first_entry = record_input!(event_ref: "Ev-first")
    first_context = context!(first_entry)
    ignore = decision!(:ignore, nil, :unrelated)
    assert {:ok, _result} = Admission.commit(first_context, ignore, "decision-collision")

    second_entry = record_input!(event_ref: "Ev-second", message_ref: "1787832001.000100")
    second_context = context!(second_entry)
    start = decision!(:start_episode, nil, :unrelated)

    assert {:error, {:persistence_failed, :admission_decision, _errors}} =
             Admission.commit(second_context, start, "decision-collision")

    assert {:ok, still_pending} = Inbox.fetch(Inbox.ref(second_entry))
    assert still_pending.status == :pending
    assert :error == Episodes.fetch_by_key("ingress-input:#{second_entry.id}")
  end

  test "the natural input slot rejects a different decision after acceptance" do
    entry = record_input!(event_ref: "Ev-decision-conflict")
    context = context!(entry)
    ignore = decision!(:ignore, nil, :unrelated)
    react = decision!(:react, nil, :unrelated)

    assert {:ok, _result} = Admission.commit(context, ignore, "decision-original")

    assert {:error,
            {:decision_conflict,
             input_ref: input_ref,
             stored_decision_ref: "decision-original",
             submitted_decision_ref: "decision-replacement",
             stored_fingerprint: stored,
             submitted_fingerprint: submitted}} =
             Admission.commit(context, react, "decision-replacement")

    assert input_ref == Inbox.ref(entry)
    refute stored == submitted

    assert {:ok, decided} = Inbox.fetch(Inbox.ref(entry))
    assert decided.decision_action == :ignore
    assert decided.decision_ref == "decision-original"
  end

  test "a frozen empty context cannot split one thread after another input starts work" do
    first = record_input!(event_ref: "Ev-thread-first")

    second =
      record_input!(
        event_ref: "Ev-thread-second",
        message_ref: "1787832001.000100",
        occurred_at: DateTime.add(@now, 1, :second),
        thread_ref: first.destination_thread_ref
      )

    first_context = context!(first)
    second_context = context!(second)
    assert first_context.candidates == []
    assert second_context.candidates == []

    start = decision!(:start_episode, nil, :unrelated)
    assert {:ok, started} = Admission.commit(first_context, start, "decision-thread-first")

    assert {:error, {:admission_rejected, :context_stale}} =
             Admission.commit(
               second_context,
               start,
               "decision-thread-second-stale"
             )

    assert {:ok, pending} = Inbox.fetch(Inbox.ref(second))
    assert pending.status == :pending

    fresh_context = context!(second)
    candidate = candidate!(fresh_context, started.episode.id)
    continue = decision!(:continue_episode, candidate.ref, :same_work)

    assert {:ok, continued} =
             Admission.commit(
               fresh_context,
               continue,
               "decision-thread-second-fresh"
             )

    assert continued.episode.id == started.episode.id
    assert :error == Episodes.fetch_by_key("ingress-input:#{second.id}")
  end

  test "new work in another thread is reconsidered with the new candidate visible" do
    first =
      record_input!(
        event_ref: "Ev-independent-first",
        message_ref: "1787832000.000101"
      )

    second =
      record_input!(
        event_ref: "Ev-independent-second",
        message_ref: "1787832000.000102"
      )

    first_context = context!(first)
    second_context = context!(second)
    start = decision!(:start_episode, nil, :unrelated)

    assert {:ok, first_result} =
             Admission.commit(first_context, start, "decision-independent-first")

    assert {:error, {:admission_rejected, :context_stale}} =
             Admission.commit(second_context, start, "decision-independent-second-stale")

    assert {:ok, pending} = Inbox.fetch(Inbox.ref(second))
    assert pending.status == :pending

    fresh_context = context!(second)
    assert Enum.any?(fresh_context.candidates, &(&1.episode.id == first_result.episode.id))

    assert {:ok, second_result} =
             Admission.commit(fresh_context, start, "decision-independent-second-fresh")

    refute first_result.episode.id == second_result.episode.id
    assert first_result.episode.destination_thread_ref == first.destination_thread_ref
    assert second_result.episode.destination_thread_ref == second.destination_thread_ref
  end

  test "new work is reconsidered when completed history becomes active during classification" do
    old = create_episode!(thread_ref: "1787830000.000099", complete: true)

    Repo.update_all(
      from(episode in Responder.Episodes.Episode, where: episode.id == ^old.id),
      set: [updated_at: DateTime.add(@now, -2 * 60 * 60)]
    )

    entry = record_input!(event_ref: "Ev-frozen-before-history-reopens")
    context = context!(entry)
    candidate = candidate!(context, old.id)
    assert candidate.allowed_relations == [:history_only]

    reopening_input =
      input!(
        event_ref: "Ev-reopen-history",
        message_ref: "1787832001.000099",
        occurred_at: DateTime.add(@now, 1, :second),
        thread_ref: old.destination_thread_ref
      )

    assert {:ok, reopened} =
             Episodes.apply(%Command.AdmitInput{
               actor_ref: Input.actor_ref(reopening_input),
               destination: %{
                 conversation_ref: old.destination_conversation_ref,
                 thread_ref: old.destination_thread_ref,
                 transport: old.destination_transport
               },
               episode_id: old.id,
               episode_key: old.key,
               linked_episode_id: old.linked_episode_id,
               native_input_id: reopening_input.native_input_id,
               occurred_at: reopening_input.occurred_at,
               payload: Input.document(reopening_input),
               revision: reopening_input.revision,
               turn_ref: "turn-reopen-history"
             })

    assert reopened.episode.state == :working

    start = decision!(:start_episode, candidate.ref, :history_only)

    assert {:error, {:admission_rejected, :context_stale}} =
             Admission.commit(context, start, "decision-frozen-before-history-reopened")

    assert {:ok, pending} = Inbox.fetch(Inbox.ref(entry))
    assert pending.status == :pending
    :error = Episodes.fetch_by_key("ingress-input:#{entry.id}")
  end

  test "bounded exact-thread context can start linked work while unrelated active work stays unchanged" do
    old = create_episode!(thread_ref: "1787830000.000777", complete: true)

    for index <- 1..8 do
      create_episode!(
        thread_ref: "1787831000.#{String.pad_leading(Integer.to_string(index), 6, "0")}"
      )
    end

    entry =
      record_input!(
        event_ref: "Ev-exact-thread-capacity",
        message_ref: "1787832000.000777",
        thread_ref: old.destination_thread_ref
      )

    context = context!(entry)
    assert length(context.candidates) == 8
    candidate = candidate!(context, old.id)
    start = decision!(:start_episode, candidate.ref, :history_only)

    assert {:ok, result} =
             Admission.commit(context, start, "decision-exact-thread-capacity")

    assert result.episode.linked_episode_id == old.id
    assert result.episode.destination_thread_ref == old.destination_thread_ref
  end

  test "a newer revision admitted during classification supersedes stale new-work routing" do
    active = create_episode!(thread_ref: "1787830000.000001")
    entry = record_input!(event_ref: "Ev-revision-race")
    context = context!(entry)
    candidate = candidate!(context, active.id)

    assert {:ok, _newer} =
             Episodes.apply(%Command.AdmitInput{
               actor_ref: "slack:app:A-newer-revision",
               destination: %{
                 conversation_ref: active.destination_conversation_ref,
                 thread_ref: active.destination_thread_ref,
                 transport: active.destination_transport
               },
               episode_id: active.id,
               episode_key: active.key,
               linked_episode_id: active.linked_episode_id,
               native_input_id: entry.native_input_id,
               occurred_at: DateTime.add(@now, 1, :second),
               payload: %{"text" => "Revision 2 won while revision 1 was being classified."},
               revision: 2,
               turn_ref: "turn-newer-revision-race"
             })

    stale_start = decision!(:start_episode, candidate.ref, :history_only)

    assert {:ok, result} =
             Admission.commit(context, stale_start, "decision-stale-revision-race")

    assert result.status == :superseded
    assert result.entry.status == :superseded
    assert result.episode.id == active.id
    assert result.entry.last_error_code == "stale_input_revision"
    assert :error = Episodes.fetch_by_key("ingress-input:#{entry.id}")

    assert {:ok, duplicate} =
             Admission.commit(context, stale_start, "decision-stale-revision-race")

    assert duplicate.status == :superseded
    assert duplicate.entry.status == :superseded
    assert duplicate.transitions == []
  end

  test "a source owner created during classification prevents routing the revision elsewhere" do
    # A Slack edit and another lifecycle update can race while the model is
    # choosing among active episodes. The stable source item must stay with the
    # episode that admitted its first revision.
    owner =
      create_episode!(thread_ref: "1787830000.005551", actor: %{kind: :app, ref: "A123"})

    other =
      create_episode!(thread_ref: "1787830000.005552", actor: %{kind: :app, ref: "A123"})

    entry =
      record_input!(
        actor: %{kind: :app, ref: "A123"},
        event_ref: "Ev-source-owner-race-revision-two",
        message_ref: "1787830000.005553",
        revision: 2
      )

    context = context!(entry)
    other_candidate = candidate!(context, other.id)

    assert {:ok, _first_revision} =
             Episodes.apply(%Command.AdmitInput{
               actor_ref: "slack:app:A-source-owner-race",
               destination: %{
                 conversation_ref: owner.destination_conversation_ref,
                 thread_ref: owner.destination_thread_ref,
                 transport: owner.destination_transport
               },
               episode_id: owner.id,
               episode_key: owner.key,
               linked_episode_id: owner.linked_episode_id,
               native_input_id: entry.native_input_id,
               occurred_at: DateTime.add(@now, -1, :second),
               payload: %{"text" => "The first revision established the source-item owner."},
               revision: 1,
               turn_ref: "turn-source-owner-race"
             })

    wrong_owner = decision!(:continue_episode, other_candidate.ref, :same_work)

    assert {:error, {:admission_rejected, :context_stale}} =
             Admission.commit(context, wrong_owner, "decision-source-owner-race")

    assert {:ok, pending} = Inbox.fetch(Inbox.ref(entry))
    assert pending.status == :pending
    assert {:ok, unchanged_other} = Episodes.fetch_by_key(other.key)
    refute Map.has_key?(unchanged_other.input_revisions, entry.native_input_id)
  end

  test "a stale source revision cannot apply a reaction chosen before the newer edit" do
    active = create_episode!(thread_ref: "1787830000.000001")
    entry = record_input!(event_ref: "Ev-stale-reaction")
    context = context!(entry)

    assert {:ok, _newer} =
             Episodes.apply(%Command.AdmitInput{
               actor_ref: "slack:app:A-newer-reaction",
               destination: %{
                 conversation_ref: active.destination_conversation_ref,
                 thread_ref: active.destination_thread_ref,
                 transport: active.destination_transport
               },
               episode_id: active.id,
               episode_key: active.key,
               linked_episode_id: active.linked_episode_id,
               native_input_id: entry.native_input_id,
               occurred_at: DateTime.add(@now, 1, :second),
               payload: %{"text" => "The source item was edited before the reaction committed."},
               revision: 2,
               turn_ref: "turn-newer-reaction"
             })

    react = decision!(:react, nil, :unrelated)

    assert {:ok, result} =
             Admission.commit(context, react, "decision-stale-reaction")

    assert result.status == :superseded
    assert result.entry.status == :superseded
    assert result.entry.decision_action == :react
    assert result.episode.id == active.id
    assert result.transitions == []
  end

  test "a historical source owner outranks bounded thread history for a stale revision" do
    thread_ref = "1787830000.008888"

    entry =
      record_input!(
        event_ref: "Ev-stale-omitted-owner",
        message_ref: thread_ref,
        thread_ref: thread_ref
      )

    owner =
      create_episode!(
        thread_ref: thread_ref,
        native_input_id: entry.native_input_id,
        revision: 2,
        complete: true,
        updated_at: DateTime.add(@now, -3_600, :second)
      )

    for index <- 1..20 do
      create_episode!(
        thread_ref: thread_ref,
        message_ref: "1787830001.#{String.pad_leading(Integer.to_string(index), 6, "0")}",
        source_thread_ref: thread_ref,
        complete: true,
        updated_at: DateTime.add(@now, -index, :second)
      )
    end

    context = context!(entry)
    assert Enum.any?(context.candidates, &(&1.episode.id == owner.id))
    selected = Enum.find(context.candidates, &(&1.episode.id != owner.id))
    continue = decision!(:continue_episode, selected.ref, :same_work)

    assert {:ok, result} =
             Admission.commit(context, continue, "decision-stale-omitted-owner")

    assert result.status == :superseded
    assert result.entry.status == :superseded
    assert result.episode.id == owner.id
    assert result.transitions == []

    assert {:ok, unchanged_selected} = Episodes.fetch_by_key(selected.episode.key)
    refute Map.has_key?(unchanged_selected.input_revisions, entry.native_input_id)
  end

  test "a newer revision stays with its existing source-item owner" do
    entry =
      record_input!(
        actor: %{kind: :app, ref: "A123"},
        event_ref: "Ev-owned-revision-two",
        message_ref: "1787830000.007777",
        revision: 2
      )

    owner =
      create_episode!(
        thread_ref: "1787820000.000001",
        native_input_id: entry.native_input_id,
        revision: 1,
        complete: true,
        updated_at: DateTime.add(@now, -40, :day)
      )

    other =
      create_episode!(thread_ref: "1787830000.000002", actor: %{kind: :app, ref: "A123"})

    context = context!(entry)
    owner_candidate = candidate!(context, owner.id)
    other_candidate = candidate!(context, other.id)

    assert owner_candidate.allowed_relations == [:same_work, :history_only]

    wrong_owner = decision!(:continue_episode, other_candidate.ref, :same_work)
    owner_ref = owner_candidate.ref

    assert {:error, {:admission_rejected, :source_item_owner, owner_ref: ^owner_ref}} =
             Admission.validate(context, wrong_owner)

    correct_owner = decision!(:continue_episode, owner_candidate.ref, :same_work)

    assert {:ok, result} =
             Admission.commit(context, correct_owner, "decision-owned-revision-two")

    assert result.status == :applied
    assert result.episode.id == owner.id
    assert result.episode.input_revisions[entry.native_input_id] == 2

    assert {:ok, unchanged_other} = Episodes.fetch_by_key(other.key)
    refute Map.has_key?(unchanged_other.input_revisions, entry.native_input_id)
  end

  test "ignoring a cosmetic revision does not move its source item from the owning episode" do
    message_ref = "1787830000.005555"

    ignored_entry =
      record_input!(
        event_ref: "Ev-owned-revision-ignored",
        message_ref: message_ref,
        revision: 2
      )

    owner =
      create_episode!(
        thread_ref: "1787820000.005555",
        native_input_id: ignored_entry.native_input_id,
        revision: 1
      )

    assert {:ok, ignored} =
             Admission.commit(
               context!(ignored_entry),
               decision!(:ignore, nil, :unrelated),
               "decision-ignore-cosmetic-revision"
             )

    assert ignored.entry.status == :decided
    assert ignored.entry.decision_action == :ignore
    assert {:ok, unchanged_owner} = Episodes.fetch_by_key(owner.key)
    assert unchanged_owner.input_revisions[ignored_entry.native_input_id] == 1

    routed_entry =
      record_input!(
        event_ref: "Ev-owned-revision-routed",
        message_ref: message_ref,
        revision: 3
      )

    context = context!(routed_entry)
    owner_candidate = candidate!(context, owner.id)

    assert {:ok, routed} =
             Admission.commit(
               context,
               decision!(:continue_episode, owner_candidate.ref, :same_work),
               "decision-route-later-revision"
             )

    assert routed.episode.id == owner.id
    assert routed.episode.input_revisions[routed_entry.native_input_id] == 3
  end

  test "a newer revision starts linked work after its former owner was cancelled" do
    entry =
      record_input!(
        event_ref: "Ev-owned-revision-after-cancel",
        message_ref: "1787830000.006666",
        revision: 2
      )

    owner =
      create_episode!(
        thread_ref: "1787820000.006666",
        native_input_id: entry.native_input_id,
        revision: 1
      )

    assert {:ok, cancelled} =
             Episodes.apply(%Command.CancelEpisode{
               cancel_ref: "cancel-owned-revision",
               episode_key: owner.key,
               expected_owner: %{kind: owner.owner_kind, ref: owner.owner_ref},
               occurred_at: DateTime.add(@now, -1, :second),
               reason: "The operator stopped the earlier work."
             })

    assert cancelled.episode.state == :cancelled
    context = context!(entry)
    owner_candidate = candidate!(context, owner.id)
    assert owner_candidate.allowed_relations == [:history_only]
    start = decision!(:start_episode, owner_candidate.ref, :history_only)

    assert {:ok, result} =
             Admission.commit(context, start, "decision-owned-revision-after-cancel")

    assert result.status == :applied
    assert result.episode.id != owner.id
    assert result.episode.linked_episode_id == owner.id
    assert result.episode.input_revisions[entry.native_input_id] == 2
  end

  test "a selected routing decision survives newer input on the same work" do
    active =
      create_episode!(thread_ref: "1787830000.000001", actor: %{kind: :app, ref: "A123"})

    entry =
      record_input!(
        actor: %{kind: :app, ref: "A123"},
        event_ref: "Ev-frozen-before-newer-input"
      )

    context = context!(entry)
    candidate = candidate!(context, active.id)
    continue = decision!(:continue_episode, candidate.ref, :same_work)

    intervening =
      input!(
        content: %{"text" => "A newer lifecycle update arrived while routing."},
        event_ref: "Ev-intervening-update",
        message_ref: "1787832001.000200",
        occurred_at: DateTime.add(@now, 1, :second),
        thread_ref: active.destination_thread_ref
      )

    assert {:ok, _transition} =
             Episodes.apply(%Command.AdmitInput{
               actor_ref: Input.actor_ref(intervening),
               destination: %{
                 conversation_ref: active.destination_conversation_ref,
                 thread_ref: active.destination_thread_ref,
                 transport: active.destination_transport
               },
               episode_id: active.id,
               episode_key: active.key,
               linked_episode_id: active.linked_episode_id,
               native_input_id: intervening.native_input_id,
               occurred_at: intervening.occurred_at,
               payload: Input.document(intervening),
               revision: intervening.revision,
               turn_ref: "turn-intervening-update"
             })

    assert {:ok, result} =
             Admission.commit(context, continue, "decision-before-newer-input")

    assert result.episode.id == active.id
    assert length(result.episode.queued_input_refs) == 2
  end

  test "a selected routing decision can reopen work completed while admission was running" do
    active = create_episode!(thread_ref: "1787832000.000100")

    entry =
      record_input!(
        event_ref: "Ev-frozen-before-completion",
        message_ref: "1787832001.000100",
        thread_ref: active.destination_thread_ref
      )

    context = context!(entry)
    candidate = candidate!(context, active.id)
    assert candidate.allowed_relations == [:same_work, :history_only]

    assert {:ok, _completed} =
             Episodes.apply(%Command.AcceptResult{
               decision_reason: "The earlier work completed while this input was being routed.",
               delivery: :none,
               delivery_ref: nil,
               episode_key: active.key,
               expected_turn_ref: active.owner_ref,
               next_turn_ref: nil,
               occurred_at: DateTime.add(@now, -1, :second),
               result_ref: "result-completed-during-admission"
             })

    continue = decision!(:continue_episode, candidate.ref, :same_work)

    assert {:ok, result} =
             Admission.commit(context, continue, "decision-before-completion")

    assert result.episode.id == active.id
    assert result.episode.state == :working
  end

  defp context!(entry) do
    assert {:ok, context} = context_result(entry)

    context
  end

  defp context_result(entry, lease_ref \\ nil) do
    Admission.context(Inbox.ref(entry),
      now: @now,
      continuation_window: 30 * 60,
      history_window: 30 * 24 * 60 * 60,
      candidate_limit: 8,
      lease_ref: lease_ref
    )
  end

  defp candidate!(context, episode_id) do
    Enum.find(context.candidates, &(&1.episode.id == episode_id)) ||
      flunk("episode #{episode_id} was not offered as a candidate")
  end

  defp decision!(action, episode_ref, relation, selected_work_class \\ :default) do
    reaction = if action == :react, do: %{"emoji_name" => "eyes"}, else: nil

    selected_work_class =
      if selected_work_class == :default, do: work_class(action), else: selected_work_class

    assert {:ok, decision} =
             Decision.parse(%{
               "action" => Atom.to_string(action),
               "episode_ref" => episode_ref,
               "reaction" => reaction,
               "relation" => Atom.to_string(relation),
               "reason" => "Recorded model admission decision for this test.",
               "work_class" => selected_work_class
             })

    decision
  end

  defp work_class(action) when action in [:react, :ignore], do: nil
  defp work_class(:reply), do: "conversational"
  defp work_class(_action), do: "standard"

  defp record_input!(overrides) do
    attributes =
      Keyword.merge(
        [
          actor: %{kind: :user, ref: "U123"},
          channel_ref: "C456",
          content: %{"text" => "Current Slack input"},
          event_kind: :message,
          event_ref: "Ev-#{Ecto.UUID.generate()}",
          message_ref: "1787832000.000100",
          occurred_at: @now,
          revision: 1,
          thread_ref: nil,
          workspace_ref: "TADMISSIONCOMMIT"
        ],
        overrides
      )

    assert {:ok, input} = SlackInput.new(attributes)
    assert {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp create_episode!(options) do
    episode_id = Ecto.UUID.generate()
    episode_key = "existing:#{episode_id}"
    thread_ref = Keyword.fetch!(options, :thread_ref)

    source_input =
      input!(
        actor: Keyword.get(options, :actor, %{kind: :app, ref: "A-old"}),
        content: %{"text" => "Earlier Slack work"},
        event_ref: "Ev-#{Ecto.UUID.generate()}",
        message_ref: Keyword.get(options, :message_ref, thread_ref),
        thread_ref: Keyword.get(options, :source_thread_ref)
      )

    admit = %Command.AdmitInput{
      actor_ref: Input.actor_ref(source_input),
      destination: source_input.destination,
      episode_id: episode_id,
      episode_key: episode_key,
      linked_episode_id: nil,
      native_input_id: Keyword.get(options, :native_input_id, source_input.native_input_id),
      occurred_at: DateTime.add(@now, -60, :second),
      payload: Input.document(source_input),
      revision: Keyword.get(options, :revision, 1),
      turn_ref: "turn-existing-#{episode_id}"
    }

    assert {:ok, _transition} = Episodes.apply(admit)

    case Keyword.get(options, :wait) do
      nil ->
        :ok

      kind ->
        assert {:ok, _transition} =
                 Episodes.apply(%Command.StartWait{
                   deadline_at: if(kind == :event, do: DateTime.add(@now, 3_600), else: nil),
                   episode_key: episode_key,
                   expected_turn_ref: admit.turn_ref,
                   kind: kind,
                   occurred_at: DateTime.add(@now, -30, :second),
                   wait_ref: "wait-#{episode_id}"
                 })
    end

    if Keyword.get(options, :complete, false) do
      assert {:ok, _transition} =
               Episodes.apply(%Command.AcceptResult{
                 decision_reason: "No visible reply was needed.",
                 delivery: :none,
                 delivery_ref: nil,
                 episode_key: episode_key,
                 expected_turn_ref: admit.turn_ref,
                 next_turn_ref: nil,
                 occurred_at: DateTime.add(@now, -30, :second),
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

    assert {:ok, episode} = Episodes.fetch_by_key(episode_key)
    episode
  end

  defp input!(overrides) do
    attributes =
      Keyword.merge(
        [
          actor: %{kind: :app, ref: "A123"},
          channel_ref: "C456",
          content: %{"text" => "A generic Slack message"},
          event_kind: :message,
          event_ref: "Ev123",
          message_ref: "1787832000.000100",
          occurred_at: @now,
          revision: 1,
          thread_ref: nil,
          workspace_ref: "TADMISSIONCOMMIT"
        ],
        overrides
      )

    assert {:ok, input} = SlackInput.new(attributes)
    input
  end
end
