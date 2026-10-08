defmodule Ryker.CoopFleet.ClientTest do
  use Ryker.DataCase, async: true
  import Ryker.TestHelpers, only: [digest: 1]
  import Ecto.Query, only: [from: 2]
  alias Ryker.{Artifacts, CanonicalJSON, Instructions}
  alias Ryker.CoopFleet.Bodies
  alias Ryker.CoopFleet.{Client, Command, ControlPlane, JobSpec, Placement, Worker}
  alias Ryker.CoopFleet.WorkspaceCheckpointTransfer
  alias Ryker.Crypto
  alias Ryker.Episodes
  alias Ryker.Fixtures.CoopWorkers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Fixtures.WorkspaceCheckpoint, as: WorkspaceCheckpointFixture
  alias Ryker.Repo
  alias Ryker.Work.{Custody, Session, SubmissionBuilder}

  @authority_digest String.duplicate("d", 64)
  @policy "work-read-only"
  @policy_digest String.duplicate("b", 64)

  defmodule FakeBridge do
    def execute(session, kind, payload, key, options) do
      send(Process.get(:coop_fleet_client_test_pid), {
        :fleet_command,
        session,
        kind,
        payload,
        key,
        options
      })

      case kind do
        "create_session" ->
          {:ok, %{"session" => %{"id" => "remote-resource", "revision" => 1, "state" => "open"}}}

        "ensure_workspace" ->
          {:ok, %{"session" => %{"id" => "remote-resource", "revision" => 2, "state" => "open"}}}

        "checkpoint_workspace" ->
          {:ok,
           %{
             "checkpoint_ref" => "checkpoint:#{String.duplicate("c", 32)}",
             "state" => "stored",
             "transfer_id" => "018f04f4-5555-7000-8000-000000000001"
           }}

        "reconcile_operation" ->
          {:ok,
           Process.get(
             :coop_fleet_reconcile_result,
             %{"id" => "remote-resource", "state" => "succeeded"}
           )}

        "get_session" ->
          {:ok,
           Process.get(
             :coop_fleet_get_session_result,
             %{"id" => "remote-resource", "state" => "succeeded"}
           )}

        "run_review" ->
          Process.get(:coop_fleet_run_review_result, {:ok, %{"id" => "remote-resource"}})

        "get_output_artifact" ->
          Process.get(:coop_fleet_binary_result, {:error, :missing_test_body})

        _other ->
          {:ok, %{"id" => "remote-resource", "state" => "succeeded"}}
      end
    end

    def await_command(command_id, _options) do
      send(Process.get(:coop_fleet_client_test_pid), {:fleet_await, command_id})

      case Process.get(:coop_fleet_await_result, {:error, :unexpected_command_wait}) do
        callback when is_function(callback, 1) -> callback.(command_id)
        result -> result
      end
    end
  end

  setup do
    Process.put(:coop_fleet_client_test_pid, self())

    on_exit(fn ->
      Process.delete(:coop_fleet_client_test_pid)
      Process.delete(:coop_fleet_reconcile_result)
      Process.delete(:coop_fleet_get_session_result)
    end)

    session = session!()

    assert {:ok, client} =
             Client.new(
               bridge: FakeBridge,
               capability_names: ["controller-tools"],
               lease_seconds: 30,
               max_waits: 2,
               poll_interval_ms: 1,
               wait: fn -> :ok end,
               workspace_ref: "workspace-main"
             )

    %{client: client, session: session}
  end

  test "new requires one bounded workspace and rejects unknown or duplicate options" do
    assert Client.new([]) == {:error, {:invalid_coop_fleet_client, :options}}

    assert Client.new(workspace_ref: "workspace-main", workspace_ref: "other") ==
             {:error, {:invalid_coop_fleet_client, :options}}

    assert Client.new(workspace_ref: "workspace-main", secret: "must-not-cross") ==
             {:error, {:invalid_coop_fleet_client, :options}}

    assert Client.new(workspace_ref: String.duplicate("w", 1_025)) ==
             {:error, {:invalid_coop_fleet_client, :options}}
  end

  test "create and fence use the same pinned job instead of a worker policy", %{
    client: client,
    session: session
  } do
    job = session.worker_job_document
    digest = session.worker_job_digest

    key = "ryker:work:create:#{session.id}:job"

    assert {:ok, %{"session" => %{"id" => "remote-resource"}}} =
             Client.create_session(
               client,
               key,
               @policy,
               session.external_ref,
               session.repository_source
             )

    assert_receive {:fleet_command, ^session, "create_session", payload, ^key, _options}

    assert payload == %{
             "external_ref" => session.external_ref,
             "job" => job,
             "job_digest" => digest
           }

    session
    |> Ecto.Changeset.change(worker_job_digest: String.duplicate("f", 64))
    |> Repo.update!()

    assert Client.fence_create_session(
             client,
             key,
             @policy,
             session.external_ref,
             session.repository_source
           ) ==
             {:error, {:coop_fleet_authority_mismatch, :worker_job}}

    refute_receive {:fleet_command, _, _, _, _, _}
  end

  test "an unplaced session exposes only its enforced placement capability", %{session: session} do
    assert {:ok, unversioned} = Client.new(workspace_ref: "workspace-main")

    assert {:ok, %{"repository_freshness_receipt_versions" => []}} =
             Client.capabilities(unversioned, session)

    assert {:ok, versioned} =
             Client.new(
               capability_versions: %{"repository-freshness" => "2"},
               workspace_ref: "workspace-main"
             )

    assert {:ok, %{"repository_freshness_receipt_versions" => [2]}} =
             Client.capabilities(versioned, session)

    bound = bind_session!(session, "remote:unplaced-capability")

    assert Client.capabilities(versioned, bound) ==
             {:error, {:coop_upgrade_required, :repository_freshness_v2}}
  end

  test "a create key selects its execution even when another session reuses the workspace offer",
       %{client: client, session: session} do
    offer = "offer:shared-create"

    session =
      session |> Ecto.Changeset.change(workspace_task: %{"offer_ref" => offer}) |> Repo.update!()

    newer =
      session!()
      |> Ecto.Changeset.change(generation: 2, workspace_task: %{"offer_ref" => offer})
      |> Repo.update!()

    key = "ryker:work:create:#{session.id}:g#{session.create_generation}"

    assert Client.prepare_create_session(client, key, @policy, offer, session.repository_source) ==
             :ok

    assert {:ok, _} =
             Client.create_session(client, key, @policy, offer, session.repository_source)

    assert_receive {:fleet_command, ^session, "create_session", _, ^key, _}
    refute_receive {:fleet_command, ^newer, "create_session", _, _, _}

    assert {:ok, receipt} =
             Client.fence_create_session(client, key, @policy, offer, session.repository_source)

    assert Repo.get_by!(Command, idempotency_key: key).session_id == session.id

    session |> Ecto.Changeset.change(create_generation: 2) |> Repo.update!()

    assert {:ok, ^receipt} =
             Client.fence_create_session(client, key, @policy, offer, session.repository_source)
  end

  test "an unknown stale create key cannot prepare or enqueue a newer attempt",
       %{client: client, session: session} do
    key = "ryker:work:create:#{session.id}:g#{session.create_generation}"
    session |> Ecto.Changeset.change(create_generation: 2) |> Repo.update!()

    for call <- [
          &Client.prepare_create_session/5,
          &Client.create_session/5,
          &Client.fence_create_session/5
        ] do
      assert {:error, {:coop_worker_command_conflict, ^key}} =
               call.(client, key, @policy, session.external_ref, session.repository_source)
    end

    refute_receive {:fleet_command, _, _, _, _, _}
    assert Repo.aggregate(Command, :count) == 0
    assert Repo.aggregate(Placement, :count) == 0
  end

  test "a create fence survives late source preparation without placing or launching work", %{
    client: client,
    session: session
  } do
    session =
      session
      |> Ecto.Changeset.change(worker_job_document: nil, worker_job_digest: nil)
      |> Repo.update!()

    key = "create:source-unavailable"

    assert {:ok, %{"state" => "failed", "error_code" => "operation_not_enqueued"}} =
             Client.fence_create_session(
               client,
               key,
               session.policy,
               session.external_ref,
               session.repository_source
             )

    assert Repo.get!(Ryker.Work.Session, session.id).worker_job_document == nil
    assert Repo.aggregate(Placement, :count) == 0

    assert %Command{
             status: :failed,
             placement_id: nil,
             error: %{"code" => "operation_not_enqueued"}
           } =
             Repo.get_by!(Command, idempotency_key: key)

    # Source preparation runs without DB locks. A creator already fetching when
    # this cancellation arrived can finish pinning, but must never enqueue afterward.
    session = pin_job!(session)
    assert {:ok, restarted} = Client.new(workspace_ref: "workspace-main")

    assert {:ok, receipt} = Client.operation_by_key(restarted, key)
    assert receipt["state"] == "failed"
    assert receipt["error_code"] == "operation_not_enqueued"

    assert {:error, {:coop_error, 409, "operation_not_enqueued", _}} =
             Client.create_session(
               restarted,
               key,
               session.policy,
               session.external_ref,
               session.repository_source
             )

    assert {:ok, ^receipt} =
             Client.fence_create_session(
               restarted,
               key,
               session.policy,
               session.external_ref,
               session.repository_source
             )

    assert Repo.aggregate(Placement, :count) == 0
    assert Repo.aggregate(Command, :count) == 1
    refute_receive {:fleet_command, _, _, _, _, _}
  end

  test "a create fence binds the requested task but survives advancing the next create attempt",
       %{client: client, session: session} do
    offer = "offer:fenced-workspace"

    session =
      session |> Ecto.Changeset.change(workspace_task: %{"offer_ref" => offer}) |> Repo.update!()

    key = "create:task-identity"

    assert {:ok, receipt} =
             Client.fence_create_session(
               client,
               key,
               session.policy,
               offer,
               session.repository_source
             )

    assert {:error, {:coop_worker_command_conflict, ^key}} =
             Client.fence_create_session(
               client,
               key,
               session.policy,
               session.external_ref,
               session.repository_source
             )

    assert {:ok, real} = Client.new(workspace_ref: "workspace-main")

    assert {:error, {:coop_worker_command_conflict, ^key}} =
             Client.create_session(
               real,
               key,
               session.policy,
               session.external_ref,
               session.repository_source
             )

    session
    |> Ecto.Changeset.change(create_generation: session.create_generation + 1)
    |> Repo.update!()

    assert {:ok, ^receipt} =
             Client.fence_create_session(
               client,
               key,
               session.policy,
               offer,
               session.repository_source
             )

    assert Repo.aggregate(Placement, :count) == 0
  end

  test "unplaced terminal commands cannot have missing receipts or partial placement identity", %{
    client: client,
    session: session
  } do
    key = "create:database-constraint"

    assert {:ok, _receipt} =
             Client.fence_create_session(
               client,
               key,
               session.policy,
               session.external_ref,
               session.repository_source
             )

    command = Repo.get_by!(Command, idempotency_key: key)

    for fields <- [
          %{operation_key: nil},
          %{result_fingerprint: nil},
          %{worker_id: "partial-worker"}
        ] do
      changeset =
        command
        |> Ecto.Changeset.change(fields)
        |> Ecto.Changeset.check_constraint(:operation_key,
          name: :coop_worker_command_identity_valid
        )

      assert {:error, changeset} = Repo.update(changeset, mode: :savepoint)
      assert "is invalid" in errors_on(changeset).operation_key
    end

    assert Repo.get!(Command, command.id) == command
  end

  test "direct create enqueue cannot resurrect a bound or discarded session", %{session: session} do
    command = command!(session, "placement-before-pruning")

    for attributes <- [
          %{coop_session_id: "already-bound"},
          %{coop_session_id: nil, cleanup_status: :discarded}
        ] do
      session = session |> Ecto.Changeset.change(attributes) |> Repo.update!()
      key = "create:after-prune:#{Ecto.UUID.generate()}"

      assert ControlPlane.enqueue_command(
               command.placement_id,
               "create_session",
               create_payload(session, session.external_ref),
               key
             ) == {:error, {:coop_fleet_authority_mismatch, :worker_job}}

      refute Repo.get_by(Command, idempotency_key: key)
    end
  end

  test "create session carries the admission-pinned authority and no worker-selected policy", %{
    client: client,
    session: session
  } do
    key = "ryker:work:create:#{session.id}:g1"

    assert {:ok, %{"session" => %{"id" => "remote-resource"}}} =
             Client.create_session(
               client,
               key,
               @policy,
               session.external_ref,
               session.repository_source
             )

    assert_receive {:fleet_command, ^session, "create_session", payload, ^key, options}

    assert payload == create_payload(session, session.external_ref)

    assert Keyword.fetch!(options, :workspace_ref) == "workspace-main"
    assert Keyword.fetch!(options, :capability_names) == ["controller-tools"]

    assert Client.create_session(
             client,
             key,
             "write-everywhere",
             session.external_ref,
             session.repository_source
           ) == {:error, {:coop_fleet_authority_mismatch, :policy}}

    refute_receive {:fleet_command, _, _, _, _, _}
  end

  test "fleet create carries the selector and its fence hashes the identical payload", %{
    client: client,
    session: session
  } do
    key = "ryker:work:create:#{session.id}:g1"
    source = %{"kind" => "branch", "name" => "feature/payments"}

    # The fleet forwards only what custody persisted: asking it to create this
    # session under another selector is an authority mismatch, exactly like
    # asking for another policy.
    assert Client.create_session(client, key, @policy, session.external_ref, source) ==
             {:error, {:coop_fleet_authority_mismatch, :repository_source}}

    refute_receive {:fleet_command, _, _, _, _, _}

    session =
      session |> Ecto.Changeset.change(repository_source: source) |> Repo.update!() |> pin_job!()

    assert {:ok, %{"session" => %{"id" => "remote-resource"}}} =
             Client.create_session(client, key, @policy, session.external_ref, source)

    assert_receive {:fleet_command, ^session, "create_session", created, ^key, _options}

    assert created == create_payload(session)

    fence_key = "#{key}:durable"

    operation = %{
      "id" => "operation-selector-create",
      "method" => "CreateRemoteSession",
      "resource_id" => "remote-selector-create",
      "resource_type" => "session",
      "state" => "succeeded"
    }

    session
    |> command!("selector-fence", kind: "create_session", payload: created, key: fence_key)
    |> complete_command!(:succeeded, %{"operation" => operation})

    Process.put(:coop_fleet_reconcile_result, %{"operation" => operation})

    assert {:ok, ^operation} =
             Client.fence_create_session(client, fence_key, @policy, session.external_ref, source)

    # The same operation identity carrying another selector is a conflict, not a
    # rebind: a retry must never land the workspace on a different source. A
    # durable command that somehow recorded another selector under this key is
    # refused for the same reason.
    assert Client.fence_create_session(client, fence_key, @policy, session.external_ref, %{
             "kind" => "default"
           }) == {:error, {:coop_fleet_authority_mismatch, :repository_source}}

    assert Client.fence_create_session(client, fence_key, @policy, session.external_ref, nil) ==
             {:error, {:coop_fleet_authority_mismatch, :repository_source}}

    Command
    |> Repo.get_by!(idempotency_key: fence_key)
    |> Ecto.Changeset.change(payload: Map.put(created, "source", %{"kind" => "default"}))
    |> Repo.update!()

    assert Client.fence_create_session(client, fence_key, @policy, session.external_ref, source) ==
             {:error, {:coop_worker_command_conflict, fence_key}}
  end

  test "a selector outside the frozen union is refused before any worker command", %{
    client: client,
    session: session
  } do
    key = "ryker:work:create:#{session.id}:g1"

    for invalid <- [
          %{"kind" => "tag", "name" => "v1"},
          %{"kind" => "branch", "name" => "refs/heads/main"},
          %{"kind" => "commit", "sha" => String.duplicate("A", 40)}
        ] do
      assert Client.create_session(client, key, @policy, session.external_ref, invalid) ==
               {:error, {:invalid_coop_request, :repository_source}}

      assert Client.fence_create_session(client, key, @policy, session.external_ref, invalid) ==
               {:error, {:invalid_coop_request, :repository_source}}
    end

    refute_receive {:fleet_command, _, _, _, _, _}
  end

  test "an unplaced session reports the configured freshness requirement", %{
    session: session
  } do
    assert {:ok, unversioned} = Client.new(workspace_ref: "workspace-main")

    assert {:ok, %{"repository_freshness_receipt_versions" => []}} =
             Client.capabilities(unversioned, session)

    assert {:ok, versioned} =
             Client.new(
               capability_versions: %{
                 "repository-freshness" => "2"
               },
               workspace_ref: "workspace-main"
             )

    assert {:ok,
            %{
              "repository_freshness_receipt_versions" => [2]
            }} = Client.capabilities(versioned, session)
  end

  test "freshness capability follows the exact session placement during a rolling upgrade", %{
    client: client,
    session: session
  } do
    command = command!(session, "freshness-capability")

    upgraded_worker_id = "client-worker-upgraded-#{Ecto.UUID.generate()}"
    certificate_sha256 = digest(upgraded_worker_id)

    assert {:ok, _worker} =
             CoopWorkers.authorize(
               upgraded_worker_id,
               "workspace-main",
               certificate_sha256
             )

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(
               upgraded_worker_id,
               poll(upgraded_worker_id, "upgraded-unplaced", true)
             )

    assert {:ok, %{"repository_freshness_receipt_versions" => []}} =
             Client.capabilities(client, session)

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(
               command.worker_id,
               poll(command.worker_id, "upgraded-placed", true)
             )

    assert {:ok, %{"repository_freshness_receipt_versions" => [2]}} =
             Client.capabilities(client, session)

    command.placement_id
    |> then(&Repo.get!(Placement, &1))
    |> Ecto.Changeset.change(lease_expires_at: DateTime.add(Repo.now!(), -1, :second))
    |> Repo.update!()

    assert Client.capabilities(client, session) ==
             {:error, {:coop_upgrade_required, :repository_freshness_v2}}
  end

  test "a confirmed engineering session ensures its exact task before create returns", %{
    client: client,
    session: session
  } do
    workspace_task = %{
      "authority_limits" => ["must not deploy"],
      "instruction_ref" => "input:trusted:1",
      "offer_ref" => "record:task_offer:0123456789abcdef",
      "prompt" => "Change the parser and preserve idempotency.",
      "source_refs" => ["artifact:incident:1"],
      "success_checks" => ["focused tests pass", "retry remains idempotent"],
      "title" => "Fix parser retries"
    }

    session =
      session
      |> Session.Changeset.bind_workspace_task(workspace_task)
      |> Repo.update!()

    key = "ryker:work:create:#{session.id}:g1"

    assert {:ok, %{"session" => %{"id" => "remote-resource", "revision" => 2}}} =
             Client.create_session(
               client,
               key,
               @policy,
               workspace_task["offer_ref"],
               session.repository_source
             )

    assert_receive {:fleet_command, ^session, "create_session", create_payload, ^key, _}

    assert create_payload["external_ref"] == workspace_task["offer_ref"]

    assert_receive {:fleet_command, ^session, "ensure_workspace", payload, ensure_key, _}

    assert payload == %{
             "coop_session_id" => "remote-resource",
             "expected_revision" => 1,
             "task" => workspace_task
           }

    assert ensure_key =~ "ryker:workspace:"
  end

  test "a worker's invented transfer receipt is not accepted as durable checkpoint custody", %{
    client: client,
    session: session
  } do
    session = bind_session!(session, "coop-session-checkpoint")

    assert Client.checkpoint_workspace(client, session.coop_session_id, "checkpoint-key-1", 4) ==
             {:error, :checkpoint_not_available}

    assert_receive {:fleet_command, ^session, "checkpoint_workspace", payload, "checkpoint-key-1",
                    _options}

    assert payload == %{
             "coop_session_id" => session.coop_session_id,
             "expected_revision" => 4,
             "repository_ref" => "ryker",
             "session_ref" => session.id
           }
  end

  test "a replacement engineering generation restores only the latest verified checkpoint", %{
    client: client,
    session: session
  } do
    workspace_task = %{
      "authority_limits" => ["must not deploy"],
      "offer_ref" => "record:task_offer:replacement-checkpoint",
      "prompt" => "Continue the exact writable workspace.",
      "source_refs" => [],
      "success_checks" => ["focused tests pass"],
      "title" => "Restore checkpoint"
    }

    source =
      session
      |> Session.Changeset.bind_workspace_task(workspace_task)
      |> Ecto.Changeset.change(coop_session_id: "coop-session-source")
      |> Repo.update!()

    command = command!(source, "checkpoint-source")

    command =
      command
      |> Ecto.Changeset.change(
        kind: "checkpoint_workspace",
        payload: %{
          "coop_session_id" => source.coop_session_id,
          "expected_revision" => 4,
          "repository_ref" => "ryker",
          "session_ref" => source.id
        }
      )
      |> Repo.update!()

    command =
      complete_command!(command, :succeeded, %{
        "checkpoint_ref" => "checkpoint:pending",
        "state" => "stored",
        "transfer_id" => Ecto.UUID.generate()
      })

    {checkpoint, bundle} =
      WorkspaceCheckpointFixture.build(%{
        session_ref: source.id,
        placement_generation: command.placement_generation
      })

    transfer_id = Ecto.UUID.generate()

    %WorkspaceCheckpointTransfer{
      id: transfer_id,
      command_id: command.id,
      worker_id: command.worker_id,
      checkpoint_ref: checkpoint["checkpoint_ref"],
      session_ref: source.id,
      placement_generation: command.placement_generation,
      repository_ref: "ryker",
      descriptor: checkpoint,
      bundle_sha256: checkpoint["bundle"]["sha256"],
      bundle_byte_size: byte_size(bundle),
      body_command_id: command.id,
      encryption_key_sha256: String.duplicate("a", 64)
    }
    |> Repo.insert!()

    # A replacement generation carries its predecessor's exact repository source,
    # which is what makes the checkpoint's tree the right seed for it.
    replacement =
      Session.Changeset.insert(%{
        id: Ecto.UUID.generate(),
        episode_id: source.episode_id,
        generation: 2,
        policy: source.policy,
        policy_digest: source.policy_digest,
        repository_ref: source.repository_ref,
        external_ref: source.external_ref,
        authority_digest: source.authority_digest,
        repository_source: source.repository_source,
        worker_job_document: source.worker_job_document,
        worker_job_digest: source.worker_job_digest,
        workspace_task: nil
      })
      |> Repo.insert!()
      |> Session.Changeset.bind_workspace_task(workspace_task)
      |> Repo.update!()

    key = "ryker:work:create:#{replacement.id}:g1"

    assert {:ok, %{"session" => %{"id" => "remote-resource", "revision" => 2}}} =
             Client.create_session(
               client,
               key,
               @policy,
               workspace_task["offer_ref"],
               replacement.repository_source
             )

    assert_receive {:fleet_command, ^replacement, "create_session", create_payload, ^key, _}

    assert create_payload["external_ref"] == workspace_task["offer_ref"]

    assert_receive {:fleet_command, ^replacement, "ensure_workspace", payload, _ensure_key, _}

    assert payload["checkpoint"] == %{
             "byte_size" => byte_size(bundle),
             "checkpoint_ref" => checkpoint["checkpoint_ref"],
             "sha256" => checkpoint["bundle"]["sha256"],
             "source_placement_generation" => command.placement_generation,
             "source_session_ref" => source.id,
             "transfer_id" => transfer_id
           }

    # A checkpoint taken from another source can never seed this generation.
    # Rotation copies the selector verbatim, so a mismatch is tampering or a
    # bug, and the answer is to refuse rather than start from the wrong tree.
    source
    |> Ecto.Changeset.change(repository_source: %{"kind" => "branch", "name" => "feature/other"})
    |> Repo.update!()

    other =
      replacement
      |> Ecto.Changeset.change(external_ref: "other-generation")
      |> Repo.update!()
      |> pin_job!()

    assert Client.create_session(
             client,
             "#{key}:other",
             @policy,
             other.external_ref,
             other.repository_source
           ) == {:error, {:coop_workspace_checkpoint_source_mismatch, other.id, other.generation}}

    refute_receive {:fleet_command, ^other, "ensure_workspace", _, _, _}
  end

  test "a replacement after the task was never bound starts from a clean workspace", %{
    client: client,
    session: session
  } do
    workspace_task = %{
      "authority_limits" => ["must not deploy"],
      "offer_ref" => "record:task_offer:unbound-replacement",
      "prompt" => "Continue the exact writable task.",
      "source_refs" => [],
      "success_checks" => ["focused tests pass"],
      "title" => "Recover unbound task"
    }

    source =
      session
      |> Session.Changeset.bind_workspace_task(workspace_task)
      |> Ecto.Changeset.change(coop_session_id: "coop-session-never-task-bound")
      |> Repo.update!()

    replacement =
      Session.Changeset.insert(%{
        id: Ecto.UUID.generate(),
        episode_id: source.episode_id,
        generation: 2,
        policy: source.policy,
        policy_digest: source.policy_digest,
        repository_ref: source.repository_ref,
        external_ref: source.external_ref,
        authority_digest: source.authority_digest,
        repository_source: source.repository_source,
        worker_job_document: source.worker_job_document,
        worker_job_digest: source.worker_job_digest,
        workspace_task: nil
      })
      |> Repo.insert!()
      |> Session.Changeset.bind_workspace_task(workspace_task)
      |> Repo.update!()

    key = "ryker:work:create:#{replacement.id}:g1"

    # Covers: TestUnboundTaskReplacementStartsClean
    # The third live retry had a remote session ID but never acquired a writable workspace;
    # requiring a nonexistent checkpoint would strand the repaired task again.
    assert {:ok, %{"session" => %{"id" => "remote-resource", "revision" => 2}}} =
             Client.create_session(
               client,
               key,
               @policy,
               workspace_task["offer_ref"],
               replacement.repository_source
             )

    assert_receive {:fleet_command, ^replacement, "ensure_workspace", payload, _ensure_key, _}
    refute Map.has_key?(payload, "checkpoint")
  end

  test "a replacement after task binding but before any turn starts uses a clean workspace", %{
    client: client,
    session: session
  } do
    workspace_task = %{
      "authority_limits" => ["runner version only"],
      "offer_ref" => "record:task_offer:bound-without-turn",
      "prompt" => "Bump the internal hosted runner version.",
      "source_refs" => [],
      "success_checks" => ["focused tests pass"],
      "title" => "Bump hosted runner"
    }

    source =
      session
      |> Session.Changeset.bind_workspace_task(workspace_task)
      |> Ecto.Changeset.change(coop_session_id: "coop-session-bound-without-turn")
      |> Repo.update!()

    binding =
      command!(source, "bound-without-turn",
        kind: "ensure_workspace",
        payload: %{
          "coop_session_id" => source.coop_session_id,
          "expected_revision" => 1,
          "task" => workspace_task
        }
      )

    complete_command!(binding, :succeeded, %{
      "session" => %{
        "id" => source.coop_session_id,
        "revision" => 2,
        "state" => "open",
        "workspace_task" => %{"offer_ref" => workspace_task["offer_ref"]}
      }
    })

    replacement =
      Session.Changeset.insert(%{
        id: Ecto.UUID.generate(),
        episode_id: source.episode_id,
        generation: 2,
        policy: source.policy,
        policy_digest: source.policy_digest,
        repository_ref: source.repository_ref,
        external_ref: source.external_ref,
        authority_digest: source.authority_digest,
        repository_source: source.repository_source,
        worker_job_document: source.worker_job_document,
        worker_job_digest: source.worker_job_digest,
        workspace_task: nil
      })
      |> Repo.insert!()
      |> Session.Changeset.bind_workspace_task(workspace_task)
      |> Repo.update!()

    key = "ryker:work:create:#{replacement.id}:g1"

    # The production session was task-bound but closed with turns_used=0. With no submit
    # command, there is no model-authored workspace state to checkpoint into the replacement.
    assert {:ok, %{"session" => %{"id" => "remote-resource", "revision" => 2}}} =
             Client.create_session(
               client,
               key,
               @policy,
               workspace_task["offer_ref"],
               replacement.repository_source
             )

    assert_receive {:fleet_command, ^replacement, "ensure_workspace", payload, _ensure_key, _}
    refute Map.has_key?(payload, "checkpoint")
  end

  test "a replacement still requires a checkpoint after any turn submission attempt", %{
    client: client,
    session: session
  } do
    workspace_task = %{
      "authority_limits" => ["must preserve workspace changes"],
      "offer_ref" => "record:task_offer:attempted-binding",
      "prompt" => "Continue without losing prior work.",
      "source_refs" => [],
      "success_checks" => ["prior changes survive"],
      "title" => "Preserve attempted workspace"
    }

    source =
      session
      |> Session.Changeset.bind_workspace_task(workspace_task)
      |> Ecto.Changeset.change(coop_session_id: "coop-session-binding-attempted")
      |> Repo.update!()

    _binding_command =
      command!(source, "attempted-workspace-binding",
        kind: "ensure_workspace",
        payload: %{
          "coop_session_id" => source.coop_session_id,
          "expected_revision" => 1,
          "task" => workspace_task
        }
      )

    _turn_command =
      command!(source, "attempted-turn-submission",
        kind: "submit_turn",
        payload: %{
          "coop_session_id" => source.coop_session_id,
          "expected_revision" => 2,
          "submission" => %{"prompt" => "Continue the exact task."}
        }
      )

    replacement =
      Session.Changeset.insert(%{
        id: Ecto.UUID.generate(),
        episode_id: source.episode_id,
        generation: 2,
        policy: source.policy,
        policy_digest: source.policy_digest,
        repository_ref: source.repository_ref,
        external_ref: source.external_ref,
        authority_digest: source.authority_digest,
        repository_source: source.repository_source,
        worker_job_document: source.worker_job_document,
        worker_job_digest: source.worker_job_digest,
        workspace_task: nil
      })
      |> Repo.insert!()
      |> Session.Changeset.bind_workspace_task(workspace_task)
      |> Repo.update!()

    key = "ryker:work:create:#{replacement.id}:g1"

    assert {:error, {:coop_workspace_checkpoint_required, source_id, source_generation}} =
             Client.create_session(
               client,
               key,
               @policy,
               workspace_task["offer_ref"],
               replacement.repository_source
             )

    assert source_id == source.id
    assert source_generation == source.generation

    refute_receive {:fleet_command, ^replacement, "ensure_workspace", _, _, _}
  end

  test "frozen submit preserves exact persisted prompt schema context and digest", %{
    client: client,
    session: session
  } do
    session = bind_session!(session, "coop-session-1")

    submission = %{
      "contract_version" => "work-final-live-v3",
      "context" => %{"turn_ref" => "turn-7", "input_refs" => ["input-1"]},
      "input_artifact_refs" => [],
      "output_schema" => %{"type" => "object"},
      "prompt" => "exact & <frozen> prompt"
    }

    key = "ryker:work:submit:turn-7:g1"

    binding = %{
      "endpoint" => "https://ryker.example/v1/state-tools/mcp",
      "token" => String.duplicate("a", 64) <> String.duplicate("t", 43)
    }

    assert {:ok, _resource} =
             Client.submit_frozen_turn(
               client,
               session.coop_session_id,
               key,
               4,
               submission,
               binding,
               []
             )

    assert_receive {:fleet_command, ^session, "submit_turn", payload, ^key, _options}

    assert payload == %{
             "coop_session_id" => "coop-session-1",
             "expected_revision" => 4,
             "controller_tools" => %{
               "endpoint" => binding["endpoint"],
               "token_sha256" => Crypto.sha256_hex(binding["token"])
             },
             "submission" => submission,
             "submission_sha256" =>
               "7afc3936977c127a93fe257e79185fa6e5b0a04fd7f6803e927cadf174e76382",
             "turn_ref" => "turn-7"
           }
  end

  test "fleet submission keeps the prepared instructions after an operator clears them", %{
    client: client,
    session: session
  } do
    session = bind_session!(session, "coop-session-instructions")
    assert {:ok, _} = Instructions.save(:global, "Keep replies concise.", 0, "operator:test")
    assert {:ok, claim} = Custody.claim_next("fleet-instructions", 300)
    assert claim.episode.id == session.episode_id
    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert {:ok, frozen} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, _} = Instructions.save(:global, "", 1, "operator:test")
    key = "ryker:work:submit:#{claim.turn.turn_ref}:g1"

    assert {:ok, _} =
             Client.submit_frozen_turn(
               client,
               session.coop_session_id,
               key,
               4,
               frozen.submission,
               nil,
               []
             )

    assert_receive {:fleet_command, ^session, "submit_turn", payload, ^key, _}
    assert payload["submission"] == frozen.submission
    assert payload["submission_sha256"] == frozen.submission_fingerprint

    assert Jason.decode!(payload["submission"]["prompt"])["work"]["custom_instructions"][
             "global"
           ] == %{"scope" => "global", "revision" => 1, "text" => "Keep replies concise."}
  end

  test "semantic validation carries the exact candidate attempt and frozen verdict", %{
    client: client,
    session: session
  } do
    session = bind_session!(session, "coop-session-2")
    sha256 = String.duplicate("c", 64)
    key = "ryker:work:validate:turn-8:a3:#{sha256}:reject:g1"

    assert {:ok, _resource} =
             Client.validate_frozen_candidate(
               client,
               session.coop_session_id,
               "coop-turn-8",
               key,
               3,
               sha256,
               {:reject, ["missing required evidence"]}
             )

    assert_receive {:fleet_command, ^session, "validate_candidate", payload, ^key, _options}

    assert payload == %{
             "candidate_attempt" => 3,
             "candidate_sha256" => sha256,
             "coop_session_id" => "coop-session-2",
             "coop_turn_id" => "coop-turn-8",
             "verdict" => "reject",
             "violations" => ["missing required evidence"]
           }
  end

  test "publication freezes its first command after its placement ends",
       %{client: client, session: session} do
    session = bind_session!(session, "publication-owner")
    owner = uncertain_review!(session, "publication-owner")
    body = publication_body()
    response = publication_response(session)
    Process.put(:coop_fleet_await_result, {:ok, response})
    key = "publish:owner"

    assert {:ok, receipt} =
             Client.publish_review(
               client,
               session.coop_session_id,
               owner.idempotency_key,
               "review-op",
               key,
               body
             )

    command = Repo.get_by!(Command, idempotency_key: key)
    assert command.placement_id == owner.placement_id
    assert command.payload["body"] == body
    assert command.payload["path"] == "/v1/sessions/publication-owner/reviews/review-op/publish"
    assert receipt == response["publication"]["receipt"]
    complete_command!(command, :succeeded, response)

    Repo.get!(Placement, owner.placement_id)
    |> Ecto.Changeset.change(state: :retired)
    |> Repo.update!()

    changed_settings =
      Map.merge(body, %{"branch" => "new-prefix/ignored", "title" => "New title"})

    assert {:ok, ^receipt} =
             Client.publish_review(
               client,
               session.coop_session_id,
               owner.idempotency_key,
               "review-op",
               key,
               changed_settings
             )

    assert Repo.get!(Command, command.id).payload["body"] == body

    assert {:error, {:coop_worker_command_conflict, ^key}} =
             Client.publish_review(
               client,
               session.coop_session_id,
               owner.idempotency_key,
               "review-op",
               key,
               Map.put(body, "candidate_head", String.duplicate("f", 40))
             )

    assert Repo.aggregate(Command, :count) == 2
    refute_receive {:fleet_command, _, _, _, _, _}
  end

  # A review waits for a person; its placement's lease does not. On 30 Sep Andrew approved an
  # emisar draft six hours after its review ran, and PR #2's update a day and a half after its
  # review. Both placements had lapsed while the worker still held both sessions, so each
  # publication deferred once a minute (31 and 33 attempts) and its card said "PR preparation
  # stopped after an error".
  test "a review approved after its placement lapsed publishes from the worker still holding it",
       %{client: client, session: session} do
    session = bind_session!(session, "publication-lapsed")
    owner = lapsed_review!(session, "publication-lapsed")
    response = publication_response(session)
    Process.put(:coop_fleet_await_result, {:ok, response})
    key = "publish:lapsed"

    assert {:ok, receipt} =
             Client.publish_review(
               client,
               session.coop_session_id,
               owner.idempotency_key,
               "review-op",
               key,
               publication_body()
             )

    assert receipt == response["publication"]["receipt"]
    command = Repo.get_by!(Command, idempotency_key: key)
    assert command.worker_id == owner.worker_id
    assert command.placement_generation > owner.placement_generation
    complete_command!(command, :succeeded, response)

    assert {:ok, ^receipt} =
             Client.publish_review(
               client,
               session.coop_session_id,
               owner.idempotency_key,
               "review-op",
               key,
               publication_body()
             )

    refute_receive {:fleet_command, _, _, _, _, _}
  end

  test "a review whose worker went quiet never publishes from anywhere else",
       %{client: client, session: session} do
    session = bind_session!(session, "publication-quiet")
    owner = lapsed_review!(session, "publication-quiet")

    Repo.get!(Worker, owner.worker_id)
    |> Ecto.Changeset.change(last_seen_at: DateTime.add(Repo.now!(), -300))
    |> Repo.update!()

    assert {:error, {:coop_session_replacement_required, _, _}} =
             Client.publish_review(
               client,
               session.coop_session_id,
               owner.idempotency_key,
               "review-op",
               "publish:quiet",
               publication_body()
             )

    refute Repo.get_by(Command, idempotency_key: "publish:quiet")
    refute_receive {:fleet_command, _, _, _, _, _}
  end

  # The same crash can land between a publish being accepted and it finishing: the pull
  # request is being made on the worker while the placement that asked for it lapses.
  test "an accepted publish whose placement lapsed is read through the worker still holding it",
       %{client: client, session: session} do
    session = bind_session!(session, "publication-accepted")
    owner = uncertain_review!(session, "publication-accepted")
    response = publication_response(session)
    running = %{"operation" => Map.put(response["operation"], "state", "running")}
    key = "publish:accepted"

    Process.put(:coop_fleet_await_result, fn id ->
      case Repo.get!(Command, id) do
        %Command{kind: "api_request", idempotency_key: ^key} -> {:ok, running}
        %Command{kind: "reconcile_operation"} -> {:ok, Process.get(:publication_operation)}
        %Command{kind: "api_request"} -> {:ok, response}
      end
    end)

    Process.put(:publication_operation, running["operation"])

    assert {:error, {:coop_unavailable, _}} =
             Client.publish_review(
               client,
               session.coop_session_id,
               owner.idempotency_key,
               "review-op",
               key,
               publication_body()
             )

    replaced_placement!(owner.placement_id)

    Process.put(:publication_operation, response["operation"])

    assert {:ok, receipt} =
             Client.publish_review(
               client,
               session.coop_session_id,
               owner.idempotency_key,
               "review-op",
               key,
               publication_body()
             )

    assert receipt == response["publication"]["receipt"]

    lookups =
      Repo.all(
        from(command in Command,
          where:
            command.kind in ["reconcile_operation", "api_request"] and
              command.idempotency_key != ^key,
          order_by: command.inserted_at
        )
      )

    assert [_first_reconcile | after_lapse] = lookups
    assert after_lapse != []
    assert Enum.all?(after_lapse, &(&1.worker_id == owner.worker_id))
    assert Enum.all?(after_lapse, &(&1.placement_generation > owner.placement_generation))
  end

  test "accepted background publication recovers through the real poll and remains readable after placement expiry",
       %{session: session} do
    session = bind_session!(session, "publication-background")
    owner = uncertain_review!(session, "publication-background")
    response = publication_response(session)
    pending = %{"operation" => Map.put(response["operation"], "state", "running")}
    key = "publish:background"

    assert {:ok, client} =
             Client.new(
               workspace_ref: "workspace-main",
               max_waits: 2,
               poll_interval_ms: 1,
               wait: fn ->
                 {:ok, %{"commands" => [request]}} =
                   ControlPlane.handle_poll_certificate(
                     owner.worker_id,
                     poll(owner.worker_id, Ecto.UUID.generate())
                   )

                 stored = Repo.get!(Command, request["command_id"])
                 assert stored.placement_id == owner.placement_id

                 {status, result} =
                   case request["payload"] do
                     %{"method" => "POST", "body" => body} ->
                       assert body == publication_body()
                       {202, pending}

                     %{"method" => "GET", "path" => "/v1/operations?" <> query} ->
                       assert URI.decode_query(query) == %{"key" => key}
                       {200, response["operation"]}

                     %{
                       "method" => "GET",
                       "path" => "/v1/sessions/publication-background/publications/publish-op"
                     } ->
                       {200, response}
                   end

                 result = %{
                   "command_id" => request["command_id"],
                   "operation_key" => request["idempotency_key"],
                   "state" => "succeeded",
                   "error" => nil,
                   "resource" => %{"status" => status, "body" => result}
                 }

                 {:ok, acknowledgement} =
                   ControlPlane.handle_poll_certificate(
                     owner.worker_id,
                     Map.put(poll(owner.worker_id, Ecto.UUID.generate()), "command_results", [
                       result
                     ])
                   )

                 assert acknowledgement["acknowledged_result_command_ids"] == [
                          request["command_id"]
                        ]

                 :ok
               end
             )

    assert {:ok, receipt} =
             Client.publish_review(
               client,
               session.coop_session_id,
               owner.idempotency_key,
               "review-op",
               key,
               publication_body()
             )

    assert Repo.get_by!(Command, idempotency_key: key).result["status"] == 202
    assert Repo.aggregate(Command, :count) == 4

    Repo.get!(Placement, owner.placement_id)
    |> Ecto.Changeset.change(lease_expires_at: DateTime.add(Repo.now!(), -1))
    |> Repo.update!()

    assert {:ok, ^receipt} =
             Client.publish_review(
               client,
               session.coop_session_id,
               owner.idempotency_key,
               "review-op",
               key,
               publication_body()
             )

    assert Repo.aggregate(Command, :count) == 4
  end

  test "publication preserves terminal refusals without creating conflict evidence or retrying",
       %{client: client, session: session} do
    session = bind_session!(session, "publication-refused")
    owner = uncertain_review!(session, "publication-refused")

    for code <- [
          :publication_authorization_revoked,
          :publication_branch_already_exists,
          :publication_existing_pull_request_changed,
          :publication_pull_request_mismatch
        ] do
      response =
        Map.put(publication_response(session), "publication", %{
          "status" => "refused",
          "error_code" => Atom.to_string(code)
        })

      Process.put(:coop_fleet_await_result, {:ok, response})

      assert {:error, ^code} =
               Client.publish_review(
                 client,
                 session.coop_session_id,
                 owner.idempotency_key,
                 "review-op",
                 "publish:#{code}",
                 publication_body()
               )
    end

    Process.put(:coop_fleet_await_result, {:ok, %{"operation" => %{"state" => "succeeded"}}})

    assert Client.publish_review(
             client,
             session.coop_session_id,
             owner.idempotency_key,
             "review-op",
             "publish:malformed",
             publication_body()
           ) == {:error, {:coop_protocol_error, :publication_resource}}

    refute_receive {:fleet_command, _, _, _, _, _}
  end

  test "workspace review and retention remain typed commands on the same placed session", %{
    client: client,
    session: session
  } do
    session = bind_session!(session, "coop-session-lifecycle")

    assert {:ok, _} = Client.get_changes(client, session.coop_session_id)
    assert_receive {:fleet_command, ^session, "get_changes", changes, _read_key, _options}
    assert changes == %{"coop_session_id" => session.coop_session_id}

    assert {:ok, _} = Client.get_changes_page(client, session.coop_session_id, 2_400, 2_400)
    assert_receive {:fleet_command, ^session, "get_changes_page", page, _read_key, _options}

    assert page == %{
             "coop_session_id" => session.coop_session_id,
             "patch_limit" => 2_400,
             "patch_offset" => 2_400
           }

    assert {:ok, _} = Client.run_review(client, session.coop_session_id, "review-key", 7)
    assert_receive {:fleet_command, ^session, "run_review", review, "review-key", _options}
    assert review == %{"coop_session_id" => session.coop_session_id, "expected_revision" => 7}

    # A red review's gate output, one page per read, from Coop's cursor.
    assert {:ok, _} =
             Client.read_review_gate_output(
               client,
               session.coop_session_id,
               "review-op",
               "1048576"
             )

    assert_receive {:fleet_command, ^session, "get_review_gate_output", output, _read_key,
                    _options}

    assert output == %{
             "coop_session_id" => session.coop_session_id,
             "cursor" => "1048576",
             "operation_id" => "review-op"
           }

    assert {:ok, _} =
             Client.plan_discard(
               client,
               session.coop_session_id,
               "plan-key",
               8,
               false,
               true
             )

    assert_receive {:fleet_command, ^session, "plan_discard", plan, "plan-key", _options}

    assert plan == %{
             "accept_dirty" => false,
             "accept_unmerged" => true,
             "coop_session_id" => session.coop_session_id,
             "expected_revision" => 8
           }

    assert {:ok, _} =
             Client.discard_session(
               client,
               session.coop_session_id,
               "discard-key",
               "operation-plan-1"
             )

    assert_receive {:fleet_command, ^session, "discard_session", discard, "discard-key", _options}

    assert discard == %{
             "coop_session_id" => session.coop_session_id,
             "plan_operation_id" => "operation-plan-1"
           }
  end

  test "an uncertain review recovers its completed result without rewriting the transport receipt",
       %{client: client, session: session} do
    # The real 54-second review completed after the worker's 30-second HTTP timeout;
    # every publication retry then replayed the same transport uncertainty forever.
    response = completed_review_fixture()
    session = bind_session!(session, response["review"]["session_id"])
    command = uncertain_review!(session, "completed")
    Process.put(:coop_fleet_await_result, {:ok, response})

    assert Client.run_review(client, session.coop_session_id, command.idempotency_key, 3) ==
             {:ok, response}

    assert_receive {:fleet_await, reconciliation_id}
    reconciliation = Repo.get!(Command, reconciliation_id)
    assert reconciliation.kind == "reconcile_operation"
    assert reconciliation.payload == %{"operation_key" => command.idempotency_key}
    assert reconciliation.placement_id == command.placement_id
    assert reconciliation.placement_generation == command.placement_generation
    assert Repo.get!(Command, command.id) == command
    refute_receive {:fleet_command, _, "run_review", _, _, _}
  end

  test "review reconciliation preserves pending and definite failed operation outcomes", %{
    client: client,
    session: session
  } do
    session = bind_session!(session, completed_review_fixture()["review"]["session_id"])
    command = uncertain_review!(session, "pending")

    for state <- ["reserved", "running"] do
      Process.put(:coop_fleet_await_result, {:ok, %{"method" => "RunReview", "state" => state}})

      assert Client.run_review(client, session.coop_session_id, command.idempotency_key, 3) ==
               {:error, {:coop_unavailable, "Review operation has not completed."}}
    end

    # Coop marks an operation uncertain when its service restarts under it; that review never
    # finishes. On 30 Sep OrbStack crashed mid-review and the publication waited on it forever.
    Process.put(
      :coop_fleet_await_result,
      {:ok, %{"method" => "RunReview", "state" => "uncertain"}}
    )

    assert {:error, {:coop_review_lost, _detail}} =
             Client.run_review(client, session.coop_session_id, command.idempotency_key, 3)

    Process.put(:coop_fleet_await_result, {
      :ok,
      %{
        "method" => "RunReview",
        "state" => "failed",
        "error_code" => "revision_conflict",
        "error_detail" => "stale revision"
      }
    })

    assert Client.run_review(client, session.coop_session_id, command.idempotency_key, 3) ==
             {:error, {:coop_error, 409, "revision_conflict", "stale revision"}}

    assert Repo.get!(Command, command.id) == command
  end

  test "a failed completed-review lookup remains a failure", %{
    client: client,
    session: session
  } do
    response = completed_review_fixture()
    session = bind_session!(session, response["review"]["session_id"])
    command = uncertain_review!(session, "upgrade")

    Process.put(:coop_fleet_await_result, fn id ->
      case Repo.get!(Command, id).kind do
        "reconcile_operation" -> {:ok, response["operation"]}
        "get_review" -> {:error, {:coop_error, 404, "review_not_found", "missing"}}
      end
    end)

    assert Client.run_review(client, session.coop_session_id, command.idempotency_key, 3) ==
             {:error, {:coop_error, 404, "review_not_found", "missing"}}

    assert Repo.get!(Command, command.id) == command
  end

  test "a completed review crosses the real outbound poll without replacing its uncertain command",
       %{session: session} do
    response = completed_review_fixture()
    session = bind_session!(session, response["review"]["session_id"])
    command = uncertain_review!(session, "outbound")

    assert {:ok, client} =
             Client.new(
               workspace_ref: "workspace-main",
               max_waits: 2,
               poll_interval_ms: 1,
               wait: fn ->
                 assert {:ok, %{"commands" => [read]}} =
                          ControlPlane.handle_poll_certificate(
                            command.worker_id,
                            poll(command.worker_id, "read")
                          )

                 assert read["kind"] == "api_request"
                 assert read["payload"]["method"] == "GET"
                 path = read["payload"]["path"]

                 body =
                   if String.starts_with?(path, "/v1/operations?") do
                     assert URI.decode_query(URI.parse(path).query) == %{
                              "key" => command.idempotency_key
                            }

                     response["operation"]
                   else
                     assert path ==
                              "/v1/sessions/#{session.coop_session_id}/reviews/#{response["operation"]["id"]}"

                     response
                   end

                 result = %{
                   "command_id" => read["command_id"],
                   "error" => nil,
                   "operation_key" => read["idempotency_key"],
                   "resource" => %{"status" => 200, "body" => body},
                   "state" => "succeeded"
                 }

                 poll =
                   command.worker_id
                   |> poll("result")
                   |> Map.put("command_results", [result])

                 assert {:ok, acknowledgement} =
                          ControlPlane.handle_poll_certificate(command.worker_id, poll)

                 assert acknowledgement["acknowledged_result_command_ids"] == [read["command_id"]]
                 :ok
               end
             )

    assert Client.run_review(client, session.coop_session_id, command.idempotency_key, 3) ==
             {:ok, response}

    assert Repo.get!(Command, command.id) == command
  end

  test "review recovery refuses changed requests, and a worker that went quiet, without another command",
       %{client: client, session: session} do
    session = bind_session!(session, completed_review_fixture()["review"]["session_id"])
    command = uncertain_review!(session, "fenced")

    assert {:error, {:coop_worker_command_conflict, _key}} =
             Client.run_review(client, session.coop_session_id, command.idempotency_key, 4)

    replaced_placement!(command.placement_id)

    Repo.get!(Worker, command.worker_id)
    |> Ecto.Changeset.change(last_seen_at: DateTime.add(Repo.now!(), -300))
    |> Repo.update!()

    assert {:error, {:coop_session_replacement_required, _, _}} =
             Client.run_review(client, session.coop_session_id, command.idempotency_key, 3)

    assert Repo.aggregate(Command, :count) == 1
    assert Repo.get!(Command, command.id) == command
    refute_receive {:fleet_await, _}
    refute_receive {:fleet_command, _, _, _, _, _}
  end

  # The review Andrew started at 11:34 on 30 Sep outlived its placement when OrbStack crashed
  # at 11:36; every later attempt asked for the lapsed placement and stopped there. The
  # operation lives in the worker's session service, which a newer placement reaches too.
  test "a review whose placement lapsed is reconciled through the worker still holding it", %{
    client: client,
    session: session
  } do
    response = completed_review_fixture()
    session = bind_session!(session, response["review"]["session_id"])
    command = uncertain_review!(session, "lapsed")

    replaced_placement!(command.placement_id)

    Process.put(:coop_fleet_await_result, {:ok, response})

    assert Client.run_review(client, session.coop_session_id, command.idempotency_key, 3) ==
             {:ok, response}

    assert_receive {:fleet_await, reconciliation_id}
    reconciliation = Repo.get!(Command, reconciliation_id)
    assert reconciliation.kind == "reconcile_operation"
    assert reconciliation.payload == %{"operation_key" => command.idempotency_key}
    assert reconciliation.worker_id == command.worker_id
    assert reconciliation.placement_generation > command.placement_generation
    assert Repo.get!(Command, command.id) == command
  end

  # Found live 2026-09-12 — the create that stranded an operator retry was never enqueued
  # at all. An unbound session whose placement is gone fails closed before any command row
  # exists, so the durable boundary holds no operation under that key. Those two answers
  # together are the host's proof that nothing crossed, and Work releases the create fence
  # on them instead of refusing its own session replacement on every later retry.
  test "a create the fleet cannot place enqueues nothing and leaves its key unknown", %{
    session: session
  } do
    stale = command!(session, "unplaceable-create")

    Repo.get!(Placement, stale.placement_id)
    |> Ecto.Changeset.change(
      lease_expires_at: DateTime.add(Repo.now!(), -1, :second),
      state: :replaced
    )
    |> Repo.update!()

    assert {:ok, placing} = Client.new(workspace_ref: "workspace-main")
    key = "ryker:work:create:#{session.id}:g1"

    assert Client.create_session(
             placing,
             key,
             @policy,
             session.external_ref,
             session.repository_source
           ) ==
             {:error,
              {:coop_session_replacement_required, session.id, stale.placement_generation}}

    assert Client.operation_by_key(placing, key) == :not_found
    assert Repo.aggregate(Command, :count) == 1
  end

  test "a recovered review must match the original session revision and operation", %{
    client: client,
    session: session
  } do
    response = completed_review_fixture()
    session = bind_session!(session, response["review"]["session_id"])
    command = uncertain_review!(session, "identity")

    for changed <- [
          put_in(response, ["operation", "method"], "SubmitTurn"),
          put_in(response, ["operation", "resource_id"], "another-session"),
          put_in(response, ["review", "operation_id"], "another-operation"),
          put_in(response, ["review", "session_id"], "another-session"),
          put_in(response, ["review", "session_revision"], 4)
        ] do
      Process.put(:coop_fleet_await_result, {:ok, changed})

      assert Client.run_review(client, session.coop_session_id, command.idempotency_key, 3) ==
               {:error, {:coop_protocol_error, :review_resource}}
    end
  end

  test "output artifacts use verified generic response files", %{
    client: client,
    session: session
  } do
    key = Ryker.Secret.new(:binary.copy(<<7>>, 32))
    client = %{client | bridge_options: Keyword.put(client.bridge_options, :checkpoint_key, key)}
    session = bind_session!(session, "s-binary")
    root = Path.join(System.tmp_dir!(), "coop-client-binary-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(root) end)
    id = Ecto.UUID.generate()
    bytes = <<0, 1, 2, 255>>

    reference = %{
      "byte_size" => byte_size(bytes),
      "sha256" => digest(bytes)
    }

    assert Bodies.put(root, id, :response, reference, [bytes], key) == :ok
    assert {:ok, stored, ^reference} = Bodies.fetch(root, id, :response)

    response = %{
      stored_body: stored,
      body_ref: reference,
      headers: %{"Etag" => ~s("#{reference["sha256"]}"), "Content-Type" => "image/png"}
    }

    Process.put(:coop_fleet_binary_result, {:ok, response})

    assert {:ok, artifact} = Client.get_output_artifact(client, session.coop_session_id, "t", "a")

    assert artifact == %{
             "id" => "a",
             "data" => bytes,
             "bytes" => 4,
             "sha256" => reference["sha256"],
             "media_type" => "image/png"
           }

    Process.put(:coop_fleet_binary_result, {:ok, put_in(response, [:headers, "Etag"], "wrong")})

    assert Client.get_output_artifact(client, session.coop_session_id, "t", "a") ==
             {:error, {:coop_protocol_error, :output_artifact_transfer}}
  end

  test "frozen turn transports exact artifact references without persisting their bytes", %{
    client: client,
    session: session
  } do
    session = bind_session!(session, "coop-session-artifact")
    data = "exact authenticated pull request attachment"

    assert {:ok, artifact} =
             Artifacts.put(%{
               data: data,
               media_type: "text/plain",
               name: "review.txt",
               source_kind: "github",
               source_ref: "github:review:#{Ecto.UUID.generate()}"
             })

    assert {:ok, artifacts} = Artifacts.coop_inputs([artifact.ref])

    submission = %{
      "contract_version" => "work-final-live-v3",
      "context" => %{"turn_ref" => "turn-artifact"},
      "input_artifact_refs" => [artifact.ref],
      "output_schema" => %{"type" => "object"},
      "prompt" => "Inspect the exact attachment."
    }

    assert {:ok, _resource} =
             Client.submit_frozen_turn(
               client,
               session.coop_session_id,
               "submit-artifact",
               3,
               submission,
               nil,
               artifacts
             )

    assert_receive {:fleet_command, ^session, "submit_turn", payload, "submit-artifact", _options}

    assert payload["submission"] == submission
    assert payload["submission_sha256"] == CanonicalJSON.worker_digest(submission)
    refute inspect(payload) =~ data

    fence_command =
      command!(session, "fence-artifact",
        kind: "submit_turn",
        payload: %{
          "coop_session_id" => session.coop_session_id,
          "expected_revision" => 3,
          "submission" => submission,
          "submission_sha256" => CanonicalJSON.worker_digest(submission),
          "turn_ref" => "turn-artifact"
        },
        key: "submit-artifact"
      )

    fence_command =
      complete_command!(fence_command, :succeeded, %{
        "operation" => %{
          "id" => "operation-submit-artifact",
          "method" => "SubmitTurn",
          "state" => "succeeded"
        }
      })

    assert {:ok, %{"id" => "operation-submit-artifact"}} =
             Client.fence_frozen_turn(
               client,
               session.coop_session_id,
               "submit-artifact",
               3,
               submission,
               nil,
               artifacts
             )

    assert fence_command.payload["submission"]["input_artifact_refs"] == [artifact.ref]
    refute inspect(fence_command.payload) =~ data
    refute_receive {:fleet_command, _, "fence_operation", _, "submit-artifact", _}

    [input] = artifacts
    crossed = [Map.put(input, "sha256", String.duplicate("0", 64))]

    assert Client.submit_frozen_turn(
             client,
             session.coop_session_id,
             "crossed-artifact",
             3,
             submission,
             nil,
             crossed
           ) == {:error, :coop_fleet_input_artifact_mismatch}

    refute_receive {:fleet_command, _, _, _, "crossed-artifact", _}
  end

  test "the fleet adapter carries every session and turn mutation through the pinned worker", %{
    client: client,
    session: session
  } do
    # An audited incident retry exhausted into cancellation after placement rejected the create;
    # without a command row, the outbound-only fleet could prove that nothing reached Coop.
    assert {:ok,
            %{
              "error_code" => "operation_not_enqueued",
              "method" => "CreateRemoteSession",
              "state" => "failed"
            }} =
             Client.fence_create_session(
               client,
               "fence-create",
               @policy,
               session.external_ref,
               session.repository_source
             )

    session = bind_session!(session, "coop-session-all-commands")
    schema = %{"type" => "object"}

    assert {:ok, _} = Client.get_session(client, session.coop_session_id)
    assert_receive {:fleet_command, ^session, "get_session", get_session, _key, _options}
    assert get_session == %{"coop_session_id" => session.coop_session_id}

    assert {:ok, _} =
             Client.submit_turn(
               client,
               session.coop_session_id,
               "submit",
               3,
               "frozen prompt",
               schema
             )

    assert_receive {:fleet_command, ^session, "submit_turn", submit, "submit", _options}
    assert submit["expected_revision"] == 3
    assert submit["submission"]["prompt"] == "frozen prompt"
    assert submit["submission"]["output_schema"] == schema

    assert {:ok,
            %{
              "error_code" => "operation_not_enqueued",
              "method" => "SubmitTurn",
              "state" => "failed"
            }} =
             Client.fence_frozen_turn(
               client,
               session.coop_session_id,
               "fence-submit",
               3,
               %{
                 "input_artifact_refs" => [],
                 "output_schema" => schema,
                 "prompt" => "frozen prompt"
               },
               nil,
               []
             )

    assert {:ok, _} = Client.get_turn(client, session.coop_session_id, "coop-turn-1")
    assert_receive {:fleet_command, ^session, "get_turn", get_turn, _key, _options}
    assert get_turn["coop_turn_id"] == "coop-turn-1"

    assert {:ok, _} =
             Client.validate_candidate(
               client,
               session.coop_session_id,
               "coop-turn-1",
               "accept",
               String.duplicate("a", 64),
               :accept
             )

    assert_receive {:fleet_command, ^session, "validate_candidate", accept, "accept", _options}
    assert accept["candidate_attempt"] == 1
    assert accept["verdict"] == "accept"
    assert accept["violations"] == []

    assert Client.validate_candidate(
             client,
             session.coop_session_id,
             "coop-turn-1",
             "invalid",
             String.duplicate("b", 64),
             :maybe
           ) == {:error, {:invalid_coop_request, :verdict}}

    assert {:ok, _} =
             Client.cancel_turn(client, session.coop_session_id, "coop-turn-1", "cancel", 4)

    assert_receive {:fleet_command, ^session, "cancel_turn", cancel, "cancel", _options}
    assert cancel["coop_turn_id"] == "coop-turn-1"
    assert cancel["expected_revision"] == 4

    assert {:ok, _} = Client.close_session(client, session.coop_session_id, "close", 5)
    assert_receive {:fleet_command, ^session, "close_session", close, "close", _options}
    assert close["expected_revision"] == 5

    refute_receive {:fleet_command, _, _, _, "invalid", _}
  end

  test "unknown remote session identities fail closed before a fleet command is created", %{
    client: client
  } do
    assert Client.get_session(client, "missing-session") ==
             {:error, {:coop_session_not_found, "missing-session"}}

    assert Client.get_turn(client, "missing-session", "missing-turn") ==
             {:error, {:coop_session_not_found, "missing-session"}}

    assert Client.create_session(client, "missing-create", @policy, "missing-task", nil) ==
             {:error, {:coop_session_not_found, "missing-task"}}

    assert Client.operation_by_key(client, "missing-operation") == :not_found
    refute_receive {:fleet_command, _, _, _, _, _}
  end

  test "an unbound remote session resolves through its successful durable create", %{
    client: client,
    session: session
  } do
    remote_session_id = "remote:created-before-bind"

    command =
      command!(session, "created-before-bind",
        kind: "create_session",
        payload: create_payload(session, session.external_ref),
        key: "ryker:work:create:#{session.id}:g1"
      )

    complete_command!(command, :succeeded, %{
      "operation" => %{
        "id" => "operation-created-before-bind",
        "method" => "CreateRemoteSession",
        "state" => "running"
      }
    })

    reconciliation =
      command!(session, "reconcile-created-before-bind",
        kind: "reconcile_operation",
        payload: %{"operation_key" => command.idempotency_key}
      )

    complete_command!(reconciliation, :succeeded, %{
      "id" => "operation-created-before-bind",
      "method" => "CreateRemoteSession",
      "resource_id" => remote_session_id,
      "resource_type" => "session",
      "state" => "succeeded"
    })

    # Two stopped Slack runs could reconcile their successful creates, but could not fetch
    # and bind those sessions because the adapter only looked for an already-bound identity.
    assert {:ok, %{"id" => "remote-resource"}} = Client.get_session(client, remote_session_id)

    assert_receive {:fleet_command, ^session, "get_session",
                    %{"coop_session_id" => ^remote_session_id}, _read_key, _options}
  end

  test "binary transfer and authority mismatches fail closed at the fleet adapter", %{
    client: client,
    session: session
  } do
    Process.put(:coop_fleet_binary_result, {:ok, %{"unexpected" => "not a body receipt"}})

    assert Client.create_session(
             client,
             "wrong-create",
             "wrong-policy",
             session.external_ref,
             nil
           ) == {:error, {:coop_fleet_authority_mismatch, :policy}}

    assert Client.fence_create_session(
             client,
             "wrong-fence",
             "wrong-policy",
             session.external_ref,
             nil
           ) == {:error, {:coop_fleet_authority_mismatch, :policy}}

    session = bind_session!(session, "coop-session-transfers")

    assert Client.get_output_artifact(
             client,
             session.coop_session_id,
             "coop-turn",
             "artifact"
           ) == {:error, {:coop_protocol_error, :output_artifact_transfer}}

    assert_receive {:fleet_command, ^session, "get_output_artifact", _payload, _key, _options}

    artifacts = [%{"id" => "artifact"}]

    submission = %{
      "input_artifact_refs" => [],
      "output_schema" => %{"type" => "object"},
      "prompt" => "prompt"
    }

    assert Client.submit_frozen_turn(
             client,
             session.coop_session_id,
             "submit-artifact",
             1,
             submission,
             nil,
             artifacts
           ) == {:error, :coop_fleet_input_artifact_mismatch}

    assert Client.fence_frozen_turn(
             client,
             session.coop_session_id,
             "fence-artifact",
             1,
             submission,
             nil,
             artifacts
           ) == {:error, :coop_fleet_input_artifact_mismatch}

    refute_receive {:fleet_command, _, _, _, "wrong-create", _}
    refute_receive {:fleet_command, _, _, _, "wrong-fence", _}
  end

  test "operation reconciliation uses only the durable command result and owning session", %{
    client: client,
    session: session
  } do
    queued = command!(session, "queued")

    assert Client.operation_by_key(client, queued.idempotency_key) ==
             {:error, :unexpected_command_wait}

    wrapped = command!(session, "wrapped")

    wrapped =
      complete_command!(wrapped, :succeeded, %{
        "operation" => %{"id" => "operation-wrapped", "state" => "succeeded"}
      })

    assert {:ok, %{"id" => "operation-wrapped"}} =
             Client.operation_by_key(client, wrapped.idempotency_key)

    running = command!(session, "running")

    running =
      complete_command!(running, :succeeded, %{
        "operation" => %{
          "id" => "operation-running",
          "method" => "CreateRemoteSession",
          "state" => "running"
        }
      })

    terminal_operation = %{
      "id" => "operation-running",
      "method" => "CreateRemoteSession",
      "resource_id" => "remote-session",
      "resource_type" => "session",
      "state" => "succeeded"
    }

    Process.put(:coop_fleet_reconcile_result, %{"operation" => terminal_operation})

    # The live connector returned one successful command receipt containing a
    # still-running create operation, which otherwise never advanced to its session.
    assert {:ok, ^terminal_operation} = Client.operation_by_key(client, running.idempotency_key)

    assert_receive {:fleet_command, ^session, "reconcile_operation", running_payload, _key,
                    _options}

    assert running_payload == %{"operation_key" => running.idempotency_key}

    Process.delete(:coop_fleet_reconcile_result)

    direct = command!(session, "direct")
    direct = complete_command!(direct, :succeeded, %{"id" => "operation-direct"})

    assert {:ok, %{"id" => "operation-direct"}} =
             Client.operation_by_key(client, direct.idempotency_key)

    reconcile = command!(session, "reconcile")
    reconcile = complete_command!(reconcile, :failed, nil)

    assert {:ok, %{"id" => "remote-resource"}} =
             Client.operation_by_key(client, reconcile.idempotency_key)

    assert_receive {:fleet_command, ^session, "reconcile_operation", payload, _key, _options}
    assert payload == %{"operation_key" => reconcile.idempotency_key}
  end

  test "asynchronous writable session creation binds its approved task before reconciliation completes",
       %{
         client: client,
         session: session
       } do
    workspace_task = %{
      "authority_limits" => ["must not deploy"],
      "instruction_ref" => "input:trusted:async",
      "offer_ref" => "record:task_offer:async-workspace-binding",
      "prompt" => "Change the runner version and preserve idempotency.",
      "source_refs" => ["artifact:incident:async"],
      "success_checks" => ["focused tests pass"],
      "title" => "Bump the hosted runner"
    }

    session =
      session
      |> Session.Changeset.bind_workspace_task(workspace_task)
      |> Repo.update!()

    key = "ryker:work:create:#{session.id}:g1"

    create =
      command!(session, "async-workspace-binding",
        kind: "create_session",
        payload: create_payload(session, workspace_task["offer_ref"]),
        key: key
      )

    complete_command!(create, :succeeded, %{
      "operation" => %{
        "id" => "operation-async-workspace-binding",
        "method" => "CreateRemoteSession",
        "state" => "running"
      }
    })

    terminal_operation = %{
      "id" => "operation-async-workspace-binding",
      "method" => "CreateRemoteSession",
      "resource_id" => "remote-async-workspace-binding",
      "resource_type" => "session",
      "state" => "succeeded"
    }

    Process.put(:coop_fleet_reconcile_result, %{"operation" => terminal_operation})

    Process.put(:coop_fleet_get_session_result, %{
      "id" => "remote-async-workspace-binding",
      "revision" => 1,
      "state" => "open"
    })

    # Covers: TestAsynchronousWritableSessionBindsApprovedTask
    # Three live repair attempts sent a valid task offer, then failed before model work
    # because asynchronous session creation never bound that task to the workspace.
    assert {:ok, ^terminal_operation} = Client.operation_by_key(client, key)

    assert_receive {:fleet_command, ^session, "reconcile_operation", %{"operation_key" => ^key},
                    _reconcile_key, _options}

    assert_receive {:fleet_command, ^session, "get_session",
                    %{"coop_session_id" => "remote-async-workspace-binding"}, _get_key, _options}

    assert_receive {:fleet_command, ^session, "ensure_workspace", payload, ensure_key, _options}

    assert payload == %{
             "coop_session_id" => "remote-async-workspace-binding",
             "expected_revision" => 1,
             "task" => workspace_task
           }

    assert String.starts_with?(ensure_key, "ryker:workspace:")
  end

  test "an uncertain writable session creation binds its approved task when reconciliation succeeds",
       %{
         client: client,
         session: session
       } do
    workspace_task = %{
      "authority_limits" => ["must not deploy"],
      "offer_ref" => "record:task_offer:uncertain-workspace-binding",
      "prompt" => "Change the runner version and preserve idempotency.",
      "source_refs" => [],
      "success_checks" => ["focused tests pass"],
      "title" => "Recover the hosted runner task"
    }

    session =
      session
      |> Session.Changeset.bind_workspace_task(workspace_task)
      |> Repo.update!()

    key = "ryker:work:create:#{session.id}:g1"

    create =
      command!(session, "uncertain-workspace-binding",
        kind: "create_session",
        payload: create_payload(session, workspace_task["offer_ref"]),
        key: key
      )

    complete_command!(create, :uncertain, nil)

    terminal_operation = %{
      "id" => "operation-uncertain-workspace-binding",
      "method" => "CreateRemoteSession",
      "resource_id" => "remote-uncertain-workspace-binding",
      "resource_type" => "session",
      "state" => "succeeded"
    }

    Process.put(:coop_fleet_reconcile_result, %{"operation" => terminal_operation})

    Process.put(:coop_fleet_get_session_result, %{
      "id" => "remote-uncertain-workspace-binding",
      "revision" => 1,
      "state" => "open"
    })

    assert {:ok, ^terminal_operation} = Client.operation_by_key(client, key)

    assert_receive {:fleet_command, ^session, "reconcile_operation", %{"operation_key" => ^key},
                    _reconcile_key, _options}

    assert_receive {:fleet_command, ^session, "get_session",
                    %{"coop_session_id" => "remote-uncertain-workspace-binding"}, _get_key,
                    _options}

    assert_receive {:fleet_command, ^session, "ensure_workspace", payload, _ensure_key, _options}
    assert payload["task"] == workspace_task
  end

  test "a create fence reuses its durable command instead of colliding with that command", %{
    client: client,
    session: session
  } do
    key = "ryker:work:create:#{session.id}:g1"

    command =
      command!(session, "create-fence",
        kind: "create_session",
        payload: create_payload(session, session.external_ref),
        key: key
      )

    command =
      complete_command!(command, :succeeded, %{
        "operation" => %{
          "id" => "operation-create-fence",
          "method" => "CreateRemoteSession",
          "state" => "running"
        }
      })

    terminal_operation = %{
      "id" => "operation-create-fence",
      "method" => "CreateRemoteSession",
      "resource_id" => "remote-create-fence",
      "resource_type" => "session",
      "state" => "succeeded"
    }

    Process.put(:coop_fleet_reconcile_result, %{"operation" => terminal_operation})

    # Five Slack inputs stopped in one incident because cancellation tried to enqueue a
    # second command under this already-succeeded create key and hit an idempotency conflict.
    assert {:ok, ^terminal_operation} =
             Client.fence_create_session(
               client,
               key,
               @policy,
               session.external_ref,
               session.repository_source
             )

    assert_receive {:fleet_command, ^session, "reconcile_operation", %{"operation_key" => ^key},
                    read_key, _options}

    assert String.starts_with?(read_key, "ryker:fleet:read:reconcile_operation:")
    refute_receive {:fleet_command, _, "fence_operation", _, ^key, _}
    assert command.idempotency_key == key
  end

  test "a create fence settles from durable task receipts after its placement expires", %{
    client: client,
    session: session
  } do
    workspace_task = %{
      "authority_limits" => ["runner version only"],
      "offer_ref" => "record:task_offer:expired-create-receipts",
      "prompt" => "Bump the internal hosted runner version.",
      "source_refs" => [],
      "success_checks" => ["focused checks pass"],
      "title" => "Bump hosted runner"
    }

    session =
      session
      |> Session.Changeset.bind_workspace_task(workspace_task)
      |> Repo.update!()

    key = "ryker:work:create:#{session.id}:g1"

    create =
      command!(session, "expired-create-receipts",
        kind: "create_session",
        payload: create_payload(session, workspace_task["offer_ref"]),
        key: key
      )

    complete_command!(create, :succeeded, %{
      "operation" => %{
        "id" => "operation-expired-create-receipts",
        "method" => "CreateRemoteSession",
        "state" => "running"
      }
    })

    remote_session_id = "remote-expired-create-receipts"

    terminal_operation = %{
      "id" => "operation-expired-create-receipts",
      "method" => "CreateRemoteSession",
      "resource_id" => remote_session_id,
      "resource_type" => "session",
      "state" => "succeeded"
    }

    reconciliation =
      command!(session, "expired-create-reconciliation",
        kind: "reconcile_operation",
        payload: %{"operation_key" => key}
      )

    complete_command!(reconciliation, :succeeded, terminal_operation)

    bound_task = %{
      "draft_sha256" => String.duplicate("a", 64),
      "id" => "ryker-expired-create-receipts",
      "offer_ref" => workspace_task["offer_ref"],
      "queue_id" => String.duplicate("b", 32),
      "task_id" => String.duplicate("c", 32)
    }

    workspace =
      command!(session, "expired-create-workspace",
        kind: "ensure_workspace",
        payload: %{
          "coop_session_id" => remote_session_id,
          "expected_revision" => 1,
          "task" => workspace_task
        }
      )

    complete_command!(workspace, :succeeded, %{
      "session" => %{
        "id" => remote_session_id,
        "revision" => 2,
        "state" => "open",
        "workspace_task" => %{bound_task | "offer_ref" => "record:task_offer:unrelated"}
      }
    })

    create.placement_id
    |> then(&Repo.get!(Placement, &1))
    |> Ecto.Changeset.change(
      lease_expires_at: DateTime.add(Repo.now!(), -1, :second),
      state: :replaced
    )
    |> Repo.update!()

    assert {:error, {:coop_session_replacement_required, session_id, 1}} =
             Client.fence_create_session(
               client,
               key,
               @policy,
               workspace_task["offer_ref"],
               session.repository_source
             )

    assert session_id == session.id
    refute_receive {:fleet_command, _, _, _, _, _}

    complete_command!(workspace, :succeeded, %{
      "session" => %{
        "id" => remote_session_id,
        "revision" => 2,
        "state" => "open",
        "workspace_task" => bound_task
      }
    })

    # The repaired live task had both successful receipts, but cancellation kept trying to
    # contact the expired placement instead of settling from those immutable results.
    assert {:ok, ^terminal_operation} =
             Client.fence_create_session(
               client,
               key,
               @policy,
               workspace_task["offer_ref"],
               session.repository_source
             )

    refute_receive {:fleet_command, _, _, _, _, _}

    # Cancellation binds the asynchronous remote ID locally from this same proof. It must not
    # ask the expired worker for a document the successful workspace receipt already contains.
    assert {:ok,
            %{
              "id" => ^remote_session_id,
              "workspace_task" => %{"offer_ref" => "record:task_offer:expired-create-receipts"}
            }} = Client.get_session(client, remote_session_id)

    refute_receive {:fleet_command, _, _, _, _, _}
  end

  test "a worker-local submit rejection settles from its durable receipt", %{
    client: client,
    session: session
  } do
    session = bind_session!(session, "remote:worker-local-rejection")
    key = "ryker:work:turn:worker-local-rejection:g1"

    submission = %{
      "contract_version" => "work-final-live-v3",
      "context" => %{"source" => "https://example.test/?first=1&second=2"},
      "input_artifact_refs" => [],
      "output_schema" => %{"type" => "object"},
      "prompt" => "Use the exact frozen input."
    }

    command =
      command!(session, "worker-local-rejection",
        kind: "submit_turn",
        payload: %{
          "coop_session_id" => session.coop_session_id,
          "expected_revision" => 1,
          "submission" => submission,
          "submission_sha256" => CanonicalJSON.worker_digest(submission),
          "turn_ref" => "logical-turn"
        },
        key: key
      )

    complete_command!(command, :failed, nil, %{
      "code" => "invalid_command",
      "detail" => "frozen submission digest does not match"
    })

    # Two live runs reached cancellation after the connector rejected their ampersand-bearing
    # Slack envelopes before calling Coop, then retried a nonexistent remote operation forever.
    assert {:ok,
            %{
              "error_code" => "invalid_command",
              "method" => "SubmitTurn",
              "state" => "failed"
            }} =
             Client.fence_frozen_turn(
               client,
               session.coop_session_id,
               key,
               1,
               submission,
               nil,
               []
             )

    refute_receive {:fleet_command, _, "reconcile_operation", _, _, _}
    refute_receive {:fleet_command, _, "fence_operation", _, _, _}
  end

  # The worker gave the session up: its placement was replaced and its lease
  # ran out a minute ago.
  defp replaced_placement!(placement_id) do
    Placement
    |> Repo.get!(placement_id)
    |> Ecto.Changeset.change(state: :replaced, lease_expires_at: DateTime.add(Repo.now!(), -60))
    |> Repo.update!()
  end

  defp session! do
    episode_id = Ecto.UUID.generate()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "fleet:client:#{episode_id}",
                 native_input_id: "source:fleet-client:#{episode_id}",
                 occurred_at: Repo.now!(),
                 turn_ref: "turn:fleet-client:#{episode_id}"
               })
             )

    assert {:ok, session} =
             WorkSessions.pin_episode(episode_id, @policy, @policy_digest,
               authority_digest: @authority_digest,
               repository_ref: "ryker"
             )

    pin_job!(session)
  end

  defp pin_job!(session) do
    job = %{
      "version" => 2,
      "job_ref" => session.external_ref,
      "source" => %{
        "repository_ref" => "ryker",
        "github_repository" => "example/repository",
        "github_repository_id" => 17,
        "binding" => %{
          "version" => 1,
          "kind" => "default",
          "requested" => %{"kind" => "default"},
          "remote_identity" => "origin",
          "default_ref" => "refs/heads/main",
          "default_commit" => String.duplicate("a", 40),
          "selected_ref" => "refs/heads/main",
          "selected_commit" => String.duplicate("a", 40),
          "base_commit" => String.duplicate("a", 40),
          "admitted_tree" => String.duplicate("c", 40),
          "resolved_at" => "2026-09-26T12:00:00Z"
        },
        "submodules" => []
      },
      "companions" => [],
      "targets" => ["codex"],
      "mode" => "normal",
      "environment" => %{},
      "check" => %{"argv" => [], "environment" => %{}},
      "resources" => %{"cpu_millis" => 4_000, "memory_bytes" => 8_589_934_592, "pids" => 4_096},
      "repository_read_only" => false,
      "egress" => %{"mode" => "none", "rules" => [], "export_destinations" => false},
      "limits" => %{
        "max_turns" => 100,
        "max_queued_turns" => 20,
        "max_queued_bytes" => 1_048_576,
        "turn_timeout_ms" => 3_600_000,
        "warm_idle_timeout_ms" => 0,
        "max_patch_bytes" => 1_048_576
      }
    }

    source = session.repository_source || %{"kind" => "default"}
    job = put_in(job, ["source", "binding", "requested"], source)
    job = put_in(job, ["source", "binding", "kind"], source["kind"])

    job =
      if source["kind"] == "branch",
        do: put_in(job, ["source", "binding", "selected_ref"], "refs/heads/" <> source["name"]),
        else: job

    {:ok, digest} = JobSpec.digest(job)

    session
    |> Ecto.Changeset.change(worker_job_document: job, worker_job_digest: digest)
    |> Repo.update!()
  end

  defp create_payload(session, task \\ nil) do
    %{
      "external_ref" => task || session.external_ref,
      "job" => session.worker_job_document,
      "job_digest" => session.worker_job_digest
    }
  end

  defp completed_review_fixture do
    Path.join(__DIR__, "fixtures/completed_review_after_timeout.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp uncertain_review!(session, suffix) do
    error = {:error, {:coop_unavailable, "worker review request timed out"}}
    Process.put(:coop_fleet_run_review_result, error)

    session
    |> command!(suffix,
      kind: "run_review",
      payload: %{"coop_session_id" => session.coop_session_id, "expected_revision" => 3}
    )
    |> complete_command!(:uncertain, nil, %{
      "code" => "transport_uncertain",
      "detail" => "worker review request timed out"
    })
  end

  defp lapsed_review!(session, suffix) do
    review =
      session
      |> command!(suffix,
        kind: "run_review",
        payload: %{"coop_session_id" => session.coop_session_id, "expected_revision" => 3}
      )
      |> complete_command!(:succeeded, %{"id" => "review-op"})

    replaced_placement!(review.placement_id)

    review
  end

  defp publication_body do
    %{
      "authorization_ref" => "approval:one",
      "candidate_head" => String.duplicate("6", 40),
      "candidate_tree" => String.duplicate("7", 40),
      "branch" => "ryker/change",
      "base_branch" => "main",
      "expected_head" => "",
      "pull_request_number" => 0,
      "title" => "Change",
      "body" => "Reviewed work"
    }
  end

  defp publication_response(session) do
    %{
      "operation" => %{
        "id" => "publish-op",
        "method" => "PublishReview",
        "state" => "succeeded",
        "resource_type" => "publication",
        "resource_id" => session.coop_session_id
      },
      "publication" => %{
        "status" => "published",
        "receipt" => %{
          "repository" => session.repository_ref,
          "branch_ref" => "refs/heads/ryker/change",
          "candidate_tree" => String.duplicate("7", 40),
          "commit_sha" => String.duplicate("6", 40),
          "pull_request_number" => 7,
          "pull_request_url" => "https://github.com/example/repository/pull/7"
        }
      }
    }
  end

  defp bind_session!(session, coop_session_id) do
    session
    |> Ecto.Changeset.change(coop_session_id: coop_session_id)
    |> Ryker.Repo.update!()
  end

  defp command!(session, suffix, options \\ []) do
    worker_id = "client-worker-#{suffix}-#{Ecto.UUID.generate()}"
    certificate_sha256 = digest(worker_id)

    assert {:ok, _worker} =
             CoopWorkers.authorize(worker_id, "workspace-main", certificate_sha256)

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(worker_id, poll(worker_id, suffix))

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["controller-tools"],
                 repository_ref: session.repository_ref,
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert {:ok, command} =
             ControlPlane.enqueue_command(
               placement.id,
               Keyword.get(options, :kind, "get_session"),
               Keyword.get(options, :payload, %{"coop_session_id" => "remote:#{suffix}"}),
               Keyword.get(options, :key, "client:operation:#{suffix}:#{Ecto.UUID.generate()}")
             )

    command
  end

  defp complete_command!(command, status, result, command_error \\ nil) do
    error =
      if status == :succeeded,
        do: nil,
        else: command_error || %{"code" => "worker_failed", "detail" => "failed", "status" => 503}

    command
    |> Ecto.Changeset.change(
      completed_at: Repo.now!(),
      error: error,
      operation_key: command.idempotency_key,
      result: if(status == :succeeded, do: %{"status" => 200, "body" => result}, else: result),
      result_fingerprint: String.duplicate("d", 64),
      status: status
    )
    |> Repo.update!()
  end

  defp poll(worker_id, suffix, freshness_v2? \\ false) do
    capabilities =
      [%{"name" => "controller-tools", "version" => "1"}] ++
        if(freshness_v2?,
          do: [%{"name" => "repository-freshness", "version" => "2"}],
          else: []
        )

    %{
      "acknowledged_command_ids" => [],
      "command_results" => [],
      "event_batches" => [],
      "poll_ref" => "poll:#{worker_id}:#{suffix}",
      "version" => 2,
      "worker" => %{
        "build_version" => "coop-test",
        "capabilities" => capabilities,
        "capacity" => %{
          "cooldown_until" => nil,
          "session_slots_free" => 2,
          "session_slots_total" => 2,
          "state" => "eligible",
          "turn_slots_free" => 2,
          "turn_slots_total" => 2,
          "workspace_slots_free" => 2,
          "workspace_slots_total" => 2
        },
        "clock_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "id" => worker_id,
        "protocol_version" => "2",
        "sandbox_digest" => String.duplicate("a", 64),
        "state" => "eligible",
        "workspace_ref" => "workspace-main"
      }
    }
  end
end
