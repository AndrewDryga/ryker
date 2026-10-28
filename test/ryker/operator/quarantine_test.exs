defmodule Ryker.Operator.QuarantineTest do
  use Ryker.DataCase, async: true
  alias Ryker.CoopFleet.{Command, Placement}
  alias Ryker.Episodes
  alias Ryker.Fixtures.CoopWorkers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Operator.Quarantine
  alias Ryker.Work.Session

  # A controller rollback left 28 worker records quarantined. Retiring their
  # records keeps their bytes; ordinary cleanup would falsely say "removed".
  test "record retirement keeps the copy and the human wait, including after a lost response" do
    {session, placement, request} = parked_session()
    before = Repo.get!(Episodes.Episode, session.episode_id)

    assert {:ok, intent} = Quarantine.request(request)
    assert intent.status == :recorded
    assert {:ok, duplicate} = Quarantine.request(request)
    assert duplicate.status == :duplicate
    assert duplicate.outcome == intent.outcome
    assert Quarantine.settle(request.action_ref) == {:ok, :waiting}

    assert WorkSessions.pin_episode(session.episode_id, session.policy, session.policy_digest) ==
             {:error, :quarantine_recovery_pending}

    command = Repo.get!(Command, intent.outcome["command_id"])

    assert command.payload == %{
             "method" => "POST",
             "path" => "/v1/sessions/#{session.coop_session_id}/discard",
             "body" => %{"retire_quarantined" => true, "expected_revision" => 7}
           }

    receipt(command, %{"id" => session.coop_session_id, "state" => "discarded", "revision" => 8})
    assert {:ok, %{status: :recorded}} = Quarantine.settle(request.action_ref)
    assert {:ok, %{status: :duplicate}} = Quarantine.settle(request.action_ref)

    saved = Repo.get!(Session, session.id)
    assert saved.cleanup_status == :retained
    assert saved.retained_reason == "quarantined_copy"
    assert saved.cleanup_receipt["kind"] == "quarantined_copy_retained"
    assert is_nil(saved.discarded_at)
    assert Repo.get!(Episodes.Episode, session.episode_id) == before
    assert Repo.get!(Placement, placement.id).state == :retired
    assert Ryker.Retention.Custody.claim_next("cleanup:after-quarantine", 60) == {:ok, nil}

    assert {:ok, successor} =
             WorkSessions.pin_episode(session.episode_id, session.policy, session.policy_digest)

    assert successor.generation == session.generation + 1
    assert successor.repository_source == session.repository_source
    assert Repo.get!(Episodes.Episode, session.episode_id) == before
  end

  test "a changed placement cannot retire a different worker generation" do
    {session, _placement, request} = parked_session()

    assert Quarantine.request(%{request | placement_generation: 2}) ==
             {:error, :quarantine_identity_changed}

    assert Repo.get!(Session, session.id) == session
    assert Repo.aggregate(Command.Query.by_session_id(session.id), :count) == 1
  end

  test "writable work cannot be retired without an authenticated checkpoint" do
    {session, _placement, request} = parked_session()
    session |> Ecto.Changeset.change(repository_ref: "tenant-app") |> Repo.update!()
    assert Quarantine.request(request) == {:error, :quarantine_checkpoint_required}
    assert Repo.aggregate(Command.Query.by_session_id(session.id), :count) == 1
  end

  test "an unrelated discarded session is not proof of this retirement" do
    {session, _placement, request} = parked_session()
    assert {:ok, intent} = Quarantine.request(request)
    command = Repo.get!(Command, intent.outcome["command_id"])
    receipt(command, %{"id" => "another-session", "state" => "discarded", "revision" => 8})
    assert Quarantine.settle(request.action_ref) == {:error, :quarantine_receipt_mismatch}
    assert Repo.get!(Session, session.id).retained_reason == "quarantine_recovery_pending"
  end

  test "an unsettled worker command prevents retirement before it is queued" do
    {session, placement, request} = parked_session()

    assert {:ok, _} =
             Ryker.CoopFleet.ControlPlane.enqueue_command(
               placement.id,
               "api_request",
               %{"method" => "GET", "path" => "/v1/sessions/#{session.coop_session_id}"},
               "pending:#{session.id}"
             )

    assert Quarantine.request(request) == {:error, :quarantine_work_unfinished}
    assert Repo.get!(Session, session.id) == session
    assert Repo.aggregate(Command.Query.by_session_id(session.id), :count) == 2
  end

  test "a repository with a verified read-only grant can retain its copy" do
    {session, _placement, request} = parked_session()

    job =
      Ryker.Fixtures.WorkerJob.build("job:#{session.id}", "tenant-app")
      |> Map.put("repository_read_only", true)

    assert {:ok, digest} = Ryker.CoopFleet.JobSpec.digest(job)

    session =
      session
      |> Ecto.Changeset.change(
        repository_ref: "tenant-app",
        external_ref: "job:#{session.id}",
        worker_job_document: job,
        worker_job_digest: digest
      )
      |> Repo.update!()

    receipt(Repo.get!(Command, request.inspection_command_id), %{
      "id" => session.coop_session_id,
      "state" => "open",
      "activity" => "parked",
      "queued_turn_count" => 0,
      "queued_prompt_bytes" => 0,
      "revision" => 7
    })

    assert {:ok, _} = Quarantine.request(request)
  end

  test "a healthy session or stale worker revision is refused without abandoning its custody" do
    for code <- ["invalid_session_state", "revision_conflict"] do
      {session, placement, request} = parked_session()
      assert {:ok, intent} = Quarantine.request(request)
      command = Repo.get!(Command, intent.outcome["command_id"])

      command
      |> Ecto.Changeset.change(
        status: :succeeded,
        operation_key: command.idempotency_key,
        completed_at: Repo.now!(),
        result: %{
          "status" => 409,
          "body" => %{"error" => %{"code" => code, "detail" => "retirement refused"}}
        },
        result_fingerprint: String.duplicate("c", 64)
      )
      |> Repo.update!()

      assert {:ok, %{outcome: %{"kind" => "quarantine_retirement_refused", "code" => ^code}}} =
               Quarantine.settle(request.action_ref)

      saved = Repo.get!(Session, session.id)
      assert saved.cleanup_status == :active
      assert is_nil(saved.retained_reason)
      assert is_nil(saved.cleanup_receipt)
      assert Repo.get!(Placement, placement.id).state == :active
    end
  end

  test "maximum length action references can settle after retirement" do
    {session, _placement, request} = parked_session()
    request = %{request | action_ref: String.duplicate("a", 1_024)}
    assert {:ok, intent} = Quarantine.request(request)
    command = Repo.get!(Command, intent.outcome["command_id"])
    receipt(command, %{"id" => session.coop_session_id, "state" => "discarded", "revision" => 8})
    assert {:ok, %{status: :recorded}} = Quarantine.settle(request.action_ref)
  end

  test "inspection must prove the exact remote grant before retirement is queued" do
    {session, _placement, request} = parked_session()
    inspection = Repo.get!(Command, request.inspection_command_id)
    bad = put_in(inspection.result, ["body", "session", "external_ref"], "another-task")
    inspection |> Ecto.Changeset.change(result: bad) |> Repo.update!()
    assert Quarantine.request(request) == {:error, :quarantine_inspection_mismatch}
    assert Repo.get!(Session, session.id) == session
    assert Repo.aggregate(Command.Query.by_session_id(session.id), :count) == 1
  end

  test "worker work missing from the controller cannot be retired" do
    for changes <- [
          %{"queued_turn_count" => 1},
          %{"queued_prompt_bytes" => 10},
          %{"active_turn_id" => "lost-turn"},
          %{"activity" => "running"},
          %{"queued_turn_count" => nil}
        ] do
      {session, _, request} = parked_session()
      command = Repo.get!(Command, request.inspection_command_id)
      result = update_in(command.result, ["body", "session"], &Map.merge(&1, changes))
      command |> Ecto.Changeset.change(result: result) |> Repo.update!()
      assert Quarantine.request(request) == {:error, :quarantine_inspection_mismatch}
      assert Repo.get!(Session, session.id) == session
      assert Repo.aggregate(Command.Query.by_session_id(session.id), :count) == 1
    end
  end

  test "a retirement response cannot substitute another job's authority" do
    {session, _placement, request} = parked_session()
    assert {:ok, intent} = Quarantine.request(request)
    command = Repo.get!(Command, intent.outcome["command_id"])

    receipt(command, %{
      "id" => session.coop_session_id,
      "state" => "discarded",
      "revision" => 8,
      "external_ref" => "another-task"
    })

    assert Quarantine.settle(request.action_ref) == {:error, :quarantine_receipt_mismatch}
    assert Repo.get!(Session, session.id).retained_reason == "quarantine_recovery_pending"
  end

  test "a read-only grant for another repository cannot authorize recovery" do
    {session, _placement, request} = parked_session()

    job =
      Ryker.Fixtures.WorkerJob.build("job:#{session.id}", "another-repository")
      |> Map.put("repository_read_only", true)

    assert {:ok, digest} = Ryker.CoopFleet.JobSpec.digest(job)

    session
    |> Ecto.Changeset.change(
      repository_ref: "tenant-app",
      external_ref: "job:#{session.id}",
      worker_job_document: job,
      worker_job_digest: digest
    )
    |> Repo.update!()

    assert Quarantine.request(request) == {:error, :quarantine_checkpoint_required}
    assert Repo.aggregate(Command.Query.by_session_id(session.id), :count) == 1
  end

  test "background model ownership cannot be retired through work recovery" do
    {_, _, request} = parked_session()

    assert {:ok, run} =
             Ryker.Learning.prepare(Enum.map(Ryker.Fixtures.Learning.inputs!(), & &1.id), %{
               policy: "recorded-read-only-policy",
               policy_digest: String.duplicate("a", 64)
             })

    assert {:ok, _} = Ryker.Learning.FleetSession.ensure(run)
    assert {:ok, session} = Ryker.Learning.FleetSession.bind(run, "learning-session")

    assert Quarantine.request(%{
             request
             | session_id: session.id,
               remote_session_id: session.coop_session_id
           }) == {:error, :quarantine_owner_unsupported}

    assert Repo.get!(Session, session.id) == session
  end

  defp receipt(command, remote) do
    session = Repo.get!(Session, command.session_id)
    remote = Map.merge(Ryker.Fixtures.WorkerJob.receipt(session), remote)

    command
    |> Ecto.Changeset.change(
      status: :succeeded,
      operation_key: command.idempotency_key,
      completed_at: Repo.now!(),
      result: %{"status" => 200, "body" => %{"session" => remote}},
      result_fingerprint: String.duplicate("b", 64)
    )
    |> Repo.update!()
  end

  defp parked_session do
    id = Repo.generate_id()

    assert {:ok, _} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: "quarantine:#{id}",
                 native_input_id: "input:#{id}",
                 occurred_at: Repo.now!(),
                 turn_ref: "turn:#{id}"
               })
             )

    assert {:ok, session} = WorkSessions.pin_episode(id, "read-only", String.duplicate("a", 64))
    session = session |> Ecto.Changeset.change(coop_session_id: "remote-#{id}") |> Repo.update!()

    assert {:ok, _} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 episode_key: "quarantine:#{id}",
                 expected_turn_ref: "turn:#{id}",
                 wait_ref: "question:#{id}",
                 occurred_at: Repo.now!()
               })
             )

    worker = "worker:#{id}"
    assert {:ok, _} = CoopWorkers.authorize(worker, "eval", Ryker.Crypto.sha256_hex(worker))
    now = Repo.now!()
    requirements = %{"purpose" => "stop_or_cleanup"}

    placement =
      Repo.insert!(%Placement{
        session_id: session.id,
        episode_id: id,
        worker_id: worker,
        generation: 1,
        state: :active,
        lease_ref: "lease:#{id}",
        lease_expires_at: DateTime.add(now, 60),
        requirements: requirements,
        requirements_fingerprint: Ryker.CanonicalJSON.digest(requirements)
      })

    assert {:ok, inspection} =
             Ryker.CoopFleet.ControlPlane.enqueue_command(
               placement.id,
               "api_request",
               %{"method" => "GET", "path" => "/v1/sessions/#{session.coop_session_id}"},
               "inspect:#{id}"
             )

    receipt(inspection, %{
      "id" => session.coop_session_id,
      "state" => "open",
      "activity" => "parked",
      "queued_turn_count" => 0,
      "queued_prompt_bytes" => 0,
      "revision" => 7
    })

    request = %{
      inspection_command_id: inspection.id,
      session_id: session.id,
      placement_id: placement.id,
      placement_generation: 1,
      remote_session_id: session.coop_session_id,
      expected_revision: 7,
      actor_ref: "operator:local",
      action_ref: "quarantine:#{id}"
    }

    {session, placement, request}
  end
end
