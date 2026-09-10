defmodule Responder.CoopFleet.ClientTest do
  use Responder.DataCase, async: true

  alias Responder.{Artifacts, CanonicalJSON}
  alias Responder.CoopFleet.{Client, ControlPlane, Placement, WorkspaceCheckpointTransfer}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Fixtures.WorkspaceCheckpoint, as: WorkspaceCheckpointFixture
  alias Responder.Repo
  alias Responder.Work.{Custody, SessionChangeset, StateBinding}

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
          {:ok, %{"id" => "remote-resource", "revision" => 1, "state" => "open"}}

        "ensure_workspace" ->
          {:ok, %{"id" => "remote-resource", "revision" => 2, "state" => "open"}}

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

        _other ->
          {:ok, %{"id" => "remote-resource", "state" => "succeeded"}}
      end
    end

    def await_command(_command_id, _options),
      do: {:error, :unexpected_command_wait}
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
               capability_names: ["responder-state"],
               lease_seconds: 30,
               max_waits: 2,
               poll_interval_ms: 1,
               wait: fn -> :ok end,
               workspace_ref: "workspace-main"
             )

    %{client: client, session: session}
  end

  test "new requires one bounded workspace and rejects unknown or duplicate options" do
    assert {:error, {:invalid_coop_fleet_client, :options}} = Client.new([])

    assert {:error, {:invalid_coop_fleet_client, :options}} =
             Client.new(workspace_ref: "workspace-main", workspace_ref: "other")

    assert {:error, {:invalid_coop_fleet_client, :options}} =
             Client.new(workspace_ref: "workspace-main", secret: "must-not-cross")

    assert {:error, {:invalid_coop_fleet_client, :options}} =
             Client.new(workspace_ref: String.duplicate("w", 1_025))
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

  test "create session carries the admission-pinned authority and no worker-selected policy", %{
    client: client,
    session: session
  } do
    key = "responder:work:create:#{session.id}:g1"

    assert {:ok, %{"id" => "remote-resource"}} =
             Client.create_session(client, key, @policy, session.external_ref)

    assert_receive {:fleet_command, ^session, "create_session", payload, ^key, options}

    assert payload == %{
             "authority_digest" => @authority_digest,
             "external_ref" => session.external_ref,
             "policy" => @policy,
             "policy_digest" => @policy_digest
           }

    assert Keyword.fetch!(options, :workspace_ref) == "workspace-main"
    assert Keyword.fetch!(options, :capability_names) == ["responder-state"]

    assert {:error, {:coop_fleet_authority_mismatch, :policy}} =
             Client.create_session(client, key, "write-everywhere", session.external_ref)

    refute_receive {:fleet_command, _, _, _, _, _}
  end

  test "bound create carries the exact private state-tools binding", %{
    client: client,
    session: session
  } do
    key = "responder:work:create:#{session.id}:g1"

    binding = %{
      "endpoint" => "https://responder.example/v1/state-tools/mcp",
      "token" => String.duplicate("a", 64) <> String.duplicate("t", 43)
    }

    assert {:ok, %{"id" => "remote-resource"}} =
             Client.create_bound_session(client, key, @policy, session.external_ref, binding)

    assert_receive {:fleet_command, ^session, "create_session", payload, ^key, _options}

    assert payload["responder_binding"] == %{
             "endpoint" => binding["endpoint"],
             "token_sha256" => StateBinding.sha256(binding["token"])
           }

    refute inspect(payload) =~ binding["token"]

    assert Map.drop(payload, ["responder_binding"]) == %{
             "authority_digest" => @authority_digest,
             "external_ref" => session.external_ref,
             "policy" => @policy,
             "policy_digest" => @policy_digest
           }
  end

  test "freshness capability follows the exact session placement during a rolling upgrade", %{
    client: client,
    session: session
  } do
    command = command!(session, "freshness-capability")

    upgraded_worker_id = "client-worker-upgraded-#{Ecto.UUID.generate()}"
    certificate_sha256 = :crypto.hash(:sha256, upgraded_worker_id) |> Base.encode16(case: :lower)

    assert {:ok, _worker} =
             ControlPlane.authorize_worker(
               upgraded_worker_id,
               "workspace-main",
               certificate_sha256
             )

    assert {:ok, _response} =
             ControlPlane.handle_poll(
               upgraded_worker_id,
               poll(upgraded_worker_id, "upgraded-unplaced", true)
             )

    assert {:ok, %{"repository_freshness_receipt_versions" => []}} =
             Client.capabilities(client, session)

    assert {:ok, _response} =
             ControlPlane.handle_poll(
               command.worker_id,
               poll(command.worker_id, "upgraded-placed", true)
             )

    assert {:ok, %{"repository_freshness_receipt_versions" => [2]}} =
             Client.capabilities(client, session)

    command.placement_id
    |> then(&Repo.get!(Placement, &1))
    |> Ecto.Changeset.change(lease_expires_at: DateTime.add(database_now!(), -1, :second))
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
      |> SessionChangeset.bind_workspace_task(workspace_task)
      |> Repo.update!()

    key = "responder:work:create:#{session.id}:g1"

    assert {:ok, %{"id" => "remote-resource", "revision" => 2}} =
             Client.create_session(client, key, @policy, workspace_task["offer_ref"])

    assert_receive {:fleet_command, ^session, "create_session", create_payload, ^key, _}

    assert create_payload["external_ref"] == workspace_task["offer_ref"]

    assert_receive {:fleet_command, ^session, "ensure_workspace", payload, ensure_key, _}

    assert payload == %{
             "coop_session_id" => "remote-resource",
             "expected_revision" => 1,
             "task" => workspace_task
           }

    assert ensure_key =~ "responder:workspace:"
  end

  test "an accepted engineering milestone requests one exact durable checkpoint", %{
    client: client,
    session: session
  } do
    session = bind_session!(session, "coop-session-checkpoint")

    assert {:ok, %{"transfer_id" => "018f04f4-5555-7000-8000-000000000001"}} =
             Client.checkpoint_workspace(client, session.coop_session_id, "checkpoint-key-1", 4)

    assert_receive {:fleet_command, ^session, "checkpoint_workspace", payload, "checkpoint-key-1",
                    _options}

    assert payload == %{
             "coop_session_id" => session.coop_session_id,
             "expected_revision" => 4,
             "repository_ref" => "responder",
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
      |> SessionChangeset.bind_workspace_task(workspace_task)
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
          "repository_ref" => "responder",
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
      repository_ref: "responder",
      descriptor: checkpoint,
      bundle_sha256: checkpoint["bundle"]["sha256"],
      bundle_byte_size: byte_size(bundle),
      encryption_key_sha256: String.duplicate("a", 64),
      encryption_nonce: :binary.copy(<<1>>, 12),
      encryption_tag: :binary.copy(<<2>>, 16),
      ciphertext: :binary.copy(<<3>>, byte_size(bundle))
    }
    |> Repo.insert!()

    replacement =
      SessionChangeset.insert_with_authority(
        Ecto.UUID.generate(),
        source.episode_id,
        2,
        source.policy,
        source.policy_digest,
        source.repository_ref,
        source.external_ref,
        %{authority_digest: source.authority_digest, workspace_task: nil}
      )
      |> Repo.insert!()
      |> SessionChangeset.bind_workspace_task(workspace_task)
      |> Repo.update!()

    key = "responder:work:create:#{replacement.id}:g1"

    assert {:ok, %{"id" => "remote-resource", "revision" => 2}} =
             Client.create_session(client, key, @policy, workspace_task["offer_ref"])

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
      |> SessionChangeset.bind_workspace_task(workspace_task)
      |> Ecto.Changeset.change(coop_session_id: "coop-session-never-task-bound")
      |> Repo.update!()

    replacement =
      SessionChangeset.insert_with_authority(
        Ecto.UUID.generate(),
        source.episode_id,
        2,
        source.policy,
        source.policy_digest,
        source.repository_ref,
        source.external_ref,
        %{authority_digest: source.authority_digest, workspace_task: nil}
      )
      |> Repo.insert!()
      |> SessionChangeset.bind_workspace_task(workspace_task)
      |> Repo.update!()

    key = "responder:work:create:#{replacement.id}:g1"

    # Covers: TestUnboundTaskReplacementStartsClean
    # The third live retry had a remote session ID but never acquired a writable workspace;
    # requiring a nonexistent checkpoint would strand the repaired task again.
    assert {:ok, %{"id" => "remote-resource", "revision" => 2}} =
             Client.create_session(client, key, @policy, workspace_task["offer_ref"])

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
      |> SessionChangeset.bind_workspace_task(workspace_task)
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
      SessionChangeset.insert_with_authority(
        Ecto.UUID.generate(),
        source.episode_id,
        2,
        source.policy,
        source.policy_digest,
        source.repository_ref,
        source.external_ref,
        %{authority_digest: source.authority_digest, workspace_task: nil}
      )
      |> Repo.insert!()
      |> SessionChangeset.bind_workspace_task(workspace_task)
      |> Repo.update!()

    key = "responder:work:create:#{replacement.id}:g1"

    # The production session was task-bound but closed with turns_used=0. With no submit
    # command, there is no model-authored workspace state to checkpoint into the replacement.
    assert {:ok, %{"id" => "remote-resource", "revision" => 2}} =
             Client.create_session(client, key, @policy, workspace_task["offer_ref"])

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
      |> SessionChangeset.bind_workspace_task(workspace_task)
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
      SessionChangeset.insert_with_authority(
        Ecto.UUID.generate(),
        source.episode_id,
        2,
        source.policy,
        source.policy_digest,
        source.repository_ref,
        source.external_ref,
        %{authority_digest: source.authority_digest, workspace_task: nil}
      )
      |> Repo.insert!()
      |> SessionChangeset.bind_workspace_task(workspace_task)
      |> Repo.update!()

    key = "responder:work:create:#{replacement.id}:g1"

    assert {:error, {:coop_protocol_error, :create_session_response}} =
             Client.create_session(client, key, @policy, workspace_task["offer_ref"])

    refute_receive {:fleet_command, ^replacement, "ensure_workspace", _, _, _}
  end

  test "frozen submit preserves exact persisted prompt schema context and digest", %{
    client: client,
    session: session
  } do
    session = bind_session!(session, "coop-session-1")

    submission = %{
      "contract_version" => "work-final-v1",
      "context" => %{"turn_ref" => "turn-7", "input_refs" => ["input-1"]},
      "input_artifact_refs" => [],
      "output_schema" => %{"type" => "object"},
      "prompt" => "exact & <frozen> prompt"
    }

    key = "responder:work:submit:turn-7:g1"

    binding = %{
      "endpoint" => "https://responder.example/v1/state-tools/mcp",
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
             "responder_binding" => %{
               "endpoint" => binding["endpoint"],
               "token_sha256" => StateBinding.sha256(binding["token"])
             },
             "submission" => submission,
             "submission_sha256" =>
               "7b136cbd9b50c9ef8ab2b210cd686990281da74a8329586dcd577284870bb4d2",
             "turn_ref" => "turn-7"
           }
  end

  test "semantic validation carries the exact candidate attempt and frozen verdict", %{
    client: client,
    session: session
  } do
    session = bind_session!(session, "coop-session-2")
    sha256 = String.duplicate("c", 64)
    key = "responder:work:validate:turn-8:a3:#{sha256}:reject:g1"

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
      "contract_version" => "work-final-v1",
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
    assert payload["submission_sha256"] == CanonicalJSON.digest(submission)
    refute inspect(payload) =~ data

    fence_command =
      command!(session, "fence-artifact",
        kind: "submit_turn",
        payload: %{
          "coop_session_id" => session.coop_session_id,
          "expected_revision" => 3,
          "submission" => submission,
          "submission_sha256" => CanonicalJSON.digest(submission),
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
    binding = %{
      "endpoint" => "https://responder.example/v1/state-tools/mcp",
      "token" => String.duplicate("a", 64) <> String.duplicate("t", 43)
    }

    # An audited incident retry exhausted into cancellation after placement rejected the create;
    # without a command row, the outbound-only fleet could prove that nothing reached Coop.
    assert {:ok,
            %{
              "error_code" => "operation_not_enqueued",
              "method" => "CreateRemoteSession",
              "state" => "failed"
            }} =
             Client.fence_create_session(client, "fence-create", @policy, session.external_ref)

    assert {:ok,
            %{
              "error_code" => "operation_not_enqueued",
              "method" => "CreateRemoteSession",
              "state" => "failed"
            }} =
             Client.fence_bound_session(
               client,
               "fence-bound-create",
               @policy,
               session.external_ref,
               binding
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
             Client.fence_submit_turn(
               client,
               session.coop_session_id,
               "fence-submit",
               3,
               "frozen prompt",
               schema
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

    assert {:error, {:invalid_coop_request, :verdict}} =
             Client.validate_candidate(
               client,
               session.coop_session_id,
               "coop-turn-1",
               "invalid",
               String.duplicate("b", 64),
               :maybe
             )

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
    assert {:error, {:coop_session_not_found, "missing-session"}} =
             Client.get_session(client, "missing-session")

    assert {:error, {:coop_session_not_found, "missing-session"}} =
             Client.get_turn(client, "missing-session", "missing-turn")

    assert {:error, {:coop_session_not_found, "missing-task"}} =
             Client.create_session(client, "missing-create", @policy, "missing-task")

    assert :not_found = Client.operation_by_key(client, "missing-operation")
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
        payload: %{
          "authority_digest" => @authority_digest,
          "external_ref" => session.external_ref,
          "policy" => @policy,
          "policy_digest" => @policy_digest
        },
        key: "responder:work:create:#{session.id}:g1"
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
    binding = %{
      "endpoint" => "https://responder.example/v1/state-tools/mcp",
      "token" => String.duplicate("a", 64) <> String.duplicate("t", 43)
    }

    assert {:error, {:coop_fleet_authority_mismatch, :policy}} =
             Client.create_bound_session(
               client,
               "wrong-create",
               "wrong-policy",
               session.external_ref,
               binding
             )

    assert {:error, {:coop_fleet_authority_mismatch, :policy}} =
             Client.fence_create_session(
               client,
               "wrong-fence",
               "wrong-policy",
               session.external_ref
             )

    assert {:error, {:coop_fleet_authority_mismatch, :policy}} =
             Client.fence_bound_session(
               client,
               "wrong-bound-fence",
               "wrong-policy",
               session.external_ref,
               binding
             )

    session = bind_session!(session, "coop-session-transfers")

    assert {:error, :coop_fleet_review_patch_session_required} =
             Client.get_review_patch(client, "artifact", String.duplicate("a", 64), 10)

    assert {:error, {:coop_protocol_error, :review_patch_transfer}} =
             Client.get_session_review_patch(
               client,
               session.coop_session_id,
               "artifact",
               String.duplicate("a", 64),
               10
             )

    assert_receive {:fleet_command, ^session, "get_review_patch", _payload, _key, _options}

    assert {:error, {:coop_protocol_error, :output_artifact_transfer}} =
             Client.get_output_artifact(
               client,
               session.coop_session_id,
               "coop-turn",
               "artifact"
             )

    assert_receive {:fleet_command, ^session, "get_output_artifact", _payload, _key, _options}

    artifacts = [%{"id" => "artifact"}]

    assert {:error, :coop_fleet_input_artifact_mismatch} =
             Client.submit_turn_with_artifacts(
               client,
               session.coop_session_id,
               "submit-artifact",
               1,
               "prompt",
               %{"type" => "object"},
               artifacts
             )

    assert {:error, :coop_fleet_input_artifact_mismatch} =
             Client.fence_submit_turn_with_artifacts(
               client,
               session.coop_session_id,
               "fence-artifact",
               1,
               "prompt",
               %{"type" => "object"},
               artifacts
             )

    refute_receive {:fleet_command, _, _, _, "wrong-create", _}
    refute_receive {:fleet_command, _, _, _, "wrong-fence", _}
    refute_receive {:fleet_command, _, _, _, "wrong-bound-fence", _}
  end

  test "operation reconciliation uses only the durable command result and owning session", %{
    client: client,
    session: session
  } do
    queued = command!(session, "queued")

    assert {:error, :unexpected_command_wait} =
             Client.operation_by_key(client, queued.idempotency_key)

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
      |> SessionChangeset.bind_workspace_task(workspace_task)
      |> Repo.update!()

    key = "responder:work:create:#{session.id}:g1"

    create =
      command!(session, "async-workspace-binding",
        kind: "create_session",
        payload: %{
          "authority_digest" => @authority_digest,
          "external_ref" => workspace_task["offer_ref"],
          "policy" => @policy,
          "policy_digest" => @policy_digest
        },
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

    assert String.starts_with?(ensure_key, "responder:workspace:")
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
      |> SessionChangeset.bind_workspace_task(workspace_task)
      |> Repo.update!()

    key = "responder:work:create:#{session.id}:g1"

    create =
      command!(session, "uncertain-workspace-binding",
        kind: "create_session",
        payload: %{
          "authority_digest" => @authority_digest,
          "external_ref" => workspace_task["offer_ref"],
          "policy" => @policy,
          "policy_digest" => @policy_digest
        },
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
    key = "responder:work:create:#{session.id}:g1"

    command =
      command!(session, "create-fence",
        kind: "create_session",
        payload: %{
          "authority_digest" => @authority_digest,
          "external_ref" => session.external_ref,
          "policy" => @policy,
          "policy_digest" => @policy_digest
        },
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
             Client.fence_create_session(client, key, @policy, session.external_ref)

    assert_receive {:fleet_command, ^session, "reconcile_operation", %{"operation_key" => ^key},
                    read_key, _options}

    assert String.starts_with?(read_key, "responder:fleet:read:reconcile_operation:")
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
      |> SessionChangeset.bind_workspace_task(workspace_task)
      |> Repo.update!()

    key = "responder:work:create:#{session.id}:g1"

    create =
      command!(session, "expired-create-receipts",
        kind: "create_session",
        payload: %{
          "authority_digest" => @authority_digest,
          "external_ref" => workspace_task["offer_ref"],
          "policy" => @policy,
          "policy_digest" => @policy_digest
        },
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
      "id" => "responder-expired-create-receipts",
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
      lease_expires_at: DateTime.add(database_now!(), -1, :second),
      state: :replaced
    )
    |> Repo.update!()

    assert {:error, {:coop_session_replacement_required, session_id, 1}} =
             Client.fence_create_session(client, key, @policy, workspace_task["offer_ref"])

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
             Client.fence_create_session(client, key, @policy, workspace_task["offer_ref"])

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
    key = "responder:work:turn:worker-local-rejection:g1"

    submission = %{
      "contract_version" => "work-final-v1",
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
          "submission_sha256" => CanonicalJSON.digest(submission),
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

  defp session! do
    episode_id = Ecto.UUID.generate()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "fleet:client:#{episode_id}",
                 native_input_id: "source:fleet-client:#{episode_id}",
                 occurred_at: database_now!(),
                 turn_ref: "turn:fleet-client:#{episode_id}"
               })
             )

    assert {:ok, session} =
             Custody.pin_episode(
               episode_id,
               @policy,
               @policy_digest,
               @authority_digest,
               "responder"
             )

    session
  end

  defp bind_session!(session, coop_session_id) do
    session
    |> Ecto.Changeset.change(coop_session_id: coop_session_id)
    |> Responder.Repo.update!()
  end

  defp command!(session, suffix, options \\ []) do
    worker_id = "client-worker-#{suffix}-#{Ecto.UUID.generate()}"
    certificate_sha256 = :crypto.hash(:sha256, worker_id) |> Base.encode16(case: :lower)

    assert {:ok, _worker} =
             ControlPlane.authorize_worker(worker_id, "workspace-main", certificate_sha256)

    assert {:ok, _response} = ControlPlane.handle_poll(worker_id, poll(worker_id, suffix))

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["responder-state"],
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
      completed_at: database_now!(),
      error: error,
      operation_key: command.idempotency_key,
      result: result,
      result_fingerprint: String.duplicate("d", 64),
      status: status
    )
    |> Repo.update!()
  end

  defp poll(worker_id, suffix, freshness_v2? \\ false) do
    capabilities =
      [%{"name" => "responder-state", "version" => "1"}] ++
        if(freshness_v2?,
          do: [%{"name" => "repository-freshness", "version" => "2"}],
          else: []
        )

    %{
      "acknowledged_command_ids" => [],
      "command_results" => [],
      "event_batches" => [],
      "poll_ref" => "poll:#{worker_id}:#{suffix}",
      "version" => 1,
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
        "policy_authority_digests" => %{@policy => @authority_digest},
        "policy_digests" => %{@policy => @policy_digest},
        "protocol_version" => "1",
        "repositories" => [%{"ref" => "responder", "revision" => "commit:test"}],
        "sandbox_digest" => String.duplicate("a", 64),
        "state" => "eligible",
        "workspace_ref" => "workspace-main"
      }
    }
  end

  defp database_now! do
    %{rows: [[now]]} = Responder.Repo.query!("SELECT clock_timestamp()")
    now
  end
end
