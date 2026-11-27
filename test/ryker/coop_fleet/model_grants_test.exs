defmodule Ryker.CoopFleet.ModelGrantsTest do
  use Ryker.DataCase, async: false
  import Ryker.TestHelpers, only: [digest: 1]
  import Plug.Test
  alias Ryker.CoopFleet.{Certificate, JobSpec, ModelAccounts, ModelContracts}
  alias Ryker.CoopFleet.{ModelGrants, ModelPermit, ModelPermits, ModelProxy, ModelRun}
  alias Ryker.CoopFleet.{ModelSocket, ModelSocketLedger, Worker, WorkerLifecycle}
  alias Ryker.Credentials
  alias Ryker.Fixtures.CoopWorkers
  alias Ryker.Repo
  alias Ryker.Work.Session
  @key "controller-only-provider-key-canary"
  setup do
    Ryker.Fixtures.ModelAccess.create!()
  end

  test("grants carry only a temporary capability and bind the current leased job", %{
    certificate: certificate,
    placement: placement,
    request: request,
    session: session
  }) do
    assert {:ok, grant} = ModelGrants.issue(certificate, session.external_ref, request)
    refute Jason.encode!(grant) =~ @key
    assert grant["selection"] == "apikey"

    assert {:ok, binding} =
             ModelGrants.authorize(
               certificate,
               session.external_ref,
               "claude",
               grant["token"]
             )

    assert binding.account["credential"] == @key
    assert length(Repo.all(ModelRun.Query.all())) == 1
    refute inspect(Repo.all(ModelRun.Query.all())) =~ grant["token"]
    assert @key in Credentials.redaction_values()

    assert ModelGrants.issue(certificate, session.external_ref, %{request | "account" => "other"}) ==
             {:error, :model_grant_refused}

    assert ModelGrants.authorize(
             "another-certificate",
             session.external_ref,
             "claude",
             grant["token"]
           ) == {:error, :model_grant_refused}

    assert ModelGrants.authorize(certificate, "another-job", "claude", grant["token"]) ==
             {:error, :model_grant_refused}

    assert {:ok, renewed} = ModelGrants.issue(certificate, session.external_ref, request)
    assert renewed["token"] == grant["token"]
    placement |> Ecto.Changeset.change(state: :replaced) |> Repo.update!()

    assert ModelGrants.authorize(
             certificate,
             session.external_ref,
             "claude",
             grant["token"]
           ) == {:error, :model_grant_refused}
  end

  test("account replacement invalidates old capabilities", %{
    certificate: certificate,
    request: request,
    session: session
  }) do
    {:ok, grant} = ModelGrants.issue(certificate, session.external_ref, request)
    assert {:ok, _metadata} = put_account("replacement-provider-key-canary")

    assert ModelGrants.authorize(
             certificate,
             session.external_ref,
             "claude",
             grant["token"]
           ) == {:error, :model_grant_refused}

    assert {:ok, next} = ModelGrants.issue(certificate, session.external_ref, request)
    refute next["epoch"] == grant["epoch"]
    refute next["token"] == grant["token"]
  end

  test("the controller injects the provider key after route and model checks", %{
    certificate: certificate,
    request: request,
    session: session
  }) do
    {:ok, grant} = ModelGrants.issue(certificate, session.external_ref, request)
    owner = self()

    stream = fn request, _pool, _timeout, state, callback ->
      send(owner, {:upstream, request})

      Enum.reduce(
        [status: 200, headers: [{"content-type", "text/event-stream"}], data: "data: reply\n\n"],
        state,
        fn event, acc ->
          {:cont, next} = callback.(event, acc)
          next
        end
      )

      {:ok, :streaming}
    end

    json = ~s({"model":"claude-sonnet-5-5","messages":[]})
    compressed = json |> :zstd.compress(%{contentSizeFlag: false}) |> IO.iodata_to_binary()

    for {headers, body} <- [{[], json}, {[{"content-encoding", "zstd"}], compressed}] do
      conn = conn(:post, "/models?beta=true", body)
      conn = Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)

      conn =
        conn
        |> Plug.Conn.put_req_header("x-coop-model-grant", grant["token"])
        |> Plug.Conn.put_req_header("x-api-key", "workload-substitute")

      response =
        ModelProxy.call(
          conn,
          certificate,
          session.external_ref,
          "claude",
          "api.anthropic.com",
          "/v1/messages",
          model_stream: stream
        )

      assert response.status == 200
      assert response.resp_body =~ "data: reply"
      assert_received {:upstream, request}
      assert request.host == "api.anthropic.com"
      assert request.body == body
      assert Enum.all?(headers, &(&1 in request.headers))
      assert {"x-api-key", @key} in request.headers
      refute Enum.any?(request.headers, fn {name, _} -> name == "x-coop-model-grant" end)
    end

    refused_body = ~s({"model":"other-model"}) |> :zstd.compress() |> IO.iodata_to_binary()

    refused =
      conn(:post, "/models?beta=true", refused_body)
      |> Plug.Conn.put_req_header("x-coop-model-grant", grant["token"])
      |> Plug.Conn.put_req_header("content-encoding", "zstd")
      |> ModelProxy.call(
        certificate,
        session.external_ref,
        "claude",
        "api.anthropic.com",
        "/v1/messages",
        model_stream: stream
      )

    assert refused.status == 403
    refute_received {:upstream, _}

    assert ModelContracts.route(
             "claude",
             "apikey",
             "POST",
             "evil.example",
             "/v1/messages",
             "beta=true"
           ) == {:error, :model_route_refused}
  end

  test(
    "revocation interrupts an already started response instead of returning truncated success",
    %{certificate: certificate, request: request, session: session}
  ) do
    {:ok, grant} = ModelGrants.issue(certificate, session.external_ref, request)

    stream = fn _request, _pool, _timeout, state, callback ->
      {:cont, state} = callback.({:status, 200}, state)
      {:cont, state} = callback.({:headers, [{"content-type", "text/event-stream"}]}, state)
      {:cont, state} = callback.({:data, "data: first\n\n"}, state)
      {:ok, _} = put_account("replacement-key-canary")
      callback.({:data, "data: revoked\n\n"}, state)
      {:ok, :streaming}
    end

    request =
      conn(:post, "/models?beta=true", ~s({"model":"claude-sonnet-5-5","messages":[]}))
      |> Plug.Conn.put_req_header("x-coop-model-grant", grant["token"])

    assert catch_exit(
             ModelProxy.call(
               request,
               certificate,
               session.external_ref,
               "claude",
               "api.anthropic.com",
               "/v1/messages",
               model_stream: stream
             )
           ) == :shutdown
  end

  test("provider websocket refusals preserve HTTP status and retry headers", %{
    certificate: certificate,
    request: request,
    session: session
  }) do
    job = session.worker_job_document |> Map.put("targets", ["codex:gpt-6.2-sol/medium@work"])
    {:ok, checksum} = JobSpec.digest(job)
    session |> Session.Changeset.pin_worker_job(job, checksum) |> Repo.update!()
    {:ok, _} = ModelAccounts.put_key("codex@work", "codex-controller-key-canary", "test")

    {:ok, grant} =
      ModelGrants.issue(certificate, session.external_ref, %{
        request
        | "job_digest" => checksum,
          "provider" => "codex",
          "run_id" => "socket-run"
      })

    for status <- [401, 429] do
      request =
        conn(:get, "/models")
        |> Plug.Conn.put_req_header("x-coop-model-grant", grant["token"])
        |> Plug.Conn.put_req_header("upgrade", "websocket")

      response =
        ModelProxy.call(
          request,
          certificate,
          session.external_ref,
          "codex",
          "api.openai.com",
          "/v1/responses",
          model_socket: fn _options ->
            {:error,
             {:provider_response, status,
              [
                {"retry-after", "30"},
                {"set-cookie", "provider-secret"},
                {"content-type", "text/html"}
              ], "provider refusal"}}
          end
        )

      assert response.status == status
      assert response.resp_body == "provider refusal"
      assert Plug.Conn.get_resp_header(response, "x-content-type-options") == ["nosniff"]
      assert [type] = Plug.Conn.get_resp_header(response, "content-type")
      assert String.starts_with?(type, "text/plain")
      assert Plug.Conn.get_resp_header(response, "retry-after") == ["30"]
      assert Plug.Conn.get_resp_header(response, "set-cookie") == []
    end
  end

  test "an idle streaming response retains current model authority", %{
    certificate: certificate,
    session: session,
    request: request
  } do
    {:ok, grant} = ModelGrants.issue(certificate, session.external_ref, request)

    stream = fn _request, _pool, _timeout, state, callback ->
      {:cont, state} = callback.({:status, 200}, state)
      {:cont, state} = callback.({:headers, [{"content-type", "text/event-stream"}]}, state)
      {:cont, state} = callback.({:data, "data: connected\n\n"}, state)
      # Exercise two real authorization ticks while the provider sends no data.
      # credo:disable-for-next-line Ryker.Checks.TestNoProcessSleep
      Process.sleep(2100)
      {:cont, _} = callback.({:data, "data: reply\n\n"}, state)
      {:ok, :streaming}
    end

    conn =
      conn(:post, "/models?beta=true", ~s({"model":"claude-sonnet-5-5","messages":[]}))
      |> Plug.Conn.put_req_header("x-coop-model-grant", grant["token"])

    response =
      ModelProxy.call(
        conn,
        certificate,
        session.external_ref,
        "claude",
        "api.anthropic.com",
        "/v1/messages",
        model_stream: stream
      )

    assert response.resp_body =~ "data: reply"
  end

  test "a pending cancellation fences grants and live requests before worker cleanup", %{
    certificate: certificate,
    request: request,
    session: session,
    placement: placement
  } do
    {:ok, _claim} = Ryker.Work.Custody.claim_next("operator:model-cancel", 60, :work)
    {:ok, grant} = ModelGrants.issue(certificate, session.external_ref, request)

    {:ok, binding} =
      ModelGrants.authorize(certificate, session.external_ref, "claude", grant["token"])

    episode = Repo.fetch!(Ryker.Episodes.Episode.Query.by_id(session.episode_id))

    assert {:ok, %{status: :pending}} =
             Ryker.Work.Custody.cancel_current(episode, "operator:cancel", "Stop")

    assert Repo.get!(Ryker.CoopFleet.Placement, placement.id).state == :active

    assert ModelGrants.reauthorize(binding, session.external_ref, grant["token"]) ==
             {:error, :model_grant_refused}

    assert ModelGrants.issue(certificate, session.external_ref, request) ==
             {:error, :model_grant_refused}
  end

  test "admitted streams survive renewal but end on replacement or worker revocation", %{
    certificate: certificate,
    session: session,
    request: request
  } do
    {:ok, grant} = ModelGrants.issue(certificate, session.external_ref, request)

    {:ok, binding} =
      ModelGrants.authorize(certificate, session.external_ref, "claude", grant["token"])

    {1, _} =
      Repo.update_all(Certificate.Query.by_sha256(digest(certificate)),
        set: [revoked_at: Repo.now!(), revoked_by: "worker:model-worker"]
      )

    assert {:ok, _} = ModelGrants.reauthorize(binding, session.external_ref, grant["token"])

    assert ModelGrants.authorize(certificate, session.external_ref, "claude", grant["token"]) ==
             {:error, :model_grant_refused}

    replacement = "replacement-worker-certificate"
    {:ok, worker} = CoopWorkers.authorize("model-worker", "model-pool", digest(replacement))
    worker |> Worker.Changeset.enroll(digest(replacement), Repo.generate_id()) |> Repo.update!()

    assert ModelGrants.reauthorize(binding, session.external_ref, grant["token"]) ==
             {:error, :model_grant_refused}

    assert ModelGrants.authorize(replacement, session.external_ref, "claude", grant["token"]) ==
             {:error, :model_grant_refused}

    {:ok, fresh} = ModelGrants.issue(replacement, session.external_ref, request)
    refute fresh["token"] == grant["token"]

    {:ok, current} =
      ModelGrants.authorize(replacement, session.external_ref, "claude", fresh["token"])

    {:ok, _} = WorkerLifecycle.revoke("model-worker", "test")

    assert ModelGrants.reauthorize(current, session.external_ref, fresh["token"]) ==
             {:error, :model_grant_refused}
  end

  test "inference permits share principal capacity and release only after upstream stops",
       %{certificate: certificate, request: request, session: session} do
    {binding, authorize} =
      permit_binding(%{certificate: certificate, request: request, session: session})

    {:ok, _} = ModelAccounts.put_key("claude@alias", @key, "test")
    assert {:ok, lease} = ModelPermits.reserve(binding, authorize)

    upstream =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    assert {:ok, remaining} = ModelPermits.activate(lease, upstream)
    assert remaining > 0
    assert {:ok, %{active: 1, concurrency: 1}} = ModelPermits.capacity("claude@alias")

    assert ModelPermits.reserve(binding, authorize) ==
             {:error, {:model_limited, :concurrency, nil}}

    assert {:ok, %{blocked_until: nil}} = ModelPermits.capacity("claude@work")
    assert ModelPermits.cancel(lease) == :ok
    refute Process.alive?(upstream)
    assert {:ok, %{active: 0}} = ModelPermits.capacity("claude@alias")
  end

  test "websocket terminal identity releases a permit while keeping its socket alive", %{
    certificate: certificate,
    request: request,
    session: session
  } do
    {binding, authorize} =
      permit_binding(%{certificate: certificate, request: request, session: session})

    {:ok, lease} = ModelPermits.reserve(binding, authorize, :websocket)

    upstream =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, _} = ModelPermits.activate(lease, upstream)
    assert ModelPermits.bind_response(lease, "response_one") == :ok
    assert ModelPermits.complete(lease, "other") == {:error, :model_permit_changed}
    assert {:ok, %{active: 1}} = ModelPermits.capacity("claude@work")
    assert ModelPermits.complete(lease, "response_one") == :ok
    assert Process.alive?(upstream)
    assert {:ok, %{active: 0}} = ModelPermits.capacity("claude@work")
    Process.exit(upstream, :kill)
  end

  test "provider cooldown is principal-wide, monotonic and survives account replacement",
       %{certificate: certificate, request: request, session: session} do
    {binding, authorize} =
      permit_binding(%{certificate: certificate, request: request, session: session})

    {:ok, _} = ModelAccounts.put_key("claude@alias", @key, "test")
    assert ModelPermits.observe_limit(binding, [{"Retry-After", "60"}]) == {:ok, :ok}
    {:ok, %{blocked_until: until}} = ModelPermits.capacity("claude@alias")
    assert DateTime.diff(until, Repo.now!()) in 59..60
    assert ModelPermits.observe_limit(binding, [{"retry-after", "1"}]) == {:ok, :ok}
    assert {:ok, %{blocked_until: ^until}} = ModelPermits.capacity("claude@alias")

    assert {:error, {:model_limited, :provider_cooldown, ^until}} =
             ModelPermits.reserve(binding, authorize)

    assert {:ok, _} = put_account(@key)
    assert {:ok, %{blocked_until: ^until}} = ModelPermits.capacity("claude@work")
  end

  test "old controller holds require explicit stop confirmation instead of expiry", %{
    certificate: certificate,
    request: request,
    session: session
  } do
    {binding, authorize} =
      permit_binding(%{certificate: certificate, request: request, session: session})

    {:ok, lease} = ModelPermits.reserve(binding, authorize)
    :ok = ModelPermits.cancel(lease)
    [permit] = Repo.all(ModelPermit)
    old_boot = Ecto.UUID.generate()

    permit
    |> Ecto.Changeset.change(
      state: :uncertain,
      owner_boot: old_boot,
      finished_at: nil,
      finish_reason: nil,
      deadline: DateTime.add(Repo.now!(), -60)
    )
    |> Repo.update!()

    assert ModelPermits.reserve(binding, authorize) ==
             {:error, {:model_limited, :unresolved_requests, nil}}

    assert ModelPermits.acknowledge_stopped(permit.id, Ecto.UUID.generate(), "test") ==
             {:error, :model_request_still_local}

    assert ModelPermits.acknowledge_stopped(permit.id, old_boot, "test") == {:ok, :ok}
    assert {:ok, %{active: 0}} = ModelPermits.capacity("claude@work")
  end

  test "an inference deadline stops upstream before returning capacity", %{
    certificate: certificate,
    request: request,
    session: session
  } do
    {binding, authorize} =
      permit_binding(%{certificate: certificate, request: request, session: session})

    binding = %{binding | job: put_in(binding.job, ["limits", "turn_timeout_ms"], 100)}
    {:ok, lease} = ModelPermits.reserve(binding, authorize)
    monitor = Process.monitor(lease)

    upstream =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    {:ok, _} = ModelPermits.activate(lease, upstream)
    assert_receive {:DOWN, ^monitor, :process, ^lease, :normal}, 5_000
    refute Process.alive?(upstream)
    assert {:ok, %{active: 0}} = ModelPermits.capacity("claude@work")
  end

  test "request owner death stops the inference and releases its hold", %{
    certificate: certificate,
    request: request,
    session: session
  } do
    {binding, authorize} =
      permit_binding(%{certificate: certificate, request: request, session: session})

    parent = self()

    {:ok, owner} =
      Task.start(fn ->
        {:ok, lease} = ModelPermits.reserve(binding, authorize)

        upstream =
          spawn(fn ->
            receive do
              :never -> :ok
            end
          end)

        {:ok, _} = ModelPermits.activate(lease, upstream)
        send(parent, {:owned_inference, lease, upstream})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:owned_inference, lease, upstream}, 5_000
    monitor = Process.monitor(lease)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^lease, :normal}, 5_000
    refute Process.alive?(upstream)
    assert {:ok, %{active: 0}} = ModelPermits.capacity("claude@work")
  end

  test "an unexpectedly killed lease stops its upstream and is reconciled by proven process death",
       %{certificate: certificate, request: request, session: session} do
    {binding, authorize} =
      permit_binding(%{certificate: certificate, request: request, session: session})

    {:ok, lease} = ModelPermits.reserve(binding, authorize)

    upstream =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    monitor = Process.monitor(upstream)
    {:ok, _} = ModelPermits.activate(lease, upstream)
    Process.exit(lease, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^upstream, :killed}, 5_000
    {:ok, replacement} = ModelPermits.reserve(binding, authorize)
    assert {:ok, %{active: 1}} = ModelPermits.capacity("claude@work")
    assert ModelPermits.cancel(replacement) == :ok
  end

  test "a failed websocket response records principal cooldown before releasing its own hold", %{
    certificate: certificate,
    request: request,
    session: session
  } do
    {binding, authorize} =
      permit_binding(%{certificate: certificate, request: request, session: session})

    {:ok, upstream} = Agent.start(fn -> :socket end)
    {:ok, lease} = ModelPermits.reserve(binding, authorize, :websocket)
    {:ok, _} = ModelPermits.activate(lease, upstream)
    ledger = ModelSocketLedger.enqueue(%ModelSocketLedger{}, nil, lease)
    state = %ModelSocket.State{upstream: upstream, binding: binding, ledger: ledger}
    created = Jason.encode!(%{type: "response.created", response: %{id: "response_failed"}})

    assert {:push, {:text, ^created}, state} =
             ModelSocket.handle_info({:model_socket_frame, upstream, {:text, created}}, state)

    failed =
      Jason.encode!(%{
        type: "response.failed",
        headers: %{"retry-after" => "90"},
        response: %{
          id: "response_failed",
          error: %{code: "rate_limit_exceeded", headers: %{"retry-after" => "invalid"}}
        }
      })

    assert {:push, {:text, ^failed}, _state} =
             ModelSocket.handle_info({:model_socket_frame, upstream, {:text, failed}}, state)

    assert Process.alive?(upstream)
    assert {:ok, %{active: 0, blocked_until: until}} = ModelPermits.capacity("claude@work")
    assert DateTime.diff(until, Repo.now!()) in 89..90
    GenServer.stop(upstream)
  end

  test "uncorrelated websocket errors retain holds until upstream teardown", %{
    certificate: certificate,
    request: request,
    session: session
  } do
    {binding, authorize} =
      permit_binding(%{certificate: certificate, request: request, session: session})

    {:ok, upstream} = Agent.start(fn -> :socket end)
    {:ok, lease} = ModelPermits.reserve(binding, authorize, :websocket)
    {:ok, _} = ModelPermits.activate(lease, upstream)
    monitor = Process.monitor(lease)

    state = %ModelSocket.State{
      upstream: upstream,
      binding: binding,
      ledger: ModelSocketLedger.enqueue(%ModelSocketLedger{}, nil, lease)
    }

    error = ~s({"type":"error","status":400,"error":{"code":"invalid_request"}})

    assert {:stop, :normal, {1011, _reason}, {:text, ^error}, ^state} =
             ModelSocket.handle_info({:model_socket_frame, upstream, {:text, error}}, state)

    assert {:ok, %{active: 1, blocked_until: nil}} = ModelPermits.capacity("claude@work")
    assert ModelSocket.terminate(:normal, state) == :ok
    assert_receive {:DOWN, ^monitor, :process, ^lease, :normal}, 5_000
    assert {:ok, %{active: 0}} = ModelPermits.capacity("claude@work")
  end

  defp permit_binding(%{certificate: certificate, request: request, session: session}) do
    {:ok, grant} = ModelGrants.issue(certificate, session.external_ref, request)

    {:ok, binding} =
      ModelGrants.authorize(certificate, session.external_ref, "claude", grant["token"])

    {binding, fn -> ModelGrants.reauthorize(binding, session.external_ref, grant["token"]) end}
  end

  defp put_account(key) do
    ModelAccounts.put(
      "claude",
      "work",
      %{"version" => 1, "provider" => "claude", "selection" => "apikey", "credential" => key},
      "test"
    )
  end
end
