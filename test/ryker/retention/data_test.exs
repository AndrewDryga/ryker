defmodule Ryker.Retention.DataTest do
  use Ryker.DataCase, async: false
  import Ryker.TestHelpers, only: [digest: 1]
  import Ecto.Query
  alias Ryker.Admission.FleetSession
  alias Ryker.Artifacts
  alias Ryker.Behaviors.Behavior
  alias Ryker.Behaviors.StandingAssignmentRun
  alias Ryker.Behaviors.StandingRuleInventory
  alias Ryker.CanonicalJSON
  alias Ryker.CoopFleet.{Command, ControlPlane, Placement}
  alias Ryker.CoopFleet.{SessionEvidence, SessionEvidences, Worker}
  alias Ryker.Delivery.PlatformAction
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Inspectors
  alias Ryker.Learning
  alias Ryker.Learning.Batches
  alias Ryker.Learning.FleetSession, as: LearningFleetSession
  alias Ryker.Learning.Observations
  alias Ryker.LocalRouting.Comparison
  alias Ryker.Memories.CaseRecord
  alias Ryker.Operator.Actions
  alias Ryker.Operator.Retention, as: RetentionOperator
  alias Ryker.Operator.RetentionAction
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Retention.Custody, as: RetentionCustody
  alias Ryker.Retention.Data
  alias Ryker.Schedules.Schedule
  alias Ryker.Schedules.ScheduleOccurrence
  alias Ryker.Slack.{IncidentRoom, IncidentRoomLifecycleEvent, ThreadStatusReceipt}
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.StateTools.{CallLog, CallRecord}
  alias Ryker.WeeklyReport.Report, as: WeeklyReport
  alias Ryker.Work.{Activity, ActivityEvent, Custody, Result, Session, Submission, Turn}

  @old ~U[2020-01-01 00:00:00.000000Z]

  test "operational expiry removes tool bodies and replay cannot restore them" do
    # Tool results duplicate source content; retaining them after the prompt expires leaks history.
    work = settled_work!("tool-body") |> discard_session!()

    event = %{
      "id" => "tool-body",
      "occurred_at" => "2020-01-01T00:00:00.000000Z",
      "payload" => %{
        "tool_call_id" => "tool",
        "status" => "completed",
        "output" => "source-content"
      },
      "sequence" => 1,
      "session_id" => work.session.coop_session_id,
      "turn_id" => work.turn.coop_turn_id,
      "type" => "tool.completed",
      "version" => 1
    }

    assert {:ok, _} = Activity.ingest(work.session.id, [event])
    backdate_operational!(work)
    assert {:ok, _} = Data.prune(settings())
    activity = Repo.one!(ActivityEvent)
    refute inspect(activity.payload) =~ "source-content"
    assert Activity.list_for_episode(work.episode.id) == []
    assert {:ok, %{inserted: 0}} = Activity.ingest(work.session.id, [event])

    assert {:ok, _} =
             Activity.ingest(work.session.id, [
               %{event | "id" => "late-tool-body", "sequence" => 2}
             ])

    refute inspect(Repo.all(ActivityEvent)) =~ "source-content"
    assert Activity.list_for_episode(work.episode.id) == []
  end

  # Every page that lists history drops what a pass removed. Until 2026-09-26
  # they heard of a pass from a trigger's NOTIFY on each pruned table and a
  # five-second poll; a pass now says once, after it commits, which kinds of
  # history it touched, and a pass that removed nothing stays quiet.
  test "a pass that removed history reaches the pages that listed it, and an empty pass does not" do
    :ok = Data.subscribe_pruning()
    assert {:ok, _result} = Data.prune(settings())
    refute_received {:history_pruned, _kinds}

    work = settled_work!("pruning-announced") |> discard_session!()

    CallLog.record(
      work,
      "propose_automation",
      %{"proposals" => [%{"title" => "pruning-announced proposal"}]},
      {:error, "invalid_arguments"},
      @old
    )

    backdate_operational!(work)
    assert {:ok, _result} = Data.prune(settings())
    assert_received {:history_pruned, [_kind | _kinds]}
  end

  # Failures and Activity show who retried, rearmed or discarded what. Until
  # 2026-09-26 they heard of an operator action from a trigger's NOTIFY and a
  # five-second poll; the action is now announced once it commits.
  test "an operator action reaches the pages that show who acted" do
    :ok = Actions.subscribe_actions()
    insert_operator_action!("announced")
    assert {:ok, %{id: id}} = Actions.fetch("operator-action:announced")
    assert_received {:operator_action_recorded, ^id}
  end

  test "a recorded state-tool call expires with its turn's bodies" do
    # Ryker keeps the arguments and error of each state-tool call because Coop
    # never sends them. They copy what the model wrote, so they must leave with
    # the turn's other bodies instead of outliving them.
    work = settled_work!("state-tool-call") |> discard_session!()

    CallLog.record(
      work,
      "propose_automation",
      %{"proposals" => [%{"title" => "state-tool-call secret proposal"}]},
      {:error, "invalid_arguments"},
      @old
    )

    assert [%CallRecord{status: "failed"}] = Repo.all(CallRecord)
    backdate_operational!(work)
    assert {:ok, _} = Data.prune(settings())
    assert Repo.all(CallRecord) == []
    assert CallLog.list_for_episode(work.episode.id) == []
  end

  test "recorded worker evidence expires with episode history and never resurrects" do
    # The capture holds the bodies a worker exported: refused destinations, the
    # rules its session could reach, and the agent-written task note. They are
    # episode history, so they expire with it -- and a later capture of the same
    # session must not put an expired snapshot back, because the evidence would
    # then describe a session whose history the operator was told is gone.
    work = settled_work!("worker-evidence") |> discard_session!()

    assert {:ok, %{evidence: stored}} =
             SessionEvidences.record(work.session.id, worker_evidence(work.session),
               worker_id: "worker-retention",
               placement_generation: 1
             )

    assert {:ok, _result} = Data.prune(settings())
    assert Repo.get(SessionEvidence, stored.id), "operational pruning took episode history"

    backdate_history!(work, 120)

    # History only: the session row survives this pass, so the re-capture below
    # is a real one rather than a read of a session that no longer exists.
    assert {:ok, _result} =
             Data.prune(settings(episode_history_seconds: 60, audit_data_seconds: 86_400))

    assert Repo.get(SessionEvidence, stored.id) == nil
    assert SessionEvidences.for_session(work.session.id) == []
    assert SessionEvidences.latest_for_episode(work.episode.id) == []

    # A re-capture after expiry records the state observed now; it never revives
    # the expired row, and the page shows an episode with no retained evidence.
    assert {:ok, %{evidence: recaptured, recorded: :inserted}} =
             SessionEvidences.record(work.session.id, worker_evidence(work.session),
               worker_id: "worker-retention",
               placement_generation: 1
             )

    assert recaptured.id != stored.id

    Repo.delete_all(from(row in SessionEvidence, where: row.id == ^recaptured.id))
  end

  test "worker evidence cannot outlive the session row it describes" do
    # Audit pruning removes the session itself. Evidence keyed to it must go in
    # the same pass: a snapshot whose session no longer exists is unattributable
    # to any worker, placement or episode.
    work = settled_work!("worker-evidence-audit") |> discard_session!()

    assert {:ok, %{evidence: stored}} =
             SessionEvidences.record(work.session.id, worker_evidence(work.session),
               worker_id: "worker-audit",
               placement_generation: 1
             )

    backdate_history!(work, 3_600)
    mark_history_pruned!(work)

    assert {:ok, _result} =
             Data.prune(settings(episode_history_seconds: 60, audit_data_seconds: 600))

    assert Repo.get(Session, work.session.id) == nil
    assert Repo.get(SessionEvidence, stored.id) == nil
  end

  test "a recorded rule inventory expires with episode history and is never rebuilt" do
    # The inventory is the only record of which rules existed when an input was
    # processed. Once it expires the page must say "not recorded", not consult
    # today's rules; and until then it must survive operational pruning.
    old = rule_inventory!("old", DateTime.add(DateTime.utc_now(), -3_600, :second))
    fresh = rule_inventory!("fresh", DateTime.utc_now())

    assert {:ok, result} = Data.prune(settings(episode_history_seconds: 60))
    # Other suites accept inputs concurrently, so count only what this test owns.
    assert result.rule_inventories >= 1
    assert Repo.get(StandingRuleInventory, old.id) == nil
    assert Repo.get(StandingRuleInventory, fresh.id)

    assert Inspectors.rule_inventory("input:old") == nil
    assert Inspectors.rule_inventory("input:fresh").id == fresh.id
  end

  test "old instruction edit receipts expire without clearing the current value or its revision" do
    alias Ryker.Instructions
    alias Ryker.Instructions.Edit
    assert {:ok, _} = Instructions.save(:global, "Original", 0, "operator:test")
    Repo.update_all(Edit, set: [inserted_at: ~U[2000-01-01 00:00:00.000000Z]])
    assert {:ok, _} = Instructions.save(:global, "Current", 1, "operator:test")
    assert {:ok, _} = Data.prune(settings())
    assert [%Edit{revision: 2}] = Repo.all(Edit)
    assert Instructions.get(:global).text == "Current"
    assert Instructions.get(:global).revision == 2
  end

  test "operational bodies expire only after the exact Coop workspace is discarded" do
    discarded = settled_work!("discarded-secret") |> discard_session!()
    retained = settled_work!("active-secret")
    backdate_operational!(discarded)
    backdate_operational!(retained)

    assert {:ok, result} = Data.prune(settings())
    assert result.operational_turns == 1

    pruned = Repo.get!(Turn, discarded.turn.id)
    assert %DateTime{} = pruned.operational_pruned_at
    refute inspect(pruned.submission) =~ "discarded-secret"
    refute pruned.candidate =~ "discarded-secret"
    assert pruned.submission_fingerprint == discarded.turn.submission_fingerprint
    assert pruned.validation_receipt == "validation:discarded-secret"

    # Which inputs a turn read is content-free identity, so it outlives the
    # prompt body. Losing it would leave an expired turn unable to say what it
    # was answering, and "not recorded" would then be a lie about this turn.
    assert pruned.selected_input_refs == discarded.turn.selected_input_refs
    assert pruned.selected_input_refs != nil

    untouched = Repo.get!(Turn, retained.turn.id)
    assert untouched.operational_pruned_at == nil
    assert inspect(untouched.submission) =~ "active-secret"
  end

  test "input artifacts remain while referenced and retire with operational input custody" do
    suffix = Ecto.UUID.generate()

    assert {:ok, artifact} =
             Artifacts.put(%{
               data: "retained artifact #{suffix}",
               media_type: "text/plain",
               name: "evidence.txt",
               source_kind: "slack",
               source_ref: "T-retention:F-#{suffix}"
             })

    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: :user, ref: "U-retention"},
               content: %{
                 "files" => [
                   %{
                     "artifact_ref" => artifact.ref,
                     "bytes" => artifact.byte_size,
                     "media_type" => artifact.media_type,
                     "name" => artifact.name,
                     "sha256" => artifact.sha256,
                     "status" => "available"
                   }
                 ],
                 "text" => "Inspect this evidence."
               },
               destination: %{
                 conversation_ref: "slack:T-retention:C-retention",
                 thread_ref: "1788000000.000001",
                 transport: "slack"
               },
               event_kind: :message,
               event_ref: "retention-artifact:#{suffix}",
               native_input_id: "retention-artifact:#{suffix}",
               occurred_at: ~U[2026-08-29 12:00:00.000000Z],
               occurred_at_source: :source,
               revision: 1,
               source: %{kind: "slack", ref: "T-retention"},
               source_capabilities: %{"react" => %{"emoji_names" => nil}},
               source_item_ref: "1788000000.000001"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)

    # Admission request copies must follow input retention, not survive it in a
    # second table after the original sensitive input is pruned.
    admission_artifact = %{"prompt" => "retained admission source", "output_schema" => %{}}

    attempt =
      Repo.insert!(%Ryker.Admission.Attempt{
        input_id: entry.id,
        generation: 1,
        policy: "retention-test",
        policy_digest: String.duplicate("a", 64),
        submission: admission_artifact,
        submission_fingerprint: CanonicalJSON.digest(admission_artifact),
        rejections: [
          %{
            "attempt" => 1,
            "sha256" => String.duplicate("e", 64),
            "answer" => ~s({"action":"reply","reason":"retained admission source"}),
            "reason" => "rejected:unknown_candidate",
            "correction" => "episode_ref is not one of the opaque candidate references"
          }
        ]
      })

    assert Repo.query!(
             "SELECT artifact_id FROM ingress_input_artifact_references WHERE input_id = $1",
             [uuid!(entry.id)]
           ).rows == [[uuid!(artifact.id)]]

    Repo.query!(
      """
      UPDATE ingress_inbox_entries
      SET status = 'decided', decision_ref = $1, decision_fingerprint = $2,
          decision_action = 'ignore', decision_document = '{"action":"ignore"}',
          updated_at = $3
      WHERE id = $4
      """,
      [
        "decision:#{suffix}",
        String.duplicate("d", 64),
        DateTime.add(DateTime.utc_now(), -120, :second),
        uuid!(entry.id)
      ]
    )

    Repo.query!("UPDATE input_artifacts SET updated_at = $1 WHERE id = $2", [
      @old,
      uuid!(artifact.id)
    ])

    assert {:ok, result} = Data.prune(settings(audit_data_seconds: 600))
    assert result.operational_inputs == 1
    assert result.input_artifacts == 1
    assert Repo.get(Ryker.Artifacts.Artifact, artifact.id) == nil
    pruned_attempt = Repo.get!(Ryker.Admission.Attempt, attempt.id)
    assert %DateTime{} = pruned_attempt.operational_pruned_at
    assert pruned_attempt.submission == %{"retention" => "pruned"}
    assert pruned_attempt.submission_fingerprint == attempt.submission_fingerprint
    # An answer routing refused quotes what the prompt did, so it goes too.
    assert pruned_attempt.rejections == nil
  end

  # Audit pruning deleted a message whose routing session Ryker was still
  # closing. The foreign key emptied the session's input, and a session that
  # names no input can never be closed or pruned, nor rearmed (2026-10-04
  # review). The message stays until its sessions are discarded.
  test "a message stays while its routing session is still being closed" do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Route this one."},
               event_kind: :message,
               event_ref: "Ev-retention-closing-session",
               message_ref: "1787832000.000200",
               occurred_at: ~U[2026-08-30 12:00:00.000000Z],
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T123"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)

    assert {:ok, session} =
             FleetSession.ensure(entry, %{
               name: "admission-read-only",
               digest: String.duplicate("a", 64)
             })

    Repo.query!(
      "UPDATE episode_work_sessions SET cleanup_status = 'discard_pending' WHERE id = $1",
      [uuid!(session.id)]
    )

    Repo.query!(
      "UPDATE ingress_inbox_entries SET operational_pruned_at = $1, updated_at = $1 WHERE id = $2",
      [@old, uuid!(entry.id)]
    )

    assert {:ok, _result} = Data.prune(settings())
    assert Repo.get(Ryker.Ingress.Inbox.Entry, entry.id)
    assert Repo.get!(Session, session.id).admission_input_id == entry.id

    Repo.query!("UPDATE episode_work_sessions SET cleanup_status = 'discarded' WHERE id = $1", [
      uuid!(session.id)
    ])

    assert {:ok, _result} = Data.prune(settings())
    refute Repo.get(Ryker.Ingress.Inbox.Entry, entry.id)
  end

  test "settled admission fleet identity retires without a fabricated episode" do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Classify this remotely."},
               event_kind: :message,
               event_ref: "Ev-retention-admission-fleet",
               message_ref: "1787832000.000100",
               occurred_at: ~U[2026-08-30 12:00:00.000000Z],
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T123"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)

    assert {:ok, session} =
             FleetSession.ensure(entry, %{
               name: "admission-read-only",
               digest: String.duplicate("a", 64)
             })

    assert {:ok, _bound} = FleetSession.bind(entry, "coop-admission-retention")
    assert {:ok, _settled} = FleetSession.settle(entry, "coop-admission-retention")

    worker =
      Repo.insert!(%Worker{
        certificate_sha256: String.duplicate("b", 64),
        id: "worker:admission-retention",
        workspace_ref: "workspace-main"
      })

    placement =
      Repo.insert!(%Placement{
        generation: 1,
        id: Ecto.UUID.generate(),
        last_acked_event_sequence: 0,
        lease_expires_at: ~U[2026-08-30 12:01:00.000000Z],
        lease_ref: "placement-lease:admission-retention",
        requirements: %{},
        requirements_fingerprint: CanonicalJSON.digest(%{}),
        session_id: session.id,
        state: :retired,
        worker_id: worker.id
      })

    Repo.query!("UPDATE episode_work_sessions SET updated_at = $1 WHERE id = $2", [
      @old,
      uuid!(session.id)
    ])

    # Routing evidence must neither block retention forever nor vanish before its input expires.
    assert {:ok, _} =
             Activity.ingest(session.id, [
               %{
                 "id" => "retention-routing",
                 "occurred_at" => "2020-01-01T00:00:00.000000Z",
                 "payload" => %{
                   "tool_call_id" => "routing",
                   "status" => "completed",
                   "output" => "routing-source"
                 },
                 "sequence" => 1,
                 "session_id" => "coop-admission-retention",
                 "turn_id" => "routing-turn",
                 "type" => "tool.completed",
                 "version" => 1
               }
             ])

    Repo.query!("UPDATE episode_work_sessions SET updated_at = $1 WHERE id = $2", [
      @old,
      uuid!(session.id)
    ])

    assert {:ok, _result} = Data.prune(settings())
    assert Repo.get(Session, session.id)
    assert Repo.one!(ActivityEvent).payload["output"] == "routing-source"

    Repo.query!("UPDATE ingress_inbox_entries SET operational_pruned_at = $1 WHERE id = $2", [
      @old,
      uuid!(entry.id)
    ])

    assert {:ok, _result} = Data.prune(settings())
    refute inspect(Repo.all(ActivityEvent)) =~ "routing-source"

    Repo.query!("UPDATE episode_work_sessions SET updated_at = $1 WHERE id = $2", [
      DateTime.utc_now(),
      uuid!(session.id)
    ])

    assert {:ok, _result} = Data.prune(settings())
    assert Repo.get(Session, session.id)
    assert Repo.aggregate(ActivityEvent, :count) == 1

    Repo.query!("UPDATE episode_work_sessions SET updated_at = $1 WHERE id = $2", [
      @old,
      uuid!(session.id)
    ])

    assert {:ok, _result} = Data.prune(settings())
    assert Repo.get(Placement, placement.id)
    assert Repo.get(Session, session.id).cleanup_status == :plan_pending

    # Historical pruning cannot stand in for remote cleanup. Once the remote
    # discard receipt exists, the old placement and session may retire.
    discard_session!(%{session: Repo.get!(Session, session.id)})

    Repo.query!("UPDATE episode_work_sessions SET updated_at = $1 WHERE id = $2", [
      @old,
      uuid!(session.id)
    ])

    assert {:ok, _result} = Data.prune(settings())
    assert Repo.get(Placement, placement.id) == nil
    assert Repo.get(Session, session.id) == nil
  end

  # The operational prune deleted only succeeded and failed worker commands, and a routing,
  # learning or knowledge session is deleted only once no command names it. A command Coop
  # never answered, or answered too late, stayed "delivered" or "uncertain" for good, so its
  # session, its placement and the prompt the command carried were never deleted (2026-10-04
  # review; 9 such commands were waiting on the live install that day).
  test "a discarded session's commands leave with it whatever their state" do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Route this remotely."},
               event_kind: :message,
               event_ref: "Ev-retention-stranded-commands",
               message_ref: "1787832000.000200",
               occurred_at: ~U[2026-08-30 12:00:00.000000Z],
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T123"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)

    assert {:ok, session} =
             FleetSession.ensure(entry, %{
               name: "admission-read-only",
               digest: String.duplicate("a", 64)
             })

    assert {:ok, _bound} = FleetSession.bind(entry, "coop-stranded-commands")
    assert {:ok, _settled} = FleetSession.settle(entry, "coop-stranded-commands")

    worker =
      Repo.insert!(%Worker{
        certificate_sha256: String.duplicate("c", 64),
        id: "worker:stranded-commands",
        workspace_ref: "workspace-main"
      })

    placement =
      Repo.insert!(%Placement{
        generation: 1,
        id: Ecto.UUID.generate(),
        last_acked_event_sequence: 0,
        lease_expires_at: DateTime.add(Repo.now!(), 60, :second),
        lease_ref: "placement-lease:stranded-commands",
        requirements: %{},
        requirements_fingerprint: CanonicalJSON.digest(%{}),
        session_id: session.id,
        state: :active,
        worker_id: worker.id
      })

    enqueue = fn key ->
      assert {:ok, command} =
               ControlPlane.enqueue_command(
                 placement.id,
                 "get_session",
                 %{"coop_session_id" => "coop-stranded-commands"},
                 key
               )

      command
    end

    delivered = enqueue.("ryker:test:stranded:delivered")
    uncertain = enqueue.("ryker:test:stranded:uncertain")

    Repo.update_all(
      from(command in Command, where: command.id == ^delivered.id),
      set: [status: :delivered, delivered_at: @old, updated_at: @old]
    )

    Repo.update_all(
      from(command in Command, where: command.id == ^uncertain.id),
      set: [
        status: :uncertain,
        delivered_at: @old,
        operation_key: uncertain.idempotency_key,
        error: %{"code" => "placement_not_authorized", "status" => 409},
        result_fingerprint: String.duplicate("d", 64),
        completed_at: @old,
        updated_at: @old
      ]
    )

    Repo.update_all(from(p in Placement, where: p.id == ^placement.id), set: [state: :retired])
    discard_session!(%{session: Repo.get!(Session, session.id)})

    Repo.query!("UPDATE episode_work_sessions SET updated_at = $1 WHERE id = $2", [
      @old,
      uuid!(session.id)
    ])

    assert {:ok, _result} = Data.prune(settings())
    assert {:ok, _result} = Data.prune(settings())

    assert Repo.aggregate(
             from(command in Command, where: command.session_id == ^session.id),
             :count
           ) == 0

    assert Repo.get(Placement, placement.id) == nil
    assert Repo.get(Session, session.id) == nil
  end

  # A comparison holds the local routing model's answer to a routing prompt
  # that quotes the message. It is operational data with no horizon of its
  # own: it stays exactly as long as its message's bodies and leaves with
  # them, never outliving what it answered.
  test "a local routing comparison leaves with its message's bodies and not before" do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "hi, reply with one word please"},
               event_kind: :message,
               event_ref: "Ev-retention-local-routing",
               message_ref: "1787832000.000200",
               occurred_at: ~U[2026-09-27 14:53:25.000000Z],
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T123"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)

    comparison =
      Repo.insert!(%Comparison{
        input_id: entry.id,
        source_identity: Observations.source_identity(entry),
        generation: 1,
        execution_mode: :live,
        status: :compared,
        attempt_count: 1,
        local_model: "qwen2.5:3b",
        valid: true,
        agrees: true,
        differing_fields: [],
        local_answer: ~s({"action":"quick_reply","messages":["Hi!"]}),
        local_ms: 900,
        compared_at: @old,
        inserted_at: @old,
        updated_at: @old
      })

    assert {:ok, _result} = Data.prune(settings())
    assert Repo.get(Comparison, comparison.id)

    Repo.query!("UPDATE ingress_inbox_entries SET operational_pruned_at = $1 WHERE id = $2", [
      @old,
      uuid!(entry.id)
    ])

    assert {:ok, _result} = Data.prune(settings())
    assert Repo.get(Comparison, comparison.id) == nil
  end

  test "a rearmed learning session outlives its operator decision instead of stalling retention" do
    # retention_operator_actions.session_id is ON DELETE RESTRICT and the audit
    # ledger keeps the row for audit_data_seconds. The operational prune deleted
    # discarded admission and learning sessions without looking, so the first
    # learning session an operator rearmed made that DELETE raise a day after
    # its discard — and, being the oldest candidate, on every pass after that,
    # aborting the operational, closed-work, history and audit phases for good.
    # Found by reading the foreign keys, before any operator had pressed Rearm.
    assert {:ok, run} =
             Learning.prepare(Enum.map(LearningFixtures.inputs!(), & &1.id), %{
               policy: "recorded-read-only-policy",
               policy_digest: String.duplicate("a", 64)
             })

    assert {:ok, _session} = LearningFleetSession.ensure(run)
    assert {:ok, session} = LearningFleetSession.bind(run, "coop-learning-rearmed")

    run
    |> Ecto.Changeset.change(
      remote_stopped_at: DateTime.utc_now(),
      stop_receipt: %{"kind" => "terminal_turn", "state" => "completed"}
    )
    |> Repo.update!()

    assert {:ok, claim} = RetentionCustody.claim_next("cleanup", 60)
    assert claim.session.id == session.id

    assert {:ok, _blocked} =
             RetentionCustody.block(
               session.id,
               claim.lease_ref,
               "coop_protocol_error",
               "close refused"
             )

    assert {:ok, %{outcome: :rearmed}} =
             RetentionOperator.rearm(
               session.external_ref,
               "slack:user:operator",
               "retention-action:rearm"
             )

    assert {:ok, claim} = RetentionCustody.claim_next("cleanup", 60)

    assert {:ok, _discarded} =
             RetentionCustody.settle_remote_discarded(
               session.id,
               claim.lease_ref,
               "coop-learning-rearmed"
             )

    Repo.query!(
      "UPDATE episode_work_sessions SET updated_at = $1 WHERE id = $2",
      [@old, uuid!(session.id)]
    )

    # The decision ledger still names the session, so the session row stays
    # with it; nothing else in the pass may be skipped because of that.
    assert {:ok, _result} = Data.prune(settings(audit_data_seconds: 86_400))
    assert Repo.get(Session, session.id)

    assert Repo.get_by!(RetentionAction, action_ref: "retention-action:rearm").session_id ==
             session.id

    Repo.query!("UPDATE retention_operator_actions SET inserted_at = $1", [@old])

    assert {:ok, _result} = Data.prune(settings())
    assert Repo.get_by(RetentionAction, action_ref: "retention-action:rearm") == nil

    assert {:ok, _result} = Data.prune(settings())
    assert Repo.get(Session, session.id) == nil
  end

  test "a closed incident room stays while the thread episode that offered it is still open" do
    # A room has two episode owners: the thread episode that offered it and the
    # incident episode that ran in it. History pruning pins on either; the
    # closed-work prune joined only the incident episode, so a room whose
    # incident finished while the offering thread was still waiting on its
    # operator lost the room and its lifecycle events under an active episode.
    source = settled_work!("room-source")
    linked = settled_work!("room-linked") |> discard_session!()
    insert_open_record!(source)
    record = Repo.get_by!(Record, episode_id: source.episode.id)

    Repo.query!("UPDATE episode_kernel_episodes SET state = 'waiting_for_input' WHERE id = $1", [
      uuid!(source.episode.id)
    ])

    room = insert_closed_room!(source.episode.id, linked.episode.id, record.id)

    assert {:ok, result} = Data.prune(settings(closed_work_seconds: 60))
    assert result.closed_work == 0
    assert Repo.get(IncidentRoom, room.id)
    assert Repo.get_by(IncidentRoomLifecycleEvent, room_id: room.id)

    Repo.query!("UPDATE episode_kernel_episodes SET state = 'complete' WHERE id = $1", [
      uuid!(source.episode.id)
    ])

    discard_session!(source)

    assert {:ok, result} = Data.prune(settings(closed_work_seconds: 60))
    assert result.closed_work == 2
    assert Repo.get(IncidentRoom, room.id) == nil
  end

  test "standing runs, rule inventories and status receipts follow their episode, not the calendar" do
    # Three rows carried an episode owner and were pruned by age alone: the
    # standing-assignment run (the dedupe receipt that stops one input firing
    # an assignment twice), the rule inventory recorded for the episode's
    # input, and the receipts of what Slack acknowledged for the episode. An
    # incident open longer than the history horizon lost all three while it
    # was still working.
    work = settled_work!("standing-owner")

    Repo.query!("UPDATE episode_kernel_episodes SET state = 'working' WHERE id = $1", [
      uuid!(work.episode.id)
    ])

    entry = record_input_for!(work.episode.id, "standing-owner")
    insert_open_record!(work)
    run = insert_decided_standing_run!(work.episode.id, entry)
    inventory = Inspectors.rule_inventory(Inbox.ref(entry))
    Repo.query!("UPDATE standing_rule_inventories SET recorded_at = $1", [@old])
    receipt = insert_status_receipt!(work.episode.id)

    assert {:ok, _result} =
             Data.prune(settings(episode_history_seconds: 60, operational_data_seconds: 60))

    assert Repo.get(StandingAssignmentRun, run.id)
    assert Repo.get(StandingRuleInventory, inventory.id)
    assert Repo.get(ThreadStatusReceipt, receipt.id)

    Repo.query!("UPDATE episode_kernel_episodes SET state = 'complete' WHERE id = $1", [
      uuid!(work.episode.id)
    ])

    assert {:ok, _result} =
             Data.prune(settings(episode_history_seconds: 60, operational_data_seconds: 60))

    assert Repo.get(StandingAssignmentRun, run.id) == nil
    assert Repo.get(StandingRuleInventory, inventory.id) == nil
    assert Repo.get(ThreadStatusReceipt, receipt.id) == nil
  end

  # A deleted, replaced or expired rule, preference or guidance was never
  # pruned, and its row kept its source episode's whole history alive with it
  # (2026-10-04 review). It goes at the history horizon, as a finished
  # schedule does; one still in force stays.
  test "an ended behavior goes at the history horizon, and one in force stays" do
    work = settled_work!("ended-behavior")
    entry = record_input_for!(work.episode.id, "ended-behavior")
    insert_open_record!(work)
    behavior = insert_decided_standing_run!(work.episode.id, entry).assignment_id

    Repo.query!("UPDATE operator_behaviors SET updated_at = $1 WHERE id = $2", [
      @old,
      uuid!(behavior)
    ])

    assert {:ok, _result} = Data.prune(settings(episode_history_seconds: 60))
    assert Repo.get(Ryker.Behaviors.Behavior, behavior)

    Repo.query!("UPDATE operator_behaviors SET status = 'deleted' WHERE id = $1", [
      uuid!(behavior)
    ])

    assert {:ok, _result} = Data.prune(settings(episode_history_seconds: 60))
    assert Repo.get(Ryker.Behaviors.Behavior, behavior) == nil
  end

  test "an input a learning run is still judging keeps its body past the operational horizon" do
    # The operational prune checked reactions and Work sessions and never the
    # learning batch. Learning requires the exact input bodies at every step, so
    # pruning under an outstanding run turned the in-flight judgment into
    # learning_source_stale: the Coop turn was fenced, the spent start wasted,
    # and a finished result discarded. A worker outage longer than the
    # operational horizon with one run outstanding was enough.
    entries = LearningFixtures.inputs!() |> LearningFixtures.normalize_queue_timestamps!()

    settings = %{
      policy: "recorded-read-only-policy",
      policy_digest: String.duplicate("a", 64),
      quiet_seconds: 0,
      maximum_delay_seconds: 60,
      lease_seconds: 300,
      batch_size: 16
    }

    assert {:ok, claim} = Batches.claim("worker-retention", settings)
    assert {:ok, run} = Learning.prepare(Enum.map(claim.inputs, & &1.id), settings)
    assert {:ok, _started} = Batches.begin_execution(claim, run.id)

    Repo.update_all(from(entry in Inbox.Entry, where: entry.id in ^Enum.map(entries, & &1.id)),
      set: [updated_at: @old]
    )

    assert {:ok, result} = Data.prune(settings(operational_data_seconds: 60))
    assert result.operational_inputs == 0
    assert {:ok, _authorized} = Learning.authorize(run.id, claim)

    # Once the run has stopped and the batch is released, the bodies expire.
    assert {:ok, _session} = LearningFleetSession.ensure(run)
    assert {:ok, _session} = LearningFleetSession.bind(run, "retention-session:#{run.id}")

    assert {:ok, _run} =
             Learning.bind_turn(
               run.id,
               "retention-session:#{run.id}",
               "retention-turn:#{run.id}",
               claim
             )

    assert {:ok, _} =
             Learning.record_stop(
               run.id,
               %{
                 "id" => "retention-turn:#{run.id}",
                 "session_id" => "retention-session:#{run.id}",
                 "state" => "failed"
               },
               claim
             )

    assert {:ok, _batch} = Batches.finish(claim, :no_change)
    assert {:ok, result} = Data.prune(settings(operational_data_seconds: 60))
    assert result.operational_inputs == length(entries)
  end

  test "episode history is indivisible, pinned while live work depends on it, and audit survives longer" do
    eligible = settled_work!("history") |> discard_session!()
    pinned = settled_work!("pinned") |> discard_session!()
    insert_activity!(eligible, "history")
    insert_open_record!(pinned)
    backdate_history!(eligible, 120)
    backdate_history!(pinned, 120)

    assert {:ok, result} =
             Data.prune(settings(episode_history_seconds: 60, audit_data_seconds: 600))

    assert result.episode_histories == 1

    assert Repo.aggregate(
             from(event in Ryker.Episodes.Event,
               where: event.episode_id == ^eligible.episode.id
             ),
             :count
           ) == 0

    assert %DateTime{} =
             Repo.get!(Ryker.Episodes.Episode, eligible.episode.id).history_pruned_at

    assert Repo.aggregate(
             from(activity in ActivityEvent,
               where: activity.episode_id == ^eligible.episode.id
             ),
             :count
           ) == 0

    assert Repo.get!(Session, eligible.session.id).cleanup_receipt["kind"] == "discarded"

    assert Repo.aggregate(
             from(event in Ryker.Episodes.Event,
               where: event.episode_id == ^pinned.episode.id
             ),
             :count
           ) > 0

    assert Repo.get!(Ryker.Episodes.Episode, pinned.episode.id).history_pruned_at == nil

    assert {:ok, result} = Data.prune(settings(audit_data_seconds: 60))
    assert result.audit_episodes == 1
    assert Repo.get(Ryker.Episodes.Episode, eligible.episode.id) == nil
    assert Repo.get(Session, eligible.session.id) == nil
    assert Repo.get(Turn, eligible.turn.id) == nil
  end

  # A failure someone left was remembered forever, long after the failure
  # itself was gone, and each one made every later Failures read deeper
  # (2026-10-04 review). A choice to leave one is audit history: it goes at
  # the audit horizon, and a failure still failing then shows once more.
  test "a failure someone left is remembered until the audit horizon" do
    now = Repo.now!()

    for {ref, left_at} <- [{"old", DateTime.add(now, -7_200, :second)}, {"recent", now}] do
      Repo.insert!(%Ryker.Operator.FailureDismissal{
        failure_summary: "the reply could not be delivered",
        kind: "delivery",
        left_at: left_at,
        left_by: "control-plane:local",
        ref: "delivery:" <> ref
      })
    end

    assert {:ok, _result} = Data.prune(settings(audit_data_seconds: 3_600))

    assert Repo.all(from(left in Ryker.Operator.FailureDismissal, select: left.ref)) == [
             "delivery:recent"
           ]
  end

  # A button answer goes to the task that asked only while that task waits;
  # otherwise routing gives it to another task, whose input it becomes while
  # the answer row still points at it. Audit pruning of that other task deleted
  # the input under the answer's foreign key, failing the whole audit phase,
  # and the same oldest episode led every later pass (2026-10-04 review).
  test "an input another task's answer points at keeps its episode until the answer goes" do
    answered = settled_work!("answer-elsewhere") |> discard_session!()
    asking = settled_work!("answer-asking") |> discard_session!()
    neighbour = settled_work!("answer-neighbour") |> discard_session!()
    insert_open_record!(asking)
    entry = record_input_for!(answered.episode.id, "answer-elsewhere")

    Repo.query!(
      """
      INSERT INTO episode_state_record_responses
        (id, record_id, inbox_entry_id, response_ref, actor_ref, occurred_at,
         inserted_at, updated_at)
      SELECT $1, record.id, $2, 'response:answer-elsewhere', 'slack:user:U123', $3, $3, $3
      FROM episode_state_records record
      WHERE record.episode_id = $4
      """,
      [uuid!(Ecto.UUID.generate()), uuid!(entry.id), @old, uuid!(asking.episode.id)]
    )

    mark_history_pruned!(answered)
    mark_history_pruned!(neighbour)

    assert {:ok, result} = Data.prune(settings())
    assert result.audit_episodes == 1
    assert Repo.get(Ryker.Episodes.Episode, neighbour.episode.id) == nil
    assert Repo.get(Ryker.Episodes.Episode, answered.episode.id)
    assert Repo.get(Ryker.Ingress.Inbox.Entry, entry.id)
  end

  test "a closed approval watch lets its task's history expire, a live one pins it" do
    # Ryker closes an approval watch nothing waits for any more (its task was
    # closed, or its wait was answered). The history guard treated every status
    # but resumed as live, so each closed watch kept its task's history past the
    # retention horizon for good.
    closed = settled_work!("approval-closed") |> discard_session!()
    watched = settled_work!("approval-watched") |> discard_session!()
    insert_approval!(closed, "closed")
    insert_approval!(watched, "monitoring")
    backdate_history!(closed, 120)
    backdate_history!(watched, 120)

    assert {:ok, result} =
             Data.prune(settings(episode_history_seconds: 60, audit_data_seconds: 600))

    assert result.episode_histories == 1
    assert %DateTime{} = Repo.get!(Ryker.Episodes.Episode, closed.episode.id).history_pruned_at
    assert Repo.get!(Ryker.Episodes.Episode, watched.episode.id).history_pruned_at == nil

    assert Repo.aggregate(
             from(approval in Ryker.Emisar.Approval,
               where: approval.episode_id == ^closed.episode.id
             ),
             :count
           ) == 0

    assert Repo.aggregate(
             from(approval in Ryker.Emisar.Approval,
               where: approval.episode_id == ^watched.episode.id
             ),
             :count
           ) == 1
  end

  test "routine cleanup reclaims the transcript and leaves the retained case standing" do
    # A matching incident a year later has to start from what was learned, but
    # the raw transcript, the Coop workspace and the episode rows it came from
    # are disposable and must still be reclaimed on schedule.
    work = settled_work!("retained-case") |> discard_session!()
    backdate_history!(work, 120)

    assert {:ok, result} =
             Data.prune(settings(episode_history_seconds: 60, audit_data_seconds: 600))

    assert result.episode_histories == 1

    retained = Repo.get_by!(CaseRecord, case_ref: "case:#{work.episode.id}")
    assert retained.status == :active
    assert retained.episode_key == work.episode.key

    # The audit horizon removes the episode row itself; the case does not
    # depend on it and survives with its own identity.
    assert {:ok, _result} = Data.prune(settings(audit_data_seconds: 60))
    assert Repo.get(Ryker.Episodes.Episode, work.episode.id) == nil
    assert Repo.get_by!(CaseRecord, case_ref: "case:#{work.episode.id}").status == :active
  end

  test "an inert finding follows history expiry while an unanswered question still pins custody" do
    # Findings are facts, not unresolved offers: the new tool must not turn one
    # conclusion into permanent retention of the entire settled investigation.
    fact = settled_work!("finding-expiry") |> discard_session!()
    question = settled_work!("question-expiry") |> discard_session!()
    insert_open_record!(fact)

    Repo.query!("UPDATE episode_state_records SET sequence = 2 WHERE episode_id = $1", [
      uuid!(fact.episode.id)
    ])

    insert_open_record!(question)

    Repo.query!("UPDATE episode_state_records SET kind = 'finding' WHERE episode_id = $1", [
      uuid!(fact.episode.id)
    ])

    backdate_history!(fact, 120)
    backdate_history!(question, 120)

    assert {:ok, result} =
             Data.prune(settings(episode_history_seconds: 60, audit_data_seconds: 600))

    assert result.episode_histories == 1
    assert %DateTime{} = Repo.get!(Ryker.Episodes.Episode, fact.episode.id).history_pruned_at
    assert Repo.get!(Ryker.Episodes.Episode, question.episode.id).history_pruned_at == nil

    assert Repo.aggregate(
             from(r in Ryker.Records.Record, where: r.episode_id == ^fact.episode.id),
             :count
           ) == 0

    assert Repo.aggregate(
             from(r in Ryker.Records.Record, where: r.episode_id == ^question.episode.id),
             :count
           ) == 1
  end

  test "old transport, memory, and audit rows prune without touching unresolved custody" do
    delivered = insert_reaction!("delivered", "delivered")
    blocked = insert_reaction!("blocked", "blocked")
    credential_event_id = Ecto.UUID.generate()

    Repo.insert!(%Ryker.Credential.Event{
      id: credential_event_id,
      kind: :webhook,
      name: "retention-audit",
      action: :deleted,
      actor_ref: "control-plane:local",
      inserted_at: @old
    })

    insert_setting_audit!("old-audit")
    insert_interaction_audit!("old-interaction")
    insert_operator_action!("old-operator-action")
    backdate_rows!()

    assert {:ok, result} = Data.prune(settings(conversation_memory_seconds: 60))
    assert result.routing_responses == 1
    assert Repo.get(Ryker.Delivery.RoutingResponse, delivered) == nil
    assert Repo.get!(Ryker.Delivery.RoutingResponse, blocked).status == :blocked
    assert result.audit_rows == 5
    assert Repo.get(Ryker.Credential.Event, credential_event_id) == nil
    assert Actions.fetch("operator-action:old-operator-action") == :error
  end

  # The retention audit, 2026-09-26: the policy called GitHub deliveries
  # operational, but nothing ever removed one, so every webhook since
  # 2026-09-20 was still held. De-duplication needs only recent deliveries and
  # connection health only the newest, so those and anything still waiting to
  # be processed are what stays.
  test "processed GitHub deliveries leave after the horizon, but not the newest or unprocessed" do
    old_processed = insert_github_event!("github-main", "old-processed", "routed", @old)
    newest = insert_github_event!("github-main", "newest", "routed", DateTime.add(@old, 60))
    waiting = insert_github_event!("github-main", "waiting", "received", @old)
    superseded = insert_github_event!("github-other", "superseded", "metadata", @old)
    recent = insert_github_event!("github-other", "recent", "routed", DateTime.utc_now())
    quiet = insert_github_event!("github-quiet", "quiet", "routed", @old)

    assert {:ok, _result} = Data.prune(settings())

    refute Repo.get(Ryker.GitHub.Event, old_processed)
    refute Repo.get(Ryker.GitHub.Event, superseded)
    assert Repo.get(Ryker.GitHub.Event, newest)
    assert Repo.get(Ryker.GitHub.Event, waiting)
    assert Repo.get(Ryker.GitHub.Event, recent)

    # A repository that went quiet keeps its one old delivery: health says
    # when Ryker last heard from GitHub, not "never".
    assert Repo.get(Ryker.GitHub.Event, quiet)
  end

  # A week's row is how the scheduler knows the week was sent, and the latest
  # send time it checks is up to a week old. With the operational horizon at
  # its minimum of a minute, pruning at the horizon alone would let a restart
  # post the same week again; one still being posted is delivery custody.
  test "a week's report stays two weeks past its send time whatever the horizon, and one still posting never goes" do
    now = DateTime.utc_now()

    weekly_report!(~D[2020-03-02], DateTime.add(now, -3, :day), :delivered)
    weekly_report!(~D[2020-02-24], DateTime.add(now, -20, :day), :delivered)
    weekly_report!(~D[2020-02-17], DateTime.add(now, -27, :day), :blocked)
    weekly_report!(~D[2020-02-10], DateTime.add(now, -34, :day), :pending)

    assert {:ok, _result} = Data.prune(settings())

    assert Repo.all(from(r in WeeklyReport, order_by: r.week, select: r.week)) ==
             [~D[2020-02-10], ~D[2020-03-02]]
  end

  test "each maintenance transaction mutates only one bounded row batch" do
    for index <- 1..101, do: insert_setting_audit!("batch-#{index}")

    assert {:ok, first} = Data.prune(settings())
    assert first.audit_rows == 100
    assert Repo.aggregate(Ryker.Slack.ChannelSettingAudit, :count) == 1

    assert {:ok, second} = Data.prune(settings())
    assert second.audit_rows == 1
    assert Repo.aggregate(Ryker.Slack.ChannelSettingAudit, :count) == 0
  end

  test "an active scheduled child pins the occurrence that prevents overlapping work" do
    source = settled_work!("schedule-source")
    child = start_active_episode!("schedule-child")
    occurrence = insert_old_schedule_occurrence!(source, child)

    assert {:ok, first} = Data.prune(settings())
    assert first.schedule_runs == 0
    assert Repo.get!(ScheduleOccurrence, occurrence.id).child_episode_id == child.id

    assert {:ok, _completed} =
             Episodes.apply(
               EpisodeFixtures.accept_result(%{
                 decision_reason: "Scheduled work finished.",
                 delivery: :none,
                 delivery_ref: nil,
                 episode_key: child.key,
                 expected_turn_ref: child.owner_ref,
                 result_ref: "result:schedule-child"
               })
             )

    Repo.query!(
      "UPDATE episode_kernel_episodes SET updated_at = $1 WHERE id = $2",
      [@old, uuid!(child.id)]
    )

    assert {:ok, second} = Data.prune(settings())
    assert second.schedule_runs == 1
    assert Repo.get(ScheduleOccurrence, occurrence.id) == nil
  end

  test "a terminal schedule remains until its active child occurrence is retired" do
    source = settled_work!("terminal-schedule-source")
    child = start_active_episode!("terminal-schedule-child")
    occurrence = insert_old_schedule_occurrence!(source, child)

    {1, nil} =
      Repo.update_all(
        from(schedule in Schedule, where: schedule.id == ^occurrence.schedule_id),
        set: [status: :completed, updated_at: @old]
      )

    assert {:ok, result} = Data.prune(settings())
    assert result.schedule_runs == 0
    assert Repo.get!(Schedule, occurrence.schedule_id).status == :completed
    assert Repo.get!(ScheduleOccurrence, occurrence.id).child_episode_id == child.id
  end

  test "unresolved platform actions pin history and delivered actions retire before their turn" do
    work = settled_work!("platform-action") |> discard_session!()
    action = insert_platform_action!(work)
    backdate_history!(work, 120)

    assert {:ok, first} =
             Data.prune(settings(episode_history_seconds: 60, audit_data_seconds: 600))

    assert first.episode_histories == 0
    assert Repo.get!(PlatformAction, action.id).status == :pending
    assert Repo.get!(Ryker.Episodes.Episode, work.episode.id).history_pruned_at == nil

    receipt = %{
      "conversation_ref" => "slack:T1:C1",
      "delivery_ref" => action.action_ref,
      "message_ref" => "1.1",
      "thread_ref" => "1.1",
      "transport" => "slack"
    }

    {1, nil} =
      Repo.update_all(
        from(stored in PlatformAction, where: stored.id == ^action.id),
        set: [
          delivered_at: @old,
          external_receipt: receipt,
          external_receipt_fingerprint: Ryker.CanonicalJSON.digest(receipt),
          status: :delivered,
          updated_at: @old
        ]
      )

    assert {:ok, second} =
             Data.prune(settings(episode_history_seconds: 60, audit_data_seconds: 600))

    assert second.episode_histories == 1
    assert Repo.get(PlatformAction, action.id) == nil

    assert %DateTime{} =
             Repo.get!(Ryker.Episodes.Episode, work.episode.id).history_pruned_at
  end

  test "audit retention keeps unresolved platform actions and deletes delivered actions before turns" do
    pending = settled_work!("audit-platform-action-pending") |> discard_session!()
    pending_action = insert_platform_action!(pending)
    mark_history_pruned!(pending)

    assert {:ok, pinned} = Data.prune(settings(audit_data_seconds: 60))
    assert pinned.audit_episodes == 0
    assert Repo.get!(PlatformAction, pending_action.id).status == :pending
    assert Repo.get!(Turn, pending.turn.id).id == pending.turn.id

    delivered = settled_work!("audit-platform-action-delivered") |> discard_session!()

    delivered_action =
      delivered
      |> insert_platform_action!()
      |> deliver_platform_action!()

    mark_history_pruned!(delivered)

    assert {:ok, retired} = Data.prune(settings(audit_data_seconds: 60))
    assert retired.audit_episodes == 1
    assert Repo.get(PlatformAction, delivered_action.id) == nil
    assert Repo.get(Turn, delivered.turn.id) == nil
    assert Repo.get(Session, delivered.session.id) == nil
    assert Repo.get(Ryker.Episodes.Episode, delivered.episode.id) == nil
  end

  test "data horizons reject missing, unknown, and unordered policy" do
    assert {:error, {:invalid_retention_data, :settings}} = Data.prune(%{})

    assert {:error, {:invalid_retention_data, :settings}} =
             settings()
             |> Map.put(:unknown, 1)
             |> Data.prune()

    assert {:error, {:invalid_retention_data, :settings}} =
             Data.prune(settings(operational_data_seconds: 120, closed_work_seconds: 60))
  end

  defp settled_work!(suffix) do
    episode_id = Ecto.UUID.generate()
    episode_key = "retention-data:#{suffix}:#{episode_id}"

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: episode_key,
                 native_input_id: "source:#{suffix}:#{episode_id}",
                 payload: %{"text" => "#{suffix} payload"},
                 turn_ref: "turn:#{suffix}:#{episode_id}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "work-read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 120)
    assert claim.episode.id == episode_id

    assert {:ok, submission} =
             Submission.new(
               %{"secret" => "#{suffix} context"},
               "Handle #{suffix} exactly.",
               %{"type" => "object"},
               "work-final-live-v3"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission,
               selected_input_refs: Enum.uniq(claim.episode.active_input_refs)
             )

    assert {:ok, session} =
             Custody.bind_session(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:#{suffix}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:#{suffix}"
             )

    candidate = Jason.encode!(%{"delivery" => "none", "secret" => suffix})
    sha = digest(candidate)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               episode_id,
               turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha,
               1
             )

    assert {:ok, result} = Result.new(:none, nil, "Finished #{suffix}.", %{"kind" => "complete"})

    assert {:ok, _turn} =
             Custody.prepare_validation(
               episode_id,
               turn.turn_ref,
               claim.lease_ref,
               sha,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               episode_id,
               episode_key,
               turn.turn_ref,
               claim.lease_ref,
               sha,
               1,
               "validation:#{suffix}"
             )

    %{episode: accepted.episode, session: session, turn: accepted.turn}
  end

  defp discard_session!(work) do
    receipt = %{"kind" => "discarded", "remote_session_id" => work.session.coop_session_id}

    {1, nil} =
      Repo.update_all(
        from(session in Session, where: session.id == ^work.session.id),
        set: [
          cleanup_status: :discarded,
          cleanup_receipt: receipt,
          cleanup_receipt_fingerprint: Ryker.CanonicalJSON.digest(receipt),
          discarded_at: @old
        ]
      )

    %{work | session: Repo.get!(Session, work.session.id)}
  end

  defp insert_activity!(work, suffix) do
    assert {:ok, %{cursor: 1, inserted: 1}} =
             Activity.ingest(work.session.id, [
               %{
                 "id" => "activity:#{suffix}",
                 "occurred_at" => "2020-01-01T00:00:00.000000Z",
                 "payload" => %{"text" => "Checked #{suffix}."},
                 "sequence" => 1,
                 "session_id" => work.session.coop_session_id,
                 "turn_id" => work.turn.coop_turn_id,
                 "type" => "model.thought",
                 "version" => 1
               }
             ])
  end

  # A closed room in the shape the incident room worker leaves behind: the
  # offering thread episode, the linked incident episode, and one joined event.
  defp insert_closed_room!(source_episode_id, episode_id, record_id) do
    room_id = Ecto.UUID.generate()

    room =
      Repo.insert!(%IncidentRoom{
        attempt_count: 0,
        bot_user_ref: "slack:user:UBOT",
        channel_name: "inc-retention-room",
        channel_ref: "C-INC",
        channel_state: :archived,
        confirmation_ref: "confirmation:room:#{room_id}",
        episode_id: episode_id,
        id: room_id,
        inserted_at: @old,
        policy: "incident-room",
        policy_digest: String.duplicate("a", 64),
        private: false,
        prompt: "Investigate the incident in its own room.",
        reconciled_channel_state: :archived,
        record_id: record_id,
        ref: "incident-room:#{room_id}",
        repository_ref: "ryker",
        requested_at: @old,
        requested_by_actor_ref: "slack:user:U123",
        source_channel_ref: "C456",
        source_episode_id: source_episode_id,
        source_message_ref: "1787832000.000100",
        status: :closed,
        title: "Retention room",
        topic: "Retention room incident",
        updated_at: @old,
        workspace_ref: "T123"
      })

    Repo.insert!(%IncidentRoomLifecycleEvent{
      channel_ref: "C-INC",
      event_fingerprint: String.duplicate("c", 64),
      event_ref: "event:room:#{room_id}:joined",
      id: Ecto.UUID.generate(),
      inserted_at: @old,
      kind: :joined,
      occurred_at: @old,
      room_id: room.id,
      updated_at: @old,
      workspace_ref: "T123"
    })

    room
  end

  # One inbox entry admitted into the episode, the way admission binds it.
  defp record_input_for!(episode_id, suffix) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Input for #{suffix}."},
               event_kind: :message,
               event_ref: "Ev-#{suffix}",
               message_ref: "1787832000.000100",
               occurred_at: ~U[2026-08-30 12:00:00.000000Z],
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T123"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)

    Repo.query!(
      """
      UPDATE ingress_inbox_entries
      SET status = 'decided', decision_ref = $1, decision_fingerprint = $2,
          decision_action = 'start_episode', decision_document = '{"action":"start_episode"}',
          episode_id = $3
      WHERE id = $4
      """,
      [
        "decision:#{suffix}",
        String.duplicate("d", 64),
        uuid!(episode_id),
        uuid!(entry.id)
      ]
    )

    entry
  end

  # A standing assignment that fired on `entry` and started `episode_id`.
  defp insert_decided_standing_run!(episode_id, entry) do
    behavior_id = Ecto.UUID.generate()

    %{
      confirmation_ref: "confirmation:standing:#{behavior_id}",
      confirmed_at: @old,
      confirmed_by_actor_ref: "slack:user:U123",
      expires_at: nil,
      id: behavior_id,
      identity_key: "standing:#{behavior_id}",
      kind: :standing_assignment,
      offer_record_id: Repo.get_by!(Record, episode_id: episode_id).id,
      payload: %{
        "action" => "verify_deployment",
        "repository" => nil,
        "scope" => "conversation",
        "subject" => "deployments",
        "trigger" => "deployment",
        "visibility" => "conversation"
      },
      ref: "behavior:#{behavior_id}",
      revision: 1,
      scope_kind: :conversation,
      scope_ref: "slack:T123:C456",
      source_conversation_ref: "slack:T123:C456",
      source_message_ref: "1787832001.000200",
      source_thread_ref: nil,
      source_transport: "slack",
      status: :active,
      workspace_ref: "slack:T123"
    }
    |> Behavior.Changeset.insert()
    |> Repo.insert!()

    run_id = Ecto.UUID.generate()

    run =
      %{
        assignment_id: behavior_id,
        decision_action: :start_episode,
        decision_ref: "decision:#{run_id}",
        episode_id: episode_id,
        id: run_id,
        outcome: :decided,
        ref: "standing-run:#{run_id}",
        source_event_ref: entry.event_ref,
        source_input_ref: Inbox.ref(entry)
      }
      |> StandingAssignmentRun.Changeset.insert()
      |> Repo.insert!()

    Repo.query!("UPDATE standing_assignment_runs SET inserted_at = $1 WHERE id = $2", [
      @old,
      uuid!(run.id)
    ])

    run
  end

  defp insert_status_receipt!(episode_id) do
    Repo.insert!(%ThreadStatusReceipt{
      channel_ref: "C456",
      generation: 1,
      id: Ecto.UUID.generate(),
      inserted_at: @old,
      lease_ref: Ecto.UUID.generate(),
      origin_id: episode_id,
      origin_kind: "episode",
      phase: "investigating",
      text: "Investigating.",
      thread_ref: "1787832000.000100",
      workspace_ref: "T123"
    })
  end

  defp insert_open_record!(work) do
    Repo.query!(
      """
      INSERT INTO episode_state_records
        (id, episode_id, turn_id, ref, operation_id, kind, status, payload,
         payload_fingerprint, sequence, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'question', 'input_request', 'open', '{}', $5, 1, $6, $6)
      """,
      [
        uuid!(Ecto.UUID.generate()),
        uuid!(work.episode.id),
        uuid!(work.turn.id),
        "record:open:#{work.turn.id}",
        String.duplicate("b", 64),
        @old
      ]
    )
  end

  defp insert_approval!(work, status) do
    record_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO episode_state_records
        (id, episode_id, turn_id, ref, operation_id, kind, status, payload,
         payload_fingerprint, sequence, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'question', 'input_request', 'answered', '{}', $5, $6, $7, $7)
      """,
      [
        uuid!(record_id),
        uuid!(work.episode.id),
        uuid!(work.turn.id),
        "record:approval:#{work.turn.id}",
        String.duplicate("b", 64),
        System.unique_integer([:positive]),
        @old
      ]
    )

    closed = status == "closed"

    Repo.query!(
      """
      INSERT INTO episode_emisar_approvals
        (id, record_id, episode_id, connection_ref, request_id, run_id, operation_id,
         action_id, pack_ref, runner_ref, approval_url, expires_at, status, remote_status,
         closed_at, closed_reason, inserted_at, updated_at)
      VALUES ($1, $2, $3, NULL, 'request-1', 'run-1', 'operation-1', 'action-1',
              'pack-1', 'runner-1', 'https://emisar.example/approvals/1', $4, $5, $6, $7, $8,
              $4, $4)
      """,
      [
        uuid!(Ecto.UUID.generate()),
        uuid!(record_id),
        uuid!(work.episode.id),
        @old,
        status,
        if(closed, do: "cancelled", else: "pending_approval"),
        if(closed, do: @old),
        if(closed, do: "wait_ended")
      ]
    )
  end

  defp insert_platform_action!(work) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO platform_actions
        (id, episode_id, turn_id, action_ref, host_slot, tool, kind, transport,
         conversation_ref, thread_ref, source_item_ref, document, intent_fingerprint,
         status, attempt_count, retry_generation, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'reaction', 'set_slack_reaction', 'reaction', 'slack',
              'slack:T1:C1', '1.1', '1.1', '{"action":"add","emoji_name":"eyes"}', $5,
              'pending', 0, 0, $6, $6)
      """,
      [
        uuid!(id),
        uuid!(work.episode.id),
        uuid!(work.turn.id),
        "platform-action:#{id}",
        String.duplicate("f", 64),
        @old
      ]
    )

    Repo.get!(PlatformAction, id)
  end

  defp deliver_platform_action!(action) do
    receipt = %{
      "conversation_ref" => action.conversation_ref,
      "delivery_ref" => action.action_ref,
      "message_ref" => action.source_item_ref,
      "thread_ref" => action.thread_ref,
      "transport" => action.transport
    }

    {1, nil} =
      Repo.update_all(
        from(stored in PlatformAction, where: stored.id == ^action.id),
        set: [
          delivered_at: @old,
          external_receipt: receipt,
          external_receipt_fingerprint: Ryker.CanonicalJSON.digest(receipt),
          status: :delivered,
          updated_at: @old
        ]
      )

    Repo.get!(PlatformAction, action.id)
  end

  defp insert_reaction!(suffix, status) do
    entry_id = Ecto.UUID.generate()
    reaction_id = Ecto.UUID.generate()
    fingerprint = String.duplicate("c", 64)

    Repo.query!(
      """
      INSERT INTO ingress_inbox_entries
        (id, dedupe_key, event_fingerprint, source_kind, source_ref, source_item_ref,
         event_ref, event_kind, native_input_id, actor_kind, actor_ref,
         source_capabilities, destination_transport, destination_conversation_ref,
         revision, occurred_at, occurred_at_source, content, execution_mode, status,
         decision_ref, decision_fingerprint, decision_action, decision_document,
         attempt_count, execution_generation, validation_generation, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'slack', 'T1', 'M1', $4, 'message', $5, 'user', 'U1',
              '{"react":true}', 'slack', 'C1', 1, $6, 'source', '{}', 'live', 'decided',
              $7, $3, 'react', '{"action":"react"}', 0, 1, 1, $6, $6)
      """,
      [
        uuid!(entry_id),
        "dedupe:#{suffix}",
        fingerprint,
        "event:#{suffix}",
        "native:#{suffix}",
        @old,
        "decision:#{suffix}"
      ]
    )

    delivered = status == "delivered"

    Repo.query!(
      """
      INSERT INTO delivery_routing_responses
        (id, input_id, position, kind, decision_ref, delivery_ref, transport, conversation_ref,
         source_item_ref, document, document_fingerprint, status, attempt_count,
         retry_generation, last_error_code, last_error_detail, external_receipt,
         external_receipt_fingerprint, delivered_at, inserted_at, updated_at)
      VALUES ($1, $2, 1, 'reaction', $3, $4, 'slack', 'C1', 'M1', '{"emoji_name":"eyes"}', $5, $6,
              1, 0, $7, $8, $9, $10, $11, $12, $12)
      """,
      [
        uuid!(reaction_id),
        uuid!(entry_id),
        "decision:#{suffix}",
        "reaction:#{suffix}",
        fingerprint,
        status,
        if(delivered, do: nil, else: "operator_required"),
        if(delivered, do: nil, else: "Needs an operator."),
        if(delivered, do: "{}", else: nil),
        if(delivered, do: fingerprint, else: nil),
        if(delivered, do: @old, else: nil),
        @old
      ]
    )

    reaction_id
  end

  defp insert_setting_audit!(suffix) do
    Repo.query!(
      """
      INSERT INTO slack_channel_setting_audit
        (id, event_ref, request_fingerprint, workspace_ref, conversation_ref,
         actor_ref, outcome, detail, occurred_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'T1', 'C1', 'U1', 'updated', 'old', $4, $4, $4)
      """,
      [uuid!(Ecto.UUID.generate()), "audit:#{suffix}", String.duplicate("d", 64), @old]
    )
  end

  defp insert_interaction_audit!(suffix) do
    Repo.query!(
      """
      INSERT INTO slack_interaction_audit
        (id, event_ref, request_fingerprint, workspace_ref, channel_ref, thread_ref,
         message_ref, actor_ref, action_id, action_value_digest, outcome, repaint_status,
         attempt_count, occurred_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'T1', 'C1', NULL, '1.1', 'U1', 'ryker_close_work',
              $3, 'denied', 'none', 0, $4, $4, $4)
      """,
      [
        uuid!(Ecto.UUID.generate()),
        "interaction:#{suffix}",
        String.duplicate("e", 64),
        @old
      ]
    )
  end

  defp insert_operator_action!(suffix) do
    assert {:ok, %{status: :recorded}} =
             Actions.run(
               %{
                 action: :retry,
                 action_ref: "operator-action:#{suffix}",
                 actor_ref: "slack:user:U1",
                 kind: "admission",
                 request: %{"operation" => "retry"},
                 resource_ref: "ingress-input:#{suffix}"
               },
               fn -> {:ok, %{outcome: %{"status" => "pending"}, previous: %{}}} end
             )
  end

  defp start_active_episode!(suffix) do
    id = Ecto.UUID.generate()

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: "retention-data:#{suffix}:#{id}",
                 native_input_id: "source:#{suffix}:#{id}",
                 turn_ref: "turn:#{suffix}:#{id}"
               })
             )

    transition.episode
  end

  defp insert_old_schedule_occurrence!(source, child) do
    record_id = Ecto.UUID.generate()
    schedule_id = Ecto.UUID.generate()
    occurrence_id = Ecto.UUID.generate()
    payload = %{"kind" => "schedule_offer", "task" => "Inspect current service health."}

    record =
      %{
        confirmation_ref: "schedule-confirmation:#{schedule_id}",
        confirmed_at: @old,
        confirmed_by_actor_ref: "operator:retention-test",
        episode_id: source.episode.id,
        id: record_id,
        kind: "schedule_offer",
        operation_id: "schedule-offer",
        payload: payload,
        payload_fingerprint: Ryker.CanonicalJSON.digest(payload),
        ref: "record:schedule_offer:#{record_id}",
        status: :confirmed,
        turn_id: source.turn.id
      }
      |> Record.Changeset.insert()
      |> Repo.insert!()

    schedule =
      %{
        authority: :read_only,
        confirmation_ref: "schedule-confirmation:#{schedule_id}",
        confirmed_at: @old,
        confirmed_by_actor_ref: "operator:retention-test",
        destination_conversation_ref: "slack:T1:C1",
        destination_thread_ref: "thread:retention",
        destination_transport: "slack",
        expires_at: nil,
        id: schedule_id,
        next_occurrence_at: DateTime.add(@old, 1, :day),
        offer_record_id: record.id,
        recurrence: %{"kind" => "daily", "time" => "09:00:00"},
        ref: "schedule:#{schedule_id}",
        repository: nil,
        source_episode_id: source.episode.id,
        status: :active,
        task: "Inspect current service health.",
        timezone: "Etc/UTC",
        title: "Daily health"
      }
      |> Schedule.Changeset.insert()
      |> Repo.insert!()

    occurrence =
      %{
        child_episode_id: child.id,
        event_ref: "schedule-event:#{occurrence_id}",
        id: occurrence_id,
        ref: "schedule-run:#{occurrence_id}",
        schedule_id: schedule.id,
        scheduled_for: @old,
        status: :dispatched
      }
      |> ScheduleOccurrence.Changeset.insert()
      |> Repo.insert!()

    {1, nil} =
      Repo.update_all(
        from(saved in ScheduleOccurrence, where: saved.id == ^occurrence.id),
        set: [updated_at: @old]
      )

    occurrence
  end

  defp backdate_operational!(work) do
    {1, nil} =
      Repo.update_all(from(turn in Turn, where: turn.id == ^work.turn.id),
        set: [updated_at: @old]
      )

    {1, nil} =
      Repo.update_all(from(session in Session, where: session.id == ^work.session.id),
        set: [updated_at: @old]
      )

    work
  end

  defp backdate_history!(work, seconds) do
    backdate_operational!(work)

    Repo.query!(
      "UPDATE episode_kernel_episodes SET updated_at = clock_timestamp() - ($1 * interval '1 second') WHERE id = $2",
      [seconds, uuid!(work.episode.id)]
    )

    work
  end

  defp mark_history_pruned!(work) do
    Repo.delete_all(
      from(event in Ryker.Episodes.Event, where: event.episode_id == ^work.episode.id)
    )

    {1, nil} =
      Repo.update_all(
        from(episode in Ryker.Episodes.Episode, where: episode.id == ^work.episode.id),
        set: [history_pruned_at: @old, updated_at: @old]
      )

    work
  end

  defp backdate_rows! do
    Repo.query!("UPDATE ingress_inbox_entries SET updated_at = $1", [@old])
    Repo.query!("UPDATE delivery_routing_responses SET updated_at = $1", [@old])
    Repo.query!("UPDATE ryker_operator_actions SET inserted_at = $1, updated_at = $1", [@old])
  end

  defp rule_inventory!(suffix, recorded_at) do
    Repo.insert!(%StandingRuleInventory{
      id: Ecto.UUID.generate(),
      source_input_ref: "input:#{suffix}",
      source_event_ref: "event:#{suffix}",
      workspace_ref: "slack:T123",
      conversation_ref: "slack:T123:C456",
      rule_count: 0,
      matched_count: 0,
      entries: [],
      recorded_at: recorded_at
    })
  end

  defp worker_evidence(session) do
    Path.expand("../../../testdata/protocol/coop-session-evidence-v1.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("session_id", session.coop_session_id)
  end

  defp insert_github_event!(binding_ref, delivery_ref, disposition, at) do
    id = Ecto.UUID.generate()

    Repo.insert!(%Ryker.GitHub.Event{
      id: id,
      delivery_ref: delivery_ref,
      binding_ref: binding_ref,
      repository_id: 42,
      event_name: "issue_comment",
      action: "created",
      event_ref: "github:#{delivery_ref}",
      payload_digest: digest(delivery_ref),
      disposition: disposition,
      occurred_at: at,
      processed_at: if(disposition != "received", do: at),
      inserted_at: at
    })

    id
  end

  defp weekly_report!(week, due_at, status) do
    receipt = %{"delivery_ref" => "weekly-report:#{week}", "message_ref" => "1790000000.000100"}

    Repo.insert!(%WeeklyReport{
      id: Ecto.UUID.generate(),
      week: week,
      due_at: due_at,
      period_start: DateTime.add(due_at, -7, :day),
      timezone: "Etc/UTC",
      delivery_ref: "weekly-report:#{week}",
      transport: "slack",
      conversation_ref: "slack:T123:C456",
      document: %{"message" => "The week."},
      status: status,
      last_error_code: if(status == :blocked, do: "slack_api_error"),
      last_error_detail: if(status == :blocked, do: "not_in_channel"),
      external_receipt: if(status == :delivered, do: receipt),
      external_receipt_fingerprint: if(status == :delivered, do: CanonicalJSON.digest(receipt)),
      delivered_at: if(status == :delivered, do: due_at),
      inserted_at: @old,
      updated_at: @old
    })
  end

  defp settings(overrides \\ []) do
    Map.merge(
      %{
        audit_data_seconds: 60,
        closed_work_seconds: 60,
        conversation_memory_seconds: 60,
        episode_history_seconds: 60,
        operational_data_seconds: 60,
        routing_examples_enabled: false,
        routing_examples_seconds: 365 * 86_400,
        work_examples_enabled: false,
        work_examples_seconds: 365 * 86_400
      },
      Map.new(overrides)
    )
  end

  defp uuid!(value), do: Ecto.UUID.dump!(value)
end
