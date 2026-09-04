defmodule Responder.Retention.DataTest do
  use Responder.DataCase, async: false

  import Ecto.Query

  alias Responder.Admission.FleetSession
  alias Responder.Artifacts
  alias Responder.CanonicalJSON
  alias Responder.CoopFleet.{Placement, Worker}
  alias Responder.Cutover.{Item, Run}
  alias Responder.Delivery.PlatformAction
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.{Inbox, Input}
  alias Responder.Operator.Actions
  alias Responder.Repo
  alias Responder.Retention.Data
  alias Responder.Slack.Input, as: SlackInput

  alias Responder.State.{
    RecordChangeset,
    Schedule,
    ScheduleChangeset,
    ScheduleOccurrence,
    ScheduleOccurrenceChangeset
  }

  alias Responder.Work.{Activity, ActivityEvent, Custody, Result, Session, Submission, Turn}

  @old ~U[2020-01-01 00:00:00.000000Z]

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
      ["decision:#{suffix}", String.duplicate("d", 64), @old, uuid!(entry.id)]
    )

    Repo.query!("UPDATE input_artifacts SET updated_at = $1 WHERE id = $2", [
      @old,
      uuid!(artifact.id)
    ])

    assert {:ok, result} = Data.prune(settings())
    assert result.operational_inputs == 1
    assert result.input_artifacts == 1
    assert Repo.get(Responder.Artifacts.Artifact, artifact.id) == nil
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

    assert {:ok, _result} = Data.prune(settings())
    assert Repo.get(Placement, placement.id) == nil
    assert Repo.get(Session, session.id) == nil
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
             from(event in Responder.Episodes.Event,
               where: event.episode_id == ^eligible.episode.id
             ),
             :count
           ) == 0

    assert %DateTime{} =
             Repo.get!(Responder.Episodes.Episode, eligible.episode.id).history_pruned_at

    assert Repo.aggregate(
             from(activity in ActivityEvent,
               where: activity.episode_id == ^eligible.episode.id
             ),
             :count
           ) == 0

    assert Repo.get!(Session, eligible.session.id).cleanup_receipt["kind"] == "discarded"

    assert Repo.aggregate(
             from(event in Responder.Episodes.Event,
               where: event.episode_id == ^pinned.episode.id
             ),
             :count
           ) > 0

    assert Repo.get!(Responder.Episodes.Episode, pinned.episode.id).history_pruned_at == nil

    assert {:ok, result} = Data.prune(settings(audit_data_seconds: 60))
    assert result.audit_episodes == 1
    assert Repo.get(Responder.Episodes.Episode, eligible.episode.id) == nil
    assert Repo.get(Session, eligible.session.id) == nil
    assert Repo.get(Turn, eligible.turn.id) == nil
  end

  test "old transport, memory, and audit rows prune without touching unresolved custody" do
    delivered = insert_reaction!("delivered", "delivered")
    blocked = insert_reaction!("blocked", "blocked")
    insert_setting_audit!("old-audit")
    insert_interaction_audit!("old-interaction")
    insert_operator_action!("old-operator-action")
    backdate_rows!()

    assert {:ok, result} = Data.prune(settings(conversation_memory_seconds: 60))
    assert result.delivery_reactions == 1
    assert Repo.get(Responder.Delivery.Reaction, delivered) == nil
    assert Repo.get!(Responder.Delivery.Reaction, blocked).status == :blocked
    assert result.audit_rows == 4
    assert Actions.fetch("operator-action:old-operator-action") == :error
  end

  test "cutover audit keeps fingerprints while expiring copied legacy bodies" do
    run_id = Ecto.UUID.generate()
    item_id = Ecto.UUID.generate()
    manifest_sha256 = String.duplicate("1", 64)
    source_sha256 = String.duplicate("2", 64)
    target_fingerprint = String.duplicate("3", 64)

    Repo.insert!(%Run{
      applied_at: @old,
      cutover_at: @old,
      id: run_id,
      inserted_at: @old,
      item_count: 1,
      manifest_sha256: manifest_sha256,
      operator_ref: "operator:retention-test",
      review_sha256: String.duplicate("4", 64),
      reviewed_at: @old,
      source_kind: "responder_sqlite",
      source_schema_sha256: "e9aaa44b42dac7b2afe4e5740bcf6e4d24b9f93c2c2182781374e12e6643c535",
      source_schema_version: 90,
      source_sha256: String.duplicate("5", 64),
      status: :applied,
      summary: %{"episode" => 1},
      updated_at: @old,
      version: 1,
      workspace_ref: "slack:T123"
    })

    Repo.insert!(%Item{
      data: %{"objective" => "private legacy incident body"},
      decision: :import,
      id: item_id,
      inserted_at: @old,
      kind: :episode,
      ref: "episode:legacy-private",
      run_id: run_id,
      source_ref: "legacy-private",
      source_sha256: source_sha256,
      source_table: "work_episodes",
      status: :applied,
      target_fingerprint: target_fingerprint,
      target_refs: ["episode:replacement"],
      updated_at: @old
    })

    assert {:ok, result} = Data.prune(settings(audit_data_seconds: 60))
    assert result.cutover_items == 1

    retained = Repo.get!(Item, item_id)
    assert retained.data == %{"retention" => "pruned"}
    assert retained.source_sha256 == source_sha256
    assert retained.target_fingerprint == target_fingerprint
    assert retained.target_refs == ["episode:replacement"]
    assert Repo.get!(Run, run_id).manifest_sha256 == manifest_sha256
  end

  test "each maintenance transaction mutates only one bounded row batch" do
    for index <- 1..101, do: insert_setting_audit!("batch-#{index}")

    assert {:ok, first} = Data.prune(settings())
    assert first.audit_rows == 100
    assert Repo.aggregate(Responder.Slack.ChannelSettingAudit, :count) == 1

    assert {:ok, second} = Data.prune(settings())
    assert second.audit_rows == 1
    assert Repo.aggregate(Responder.Slack.ChannelSettingAudit, :count) == 0
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
    assert Repo.get!(Responder.Episodes.Episode, work.episode.id).history_pruned_at == nil

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
          external_receipt_fingerprint: Responder.CanonicalJSON.digest(receipt),
          status: :delivered,
          updated_at: @old
        ]
      )

    assert {:ok, second} =
             Data.prune(settings(episode_history_seconds: 60, audit_data_seconds: 600))

    assert second.episode_histories == 1
    assert Repo.get(PlatformAction, action.id) == nil

    assert %DateTime{} =
             Repo.get!(Responder.Episodes.Episode, work.episode.id).history_pruned_at
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
    assert Repo.get(Responder.Episodes.Episode, delivered.episode.id) == nil
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
               "work-final-v1"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(
               episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
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
          cleanup_receipt_fingerprint: Responder.CanonicalJSON.digest(receipt),
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
          external_receipt_fingerprint: Responder.CanonicalJSON.digest(receipt),
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
      INSERT INTO delivery_reactions
        (id, input_id, decision_ref, delivery_ref, transport, conversation_ref,
         source_item_ref, document, document_fingerprint, status, attempt_count,
         retry_generation, last_error_code, last_error_detail, external_receipt,
         external_receipt_fingerprint, delivered_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'slack', 'C1', 'M1', '{"emoji_name":"eyes"}', $5, $6, 1, 0,
              $7, $8, $9, $10, $11, $12, $12)
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
      VALUES ($1, $2, $3, 'T1', 'C1', NULL, '1.1', 'U1', 'responder_close_work',
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
        payload_fingerprint: Responder.CanonicalJSON.digest(payload),
        ref: "record:schedule_offer:#{record_id}",
        status: :confirmed,
        turn_id: source.turn.id
      }
      |> RecordChangeset.insert()
      |> Repo.insert!()

    schedule =
      %{
        authority: :read_only,
        catch_up: :latest,
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
      |> ScheduleChangeset.insert()
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
      |> ScheduleOccurrenceChangeset.insert()
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
      from(event in Responder.Episodes.Event, where: event.episode_id == ^work.episode.id)
    )

    {1, nil} =
      Repo.update_all(
        from(episode in Responder.Episodes.Episode, where: episode.id == ^work.episode.id),
        set: [history_pruned_at: @old, updated_at: @old]
      )

    work
  end

  defp backdate_rows! do
    Repo.query!("UPDATE ingress_inbox_entries SET updated_at = $1", [@old])
    Repo.query!("UPDATE delivery_reactions SET updated_at = $1", [@old])
    Repo.query!("UPDATE responder_operator_actions SET inserted_at = $1, updated_at = $1", [@old])
  end

  defp settings(overrides \\ []) do
    Map.merge(
      %{
        audit_data_seconds: 60,
        closed_work_seconds: 60,
        conversation_memory_seconds: 60,
        episode_history_seconds: 60,
        operational_data_seconds: 60
      },
      Map.new(overrides)
    )
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp uuid!(value), do: Ecto.UUID.dump!(value)
end
