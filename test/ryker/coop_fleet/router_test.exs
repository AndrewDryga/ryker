defmodule Ryker.CoopFleet.RouterTest do
  use Ryker.DataCase, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Ecto.Adapters.SQL.Sandbox

  alias Ryker.CoopFleet.{
    Bodies,
    Checkpoints,
    ControlPlane,
    Enrollment,
    JobSpec,
    Placement,
    Router,
    SourceGrants,
    WorkspaceCheckpointTransfer
  }

  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Fixtures.WorkspaceCheckpoint, as: WorkspaceCheckpointFixture
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Work.{Custody, Session, SessionChangeset, StateBinding}

  @policy_digest String.duplicate("b", 64)

  defmodule SourceGrantRequester do
    def request(test_pid, method, path, document, _headers) do
      send(test_pid, {:source_token_request, self(), method, path, document})

      receive do
        :complete_source_token ->
          {:ok,
           %{
             status: 201,
             body: %{
               "token" => "host-only-source-token",
               "expires_at" =>
                 DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()
             }
           }}

        {:complete_source_token, response} ->
          response
      after
        5_000 -> {:error, :test_mint_not_released}
      end
    end
  end

  test "generic bodies bind streaming custody to the current command before result acknowledgement" do
    key = Ryker.Secret.new(:binary.copy(<<7>>, 32))
    certificate = authorize_and_poll!()
    command = command!("api_request", %{"method" => "GET", "path" => "/v1/sessions/s/changes"})
    root = Path.join(System.tmp_dir!(), "coop-route-bodies-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(root) end)
    bytes = :binary.copy("test bytes", 40_000)

    reference = %{
      "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
      "byte_size" => byte_size(bytes)
    }

    result = %{
      "command_id" => command.id,
      "operation_key" => command.idempotency_key,
      "state" => "succeeded",
      "error" => nil,
      "resource" => %{"status" => 200, "body_ref" => reference}
    }

    completed =
      poll() |> Map.put("poll_ref", "poll:body-result") |> Map.put("command_results", [result])

    upload = fn id, hash ->
      :put
      |> conn("/v1/coop-workers/commands/#{id}/response-body", bytes)
      |> put_req_header("content-length", to_string(byte_size(bytes)))
      |> put_req_header("x-coop-body-sha256", hash)
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call(body_root: root, checkpoint_key: key)
    end

    assert upload.(Ecto.UUID.generate(), reference["sha256"]).status == 404
    assert upload.(command.id, String.duplicate("0", 64)).status == 400
    assert {:error, _} = Bodies.fetch(root, command.id, :response)
    assert upload.(command.id, reference["sha256"]).status == 200
    assert upload.(command.id, reference["sha256"]).status == 200
    assert {:ok, body, ^reference} = Bodies.fetch(root, command.id, :response)
    assert {:ok, ^bytes} = Bodies.read(body, key, byte_size(bytes))

    assert :ok = Bodies.put(root, command.id, :request, reference, [bytes], key)

    download =
      :get
      |> conn("/v1/coop-workers/commands/#{command.id}/request-body")
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call(body_root: root, checkpoint_key: key)

    assert download.status == 200
    assert download.resp_body == bytes

    assert {:ok, response} =
             ControlPlane.handle_poll_certificate(certificate, completed, body_root: root)

    assert response["acknowledged_result_command_ids"] == [command.id]
    assert upload.(command.id, reference["sha256"]).status == 404
  end

  test "a one-time token enrolls without mTLS and renewal requires the issued certificate" do
    authority = enrollment_authority()

    assert {:ok, issued_token} =
             Enrollment.issue_token("worker-enrolled", "workspace-main", "operator:andrew", 300)

    enrollment =
      :post
      |> conn(
        "/v1/coop-workers/enroll",
        Jason.encode!(%{
          "public_key_pem" => public_key_pem(),
          "token" => issued_token.token
        })
      )
      |> put_req_header("content-type", "application/json")
      |> Router.call(enrollment_authority: authority)

    assert enrollment.status == 201
    enrolled = Jason.decode!(enrollment.resp_body)
    certificate = certificate_der(enrolled["certificate_pem"])

    consumed =
      :post
      |> conn(
        "/v1/coop-workers/enroll",
        Jason.encode!(%{
          "public_key_pem" => public_key_pem(),
          "token" => issued_token.token
        })
      )
      |> put_req_header("content-type", "application/json")
      |> Router.call(enrollment_authority: authority)

    assert consumed.status == 401

    denied_renewal =
      :post
      |> conn(
        "/v1/coop-workers/renew",
        Jason.encode!(%{"public_key_pem" => public_key_pem()})
      )
      |> put_req_header("content-type", "application/json")
      |> Router.call(enrollment_authority: authority)

    assert denied_renewal.status == 401

    renewal =
      :post
      |> conn(
        "/v1/coop-workers/renew",
        Jason.encode!(%{"public_key_pem" => public_key_pem()})
      )
      |> put_req_header("content-type", "application/json")
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call(enrollment_authority: authority)

    assert renewal.status == 200
    renewed = Jason.decode!(renewal.resp_body)
    refute renewed["certificate_sha256"] == enrolled["certificate_sha256"]
  end

  test "the poll endpoint derives worker identity only from the verified client certificate" do
    certificate = "verified-client-certificate-der"
    fingerprint = :crypto.hash(:sha256, certificate) |> Base.encode16(case: :lower)

    assert {:ok, _worker} =
             ControlPlane.authorize_worker("worker-a", "workspace-main", fingerprint)

    conn =
      :post
      |> conn("/v1/coop-workers/poll", Jason.encode!(poll()))
      |> put_req_header("content-type", "application/json")
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call([])

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["poll_ref"] == "poll:worker-a:router"

    unauthenticated =
      :post
      |> conn("/v1/coop-workers/poll", Jason.encode!(poll()))
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert unauthenticated.status == 401
    refute unauthenticated.resp_body =~ "worker-a"
  end

  test "a rejected worker poll names its reason in the host log and nothing it carried" do
    # On 2026-09-18 the worker logged two HTTP 400s from this endpoint while
    # the fleet stalled, and Ryker logged nothing, so the only trace of why
    # was on the worker's side. The reason's codes are enough to act on; the
    # document itself carries session evidence and command results.
    certificate = authorize_and_poll!()

    skewed =
      poll()
      |> put_in(["worker", "clock_at"], "2020-01-01T00:00:00Z")
      |> put_in(["worker", "build_version"], "coop-build-sentinel")

    log =
      capture_log(fn ->
        conn =
          :post
          |> conn("/v1/coop-workers/poll", Jason.encode!(skewed))
          |> put_req_header("content-type", "application/json")
          |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
          |> Router.call([])

        assert conn.status == 400
        assert Jason.decode!(conn.resp_body) == %{"error" => %{"code" => "invalid_request"}}
      end)

    assert log =~ "coop worker poll rejected: coop_worker_clock_skew"
    refute log =~ "coop-build-sentinel"
  end

  test "the public state-tools route accepts only the exact leased turn binding" do
    session = session!()
    assert {:ok, claim} = Custody.claim_next("worker:state-tools", 60, :work)
    assert claim.session.id == session.id

    assert {:ok, binding} =
             StateBinding.derive(
               session,
               claim.turn,
               StateBinding.local_scope(session),
               "https://ryker.example/v1/state-tools/mcp",
               Ryker.Secret.new("controller-state-tools-secret")
             )

    assert {:ok, _turn} =
             Custody.bind_state_tools(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               binding.endpoint,
               binding.token_sha256
             )

    request =
      Jason.encode!(%{"id" => 1, "jsonrpc" => "2.0", "method" => "tools/list", "params" => %{}})

    options = [
      state_tools: %{
        additional_call: fn _tool, _arguments -> {:error, :not_available} end,
        additional_tools: [
          %{
            "description" => "Read one fabricated test value.",
            "inputSchema" => %{
              "additionalProperties" => false,
              "properties" => %{},
              "required" => [],
              "type" => "object"
            },
            "name" => "read_test_value"
          }
        ],
        capabilities: [:event_waits],
        emisar_rpc_url: nil
      }
    ]

    accepted =
      :post
      |> conn("/v1/state-tools/mcp", request)
      |> put_req_header("authorization", "Bearer " <> binding.token)
      |> put_req_header("content-type", "application/json")
      |> Router.call(options)

    assert accepted.status == 200
    assert get_in(Jason.decode!(accepted.resp_body), ["result", "tools"]) |> is_list()

    assert {:ok, _turn} =
             Custody.defer(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               1,
               "test",
               "lease released"
             )

    denied =
      :post
      |> conn("/v1/state-tools/mcp", request)
      |> put_req_header("authorization", "Bearer " <> binding.token)
      |> put_req_header("content-type", "application/json")
      |> Router.call(options)

    assert denied.status == 401
  end

  # tenantcorp/tenant-core vendors skypjack/entt, which no installation of the GitHub App
  # reaches (2026-10-03). Anyone may read a public repository, so its grant carries no
  # credential and the worker fetches it anonymously; it is granted only as a submodule.
  test "a public repository a job vendors as a submodule is granted without a credential" do
    certificate = authorize_and_poll!()
    session = session!()
    job_ref = session.external_ref
    {:ok, _snapshot} = Settings.initialize("control-plane:local")
    commit = String.duplicate("a", 40)

    public = %{
      "repository_ref" => "public:skypjack:entt",
      "github_repository" => "skypjack/entt",
      "github_repository_id" => 123_456
    }

    module =
      Map.merge(public, %{
        "path" => "lib/libentt",
        "commit" => commit,
        "tree" => String.duplicate("c", 40),
        "submodules" => []
      })

    job =
      job_ref
      |> WorkerJob.build(session.repository_ref || "repo:one")
      |> put_in(["source", "submodules"], [module])

    assert {:ok, digest} = JobSpec.digest(job)

    session
    |> Ecto.Changeset.change(worker_job_document: job, worker_job_digest: digest)
    |> Repo.update!()

    assert {:ok, _placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: [],
                 repository_ref: session.repository_ref,
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert {:ok, grant} = SourceGrants.source_grant(certificate, job_ref, public)
    assert grant["token"] == ""
    assert grant["public"] == true
    assert Map.take(grant, Map.keys(public)) == public
    assert {:ok, expires_at, 0} = DateTime.from_iso8601(grant["expires_at"])
    assert DateTime.compare(expires_at, DateTime.add(Repo.now!(), 60, :second)) == :gt

    # Not one the job vendors, and never as a source of its own.
    other = Map.put(public, "github_repository_id", 654_321)

    as_source =
      put_in(job, ["source"], Map.merge(job["source"], Map.put(public, "submodules", [])))

    assert {:error, :coop_worker_source_grant_not_authorized} =
             SourceGrants.source_grant(certificate, job_ref, other)

    {:ok, source_digest} = JobSpec.digest(as_source)

    Repo.get!(Session, session.id)
    |> Ecto.Changeset.change(worker_job_document: as_source, worker_job_digest: source_digest)
    |> Repo.update!()

    assert {:error, :coop_worker_source_grant_not_authorized} =
             SourceGrants.source_grant(certificate, job_ref, public)
  end

  test "only an actively leased job may request its exact GitHub source grant without a create command" do
    certificate = authorize_and_poll!()
    session = session!()
    task_ref = "offer:workspace-source"
    job_ref = session.external_ref
    refute job_ref == task_ref

    session
    |> Ecto.Changeset.change(workspace_task: %{"offer_ref" => task_ref})
    |> Repo.update!()

    {:ok, snapshot} = Settings.initialize("control-plane:local")

    {:ok, snapshot} =
      Settings.put_repository(
        %{ref: "ryker", github_repository: "example/repository", base_branch: "main"},
        snapshot.installation.revision,
        "control-plane:local"
      )

    {:ok, _snapshot} =
      Settings.put_github_binding(
        %{
          name: "source-test",
          repository_ref: "ryker",
          installation_id: 41,
          repository_id: 17,
          ryker_actor_id: 30
        },
        snapshot.installation.revision,
        "control-plane:local"
      )

    commit = String.duplicate("a", 40)

    job = %{
      "version" => 2,
      "job_ref" => job_ref,
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
          "default_commit" => commit,
          "selected_ref" => "refs/heads/main",
          "selected_commit" => commit,
          "base_commit" => commit,
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

    job_source =
      Map.take(job["source"], ~w(repository_ref github_repository github_repository_id))

    assert {:ok, digest} = JobSpec.digest(job)

    session
    |> Ecto.Changeset.change(worker_job_document: job, worker_job_digest: digest)
    |> Repo.update!()

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: [],
                 repository_ref: session.repository_ref,
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert {:ok, %{name: "source-test", repository_id: 17, installation_id: 41}, ^job_source} =
             SourceGrants.source_grant_authority(
               certificate,
               job_ref,
               job_source
             )

    # Isolate graph membership: this fixture job authorizes the configured
    # repository only as a nested child, never as its primary.
    child =
      Map.merge(job_source, %{
        "path" => "nested",
        "commit" => commit,
        "tree" => String.duplicate("c", 40),
        "submodules" => []
      })

    parent = %{
      job["source"]
      | "repository_ref" => "parent",
        "github_repository" => "example/parent",
        "github_repository_id" => 99,
        "submodules" => [
          %{
            child
            | "path" => "vendor/library",
              "repository_ref" => "middle",
              "github_repository" => "example/middle",
              "github_repository_id" => 98,
              "submodules" => [child]
          }
        ]
    }

    nested_job = Map.put(job, "source", parent)
    assert {:ok, nested_digest} = JobSpec.digest(nested_job)

    Repo.get!(Session, session.id)
    |> Ecto.Changeset.change(worker_job_document: nested_job, worker_job_digest: nested_digest)
    |> Repo.update!()

    assert {:ok, _, ^job_source} =
             SourceGrants.source_grant_authority(certificate, job_ref, job_source)

    Repo.get!(Session, session.id)
    |> Ecto.Changeset.change(worker_job_document: job, worker_job_digest: digest)
    |> Repo.update!()

    assert {:error, :coop_worker_source_grant_not_authorized} =
             SourceGrants.source_grant_authority(
               certificate,
               task_ref,
               job_source
             )

    for source <- [
          Map.put(job_source, "repository_ref", "other"),
          Map.put(job_source, "github_repository_id", 18),
          Map.put(job_source, "binding", job["source"]["binding"]),
          Map.put(job_source, "github_repository", "other/repository")
        ] do
      denied =
        :post
        |> conn(
          "/v1/coop-workers/jobs/#{job_ref}/source-grants",
          Jason.encode!(source)
        )
        |> put_req_header("content-type", "application/json")
        |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
        |> Router.call([])

      assert denied.status == 404
      assert get_resp_header(denied, "cache-control") == ["no-store"]
    end

    assert (:get
            |> conn("/v1/coop-workers/commands/#{Ecto.UUID.generate()}/job-sources/ryker/grant")
            |> Router.call([])).status == 404

    for changes <- [
          [state: :revoking],
          [state: :replaced],
          [state: :retired],
          [lease_expires_at: DateTime.add(Repo.now!(), -1, :second)]
        ] do
      Repo.get!(Placement, placement.id) |> Ecto.Changeset.change(changes) |> Repo.update!()

      assert {:error, :coop_worker_source_grant_not_authorized} =
               SourceGrants.source_grant_authority(
                 certificate,
                 job_ref,
                 job_source
               )

      Repo.get!(Placement, placement.id)
      |> Ecto.Changeset.change(state: :active, lease_expires_at: placement.lease_expires_at)
      |> Repo.update!()

      assert {:ok, %{name: "source-test", repository_id: 17, installation_id: 41}, ^job_source} =
               SourceGrants.source_grant_authority(
                 certificate,
                 job_ref,
                 job_source
               )
    end

    provider =
      start_supervised!(
        {Ryker.GitHub.InstallationTokens,
         %{
           app_http: self(),
           name: nil,
           requester: SourceGrantRequester,
           bindings: %{"source-test" => %{repository_id: 17, installation_id: 41}}
         }}
      )

    begin_mint = fn ->
      task =
        Task.async(fn ->
          receive do
            :begin_source_grant ->
              SourceGrants.source_grant(
                certificate,
                job_ref,
                job_source,
                provider
              )
          end
        end)

      Sandbox.allow(Repo, self(), task.pid)
      send(task.pid, :begin_source_grant)

      # Each mint runs in its own process, which the test releases.
      assert_receive {:source_token_request, minter, :post, "/app/installations/41/access_tokens",
                      %{"permissions" => %{"contents" => "read"}, "repository_ids" => [17]}},
                     5_000

      {task, minter}
    end

    {task, minter} = begin_mint.()
    send(minter, :complete_source_token)

    assert {:ok, %{"token" => "host-only-source-token", "github_repository_id" => 17}} =
             Task.await(task)

    {task, minter} = begin_mint.()

    Repo.get!(Placement, placement.id)
    |> Ecto.Changeset.change(state: :revoking)
    |> Repo.update!()

    send(minter, :complete_source_token)
    assert {:error, :coop_worker_source_grant_not_authorized} = Task.await(task)
    Repo.get!(Placement, placement.id) |> Ecto.Changeset.change(state: :active) |> Repo.update!()

    # GitHub busy or silent may answer the worker's next try, so the worker hears that it
    # is unavailable for now. Told "not found", tenant's worker failed a create for good when
    # GitHub answered a token request with 503 (2026-10-03).
    for answer <- [{:ok, %{status: 503, body: %{}}}, {:error, :timeout}] do
      {task, minter} = begin_mint.()
      send(minter, {:complete_source_token, answer})
      assert {:error, :coop_worker_source_grant_unavailable} = Task.await(task)
    end

    # A token GitHub refused, it refuses again.
    {task, minter} = begin_mint.()
    send(minter, {:complete_source_token, {:ok, %{status: 403, body: %{}}}})
    assert {:error, :coop_worker_source_grant_not_authorized} = Task.await(task)

    Repo.get!(Session, session.id)
    |> Ecto.Changeset.change(worker_job_digest: String.duplicate("f", 64))
    |> Repo.update!()

    assert {:error, :coop_worker_source_grant_not_authorized} =
             SourceGrants.source_grant_authority(
               certificate,
               job_ref,
               job_source
             )
  end

  test "generic API checkpoint custody restores an authenticated body with no special transfer route" do
    certificate = authorize_and_poll!()

    command =
      command!("checkpoint_workspace", %{
        "coop_session_id" => "coop-session-1",
        "expected_revision" => 4,
        "repository_ref" => "ryker"
      })

    {checkpoint, bundle} =
      WorkspaceCheckpointFixture.build(%{
        session_ref: command.session_id,
        placement_generation: command.placement_generation
      })

    {result, options, response} = capture_checkpoint(command, checkpoint, bundle, certificate)
    assert {:ok, receipt} = result
    assert receipt["state"] == "stored"
    transfer = Repo.get!(WorkspaceCheckpointTransfer, receipt["transfer_id"])
    assert transfer.command_id == command.id
    assert transfer.body_command_id != command.id
    assert transfer.descriptor == checkpoint
    assert_body_retention(options[:body_root], transfer.body_command_id)

    assert {:ok, ^receipt} =
             Checkpoints.capture(command.session_id, command.idempotency_key, response, options)

    source = Repo.get!(Session, command.session_id)

    requirements = %{
      capability_names: [],
      repository_ref: source.repository_ref,
      workspace_ref: "workspace-main"
    }

    assert ControlPlane.portable_workspace(source, requirements, options[:body_root]) != nil
    data_path = Path.join([options[:body_root], transfer.body_command_id, "response", "data"])
    File.rename!(data_path, data_path <> ".held")
    assert ControlPlane.portable_workspace(source, requirements, options[:body_root]) == nil
    File.rename!(data_path <> ".held", data_path)

    Repo.get!(Placement, command.placement_id)
    |> Ecto.Changeset.change(state: :replaced)
    |> Repo.update!()

    replacement =
      SessionChangeset.insert(
        Ecto.UUID.generate(),
        source.episode_id,
        source.generation + 1,
        source.policy,
        source.policy_digest,
        source.repository_ref,
        source.external_ref
      )
      |> Ecto.Changeset.change(repository_source: source.repository_source)
      |> Repo.insert!()

    {:ok, job, digest} =
      JobSpec.rebind(
        source.worker_job_document,
        source.worker_job_digest,
        replacement.external_ref
      )

    replacement = replacement |> SessionChangeset.pin_worker_job(job, digest) |> Repo.update!()

    assert {:ok, placement} =
             ControlPlane.place_session(
               replacement.id,
               %{
                 capability_names: [],
                 repository_ref: replacement.repository_ref,
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert {:ok, restore} =
             ControlPlane.enqueue_command(
               placement.id,
               "ensure_workspace",
               %{
                 "checkpoint" => %{
                   "transfer_id" => transfer.id,
                   "byte_size" => byte_size(bundle),
                   "checkpoint_ref" => checkpoint["checkpoint_ref"],
                   "sha256" => checkpoint["bundle"]["sha256"],
                   "source_placement_generation" => command.placement_generation,
                   "source_session_ref" => command.session_id
                 },
                 "coop_session_id" => "replacement",
                 "expected_revision" => 1
               },
               "restore:#{Ecto.UUID.generate()}"
             )

    # Enqueue is durable, but no command goes out while its large body is absent.
    assert {:ok, %{"commands" => []}} =
             ControlPlane.handle_poll(
               "worker-a",
               Map.put(poll(), "poll_ref", Ecto.UUID.generate()),
               options
             )

    assert :ok = Checkpoints.prepare_restore(restore, options)

    assert {:ok, %{"commands" => [wire]}} =
             ControlPlane.handle_poll(
               "worker-a",
               Map.put(poll(), "poll_ref", Ecto.UUID.generate()),
               options
             )

    assert wire["kind"] == "api_request"
    assert wire["payload"]["path"] == "/v1/sessions/replacement/workspace/restore"
    assert wire["payload"]["body_ref"] == Map.take(checkpoint["bundle"], ~w(sha256 byte_size))

    download =
      :get
      |> conn("/v1/coop-workers/commands/#{restore.id}/request-body")
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call(options)

    assert download.status == 200
    assert download.resp_body == bundle

    changed = put_in(response, ["checkpoint", "candidate_tree_sha256"], String.duplicate("a", 64))

    assert {:error, :checkpoint_not_authorized} =
             Checkpoints.capture(command.session_id, command.idempotency_key, changed, options)
  end

  defp assert_body_retention(root, live_id) do
    orphan = Ecto.UUID.generate()
    recent = Ecto.UUID.generate()
    old = System.os_time(:second) - 86_401
    for id <- [orphan, recent], do: File.mkdir_p!(Path.join(root, id))
    File.touch!(Path.join(root, orphan), old)
    File.touch!(Path.join(root, live_id), old)
    link = Path.join(root, Ecto.UUID.generate())
    File.ln_s!(Path.join(root, live_id), link)
    File.mkdir_p!(Path.join(root, "unrecognized"))
    File.touch!(Path.join(root, "unrecognized"), old)
    assert :ok = Bodies.prune_orphans(root)
    refute File.exists?(Path.join(root, orphan))
    assert File.dir?(Path.join(root, recent))
    assert File.dir?(Path.join(root, live_id))
    assert File.lstat!(link).type == :symlink
    assert File.dir?(Path.join(root, "unrecognized"))
  end

  test "checkpoint capture rejects credential-bearing content before recording portable custody" do
    certificate = authorize_and_poll!()

    command =
      command!("checkpoint_workspace", %{
        "coop_session_id" => "coop-session-1",
        "expected_revision" => 4,
        "repository_ref" => "ryker"
      })

    {checkpoint, bundle} =
      WorkspaceCheckpointFixture.build(%{
        session_ref: command.session_id,
        placement_generation: command.placement_generation,
        task: "token=ghp_abcdefghijklmnopqrstuvwxyz123456\n"
      })

    {result, _options, _response} = capture_checkpoint(command, checkpoint, bundle, certificate)
    assert {:error, {:invalid_workspace_checkpoint_bundle, :secret}} = result
    assert Repo.aggregate(WorkspaceCheckpointTransfer, :count) == 0
  end

  defp capture_checkpoint(command, checkpoint, bundle, certificate) do
    root = Path.join(System.tmp_dir!(), "checkpoint-api-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(root) end)
    key = Ryker.Secret.new(:binary.copy(<<7>>, 32))

    response = %{
      "checkpoint" => checkpoint,
      "operation" => %{
        "id" => "op-checkpoint",
        "method" => "CheckpointWorkspace",
        "state" => "succeeded"
      }
    }

    finish = fn id, operation_key, resource ->
      result = %{
        "command_id" => id,
        "operation_key" => operation_key,
        "error" => nil,
        "state" => "succeeded",
        "resource" => resource
      }

      document =
        poll()
        |> Map.put("poll_ref", Ecto.UUID.generate())
        |> Map.put("command_results", [result])

      assert {:ok, _} = ControlPlane.handle_poll("worker-a", document, body_root: root)
      :ok
    end

    finish.(command.id, command.idempotency_key, %{"status" => 200, "body" => response})

    options = [
      body_root: root,
      checkpoint_key: key,
      workspace_ref: "workspace-main",
      max_waits: 3,
      poll_interval_ms: 1,
      wait: fn ->
        assert {:ok, %{"commands" => [get]}} =
                 ControlPlane.handle_poll(
                   "worker-a",
                   Map.put(poll(), "poll_ref", Ecto.UUID.generate())
                 )

        assert get["payload"]["method"] == "GET"
        assert get["payload"]["path"] == "/v1/operations/op-checkpoint/checkpoint-bundle"

        upload =
          :put
          |> conn("/v1/coop-workers/commands/#{get["command_id"]}/response-body", bundle)
          |> put_req_header("content-length", to_string(byte_size(bundle)))
          |> put_req_header("x-coop-body-sha256", checkpoint["bundle"]["sha256"])
          |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
          |> Router.call(body_root: root, checkpoint_key: key)

        assert upload.status == 200

        finish.(get["command_id"], get["idempotency_key"], %{
          "status" => 200,
          "body_ref" => Map.take(checkpoint["bundle"], ~w(sha256 byte_size)),
          "headers" => %{
            "Content-Type" => checkpoint["bundle"]["media_type"],
            "Etag" => ~s("#{checkpoint["bundle"]["sha256"]}")
          }
        })
      end
    ]

    {Checkpoints.capture(command.session_id, command.idempotency_key, response, options), options,
     response}
  end

  test "worker HTTP boundaries return typed errors before accepting malformed authority or bytes" do
    authority = enrollment_authority()

    assert Router.init(enrollment_authority: authority) == [enrollment_authority: authority]

    assert 415 ==
             (:post
              |> conn("/v1/coop-workers/enroll", "{}")
              |> Router.call(enrollment_authority: authority)).status

    assert 400 ==
             (:post
              |> conn("/v1/coop-workers/enroll", "{")
              |> put_req_header("content-type", "application/json")
              |> Router.call(enrollment_authority: authority)).status

    assert 401 ==
             (:post
              |> conn("/v1/coop-workers/renew", "{}")
              |> put_req_header("content-type", "application/json")
              |> Router.call(enrollment_authority: authority)).status

    certificate = authorize_and_poll!()

    unknown_certificate = unregistered_certificate_der()

    for {method, path, body, expected_status} <- [
          {:post, "/v1/coop-workers/renew", "{}", 400},
          {:post, "/v1/coop-workers/poll", Jason.encode!(poll()), 401},
          {:get, "/v1/coop-workers/commands/missing/request-body", "", 404}
        ] do
      unauthorized =
        method
        |> conn(path, body)
        |> put_req_header("content-type", "application/json")
        |> put_peer_data(%{
          address: {127, 0, 0, 1},
          port: 1234,
          ssl_cert: unknown_certificate
        })
        |> Router.call(enrollment_authority: authority)

      assert unauthorized.status == expected_status
    end

    root = Path.join(System.tmp_dir!(), "coop-body-errors-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(root) end)
    command = command!("api_request", %{"method" => "GET", "path" => "/v1/sessions/s"})
    path = "/v1/coop-workers/commands/#{command.id}/response-body"

    for {hash, length} <- [
          {"wrong", "5"},
          {String.duplicate("a", 64), "0"},
          {String.duplicate("a", 64), "9223372036854775807"}
        ] do
      response =
        :put
        |> conn(path, "bytes")
        |> put_req_header("content-length", length)
        |> put_req_header("x-coop-body-sha256", hash)
        |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
        |> Router.call(body_root: root, checkpoint_key: Ryker.Secret.new(:binary.copy(<<7>>, 32)))

      assert response.status == 400
    end

    # These endpoints were removed, not kept as compatibility aliases.
    for route <- [
          "input-artifacts/a",
          "output-artifacts/a",
          "review-patches/a",
          "workspace-checkpoints/a"
        ] do
      assert (:get
              |> conn("/v1/coop-workers/commands/#{command.id}/#{route}")
              |> Router.call([])).status == 404

      assert (:put
              |> conn("/v1/coop-workers/commands/#{command.id}/#{route}", "bytes")
              |> Router.call([])).status == 404
    end

    assert (:put |> conn(path, "bytes") |> Router.call(body_root: root)).status == 401
  end

  # A worker could upload any size it declared, for any command, up to 2^63
  # bytes, and fill the disk (2026-10-04 review). Ryker reads documents and
  # artifacts back with an 8 MiB limit; only a checkpoint bundle is larger.
  test "a worker uploads no more for a command than Ryker reads back" do
    certificate = authorize_and_poll!()
    document = command!("api_request", %{"method" => "GET", "path" => "/v1/sessions/s"})
    {root, refused} = upload_over_document_limit(document, certificate)

    assert refused.status == 413
    assert Jason.decode!(refused.resp_body)["error"]["code"] == "response_body_too_large"
    assert {:error, _} = Bodies.fetch(root, document.id, :response)
  end

  test "a checkpoint bundle may be larger than any document" do
    certificate = authorize_and_poll!()
    bundle = command!("get_checkpoint_bundle", %{"operation_id" => "checkpoint-limits"})
    {root, stored} = upload_over_document_limit(bundle, certificate)

    assert stored.status == 200
    assert {:ok, _body, _reference} = Bodies.fetch(root, bundle.id, :response)
  end

  test "a body is stored only while the volume keeps its reserve" do
    root = System.tmp_dir!()
    assert Bodies.room?(root, 1, 0)
    refute Bodies.room?(root, 1, Integer.pow(2, 62))
  end

  defp upload_over_document_limit(command, certificate) do
    root = Path.join(System.tmp_dir!(), "coop-body-limits-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(root) end)
    bytes = :binary.copy(<<1>>, 8 * 1_024 * 1_024 + 1)

    response =
      :put
      |> conn("/v1/coop-workers/commands/#{command.id}/response-body", bytes)
      |> put_req_header("content-length", to_string(byte_size(bytes)))
      |> put_req_header(
        "x-coop-body-sha256",
        Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      )
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call(body_root: root, checkpoint_key: Ryker.Secret.new(:binary.copy(<<7>>, 32)))

    {root, response}
  end

  defp authorize_and_poll! do
    certificate = "verified-client-certificate-#{Ecto.UUID.generate()}"
    fingerprint = :crypto.hash(:sha256, certificate) |> Base.encode16(case: :lower)

    assert {:ok, _worker} =
             ControlPlane.authorize_worker("worker-a", "workspace-main", fingerprint)

    assert {:ok, _response} = ControlPlane.handle_poll_certificate(certificate, poll())
    certificate
  end

  defp command!(kind, payload) do
    session = session!()

    session =
      if is_binary(payload["coop_session_id"]) do
        session
        |> Ecto.Changeset.change(coop_session_id: payload["coop_session_id"])
        |> Repo.update!()
      else
        session
      end

    payload =
      if kind == "checkpoint_workspace",
        do: Map.put(payload, "session_ref", session.id),
        else: payload

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: [],
                 repository_ref: session.repository_ref,
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert {:ok, command} =
             ControlPlane.enqueue_command(
               placement.id,
               kind,
               payload,
               "ryker:test:#{kind}:#{Ecto.UUID.generate()}"
             )

    assert {:ok, %{"commands" => [%{"command_id" => command_id}]}} =
             ControlPlane.handle_poll(
               "worker-a",
               Map.put(poll(), "poll_ref", "poll:worker-a:command")
             )

    assert command_id == command.id
    command
  end

  defp session! do
    episode_id = Ecto.UUID.generate()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "fleet:router:#{episode_id}",
                 native_input_id: "source:fleet-router:#{episode_id}",
                 occurred_at: Repo.now!(),
                 turn_ref: "turn:fleet-router:#{episode_id}"
               })
             )

    assert {:ok, session} =
             Custody.pin_episode(episode_id, "work-read-only", @policy_digest, "ryker")

    WorkerJob.pin!(session)
  end

  defp poll do
    %{
      "acknowledged_command_ids" => [],
      "command_results" => [],
      "event_batches" => [],
      "poll_ref" => "poll:worker-a:router",
      "version" => 2,
      "worker" => %{
        "build_version" => "coop-test",
        "capabilities" => [],
        "capacity" => %{
          "cooldown_until" => nil,
          "session_slots_free" => 1,
          "session_slots_total" => 1,
          "state" => "eligible",
          "turn_slots_free" => 1,
          "turn_slots_total" => 1,
          "workspace_slots_free" => 1,
          "workspace_slots_total" => 1
        },
        "clock_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "id" => "worker-a",
        "protocol_version" => "2",
        "sandbox_digest" => String.duplicate("a", 64),
        "state" => "eligible",
        "workspace_ref" => "workspace-main"
      }
    }
  end

  defp enrollment_authority do
    root =
      :public_key.pkix_test_root_cert(~c"Ryker Test Worker CA",
        digest: :sha256,
        key: {:rsa, 2_048, 65_537}
      )

    %{
      ca_certificate_pem: :public_key.pem_encode([{:Certificate, root.cert, :not_encrypted}]),
      ca_key_pem:
        :RSAPrivateKey
        |> :public_key.pem_entry_encode(root.key)
        |> then(&:public_key.pem_encode([&1])),
      certificate_ttl_seconds: 3_600
    }
  end

  defp public_key_pem do
    private_key = :public_key.generate_key({:rsa, 2_048, 65_537})
    public_key = {:RSAPublicKey, elem(private_key, 2), elem(private_key, 3)}

    :SubjectPublicKeyInfo
    |> :public_key.pem_entry_encode(public_key)
    |> then(&:public_key.pem_encode([&1]))
  end

  defp certificate_der(pem) do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
    der
  end

  defp unregistered_certificate_der do
    :public_key.pkix_test_root_cert(~c"Unregistered Test Worker CA",
      digest: :sha256,
      key: {:rsa, 2_048, 65_537}
    ).cert
  end
end
