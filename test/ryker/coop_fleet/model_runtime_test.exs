defmodule Ryker.CoopFleet.ModelRuntimeTest do
  use Ryker.DataCase, async: false
  alias Ryker.CoopFleet.{Bridge, Certificate, Enrollment, JobSpec}
  alias Ryker.CoopFleet.{ModelAccounts, ModelGrants, ModelPermits, ModelRun, ModelSocketUpstream}
  alias Ryker.CoopFleet.{Placement, Router, Worker, WorkerLifecycle}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.{WorkerJob, WorkSessions}
  alias Ryker.Work.Session

  @moduletag skip: System.get_env("RYKER_FLEET_RUNTIME") != "1"
  @moduletag timeout: 420_000, ownership_timeout: 420_000
  @key "controller-only-provider-key-canary"
  @socket_key "controller-only-codex-key-canary"

  test "a real worker child and Docker guard use only leased Ryker model access" do
    {temporary, 0} = System.cmd("pwd", ["-P"], cd: System.tmp_dir!())

    root =
      Path.join(String.trim(temporary), "fleet-runtime-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {cert, key} = certificate!(root)
    owner = self()

    second? = System.get_env("RYKER_FLEET_SECOND_ENGINE") != nil
    counter = start_supervised!({Agent, fn -> if second?, do: -2, else: 0 end})
    stream = scripted_stream(owner, counter)
    socket_port = socket_provider!(owner)

    socket_connector = fn request ->
      ModelSocketUpstream.connect(request, fn _options ->
        {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", socket_port, protocols: [:http1])
        {:ok, conn, :ws}
      end)
    end

    gateway =
      start_supervised!(
        {Bandit,
         plug:
           {Router,
            [
              model_stream: stream,
              model_socket: socket_connector,
              enrollment_authority: %{
                ca_certificate_pem: File.read!(cert),
                ca_key_pem: File.read!(key),
                certificate_ttl_seconds: 3600
              }
            ]},
         scheme: :https,
         ip: {0, 0, 0, 0},
         port: 0,
         certfile: cert,
         keyfile: key,
         startup_log: false,
         thousand_island_options: [
           transport_options: [
             cacertfile: cert,
             verify: :verify_peer,
             fail_if_no_peer_cert: false,
             versions: [:"tlsv1.3"]
           ]
         ]}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(gateway)

    try do
      enroll_worker!(root, port, cert, "native-runtime-worker", "")

      if second? do
        enroll_worker!(root, port, cert, "small-runtime-worker", "SECOND_")
        large = Repo.get!(Worker, "native-runtime-worker").capacity["machine"]
        small = Repo.get!(Worker, "small-runtime-worker").capacity["machine"]
        assert small["cpu_millis"] < 4_000 and large["cpu_millis"] >= 4_000
        assert small["daemon"] != large["daemon"]
      end

      {:ok, _} = ModelAccounts.put_key("claude@work", @key, "test")
      session = session!()

      options = [
        workspace_ref: "native-runtime-pool",
        capability_names: [],
        poll_interval_ms: 50,
        max_waits: 2400
      ]

      if second?, do: exercise_concurrent_pair!(options)

      created =
        request!(
          session,
          "POST",
          "/v1/sessions",
          %{
            "task" => Session.coop_task_ref(session),
            "job" => session.worker_job_document,
            "expected_job_digest" => session.worker_job_digest
          },
          options
        )

      assert placed_worker(session) == "native-runtime-worker"
      operation = Map.fetch!(created, "operation")
      terminal = wait_operation!(session, operation["id"], options)
      assert terminal["state"] == "succeeded"
      coop_id = Map.fetch!(terminal, "resource_id")
      session = session |> Session.Changeset.bind(coop_id) |> Repo.update!()
      remote = request!(session, "GET", "/v1/sessions/#{coop_id}", nil, options)

      turn =
        request!(
          session,
          "POST",
          "/v1/sessions/#{coop_id}/turns",
          %{
            "expected_revision" => remote["revision"],
            "prompt" => "Reply through the native model relay."
          },
          options
        )["turn"]

      answer = wait_turn!(session, coop_id, turn["id"], options)
      assert answer["state"] == "completed", inspect(answer)
      assert Jason.encode!(answer) =~ "guarded controller reply"
      assert_received {:native_model_request, 1, "api.anthropic.com", "/v1/messages"}
      assert Repo.aggregate(Certificate.Query.by_worker_id("native-runtime-worker"), :count) > 2

      if System.get_env("RYKER_FLEET_LONG_STREAM") == "1" do
        assert Enum.any?(Repo.all(ModelRun.Query.all()), fn run ->
                 DateTime.diff(run.updated_at, run.inserted_at, :second) >= 100
               end)
      end

      remote = request!(session, "GET", "/v1/sessions/#{coop_id}", nil, options)

      trickling =
        request!(
          session,
          "POST",
          "/v1/sessions/#{coop_id}/turns",
          %{
            "expected_revision" => remote["revision"],
            "prompt" => "Keep a tiny stream alive."
          },
          options
        )["turn"]

      result = wait_turn!(session, coop_id, trickling["id"], options)
      assert result["state"] == "completed", inspect(result)
      assert_received {:native_model_request, 2, "api.anthropic.com", "/v1/messages"}
      remote = request!(session, "GET", "/v1/sessions/#{coop_id}", nil, options)

      interrupted =
        request!(
          session,
          "POST",
          "/v1/sessions/#{coop_id}/turns",
          %{
            "expected_revision" => remote["revision"],
            "prompt" => "Start a stream that will be revoked."
          },
          options
        )["turn"]

      assert_receive {:native_model_request, 3, "api.anthropic.com", "/v1/messages"}, 30_000
      assert ModelAccounts.remove("claude", "work", "test") == :ok
      failure = wait_turn!(session, coop_id, interrupted["id"], options)
      assert failure["state"] == "failed", inspect(failure)
      remote = request!(session, "GET", "/v1/sessions/#{coop_id}", nil, options)

      request!(
        session,
        "POST",
        "/v1/sessions/#{coop_id}/close",
        %{"expected_revision" => remote["revision"]},
        options
      )

      {:ok, _} = ModelAccounts.put_key("codex@work", @socket_key, "test")
      socket_session = session!("codex:gpt-6.2-sol/medium@work", 500)
      {socket_session, socket_id, socket_remote} = start_session!(socket_session, options)

      socket_turn =
        request!(
          socket_session,
          "POST",
          "/v1/sessions/#{socket_id}/turns",
          %{
            "expected_revision" => socket_remote["revision"],
            "prompt" => "Reply through the native WebSocket relay."
          },
          options
        )["turn"]

      socket_result = wait_turn!(socket_session, socket_id, socket_turn["id"], options)
      assert socket_result["state"] == "completed", inspect(socket_result)
      assert_received {:native_socket_request, 1}
      assert_receive {:native_socket_closed, 1}, 10_000
      socket_remote = request!(socket_session, "GET", "/v1/sessions/#{socket_id}", nil, options)

      stopped_turn =
        request!(
          socket_session,
          "POST",
          "/v1/sessions/#{socket_id}/turns",
          %{
            "expected_revision" => socket_remote["revision"],
            "prompt" => "Start a socket that will be revoked."
          },
          options
        )["turn"]

      assert_receive {:native_socket_request, 2}, 30_000
      :ok = ModelAccounts.remove("codex", "work", "test")
      stopped = wait_turn!(socket_session, socket_id, stopped_turn["id"], options)
      assert stopped["state"] == "failed", inspect(stopped)
      assert_receive {:native_socket_closed, 2}, 10_000
      socket_remote = request!(socket_session, "GET", "/v1/sessions/#{socket_id}", nil, options)

      request!(
        socket_session,
        "POST",
        "/v1/sessions/#{socket_id}/close",
        %{"expected_revision" => socket_remote["revision"]},
        options
      )

      for {_, name, _} <- Process.get(:fleet_workers) do
        refute worker_files_contain?(name, @socket_key)
        refute worker_files_contain?(name, @key)
      end

      if second?, do: exercise_worker_loss!(options)
    after
      Enum.each(Process.get(:fleet_workers, []), &stop_worker/1)
    end
  end

  defp exercise_worker_loss!(options) do
    {:ok, _} = ModelAccounts.put_key("claude@work", @key, "test")
    {session, _id, _turn} = start_pair_turn!(4_000, "native-runtime-worker", options)
    assert_receive {:loss_request, provider}, 30_000
    monitor = Process.monitor(provider)
    {:ok, %{active: 1}} = ModelPermits.capacity("claude@work")

    {port, name, _log} = worker = Process.get({:fleet_worker, "native-runtime-worker"})
    # Retain only the public certificate. Pin it just before the partition so
    # a denial cannot be explained by the certificate having already rotated.
    {file, 0} =
      System.cmd("docker", ["exec", name, "cat", "/var/lib/coop/sessions/identity.json"])

    [{:Certificate, der, _}] = :public_key.pem_decode(Jason.decode!(file)["certificate_pem"])

    grant_request = %{
      "account" => "work",
      "job_digest" => session.worker_job_digest,
      "provider" => "claude",
      "run_id" => "loss-check"
    }

    job = session.worker_job_document["job_ref"]
    {:ok, grant} = ModelGrants.issue(der, job, grant_request)
    {_, 0} = System.cmd("docker", ["pause", name])

    try do
      assert {:ok, %{status: :revoked}} = WorkerLifecycle.revoke("native-runtime-worker", "test")
      assert_receive {:DOWN, ^monitor, :process, ^provider, _}, 20_000
      assert ModelGrants.issue(der, job, grant_request) == {:error, :model_grant_refused}

      assert ModelGrants.authorize(der, job, "claude", grant["token"]) ==
               {:error, :model_grant_refused}

      wait_until(fn -> match?({:ok, %{active: 0}}, ModelPermits.capacity("claude@work")) end)
    after
      {_, 0} = System.cmd("docker", ["unpause", name])
    end

    {_, 0} = System.cmd("docker", ["kill", name])
    assert_receive {^port, {:exit_status, _}}, 10_000
    Process.put(:fleet_workers, List.delete(Process.get(:fleet_workers), worker))

    {survivor, id, turn} = start_pair_turn!(500, "small-runtime-worker", options)
    result = wait_turn!(survivor, id, turn, options)
    assert result["state"] == "completed"
    assert Jason.encode!(result) =~ "guarded controller reply"
  end

  # Both upstream callbacks must be alive before either is allowed to finish.
  defp exercise_concurrent_pair!(options) do
    {:ok, _} = Ryker.CoopFleet.ModelPermits.set_limit("claude@work", 2, "test")
    large = Repo.get!(Worker, "native-runtime-worker").capacity["machine"]
    first = start_pair_turn!(large["cpu_millis"] - 250, "native-runtime-worker", options)
    assert_receive {:pair_request, -1, first_provider}, 30_000

    wait_until(fn ->
      Repo.get!(Worker, "native-runtime-worker").capacity["machine"]["free_cpu_millis"] == 250
    end)

    second = start_pair_turn!(500, "small-runtime-worker", options)
    assert_receive {:pair_request, 0, second_provider}, 30_000
    send(first_provider, :release_pair)
    send(second_provider, :release_pair)

    for {session, id, turn} <- [first, second] do
      result = wait_turn!(session, id, turn, options)
      assert result["state"] == "completed"
      assert Jason.encode!(result) =~ "guarded controller reply"
      remote = request!(session, "GET", "/v1/sessions/#{id}", nil, options)

      request!(
        session,
        "POST",
        "/v1/sessions/#{id}/close",
        %{"expected_revision" => remote["revision"]},
        options
      )
    end

    wait_until(fn ->
      Enum.all?(["native-runtime-worker", "small-runtime-worker"], fn id ->
        machine = Repo.get!(Worker, id).capacity["machine"]
        machine["free_cpu_millis"] == machine["cpu_millis"]
      end)
    end)

    {:ok, _} = Ryker.CoopFleet.ModelPermits.set_limit("claude@work", 1, "test")
  end

  defp start_pair_turn!(cpu, worker, options) do
    {session, id, remote} = start_session!(session!("claude:sonnet/high@work", cpu), options)
    assert placed_worker(session) == worker

    turn =
      request!(
        session,
        "POST",
        "/v1/sessions/#{id}/turns",
        %{
          "expected_revision" => remote["revision"],
          "prompt" => "Reply through the native model relay."
        },
        options
      )

    {session, id, turn["turn"]["id"]}
  end

  defp placed_worker(session) do
    session.id
    |> Placement.Query.by_session_id()
    |> Placement.Query.active()
    |> Repo.fetch!()
    |> Map.fetch!(:worker_id)
  end

  defp enroll_worker!(root, port, cert, id, prefix) do
    {:ok, token} = Enrollment.issue_token(id, "native-runtime-pool", "test")
    invitation = Path.join(root, id)
    File.write!(invitation, token.token)
    File.chmod!(invitation, 0o600)
    worker = start_worker!(root, port, cert, invitation, prefix)
    Process.put({:fleet_worker, id}, worker)
    Process.put(:fleet_workers, [worker | Process.get(:fleet_workers, [])])

    wait_until(fn ->
      case Repo.peek(Worker.Query.by_id(id)) do
        %Worker{state: :eligible, capacity: %{"machine" => %{} = report}} -> report
        _pending -> false
      end
    end)
  end

  defp scripted_stream(owner, counter) do
    fn request, _pool, _timeout, state, callback ->
      assert {"x-api-key", @key} in request.headers
      refute Enum.any?(request.headers, fn {name, _} -> name == "x-coop-model-grant" end)
      serial = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(owner, {:native_model_request, serial, request.host, request.path})
      {:cont, state} = callback.({:status, 200}, state)
      {:cont, state} = callback.({:headers, [{"content-type", "text/event-stream"}]}, state)
      {:cont, state} = callback.({:data, "data: connected\n\n"}, state)
      await_provider(owner, serial, state, callback)
      {:cont, _state} = callback.({:data, "data: guarded controller reply\n\n"}, state)
      {:ok, :streaming}
    end
  end

  defp await_provider(owner, serial, _state, _callback) when serial <= 0 do
    send(owner, {:pair_request, serial, self()})
    assert_receive :release_pair, 60_000
  end

  defp await_provider(owner, 4, _state, _callback) do
    send(owner, {:loss_request, self()})
    assert_receive :release_loss, 60_000
  end

  defp await_provider(_owner, 5, _state, _callback), do: :ok

  defp await_provider(_owner, serial, state, callback),
    do: provider_delay(serial, state, callback)

  defp provider_delay(1, _state, _callback) do
    if System.get_env("RYKER_FLEET_LONG_STREAM") == "1", do: silence(125_000)
  end

  defp provider_delay(2, state, callback) do
    if System.get_env("RYKER_FLEET_LONG_STREAM") == "1" do
      for _ <- 1..14 do
        silence(5_000)
        {:cont, _} = callback.({:data, ": tiny keepalive\n\n"}, state)
      end
    end
  end

  defp provider_delay(_serial, _state, _callback), do: silence(30_000)

  # Provider silence is the condition under test: cross the real transport
  # idle limit and grant lifetime rather than replacing either clock.
  defp silence(milliseconds) do
    # credo:disable-for-next-line Ryker.Checks.TestNoProcessSleep
    Process.sleep(milliseconds)
  end

  defp session!(target \\ "claude:sonnet/high@work", cpu_millis \\ 4_000) do
    episode = Ecto.UUID.generate()

    {:ok, _} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: episode,
          episode_key: "runtime:#{episode}",
          native_input_id: "runtime:#{episode}",
          occurred_at: Repo.now!(),
          turn_ref: "runtime:#{episode}"
        })
      )

    {:ok, session} =
      WorkSessions.pin_episode(episode, "work-read-only", String.duplicate("b", 64))

    session = WorkerJob.pin!(session)

    job =
      session.worker_job_document
      |> Map.put("source", nil)
      |> Map.put("companions", [])
      |> Map.put("egress", %{"mode" => "open", "rules" => [], "export_destinations" => false})
      |> Map.put("model_credentials", "controller")
      |> Map.put("targets", [target])
      |> put_in(["resources", "cpu_millis"], cpu_millis)
      |> put_in(["limits", "turn_timeout_ms"], 240_000)

    {:ok, digest} = JobSpec.digest(job)
    session |> Session.Changeset.pin_worker_job(job, digest) |> Repo.update!()
  end

  defp start_session!(session, options) do
    created =
      request!(
        session,
        "POST",
        "/v1/sessions",
        %{
          "task" => Session.coop_task_ref(session),
          "job" => session.worker_job_document,
          "expected_job_digest" => session.worker_job_digest
        },
        options
      )

    terminal = wait_operation!(session, created["operation"]["id"], options)
    assert terminal["state"] == "succeeded", inspect(terminal)
    coop_id = terminal["resource_id"]
    session = session |> Session.Changeset.bind(coop_id) |> Repo.update!()
    {session, coop_id, request!(session, "GET", "/v1/sessions/#{coop_id}", nil, options)}
  end

  defp socket_provider!(owner) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(listener)

    start_supervised!(
      {Task,
       fn ->
         for serial <- 1..2 do
           {:ok, socket} = :gen_tcp.accept(listener)
           {:ok, request} = :gen_tcp.recv(socket, 0, 10_000)

           assert String.contains?(
                    String.downcase(request),
                    "authorization: bearer " <> @socket_key
                  )

           [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)\r/i, request)

           accept =
             :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

           :ok =
             :gen_tcp.send(
               socket,
               "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
             )

           :ok = :gen_tcp.send(socket, <<0x89, 4, "ping">>)
           frames = for _ <- 1..2, do: socket_frame!(socket)
           assert {10, "ping"} in frames
           {1, body} = Enum.find(frames, &(elem(&1, 0) == 1))
           assert Jason.decode!(body)["model"] == "gpt-6.2-sol"
           send(owner, {:native_socket_request, serial})

           created = ~s({"type":"response.created","response":{"id":"response_#{serial}"}})
           :ok = :gen_tcp.send(socket, <<0x81, byte_size(created), created::binary>>)

           if serial == 1 do
             reply =
               ~s({"type":"response.completed","response":{"id":"response_#{serial}"},"text":"guarded controller reply"})

             :ok = :gen_tcp.send(socket, <<0x81, byte_size(reply), reply::binary>>)
           end

           assert :gen_tcp.recv(socket, 0, 30_000) == {:error, :closed}
           send(owner, {:native_socket_closed, serial})
           :gen_tcp.close(socket)
         end

         :gen_tcp.close(listener)
       end}
    )

    on_exit(fn -> :gen_tcp.close(listener) end)
    port
  end

  defp socket_frame!(socket) do
    {:ok, <<1::1, _reserved::3, opcode::4, 1::1, size::7>>} = :gen_tcp.recv(socket, 2, 10_000)
    assert size < 126

    {:ok, <<mask::binary-size(4), data::binary-size(size)>>} =
      :gen_tcp.recv(socket, 4 + size, 10_000)

    payload =
      for {byte, index} <- data |> :binary.bin_to_list() |> Enum.with_index(),
          into: <<>>,
          do: <<Bitwise.bxor(byte, :binary.at(mask, rem(index, 4)))>>

    {opcode, payload}
  end

  defp request!(session, method, path, body, options) do
    request = %{"method" => method, "path" => path}
    request = if body, do: Map.put(request, "body", body), else: request
    key = "runtime:#{System.unique_integer([:positive])}"
    assert {:ok, response} = Bridge.execute(session, "api_request", request, key, options)
    response
  end

  defp wait_operation!(session, id, options) do
    wait_until(fn ->
      response = request!(session, "GET", "/v1/operations/#{id}", nil, options)
      operation = Map.get(response, "operation", response)
      if operation["state"] in ["succeeded", "failed", "uncertain"], do: operation
    end)
  end

  defp wait_turn!(session, coop_id, turn_id, options) do
    wait_until(fn ->
      response =
        request!(session, "GET", "/v1/sessions/#{coop_id}/turns/#{turn_id}", nil, options)

      if response["state"] in ["completed", "failed", "cancelled"], do: response
    end)
  end

  defp wait_until(callback) do
    ref = make_ref()

    assert Ryker.TestHelpers.eventually(
             fn ->
               case callback.() do
                 value when value in [nil, false] ->
                   check_worker_exit!()
                   false

                 value ->
                   send(self(), {ref, value})
                   true
               end
             end,
             240_000
           ),
           "real runtime did not reach the expected state"

    assert_receive {^ref, value}
    value
  end

  defp check_worker_exit! do
    for {worker, name, log} <- Process.get(:fleet_workers, []) do
      receive do
        {^worker, {:exit_status, status}} ->
          flunk("#{name} exited #{status}: " <> worker_output(log))
      after
        0 -> :ok
      end
    end
  end

  defp worker_output(log) do
    case File.read(log) do
      {:ok, output} -> String.slice(output, -4000, 4000)
      _missing -> "no worker output"
    end
  end

  defp start_worker!(root, port, cert, invitation, prefix) do
    docker = System.find_executable("docker")
    engine = System.fetch_env!("RYKER_FLEET_#{prefix}ENGINE")

    for {source, name} <- [{cert, "controller-ca.pem"}, {invitation, "invitation"}] do
      {_output, 0} = System.cmd(docker, ["cp", source, engine <> ":/var/lib/coop/" <> name])
    end

    {_output, 0} =
      System.cmd(docker, [
        "exec",
        engine,
        "chown",
        "1000:1000",
        "/var/lib/coop/controller-ca.pem",
        "/var/lib/coop/invitation"
      ])

    {_output, 0} =
      System.cmd(docker, [
        "exec",
        engine,
        "chmod",
        "600",
        "/var/lib/coop/controller-ca.pem",
        "/var/lib/coop/invitation"
      ])

    name = "coop-fleet-runtime-#{System.unique_integer([:positive])}"
    log = Path.join(root, name <> ".log")

    args = [
      "run",
      "--rm",
      "--pull",
      "never",
      "--name",
      name,
      "--user",
      "1000:1000",
      "--mount",
      "type=volume,src=#{System.fetch_env!("RYKER_FLEET_#{prefix}STATE_VOLUME")},dst=/var/lib/coop",
      "--mount",
      "type=volume,src=#{System.fetch_env!("RYKER_FLEET_#{prefix}SOCKET_VOLUME")},dst=/run/fleet-engine",
      "--mount",
      "type=bind,src=#{System.fetch_env!("RYKER_FLEET_COOP_BINARY")},dst=/usr/local/bin/coop,readonly",
      "-e",
      "HOME=/var/lib/coop",
      "-e",
      "TMPDIR=/var/lib/coop/tmp",
      "-e",
      "COOP_CONFIG_DIR=/var/lib/coop/agents",
      "-e",
      "COOP_RUNTIME=docker",
      "-e",
      "COOP_IMAGE=#{System.fetch_env!("RYKER_FLEET_FIXTURE_IMAGE")}",
      "-e",
      "DOCKER_HOST=unix:///run/fleet-engine/docker.sock",
      "--entrypoint",
      "/usr/local/bin/coop",
      System.fetch_env!("RYKER_FLEET_WORKER_IMAGE"),
      "sessions",
      "connect",
      "--state",
      "/var/lib/coop/sessions",
      "--controller",
      "https://host.docker.internal:#{port}",
      "--token-file",
      "/var/lib/coop/invitation",
      "--ca-file",
      "/var/lib/coop/controller-ca.pem"
    ]

    args =
      if :os.type() == {:unix, :linux},
        do: List.insert_at(args, 1, "--add-host=host.docker.internal:host-gateway"),
        else: args

    worker =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", ~s(exec "$@" > "$FLEET_WORKER_LOG" 2>&1), "fleet-worker", docker | args],
        env: [{~c"FLEET_WORKER_LOG", String.to_charlist(log)}]
      ])

    {worker, name, log}
  end

  defp stop_worker({worker, name, _log}) do
    if Port.info(worker) do
      System.cmd("docker", ["stop", "--time", "30", name], stderr_to_stdout: true)

      receive do
        {^worker, {:exit_status, _status}} -> :ok
      after
        35_000 -> flunk("worker did not stop within 30 seconds")
      end
    end
  end

  defp certificate!(root) do
    cert = Path.join(root, "ca.pem")
    key = Path.join(root, "ca-key.pem")

    {_output, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-days",
          "1",
          "-keyout",
          key,
          "-out",
          cert,
          "-subj",
          "/CN=Fleet Runtime Test",
          "-addext",
          "subjectAltName=DNS:localhost,DNS:host.docker.internal,IP:127.0.0.1",
          "-addext",
          "basicConstraints=critical,CA:TRUE"
        ],
        stderr_to_stdout: true
      )

    {cert, key}
  end

  defp worker_files_contain?(name, secret) do
    script =
      ~S(needle=$1; shift; for file do if grep -q -F -- "$needle" "$file"; then printf 'match\n'; else status=$?; if [ "$status" -ne 1 ]; then exit "$status"; fi; fi; done)

    {output, status} =
      System.cmd(
        "docker",
        [
          "exec",
          name,
          "find",
          "/var/lib/coop",
          "-type",
          "f",
          "-exec",
          "sh",
          "-c",
          script,
          "sh",
          secret,
          "{}",
          "+"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    output != ""
  end
end
