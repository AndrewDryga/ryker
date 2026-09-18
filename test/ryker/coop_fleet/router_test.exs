defmodule Ryker.CoopFleet.RouterTest do
  use Ryker.DataCase, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Ryker.Artifacts
  alias Ryker.CoopFleet.{ArtifactTransport, ControlPlane, Enrollment, Placement, Router}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkspaceCheckpoint, as: WorkspaceCheckpointFixture
  alias Ryker.Repo
  alias Ryker.Work.{Custody, Session, SessionChangeset, StateBinding}

  @policy_digest String.duplicate("b", 64)

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
          "token" => issued_token.token,
          "worker_id" => "worker-enrolled",
          "workspace_ref" => "workspace-main"
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
          "token" => issued_token.token,
          "worker_id" => "worker-enrolled",
          "workspace_ref" => "workspace-main"
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
               "controller-state-tools-secret"
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

  test "one delivered submit command can fetch only its exact authenticated input artifact" do
    certificate = authorize_and_poll!()

    assert {:ok, artifact} =
             Artifacts.put(%{
               data: "exact pull request context",
               media_type: "text/plain",
               name: "review.txt",
               source_kind: "github",
               source_ref: "github:artifact:#{Ecto.UUID.generate()}"
             })

    command =
      command!("submit_turn", %{
        "submission" => %{"input_artifact_refs" => [artifact.ref]}
      })

    conn =
      :get
      |> conn("/v1/coop-workers/commands/#{command.id}/input-artifacts/#{artifact.ref}")
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call([])

    assert conn.status == 200
    assert conn.resp_body == artifact.data
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "x-responder-artifact-sha256") == [artifact.sha256]

    denied =
      :get
      |> conn("/v1/coop-workers/commands/#{command.id}/input-artifacts/artifact:input:wrong")
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call([])

    assert denied.status == 404
  end

  test "an exact SubmitTurn fence can fetch its frozen artifact but other fences cannot" do
    certificate = authorize_and_poll!()

    assert {:ok, artifact} =
             Artifacts.put(%{
               data: "frozen review evidence",
               media_type: "text/plain",
               name: "evidence.txt",
               source_kind: "github",
               source_ref: "github:fence-artifact:#{Ecto.UUID.generate()}"
             })

    command =
      command!("fence_operation", %{
        "input_artifact_refs" => [artifact.ref],
        "method" => "SubmitTurn",
        "request" => %{"session_id" => "coop-session-1"}
      })

    accepted =
      :get
      |> conn("/v1/coop-workers/commands/#{command.id}/input-artifacts/#{artifact.ref}")
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call([])

    assert accepted.status == 200
    assert accepted.resp_body == artifact.data

    assert {:ok, crossed} =
             ControlPlane.enqueue_command(
               command.placement_id,
               "fence_operation",
               %{
                 "input_artifact_refs" => [artifact.ref],
                 "method" => "CreateRemoteSession",
                 "request" => %{}
               },
               "ryker:test:fence-crossed:#{Ecto.UUID.generate()}"
             )

    followup_poll =
      poll()
      |> Map.put("acknowledged_command_ids", [command.id])
      |> Map.put("poll_ref", "poll:worker-a:fence-crossed")

    assert {:ok, %{"commands" => commands}} =
             ControlPlane.handle_poll("worker-a", followup_poll)

    assert Enum.any?(commands, &(&1["command_id"] == crossed.id))

    denied =
      :get
      |> conn("/v1/coop-workers/commands/#{crossed.id}/input-artifacts/#{artifact.ref}")
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call([])

    assert denied.status == 404
  end

  test "one delivered output command uploads and reconciles only its exact immutable bytes" do
    certificate = authorize_and_poll!()
    artifact_ref = "artifact_chart"

    command =
      command!("get_output_artifact", %{
        "artifact_ref" => artifact_ref,
        "coop_session_id" => "coop-session-1",
        "coop_turn_id" => "coop-turn-1"
      })

    data = <<137, 80, 78, 71, 13, 10, 26, 10, "chart">>
    sha256 = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

    upload = fn body, digest ->
      :put
      |> conn(
        "/v1/coop-workers/commands/#{command.id}/output-artifacts/#{artifact_ref}",
        body
      )
      |> put_req_header("content-type", "image/png")
      |> put_req_header("content-length", Integer.to_string(byte_size(body)))
      |> put_req_header(
        "x-responder-artifact-name",
        Base.url_encode64("chart.png", padding: false)
      )
      |> put_req_header("x-responder-artifact-sha256", digest)
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call([])
    end

    first = upload.(data, sha256)
    assert first.status == 200
    response = Jason.decode!(first.resp_body)
    assert response["artifact_ref"] == artifact_ref
    assert response["bytes"] == byte_size(data)

    assert {:ok, stored} = ArtifactTransport.fetch_output(response["transfer_id"])
    assert stored["data"] == data
    assert stored["name"] == "chart.png"

    replay = upload.(data, sha256)
    assert replay.status == 200
    assert Jason.decode!(replay.resp_body)["transfer_id"] == response["transfer_id"]

    changed = <<137, 80, 78, 71, 13, 10, 26, 10, "changed">>
    changed_sha = :crypto.hash(:sha256, changed) |> Base.encode16(case: :lower)
    assert upload.(changed, changed_sha).status == 400
  end

  test "a publication review patch crosses only its exact command-scoped binary route" do
    certificate = authorize_and_poll!()
    patch = "diff --git a/lib/a.ex b/lib/a.ex\n+verified\n"
    sha256 = :crypto.hash(:sha256, patch) |> Base.encode16(case: :lower)
    artifact_id = "review-artifact-1"

    command =
      command!("get_review_patch", %{
        "artifact_id" => artifact_id,
        "coop_session_id" => "coop-session-1",
        "expected_bytes" => byte_size(patch),
        "expected_sha256" => sha256
      })

    conn =
      :put
      |> conn(
        "/v1/coop-workers/commands/#{command.id}/review-patches/#{artifact_id}",
        patch
      )
      |> put_req_header("content-type", "text/x-diff")
      |> put_req_header("content-length", Integer.to_string(byte_size(patch)))
      |> put_req_header("x-responder-artifact-sha256", sha256)
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call([])

    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)
    assert response["artifact_id"] == artifact_id
    assert {:ok, ^patch} = ArtifactTransport.fetch_review_patch(response["transfer_id"])
  end

  test "one checkpoint command stores only its verified encrypted bundle and exact replays reconcile" do
    certificate = authorize_and_poll!()
    key = :crypto.strong_rand_bytes(32)

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

    upload = fn checkpoint, body ->
      :put
      |> conn(
        "/v1/coop-workers/commands/#{command.id}/workspace-checkpoints/#{checkpoint["checkpoint_ref"]}",
        body
      )
      |> put_req_header("content-type", checkpoint["bundle"]["media_type"])
      |> put_req_header("content-length", Integer.to_string(byte_size(body)))
      |> put_req_header(
        "x-responder-checkpoint-descriptor",
        checkpoint |> Jason.encode!() |> Base.url_encode64(padding: false)
      )
      |> put_req_header("x-responder-checkpoint-sha256", checkpoint["bundle"]["sha256"])
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call(checkpoint_key: key, checkpoint_secrets: [])
    end

    first = upload.(checkpoint, bundle)
    assert first.status == 200
    response = Jason.decode!(first.resp_body)
    assert response["checkpoint_ref"] == checkpoint["checkpoint_ref"]
    assert response["state"] == "stored"

    assert {:ok, stored} = ArtifactTransport.fetch_checkpoint(response["transfer_id"], key)
    assert stored.checkpoint == checkpoint
    assert stored.bundle == bundle

    %{rows: [[ciphertext]]} =
      Repo.query!("SELECT ciphertext FROM coop_worker_workspace_checkpoints WHERE id = $1", [
        Ecto.UUID.dump!(response["transfer_id"])
      ])

    refute ciphertext == bundle
    refute :binary.match(ciphertext, "Status: in_progress") != :nomatch

    replay = upload.(checkpoint, bundle)
    assert replay.status == 200
    assert Jason.decode!(replay.resp_body)["transfer_id"] == response["transfer_id"]

    source_session = Repo.get!(Session, command.session_id)

    command.placement_id
    |> then(&Repo.get!(Placement, &1))
    |> Ecto.Changeset.change(state: :replaced)
    |> Repo.update!()

    replacement =
      SessionChangeset.insert(
        Ecto.UUID.generate(),
        source_session.episode_id,
        source_session.generation + 1,
        source_session.policy,
        source_session.policy_digest,
        source_session.repository_ref,
        source_session.external_ref
      )
      |> Repo.insert!()

    assert {:ok, replacement_placement} =
             ControlPlane.place_session(
               replacement.id,
               %{
                 capability_names: [],
                 repository_ref: replacement.repository_ref,
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert {:ok, restore_command} =
             ControlPlane.enqueue_command(
               replacement_placement.id,
               "ensure_workspace",
               %{
                 "checkpoint" => %{
                   "byte_size" => byte_size(bundle),
                   "checkpoint_ref" => checkpoint["checkpoint_ref"],
                   "sha256" => checkpoint["bundle"]["sha256"],
                   "source_placement_generation" => command.placement_generation,
                   "source_session_ref" => command.session_id,
                   "transfer_id" => response["transfer_id"]
                 },
                 "coop_session_id" => "coop-session-replacement",
                 "expected_revision" => 1,
                 "task" => %{"offer_ref" => "record:task_offer:replacement"}
               },
               "ryker:test:ensure-workspace:restore"
             )

    restore_command
    |> Ecto.Changeset.change(status: :delivered, delivered_at: database_now!())
    |> Repo.update!()

    download =
      :get
      |> conn(
        "/v1/coop-workers/commands/#{restore_command.id}/workspace-checkpoints/#{response["transfer_id"]}"
      )
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call(checkpoint_key: key, checkpoint_secrets: [])

    assert download.status == 200
    assert download.resp_body == bundle

    assert download
           |> get_resp_header("x-responder-checkpoint-descriptor")
           |> List.first()
           |> Base.url_decode64!(padding: false)
           |> Jason.decode!() == checkpoint

    changed = put_in(checkpoint, ["candidate_tree_sha256"], String.duplicate("a", 64))
    assert upload.(changed, bundle).status == 400
  end

  test "checkpoint upload rejects a credential-shaped task before durable storage" do
    certificate = authorize_and_poll!()
    key = :crypto.strong_rand_bytes(32)

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

    conn =
      :put
      |> conn(
        "/v1/coop-workers/commands/#{command.id}/workspace-checkpoints/#{checkpoint["checkpoint_ref"]}",
        bundle
      )
      |> put_req_header("content-type", checkpoint["bundle"]["media_type"])
      |> put_req_header("content-length", Integer.to_string(byte_size(bundle)))
      |> put_req_header(
        "x-responder-checkpoint-descriptor",
        checkpoint |> Jason.encode!() |> Base.url_encode64(padding: false)
      )
      |> put_req_header("x-responder-checkpoint-sha256", checkpoint["bundle"]["sha256"])
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call(checkpoint_key: key, checkpoint_secrets: [])

    assert conn.status == 400
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM coop_worker_workspace_checkpoints")
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
          {:get, "/v1/coop-workers/commands/missing/input-artifacts/missing", "", 401}
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

    upload_data = "bytes"
    upload_sha256 = :crypto.hash(:sha256, upload_data) |> Base.encode16(case: :lower)

    for {path, content_type, headers} <- [
          {
            "/v1/coop-workers/commands/missing/output-artifacts/missing",
            "image/png",
            [{"x-responder-artifact-name", Base.url_encode64("file.png", padding: false)}]
          },
          {
            "/v1/coop-workers/commands/missing/review-patches/missing",
            "text/x-diff",
            []
          }
        ] do
      unauthorized =
        :put
        |> conn(path, upload_data)
        |> put_req_header("content-type", content_type)
        |> put_req_header("content-length", Integer.to_string(byte_size(upload_data)))
        |> put_req_header("x-responder-artifact-sha256", upload_sha256)
        |> put_peer_data(%{
          address: {127, 0, 0, 1},
          port: 1234,
          ssl_cert: unknown_certificate
        })

      unauthorized =
        Enum.reduce(headers, unauthorized, fn {name, value}, request ->
          put_req_header(request, name, value)
        end)

      assert Router.call(unauthorized, []).status == 401
    end

    unsupported_renewal =
      :post
      |> conn("/v1/coop-workers/renew", "{}")
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call(enrollment_authority: authority)

    assert unsupported_renewal.status == 415

    invalid_renewal =
      :post
      |> conn("/v1/coop-workers/renew", "{")
      |> put_req_header("content-type", "application/json")
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call(enrollment_authority: authority)

    assert invalid_renewal.status == 400

    no_state_token =
      :post
      |> conn("/v1/state-tools/mcp", "{}")
      |> put_req_header("content-type", "application/json")
      |> Router.call(state_tools: %{capabilities: []})

    assert no_state_token.status == 401

    oversized = String.duplicate("x", 1_048_577)

    for {path, options} <- [
          {"/v1/coop-workers/enroll", [enrollment_authority: authority]},
          {"/v1/coop-workers/renew", [enrollment_authority: authority]},
          {"/v1/coop-workers/poll", []}
        ] do
      too_large =
        :post
        |> conn(path, oversized)
        |> put_req_header("content-type", "application/json")
        |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
        |> Router.call(options)

      assert too_large.status == 413
    end

    assert 415 ==
             (:post
              |> conn("/v1/coop-workers/poll", "{}")
              |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
              |> Router.call([])).status

    assert 400 ==
             (:post
              |> conn("/v1/coop-workers/poll", "{")
              |> put_req_header("content-type", "application/json")
              |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
              |> Router.call([])).status

    for {path, content_type, extra_headers} <- [
          {"/v1/coop-workers/commands/missing/output-artifacts/missing",
           "application/octet-stream", []},
          {"/v1/coop-workers/commands/missing/review-patches/missing", "text/x-diff", []}
        ] do
      invalid_headers =
        :put
        |> conn(path, "bytes")
        |> put_req_header("content-type", content_type)
        |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})

      invalid_headers =
        Enum.reduce(extra_headers, invalid_headers, fn {name, value}, request ->
          put_req_header(request, name, value)
        end)

      assert Router.call(invalid_headers, []).status in [400, 415]
    end

    invalid_output_headers =
      :put
      |> conn("/v1/coop-workers/commands/missing/output-artifacts/missing", upload_data)
      |> put_req_header("content-type", "image/png")
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call([])

    assert invalid_output_headers.status == 400

    invalid_review_digest =
      :put
      |> conn("/v1/coop-workers/commands/missing/review-patches/missing", upload_data)
      |> put_req_header("content-type", "text/x-diff")
      |> put_req_header("content-length", Integer.to_string(byte_size(upload_data)))
      |> put_req_header("x-responder-artifact-sha256", "not-a-digest")
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call([])

    assert invalid_review_digest.status == 415

    for {path, content_type, headers} <- [
          {
            "/v1/coop-workers/commands/missing/output-artifacts/missing",
            "image/png",
            [{"x-responder-artifact-name", Base.url_encode64("file.png", padding: false)}]
          },
          {
            "/v1/coop-workers/commands/missing/review-patches/missing",
            "text/x-diff",
            []
          }
        ] do
      mismatched_length =
        :put
        |> conn(path, upload_data)
        |> put_req_header("content-type", content_type)
        |> put_req_header("content-length", Integer.to_string(byte_size(upload_data) + 1))
        |> put_req_header("x-responder-artifact-sha256", upload_sha256)
        |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})

      mismatched_length =
        Enum.reduce(headers, mismatched_length, fn {name, value}, request ->
          put_req_header(request, name, value)
        end)

      assert Router.call(mismatched_length, []).status == 400
    end

    oversized_artifact = String.duplicate("x", 8 * 1_024 * 1_024 + 1)

    artifact_too_large =
      :put
      |> conn(
        "/v1/coop-workers/commands/missing/output-artifacts/missing",
        oversized_artifact
      )
      |> put_req_header("content-type", "image/png")
      |> put_req_header("content-length", Integer.to_string(8 * 1_024 * 1_024))
      |> put_req_header(
        "x-responder-artifact-name",
        Base.url_encode64("large.png", padding: false)
      )
      |> put_req_header("x-responder-artifact-sha256", String.duplicate("a", 64))
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
      |> Router.call([])

    assert artifact_too_large.status == 413

    assert 401 ==
             (:get
              |> conn("/v1/coop-workers/commands/missing/input-artifacts/missing")
              |> Router.call([])).status

    for {path, expected_status} <- [
          {"/v1/coop-workers/commands/missing/output-artifacts/missing", 415},
          {"/v1/coop-workers/commands/missing/review-patches/missing", 400}
        ] do
      assert 401 == (:put |> conn(path, "bytes") |> Router.call([])).status

      unsupported =
        :put
        |> conn(path, "bytes")
        |> put_req_header("content-type", "application/octet-stream")
        |> put_peer_data(%{address: {127, 0, 0, 1}, port: 1234, ssl_cert: certificate})
        |> Router.call([])

      assert unsupported.status == expected_status
    end

    assert 404 == (:get |> conn("/not-a-worker-route") |> Router.call([])).status
  end

  test "artifact transfer identifiers and unauthenticated direct calls fail closed" do
    missing = Ecto.UUID.generate()

    assert {:error, :coop_worker_output_artifact_not_found} =
             ArtifactTransport.fetch_output("not-a-uuid")

    assert {:error, :coop_worker_output_artifact_not_found} =
             ArtifactTransport.fetch_output(missing)

    assert {:error, :coop_worker_review_patch_not_found} =
             ArtifactTransport.fetch_review_patch("not-a-uuid")

    assert {:error, :coop_worker_review_patch_not_found} =
             ArtifactTransport.fetch_review_patch(missing)

    assert {:error, :coop_worker_certificate_not_authorized} =
             ArtifactTransport.fetch_input("unknown-certificate", missing, "artifact")

    assert {:error, :coop_worker_certificate_not_authorized} =
             ArtifactTransport.put_output("unknown-certificate", missing, "artifact", %{})

    assert {:error, :coop_worker_certificate_not_authorized} =
             ArtifactTransport.put_review_patch("unknown-certificate", missing, "artifact", %{})
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
                 occurred_at: database_now!(),
                 turn_ref: "turn:fleet-router:#{episode_id}"
               })
             )

    assert {:ok, session} =
             Custody.pin_episode(episode_id, "work-read-only", @policy_digest, "ryker")

    session
  end

  defp poll do
    %{
      "acknowledged_command_ids" => [],
      "command_results" => [],
      "event_batches" => [],
      "poll_ref" => "poll:worker-a:router",
      "version" => 1,
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
        "policy_digests" => %{"work-read-only" => @policy_digest},
        "protocol_version" => "1",
        "repositories" => [%{"ref" => "ryker", "revision" => "commit:test"}],
        "sandbox_digest" => String.duplicate("a", 64),
        "state" => "eligible",
        "workspace_ref" => "workspace-main"
      }
    }
  end

  defp database_now! do
    %{rows: [[now]]} = Ryker.Repo.query!("SELECT clock_timestamp()")
    now
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
